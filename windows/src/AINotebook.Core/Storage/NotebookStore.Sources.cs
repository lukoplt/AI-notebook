using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private static Source MapSource(dynamic r) => new Source(
        (long)r.id, (long)r.notebook_id,
        SourceTypeExtensions.FromDb((string)r.type), (string)r.title,
        r.uri is null ? null : (string)r.uri,
        r.raw_path is null ? null : (string)r.raw_path,
        SourceStatusExtensions.FromDb((string)r.status),
        r.error is null ? null : (string)r.error,
        SqliteDate.FromDb((string)r.ingested_at));

    public Source CreateSource(long notebookId, SourceType type, string title, string? uri, string? rawPath)
    {
        var trimmed = title.Trim();
        if (trimmed.Length == 0) throw new StoreException.InvalidSourceTitle(title);
        var now = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO sources(notebook_id, type, title, uri, raw_path, status, error, ingested_at)
            VALUES($nb, $type, $title, $uri, $raw, $status, NULL, $ingested);
            SELECT last_insert_rowid();
            """,
            new
            {
                nb = notebookId, type = type.ToDb(), title = trimmed, uri, raw = rawPath,
                status = SourceStatus.Pending.ToDb(), ingested = SqliteDate.ToDb(now)
            });
        return new Source(id, notebookId, type, trimmed, uri, rawPath, SourceStatus.Pending, null, now);
    }

    private const string SourceCols =
        "id, notebook_id, type, title, uri, raw_path, status, error, ingested_at";

    public IReadOnlyList<Source> Sources(long notebookId) =>
        Connection.Query(
            $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb AND type<>'note' ORDER BY ingested_at DESC",
            new { nb = notebookId })
            .Select(r => (Source)MapSource(r)).ToList();

    public IReadOnlyList<Source> SourcesIncludingShadow(long notebookId) =>
        Connection.Query(
            $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb ORDER BY ingested_at DESC",
            new { nb = notebookId })
            .Select(r => (Source)MapSource(r)).ToList();

    public Source? Source(long id)
    {
        var row = Connection.QueryFirstOrDefault(
            $"SELECT {SourceCols} FROM sources WHERE id=$id", new { id });
        return row is null ? null : MapSource(row);
    }

    public void UpdateSourceStatus(long id, SourceStatus status, string? error)
    {
        var rows = Connection.Execute(
            "UPDATE sources SET status=$status, error=$error WHERE id=$id",
            new { status = status.ToDb(), error, id });
        if (rows == 0) throw new StoreException.SourceNotFound(id);
    }

    public void UpdateSourceTitle(long id, string title)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "UPDATE sources SET title = $t WHERE id = $id";
        cmd.Parameters.AddWithValue("$t", title);
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    public void DeleteSource(long id)
    {
        var rows = Connection.Execute("DELETE FROM sources WHERE id=$id", new { id });
        if (rows == 0) throw new StoreException.SourceNotFound(id);
    }

    public void ReplaceChunks(long sourceId, IReadOnlyList<ChunkDraft> chunks)
    {
        using var tx = Connection.BeginTransaction();
        Connection.Execute("DELETE FROM source_chunks WHERE source_id=$sid", new { sid = sourceId }, tx);
        int ord = 0;
        foreach (var draft in chunks)
        {
            Connection.Execute(
                """
                INSERT INTO source_chunks(source_id, ord, text, token_count, page_hint)
                VALUES($sid, $ord, $text, $tc, $ph)
                """,
                new { sid = sourceId, ord, text = draft.Text, tc = draft.TokenCount, ph = draft.PageHint },
                tx);
            ord++;
        }
        tx.Commit();
    }

    public IReadOnlyList<SourceChunk> Chunks(long sourceId) =>
        Connection.Query(
            "SELECT id, source_id, ord, text, token_count, page_hint FROM source_chunks WHERE source_id=$sid ORDER BY ord ASC",
            new { sid = sourceId })
            .Select(r => new SourceChunk(
                (long)r.id, (long)r.source_id, (int)(long)r.ord, (string)r.text,
                (int)(long)r.token_count, r.page_hint is null ? (int?)null : (int)(long)r.page_hint))
            .ToList();
}
