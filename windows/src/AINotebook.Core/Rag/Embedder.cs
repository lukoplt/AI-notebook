using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class Embedder
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    private readonly Func<string> _modelGetter;
    public string Model => _modelGetter();
    public int BatchSize { get; }

    // Backward-compatible overload: fixed model string (used by existing tests + Ollama path).
    public Embedder(NotebookStore store, IEmbeddingProducing client, string model, int batchSize = 16)
        : this(store, client, () => model, batchSize) { }

    // Primary constructor: live model key via getter (used by ProviderRouter path).
    public Embedder(NotebookStore store, IEmbeddingProducing client, Func<string> modelGetter, int batchSize = 16)
    {
        _store = store;
        _client = client;
        _modelGetter = modelGetter;
        BatchSize = batchSize;
    }

    /// Embeds every chunk that has no row for current `Model`. Returns total rows written.
    public async Task<int> EmbedAllPendingAsync(CancellationToken ct = default)
    {
        var written = 0;
        while (true)
        {
            var key = Model;
            var batch = _store.UnembeddedChunks(key, BatchSize);
            if (batch.Count == 0) break;

            var inputs = batch.Select(c => c.Text).ToList();
            var vectors = await _client.EmbedAsync(key, inputs, ct);
            if (vectors.Length != batch.Count)
                throw new EmbedderException.ResponseSizeMismatch(batch.Count, vectors.Length);

            for (var i = 0; i < batch.Count; i++)
            {
                _store.StoreEmbedding(batch[i].Id!.Value, key, new EmbeddingVector(vectors[i]));
                written++;
            }
        }
        return written;
    }
}
