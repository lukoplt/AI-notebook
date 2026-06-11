using System.Text.Json;
using System.Text.Json.Serialization;
using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    // Swift JSONEncoder default keys are camelCase. snippet/marker are already
    // camelCase; chunkId/sourceId map to "chunkId"/"sourceId".
    private sealed record CitationJson(
        [property: JsonPropertyName("marker")] int Marker,
        [property: JsonPropertyName("chunkId")] long ChunkId,
        [property: JsonPropertyName("sourceId")] long SourceId,
        [property: JsonPropertyName("snippet")] string Snippet);

    public ChatSession CreateChatSession(long notebookId, string title)
    {
        var trimmed = title.Trim();
        var resolved = trimmed.Length == 0 ? "New chat" : trimmed;
        var now = DateTime.UtcNow;
        var id = Connection.ExecuteScalar<long>(
            """
            INSERT INTO chat_sessions(notebook_id, title, created_at)
            VALUES($nb, $title, $created);
            SELECT last_insert_rowid();
            """,
            new { nb = notebookId, title = resolved, created = SqliteDate.ToDb(now) });
        return new ChatSession(id, notebookId, resolved, now);
    }

    public IReadOnlyList<ChatSession> ChatSessions(long notebookId) =>
        Connection.Query(
            "SELECT id, notebook_id, title, created_at FROM chat_sessions WHERE notebook_id=$nb ORDER BY created_at DESC",
            new { nb = notebookId })
            .Select(r => new ChatSession((long)r.id, (long)r.notebook_id, (string)r.title,
                SqliteDate.FromDb((string)r.created_at)))
            .ToList();

    public void DeleteChatSession(long id) =>
        Connection.Execute("DELETE FROM chat_sessions WHERE id=$id", new { id });

    public void AppendMessage(ChatMessage message)
    {
        string? json = message.Citations.Count == 0
            ? null
            : JsonSerializer.Serialize(
                message.Citations.Select(c => new CitationJson(c.Marker, c.ChunkId, c.SourceId, c.Snippet)).ToList());
        Connection.Execute(
            """
            INSERT INTO messages(session_id, role, content, citations_json, created_at, model)
            VALUES($sid, $role, $content, $cit, $created, $model)
            """,
            new
            {
                sid = message.SessionId, role = message.Role.ToDb(), content = message.Content,
                cit = json, created = SqliteDate.ToDb(message.CreatedAt), model = message.Model
            });
    }

    public IReadOnlyList<ChatMessage> Messages(long sessionId) =>
        Connection.Query(
            "SELECT id, session_id, role, content, citations_json, created_at, model FROM messages WHERE session_id=$sid ORDER BY created_at ASC",
            new { sid = sessionId })
            .Select(r =>
            {
                IReadOnlyList<Citation> cits = Array.Empty<Citation>();
                if (r.citations_json is string raw && raw.Length > 0)
                {
                    var decoded = JsonSerializer.Deserialize<List<CitationJson>>(raw);
                    if (decoded is not null)
                        cits = decoded.Select(c => new Citation(c.Marker, c.ChunkId, c.SourceId, c.Snippet)).ToList();
                }
                return new ChatMessage(
                    (long)r.id, (long)r.session_id, ChatRoleExtensions.FromDb((string)r.role),
                    (string)r.content, cits, SqliteDate.FromDb((string)r.created_at),
                    r.model is null ? null : (string)r.model);
            })
            .ToList();

    /// <summary>
    /// Deletes the last user+assistant pair from a session (for edit/regenerate).
    /// No-op if session has fewer than 2 messages.
    /// </summary>
    public void DeleteLastExchange(long sessionId)
    {
        using var tx = Connection.BeginTransaction();
        var ids = Connection.Query<long>(
            "SELECT id FROM messages WHERE session_id=$sid ORDER BY created_at DESC LIMIT 2",
            new { sid = sessionId }, tx)
            .ToList();
        foreach (var id in ids)
            Connection.Execute("DELETE FROM messages WHERE id=$id", new { id }, tx);
        tx.Commit();
    }
}
