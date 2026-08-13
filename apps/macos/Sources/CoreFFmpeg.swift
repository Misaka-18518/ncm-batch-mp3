import Foundation

extension NCMConverterCore {
    static func findFFmpeg() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
            FileManager.default.isExecutableFile(atPath: bundled)
        {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
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

    static func transcodeToMP3(
        inputURL: URL,
        outputURL: URL,
        ffmpegPath: String,
        metadata: [String: Any],
        coverURL: URL?,
        copyAudio: Bool
    ) throws {
        var arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-i", inputURL.path,
        ]
        if let coverURL {
            arguments.append(contentsOf: ["-i", coverURL.path])
        }
        arguments.append(contentsOf: ["-map", "0:a:0", "-map_metadata", "0"])
        if coverURL != nil {
            arguments.append(contentsOf: ["-map", "1:v:0"])
        }
        if copyAudio {
            arguments.append(contentsOf: ["-codec:a", "copy"])
        } else {
            arguments.append(contentsOf: ["-codec:a", "libmp3lame", "-q:a", "2"])
        }
        if coverURL != nil {
            arguments.append(contentsOf: [
                "-codec:v", "mjpeg",
                "-pix_fmt", "yuvj420p",
                "-q:v", "2",
                "-frames:v", "1",
                "-disposition:v:0", "attached_pic",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
            ])
        }

        let title = (metadata["musicName"] as? String) ?? (metadata["name"] as? String) ?? ""
        let artist = artistNames(from: metadata)
        let album = albumName(from: metadata)
        for (key, value) in [("title", title), ("artist", artist), ("album", album)] where !value.isEmpty {
            arguments.append(contentsOf: ["-metadata", "\(key)=\(value)"])
        }
        arguments.append(contentsOf: ["-id3v2_version", "3", "-write_id3v1", "1", outputURL.path])

        let result = try ProcessRunner.run(
            ffmpegPath,
            arguments: arguments
        )
        guard result.status == 0 else {
            let detail = String(data: result.stderr, encoding: .utf8) ?? "\(result.status)"
            try? FileManager.default.removeItem(at: outputURL)
            throw NCMConversionError.process(
                "ffmpeg 转 MP3 失败：\(detail.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

}
