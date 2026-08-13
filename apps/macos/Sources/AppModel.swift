import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
        NCMConverterCore.cachedFFmpegPath == nil ? "未检测到 ffmpeg" : "ffmpeg 可用"
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
        guard !isConverting else {
            appendLog("转换进行中，暂时不能添加文件")
            return
        }
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
                    if let enumerator = fileManager.enumerator(
                        at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                    {
                        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "ncm" {
                            result.append(fileURL)
                        }
                    }
                } else {
                    let children =
                        (try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
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
        if NCMConverterCore.cachedFFmpegPath == nil {
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
