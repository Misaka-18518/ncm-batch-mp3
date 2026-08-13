namespace NcmBatchMp3.Core;

public static class UpdateRules
{
    public const string Owner = "enshuwu46-png";
    public const string Repository = "ncm-batch-mp3";
    public const string LatestReleaseApi = "https://api.github.com/repos/enshuwu46-png/ncm-batch-mp3/releases/latest";

    public static bool IsVersionNewer(string? latest, string? current)
    {
        var latestParts = VersionParts(latest);
        var currentParts = VersionParts(current);
        if (latestParts is null || currentParts is null)
        {
            return false;
        }

        var length = Math.Max(latestParts.Length, currentParts.Length);
        for (var index = 0; index < length; index++)
        {
            var newest = index < latestParts.Length ? latestParts[index] : 0;
            var installed = index < currentParts.Length ? currentParts[index] : 0;
            if (newest != installed)
            {
                return newest > installed;
            }
        }

        return false;
    }

    public static Uri? OfficialReleaseUri(string? tagName, string? releaseUrl)
    {
        return Uri.TryCreate(releaseUrl?.Trim(), UriKind.Absolute, out var uri)
            ? OfficialReleaseUri(tagName, uri)
            : null;
    }

    public static Uri? OfficialReleaseUri(string? tagName, Uri? releaseUri)
    {
        tagName = tagName?.Trim();
        if (string.IsNullOrWhiteSpace(tagName) || releaseUri is null)
        {
            return null;
        }

        var expectedPath = $"/{Owner}/{Repository}/releases/tag/{Uri.EscapeDataString(tagName)}";
        return releaseUri.Scheme == Uri.UriSchemeHttps &&
               releaseUri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase) &&
               releaseUri.AbsolutePath == expectedPath
            ? releaseUri
            : null;
    }

    public static int[]? VersionParts(string? version)
    {
        var normalized = (version ?? string.Empty).Trim();
        if (normalized.StartsWith('v') || normalized.StartsWith('V'))
        {
            normalized = normalized[1..];
        }

        var suffixIndex = normalized.IndexOfAny(['+', '-']);
        if (suffixIndex >= 0)
        {
            normalized = normalized[..suffixIndex];
        }

        var textParts = normalized.Split('.');
        if (textParts.Length is < 1 or > 3)
        {
            return null;
        }

        var parts = new int[textParts.Length];
        for (var index = 0; index < textParts.Length; index++)
        {
            if (textParts[index].Length == 0 ||
                textParts[index].Any(character => !char.IsAsciiDigit(character)) ||
                !int.TryParse(textParts[index], out parts[index]))
            {
                return null;
            }
        }

        return parts;
    }
}
