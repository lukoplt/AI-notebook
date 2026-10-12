using System.Text.Json;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    private static readonly JsonSerializerOptions FolderJson = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public FolderSource CreateFolder(long notebookId, FolderDraft draft, IFolderPathIdentity identity, long now)
    {
        ValidateFolderDraft(draft);
        var resolved = identity.Resolve(draft.RootPath);
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            RequireNotebookV19(notebookId, transaction);
            CheckFolderOverlap(notebookId, resolved, null, transaction);
            long id = _conn.ExecuteScalar<long>("""
                INSERT INTO folder_sources(notebook_id,root_path,path_identity,display_name,
                    include_exts,ignore_globs,limits,encoding_fallback,watch_enabled,created_at)
                VALUES($notebookId,$root,$identity,$display,$include,$ignore,$limits,$encoding,$watch,$created);
                SELECT last_insert_rowid();
                """, new
            {
                notebookId, root = draft.RootPath, identity = JsonSerializer.Serialize(resolved, FolderJson),
                display = draft.DisplayName, include = JsonSerializer.Serialize(draft.IncludeExts),
                ignore = JsonSerializer.Serialize(draft.IgnoreGlobs), limits = draft.LimitsJSON,
                encoding = draft.EncodingFallback, watch = draft.WatchEnabled,
                created = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime)
            }, transaction);
            var folder = ReadFolder(_conn.QuerySingle("SELECT * FROM folder_sources WHERE id=$id", new { id }, transaction));
            transaction.Commit();
            return folder;
        }
    }

    public IReadOnlyList<FolderSource> Folders(long notebookId)
    {
        lock (_gate)
        {
            RequireNotebookV19(notebookId);
            return _conn.Query("SELECT * FROM folder_sources WHERE notebook_id=$notebookId ORDER BY id", new { notebookId })
                .Select(row => (FolderSource)ReadFolder(row)).ToArray();
        }
    }

    public void UpdateFolder(long id, FolderDraft draft, IFolderPathIdentity identity)
    {
        ValidateFolderDraft(draft);
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            var row = _conn.QuerySingleOrDefault("SELECT * FROM folder_sources WHERE id=$id", new { id }, transaction);
            if (row is null) throw new StorageV19Exception("notFound");
            FolderSource existing = ReadFolder(row);
            FolderIdentity resolved = existing.Identity;
            if (!StringComparer.Ordinal.Equals(existing.Draft.RootPath, draft.RootPath))
            {
                if (_conn.ExecuteScalar<bool>("""
                    SELECT EXISTS(SELECT 1 FROM sources WHERE folder_id=$id)
                        OR EXISTS(SELECT 1 FROM scan_items WHERE folder_id=$id)
                    """, new { id }, transaction))
                    throw new StorageV19Exception("invalidValue");
                resolved = identity.Resolve(draft.RootPath);
                CheckFolderOverlap(existing.NotebookId, resolved, id, transaction);
            }
            _conn.Execute("""
                UPDATE folder_sources SET root_path=$root,path_identity=$identity,display_name=$display,
                    include_exts=$include,ignore_globs=$ignore,limits=$limits,encoding_fallback=$encoding,
                    watch_enabled=$watch WHERE id=$id
                """, new
            {
                id, root = draft.RootPath, identity = JsonSerializer.Serialize(resolved, FolderJson),
                display = draft.DisplayName, include = JsonSerializer.Serialize(draft.IncludeExts),
                ignore = JsonSerializer.Serialize(draft.IgnoreGlobs), limits = draft.LimitsJSON,
                encoding = draft.EncodingFallback, watch = draft.WatchEnabled
            }, transaction);
            transaction.Commit();
        }
    }

    public void DeleteFolder(long id)
    {
        lock (_gate)
        {
            if (_conn.Execute("DELETE FROM folder_sources WHERE id=$id", new { id }) == 0)
                throw new StorageV19Exception("notFound");
        }
    }

    public void UpsertScanItems(long folderId, IReadOnlyList<ScanItem> items)
    {
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            RequireFolderNotebook(folderId, transaction);
            foreach (var item in items)
            {
                if (item.FolderId != folderId) throw new StorageV19Exception("invalidValue");
                ValidateRelativePath(item.RelPath);
                if (item.SizeBytes < 0 || item.SeenGeneration < 0 ||
                    item.Kind is not ("eligible" or "skipped") ||
                    item.Kind == "eligible" && item.SkipReason is not null ||
                    item.Kind == "skipped" && item.SkipReason is not ("ignored" or "unsupported_ext" or "over_limit"))
                    throw new StorageV19Exception("invalidValue");
            }
            foreach (var item in items)
                _conn.Execute("""
                    INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
                    VALUES($folderId,$relPath,$kind,$skipReason,$mtime,$sizeBytes,$seenGeneration)
                    ON CONFLICT(folder_id,rel_path) DO UPDATE SET kind=excluded.kind,
                        skip_reason=excluded.skip_reason,mtime=excluded.mtime,size_bytes=excluded.size_bytes,
                        seen_generation=excluded.seen_generation
                    """, new
                {
                    folderId, relPath = item.RelPath, kind = item.Kind, skipReason = item.SkipReason,
                    mtime = item.Mtime, sizeBytes = item.SizeBytes, seenGeneration = item.SeenGeneration
                }, transaction);
            transaction.Commit();
        }
    }

    public IReadOnlyList<ScanItem> ScanItems(long folderId)
    {
        lock (_gate)
        {
            RequireFolderNotebook(folderId);
            return _conn.Query("SELECT * FROM scan_items WHERE folder_id=$folderId ORDER BY CAST(rel_path AS BLOB)", new { folderId })
                .Select(row => new ScanItem((long)row.folder_id, (string)row.rel_path, (string)row.kind,
                    (string?)row.skip_reason, (long?)row.mtime, (long?)row.size_bytes, (long)row.seen_generation))
                .ToArray();
        }
    }

    public void AttachSource(long sourceId, long folderId, string relPath)
    {
        ValidateRelativePath(relPath);
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            long folderNotebook = RequireFolderNotebook(folderId, transaction);
            long? sourceNotebook = _conn.QuerySingleOrDefault<long?>(
                "SELECT notebook_id FROM sources WHERE id=$sourceId", new { sourceId }, transaction);
            if (sourceNotebook is null) throw new StorageV19Exception("notFound");
            if (sourceNotebook != folderNotebook) throw new StorageV19Exception("notebookMismatch");
            if (_conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM sources WHERE folder_id=$folderId AND rel_path=$relPath AND id<>$sourceId)
                """, new { folderId, relPath, sourceId }, transaction))
                throw new StorageV19Exception("invalidValue");
            _conn.Execute("UPDATE sources SET folder_id=$folderId,rel_path=$relPath WHERE id=$sourceId",
                new { sourceId, folderId, relPath }, transaction);
            transaction.Commit();
        }
    }

    private void RequireNotebookV19(long notebookId, SqliteTransaction? transaction = null)
    {
        if (!_conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=$notebookId)", new { notebookId }, transaction))
            throw new StorageV19Exception("notFound");
    }

    private long RequireFolderNotebook(long folderId, SqliteTransaction? transaction = null)
        => _conn.QuerySingleOrDefault<long?>("SELECT notebook_id FROM folder_sources WHERE id=$folderId", new { folderId }, transaction)
            ?? throw new StorageV19Exception("notFound");

    private void CheckFolderOverlap(long notebookId, FolderIdentity proposed, long? excludingId, SqliteTransaction transaction)
    {
        var saved = _conn.Query<string>("""
            SELECT path_identity FROM folder_sources
            WHERE notebook_id=$notebookId AND ($excludingId IS NULL OR id<>$excludingId)
            """, new { notebookId, excludingId }, transaction);
        foreach (var json in saved)
            if (Overlaps(proposed, JsonSerializer.Deserialize<FolderIdentity>(json, FolderJson)!))
                throw new StorageV19Exception("overlappingRoot");
    }

    private static bool Overlaps(FolderIdentity a, FolderIdentity b)
    {
        if (!StringComparer.Ordinal.Equals(a.VolumeId, b.VolumeId)) return false;
        int count = Math.Min(a.Components.Count, b.Components.Count);
        return a.Components.Take(count).SequenceEqual(b.Components.Take(count), StringComparer.Ordinal);
    }

    private static void ValidateRelativePath(string relPath)
    {
        if (string.IsNullOrEmpty(relPath) || relPath[0] == '/' || relPath.Contains('\\') || relPath.Contains('\0') ||
            relPath.Length >= 2 && ((relPath[0] is >= 'A' and <= 'Z') || (relPath[0] is >= 'a' and <= 'z')) && relPath[1] == ':' ||
            relPath.Split('/').Any(component => component.Length == 0 || component is "." or ".."))
            throw new StorageV19Exception("invalidPath");
    }

    private static void ValidateFolderDraft(FolderDraft draft)
    {
        if (draft.EncodingFallback is not ("cp1250" or "none")) throw new StorageV19Exception("invalidValue");
        try
        {
            using var limits = JsonDocument.Parse(draft.LimitsJSON);
            if (limits.RootElement.ValueKind != JsonValueKind.Object) throw new StorageV19Exception("invalidValue");
        }
        catch (JsonException) { throw new StorageV19Exception("invalidValue"); }
    }

    private static FolderSource ReadFolder(dynamic row) => new(
        (long)row.id, (long)row.notebook_id,
        new FolderDraft((string)row.root_path, (string)row.display_name,
            JsonSerializer.Deserialize<string[]>((string)row.include_exts)!,
            JsonSerializer.Deserialize<string[]>((string)row.ignore_globs)!,
            (string)row.limits, (string)row.encoding_fallback, (long)row.watch_enabled != 0),
        JsonSerializer.Deserialize<FolderIdentity>((string)row.path_identity, FolderJson)!,
        (string)row.scan_state, (long)row.scan_generation, (long?)row.last_full_scan_at,
        (string?)row.last_scan_error, new DateTimeOffset(SqliteDate.FromDb((string)row.created_at)).ToUnixTimeSeconds());
}
