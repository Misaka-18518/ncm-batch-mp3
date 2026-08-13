import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
            if colorScheme == .dark {
                Color.black
            } else {
                Color(red: 0.92, green: 0.90, blue: 0.85)
            }

            Rectangle()
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.18))
                .frame(height: 1)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.18), value: colorScheme)
        .ignoresSafeArea()
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
                            Color.teal.opacity(0.18),
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
        HStack(spacing: 7) {
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
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var manualColorScheme: ColorScheme?
    @State private var isTutorialPresented = false

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
        .frame(minWidth: 940, minHeight: 640)
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
                Text("🧡")
                    .font(.system(size: 11))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .padding(8)
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
        .alert(
            model.updatePrompt?.title ?? "",
            isPresented: Binding(
                get: { model.updatePrompt != nil },
                set: { presented in
                    if !presented {
                        model.dismissUpdatePrompt()
                    }
                }
            )
        ) {
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
        .preferredColorScheme(manualColorScheme)
        .sheet(isPresented: $isTutorialPresented) {
            TutorialView()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppMark(size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("NCM 批量转 MP3")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
            }

            Spacer(minLength: 0)

            StatusPill(title: "队列", value: "\(model.items.count)", systemImage: "tray.full", color: .blue)
            StatusPill(
                title: "完成", value: "\(model.finishedCount)", systemImage: "checkmark.circle.fill", color: .green)
            StatusPill(
                title: "引擎",
                value: model.ffmpegStatusText.contains("未") ? "缺失" : "可用",
                systemImage: model.ffmpegStatusText.contains("未")
                    ? "exclamationmark.triangle.fill" : "waveform.circle.fill",
                color: model.ffmpegStatusText.contains("未") ? .orange : .teal
            )

            Button {
                model.checkForUpdates(manual: true)
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .liquidButton()
            .help("检查更新")

            Button {
                manualColorScheme = colorScheme == .dark ? .light : .dark
            } label: {
                Image(systemName: colorScheme == .dark ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .controlSize(.small)
            .liquidButton()
            .help("切换深浅色")
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
            .disabled(model.isConverting)
            .help("添加 .ncm 文件")

            Button(action: model.chooseFolder) {
                Label("添加文件夹", systemImage: "folder.badge.plus")
                    .labelStyle(.titleAndIcon)
            }
            .liquidButton()
            .disabled(model.isConverting)
            .help("扫描文件夹里的 .ncm 文件")

            Button(action: model.removeSelected) {
                Image(systemName: "minus")
            }
            .liquidButton()
            .disabled(model.selection.isEmpty || model.isConverting)
            .help("移除选中的文件")

            Button(action: model.clearQueue) {
                Image(systemName: "trash")
            }
            .liquidButton()
            .disabled(model.items.isEmpty || model.isConverting)
            .help("清空列表")

            Spacer()

            Button(action: model.openOutputDirectory) {
                Label("打开结果文件", systemImage: "folder")
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
        .controlSize(.regular)
        .padding(10)
        .liquidPanel(cornerRadius: 14)
    }

    private var mainContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isTutorialPresented = true
                } label: {
                    Label("开始使用教程", systemImage: "book.pages")
                }
                .liquidButton()

                queuePanel
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            inspectorPanel
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 340)
                .frame(maxHeight: .infinity)
        }
    }

    private var queuePanel: some View {
        VStack(spacing: 12) {
            HStack {
                SectionTitle(title: "转换队列", systemImage: "music.note.list")
                Spacer()
                Text("\(model.items.count) 个文件")
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(14)
        .liquidPanel(cornerRadius: 14)
    }

    private var inspectorPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(title: "输出", systemImage: "square.and.arrow.down")
                HStack(spacing: 8) {
                    TextField(
                        "输出目录",
                        text: Binding(
                            get: { model.outputDirectory.path },
                            set: { model.outputDirectory = URL(fileURLWithPath: $0, isDirectory: true) }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button(action: model.chooseOutputDirectory) {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .liquidButton()
                    .help("选择输出目录")
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(title: "选项", systemImage: "slider.horizontal.3")
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
        .liquidPanel(cornerRadius: 14)
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

struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss

    private let steps: [(String, String, String)] = [
        ("1", "添加歌曲", "点击“添加文件”选择多个 .ncm，或点击“添加文件夹”批量扫描；也可以直接把文件或文件夹拖进窗口。"),
        ("2", "设置输出目录", "在右侧“输出”区域选择保存位置。转换完成后，可用工具栏的文件夹按钮直接在 Finder 中打开。"),
        ("3", "选择格式", "“优先 MP3”会保留原本就是 MP3 的歌曲，并通过内置 ffmpeg 把 FLAC、OGG 或 WAV 转成 MP3；“原始格式”只解密，不转码。"),
        ("4", "调整命名", "开启“用歌曲信息命名”后，将优先使用歌手和歌曲名；关闭后保留原 NCM 文件名。同名文件默认自动追加序号。"),
        ("5", "开始转换", "确认队列后点击“开始转换”。每首歌曲的状态、总进度和详细记录会实时显示，转换期间可以取消。"),
        ("6", "查看结果", "成功项目会显示输出文件位置。若解密后的音频头无法识别，程序会停止该文件，避免生成无法播放的伪 MP3。"),
        ("7", "获取更新", "右上角循环箭头会检查 GitHub Release。启动时也会静默检查，只有发现新版本时才提示下载。"),
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
                    ForEach(steps, id: \.0) { step in
                        HStack(alignment: .top, spacing: 13) {
                            Text(step.0)
                                .font(.callout.weight(.bold))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.08), in: Circle())
                            VStack(alignment: .leading, spacing: 5) {
                                Text(step.1)
                                    .font(.headline)
                                Text(step.2)
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
