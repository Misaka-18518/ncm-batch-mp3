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

struct UpdatePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let downloadURL: URL?
}

enum ReleaseUpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/enshuwu46-png/ncm-batch-mp3/releases/latest")!
    private static let expectedReleasePrefix = "/enshuwu46-png/ncm-batch-mp3/releases/tag/"

    private struct LatestRelease: Decodable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static func fetchUpdate(currentVersion: String) async throws -> UpdatePrompt? {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NCM-Batch-MP3", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 7

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        guard isNewerVersion(release.tagName, than: currentVersion) else {
            return nil
        }
        guard isOfficialReleaseURL(release.htmlURL, tagName: release.tagName) else {
            throw URLError(.badURL)
        }

        return UpdatePrompt(
            title: "发现新版本",
            message: "NCM 批量转 MP3 \(release.tagName) 已发布。前往 GitHub Release 下载最新版。",
            downloadURL: release.htmlURL
        )
    }

    static func isNewerVersion(_ latest: String, than current: String) -> Bool {
        guard let latestParts = versionParts(latest), let currentParts = versionParts(current) else {
            return false
        }

        for index in 0..<max(latestParts.count, currentParts.count) {
            let newest = index < latestParts.count ? latestParts[index] : 0
            let installed = index < currentParts.count ? currentParts[index] : 0
            if newest != installed {
                return newest > installed
            }
        }
        return false
    }

    private static func versionParts(_ version: String) -> [Int]? {
        let normalized = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.anchored, .caseInsensitive])
            .split(whereSeparator: { $0 == "-" || $0 == "+" })
            .first
            .map(String.init) ?? ""
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return parts.compactMap { Int($0) }
    }

    private static func isOfficialReleaseURL(_ url: URL, tagName: String) -> Bool {
        guard let encodedTagName = tagName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return false
        }
        return url.scheme == "https"
            && url.host == "github.com"
            && url.path == expectedReleasePrefix + encodedTagName
    }
}

enum EricEvaEasterEgg {
    static func daysTogether(on date: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 30)) else {
            return 0
        }
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: start),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    static func message(on date: Date = Date()) -> String {
        "谨以此app，纪念Eric与Eva认识\(daysTogether(on: date))天！"
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
    @Published var updatePrompt: UpdatePrompt?
    @Published var isEasterEggPresented = false

    private var currentToken: CancellationToken?
    private var updateCheckInProgress = false
    private var automaticUpdateCheckFinished = false

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

    var queuedCount: Int {
        items.filter { $0.status == .queued }.count
    }

    var runningCount: Int {
        items.filter { $0.status == .running }.count
    }

    var finishedCount: Int {
        items.filter { $0.status == .finished }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }

    var easterEggMessage: String {
        EricEvaEasterEgg.message()
    }

    func checkForUpdates(manual: Bool = false) {
        guard !updateCheckInProgress, manual || !automaticUpdateCheckFinished else { return }
        if !manual {
            automaticUpdateCheckFinished = true
        }
        updateCheckInProgress = true
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

        Task { [weak self] in
            do {
                let prompt = try await ReleaseUpdateChecker.fetchUpdate(currentVersion: currentVersion)
                guard let self else { return }
                self.updateCheckInProgress = false
                if let prompt {
                    self.updatePrompt = prompt
                } else if manual {
                    self.updatePrompt = UpdatePrompt(title: "检查更新", message: "当前已是最新版本。", downloadURL: nil)
                }
            } catch {
                guard let self else { return }
                self.updateCheckInProgress = false
                if manual {
                    self.updatePrompt = UpdatePrompt(title: "检查更新失败", message: "暂时无法检查更新，请稍后再试。", downloadURL: nil)
                }
            }
        }
    }

    func dismissUpdatePrompt() {
        updatePrompt = nil
    }

    func openUpdateDownload() {
        guard let url = updatePrompt?.downloadURL else { return }
        NSWorkspace.shared.open(url)
        dismissUpdatePrompt()
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

enum GlassTheme {
    static let radius: CGFloat = 24
}

extension View {
    @ViewBuilder
    func liquidPanel(cornerRadius: CGFloat = GlassTheme.radius, interactive: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self
                .glassEffect(.regular.interactive(interactive), in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.24), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.10), radius: 18, x: 0, y: 10)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 10)
        }
    }

    @ViewBuilder
    func liquidButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

