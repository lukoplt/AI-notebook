using System.Globalization;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Runs claimed embed jobs with one immutable captured session: a dimension bootstrap (notebook target) embeds
/// the first real corpus batch, then fenced generation batches follow until reconciliation-then-activation.
/// The active generation is never modified by a build. Each new background batch waits for the chat gate
/// immediately before its provider call and rechecks the lease afterwards; question embeddings are never gated.
/// </summary>
public sealed class FolderIndexCoordinator
{
    private readonly NotebookStore _store;
    private readonly IngestionAdmission _admission;
    private readonly IIngestLeaseClock _clock;
    private readonly Func<long, CancellationToken, Task<FolderEmbeddingSession?>> _session;
    private readonly Func<long, Task<EmbeddingSelection?>> _selectedSelection;
    private int _waitingForChat;

    public FolderIndexCoordinator(NotebookStore store, IngestionAdmission admission, IIngestLeaseClock clock,
        Func<long, CancellationToken, Task<FolderEmbeddingSession?>> session,
        Func<long, Task<EmbeddingSelection?>> selectedSelection)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _admission = admission ?? throw new ArgumentNullException(nameof(admission));
        _clock = clock ?? throw new ArgumentNullException(nameof(clock));
        _session = session ?? throw new ArgumentNullException(nameof(session));
        _selectedSelection = selectedSelection ?? throw new ArgumentNullException(nameof(selectedSelection));
    }

    /// <summary>
    /// Chunks per background provider request. Larger requests amortize the per-batch store work and HTTP round
    /// trip (Ollama <c>/api/embed</c> and OpenAI embeddings both take an input array); 64 stays far below provider limits.
    /// </summary>
    public const int DefaultBatchSize = 64;

    public int BatchSize { get; init; } = DefaultBatchSize;

    public static int ValidatedDimensions(float[][] vectors, int count)
    {
        if (vectors is null || vectors.Length != count || vectors.Length == 0 || vectors[0] is null || vectors[0].Length == 0)
            throw new FolderIngestionException("invalidVector");
        int dims = vectors[0].Length;
        if (vectors.Any(v => v is null || v.Length != dims || v.Any(x => !float.IsFinite(x)) || !v.Any(x => x != 0)))
            throw new FolderIngestionException("invalidVector");
        return dims;
    }

    public async Task ExecuteAsync(IngestJob job, JobFence fence, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(job);
        ArgumentNullException.ThrowIfNull(fence);
        var (notebookId, options) = Describe(job);
        var session = await _session(notebookId, ct).ConfigureAwait(false);
        // Restart may only continue with a session matching the durable options.
        if (session is null || !IngestionGenerationSQL.SameSpace(session.Selection, options.Selection))
        {
            _store.InvalidateEmbeddingSelection(fence, _clock.Now);
            return;
        }
        // Keyset position of the last consumed candidate (embedding-plan-v1 §4).
        EmbeddingCursor? cursor = null;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var current = _store.Job(job.Id);
            if (current is not { State: "running" } || current.LeaseToken != fence.LeaseToken) return;
            if (!await StillCurrentAsync(notebookId, options.Selection).ConfigureAwait(false))
            {
                _store.InvalidateEmbeddingSelection(fence, _clock.Now);
                return;
            }
            IReadOnlyList<FolderEmbeddingItem> batch;
            IReadOnlyList<EmbeddingDuplicate> duplicates;
            if (current.Draft.Target.StartsWith("notebook:", StringComparison.Ordinal))
            {
                cursor = null;
                (batch, duplicates) = BootstrapRound(TargetId(current.Draft.Target));
            }
            else
            {
                var round = _store.CaptureEmbeddingRound(TargetId(current.Draft.Target), BatchSize, cursor, fence, _clock.Now);
                if (round is null) return; // Fenced out or the build ended.
                if (round.Items.Count == 0 && round.Copied == 0)
                {
                    // Nothing after the cursor: look once more from the start before concluding.
                    bool startedAtCursor = cursor is not null && !round.Reset;
                    cursor = null;
                    if (startedAtCursor) continue;
                }
                else
                {
                    cursor = round.Cursor;
                    if (round.Items.Count == 0) continue;
                }
                (batch, duplicates) = (round.Items, round.Joined);
            }
            if (batch.Count == 0)
            {
                if (await FinishOrActivateAsync(current, fence).ConfigureAwait(false)) return;
                if (SelectBatch(_store.Job(job.Id) ?? current).Count == 0) return; // Fenced out or nothing left to do.
                continue;
            }
            Interlocked.Increment(ref _waitingForChat);
            try { await _admission.WaitForBackgroundBatchAsync(ct).ConfigureAwait(false); }
            finally { Interlocked.Decrement(ref _waitingForChat); }
            // Waiting for chat may span renewals; never send for a lost lease.
            if (!_store.RenewJob(fence, _clock.Now)) return;
            float[][] vectors;
            try
            {
                var inputs = batch.Select(item => item.Text).ToArray();
                if (session.Selection.DocFormatVersion == EmbeddingQueryFormat.V2)
                {
                    // embedding-raw-format-v2 §3: each document input starts with its source's path line.
                    // Same-text duplicates (embedding-plan-v1 §5) reuse the first occurrence's vector.
                    var headers = _store.EmbeddingHeaders(batch.Select(item => item.ChunkId).ToArray());
                    inputs = batch.Select(item => headers.GetValueOrDefault(item.ChunkId, "") + item.Text).ToArray();
                }
                vectors = await session.EmbedAsync(inputs, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception error)
            {
                _store.FailEmbeddingJob(fence, FailureCode(error), _clock.Now);
                return;
            }
            var outcome = await CommitBatchAsync(current, fence, batch, vectors, duplicates).ConfigureAwait(false);
            if (outcome is BatchOutcome.Failed or BatchOutcome.Invalidated or BatchOutcome.Fenced) return;
        }
    }

    internal enum BatchOutcome { Committed, Retargeted, Stale, Fenced, Failed, Invalidated }

    internal (long NotebookId, IngestionGenerationSQL.EmbedOptions Options) Describe(IngestJob job)
    {
        var options = IngestionGenerationSQL.ReadOptions(job.Draft.OptionsJson);
        if (job.Draft.Kind != "embed" || options is null) throw new FolderIngestionException("unsupportedSyntax");
        string target = job.Draft.Target;
        long notebookId = target.StartsWith("notebook:", StringComparison.Ordinal) ? TargetId(target)
            : _store.Generation(TargetId(target))?.NotebookId ?? throw new StorageV19Exception("notFound");
        return (notebookId, options);
    }

    /// <summary>
    /// The bootstrap round (no generation yet): embeddable published chunks in build order; identical texts join one
    /// input (embedding-plan-v1 §5 rules 2–4).
    /// </summary>
    internal (IReadOnlyList<FolderEmbeddingItem> Items, IReadOnlyList<EmbeddingDuplicate> Duplicates) BootstrapRound(long notebookId)
    {
        var items = new List<FolderEmbeddingItem>();
        var inputs = new Dictionary<string, int>(StringComparer.Ordinal);
        var duplicates = new List<EmbeddingDuplicate>();
        foreach (var candidate in _store.NextBootstrapBatch(notebookId, EmbeddingPlan.RoundScanFactor * BatchSize))
        {
            if (inputs.TryGetValue(candidate.Text, out int index))
                duplicates.Add(new EmbeddingDuplicate(candidate.ChunkId, candidate.RevisionId, items[index].ChunkId));
            else if (items.Count < BatchSize)
            {
                inputs[candidate.Text] = items.Count;
                items.Add(candidate);
            }
            else break;
        }
        return (items, duplicates);
    }

    /// <summary>The next batch for the job's current target: bootstrap corpus or pending generation chunks.</summary>
    internal IReadOnlyList<FolderEmbeddingItem> SelectBatch(IngestJob job)
    {
        string target = job.Draft.Target;
        return target.StartsWith("notebook:", StringComparison.Ordinal)
            ? _store.NextBootstrapBatch(TargetId(target), BatchSize)
            : _store.NextEmbeddingBatch(TargetId(target), BatchSize);
    }

    /// <summary>
    /// Validates a provider response for the captured batch and commits it through the job's live fence.
    /// Invalid shapes fail the attempt (a terminal fifth failure fails the building generation).
    /// </summary>
    internal async Task<BatchOutcome> CommitBatchAsync(IngestJob job, JobFence fence, IReadOnlyList<FolderEmbeddingItem> batch,
        float[][] vectors, IReadOnlyList<EmbeddingDuplicate>? duplicates = null)
    {
        var (notebookId, options) = Describe(job);
        int dims;
        try { dims = ValidatedDimensions(vectors, batch.Count); }
        catch (FolderIngestionException error)
        {
            _store.FailEmbeddingJob(fence, error.Code, _clock.Now);
            return BatchOutcome.Failed;
        }
        var chunkIds = batch.Select(item => item.ChunkId).ToArray();
        var revisionIds = batch.Select(item => item.RevisionId).ToArray();
        if (job.Draft.Target.StartsWith("notebook:", StringComparison.Ordinal))
        {
            if (!await StillCurrentAsync(notebookId, options.Selection).ConfigureAwait(false))
            {
                _store.InvalidateEmbeddingSelection(fence, _clock.Now);
                return BatchOutcome.Invalidated;
            }
            var created = _store.CommitBootstrapBatch(notebookId, options.Selection, dims, chunkIds, revisionIds, vectors,
                options.CopyExisting, fence, _clock.Now, duplicates);
            // Null: fenced out, or every captured row went stale and a fresh batch is selected under the same job.
            return created is null ? BatchOutcome.Stale : BatchOutcome.Retargeted;
        }
        long generationId = TargetId(job.Draft.Target);
        if (_store.Generation(generationId) is not { } generation || generation.Identity.Dims != dims)
        {
            _store.FailEmbeddingJob(fence, "invalidVector", _clock.Now);
            return BatchOutcome.Failed;
        }
        return _store.CommitEmbeddingBatch(generationId, chunkIds, revisionIds, vectors, fence, _clock.Now, duplicates)
            ? BatchOutcome.Committed : BatchOutcome.Fenced;
    }

    /// <summary>
    /// No batch left: a bootstrap without corpus completes through its fence; a build reconciles and activates if the
    /// selected identity is unchanged. True when the job finished.
    /// </summary>
    internal async Task<bool> FinishOrActivateAsync(IngestJob job, JobFence fence)
    {
        var (notebookId, options) = Describe(job);
        if (job.Draft.Target.StartsWith("notebook:", StringComparison.Ordinal))
            return _store.CompleteJob(fence, _clock.Now);
        long generationId = TargetId(job.Draft.Target);
        var generation = _store.Generation(generationId);
        if (generation is not { State: "building" }) return true;
        var selected = await _selectedSelection(notebookId).ConfigureAwait(false);
        if (selected is null || !IngestionGenerationSQL.SameSpace(selected, options.Selection) ||
            selected.Dims is int dims && dims != generation.Identity.Dims)
        {
            _store.InvalidateEmbeddingSelection(fence, _clock.Now);
            return true;
        }
        return _store.ActivateBuiltGeneration(generationId, IngestionGenerationSQL.Identity(selected, generation.Identity.Dims),
            fence, _clock.Now);
    }

    /// <summary>Explicit re-index with verified dimensions; returns the new building generation ID.</summary>
    public Task<long> ReindexAsync(long notebookId, GenerationIdentity identity, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(_store.RequestReindex(notebookId, identity, _clock.Now));
    }

    /// <summary>Captures the selected session now and persists its selection as a fresh build; returns the job ID.</summary>
    public async Task<long> RequestReindexAsync(long notebookId, CancellationToken ct = default)
    {
        var session = await _session(notebookId, ct).ConfigureAwait(false)
            ?? throw new FolderIngestionException("unsupportedEndpoint");
        return _store.RequestEmbeddingBuild(notebookId, session.Selection, copyExisting: false, _clock.Now);
    }

    public Task DiscardAsync(long generationId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        _store.DiscardBuildingGeneration(generationId, _clock.Now);
        return Task.CompletedTask;
    }

    public Task DiscardJobAsync(long jobId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var job = _store.Job(jobId) ?? throw new StorageV19Exception("notFound");
        long notebookId = job.Draft.Target.StartsWith("notebook:", StringComparison.Ordinal) ? TargetId(job.Draft.Target)
            : _store.Generation(TargetId(job.Draft.Target))?.NotebookId ?? throw new StorageV19Exception("notFound");
        _store.DiscardEmbeddingJob(notebookId, jobId, _clock.Now);
        return Task.CompletedTask;
    }

    public Task<GenerationProgress> ProgressAsync(long notebookId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var progress = _store.GenerationProgress(notebookId);
        return Task.FromResult(progress with { PausedForChat = Volatile.Read(ref _waitingForChat) > 0 });
    }

    internal async Task<bool> StillCurrentAsync(long notebookId, EmbeddingSelection durable)
    {
        var selected = await _selectedSelection(notebookId).ConfigureAwait(false);
        return selected is not null && IngestionGenerationSQL.SameSpace(selected, durable);
    }

    private static string FailureCode(Exception error) => error switch
    {
        FolderIngestionException ingestion => ingestion.Code,
        StorageV19Exception storage => storage.Code,
        ProviderConfigurationException configuration => configuration.Code,
        ProviderConsentException => "consentRequired",
        ProviderAuthException => "providerAuth",
        ProviderRateLimitException => "providerRateLimit",
        ProviderHttpException http => "providerHttp" + http.StatusCode.ToString(CultureInfo.InvariantCulture),
        Ollama.OllamaException.HttpStatus http => "providerHttp" + http.Code.ToString(CultureInfo.InvariantCulture),
        Ollama.OllamaException.NotReachable => "providerUnreachable",
        Ollama.OllamaException.Timeout or TimeoutException => "providerTimeout",
        _ => "providerError"
    };

    private static long TargetId(string target) =>
        long.Parse(target[(target.IndexOf(':') + 1)..], NumberStyles.None, CultureInfo.InvariantCulture);
}
