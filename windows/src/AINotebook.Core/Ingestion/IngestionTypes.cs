using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

public sealed class FolderIngestionException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed record IngestionLimits(long FileBytes, long OfficeBytes, int TextScalars, int PdfPages, int Chunks, int Cells)
{
    public static IngestionLimits Defaults { get; } = new(RagContractV1.Scan.MaxFileBytes,
        RagContractV1.Scan.MaxOfficeDecompressedBytes, RagContractV1.Scan.MaxExtractedChars,
        RagContractV1.Scan.MaxPdfPages, RagContractV1.Scan.MaxChunksPerFile, 1_000_000);

    public void Validate()
    {
        static void Check(long value, long maximum, string code)
        {
            if (value <= 0 || value > maximum) throw new FolderIngestionException(code);
        }
        Check(FileBytes, Defaults.FileBytes, "fileLimit");
        Check(OfficeBytes, Defaults.OfficeBytes, "officeLimit");
        Check(TextScalars, Defaults.TextScalars, "textLimit");
        Check(PdfPages, Defaults.PdfPages, "pageLimit");
        Check(Chunks, Defaults.Chunks, "chunkLimit");
        Check(Cells, Defaults.Cells, "cellLimit");
    }

    public static IngestionLimits FromJson(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new FolderIngestionException("unsupportedSyntax");
            var result = Defaults;
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var property in document.RootElement.EnumerateObject())
            {
                if (!seen.Add(property.Name) || property.Value.ValueKind != JsonValueKind.Number ||
                    !property.Value.TryGetInt64(out long value))
                    throw new FolderIngestionException("unsupportedSyntax");
                result = property.Name switch
                {
                    "maxFileBytes" => result with { FileBytes = value },
                    "maxOfficeDecompressedBytes" => result with { OfficeBytes = value },
                    "maxExtractedChars" => result with { TextScalars = Narrow(value, "textLimit") },
                    "maxPdfPages" => result with { PdfPages = Narrow(value, "pageLimit") },
                    "maxChunksPerFile" => result with { Chunks = Narrow(value, "chunkLimit") },
                    "maxCells" => result with { Cells = Narrow(value, "cellLimit") },
                    _ => throw new FolderIngestionException("unsupportedSyntax")
                };
            }
            result.Validate();
            return result;
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            throw new FolderIngestionException("unsupportedSyntax");
        }
    }

    private static int Narrow(long value, string code)
    {
        if (value is < int.MinValue or > int.MaxValue) throw new FolderIngestionException(code);
        return (int)value;
    }

    public string ToJson()
    {
        Validate();
        return JsonSerializer.Serialize(new
        {
            maxFileBytes = FileBytes,
            maxOfficeDecompressedBytes = OfficeBytes,
            maxExtractedChars = TextScalars,
            maxPdfPages = PdfPages,
            maxChunksPerFile = Chunks,
            maxCells = Cells
        });
    }
}

public sealed record FolderRules
{
    private IReadOnlyList<string> _includeExts = Array.Empty<string>();
    private IReadOnlyList<string> _ignoreGlobs = Array.Empty<string>();
    public IReadOnlyList<string> IncludeExts { get => _includeExts; init => _includeExts = IngestionValues.Snapshot(value); }
    public IReadOnlyList<string> IgnoreGlobs { get => _ignoreGlobs; init => _ignoreGlobs = IngestionValues.Snapshot(value); }
    public IngestionLimits Limits { get; init; }
    public string EncodingFallback { get; init; }

    public FolderRules(IReadOnlyList<string> includeExts, IReadOnlyList<string> ignoreGlobs,
        IngestionLimits limits, string encodingFallback)
    {
        IncludeExts = includeExts;
        IgnoreGlobs = ignoreGlobs;
        Limits = limits;
        EncodingFallback = encodingFallback;
    }

    /// <summary>Contract ingestion-formats-v1 §3. Folders stored with the previous default are upgraded once
    /// (Storage.FolderDefaultsUpgrade).</summary>
    public static FolderRules Defaults { get; } = new(
        ["pdf", "txt", "md", "markdown", "docx", "pptx", "xlsx", "docm", "pptm", "xlsm", "eml", "msg"],
        [".*", "node_modules", ".git", "build", "dist", ".venv", "__pycache__", "target", "bin", "obj", "~$*"],
        IngestionLimits.Defaults, "cp1250");

    public FolderRules Validate(UnicodeTables tables, bool caseSensitive)
    {
        ArgumentNullException.ThrowIfNull(tables);
        if (Limits is null) throw new FolderIngestionException("unsupportedSyntax");
        Limits.Validate();
        if (EncodingFallback is not ("cp1250" or "none"))
            throw new FolderIngestionException("unsupportedEncoding");
        var extensions = new List<string>(IncludeExts.Count);
        foreach (string extension in IncludeExts)
        {
            if (string.IsNullOrWhiteSpace(extension)) throw new FolderIngestionException("unsupportedSyntax");
            string value = extension[0] == '.' ? extension[1..] : extension;
            if (value.Length == 0 || value.Any(char.IsWhiteSpace) || value.IndexOfAny(['*', '?', '[', ']', '{', '}', '/', '\\']) >= 0)
                throw new FolderIngestionException("unsupportedSyntax");
            extensions.Add(string.Concat(value.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + ('a' - 'A')) : c)));
        }
        foreach (string pattern in IgnoreGlobs) _ = new FolderGlob(pattern, caseSensitive, tables);
        return this with { IncludeExts = extensions };
    }

    public bool Equals(FolderRules? other) => other is not null && Limits == other.Limits &&
        StringComparer.Ordinal.Equals(EncodingFallback, other.EncodingFallback) &&
        IncludeExts.SequenceEqual(other.IncludeExts, StringComparer.Ordinal) &&
        IgnoreGlobs.SequenceEqual(other.IgnoreGlobs, StringComparer.Ordinal);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(Limits);
        hash.Add(EncodingFallback, StringComparer.Ordinal);
        foreach (string extension in IncludeExts) hash.Add(extension, StringComparer.Ordinal);
        hash.Add(IncludeExts.Count);
        foreach (string pattern in IgnoreGlobs) hash.Add(pattern, StringComparer.Ordinal);
        return hash.ToHashCode();
    }
}

