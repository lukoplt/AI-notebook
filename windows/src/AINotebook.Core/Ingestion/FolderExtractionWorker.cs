using System.Globalization;
using System.Security.Cryptography;
using AINotebook.Core.Extractors;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>Result of one fenced publication attempt.</summary>
public sealed record FolderPublicationResult(bool Accepted, long? RevisionId, string? Error);

/// <summary>
/// Everything extracted from one snapshot, before publication. Detections are null when unavailable; they carry the
/// label-only decisions (identical to the diagnostic detector's label and reason).
/// </summary>
internal sealed record FolderExtractionDraft(RevisionDraft Revision, IReadOnlyList<RevisionChunkDraft> Chunks,
    IReadOnlyList<LanguageTextDecision?> Detections, LanguageAggregate? Document, PublicationMetadata Metadata);

/// <summary>
/// Executes one queue-claimed extract job: bounded snapshot through the validated native handle, admitted-type
/// extraction of that private copy, scalar chunks, one document detection on canonical text plus per-chunk
/// detection, then a re-stat and re-hash of the original before one fenced publication transaction.
/// It never calls BeginExtraction; codec/limit/IO failures propagate so the queue fails the claimed fence.
/// </summary>
public sealed class FolderExtractionWorker
{
    private readonly NotebookStore _store;
    private readonly IFolderFileSystem _fileSystem;
    private readonly LanguageDetector _detector;
    private readonly IIngestLeaseClock _clock;
    private readonly Func<long, Task<EmbeddingSelection?>> _embeddingSelection;
    private readonly Func<Uri, SourceType, FolderRules, CancellationToken, Task<CanonicalDocument>> _extract;
    private readonly ITextExtractor? _web;

    /// <param name="web">Re-fetches a loose web source's automatic retry; null = web retries are unavailable.</param>
    public FolderExtractionWorker(NotebookStore store, IFolderFileSystem fileSystem, LanguageDetector detector,
        IIngestLeaseClock clock, Func<long, Task<EmbeddingSelection?>> embeddingSelection,
        Func<Uri, SourceType, FolderRules, CancellationToken, Task<CanonicalDocument>> extract, ITextExtractor? web = null)
    {
        _web = web;
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _detector = detector ?? throw new ArgumentNullException(nameof(detector));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _embeddingSelection = embeddingSelection ?? throw new ArgumentNullException(nameof(embeddingSelection));
        _extract = extract ?? throw new ArgumentNullException(nameof(extract));
    }

    public async Task ExecuteAsync(IngestJob job, JobFence fence, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(job);
        ArgumentNullException.ThrowIfNull(fence);
        try
        {
            // A loose source's automatic retry re-reads its own file or URL (ingestion-retry-cap-v1 §3a).
            if (SourceId(job) is long looseId && _store.LooseExtractionTarget(looseId) is { } loose)
            {
                await RunLooseAsync(loose, job, fence, ct).ConfigureAwait(false);
                return;
            }
            var context = Load(job, fence);
            if (context is null) return;
            using var snapshot = Snapshot(context, ct);
            var draft = await ExtractAsync(context, snapshot, ct).ConfigureAwait(false);
            await PublishAsync(context, snapshot, draft, ct).ConfigureAwait(false);
        }
        finally { RefillSpreadsheetUpgrades(job); }
    }

    /// <summary>A finished spreadsheet-upgrade job tops the throttled batch up again (<c>ingestion-reextract-v1</c> §7),
    /// so the upgrade drains with extraction instead of waiting for the next periodic reconciliation. Best effort.</summary>
    private void RefillSpreadsheetUpgrades(IngestJob job)
    {
        if (!job.Draft.OptionsJson.Contains("\"" + ExtractorRevision.SpreadsheetOptionsKey + "\"", StringComparison.Ordinal)) return;
        try { _store.RequeueSpreadsheetUpgrades(_clock.Now); }
        catch (Exception error) when (error is not OutOfMemoryException) { }
    }

