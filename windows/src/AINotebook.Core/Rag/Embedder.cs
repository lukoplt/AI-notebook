using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class Embedder
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    private readonly Func<string> _modelGetter;
    private readonly IngestionAdmission? _admission;
    /// <summary>WP7 named-profile drain (<see cref="ProfileEmbeddingDrain.RunAsync"/>); a null result is a legacy selection.</summary>
    private readonly Func<CancellationToken, Task<int?>>? _profileDrain;
    public string Model => _modelGetter();
    public int BatchSize { get; }

    // Backward-compatible overload: fixed model string (used by existing tests + Ollama path).
    public Embedder(NotebookStore store, IEmbeddingProducing client, string model, int batchSize = 16,
        IngestionAdmission? admission = null)
        : this(store, client, () => model, batchSize, admission) { }

    // Primary constructor: live model key via getter (used by ProviderRouter path).
    // Legacy compatibility path; production embedding runs through the durable FolderIndexCoordinator.
    public Embedder(NotebookStore store, IEmbeddingProducing client, Func<string> modelGetter, int batchSize = 16,
        IngestionAdmission? admission = null, Func<CancellationToken, Task<int?>>? profileDrain = null)
    {
        _store = store;
        _profileDrain = profileDrain;
        _admission = admission;
        _client = client;
        _modelGetter = modelGetter;
        BatchSize = batchSize;
    }

    /// Embeds pending published chunks for one captured model key. Returns rows written.
    public async Task<int> EmbedAllPendingAsync(CancellationToken ct = default)
    {
        // A selected named profile owns ordinary embedding work; null keeps the legacy drain below.
        if (_profileDrain is not null)
        {
            int? profiled = await _profileDrain(ct);
            if (profiled.HasValue) return profiled.Value;
        }
        string key = Model;
        var written = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var batch = _store.CaptureEmbeddingBatch(key, BatchSize);
            if (batch.Items.Count == 0)
            {
                _store.CompleteAvailableEmbeddingWork(key, Model, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
                break;
            }

            // Same shared chat gate as durable indexing: wait immediately before each background batch.
            if (_admission is not null) await _admission.WaitForBackgroundBatchAsync(ct);
            var inputs = batch.Items.Select(item => item.Chunk.Text).ToArray();
            var vectors = await _client.EmbedAsync(key, inputs, ct);
            ct.ThrowIfCancellationRequested();
            if (vectors.Length != batch.Items.Count)
                throw new EmbedderException.ResponseSizeMismatch(batch.Items.Count, vectors.Length);

            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var committed = _store.CommitEmbeddingBatch(batch, vectors.Select(vector => new EmbeddingVector(vector)).ToArray(), now);
            written += committed.Written;
            ct.ThrowIfCancellationRequested();
            string selected = Model;
            // A stale batch is retried by a later drain after the new source publication.
            if (committed.Stale) break;
            foreach (long generationId in committed.GenerationIds)
                _store.CompleteEmbeddingGeneration(generationId, Model, now);
            if (!StringComparer.Ordinal.Equals(key, selected)) break;
        }
        return written;
    }
}
