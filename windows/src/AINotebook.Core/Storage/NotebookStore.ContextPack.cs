using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Dapper;

namespace AINotebook.Core.Storage;

/// <summary>Metadata the context-pack adapters materialize under the store gate.</summary>
public sealed record ContextSourceDetail(long SourceId, long NotebookId, SourceType Type, string Title,
    long? FolderId, string? RelPath, string? Lang, string? Descriptor);

public sealed record ContextFolderDetail(long Id, string DisplayName, string ScanState, long? LastFullScanAt);

/// <summary>The live identity an original-opening request is checked against.</summary>
public sealed record ContextOriginalRecord(ContextSourceDetail Source, string? RawPath, long? CurrentRevisionId,
    FolderSource? Folder, long? NoteId);

public sealed partial class NotebookStore
{
    // MARK: Freshness fingerprints

    /// <summary>
    /// Lowercase SHA-256 over every persisted message (ID, role, content, model and
    /// citations JSON) ordered by ID. An in-place edit changes the digest; an empty
    /// session still has a real digest.
    /// </summary>
    public string ContextHistoryFingerprint(long sessionId)
    {
        JsonArray messages;
        lock (_gate)
        {
            messages = new JsonArray(_conn.Query("""
                SELECT id,role,content,model,citations_json FROM messages WHERE session_id=$sessionId ORDER BY id
                """, new { sessionId }).Select(row => (JsonNode)new JsonObject
            {
                ["id"] = (long)row.id,
                ["role"] = (string)row.role,
                ["content"] = (string)row.content,
                ["model"] = (string?)row.model,
                ["citations"] = (string?)row.citations_json,
            }).ToArray());
        }
        return Digest(new JsonObject { ["sessionId"] = sessionId, ["messages"] = messages });
    }

