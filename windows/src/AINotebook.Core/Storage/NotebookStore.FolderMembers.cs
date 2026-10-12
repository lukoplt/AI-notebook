using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

/// <summary>One page of a persisted folder's member sources (contract folder-members-v1).</summary>
public sealed record FolderMemberPage(IReadOnlyList<Source> Members, int Offset, int Total)
{
    public int NextOffset => Offset + Members.Count;
    public bool HasMore => NextOffset < Total;
}

public sealed partial class NotebookStore
{
    /// <summary>Largest page <see cref="FolderMembers"/> accepts.</summary>
    public const int FolderMembersMaxLimit = 500;

    /// <summary>Page size the Sources list requests when a folder is expanded or extended.</summary>
    public const int FolderMembersPageSize = 200;

    /// <summary>
    /// Members of one folder ordered by rel_path in SQLite BINARY (UTF-8 byte) order, then id.
    /// Page and total come from one transaction, so they are mutually consistent.
    /// </summary>
    public FolderMemberPage FolderMembers(long folderId, int offset, int limit)
    {
        if (offset < 0 || limit < 1 || limit > FolderMembersMaxLimit) throw new StorageV19Exception("invalidValue");
        lock (_gate)
        {
            using var transaction = _conn.BeginTransaction();
            RequireFolderNotebook(folderId, transaction);
            int total = _conn.ExecuteScalar<int>(
                "SELECT COUNT(*) FROM sources WHERE folder_id=$folderId AND type<>'note'", new { folderId }, transaction);
            var members = _conn.Query(
                $"SELECT {SourceCols} FROM sources WHERE folder_id=$folderId AND type<>'note' ORDER BY rel_path, id LIMIT $limit OFFSET $offset",
                new { folderId, limit, offset }, transaction)
                .Select(r => (Source)MapSource(r)).ToList();
            transaction.Commit();
            return new FolderMemberPage(members, offset, total);
        }
    }

    /// <summary>Non-note sources that belong to no folder, newest first (the ungrouped part of the Sources list).</summary>
    public IReadOnlyList<Source> LooseSources(long notebookId)
    {
        lock (_gate)
            return _conn.Query(
                $"SELECT {SourceCols} FROM sources WHERE notebook_id=$nb AND folder_id IS NULL AND type<>'note' ORDER BY ingested_at DESC, id DESC",
                new { nb = notebookId })
                .Select(r => (Source)MapSource(r)).ToList();
    }
}
