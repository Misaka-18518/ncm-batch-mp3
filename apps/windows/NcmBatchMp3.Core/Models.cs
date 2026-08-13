namespace NcmBatchMp3.Core;

public enum OutputMode
{
    PreferMp3,
    Original
}

public sealed record ConversionOptions(
    string OutputDirectory,
    OutputMode OutputMode,
    bool RenameByMetadata,
    bool OverwriteExisting);

public sealed record ConversionProgress(string Phase, double Fraction);

public sealed record ConversionResult(
    string OutputPath,
    string SourceFormat,
    bool Transcoded,
    string Message);

internal sealed record NcmMetadata(string Title, string Artists, string Album);

internal sealed record ExtractionResult(
    string TempDirectory,
    string AudioPath,
    NcmMetadata Metadata,
    string SourceFormat,
    string? CoverPath);
