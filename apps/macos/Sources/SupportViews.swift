import AppKit
import Foundation
import SwiftUI

private struct TutorialStep {
    let number: String
    let title: String
    let detail: String
}

struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [TutorialStep] = [
        TutorialStep(
            number: "1", title: "添加歌曲",
            detail: "点击“添加文件”选择多个 .ncm，或点击“添加文件夹”批量扫描；也可以直接把文件或文件夹拖进窗口。"),
        TutorialStep(
            number: "2", title: "设置输出目录",
            detail: "在右侧“输出”区域选择保存位置。转换完成后，可用工具栏的文件夹按钮直接在 Finder 中打开。"),
        TutorialStep(
            number: "3", title: "选择格式",
            detail: "“优先 MP3”会保留原本就是 MP3 的歌曲，并通过内置 ffmpeg 把 FLAC、OGG 或 WAV 转成 MP3；“原始格式”只解密，不转码。"),
        TutorialStep(
            number: "4", title: "调整命名",
            detail: "开启“用歌曲信息命名”后，将优先使用歌手和歌曲名；关闭后保留原 NCM 文件名。同名文件默认自动追加序号。"),
        TutorialStep(
            number: "5", title: "开始转换",
            detail: "确认队列后点击“开始转换”。每首歌曲的状态、总进度和详细记录会实时显示，转换期间可以取消。"),
        TutorialStep(
            number: "6", title: "查看结果",
            detail: "成功项目会显示输出文件位置。若解密后的音频头无法识别，程序会停止该文件，避免生成无法播放的伪 MP3。"),
        TutorialStep(
            number: "7", title: "获取更新",
            detail: "右上角循环箭头会检查 GitHub Release。启动时也会静默检查，只有发现新版本时才提示下载。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始使用")
                        .font(.title2.weight(.bold))
                    Text("NCM 批量转 MP3")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(22)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(steps, id: \.number) { step in
                        HStack(alignment: .top, spacing: 13) {
                            Text(step.number)
                                .font(.callout.weight(.bold))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.title)
                                    .font(.headline)
                                Text(step.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(22)
            }

            Divider()
            HStack {
                Spacer()
                Button("知道了") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .liquidButton(prominent: true)
            }
            .padding(16)
        }
        .frame(width: 600)
        .frame(minHeight: 570, idealHeight: 650)
    }
}

struct EmptyQueueView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.teal)
                .frame(width: 76, height: 76)

            Text("拖入 .ncm 文件或文件夹")
                .font(.title3.weight(.semibold))
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
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Text(item.detail.isEmpty ? item.status.title : item.detail)
                .font(.caption)
                .foregroundStyle(item.status == .failed ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    if lines.isEmpty {
                        Text("暂无日志")
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
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.62),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            }
            .onChange(of: lines.count) { _, count in
                guard count > 0 else { return }
                proxy.scrollTo(count - 1, anchor: .bottom)
            }
        }
    }
}
