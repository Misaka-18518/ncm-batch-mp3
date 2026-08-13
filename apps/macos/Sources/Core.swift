import Foundation

struct ProcessResult {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

enum ProcessRunner {
    static func run(_ executable: String, arguments: [String], input: Data? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        // Drain stdout/stderr concurrently: a child that fills a pipe buffer blocks on
        // write, so reading only after waitUntilExit would deadlock.
        var stdout = Data()
        var stderr = Data()
        let drainGroup = DispatchGroup()
        DispatchQueue.global().async(group: drainGroup) {
            stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(group: drainGroup) {
            stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        }

        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        drainGroup.wait()

        return ProcessResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            guard let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) else {
                break
            }
            let byteString = String(hexString[index..<next])
            bytes.append(UInt8(byteString, radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    func starts(withASCII ascii: String) -> Bool {
        starts(with: Data(ascii.utf8))
    }
}

final class BinaryReader {
    private let handle: FileHandle

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func read(count: Int) throws -> Data {
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw NCMConversionError.incompleteFile("文件结构不完整")
        }
        return data
    }

    func readUInt32LE() throws -> UInt32 {
        let data = try read(count: 4)
        let bytes = [UInt8](data)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    func offset() throws -> UInt64 {
        try handle.offset()
    }

    func seek(to offset: UInt64) throws {
        try handle.seek(toOffset: offset)
    }

    func seekForward(_ amount: UInt64) throws {
        try handle.seek(toOffset: try handle.offset() + amount)
    }

    func readChunk(maxLength: Int) throws -> Data? {
        try handle.read(upToCount: maxLength)
    }
}

enum NCMConverterCore {
    static let magic = Data("CTENFDAM".utf8)
    static let coreKey = Data(hexString: "687A4852416D736F356B496E62617857")
    static let metaKey = Data(hexString: "2331346C6A6B5F215C5D2630553C2728")
    static let opensslPath = "/usr/bin/openssl"
    static let chunkSize = 1024 * 1024
    static let maxCoverBytes = 32 * 1024 * 1024
    static let cachedFFmpegPath: String? = findFFmpeg()

    struct ParsedHeader {
        let keyBox: [UInt8]
        let metadata: [String: Any]
        let coverData: Data?
    }

    struct ExtractionResult {
        let metadata: [String: Any]
        let sourceFormat: String
        let coverData: Data?
    }

    static func convertOne(inputURL: URL, options: ConversionOptions) throws -> ConversionResult {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ncm-swift-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let tempAudioURL = tempDirectory.appendingPathComponent("audio.bin")
        let extraction = try extractNCM(inputURL: inputURL, outputURL: tempAudioURL)
        guard extraction.sourceFormat != "unknown" else {
            throw NCMConversionError.output("解密后的音频头无法识别，已停止输出，避免生成无法播放的文件")
        }

        let stem = outputStem(
            inputURL: inputURL, metadata: extraction.metadata, renameByMetadata: options.renameByMetadata)
        let coverURL = try writeCoverFile(extraction.coverData, to: tempDirectory)
        let context = ConversionContext(
            inputURL: inputURL,
            extraction: extraction,
            stem: stem,
            options: options,
            tempAudioURL: tempAudioURL,
            coverURL: coverURL
        )

        if options.outputMode == .original {
            return try exportOriginal(context)
        }
        if extraction.sourceFormat == "mp3" {
            return try exportDirectMP3(context)
        }
        if let ffmpeg = cachedFFmpegPath {
            return try exportTranscoded(context, ffmpegPath: ffmpeg)
        }
        return try exportFallback(context)
    }

    static func extractNCM(inputURL: URL, outputURL: URL) throws -> ExtractionResult {
        let reader = try BinaryReader(url: inputURL)
        let fileSize = try FileManager.default.attributesOfItem(atPath: inputURL.path)[.size] as? UInt64 ?? 0
        let header = try readHeader(reader: reader, fileSize: fileSize)

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        var offset = 0
        var firstBytes = Data()

        while let chunk = try reader.readChunk(maxLength: chunkSize), !chunk.isEmpty {
            var bytes = [UInt8](chunk)
            for index in bytes.indices {
                let position = offset + index
                let j = (position + 1) & 0xFF
                let first = Int(header.keyBox[j])
                let secondIndex = (first + j) & 0xFF
                let maskIndex = (first + Int(header.keyBox[secondIndex])) & 0xFF
                bytes[index] ^= header.keyBox[maskIndex]
            }

            if firstBytes.isEmpty {
                firstBytes = Data(bytes.prefix(64))
            }
            try outputHandle.write(contentsOf: Data(bytes))
            offset += bytes.count
        }

        return ExtractionResult(
            metadata: header.metadata,
            sourceFormat: sniffAudioFormat(firstBytes: firstBytes, metadata: header.metadata),
            coverData: header.coverData
        )
    }

    static func readHeader(reader: BinaryReader, fileSize: UInt64) throws -> ParsedHeader {
        guard try reader.read(count: 8) == magic else {
            throw NCMConversionError.invalidNCM
        }
        _ = try reader.read(count: 2)

        let keyLength = Int(try reader.readUInt32LE())
        let encryptedKey = xor(data: try reader.read(count: keyLength), value: 0x64)
        let decryptedKey = try aes128ECBDecrypt(encryptedKey, key: coreKey)
        guard decryptedKey.count > 17 else {
            throw NCMConversionError.crypto("NCM 音频密钥异常")
        }
        let keyData = Data(decryptedKey.dropFirst(17))
        let keyBox = try buildKeyBox(keyData: keyData)

        let metadataLength = Int(try reader.readUInt32LE())
        let encryptedMetadata = xor(data: try reader.read(count: metadataLength), value: 0x63)
        let metadata = try parseMetadata(encryptedMetadata)

        let coverData = try readCoverArea(reader: reader, fileSize: fileSize)

        return ParsedHeader(keyBox: keyBox, metadata: metadata, coverData: coverData)
    }

    static func aes128ECBDecrypt(_ data: Data, key: Data) throws -> Data {
        guard FileManager.default.fileExists(atPath: opensslPath) else {
            throw NCMConversionError.crypto("找不到系统 openssl，无法解密 NCM 头部")
        }
        guard data.count % 16 == 0 else {
            throw NCMConversionError.crypto("AES 数据长度异常")
        }
        let result = try ProcessRunner.run(
            opensslPath,
            arguments: ["enc", "-d", "-aes-128-ecb", "-K", key.hexString, "-nosalt", "-nopad"],
            input: data
        )
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8) ?? "\(result.status)"
            throw NCMConversionError.crypto(
                "openssl AES 解密失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try pkcs7Unpad(result.stdout)
    }

    static func aes128ECBEncryptPKCS7(_ data: Data, key: Data) throws -> Data {
        let result = try ProcessRunner.run(
            opensslPath,
            arguments: ["enc", "-e", "-aes-128-ecb", "-K", key.hexString, "-nosalt"],
            input: data
        )
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8) ?? "\(result.status)"
            throw NCMConversionError.crypto(
                "openssl AES 加密失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.stdout
    }

    static func pkcs7Unpad(_ data: Data) throws -> Data {
        guard let last = data.last else {
            throw NCMConversionError.crypto("AES 解密结果为空")
        }
        let pad = Int(last)
        guard pad >= 1, pad <= 16, data.count >= pad else {
            throw NCMConversionError.crypto("AES 填充校验失败，文件可能不是有效 NCM")
        }
        let suffix = data.suffix(pad)
        guard suffix.allSatisfy({ $0 == last }) else {
            throw NCMConversionError.crypto("AES 填充校验失败，文件可能不是有效 NCM")
        }
        return Data(data.dropLast(pad))
    }

    static func parseMetadata(_ raw: Data) throws -> [String: Any] {
        do {
            guard raw.count > 22 else {
                throw NCMConversionError.metadata("歌曲信息字段过短")
            }
            let base64Payload = Data(raw.dropFirst(22))
            guard let decoded = Data(base64Encoded: base64Payload) else {
                throw NCMConversionError.metadata("歌曲信息 Base64 解码失败")
            }
            let plain = try aes128ECBDecrypt(decoded, key: metaKey)
            var text = String(data: plain, encoding: .utf8) ?? ""
            if text.hasPrefix("music:") {
                text.removeFirst(6)
            }
            guard let jsonData = text.data(using: .utf8),
                let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            else {
                throw NCMConversionError.metadata("歌曲信息 JSON 解析失败")
            }
            return object
        } catch let error as NCMConversionError {
            throw error
        } catch {
            throw NCMConversionError.metadata("无法解析歌曲信息：\(error.localizedDescription)")
        }
    }

    static func buildKeyBox(keyData: Data) throws -> [UInt8] {
        let key = [UInt8](keyData)
        guard !key.isEmpty else {
            throw NCMConversionError.crypto("NCM 音频密钥为空")
        }

        var box = Array(UInt8.min...UInt8.max)
        var c = 0
        var lastByte = 0
        var keyOffset = 0

        for i in 0..<256 {
            let swap = box[i]
            c = (Int(swap) + lastByte + Int(key[keyOffset])) & 0xFF
            keyOffset += 1
            if keyOffset >= key.count {
                keyOffset = 0
            }
            box[i] = box[c]
            box[c] = swap
            lastByte = c
        }
        return box
    }

    static func xor(data: Data, value: UInt8) -> Data {
        Data(data.map { $0 ^ value })
    }

    static func sniffAudioFormat(firstBytes: Data, metadata: [String: Any]) -> String {
        let bytes = [UInt8](firstBytes)
        if firstBytes.starts(withASCII: "ID3") {
            return "mp3"
        }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 {
            return "mp3"
        }
        if firstBytes.starts(withASCII: "fLaC") {
            return "flac"
        }
        if firstBytes.starts(withASCII: "OggS") {
            return "ogg"
        }
        if bytes.count >= 12,
            Data(bytes[0..<4]).starts(withASCII: "RIFF"),
            Data(bytes[8..<12]).starts(withASCII: "WAVE")
        {
            return "wav"
        }
        return "unknown"
    }

    static func encryptAudioForTest(_ audio: Data, keyBox: [UInt8]) -> Data {
        var bytes = [UInt8](audio)
        for index in bytes.indices {
            let j = (index + 1) & 0xFF
            let first = Int(keyBox[j])
            let secondIndex = (first + j) & 0xFF
            let maskIndex = (first + Int(keyBox[secondIndex])) & 0xFF
            bytes[index] ^= keyBox[maskIndex]
        }
        return Data(bytes)
    }
}
