using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Rag;

public sealed class Retriever
{
    private readonly NotebookStore _store;
    private readonly IEmbeddingProducing _client;
    public string Model { get; }
    public int RrfK { get; }

    public Retriever(NotebookStore store, IEmbeddingProducing client, string model, int rrfK = 60)
    {
        _store = store;
        _client = client;
        Model = model;
        RrfK = rrfK;
    }

    public async Task<IReadOnlyList<RetrievalHit>> SearchAsync(
        long notebookId, string query, int topK = 8, CancellationToken ct = default)
    {
        // 1) Vector ranking — embed query, brute-force cosine over all embeddings.
        var queryVectors = await _client.EmbedAsync(Model, new[] { query }, ct);
        var queryVector = queryVectors.Length > 0 ? queryVectors[0] : Array.Empty<float>();

        var allEmbeddings = _store.Embeddings(notebookId, Model);
        var vectorRanked = allEmbeddings
            .Select(e => (e.ChunkId, e.SourceId, Score: Cosine.Similarity(queryVector, e.Vector.Values)))
            .OrderByDescending(x => x.Score)
            .Take(topK)
            .ToList();

        // 2) FTS ranking — BM25 top-K within the notebook.
        var ftsRanked = FtsTopK(notebookId, query, topK);

        // 3) Reciprocal Rank Fusion over BOTH lists.
        var rrfScores = new Dictionary<long, float>();
        var meta = new Dictionary<long, (long SourceId, string Snippet)>();
        for (var rank = 0; rank < vectorRanked.Count; rank++)
        {
            var hit = vectorRanked[rank];
            rrfScores[hit.ChunkId] = rrfScores.GetValueOrDefault(hit.ChunkId) + 1.0f / (RrfK + rank + 1);
            meta[hit.ChunkId] = (hit.SourceId, "");
        }
        for (var rank = 0; rank < ftsRanked.Count; rank++)
        {
            var hit = ftsRanked[rank];
            rrfScores[hit.ChunkId] = rrfScores.GetValueOrDefault(hit.ChunkId) + 1.0f / (RrfK + rank + 1);
            meta[hit.ChunkId] = (hit.SourceId, hit.Snippet);  // FTS overwrites with bm25 snippet
        }

        // 4) Hydrate snippets for chunks that only came from the vector branch.
        var missing = meta.Where(kv => kv.Value.Snippet.Length == 0).Select(kv => kv.Key).ToList();
        if (missing.Count > 0)
        {
            var snippets = Snippets(missing);
            foreach (var (id, snip) in snippets)
                meta[id] = (meta[id].SourceId, snip);
        }

        return rrfScores
            .OrderByDescending(kv => kv.Value)
            .Take(topK)
            .Where(kv => meta.ContainsKey(kv.Key))
            .Select(kv => new RetrievalHit(kv.Key, meta[kv.Key].SourceId, kv.Value, meta[kv.Key].Snippet))
            .ToList();
    }

    private List<(long ChunkId, long SourceId, string Snippet)> FtsTopK(long notebookId, string query, int k)
    {
        var conn = _store.Connection;
        using var cmd = conn.CreateCommand();
        cmd.CommandText = """
            SELECT sc.id AS chunk_id, sc.source_id AS source_id, sc.text AS text
            FROM chunks_fts f
            JOIN source_chunks sc ON sc.id = f.chunk_id
            JOIN sources s ON s.id = sc.source_id
            WHERE f.text MATCH $q AND s.notebook_id = $nb
            ORDER BY bm25(chunks_fts)
            LIMIT $k
            """;
        cmd.Parameters.AddWithValue("$q", EscapeFts(query));
        cmd.Parameters.AddWithValue("$nb", notebookId);
        cmd.Parameters.AddWithValue("$k", k);

        var rows = new List<(long, long, string)>();
        using var reader = cmd.ExecuteReader();
        while (reader.Read())
        {
            var text = reader.GetString(2);
            rows.Add((reader.GetInt64(0), reader.GetInt64(1), Prefix240(text)));
        }
        return rows;
    }

    private Dictionary<long, string> Snippets(IReadOnlyList<long> chunkIds)
    {
        var result = new Dictionary<long, string>();
        if (chunkIds.Count == 0) return result;

        var conn = _store.Connection;
        var placeholders = string.Join(",", chunkIds.Select((_, i) => "$p" + i));
        using var cmd = conn.CreateCommand();
        cmd.CommandText = $"SELECT id, text FROM source_chunks WHERE id IN ({placeholders})";
        for (var i = 0; i < chunkIds.Count; i++)
            cmd.Parameters.AddWithValue("$p" + i, chunkIds[i]);

        using var reader = cmd.ExecuteReader();
        while (reader.Read())
            result[reader.GetInt64(0)] = Prefix240(reader.GetString(1));
        return result;
    }

    private static string Prefix240(string text) => text.Length <= 240 ? text : text[..240];

    /// Wrap whole query as an FTS5 phrase: replace " with "" then surround in quotes.
    private static string EscapeFts(string raw) => "\"" + raw.Replace("\"", "\"\"") + "\"";
}
