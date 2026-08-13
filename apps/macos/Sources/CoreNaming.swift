import Foundation

extension NCMConverterCore {
    static func outputStem(inputURL: URL, metadata: [String: Any], renameByMetadata: Bool) -> String {
        guard renameByMetadata else {
            return safeFilename(inputURL.deletingPathExtension().lastPathComponent)
        }

        let title =
            (metadata["musicName"] as? String)
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

    static func albumName(from metadata: [String: Any]) -> String {
        let raw = metadata["album"]
        if let name = raw as? String {
            return name
        }
        if let values = raw as? [Any], let name = values.first as? String {
            return name
        }
        if let dictionary = raw as? [String: Any], let name = dictionary["name"] as? String {
            return name
        }
        return ""
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

}
