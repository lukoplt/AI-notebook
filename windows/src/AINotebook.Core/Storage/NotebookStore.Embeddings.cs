using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public void StoreEmbedding(long chunkId, string model, EmbeddingVector vector)
    {
        Connection.Execute(
            """
            INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding)
            VALUES($cid, $dim, $model, $emb)
            ON CONFLICT(chunk_id) DO UPDATE SET
              dim = excluded.dim,
              model = excluded.model,
              embedding = excluded.embedding
            """,
            new { cid = chunkId, dim = vector.Dim, model, emb = vector.ToBytes() });
    }

    public IReadOnlyList<StoredEmbedding> Embeddings(long notebookId, string model)
    {
        return Connection.Query(
            """
            SELECT ce.chunk_id AS chunk_id, sc.source_id AS source_id, ce.embedding AS embedding
            FROM chunk_embeddings ce
            JOIN source_chunks sc ON sc.id = ce.chunk_id
            JOIN sources s ON s.id = sc.source_id
            WHERE s.notebook_id = $nb AND ce.model = $model
            """,
            new { nb = notebookId, model })
            .Select(r => new StoredEmbedding(
                (long)r.chunk_id, (long)r.source_id,
                EmbeddingVector.FromBytes((byte[])r.embedding)))
            .ToList();
    }

    public IReadOnlyList<SourceChunk> UnembeddedChunks(string model, int limit)
    {
        return Connection.Query(
            """
            SELECT sc.id AS id, sc.source_id AS source_id, sc.ord AS ord,
                   sc.text AS text, sc.token_count AS token_count, sc.page_hint AS page_hint
            FROM source_chunks sc
            LEFT JOIN chunk_embeddings ce ON ce.chunk_id = sc.id AND ce.model = $model
            WHERE ce.chunk_id IS NULL
            ORDER BY sc.id ASC
            LIMIT $limit
            """,
            new { model, limit })
            .Select(r => new SourceChunk(
                (long)r.id, (long)r.source_id, (int)(long)r.ord, (string)r.text,
                (int)(long)r.token_count, r.page_hint is null ? (int?)null : (int)(long)r.page_hint))
            .ToList();
    }

    public int UnembeddedCount(string model)
    {
        return Connection.ExecuteScalar<int>(
            """
            SELECT count(*) FROM source_chunks sc
            LEFT JOIN chunk_embeddings ce ON ce.chunk_id = sc.id AND ce.model = $model
            WHERE ce.chunk_id IS NULL
            """,
            new { model });
    }

    public void DeleteAllEmbeddings(string model) =>
        Connection.Execute("DELETE FROM chunk_embeddings WHERE model = $model", new { model });
}