    /// <summary>
    /// One automatic attempt for a loose source: the bounded canonical pipeline on its local file (as IngestionService
    /// ingests it), or a re-fetch of a web source. Errors propagate so the queue records a fenced failure; a source with
    /// nothing to re-read ends its job without an attempt.
    /// </summary>
    internal async Task RunLooseAsync(LooseExtractionTarget target, IngestJob job, JobFence fence, CancellationToken ct)
    {
        if (target.File is { } path)
        {
            var rules = FolderRules.Defaults;
            var info = new FileInfo(path);
            if (info.Exists && info.Length > rules.Limits.FileBytes) throw new FolderIngestionException("fileLimit");
            var url = new Uri(path);
            var document = await _extract(url, target.Kind, rules, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            string hash;
            long size;
            await using (var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, useAsync: true))
            {
                size = file.Length;
                hash = Convert.ToHexString(await SHA256.HashDataAsync(file, ct).ConfigureAwait(false)).ToLowerInvariant();
            }
            var draft = Prepare(document, hash, size, Path.GetFileName(path), _detector, rules.Limits);
            var selection = await PublishableSelectionAsync(target.NotebookId, _embeddingSelection, ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            _store.PublishLooseExtraction(target.SourceId, draft.Revision, draft.Chunks, draft.Metadata, selection, fence, _clock.Now);
            return;
        }
        // A URL is fetched only for an explicit user retry unless background web retries are on (§3a).
        if (target.Url is { } address && _web is not null
            && (ExtractionRetryBudget.BackgroundWebRetry || RetryBudgetSQL.UserInitiated(job)))
        {
            var extracted = await _web.ExtractAsync(address, target.Kind).WaitAsync(ct).ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            var (revision, chunks) = IngestionService.PrepareRevision(extracted, target.Kind);
            _store.CommitExtraction(target.SourceId, revision, chunks, fence, _clock.Now);
            return;
        }
        _store.AbandonLooseExtraction(fence, _clock.Now);
    }

    internal sealed record Context(IngestJob Job, JobFence Fence, ExtractionRequest Request, FolderSource Folder, long NotebookId);

    /// <summary>A missing, ineligible or unavailable source cancels the current job.</summary>
    internal Context? Load(IngestJob job, JobFence fence)
    {
        long? sourceId = SourceId(job);
        var request = sourceId is long id ? _store.ExtractionRequest(id) : null;
        var source = sourceId is long sid ? _store.Source(sid) : null;
        var folder = request is null ? null : _store.Folder(request.FolderId);
        if (request is null || source is null || folder is null || !source.Eligible || source.Availability != "present")
        {
            _store.CancelJob(fence, _clock.Now);
            return null;
        }
        return new Context(job, fence, request, folder, folder.NotebookId);
    }

    internal FolderFileSnapshot Snapshot(Context context, CancellationToken ct) =>
        _fileSystem.Snapshot(context.Folder, context.Request.RelPath, context.Request.Rules.Limits.FileBytes, ct);

    internal async Task<FolderExtractionDraft> ExtractAsync(Context context, FolderFileSnapshot snapshot, CancellationToken ct)
    {
        string extension = FolderRuleClassifier.Extension(context.Request.RelPath);
        var document = await _extract(new Uri(snapshot.Path), TypeFor(extension), context.Request.Rules, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        // Detection and chunking are CPU-bound background work (addendum A §A.5).
        return BackgroundPriority.Run(() => Prepare(document, snapshot.Hash, snapshot.Stamp.SizeBytes, context.Request.RelPath,
            _detector, context.Request.Rules.Limits));
    }

    /// <summary>Pure pipeline from a canonical document to a publication draft.</summary>
    internal static FolderExtractionDraft Prepare(CanonicalDocument document, string contentHash, long sizeBytes,
        string relPath, LanguageDetector detector, IngestionLimits limits)
    {
        // Label-only detection: the same decisions as DetectDocument/DetectText without diagnostics.
        var documentResult = detector.DecideDocument(document.Text);
        var detections = new List<LanguageTextDecision?>();
        var chunks = ScalarChunker.Bounded(document.Text, document.Pages, limits.Chunks).Select(chunk =>
        {
            // Canonical spans stay in original scalar offsets; detector normalization never moves them.
            var result = detector.DecideText(chunk.Text);
            detections.Add(result);
            var language = ChunkLanguage.Resolve(result?.Label, result?.Reason, documentResult?.Label);
            return chunk with { Lang = language.Lang, LangInherited = language.LangInherited };
        }).ToArray();
        string? lang = documentResult?.Label;
        string filename = relPath[(relPath.LastIndexOf('/') + 1)..];
        var metadata = new PublicationMetadata(document.Encoding, lang,
            documentResult is null ? null : SourceDescriptor.CoverageJson(documentResult),
            SourceDescriptor.Make(document, filename, sizeBytes, lang).ToJson(), document.Pages);
        return new FolderExtractionDraft(new RevisionDraft(contentHash, document.Text, TextFormatVersion(document.Kind), 2),
            chunks, detections, documentResult, metadata);
    }

    /// <summary>Spreadsheets carry the compact spreadsheet text (<c>ingestion-xlsx-v2</c>); every other kind format 1.</summary>
    internal static int TextFormatVersion(string kind) => kind == "xlsx" ? SpreadsheetText.FormatVersion : 1;

    /// <summary>
    /// Re-stats and re-hashes the original; any change requests fresh extraction instead of publishing.
    /// </summary>
    internal async Task<FolderPublicationResult> PublishAsync(Context context, FolderFileSnapshot snapshot,
        FolderExtractionDraft draft, CancellationToken ct)
    {
        var original = _fileSystem.Hash(context.Folder, context.Request.RelPath, context.Request.Rules.Limits.FileBytes, ct);
        if (original.Stamp != snapshot.Stamp || !StringComparer.Ordinal.Equals(original.Sha256, snapshot.Hash))
        {
            _store.RequestFreshExtraction(context.Request.SourceId, context.Fence, _clock.Now);
            return new FolderPublicationResult(false, null, "changedDuringExtraction");
        }
        var selection = await PublishableSelectionAsync(context.NotebookId, _embeddingSelection, ct).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        // The request keeps the persisted observation stamp: publication is rejected if a newer observation
        // was committed meanwhile. The committed hash is the hash of the bytes actually extracted.
        var request = context.Request with { Hash = snapshot.Hash };
        var revision = _store.PublishFolderExtraction(request, draft.Revision, draft.Chunks, draft.Metadata, selection,
            context.Fence, _clock.Now);
        return new FolderPublicationResult(revision is not null, revision?.Id, null);
    }

    /// <summary>
    /// A selection lookup failure (e.g. a credential-store error) never fails extraction: the revision publishes without
    /// an embed job and the indexing status shows why. Only cancellation propagates.
    /// </summary>
    internal static async Task<EmbeddingSelection?> PublishableSelectionAsync(long notebookId,
        Func<long, Task<EmbeddingSelection?>> lookup, CancellationToken ct)
    {
        try { return await lookup(notebookId).ConfigureAwait(false); }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception) { return null; }
    }

    /// <summary>The extraction kind of a folder file extension (SourceTypeExtensions.Detect); unknown reads as text.</summary>
    internal static SourceType TypeFor(string extension) => SourceTypeExtensions.Detect("f." + extension) ?? SourceType.Text;

    private static long? SourceId(IngestJob job) =>
        job.Draft.Kind == "extract" && job.Draft.Target.StartsWith("source:", StringComparison.Ordinal) &&
        long.TryParse(job.Draft.Target["source:".Length..], NumberStyles.None, CultureInfo.InvariantCulture, out long id)
            ? id : null;
}