public sealed record FileStamp(string Identity, long MtimeNs, long SizeBytes);
public sealed record PageBoundary(int Page, int Start, int End);

public sealed record CanonicalDocument
{
    private IReadOnlyList<PageBoundary> _pages = Array.Empty<PageBoundary>();
    private IReadOnlyList<string> _sheetNames = Array.Empty<string>();
    public string Text { get; init; }
    public string? Title { get; init; }
    public string Kind { get; init; }
    public IReadOnlyList<PageBoundary> Pages { get => _pages; init => _pages = IngestionValues.Snapshot(value); }
    public IReadOnlyList<string> SheetNames { get => _sheetNames; init => _sheetNames = IngestionValues.Snapshot(value); }
    public string? Encoding { get; init; }

    public CanonicalDocument(string text, string? title, string kind, IReadOnlyList<PageBoundary> pages,
        IReadOnlyList<string> sheetNames, string? encoding)
    {
        Text = text;
        Title = title;
        Kind = kind;
        Pages = pages;
        SheetNames = sheetNames;
        Encoding = encoding;
    }
}

public sealed record DecodedText(string Text, string Encoding);
public sealed record FolderObservation(string RelPath, FileStamp Stamp, string Kind, string? SkipReason, string? ContentHash);
public sealed record ScanTicket(long FolderId, long Generation, JobFence Fence);

/// <summary>
/// One entry of a batched scan commit (contract ingestion-scan-perf-v1 §1). <see cref="KnownOnly"/> marks an interior
/// link: it is recorded (skipped/ignored) only when the path already has a source.
/// </summary>
public sealed record FolderScanObservation(FolderObservation Observation, bool KnownOnly)
{
    public static FolderScanObservation File(FolderObservation observation) => new(observation, false);
    public static FolderScanObservation InteriorLink(string relPath, FileStamp stamp) =>
        new(new FolderObservation(relPath, stamp, "skipped", "ignored", null), true);
}

/// <summary>
/// Outcome of one batched scan commit: <see cref="Unchanged"/> rows only had seen_generation bumped; <see cref="Changed"/>
/// rows took the per-file path. Interior links without a source count as neither.
/// </summary>
public sealed record FolderObserveBatchResult(int Changed, int Unchanged);

public sealed record ScanCompletion
{
    private IReadOnlyList<string> _completed = Array.Empty<string>();
    private IReadOnlyList<string> _incomplete = Array.Empty<string>();
    public IReadOnlyList<string> Completed { get => _completed; init => _completed = IngestionValues.Snapshot(value); }
    public IReadOnlyList<string> Incomplete { get => _incomplete; init => _incomplete = IngestionValues.Snapshot(value); }
    public bool RootUnavailable { get; init; }
    public string? Error { get; init; }

    public ScanCompletion(IReadOnlyList<string> completed, IReadOnlyList<string> incomplete,
        bool rootUnavailable, string? error)
    {
        Completed = completed;
        Incomplete = incomplete;
        RootUnavailable = rootUnavailable;
        Error = error;
    }
}

public sealed record ExtractionRequest(long SourceId, long FolderId, string RelPath, FileStamp Stamp, string Hash, FolderRules Rules);
public sealed record EmbeddingSelection(string ProviderId, string EndpointRevision, string Model, string? ModelDigest,
    int? Dims, string Normalization, string QueryFormatVersion, string DocFormatVersion, string ChunkerVersion);

public sealed record PublicationMetadata
{
    private IReadOnlyList<PageBoundary> _pages = Array.Empty<PageBoundary>();
    public string? Encoding { get; init; }
    public string? Lang { get; init; }
    public string? CoverageJSON { get; init; }
    public string DescriptorJSON { get; init; }
    public IReadOnlyList<PageBoundary> Pages { get => _pages; init => _pages = IngestionValues.Snapshot(value); }

    public PublicationMetadata(string? encoding, string? lang, string? coverageJSON,
        string descriptorJSON, IReadOnlyList<PageBoundary> pages)
    {
        Encoding = encoding;
        Lang = lang;
        CoverageJSON = coverageJSON;
        DescriptorJSON = descriptorJSON;
        Pages = pages;
    }
}

internal static class IngestionValues
{
    internal static IReadOnlyList<T> Snapshot<T>(IReadOnlyList<T> values)
    {
        ArgumentNullException.ThrowIfNull(values);
        return Array.AsReadOnly(values.ToArray());
    }
}
