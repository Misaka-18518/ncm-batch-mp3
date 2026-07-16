using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using NcmBatchMp3.Core;

internal static class Program
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("CTENFDAM");
    private static readonly byte[] CoreKey = Convert.FromHexString("687A4852416D736F356B496E62617857");
    private static readonly byte[] MetadataKey = Convert.FromHexString("2331346C6A6B5F215C5D2630553C2728");

    private static async Task Main()
    {
        AssertEqual(894, EasterEgg.DaysTogether(new DateTime(2026, 7, 12, 12, 0, 0)), "彩蛋计时");
        AssertEqual(
            "谨以此app，纪念Eric与Eva认识894天！",
            EasterEgg.Message(new DateTime(2026, 7, 12, 12, 0, 0)),
            "彩蛋文案");

        AssertTrue(UpdateRules.IsVersionNewer("v1.2.0", "1.1.2"), "新版比较");
        AssertTrue(!UpdateRules.IsVersionNewer("1.2.0", "1.2.0"), "同版比较");
        AssertTrue(!UpdateRules.IsVersionNewer("1.1.2", "1.2.0"), "旧版比较");
        AssertEqual(
            "https://github.com/enshuwu46-png/ncm-batch-mp3/releases/tag/v1.2.0",
            UpdateRules.OfficialReleaseUri(
                "v1.2.0",
                "https://github.com/enshuwu46-png/ncm-batch-mp3/releases/tag/v1.2.0")?.AbsoluteUri,
            "官方更新地址");
        AssertTrue(
            UpdateRules.OfficialReleaseUri("v1.2.0", "https://example.com/update") is null,
            "拦截非官方更新地址");

        var keyBox = NcmConverter.BuildKeyBox(Encoding.UTF8.GetBytes("test-stream-key"));
        var expectedPrefix = new byte[]
        {
            70, 218, 132, 64, 217, 166, 112, 195,
            68, 11, 211, 232, 95, 55, 88, 238,
            228, 34, 90, 131, 76, 19, 50, 174,
            108, 173, 40, 122, 251, 145, 35, 59
        };
        AssertTrue(keyBox.AsSpan(0, expectedPrefix.Length).SequenceEqual(expectedPrefix), "密钥盒算法");

        var temporaryDirectory = Path.Combine(Path.GetTempPath(), $"ncm-native-tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(temporaryDirectory);
        try
        {
            var sourcePath = Path.Combine(temporaryDirectory, "sample.ncm");
            var outputDirectory = Path.Combine(temporaryDirectory, "out");
            var expectedAudio = Encoding.Latin1.GetBytes("ID3\x04\x00\x00\x00\x00\x00\x10")
                .Concat(Encoding.UTF8.GetBytes(string.Concat(Enumerable.Repeat("synthetic audio payload", 64))))
                .ToArray();
            await BuildSyntheticNcmAsync(sourcePath, expectedAudio, "mp3", "Synthetic Track");

            var converter = new NcmConverter();
            var result = await converter.ConvertAsync(
                sourcePath,
                new ConversionOptions(outputDirectory, OutputMode.PreferMp3, true, false),
                null,
                CancellationToken.None);

            AssertEqual("Codex - Synthetic Track.mp3", Path.GetFileName(result.OutputPath), "元数据命名");
            AssertTrue(File.ReadAllBytes(result.OutputPath).AsSpan().SequenceEqual(expectedAudio), "NCM 往返字节一致");
            Console.WriteLine($"native core roundtrip ok: {Path.GetFileName(result.OutputPath)}");
        }
        finally
        {
            Directory.Delete(temporaryDirectory, true);
        }
    }

    private static async Task BuildSyntheticNcmAsync(
        string filePath,
        byte[] audio,
        string audioFormat,
        string title)
    {
        var keyData = Encoding.UTF8.GetBytes("test-stream-key");
        var keyPlain = Encoding.UTF8.GetBytes("neteasecloudmusic").Concat(keyData).ToArray();
        var encryptedKey = Xor(AesEncrypt(keyPlain, CoreKey), 0x64);
        var metadata = JsonSerializer.Serialize(new
        {
            musicName = title,
            artist = new object[] { new object[] { "Codex", 1 } },
            format = audioFormat
        });
        var metadataPlain = Encoding.UTF8.GetBytes($"music:{metadata}");
        var metadataPayload = Encoding.UTF8.GetBytes("163 key(Don't modify):")
            .Concat(Encoding.UTF8.GetBytes(Convert.ToBase64String(AesEncrypt(metadataPlain, MetadataKey))))
            .ToArray();
        var encryptedMetadata = Xor(metadataPayload, 0x63);
        var encryptedAudio = EncryptAudio(audio, NcmConverter.BuildKeyBox(keyData));

        await using var output = File.Create(filePath);
        await output.WriteAsync(Magic);
        await output.WriteAsync(new byte[] { 0x02, 0x00 });
        await output.WriteAsync(BitConverter.GetBytes((uint)encryptedKey.Length));
        await output.WriteAsync(encryptedKey);
        await output.WriteAsync(BitConverter.GetBytes((uint)encryptedMetadata.Length));
        await output.WriteAsync(encryptedMetadata);
        await output.WriteAsync(new byte[5]);
        await output.WriteAsync(new byte[4]);
        await output.WriteAsync(new byte[4]);
        await output.WriteAsync(encryptedAudio);
    }

    private static byte[] AesEncrypt(byte[] data, byte[] key)
    {
        using var aes = Aes.Create();
        aes.Key = key;
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.PKCS7;
        using var encryptor = aes.CreateEncryptor();
        return encryptor.TransformFinalBlock(data, 0, data.Length);
    }

    private static byte[] Xor(byte[] data, byte value)
    {
        var output = data.ToArray();
        for (var index = 0; index < output.Length; index++)
        {
            output[index] ^= value;
        }
        return output;
    }

    private static byte[] EncryptAudio(byte[] data, byte[] keyBox)
    {
        var output = data.ToArray();
        for (var index = 0; index < output.Length; index++)
        {
            var j = (index + 1) & 0xff;
            var first = keyBox[j];
            var secondIndex = (first + j) & 0xff;
            var maskIndex = (first + keyBox[secondIndex]) & 0xff;
            output[index] ^= keyBox[maskIndex];
        }
        return output;
    }

    private static void AssertTrue(bool value, string name)
    {
        if (!value)
        {
            throw new InvalidOperationException($"测试失败：{name}");
        }
    }

    private static void AssertEqual<T>(T expected, T actual, string name)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"测试失败：{name}，预期 {expected}，实际 {actual}");
        }
    }
}
