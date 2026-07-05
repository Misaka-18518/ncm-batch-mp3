import AppKit
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    case preferMP3
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preferMP3: return "优先 MP3"
        case .original: return "原始格式"
        }
    }
}

enum ConversionStatus: String, Sendable {
    case queued
    case running
    case finished
    case failed

    var title: String {
        switch self {
        case .queued: return "等待"
        case .running: return "转换中"
        case .finished: return "完成"
        case .failed: return "失败"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .finished: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .queued: return .secondary
        case .running: return .blue
        case .finished: return .green
        case .failed: return .red
        }
    }
}

struct QueueItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    var status: ConversionStatus
    var outputURL: URL?
    var detail: String

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.status = .queued
        self.outputURL = nil
        self.detail = ""
    }
}

struct ConversionOptions: Sendable {
    let outputDirectory: URL
    let outputMode: OutputMode
    let renameByMetadata: Bool
    let overwriteExisting: Bool
}

struct ConversionResult: Sendable {
    let inputURL: URL
    let outputURL: URL
    let sourceFormat: String
    let transcoded: Bool
    let message: String
}

enum NCMConversionError: LocalizedError {
    case invalidNCM
    case incompleteFile(String)
    case crypto(String)
    case metadata(String)
    case output(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .invalidNCM:
            return "不是有效的 .ncm 文件"
        case .incompleteFile(let message),
             .crypto(let message),
             .metadata(let message),
             .output(let message),
             .process(let message):
            return message
        }
    }
}

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

        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(stdout: stdout, stderr: stderr, status: process.terminationStatus)
    }
}

extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
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

    struct ParsedHeader {
        let keyBox: [UInt8]
        let metadata: [String: Any]
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
        if extraction.sourceFormat == "unknown" {
            throw NCMConversionError.output("解密后的音频头无法识别，已停止输出，避免生成无法播放的文件")
        }
        let stem = outputStem(inputURL: inputURL, metadata: extraction.metadata, renameByMetadata: options.renameByMetadata)

        if options.outputMode == .original {
            let target = try uniqueURL(options.outputDirectory.appendingPathComponent(stem).appendingPathExtension(extraction.sourceFormat), overwrite: options.overwriteExisting)
            try moveReplacingIfNeeded(from: tempAudioURL, to: target, overwrite: options.overwriteExisting)
            return ConversionResult(inputURL: inputURL, outputURL: target, sourceFormat: extraction.sourceFormat, transcoded: false, message: "已导出原始音频")
        }

        if extraction.sourceFormat == "mp3" {
            let target = try uniqueURL(options.outputDirectory.appendingPathComponent(stem).appendingPathExtension("mp3"), overwrite: options.overwriteExisting)
            try moveReplacingIfNeeded(from: tempAudioURL, to: target, overwrite: options.overwriteExisting)
            return ConversionResult(inputURL: inputURL, outputURL: target, sourceFormat: "mp3", transcoded: false, message: "已转换为 MP3")
        }

        if let ffmpeg = findFFmpeg() {
            let target = try uniqueURL(options.outputDirectory.appendingPathComponent(stem).appendingPathExtension("mp3"), overwrite: options.overwriteExisting)
            try transcodeToMP3(inputURL: tempAudioURL, outputURL: target, ffmpegPath: ffmpeg)
            return ConversionResult(inputURL: inputURL, outputURL: target, sourceFormat: extraction.sourceFormat, transcoded: true, message: "已从 \(extraction.sourceFormat.uppercased()) 转码为 MP3")
        }

        let target = try uniqueURL(options.outputDirectory.appendingPathComponent(stem).appendingPathExtension(extraction.sourceFormat), overwrite: options.overwriteExisting)
        try moveReplacingIfNeeded(from: tempAudioURL, to: target, overwrite: options.overwriteExisting)
        return ConversionResult(
            inputURL: inputURL,
            outputURL: target,
            sourceFormat: extraction.sourceFormat,
            transcoded: false,
            message: "源音频是 \(extraction.sourceFormat.uppercased())；未检测到 ffmpeg，已导出原始音频"
        )
    }

    static func extractNCM(inputURL: URL, outputURL: URL) throws -> (metadata: [String: Any], sourceFormat: String) {
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

        return (header.metadata, sniffAudioFormat(firstBytes: firstBytes, metadata: header.metadata))
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

        try skipCoverArea(reader: reader, fileSize: fileSize)

        return ParsedHeader(keyBox: keyBox, metadata: metadata)
    }

    static func skipCoverArea(reader: BinaryReader, fileSize: UInt64) throws {
        let start = try reader.offset()

        do {
            try reader.seekForward(5)
            let coverFrameLength = UInt64(try reader.readUInt32LE())
            let imageLength = UInt64(try reader.readUInt32LE())
            let payloadStart = try reader.offset()

            guard imageLength <= coverFrameLength,
                  payloadStart + coverFrameLength <= fileSize else {
                throw NCMConversionError.incompleteFile("封面长度字段异常，无法定位音频数据")
            }

            try reader.seek(to: payloadStart + coverFrameLength)
        } catch {
            try reader.seek(to: start)
            _ = try reader.read(count: 4)
            _ = try reader.read(count: 5)
            let imageLength = UInt64(try reader.readUInt32LE())
            let payloadStart = try reader.offset()
            guard payloadStart + imageLength <= fileSize else {
                throw NCMConversionError.incompleteFile("封面长度字段异常，无法定位音频数据")
            }
            try reader.seek(to: payloadStart + imageLength)
        }
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
            throw NCMConversionError.crypto("openssl AES 解密失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
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
            throw NCMConversionError.crypto("openssl AES 加密失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
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
                  let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
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
           Data(bytes[8..<12]).starts(withASCII: "WAVE") {
            return "wav"
        }
        return "unknown"
    }

    static func outputStem(inputURL: URL, metadata: [String: Any], renameByMetadata: Bool) -> String {
        guard renameByMetadata else {
            return safeFilename(inputURL.deletingPathExtension().lastPathComponent)
        }

        let title = (metadata["musicName"] as? String)
            ?? (metadata["name"] as? String)
            ?? inputURL.deletingPathExtension().lastPathComponent
        let artists = artistNames(from: metadata)
        if artists.isEmpty {
            return safeFilename(title)
        }
        return safeFilename("\(artists) - \(title)")
    }

    static func artistNames(from metadata: [String: Any]) -> String {
        let raw = metadata["artist"] ?? metadata["artists"]
        var names: [String] = []

        if let arrays = raw as? [[Any]] {
            for item in arrays {
                if let first = item.first as? String, !first.isEmpty {
                    names.append(first)
                }
            }
        } else if let dictionaries = raw as? [[String: Any]] {
            for item in dictionaries {
                if let name = item["name"] as? String, !name.isEmpty {
                    names.append(name)
                }
            }
        } else if let strings = raw as? [String] {
            names.append(contentsOf: strings.filter { !$0.isEmpty })
        }

        return names.joined(separator: "、")
    }

    static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let parts = name.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        let cleaned = String(parts).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if cleaned.isEmpty {
            return "converted"
        }
        return String(cleaned.prefix(180))
    }

    static func uniqueURL(_ desired: URL, overwrite: Bool) throws -> URL {
        if overwrite || !FileManager.default.fileExists(atPath: desired.path) {
            return desired
        }

        let directory = desired.deletingLastPathComponent()
        let base = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension

        for index in 1..<10000 {
            let candidate = directory.appendingPathComponent("\(base) (\(index))").appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw NCMConversionError.output("输出目录里重名文件太多：\(desired.lastPathComponent)")
    }

    static func moveReplacingIfNeeded(from source: URL, to target: URL, overwrite: Bool) throws {
        if overwrite, FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: source, to: target)
    }

    static func findFFmpeg() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let result = try? ProcessRunner.run("/usr/bin/which", arguments: ["ffmpeg"])
        guard let result, result.status == 0 else {
            return nil
        }
        let path = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func transcodeToMP3(inputURL: URL, outputURL: URL, ffmpegPath: String) throws {
        let result = try ProcessRunner.run(
            ffmpegPath,
            arguments: [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", inputURL.path,
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                outputURL.path
            ]
        )
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8) ?? "\(result.status)"
            throw NCMConversionError.process("ffmpeg 转 MP3 失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
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

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelledValue = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledValue
    }

    func cancel() {
        lock.lock()
        cancelledValue = true
        lock.unlock()
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [QueueItem] = []
    @Published var selection: Set<UUID> = []
    @Published var outputDirectory: URL
    @Published var outputMode: OutputMode = .preferMP3
    @Published var renameByMetadata = true
    @Published var overwriteExisting = false
    @Published var recursiveFolderSearch = true
    @Published var isConverting = false
    @Published var completedCount = 0
    @Published var logLines: [String] = []
    @Published var isDropTargeted = false

    private var currentToken: CancellationToken?

    init() {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        self.outputDirectory = (music ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("NCM 转换输出", isDirectory: true)
    }

    var progressFraction: Double {
        guard !items.isEmpty else { return 0 }
        return Double(completedCount) / Double(items.count)
    }

    var ffmpegStatusText: String {
        NCMConverterCore.findFFmpeg() == nil ? "未检测到 ffmpeg" : "ffmpeg 可用"
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择 NCM 文件"
        panel.allowedContentTypes = [UTType(filenameExtension: "ncm") ?? .data]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择包含 NCM 的文件夹"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择输出目录"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
        }
    }

    func addURLs(_ urls: [URL]) {
        let discovered = collectNCMFiles(from: urls)
        let existing = Set(items.map { $0.url.standardizedFileURL })
        var added = 0
        for url in discovered {
            let normalized = url.standardizedFileURL
            if !existing.contains(normalized), !items.contains(where: { $0.url.standardizedFileURL == normalized }) {
                items.append(QueueItem(url: normalized))
                added += 1
            }
        }
        if added > 0 {
            appendLog("已添加 \(added) 个文件")
        }
    }

    func collectNCMFiles(from urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                if recursiveFolderSearch {
                    if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "ncm" {
                            result.append(fileURL)
                        }
                    }
                } else {
                    let children = (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                    result.append(contentsOf: children.filter { $0.pathExtension.lowercased() == "ncm" })
                }
            } else if url.pathExtension.lowercased() == "ncm" {
                result.append(url)
            }
        }

        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func removeSelected() {
        guard !selection.isEmpty else { return }
        items.removeAll { selection.contains($0.id) }
        selection.removeAll()
    }

    func clearQueue() {
        items.removeAll()
        selection.removeAll()
        completedCount = 0
        logLines.removeAll()
    }

    func openOutputDirectory() {
        NSWorkspace.shared.open(outputDirectory)
    }

    func cancelConversion() {
        currentToken?.cancel()
        appendLog("正在取消，当前文件处理完后停止")
    }

    func startConversion() {
        guard !items.isEmpty, !isConverting else { return }

        isConverting = true
        completedCount = 0
        currentToken = CancellationToken()
        let token = currentToken!
        let files = items.map(\.url)
        let options = ConversionOptions(
            outputDirectory: outputDirectory,
            outputMode: outputMode,
            renameByMetadata: renameByMetadata,
            overwriteExisting: overwriteExisting
        )

        for index in items.indices {
            items[index].status = .queued
            items[index].detail = ""
            items[index].outputURL = nil
        }

        appendLog("开始转换 \(files.count) 个文件")
        if NCMConverterCore.findFFmpeg() == nil {
            appendLog("未检测到 ffmpeg；FLAC 源会导出为 FLAC")
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self, files, options, token] in
            var ok = 0
            var failed = 0

            for (index, file) in files.enumerated() {
                if token.isCancelled {
                    break
                }

                DispatchQueue.main.async {
                    self?.markRunning(url: file, index: index, total: files.count)
                }

                do {
                    let result = try NCMConverterCore.convertOne(inputURL: file, options: options)
                    ok += 1
                    DispatchQueue.main.async {
                        self?.markFinished(result: result, completed: index + 1)
                    }
                } catch {
                    failed += 1
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        self?.markFailed(url: file, message: message, completed: index + 1)
                    }
                }
            }

            DispatchQueue.main.async {
                self?.finishConversion(ok: ok, failed: failed, cancelled: token.isCancelled)
            }
        }
    }

    func markRunning(url: URL, index: Int, total: Int) {
        if let itemIndex = items.firstIndex(where: { $0.url == url }) {
            items[itemIndex].status = .running
            items[itemIndex].detail = "\(index + 1)/\(total)"
        }
        appendLog("[\(index + 1)/\(total)] \(url.lastPathComponent)")
    }

    func markFinished(result: ConversionResult, completed: Int) {
        completedCount = completed
        if let itemIndex = items.firstIndex(where: { $0.url == result.inputURL }) {
            items[itemIndex].status = .finished
            items[itemIndex].outputURL = result.outputURL
            items[itemIndex].detail = result.message
        }
        appendLog("  OK -> \(result.outputURL.lastPathComponent)  \(result.message)")
    }

    func markFailed(url: URL, message: String, completed: Int) {
        completedCount = completed
        if let itemIndex = items.firstIndex(where: { $0.url == url }) {
            items[itemIndex].status = .failed
            items[itemIndex].detail = message
        }
        appendLog("  失败：\(message)")
    }

    func finishConversion(ok: Int, failed: Int, cancelled: Bool) {
        isConverting = false
        currentToken = nil
        if cancelled {
            appendLog("已取消：成功 \(ok)，失败 \(failed)")
        } else {
            appendLog("完成：成功 \(ok)，失败 \(failed)")
        }
    }

    func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("[\(formatter.string(from: Date()))] \(line)")
        if logLines.count > 1000 {
            logLines.removeFirst(logLines.count - 1000)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            mainContent
            Divider()
            footer
        }
        .frame(minWidth: 920, minHeight: 620)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("NCM 批量转 MP3", systemImage: "music.note.list")
                .font(.title3.weight(.semibold))
            Spacer()
            Label(model.ffmpegStatusText, systemImage: model.ffmpegStatusText.contains("未") ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.callout)
                .foregroundStyle(model.ffmpegStatusText.contains("未") ? .orange : .green)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: model.chooseFiles) {
                Label("添加文件", systemImage: "plus")
            }
            .help("添加 .ncm 文件")

            Button(action: model.chooseFolder) {
                Label("添加文件夹", systemImage: "folder.badge.plus")
            }
            .help("扫描文件夹里的 .ncm 文件")

            Button(action: model.removeSelected) {
                Label("移除", systemImage: "minus")
            }
            .disabled(model.selection.isEmpty || model.isConverting)
            .help("移除选中的文件")

            Button(action: model.clearQueue) {
                Label("清空", systemImage: "trash")
            }
            .disabled(model.items.isEmpty || model.isConverting)
            .help("清空列表")

            Spacer()

            Button(action: model.openOutputDirectory) {
                Label("打开输出目录", systemImage: "folder")
            }
            .help("在 Finder 中打开输出目录")

            if model.isConverting {
                Button(action: model.cancelConversion) {
                    Label("取消", systemImage: "stop.fill")
                }
            } else {
                Button(action: model.startConversion) {
                    Label("开始转换", systemImage: "play.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.items.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mainContent: some View {
        HSplitView {
            queueList
                .frame(minWidth: 520)
            sidePanel
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 430)
        }
    }

    private var queueList: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 42))
                        .foregroundStyle(.secondary)
                    Text("拖入 .ncm 文件或文件夹")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        QueueRow(item: item)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("输出目录")
                    .font(.headline)
                HStack {
                    TextField("输出目录", text: Binding(
                        get: { model.outputDirectory.path },
                        set: { model.outputDirectory = URL(fileURLWithPath: $0, isDirectory: true) }
                    ))
                    Button(action: model.chooseOutputDirectory) {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .help("选择输出目录")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("格式")
                    .font(.headline)
                Picker("格式", selection: $model.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("用歌曲信息命名", isOn: $model.renameByMetadata)
                Toggle("覆盖同名文件", isOn: $model.overwriteExisting)
                Toggle("递归扫描文件夹", isOn: $model.recursiveFolderSearch)
            }

            Divider()

            Text("日志")
                .font(.headline)
            LogView(lines: model.logLines)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progressFraction)
                .frame(maxWidth: .infinity)
            Text("\(model.completedCount)/\(model.items.count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsurl = item as? NSURL {
                    url = nsurl as URL
                } else {
                    url = nil
                }

                if let url {
                    Task { @MainActor in
                        model.addURLs([url])
                    }
                }
            }
        }
        return accepted
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status.color)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                Text(item.outputURL?.path ?? item.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(item.detail.isEmpty ? item.status.title : item.detail)
                .font(.caption)
                .foregroundStyle(item.status == .failed ? .red : .secondary)
                .lineLimit(2)
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onChange(of: lines.count) { count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}

enum CommandLineMode {
    static func handleIfNeeded() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { return }

        if first == "--self-test" {
            do {
                try SelfTest.run()
                print("SwiftUI app self-test ok")
                exit(0)
            } catch {
                fputs("Self-test failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }

        if first == "--cli-convert" {
            exit(runCLI(arguments: Array(args.dropFirst())))
        }
    }

    static func runCLI(arguments: [String]) -> Int32 {
        var inputs: [URL] = []
        var outputDirectory = FileManager.default.currentDirectoryPath
        var mode: OutputMode = .preferMP3
        var rename = false
        var overwrite = false

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--output", "-o":
                index += 1
                guard index < arguments.count else {
                    fputs("missing output directory\n", stderr)
                    return 2
                }
                outputDirectory = arguments[index]
            case "--mode":
                index += 1
                guard index < arguments.count else {
                    fputs("missing mode\n", stderr)
                    return 2
                }
                mode = arguments[index] == "original" ? .original : .preferMP3
            case "--rename":
                rename = true
            case "--overwrite":
                overwrite = true
            default:
                inputs.append(URL(fileURLWithPath: arg))
            }
            index += 1
        }

        guard !inputs.isEmpty else {
            fputs("usage: NCMConverter --cli-convert file.ncm [...] --output outdir [--rename] [--overwrite]\n", stderr)
            return 2
        }

        let options = ConversionOptions(
            outputDirectory: URL(fileURLWithPath: outputDirectory, isDirectory: true),
            outputMode: mode,
            renameByMetadata: rename,
            overwriteExisting: overwrite
        )

        var failed = 0
        for input in inputs {
            do {
                let result = try NCMConverterCore.convertOne(inputURL: input, options: options)
                print("OK \(input.lastPathComponent) -> \(result.outputURL.lastPathComponent)")
            } catch {
                failed += 1
                fputs("ERR \(input.lastPathComponent): \(error.localizedDescription)\n", stderr)
            }
        }
        return failed == 0 ? 0 : 1
    }
}

enum SelfTest {
    static func run() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("ncm-swift-selftest-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let inputURL = tempDirectory.appendingPathComponent("sample.ncm")
        let outputDirectory = tempDirectory.appendingPathComponent("out", isDirectory: true)
        let expectedAudio = try buildSyntheticNCM(at: inputURL)
        let result = try NCMConverterCore.convertOne(
            inputURL: inputURL,
            options: ConversionOptions(
                outputDirectory: outputDirectory,
                outputMode: .preferMP3,
                renameByMetadata: true,
                overwriteExisting: false
            )
        )
        let actual = try Data(contentsOf: result.outputURL)
        guard actual == expectedAudio else {
            throw NCMConversionError.output("自测输出音频不一致")
        }
    }

    static func buildSyntheticNCM(at url: URL) throws -> Data {
        let keyData = Data("test-stream-key".utf8)
        let expectedKeyBoxPrefix: [UInt8] = [
            70, 218, 132, 64, 217, 166, 112, 195,
            68, 11, 211, 232, 95, 55, 88, 238,
            228, 34, 90, 131, 76, 19, 50, 174,
            108, 173, 40, 122, 251, 145, 35, 59
        ]
        let encryptedKeyPlain = Data("neteasecloudmusic".utf8) + keyData
        let encryptedKey = NCMConverterCore.xor(
            data: try NCMConverterCore.aes128ECBEncryptPKCS7(encryptedKeyPlain, key: NCMConverterCore.coreKey),
            value: 0x64
        )

        let metadata: [String: Any] = [
            "musicName": "Synthetic Track",
            "artist": [["Codex", 1]],
            "format": "mp3"
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        let metadataPlain = Data("music:".utf8) + metadataJSON
        let metadataCipher = try NCMConverterCore.aes128ECBEncryptPKCS7(metadataPlain, key: NCMConverterCore.metaKey)
        let metadataPayload = Data("163 key(Don't modify):".utf8)
            + Data(metadataCipher.base64EncodedString().utf8)
        let encryptedMetadata = NCMConverterCore.xor(data: metadataPayload, value: 0x63)

        var audio = Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10])
        for _ in 0..<64 {
            audio.append(Data("synthetic audio payload".utf8))
        }

        let keyBox = try NCMConverterCore.buildKeyBox(keyData: keyData)
        guard Array(keyBox.prefix(expectedKeyBoxPrefix.count)) == expectedKeyBoxPrefix else {
            throw NCMConversionError.crypto("自测 key-box 与 ncmdump 参考算法不一致")
        }
        let encryptedAudio = NCMConverterCore.encryptAudioForTest(audio, keyBox: keyBox)

        var blob = Data()
        blob.append(NCMConverterCore.magic)
        blob.append(Data([0x02, 0x00]))
        blob.appendUInt32LE(UInt32(encryptedKey.count))
        blob.append(encryptedKey)
        blob.appendUInt32LE(UInt32(encryptedMetadata.count))
        blob.append(encryptedMetadata)
        blob.append(Data([0x00, 0x00, 0x00, 0x00, 0x00]))
        blob.appendUInt32LE(0)
        blob.appendUInt32LE(0)
        blob.append(encryptedAudio)
        try blob.write(to: url)
        return audio
    }
}

@main
@MainActor
struct NCMBatchMP3App: App {
    @StateObject private var model: AppModel

    init() {
        CommandLineMode.handleIfNeeded()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    model.addURLs([url])
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("NCM") {
                Button("添加文件") { model.chooseFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("添加文件夹") { model.chooseFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("开始转换") { model.startConversion() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.items.isEmpty || model.isConverting)
            }
        }
    }
}
