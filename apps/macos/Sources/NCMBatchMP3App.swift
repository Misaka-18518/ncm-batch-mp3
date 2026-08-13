import Foundation
import SwiftUI

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

    private struct CLIArguments {
        var inputs: [URL] = []
        var outputDirectory = FileManager.default.currentDirectoryPath
        var mode: OutputMode = .preferMP3
        var rename = false
        var overwrite = false
    }

    static func runCLI(arguments: [String]) -> Int32 {
        guard let parsed = parseCLIArguments(arguments), !parsed.inputs.isEmpty else {
            fputs("usage: NCMConverter --cli-convert file.ncm [...] --output outdir [--rename] [--overwrite]\n", stderr)
            return 2
        }

        let options = ConversionOptions(
            outputDirectory: URL(fileURLWithPath: parsed.outputDirectory, isDirectory: true),
            outputMode: parsed.mode,
            renameByMetadata: parsed.rename,
            overwriteExisting: parsed.overwrite
        )

        var failed = 0
        for input in parsed.inputs {
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

    private static func parseCLIArguments(_ arguments: [String]) -> CLIArguments? {
        var parsed = CLIArguments()
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--output", "-o":
                index += 1
                guard index < arguments.count else {
                    fputs("missing output directory\n", stderr)
                    return nil
                }
                parsed.outputDirectory = arguments[index]
            case "--mode":
                index += 1
                guard index < arguments.count else {
                    fputs("missing mode\n", stderr)
                    return nil
                }
                parsed.mode = arguments[index] == "original" ? .original : .preferMP3
            case "--rename":
                parsed.rename = true
            case "--overwrite":
                parsed.overwrite = true
            default:
                parsed.inputs.append(URL(fileURLWithPath: arg))
            }
            index += 1
        }
        return parsed
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
        guard ReleaseUpdateChecker.isNewerVersion("v1.2.0", than: "1.1.2"),
            !ReleaseUpdateChecker.isNewerVersion("1.2.0", than: "1.2.0")
        else {
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
            108, 173, 40, 122, 251, 145, 35, 59,
        ]
        let encryptedKeyPlain = Data("neteasecloudmusic".utf8) + keyData
        let encryptedKey = NCMConverterCore.xor(
            data: try NCMConverterCore.aes128ECBEncryptPKCS7(encryptedKeyPlain, key: NCMConverterCore.coreKey),
            value: 0x64
        )

        let metadata: [String: Any] = [
            "musicName": "Synthetic Track",
            "artist": [["Codex", 1]],
            "format": "mp3",
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        let metadataPlain = Data("music:".utf8) + metadataJSON
        let metadataCipher = try NCMConverterCore.aes128ECBEncryptPKCS7(metadataPlain, key: NCMConverterCore.metaKey)
        let metadataPayload =
            Data("163 key(Don't modify):".utf8)
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
