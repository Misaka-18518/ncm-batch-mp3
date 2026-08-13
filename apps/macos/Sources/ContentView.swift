import Foundation
import SwiftUI
import UniformTypeIdentifiers

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
