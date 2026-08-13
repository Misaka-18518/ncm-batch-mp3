import Foundation
import SwiftUI

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
struct UpdatePrompt: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let downloadURL: URL?
}

private struct LatestRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

enum ReleaseUpdateChecker {
    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/enshuwu46-png/ncm-batch-mp3/releases/latest")!
    private static let expectedReleasePrefix = "/enshuwu46-png/ncm-batch-mp3/releases/tag/"

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
        let normalized =
            version
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
