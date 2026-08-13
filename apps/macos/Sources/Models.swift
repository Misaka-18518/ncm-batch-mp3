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
