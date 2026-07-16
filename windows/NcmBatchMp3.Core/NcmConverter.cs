using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace NcmBatchMp3.Core;

public sealed class NcmConverter
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("CTENFDAM");
    private static readonly byte[] CoreKey = Convert.FromHexString("687A4852416D736F356B496E62617857");
    private static readonly byte[] MetadataKey = Convert.FromHexString("2331346C6A6B5F215C5D2630553C2728");
    private const int ChunkSize = 1024 * 1024;

    public async Task<ConversionResult> ConvertAsync(
        string inputPath,
        ConversionOptions options,
        string? ffmpegPath,
        CancellationToken cancellationToken,
        IProgress<ConversionProgress>? progress = null)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(inputPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(options.OutputDirectory);
        cancellationToken.ThrowIfCancellationRequested();

        Directory.CreateDirectory(options.OutputDirectory);
        var extraction = await ExtractAsync(inputPath, cancellationToken, progress).ConfigureAwait(false);

        try
        {
            if (extraction.SourceFormat == "unknown")
            {
                throw new InvalidDataException("解密后的音频头无法识别，已停止，避免生成打不开的伪 MP3");
            }

            var stem = OutputStem(inputPath, extraction.Metadata, options.RenameByMetadata);
            var preferMp3 = options.OutputMode == OutputMode.PreferMp3;

            if (preferMp3 && extraction.SourceFormat != "mp3" && !string.IsNullOrWhiteSpace(ffmpegPath))
            {
                var target = UniqueOutputPath(options.OutputDirectory, stem, "mp3", options.OverwriteExisting);
                progress?.Report(new ConversionProgress("transcode", 0.92));
                try
                {
                    await TranscodeToMp3Async(extraction.AudioPath, target, ffmpegPath, cancellationToken)
                        .ConfigureAwait(false);
                }
                catch
                {
                    TryDeleteFile(target);
                    throw;
                }
                progress?.Report(new ConversionProgress("done", 1));
                return new ConversionResult(
                    target,
                    extraction.SourceFormat,
                    true,
                    $"已从 {extraction.SourceFormat.ToUpperInvariant()} 转码为 MP3");
            }

            var extension = preferMp3 && extraction.SourceFormat == "mp3"
                ? "mp3"
                : extraction.SourceFormat;
            var outputPath = UniqueOutputPath(
                options.OutputDirectory,
                stem,
                extension,
                options.OverwriteExisting);
            MoveReplacing(extraction.AudioPath, outputPath, options.OverwriteExisting);
            progress?.Report(new ConversionProgress("done", 1));

            var message = extraction.SourceFormat == "mp3"
                ? "已导出 MP3"
                : $"已导出 {extraction.SourceFormat.ToUpperInvariant()}";
            return new ConversionResult(outputPath, extraction.SourceFormat, false, message);
        }
        finally
        {
            TryDeleteDirectory(extraction.TempDirectory);
        }
    }

    public static byte[] BuildKeyBox(ReadOnlySpan<byte> keyData)
    {
        if (keyData.IsEmpty)
        {
            throw new InvalidDataException("NCM 音频密钥为空");
        }

        var box = Enumerable.Range(0, 256).Select(value => (byte)value).ToArray();
        var c = 0;
        var lastByte = 0;
        var keyOffset = 0;

        for (var index = 0; index < 256; index++)
        {
            var swap = box[index];
            c = (swap + lastByte + keyData[keyOffset]) & 0xff;
            keyOffset = (keyOffset + 1) % keyData.Length;
            box[index] = box[c];
            box[c] = swap;
            lastByte = c;
        }

        return box;
    }

    private static async Task<ExtractionResult> ExtractAsync(
        string inputPath,
        CancellationToken cancellationToken,
        IProgress<ConversionProgress>? progress)
    {
        var fileInfo = new FileInfo(inputPath);
        if (!fileInfo.Exists)
        {
            throw new FileNotFoundException("找不到 NCM 文件", inputPath);
        }

        var tempDirectory = Path.Combine(Path.GetTempPath(), $"ncm-batch-mp3-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tempDirectory);
        var audioPath = Path.Combine(tempDirectory, $"{Guid.NewGuid():N}.audio");

        try
        {
            await using var input = new FileStream(
                inputPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                ChunkSize,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            await using var output = new FileStream(
                audioPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                ChunkSize,
                FileOptions.Asynchronous | FileOptions.SequentialScan);

            var cursor = new BinaryCursor(input);
            var header = await ReadHeaderAsync(cursor, fileInfo.Length, cancellationToken).ConfigureAwait(false);
            var totalAudioBytes = Math.Max(1, fileInfo.Length - header.AudioOffset);
            var audioOffset = 0L;
            using var firstBytes = new MemoryStream(64);
            var buffer = new byte[ChunkSize];

            while (cursor.Position < fileInfo.Length)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var remaining = fileInfo.Length - cursor.Position;
                var length = (int)Math.Min(buffer.Length, remaining);
                await cursor.ReadExactlyAsync(buffer.AsMemory(0, length), cancellationToken).ConfigureAwait(false);
                DecryptAudioChunk(buffer.AsSpan(0, length), header.KeyBox, audioOffset);

                if (firstBytes.Length < 64)
                {
                    var captureLength = (int)Math.Min(64 - firstBytes.Length, length);
                    firstBytes.Write(buffer, 0, captureLength);
                }

                await output.WriteAsync(buffer.AsMemory(0, length), cancellationToken).ConfigureAwait(false);
                audioOffset += length;
                progress?.Report(new ConversionProgress(
                    "extract",
                    Math.Min(0.86, audioOffset / (double)totalAudioBytes * 0.86)));
            }

            await output.FlushAsync(cancellationToken).ConfigureAwait(false);
            return new ExtractionResult(
                tempDirectory,
                audioPath,
                header.Metadata,
                SniffAudioFormat(firstBytes.ToArray()));
        }
        catch
        {
            TryDeleteDirectory(tempDirectory);
            throw;
        }
    }

    private static async Task<NcmHeader> ReadHeaderAsync(
        BinaryCursor cursor,
        long fileSize,
        CancellationToken cancellationToken)
    {
        var magic = await cursor.ReadAsync(8, cancellationToken).ConfigureAwait(false);
        if (!magic.AsSpan().SequenceEqual(Magic))
        {
            throw new InvalidDataException("不是有效的 NCM 文件");
        }

        await cursor.SkipAsync(2, fileSize).ConfigureAwait(false);
        var keyLength = await cursor.ReadUInt32Async(cancellationToken).ConfigureAwait(false);
        var encryptedKey = await cursor.ReadAsync(CheckedLength(keyLength), cancellationToken).ConfigureAwait(false);
        Xor(encryptedKey, 0x64);
        var decryptedKey = AesEcbDecrypt(encryptedKey, CoreKey);
        if (decryptedKey.Length <= 17)
        {
            throw new InvalidDataException("NCM 音频密钥异常");
        }

        var keyBox = BuildKeyBox(decryptedKey.AsSpan(17));
        var metadataLength = await cursor.ReadUInt32Async(cancellationToken).ConfigureAwait(false);
        var encryptedMetadata = await cursor.ReadAsync(CheckedLength(metadataLength), cancellationToken)
            .ConfigureAwait(false);
        Xor(encryptedMetadata, 0x63);
        var metadata = ParseMetadata(encryptedMetadata);

        await SkipCoverAreaAsync(cursor, fileSize, cancellationToken).ConfigureAwait(false);
        return new NcmHeader(keyBox, metadata, cursor.Position);
    }

    private static int CheckedLength(uint length)
    {
        if (length == 0 || length > int.MaxValue)
        {
            throw new InvalidDataException("NCM 头部长度字段异常");
        }

        return checked((int)length);
    }

    private static async Task SkipCoverAreaAsync(
        BinaryCursor cursor,
        long fileSize,
        CancellationToken cancellationToken)
    {
        var start = cursor.Position;
        try
        {
            await cursor.SkipAsync(5, fileSize).ConfigureAwait(false);
            var frameLength = await cursor.ReadUInt32Async(cancellationToken).ConfigureAwait(false);
            var imageLength = await cursor.ReadUInt32Async(cancellationToken).ConfigureAwait(false);
            var payloadStart = cursor.Position;
            if (imageLength > frameLength || payloadStart + frameLength > fileSize)
            {
                throw new InvalidDataException("封面长度字段异常，无法定位音频数据");
            }

            cursor.Seek(payloadStart + frameLength, fileSize);
        }
        catch (Exception error) when (error is InvalidDataException or EndOfStreamException)
        {
            cursor.Seek(start, fileSize);
            _ = await cursor.ReadAsync(4, cancellationToken).ConfigureAwait(false);
            _ = await cursor.ReadAsync(5, cancellationToken).ConfigureAwait(false);
            var imageLength = await cursor.ReadUInt32Async(cancellationToken).ConfigureAwait(false);
            var payloadStart = cursor.Position;
            if (payloadStart + imageLength > fileSize)
            {
                throw new InvalidDataException("封面长度字段异常，无法定位音频数据");
            }

            cursor.Seek(payloadStart + imageLength, fileSize);
        }
    }

    private static NcmMetadata ParseMetadata(byte[] raw)
    {
        if (raw.Length <= 22)
        {
            throw new InvalidDataException("歌曲信息字段过短");
        }

        try
        {
            var base64 = Encoding.UTF8.GetString(raw, 22, raw.Length - 22);
            var plain = Encoding.UTF8.GetString(AesEcbDecrypt(Convert.FromBase64String(base64), MetadataKey));
            var json = plain.StartsWith("music:", StringComparison.Ordinal) ? plain[6..] : plain;
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var title = JsonString(root, "musicName") ?? JsonString(root, "name") ?? string.Empty;
            var artists = ParseArtists(root);
            return new NcmMetadata(title, artists);
        }
        catch (Exception error) when (error is FormatException or CryptographicException or JsonException)
        {
            throw new InvalidDataException("歌曲信息字段损坏", error);
        }
    }

    private static string? JsonString(JsonElement root, string property)
    {
        return root.TryGetProperty(property, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
    }

    private static string ParseArtists(JsonElement root)
    {
        if ((!root.TryGetProperty("artist", out var artists) &&
             !root.TryGetProperty("artists", out artists)) ||
            artists.ValueKind != JsonValueKind.Array)
        {
            return string.Empty;
        }

        var names = new List<string>();
        foreach (var artist in artists.EnumerateArray())
        {
            string? name = null;
            if (artist.ValueKind == JsonValueKind.Array)
            {
                var enumerator = artist.EnumerateArray();
                if (enumerator.MoveNext() && enumerator.Current.ValueKind == JsonValueKind.String)
                {
                    name = enumerator.Current.GetString();
                }
            }
            else if (artist.ValueKind == JsonValueKind.Object &&
                     artist.TryGetProperty("name", out var property) &&
                     property.ValueKind == JsonValueKind.String)
            {
                name = property.GetString();
            }
            else if (artist.ValueKind == JsonValueKind.String)
            {
                name = artist.GetString();
            }

            if (!string.IsNullOrWhiteSpace(name))
            {
                names.Add(name);
            }
        }

        return string.Join("、", names);
    }

    private static void DecryptAudioChunk(Span<byte> chunk, byte[] keyBox, long absoluteOffset)
    {
        for (var index = 0; index < chunk.Length; index++)
        {
            var position = absoluteOffset + index;
            var j = (int)((position + 1) & 0xff);
            var first = keyBox[j];
            var secondIndex = (first + j) & 0xff;
            var maskIndex = (first + keyBox[secondIndex]) & 0xff;
            chunk[index] ^= keyBox[maskIndex];
        }
    }

    private static byte[] AesEcbDecrypt(byte[] data, byte[] key)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.PKCS7;
        using var decryptor = aes.CreateDecryptor();
        return decryptor.TransformFinalBlock(data, 0, data.Length);
    }

    private static void Xor(Span<byte> data, byte value)
    {
        for (var index = 0; index < data.Length; index++)
        {
            data[index] ^= value;
        }
    }

    private static string SniffAudioFormat(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length >= 3 && bytes[..3].SequenceEqual("ID3"u8))
        {
            return "mp3";
        }

        if (bytes.Length >= 2 && bytes[0] == 0xff && (bytes[1] & 0xe0) == 0xe0)
        {
            return "mp3";
        }

        if (bytes.Length >= 4 && bytes[..4].SequenceEqual("fLaC"u8))
        {
            return "flac";
        }

        if (bytes.Length >= 4 && bytes[..4].SequenceEqual("OggS"u8))
        {
            return "ogg";
        }

        if (bytes.Length >= 12 && bytes[..4].SequenceEqual("RIFF"u8) && bytes[8..12].SequenceEqual("WAVE"u8))
        {
            return "wav";
        }

        return "unknown";
    }

    private static string OutputStem(string inputPath, NcmMetadata metadata, bool renameByMetadata)
    {
        var original = Path.GetFileNameWithoutExtension(inputPath);
        if (!renameByMetadata)
        {
            return SafeFilename(original);
        }

        var title = string.IsNullOrWhiteSpace(metadata.Title) ? original : metadata.Title;
        return SafeFilename(string.IsNullOrWhiteSpace(metadata.Artists)
            ? title
            : $"{metadata.Artists} - {title}");
    }

    public static string SafeFilename(string? name)
    {
        var value = string.IsNullOrWhiteSpace(name) ? "converted" : name;
        var invalid = new HashSet<char>(['\\', '/', ':', '*', '?', '"', '<', '>', '|']);
        var builder = new StringBuilder(value.Length);
        var previousWhitespace = false;

        foreach (var character in value)
        {
            var output = invalid.Contains(character) ? '_' : character;
            if (char.IsWhiteSpace(output))
            {
                if (!previousWhitespace)
                {
                    builder.Append(' ');
                }
                previousWhitespace = true;
            }
            else
            {
                builder.Append(output);
                previousWhitespace = false;
            }
        }

        var cleaned = builder.ToString().Trim();
        if (cleaned.Length == 0)
        {
            cleaned = "converted";
        }

        return cleaned[..Math.Min(180, cleaned.Length)];
    }

    private static string UniqueOutputPath(
        string directory,
        string stem,
        string extension,
        bool overwrite)
    {
        extension = extension.TrimStart('.');
        var desired = Path.Combine(directory, $"{stem}.{extension}");
        if (overwrite || !File.Exists(desired))
        {
            return desired;
        }

        for (var index = 1; index < 10_000; index++)
        {
            var candidate = Path.Combine(directory, $"{stem} ({index}).{extension}");
            if (!File.Exists(candidate))
            {
                return candidate;
            }
        }

        throw new IOException($"输出目录里重名文件太多：{Path.GetFileName(desired)}");
    }

    private static void MoveReplacing(string source, string target, bool overwrite)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        if (overwrite && File.Exists(target))
        {
            File.Delete(target);
        }

        try
        {
            File.Move(source, target);
        }
        catch (IOException)
        {
            File.Copy(source, target, overwrite);
            File.Delete(source);
        }
    }

    private static async Task TranscodeToMp3Async(
        string inputPath,
        string outputPath,
        string ffmpegPath,
        CancellationToken cancellationToken)
    {
        var startInfo = new ProcessStartInfo(ffmpegPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true
        };
        foreach (var argument in new[]
                 {
                     "-hide_banner", "-loglevel", "error", "-y", "-i", inputPath,
                     "-codec:a", "libmp3lame", "-q:a", "2", outputPath
                 })
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = new Process { StartInfo = startInfo };
        if (!process.Start())
        {
            throw new InvalidOperationException("无法启动内置 ffmpeg");
        }

        using var cancellation = cancellationToken.Register(() =>
        {
            try
            {
                if (!process.HasExited)
                {
                    process.Kill(true);
                }
            }
            catch
            {
                // The process may have exited between the checks.
            }
        });

        var stderrTask = process.StandardError.ReadToEndAsync(cancellationToken);
        var stdoutTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        _ = await stdoutTask.ConfigureAwait(false);

        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException(string.IsNullOrWhiteSpace(stderr)
                ? $"ffmpeg 退出码 {process.ExitCode}"
                : stderr.Trim());
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, true);
            }
        }
        catch
        {
            // Temporary files can be cleaned by Windows if an antivirus still holds a handle.
        }
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // A failed transcode must not hide the original conversion error.
        }
    }

    private sealed record NcmHeader(byte[] KeyBox, NcmMetadata Metadata, long AudioOffset);

    private sealed class BinaryCursor(FileStream stream)
    {
        public long Position => stream.Position;

        public async Task<byte[]> ReadAsync(int length, CancellationToken cancellationToken)
        {
            var buffer = new byte[length];
            await ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
            return buffer;
        }

        public async Task ReadExactlyAsync(Memory<byte> buffer, CancellationToken cancellationToken)
        {
            try
            {
                await stream.ReadExactlyAsync(buffer, cancellationToken).ConfigureAwait(false);
            }
            catch (EndOfStreamException error)
            {
                throw new EndOfStreamException("文件不完整或 NCM 头部损坏", error);
            }
        }

        public async Task<uint> ReadUInt32Async(CancellationToken cancellationToken)
        {
            var bytes = await ReadAsync(4, cancellationToken).ConfigureAwait(false);
            return BinaryPrimitives.ReadUInt32LittleEndian(bytes);
        }

        public Task SkipAsync(long length, long fileSize)
        {
            Seek(Position + length, fileSize);
            return Task.CompletedTask;
        }

        public void Seek(long position, long fileSize)
        {
            if (position < 0 || position > fileSize)
            {
                throw new InvalidDataException("文件不完整或 NCM 头部损坏");
            }
            stream.Seek(position, SeekOrigin.Begin);
        }
    }
}