struct LiquidBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: backgroundColors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(colorScheme == .dark ? 0.48 : 0.74)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.18))
                    .frame(height: 92)
                Spacer()
                Rectangle()
                    .fill(Color.black.opacity(colorScheme == .dark ? 0.20 : 0.04))
                    .frame(height: 1)
            }

            GeometryReader { proxy in
                Path { path in
                    let width = proxy.size.width
                    let height = proxy.size.height
                    path.move(to: CGPoint(x: 0, y: height * 0.18))
                    path.addCurve(
                        to: CGPoint(x: width, y: height * 0.12),
                        control1: CGPoint(x: width * 0.32, y: height * 0.02),
                        control2: CGPoint(x: width * 0.70, y: height * 0.30)
                    )
                    path.addLine(to: CGPoint(x: width, y: height * 0.18))
                    path.addCurve(
                        to: CGPoint(x: 0, y: height * 0.24),
                        control1: CGPoint(x: width * 0.66, y: height * 0.36),
                        control2: CGPoint(x: width * 0.30, y: height * 0.08)
                    )
                    path.closeSubpath()
                }
                .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.23))
            }
        }
        .ignoresSafeArea()
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.08, green: 0.12, blue: 0.16),
                Color(red: 0.05, green: 0.20, blue: 0.22),
                Color(red: 0.16, green: 0.13, blue: 0.19),
                Color(red: 0.07, green: 0.08, blue: 0.10)
            ]
        }
        return [
            Color(red: 0.93, green: 0.98, blue: 1.00),
            Color(red: 0.92, green: 0.96, blue: 0.91),
            Color(red: 0.99, green: 0.95, blue: 0.89),
            Color(red: 0.96, green: 0.97, blue: 1.00)
        ]
    }
}

struct AppMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.78),
                            Color.teal.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .stroke(.white.opacity(0.34), lineWidth: 1)
                }

            Circle()
                .fill(Color.white.opacity(0.74))
                .frame(width: size * 0.58, height: size * 0.58)
                .overlay {
                    Circle()
                        .stroke(Color.cyan.opacity(0.30), lineWidth: size * 0.035)
                }

            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(Color(red: 0.05, green: 0.18, blue: 0.22))
                .offset(x: -size * 0.02, y: -size * 0.02)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: size * 0.20, weight: .bold))
                .foregroundStyle(.white)
                .padding(size * 0.09)
                .background(Color.teal, in: Circle())
                .offset(x: size * 0.28, y: size * 0.27)
        }
        .frame(width: size, height: size)
    }
}

