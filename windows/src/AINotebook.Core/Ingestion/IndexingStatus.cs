using AINotebook.Core.Providers;

namespace AINotebook.Core.Ingestion;

/// <summary>Why background embedding cannot run for a notebook (contract <c>indexing-status-v1</c> §4).</summary>
public enum EmbeddingAvailability
{
    Ready,
    NoProvider,
    ProviderDisabled,
    NoModel,
    ConsentRequired,
    ProviderHasNoEmbeddings,
    CredentialUnavailable
}

/// <summary>A captured embedding session, or the reason there is none (never a bare null).</summary>
public sealed record EmbeddingSessionResolution
{
    private EmbeddingSessionResolution(FolderEmbeddingSession? session, EmbeddingAvailability availability)
    {
        Session = session;
        Availability = availability;
    }

    public FolderEmbeddingSession? Session { get; }
    public EmbeddingAvailability Availability { get; }

    public static EmbeddingSessionResolution Ready(FolderEmbeddingSession session) =>
        new(session ?? throw new ArgumentNullException(nameof(session)), EmbeddingAvailability.Ready);

    public static EmbeddingSessionResolution Unavailable(EmbeddingAvailability reason) =>
        reason == EmbeddingAvailability.Ready
            ? throw new ArgumentException("An unavailable resolution needs a reason.", nameof(reason))
            : new(null, reason);
}

/// <summary>One folder of the notebook as the status derivation sees it.</summary>
/// <param name="ScanState"><c>idle|scanning|partial|error|unavailable</c>.</param>
/// <param name="FilesSeen">Files observed so far in the running scan (scanning folders only).</param>
public sealed record IndexingFolderInput(long FolderId, string ScanState, string? LastScanError, int? FilesSeen);

/// <summary>The notebook's newest embed job; <paramref name="Bootstrap"/> = notebook-target dimension bootstrap.</summary>
public sealed record IndexingEmbedJobInput(string State, int Attempts, long? NextRetryAt, string? ErrorCode, bool Bootstrap)
{
    /// <summary>Waiting for an automatic retry deadline (contract §2.4).</summary>
    public bool IsWaiting(long now) => State switch
    {
        "failed" => Attempts < 5 && NextRetryAt is not null,
        "queued" => NextRetryAt is long retry && retry > now,
        _ => false
    };
}

/// <summary>Snapshot read by the store in one batch plus the runtime facts (contract §1).</summary>
public sealed record IndexingInputs
{
    public long Now { get; init; }
    public string? RuntimeError { get; init; }
    public EmbeddingAvailability EmbeddingAvailability { get; init; } = EmbeddingAvailability.Ready;
    public IReadOnlyList<IndexingFolderInput> Folders { get; init; } = [];
    public int ScanJobsPending { get; init; }
    public int ExtractQueued { get; init; }
    public int ExtractRunning { get; init; }
    public int SourcesTotal { get; init; }
    public int SourcesReady { get; init; }
    public int SourcesError { get; init; }
    public bool NeedsEmbedding { get; init; }
    public IndexingEmbedJobInput? EmbedJob { get; init; }
    public int EmbedChunksDone { get; init; }
    public int EmbedChunksTotal { get; init; }
    /// <summary>Extraction admission's memory-pressure level (runtime fact, addendum §6).</summary>
    public MemoryPressureLevel MemoryPressure { get; init; } = MemoryPressureLevel.Normal;
}

/// <summary>Status phase; priority order is the contract's derivation order.</summary>
public enum IndexingPhase
{
    /// <summary>"Checking folder… N files" (<see cref="IndexingStatus.FilesSeen"/> null = unknown).</summary>
    Scanning,
    /// <summary>"Processing files d / t" (sources).</summary>
    Extracting,
    /// <summary>"Indexing d / t chunks"; null counts = indeterminate; <see cref="IndexingStatus.Preparing"/> = bootstrap.</summary>
    Embedding,
    Retrying,
    Blocked,
    Ready,
    /// <summary>Full-text search only; "Build index" → RetryIndexingNowAsync.</summary>
    LexicalOnly,
    Empty
}

public enum IndexingBlockedReason
{
    /// <summary>No provider, no model, or a provider without embeddings → Settings › Providers.</summary>
    NoEmbeddingModel,
    ProviderDisabled,
    ConsentRequired,
    /// <summary>The provider's API key could not be loaded (credential store).</summary>
    CredentialUnavailable,
    /// <summary>Terminal embed failure (<see cref="IndexingStatus.ErrorCode"/>); "Retry now".</summary>
    IndexFailed,
    /// <summary>The ingestion runtime failed to start (<see cref="IndexingStatus.ErrorCode"/>); "Retry now".</summary>
    RuntimeFailed
}

/// <summary>The embed job's pending automatic retry; <paramref name="RetryInSeconds"/> = max(0, retryAt − now).</summary>
public sealed record IndexingRetry(string Code, long RetryAt, int Attempt, long RetryInSeconds);

/// <summary>A folder whose last scan did not complete cleanly (<c>partial|error|unavailable</c>).</summary>
public sealed record IndexingScanWarning(long FolderId, string State, string? Error);

