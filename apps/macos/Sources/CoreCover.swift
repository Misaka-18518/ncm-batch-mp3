import Foundation

extension NCMConverterCore {
    static func readCoverArea(reader: BinaryReader, fileSize: UInt64) throws -> Data? {
        let start = try reader.offset()

        do {
            try reader.seekForward(5)
            let coverFrameLength = UInt64(try reader.readUInt32LE())
            let imageLength = UInt64(try reader.readUInt32LE())
            let payloadStart = try reader.offset()

            guard imageLength <= coverFrameLength,
                payloadStart + coverFrameLength <= fileSize
            else {
                throw NCMConversionError.incompleteFile("封面长度字段异常，无法定位音频数据")
            }

            let coverData = try readCoverPayload(reader: reader, imageLength: imageLength)
            try reader.seek(to: payloadStart + coverFrameLength)
            return coverData
        } catch {
            try reader.seek(to: start)
            _ = try reader.read(count: 4)
            _ = try reader.read(count: 5)
            let imageLength = UInt64(try reader.readUInt32LE())
            let payloadStart = try reader.offset()
            guard payloadStart + imageLength <= fileSize else {
                throw NCMConversionError.incompleteFile("封面长度字段异常，无法定位音频数据")
            }
            let coverData = try readCoverPayload(reader: reader, imageLength: imageLength)
            try reader.seek(to: payloadStart + imageLength)
            return coverData
        }
    }

    static func readCoverPayload(reader: BinaryReader, imageLength: UInt64) throws -> Data? {
        guard imageLength > 0 else {
            return nil
        }
        guard imageLength <= UInt64(maxCoverBytes) else {
            try reader.seekForward(imageLength)
            return nil
        }
        return try reader.read(count: Int(imageLength))
    }

    static func writeCoverFile(_ coverData: Data?, to directory: URL) throws -> URL? {
        guard let coverData, !coverData.isEmpty,
            let fileExtension = coverFileExtension(coverData)
        else {
            return nil
        }
        let url = directory.appendingPathComponent("cover").appendingPathExtension(fileExtension)
        try coverData.write(to: url, options: .atomic)
        return url
    }

    static func coverFileExtension(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "jpg"
        }
        if bytes.count >= 8, bytes[0...7].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "png"
        }
        if data.starts(withASCII: "GIF87a") || data.starts(withASCII: "GIF89a") {
            return "gif"
        }
        if bytes.count >= 12,
            Data(bytes[0..<4]).starts(withASCII: "RIFF"),
            Data(bytes[8..<12]).starts(withASCII: "WEBP")
        {
            return "webp"
        }
        return nil
    }

}