struct StatusPill: View {
    let title: String
    let value: String
    let systemImage: String
    var color: Color = .accentColor

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct SectionTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline.weight(.semibold))
            .foregroundStyle(.primary)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            LiquidBackground()

            VStack(spacing: 14) {
                header
                actionBar
                mainContent
                footer
            }
            .padding(18)
        }
        .frame(minWidth: 1020, minHeight: 700)
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .overlay {
            if model.isDropTargeted {
                dropOverlay
            }
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                model.isEasterEggPresented = true
            } label: {
                Circle()
                    .fill(.black)
                    .frame(width: 7, height: 7)
            }
            .buttonStyle(.plain)
            .padding(10)
            .accessibilityHidden(true)
        }
        .overlay {
            if model.isEasterEggPresented {
                easterEggOverlay
            }
        }
        .task {
            model.checkForUpdates()
        }
        .alert(model.updatePrompt?.title ?? "", isPresented: Binding(
            get: { model.updatePrompt != nil },
            set: { presented in
                if !presented {
                    model.dismissUpdatePrompt()
                }
            }
        )) {
            if model.updatePrompt?.downloadURL != nil {
                Button("前往下载") {
                    model.openUpdateDownload()
                }
            }
            Button(model.updatePrompt?.downloadURL == nil ? "好" : "稍后", role: .cancel) {
                model.dismissUpdatePrompt()
            }
        } message: {
            Text(model.updatePrompt?.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            AppMark(size: 68)

            VStack(alignment: .leading, spacing: 6) {
                Text("NCM 批量转 MP3")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("批量解开网易云 NCM，自动识别 MP3 / FLAC，并用内置 ffmpeg 转成可播放 MP3。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 16)

            Button {
                model.checkForUpdates(manual: true)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .liquidButton()
            .help("检查更新")

            StatusPill(title: "队列", value: "\(model.items.count)", systemImage: "tray.full", color: .blue)
            StatusPill(title: "完成", value: "\(model.finishedCount)", systemImage: "checkmark.circle.fill", color: .green)
            StatusPill(
                title: "ffmpeg",
                value: model.ffmpegStatusText.contains("未") ? "缺失" : "可用",
                systemImage: model.ffmpegStatusText.contains("未") ? "exclamationmark.triangle.fill" : "waveform.circle.fill",
                color: model.ffmpegStatusText.contains("未") ? .orange : .teal
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button(action: model.chooseFiles) {
                Label("添加文件", systemImage: "plus")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .help("添加 .ncm 文件")

            Button(action: model.chooseFolder) {
                Label("添加文件夹", systemImage: "folder.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .help("扫描文件夹里的 .ncm 文件")

            Button(action: model.removeSelected) {
                Label("移除", systemImage: "minus")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .disabled(model.selection.isEmpty || model.isConverting)
            .help("移除选中的文件")

            Button(action: model.clearQueue) {
                Label("清空", systemImage: "trash")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .disabled(model.items.isEmpty || model.isConverting)
            .help("清空列表")

            Spacer()

            Button(action: model.openOutputDirectory) {
                Label("输出目录", systemImage: "folder")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .help("在 Finder 中打开输出目录")

            if model.isConverting {
                Button(action: model.cancelConversion) {
                    Label("取消", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .liquidButton(prominent: true)
            } else {
                Button(action: model.startConversion) {
                    Label("开始转换", systemImage: "play.fill")
                        .labelStyle(.titleAndIcon)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .liquidButton(prominent: true)
                .disabled(model.items.isEmpty)
            }
        }
        .controlSize(.large)
        .padding(12)
        .liquidPanel(cornerRadius: 24)
    }

    private var mainContent: some View {
        HStack(spacing: 14) {
            queuePanel
                .frame(minWidth: 580, maxWidth: .infinity, maxHeight: .infinity)
            inspectorPanel
                .frame(width: 370)
                .frame(maxHeight: .infinity)
        }
    }

    private var queuePanel: some View {
        VStack(spacing: 12) {
            HStack {
                SectionTitle(title: "转换队列", systemImage: "music.note.list")
                Spacer()
                Text("\(model.queuedCount) 等待 / \(model.runningCount) 运行 / \(model.failedCount) 失败")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if model.items.isEmpty {
                EmptyQueueView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.items) { item in
                        QueueRow(item: item)
                            .tag(item.id)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(14)
        .liquidPanel(cornerRadius: 26)
    }

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(title: "输出", systemImage: "square.and.arrow.down")
                HStack(spacing: 8) {
                    TextField("输出目录", text: Binding(
                        get: { model.outputDirectory.path },
                        set: { model.outputDirectory = URL(fileURLWithPath: $0, isDirectory: true) }
                    ))
                    .textFieldStyle(.roundedBorder)

                    Button(action: model.chooseOutputDirectory) {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .liquidButton()
                    .help("选择输出目录")
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(title: "转换偏好", systemImage: "slider.horizontal.3")
                Picker("格式", selection: $model.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("用歌曲信息命名", isOn: $model.renameByMetadata)
                Toggle("覆盖同名文件", isOn: $model.overwriteExisting)
                Toggle("递归扫描文件夹", isOn: $model.recursiveFolderSearch)
            }

            Divider()

            SectionTitle(title: "日志", systemImage: "text.alignleft")
            LogView(lines: model.logLines)
        }
        .padding(14)
        .liquidPanel(cornerRadius: 26)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ProgressView(value: model.progressFraction)
                .tint(.teal)
                .frame(maxWidth: .infinity)

            Text("\(model.completedCount)/\(model.items.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var dropOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.teal)
            Text("松开即可添加 NCM 文件")
                .font(.headline)
            Text("支持文件夹拖入与递归扫描")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 42)
        .padding(.vertical, 30)
        .liquidPanel(cornerRadius: 28, interactive: true)
    }

    private var easterEggOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture {
                    model.isEasterEggPresented = false
                }

            VStack(spacing: 10) {
                Text(model.easterEggMessage)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("我们是永远的最好的朋友！")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 38)
            .padding(.vertical, 30)
            .frame(maxWidth: 440)
            .liquidPanel(cornerRadius: 16)
            .overlay(alignment: .topTrailing) {
                Button {
                    model.isEasterEggPresented = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .padding(7)
            }
        }
        .transition(.opacity)
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

struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.thinMaterial)
                    .frame(width: 112, height: 112)
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.teal)
            }
            .liquidPanel(cornerRadius: 26)

            Text("拖入 .ncm 文件或文件夹")
                .font(.title3.weight(.semibold))
            Text("也可以用上方按钮添加，队列会自动去重。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QueueRow: View {
    let item: QueueItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.status.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(item.status.color)
                .frame(width: 26, height: 26)
                .background(item.status.color.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .font(.callout.weight(.medium))
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
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 230, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if lines.isEmpty {
                        Text("等待转换任务...")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.62), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .onChange(of: lines.count) { _, count in
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day894 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12))!
        guard EricEvaEasterEgg.daysTogether(on: day894, calendar: calendar) == 894 else {
            throw NCMConversionError.output("彩蛋计时器日期计算异常")
        }
        guard ReleaseUpdateChecker.isNewerVersion("v1.1.2", than: "1.1.1"),
              !ReleaseUpdateChecker.isNewerVersion("1.1.2", than: "1.1.2") else {
            throw NCMConversionError.output("版本比较异常")
        }

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
