using System.Text.Json;
using AINotebook.Core.Ingestion;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// One-time upgrade of folders still on the pre-mail default include list to the current
/// FolderRules.Defaults.IncludeExts (contract ingestion-formats-v1 §4, same rules as macOS FolderDefaultsUpgrade).
/// Runs on store open after the migrations; the marker row in grdb_migrations makes it run once per database
/// (unknown identifiers are ignored by GRDB and the migrator), so a user who later restores the old list keeps
/// it. Customized lists are never touched. The caller holds the store's connection gate.
/// </summary>
internal static class FolderDefaultsUpgrade
{
    internal const string Marker = "data_folder_include_exts_v2";
    internal static readonly string[] OldDefault = ["pdf", "txt", "md", "markdown", "docx", "pptx", "xlsx"];
    internal static IReadOnlyList<string> Added => FolderRules.Defaults.IncludeExts.Where(ext => !OldDefault.Contains(ext)).ToArray();

    /// <summary>True when stored is a permutation of the old default (same elements, same count).</summary>
    internal static bool IsOldDefault(IReadOnlyList<string> stored) =>
        stored.OrderBy(value => value, StringComparer.Ordinal)
            .SequenceEqual(OldDefault.OrderBy(value => value, StringComparer.Ordinal), StringComparer.Ordinal);

    /// <summary>Returns the notebook ids of upgraded folders, ascending by folder id.</summary>
    internal static IReadOnlyList<long> Apply(SqliteConnection conn, long now)
    {
        if (conn.ExecuteScalar<long>("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='folder_sources'") == 0)
            return Array.Empty<long>();
        using var tx = conn.BeginTransaction();
        conn.Execute("CREATE TABLE IF NOT EXISTS grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)", transaction: tx);
        if (conn.ExecuteScalar<long>("SELECT count(*) FROM grdb_migrations WHERE identifier=$marker",
                new { marker = Marker }, tx) != 0)
            return Array.Empty<long>();
        string encoded = JsonSerializer.Serialize(FolderRules.Defaults.IncludeExts);
        var added = new HashSet<string>(Added, StringComparer.Ordinal);
        var notebooks = new List<long>();
        var folders = conn.Query("SELECT id,notebook_id,include_exts,limits FROM folder_sources ORDER BY id",
            transaction: tx).ToList();
        foreach (var folder in folders)
        {
            string[]? stored;
            try { stored = JsonSerializer.Deserialize<string[]>((string)folder.include_exts); }
            catch (JsonException) { continue; }
            if (stored is null || stored.Any(value => value is null) || !IsOldDefault(stored)) continue;
            long folderId = (long)folder.id;
            conn.Execute("UPDATE folder_sources SET include_exts=$encoded WHERE id=$folderId", new { encoded, folderId }, tx);
            IngestionLimits? limits;
            try { limits = IngestionLimits.FromJson((string)folder.limits); }
            catch (FolderIngestionException) { limits = null; }
            if (limits is not null)
            {
                var items = conn.Query("""
                    SELECT rel_path,size_bytes FROM scan_items
                    WHERE folder_id=$folderId AND kind='skipped' AND skip_reason='unsupported_ext' ORDER BY rel_path
                    """, new { folderId }, tx).ToList();
                foreach (var item in items)
                {
                    string relPath = (string)item.rel_path;
                    if (!added.Contains(FolderRuleClassifier.Extension(relPath))) continue;
                    long? size = (long?)item.size_bytes;
                    conn.Execute(size is { } bytes && bytes > limits.FileBytes
                        ? "UPDATE scan_items SET skip_reason='over_limit' WHERE folder_id=$folderId AND rel_path=$relPath"
                        : "UPDATE scan_items SET kind='eligible',skip_reason=NULL WHERE folder_id=$folderId AND rel_path=$relPath",
                        new { folderId, relPath }, tx);
                }
            }
            // The scan turns newly included files into sources even though their mtime/size are unchanged.
            string target = "folder:" + folderId.ToString(System.Globalization.CultureInfo.InvariantCulture);
            if (!conn.ExecuteScalar<bool>(
                    "SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=$target AND state='queued')",
                    new { target }, tx))
            {
                long id = RevisionJobSQL.EnqueueJob(conn, tx, new IngestJobDraft("scan", target, null, """{"verifyAll":false}"""), now);
                conn.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$id", new { id }, tx);
            }
            notebooks.Add((long)folder.notebook_id);
        }
        conn.Execute("INSERT INTO grdb_migrations(identifier) VALUES($marker)", new { marker = Marker }, tx);
        tx.Commit();
        return notebooks;
    }
}
