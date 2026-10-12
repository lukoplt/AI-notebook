namespace AINotebook.Core.Storage;

public sealed record FolderIdentity(string VolumeId, IReadOnlyList<string> Components, string RootFileId);

public interface IFolderPathIdentity
{
    FolderIdentity Resolve(string rootPath);
}

public sealed record FolderDraft(string RootPath, string DisplayName,
    IReadOnlyList<string> IncludeExts, IReadOnlyList<string> IgnoreGlobs,
    string LimitsJSON, string EncodingFallback, bool WatchEnabled);

public sealed record FolderSource(long Id, long NotebookId, FolderDraft Draft,
    FolderIdentity Identity, string ScanState, long ScanGeneration,
    long? LastFullScanAt, string? LastScanError, long CreatedAt);

public sealed record ScanItem(long FolderId, string RelPath, string Kind, string? SkipReason,
    long? Mtime, long? SizeBytes, long SeenGeneration);

public sealed record CoverageSnapshot(int Searchable, int Pending, int Error, int Skipped,
    int Missing, int Unavailable, int RefreshPending, int RefreshError, bool IsLowerBound,
    int NotSearchable = 0, int Current = 0);

public sealed record ProviderModelLimits(string ProviderId, string Model, int? ContextWindow,
    int RuntimeContext, int MaxOutputTokens, string Source);
