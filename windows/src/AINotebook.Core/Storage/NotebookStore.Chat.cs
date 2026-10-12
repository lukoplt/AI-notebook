using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public ChatSession CreateChatSession(long notebookId, string title)
    {
        lock (_gate)
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
    }

    public IReadOnlyList<ChatSession> ChatSessions(long notebookId)
    {
        lock (_gate)
            return Connection.Query(
                "SELECT id, notebook_id, title, created_at FROM chat_sessions WHERE notebook_id=$nb ORDER BY created_at DESC",
                new { nb = notebookId })
                .Select(r => new ChatSession((long)r.id, (long)r.notebook_id, (string)r.title,
                    SqliteDate.FromDb((string)r.created_at)))
                .ToList();
    }

    /// <summary>
    /// Renames a chat (Swift <c>renameChatSession</c>). The title is trimmed; a blank title is
    /// rejected and the stored one kept. No schema change: <c>chat_sessions.title</c> already exists.
    /// </summary>
    public ChatSession RenameChatSession(long id, string title)
    {
        lock (_gate)
        {
            var trimmed = title.Trim();
            if (trimmed.Length == 0) throw new StoreException.InvalidChatTitle(title);
            var rows = Connection.Execute("UPDATE chat_sessions SET title=$title WHERE id=$id", new { title = trimmed, id });
            if (rows == 0) throw new StoreException.ChatSessionNotFound(id);
            var row = Connection.QuerySingle(
                "SELECT id, notebook_id, title, created_at FROM chat_sessions WHERE id=$id", new { id });
            return new ChatSession((long)row.id, (long)row.notebook_id, (string)row.title,
                SqliteDate.FromDb((string)row.created_at));
        }
    }

    public void DeleteChatSession(long id)
    {
        lock (_gate)
            Connection.Execute("DELETE FROM chat_sessions WHERE id=$id", new { id });
    }

    public void AppendMessage(ChatMessage message)
    {
        lock (_gate)
        {
            var json = CitationsCodec.Encode(message.Citations);
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
    }

    public IReadOnlyList<ChatMessage> Messages(long sessionId)
    {
        lock (_gate)
            return Connection.Query(
                "SELECT id, session_id, role, content, citations_json, created_at, model FROM messages WHERE session_id=$sid ORDER BY created_at ASC",
                new { sid = sessionId })
                .Select(r =>
                {
                    var cits = CitationsCodec.Decode((string?)r.citations_json);
                    return new ChatMessage(
                        (long)r.id, (long)r.session_id, ChatRoleExtensions.FromDb((string)r.role),
                        (string)r.content, cits, SqliteDate.FromDb((string)r.created_at),
                        r.model is null ? null : (string)r.model);
                })
                .ToList();
    }

    /// <summary>
    /// Deletes the last user+assistant pair from a session (for edit/regenerate).
    /// No-op if session has fewer than 2 messages.
    /// </summary>
    public void DeleteLastExchange(long sessionId)
    {
        lock (_gate)
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
}