/// <summary>
/// Per-notebook indexing status (contract <c>indexing-status-v1</c>). <paramref name="MemoryPressure"/>: extracting only —
/// system memory pressure slows (warning) or pauses (critical) extraction; null otherwise (addendum §6).
/// </summary>
/// <para><paramref name="ScanInProgress"/>: a folder scan is running or queued while this phase is shown (scanning, or the
/// extracting/embedding work it no longer hides, addendum §7); <paramref name="FilesSeen"/> is then the scan's files seen.</para>
public sealed record IndexingStatus(IndexingPhase Phase, int? FilesSeen, int? Done, int? Total, bool Preparing,
    IndexingRetry? Retry, IndexingBlockedReason? BlockedReason, string? ErrorCode, int SourceErrors,
    IReadOnlyList<IndexingScanWarning> ScanWarnings, MemoryPressureLevel? MemoryPressure = null, bool ScanInProgress = false)
{
    /// <summary>Scanning, extracting, embedding or retrying.</summary>
    public bool IsActive => Phase is IndexingPhase.Scanning or IndexingPhase.Extracting or IndexingPhase.Embedding
        or IndexingPhase.Retrying;
}

/// <summary>The last finished scan of a folder (runtime memory) for "No changes · N files up to date".</summary>
/// <param name="ChangedFiles">Extract jobs queued for the folder's sources while the scan ran.</param>
/// <param name="FilesSeen">Eligible files seen in the folder's current scan generation.</param>
/// <param name="FinishedAt">Lease-clock seconds.</param>
public sealed record FolderScanOutcome(long FolderId, int ChangedFiles, int FilesSeen, long FinishedAt);

/// <summary>The pure derivation (contract §2) and contract names.</summary>
public static class IndexingStatusDerivation
{
    private static readonly string[] WarningStates = ["partial", "error", "unavailable"];

    /// <summary>Contract (camelCase) name of a phase, blocked reason or availability.</summary>
    public static string ContractName<T>(T value) where T : struct, Enum
    {
        string name = value.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    /// <summary>First match wins.</summary>
    public static IndexingStatus Derive(IndexingInputs input)
    {
        ArgumentNullException.ThrowIfNull(input);
        var warnings = input.Folders.Where(f => WarningStates.Contains(f.ScanState, StringComparer.Ordinal))
            .Select(f => new IndexingScanWarning(f.FolderId, f.ScanState, f.LastScanError)).ToArray();
        IndexingStatus Status(IndexingPhase phase, int? filesSeen = null, int? done = null, int? total = null,
            bool preparing = false, IndexingRetry? retry = null, IndexingBlockedReason? reason = null, string? code = null,
            MemoryPressureLevel? pressure = null) =>
            new(phase, filesSeen, done, total, preparing, retry, reason, code, input.SourcesError, warnings, pressure);

        if (input.RuntimeError is { } runtimeError)
            return Status(IndexingPhase.Blocked, reason: IndexingBlockedReason.RuntimeFailed, code: runtimeError);
        var scanning = input.Folders.Where(f => f.ScanState == "scanning").ToArray();
        if (scanning.Length > 0 || input.ScanJobsPending > 0)
        {
            var seen = scanning.Where(f => f.FilesSeen is not null).Select(f => f.FilesSeen!.Value).ToArray();
            int? filesSeen = seen.Length == 0 ? null : seen.Sum();
            // Addendum §7: extraction/embedding progress is never hidden behind a running scan.
            return Work() is { } work ? work with { FilesSeen = filesSeen, ScanInProgress = true }
                : Status(IndexingPhase.Scanning, filesSeen: filesSeen) with { ScanInProgress = true };
        }
        if (Work() is { } due) return due;

        // Steps 3–4 without retrying: extraction or a due embed job.
        IndexingStatus? Work()
        {
            if (input.ExtractQueued + input.ExtractRunning > 0)
                return Status(IndexingPhase.Extracting, done: Math.Min(input.SourcesTotal, input.SourcesReady + input.SourcesError),
                    total: input.SourcesTotal,
                    pressure: input.MemoryPressure == MemoryPressureLevel.Normal ? null : input.MemoryPressure);
            var embed = input.EmbedJob;
            if (embed is null || embed.IsWaiting(input.Now) || embed.State is not ("running" or "queued")) return null;
            if (embed.Bootstrap) return Status(IndexingPhase.Embedding, preparing: true);
            int total = input.EmbedChunksTotal;
            return total <= 0 ? Status(IndexingPhase.Embedding)
                : Status(IndexingPhase.Embedding, done: Math.Min(total, input.EmbedChunksDone), total: total);
        }

        var job = input.EmbedJob;
        if (job is not null && job.IsWaiting(input.Now) && job.NextRetryAt is long retryAt)
            return Status(IndexingPhase.Retrying, retry: new IndexingRetry(job.ErrorCode ?? "unknown", retryAt, job.Attempts,
                Math.Max(0, retryAt - input.Now)));
        if (input.SourcesTotal == 0) return Status(IndexingPhase.Empty);
        IndexingBlockedReason? unavailable = input.EmbeddingAvailability switch
        {
            EmbeddingAvailability.Ready => null,
            EmbeddingAvailability.ProviderDisabled => IndexingBlockedReason.ProviderDisabled,
            EmbeddingAvailability.ConsentRequired => IndexingBlockedReason.ConsentRequired,
            EmbeddingAvailability.CredentialUnavailable => IndexingBlockedReason.CredentialUnavailable,
            _ => IndexingBlockedReason.NoEmbeddingModel
        };
        if (unavailable is not null) return Status(IndexingPhase.Blocked, reason: unavailable);
        if (job is { State: "failed" } && !job.IsWaiting(input.Now) && input.NeedsEmbedding)
            return Status(IndexingPhase.Blocked, reason: IndexingBlockedReason.IndexFailed, code: job.ErrorCode ?? "unknown");
        return Status(input.NeedsEmbedding ? IndexingPhase.LexicalOnly : IndexingPhase.Ready);
    }
}