    /// <summary>
    /// Lowercase SHA-256 over the selection, the notebook's folder set and the scope's REVOKED
    /// sources (not present, or not eligible): their folder membership, availability and
    /// eligibility. Revision freshness is excluded, and so are usable sources: a file a running
    /// folder check discovers, or whose extraction publishes, only adds evidence and never makes
    /// a prepared turn stale; a source that became missing, unavailable or ineligible does
    /// (chat-during-scan-v1 §3). Removing a folder changes the folder set; a loose source
    /// deleted while a turn is in flight is not detected here (its citation then resolves as
    /// unavailable). An empty selection reads no source rows but still has a real digest.
    /// </summary>
    public string ContextScopeFingerprint(long notebookId, RetrievalScope scope)
    {
        ArgumentNullException.ThrowIfNull(scope);
        var (kind, sourceIds, folderIds) = PackIntentKey.ScopeParts(scope);
        JsonArray sources, folders;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: true);
            var rows = scope.IsEmptySelection ? [] : _conn.Query("""
                SELECT id,folder_id,availability,eligible FROM sources s
                WHERE s.notebook_id=$nb AND (s.availability<>'present' OR s.eligible=0)
                  AND ($all=1 OR s.id IN (SELECT CAST(value AS INTEGER) FROM json_each($sourceIds))
                       OR s.folder_id IN (SELECT CAST(value AS INTEGER) FROM json_each($folderIds)))
                ORDER BY id
                """, new
            {
                nb = notebookId, all = kind == "all" ? 1 : 0,
                sourceIds = JsonSerializer.Serialize(sourceIds), folderIds = JsonSerializer.Serialize(folderIds)
            }, tx).ToArray();
            sources = new JsonArray(rows.Select(row => (JsonNode)new JsonObject
            {
                ["id"] = (long)row.id,
                ["folderId"] = (long?)row.folder_id,
                ["availability"] = (string)row.availability,
                ["eligible"] = (long)row.eligible != 0,
            }).ToArray());
            folders = new JsonArray(_conn.Query<long>("SELECT id FROM folder_sources WHERE notebook_id=$nb ORDER BY id",
                new { nb = notebookId }, tx).Select(id => (JsonNode)JsonValue.Create(id)).ToArray());
            tx.Commit();
        }
        return Digest(new JsonObject
        {
            ["notebookId"] = notebookId, ["kind"] = kind,
            ["sourceIds"] = new JsonArray(sourceIds.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()),
            ["folderIds"] = new JsonArray(folderIds.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()),
            ["sources"] = sources, ["folders"] = folders,
        });
    }

    private static string Digest(JsonObject node) => Convert.ToHexString(SHA256.HashData(
        PreparedContextRequestJson.CanonicalBytes(JsonSerializer.SerializeToElement(node)))).ToLowerInvariant();

    // MARK: Turn persistence

    /// <summary>Inserts the current user turn and returns it with its real ID.</summary>
    public ChatMessage AppendContextUser(long sessionId, string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        var now = DateTime.UtcNow;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction();
            if (!_conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=$sessionId)", new { sessionId }, tx))
                throw new StorageV19Exception("notFound");
            long id = _conn.ExecuteScalar<long>("""
                INSERT INTO messages(session_id,role,content,citations_json,created_at,model)
                VALUES($sessionId,'user',$text,NULL,$created,NULL);
                SELECT last_insert_rowid();
                """, new { sessionId, text, created = SqliteDate.ToDb(now) }, tx);
            tx.Commit();
            return new ChatMessage(id, sessionId, ChatRole.User, text, Array.Empty<Citation>(), now);
        }
    }

    /// <summary>
    /// Removes a user turn that never got an answer (a new turn stopped before any text streamed).
    /// Deletes only when <paramref name="messageId"/> is a user row of <paramref name="sessionId"/> and
    /// nothing newer follows it in the session; returns whether the row was removed. Inverse of
    /// <see cref="AppendContextUser"/>.
    /// </summary>
    public bool DeleteUnansweredQuestion(long sessionId, long messageId)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction();
            string? role = _conn.ExecuteScalar<string?>(
                "SELECT role FROM messages WHERE id=$messageId AND session_id=$sessionId", new { messageId, sessionId }, tx);
            if (role != ChatRole.User.ToDb()
                || _conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM messages WHERE session_id=$sessionId AND id>$messageId)",
                    new { sessionId, messageId }, tx))
                return false;
            _conn.Execute("DELETE FROM messages WHERE id=$messageId", new { messageId }, tx);
            tx.Commit();
            return true;
        }
    }

    /// <summary>
    /// One transaction, run only after a successful stream: optionally rewrites the edited
    /// user text, deletes the replaced assistant and inserts the new answer, returning it
    /// with its real ID. Replaced IDs must belong to <paramref name="sessionId"/> with the
    /// right roles; otherwise nothing changes.
    /// </summary>
    public ChatMessage CommitContextAssistant(long sessionId, string content, IReadOnlyList<Citation> citations,
        string model, long? replacesAssistantId, long? replacesUserId, string? replacementUserText)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(citations);
        var now = DateTime.UtcNow;
        string? json = CitationsCodec.Encode(citations);
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction();
            if (!_conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM chat_sessions WHERE id=$sessionId)", new { sessionId }, tx))
                throw new StorageV19Exception("notFound");
            dynamic Owned(long id, ChatRole role)
            {
                var row = _conn.QuerySingleOrDefault("SELECT role,content FROM messages WHERE id=$id AND session_id=$sessionId",
                    new { id, sessionId }, tx);
                if (row is null || (string)row.role != role.ToDb()) throw new StorageV19Exception("notebookMismatch");
                return row;
            }
            if (replacesUserId is long userId)
            {
                var row = Owned(userId, ChatRole.User);
                if (replacementUserText is not null && !StringComparer.Ordinal.Equals((string)row.content, replacementUserText))
                    _conn.Execute("UPDATE messages SET content=$text WHERE id=$userId", new { text = replacementUserText, userId }, tx);
            }
            else if (replacementUserText is not null) throw new StorageV19Exception("invalidValue");
            if (replacesAssistantId is long assistantId)
            {
                Owned(assistantId, ChatRole.Assistant);
                _conn.Execute("DELETE FROM messages WHERE id=$assistantId", new { assistantId }, tx);
            }
            long id = _conn.ExecuteScalar<long>("""
                INSERT INTO messages(session_id,role,content,citations_json,created_at,model)
                VALUES($sessionId,'assistant',$content,$json,$created,$model);
                SELECT last_insert_rowid();
                """, new { sessionId, content, json, created = SqliteDate.ToDb(now), model }, tx);
            tx.Commit();
            return new ChatMessage(id, sessionId, ChatRole.Assistant, content, citations.ToArray(), now, model);
        }
    }

    // MARK: Pinned-read metadata

    internal void ContextValidateSession(long notebookId, long sessionId)
    {
        lock (_gate)
        {
            long? owner = _conn.ExecuteScalar<long?>("SELECT notebook_id FROM chat_sessions WHERE id=$sessionId", new { sessionId });
            if (owner is null) throw new StorageV19Exception("notFound");
            if (owner != notebookId) throw new StorageV19Exception("notebookMismatch");
        }
    }

    /// <summary>The notebook's name and stored instructions (empty when unset).</summary>
    public (string Name, string Instructions) ContextNotebook(long notebookId)
    {
        lock (_gate)
        {
            var row = _conn.QuerySingleOrDefault("SELECT name,instructions FROM notebooks WHERE id=$notebookId", new { notebookId })
                ?? throw new StorageV19Exception("notFound");
            return ((string)row.name, (string?)row.instructions ?? "");
        }
    }

    internal IReadOnlyDictionary<long, ContextSourceDetail> ContextSourceDetails(IEnumerable<long> ids)
    {
        var sorted = ids.Distinct().Order().ToArray();
        if (sorted.Length == 0) return new Dictionary<long, ContextSourceDetail>();
        lock (_gate)
            return _conn.Query("""
                SELECT id,notebook_id,type,title,folder_id,rel_path,lang,descriptor FROM sources
                WHERE id IN (SELECT CAST(value AS INTEGER) FROM json_each($ids))
                """, new { ids = JsonSerializer.Serialize(sorted) })
                .Select(row => (ContextSourceDetail)Detail(row)).ToDictionary(d => d.SourceId);
    }

    private static ContextSourceDetail Detail(dynamic row)
    {
        SourceType type;
        try { type = SourceTypeExtensions.FromDb((string)row.type); }
        catch (ArgumentOutOfRangeException) { type = SourceType.Text; }
        return new((long)row.id, (long)row.notebook_id, type, (string)row.title, (long?)row.folder_id,
            (string?)row.rel_path, (string?)row.lang, (string?)row.descriptor);
    }

    internal IReadOnlyDictionary<long, ContextFolderDetail> ContextFolders(long notebookId)
    {
        lock (_gate)
            return _conn.Query("SELECT id,display_name,scan_state,last_full_scan_at FROM folder_sources WHERE notebook_id=$notebookId",
                new { notebookId }).Select(row => new ContextFolderDetail((long)row.id, (string)row.display_name,
                    (string)row.scan_state, (long?)row.last_full_scan_at)).ToDictionary(f => f.Id);
    }

    internal IReadOnlyDictionary<long, string> ContextChunkLanguages(IEnumerable<long> chunkIds)
    {
        var sorted = chunkIds.Distinct().Order().ToArray();
        if (sorted.Length == 0) return new Dictionary<long, string>();
        lock (_gate)
            return _conn.Query("""
                SELECT id,lang FROM source_chunks WHERE lang IS NOT NULL
                  AND id IN (SELECT CAST(value AS INTEGER) FROM json_each($ids))
                """, new { ids = JsonSerializer.Serialize(sorted) }).ToDictionary(row => (long)row.id, row => (string)row.lang);
    }

    /// <summary>The first chunk (ordinal 0) of each given published revision.</summary>
    internal IReadOnlyList<ChunkReference> ContextFirstChunks(IReadOnlyDictionary<long, long> revisions)
    {
        if (revisions.Count == 0) return Array.Empty<ChunkReference>();
        string pairs = JsonSerializer.Serialize(revisions.OrderBy(p => p.Key).Select(p => new { sourceId = p.Key, revisionId = p.Value }));
        lock (_gate)
            return _conn.Query("""
                SELECT sc.id,sc.source_id,sc.revision_id,sc.ord FROM source_chunks sc
                JOIN json_each($pairs) p ON CAST(json_extract(p.value,'$.sourceId') AS INTEGER)=sc.source_id
                  AND CAST(json_extract(p.value,'$.revisionId') AS INTEGER)=sc.revision_id
                WHERE sc.ord=0 ORDER BY sc.source_id,sc.id
                """, new { pairs }).Select(row => new ChunkReference((long)row.id, (long)row.source_id,
                    (long)row.revision_id, checked((int)(long)row.ord))).ToArray();
    }

    /// <summary>Refetches the live source, its folder and current revision for one click.</summary>
    public ContextOriginalRecord? ContextOriginal(long notebookId, long sourceId)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: true);
            var row = _conn.QuerySingleOrDefault("""
                SELECT id,notebook_id,type,title,folder_id,rel_path,lang,descriptor,raw_path,current_revision,
                       published_revision_id FROM sources WHERE id=$sourceId AND notebook_id=$notebookId
                """, new { sourceId, notebookId }, tx);
            if (row is null) { tx.Commit(); return null; }
            ContextSourceDetail detail = Detail(row);
            long? revision = (long?)row.current_revision ?? (long?)row.published_revision_id;
            long? noteId = detail.Type == SourceType.Note
                ? _conn.ExecuteScalar<long?>("SELECT id FROM notes WHERE auto_source_id=$sourceId AND notebook_id=$notebookId",
                    new { sourceId, notebookId }, tx)
                : null;
            FolderSource? folder = null;
            if (detail.FolderId is long folderId)
            {
                var folderRow = _conn.QuerySingleOrDefault("SELECT * FROM folder_sources WHERE id=$folderId AND notebook_id=$notebookId",
                    new { folderId, notebookId }, tx);
                if (folderRow is not null) folder = ReadFolder(folderRow);
            }
            tx.Commit();
            return new ContextOriginalRecord(detail, (string?)row.raw_path, revision, folder, noteId);
        }
    }
}
