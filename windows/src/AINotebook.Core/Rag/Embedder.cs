using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class Embedder
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    public string Model { get; }
    public int BatchSize { get; }

    public Embedder(NotebookStore store, IEmbeddingProducing client, string model, int batchSize = 16)
    {
        _store = store;
        _client = client;
        Model = model;
        BatchSize = batchSize;
    }

    /// Embeds every chunk that has no row for `Model`. Returns total rows written.
    public async Task<int> EmbedAllPendingAsync(CancellationToken ct = default)
    {
        var written = 0;
        while (true)
        {
            var batch = _store.UnembeddedChunks(Model, BatchSize);
            if (batch.Count == 0) break;

            var inputs = batch.Select(c => c.Text).ToList();
            var vectors = await _client.EmbedAsync(Model, inputs, ct);
            if (vectors.Length != batch.Count)
                throw new EmbedderException.ResponseSizeMismatch(batch.Count, vectors.Length);

            for (var i = 0; i < batch.Count; i++)
            {
                _store.StoreEmbedding(batch[i].Id!.Value, Model, new EmbeddingVector(vectors[i]));
                written++;
            }
        }
        return written;
    }
}
