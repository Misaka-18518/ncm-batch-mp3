import Foundation

extension NCMConverterCore {
    static func exportOriginal(_ context: ConversionContext) throws -> ConversionResult {
        let target = try outputTarget(context, fileExtension: context.extraction.sourceFormat)
        if context.extraction.sourceFormat == "mp3", let ffmpeg = cachedFFmpegPath, context.coverURL != nil {
            try transcodeToMP3(
                inputURL: context.tempAudioURL,
                outputURL: target,
                ffmpegPath: ffmpeg,
                metadata: context.extraction.metadata,
                coverURL: context.coverURL,
                copyAudio: true
            )
            return ConversionResult(
                inputURL: context.inputURL, outputURL: target, sourceFormat: "mp3", transcoded: false,
                message: "已导出 MP3（含封面）")
        }
        try moveReplacingIfNeeded(from: context.tempAudioURL, to: target, overwrite: context.options.overwriteExisting)
        return ConversionResult(
            inputURL: context.inputURL, outputURL: target, sourceFormat: context.extraction.sourceFormat,
            transcoded: false, message: "已导出原始音频")
    }

    static func exportDirectMP3(_ context: ConversionContext) throws -> ConversionResult {
        let target = try outputTarget(context, fileExtension: "mp3")
        if let ffmpeg = cachedFFmpegPath, context.coverURL != nil {
            try transcodeToMP3(
                inputURL: context.tempAudioURL,
                outputURL: target,
                ffmpegPath: ffmpeg,
                metadata: context.extraction.metadata,
                coverURL: context.coverURL,
                copyAudio: true
            )
            return ConversionResult(
                inputURL: context.inputURL, outputURL: target, sourceFormat: "mp3", transcoded: false,
                message: "已转换为 MP3（含封面）")
        }
        try moveReplacingIfNeeded(from: context.tempAudioURL, to: target, overwrite: context.options.overwriteExisting)
        return ConversionResult(
            inputURL: context.inputURL, outputURL: target, sourceFormat: "mp3", transcoded: false,
            message: "已转换为 MP3")
    }

    static func exportTranscoded(_ context: ConversionContext, ffmpegPath: String) throws -> ConversionResult {
        let target = try outputTarget(context, fileExtension: "mp3")
        try transcodeToMP3(
            inputURL: context.tempAudioURL,
            outputURL: target,
            ffmpegPath: ffmpegPath,
            metadata: context.extraction.metadata,
            coverURL: context.coverURL,
            copyAudio: false
        )
        return ConversionResult(
            inputURL: context.inputURL, outputURL: target, sourceFormat: context.extraction.sourceFormat,
            transcoded: true, message: "已从 \(context.extraction.sourceFormat.uppercased()) 转码为 MP3")
    }

    static func exportFallback(_ context: ConversionContext) throws -> ConversionResult {
        let target = try outputTarget(context, fileExtension: context.extraction.sourceFormat)
        try moveReplacingIfNeeded(from: context.tempAudioURL, to: target, overwrite: context.options.overwriteExisting)
        return ConversionResult(
            inputURL: context.inputURL,
            outputURL: target,
            sourceFormat: context.extraction.sourceFormat,
            transcoded: false,
            message: "源音频是 \(context.extraction.sourceFormat.uppercased())；未检测到 ffmpeg，已导出原始音频"
        )
    }

    static func outputTarget(_ context: ConversionContext, fileExtension: String) throws -> URL {
        try uniqueURL(
            context.options.outputDirectory.appendingPathComponent(context.stem).appendingPathExtension(fileExtension),
            overwrite: context.options.overwriteExisting)
    }

    struct ConversionContext {
        let inputURL: URL
        let extraction: ExtractionResult
        let stem: String
        let options: ConversionOptions
        let tempAudioURL: URL
        let coverURL: URL?
    }
}
