using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>ingestion-formats-v1 §3–4: new default include list and the one-time upgrade of folders still on the
/// old default (same cases as macOS FolderDefaultsUpgradeTests).</summary>
public sealed class FolderDefaultsUpgradeTests
{
    private sealed class Identity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => new("test", ["docs"], "root-1");
    }

    /// <summary>A flat folder whose files never change between scans.</summary>
    private sealed class StaticFolder(IReadOnlyList<FolderEntry> entries) : IFolderFileSystem
    {
        public FolderIdentity Resolve(string rootPath) => new Identity().Resolve(rootPath);
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) =>
            directory.Length == 0 ? entries : Array.Empty<FolderEntry>();
        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp("root-1", 0, 0) : entries.Single(e => e.RelPath == relativePath).Stamp;
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) =>
            new([], entries.Single(e => e.RelPath == relativePath).Stamp, "hash-" + relativePath);
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) =>
            throw new FolderIngestionException("unexpectedError");
    }

    private sealed class Clock(long value) : IIngestLeaseClock
    {
        public long Now => value;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.FromCanceled(new CancellationToken(true));
    }

    private static JsonElement Fixture() => SharedFixtures.Json("contracts/ingestion-formats-v1.json");

    private static void InsertFolder(SqliteConnection connection, string includeExts, string limits = "{}")
    {
        connection.Execute("""
            INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
            VALUES(1,1,'/docs','{"volumeId":"test","components":["docs"],"rootFileId":"root-1"}','Docs',$includeExts,'[]',$limits,'2026-01-01 00:00:00.000')
            """, new { includeExts, limits });
        connection.Execute("DELETE FROM grdb_migrations WHERE identifier=$marker", new { marker = FolderDefaultsUpgrade.Marker });
    }

    private static string[] IncludeExts(SqliteConnection connection) =>
        JsonSerializer.Deserialize<string[]>(connection.ExecuteScalar<string>("SELECT include_exts FROM folder_sources WHERE id=1")!)!;

    private static int ScanJobs(SqliteConnection connection) =>
        connection.ExecuteScalar<int>("SELECT count(*) FROM ingest_jobs WHERE kind='scan' AND target='folder:1'");

    [Fact]
    public void DefaultsMatchContract()
    {
        var contract = Fixture();
        Assert.Equal(contract.GetProperty("defaultIncludeExts").EnumerateArray().Select(e => e.GetString()!), FolderRules.Defaults.IncludeExts);
        Assert.Equal(contract.GetProperty("oldDefaultIncludeExts").EnumerateArray().Select(e => e.GetString()!), FolderDefaultsUpgrade.OldDefault);
        Assert.Equal(contract.GetProperty("upgradeMarker").GetString(), FolderDefaultsUpgrade.Marker);
        foreach (var extension in FolderRules.Defaults.IncludeExts)
            Assert.NotNull(SourceTypeExtensions.Detect("a." + extension));
    }

    [Fact]
    public void UpgradeCases()
    {
        var rows = Fixture().GetProperty("cases").EnumerateArray()
            .Where(row => row.GetProperty("operation").GetString() == "upgrade").ToArray();
        Assert.Equal(6, rows.Length);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var stored = row.GetProperty("input").GetProperty("includeExts").EnumerateArray().Select(e => e.GetString()!).ToArray();
            var expected = row.GetProperty("expected").GetProperty("includeExts").EnumerateArray().Select(e => e.GetString()!).ToArray();
            using var store = new NotebookStore(StorePath.InMemory);
            Assert.Equal(1, store.CreateNotebook("n").Id);
            InsertFolder(store.Connection, JsonSerializer.Serialize(stored));
            var notebooks = FolderDefaultsUpgrade.Apply(store.Connection, 5);
            bool upgraded = !expected.SequenceEqual(stored);
            Assert.True(expected.SequenceEqual(IncludeExts(store.Connection)), name);
            Assert.Equal(upgraded ? new long[] { 1 } : Array.Empty<long>(), notebooks);
            Assert.Equal(upgraded ? 1 : 0, ScanJobs(store.Connection));
            Assert.Equal(1, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM grdb_migrations WHERE identifier=$marker",
                new { marker = FolderDefaultsUpgrade.Marker }));
        }
    }

    [Fact]
    public void UpgradeRunsOnceAndReclassifiesInventory()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        Assert.Equal(1, store.CreateNotebook("n").Id);
        var connection = store.Connection;
        InsertFolder(connection, JsonSerializer.Serialize(FolderDefaultsUpgrade.OldDefault), """{"maxFileBytes":100}""");
        foreach (var (path, kind, reason, size) in new (string, string, string?, long)[]
                 {
                     ("a.msg", "skipped", "unsupported_ext", 10), ("b.EML", "skipped", "unsupported_ext", 101),
                     ("c.xls", "skipped", "unsupported_ext", 10), ("d.md", "eligible", null, 10),
                     (".cache/e.msg", "skipped", "ignored", 10), ("f.xlsm", "skipped", "unsupported_ext", 100)
                 })
            connection.Execute("""
                INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
                VALUES(1,$path,$kind,$reason,1,$size,0)
                """, new { path, kind, reason, size });
        FolderDefaultsUpgrade.Apply(connection, 5);
        var items = connection.Query("SELECT rel_path,kind,skip_reason FROM scan_items ORDER BY rel_path")
            .Select(row => $"{(string)row.rel_path}|{(string)row.kind}|{(string?)row.skip_reason ?? "-"}").ToArray();
        Assert.Equal(new[]
        {
            ".cache/e.msg|skipped|ignored", "a.msg|eligible|-", "b.EML|skipped|over_limit", "c.xls|skipped|unsupported_ext",
            "d.md|eligible|-", "f.xlsm|eligible|-"
        }, items);
        var job = connection.QuerySingle("SELECT state,options_json,next_retry_at FROM ingest_jobs WHERE kind='scan' AND target='folder:1'");
        Assert.Equal("queued", (string)job.state);
        Assert.Equal("""{"verifyAll":false}""", (string)job.options_json);
        Assert.Null((long?)job.next_retry_at);

        // Once per database: a user who restores the old list keeps it.
        connection.Execute("UPDATE folder_sources SET include_exts=$value WHERE id=1",
            new { value = JsonSerializer.Serialize(FolderDefaultsUpgrade.OldDefault) });
        Assert.Empty(FolderDefaultsUpgrade.Apply(connection, 6));
        Assert.Equal(FolderDefaultsUpgrade.OldDefault, IncludeExts(connection));
        Assert.Equal(1, ScanJobs(connection));
    }

    /// <summary>End to end: a database from the previous release (old default, mail and macro files skipped as
    /// unsupported) is upgraded on open, and the next scan turns those unchanged files into sources of the right kind.</summary>
    [Fact]
    public async Task StoreOpenUpgradesAndNextScanPicksUpSkippedFiles()
    {
        string directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var path = new StorePath(Path.Combine(directory, "store.sqlite"));
            var fs = new StaticFolder(new[] { "a.md", "b.msg", "c.xlsm", "d.eml", "e.xls" }
                .Select(name => new FolderEntry(name, false, false, new FileStamp(name, 7, 9))).ToArray());
            var tables = UnicodeTables.LoadBundled();
            using (var store = new NotebookStore(path))
            {
                long notebook = store.CreateNotebook("mail").Id!.Value;
                var folder = store.CreateFolder(notebook, new FolderDraft("/docs", "Docs", FolderDefaultsUpgrade.OldDefault, [], "{}",
                    "cp1250", false), new Identity(), 0);
                long id = store.EnqueueJob(new IngestJobDraft("scan", $"folder:{folder.Id}", null), 1);
                Assert.NotNull(store.ClaimJob(1, "old-scan", id));
                await new FolderScanner(store, fs, tables, new Clock(2)).ScanAsync(folder.Id, false, new JobFence(id, "old-scan"), 1);
                Assert.Equal(new[] { "a.md" }, store.Connection.Query<string>("SELECT rel_path FROM sources ORDER BY rel_path"));
                Assert.Equal(new[] { "b.msg", "c.xlsm", "d.eml", "e.xls" }, store.Connection.Query<string>(
                    "SELECT rel_path FROM scan_items WHERE skip_reason='unsupported_ext' ORDER BY rel_path"));
                // A database written by the previous release has no marker.
                store.Connection.Execute("DELETE FROM grdb_migrations WHERE identifier=$marker", new { marker = FolderDefaultsUpgrade.Marker });
                store.Connection.Execute("DELETE FROM ingest_jobs WHERE kind='extract'");
            }
            using (var store = new NotebookStore(path))
            {
                Assert.Equal(FolderRules.Defaults.IncludeExts, store.Folder(1)!.Draft.IncludeExts);
                var queued = store.Connection.Query<long>("SELECT id FROM ingest_jobs WHERE kind='scan' AND state='queued' ORDER BY id").ToArray();
                Assert.Single(queued);
                Assert.NotNull(store.ClaimJob(10, "new-scan", queued[0]));
                await new FolderScanner(store, fs, tables, new Clock(11)).ScanAsync(1, false, new JobFence(queued[0], "new-scan"), 10);
                Assert.Equal(new[] { "a.md|markdown", "b.msg|email", "c.xlsm|xlsx", "d.eml|email" },
                    store.Connection.Query("SELECT rel_path,type FROM sources ORDER BY rel_path")
                        .Select(row => $"{(string)row.rel_path}|{(string)row.type}"));
                Assert.Equal(new[] { "e.xls" },
                    store.Connection.Query<string>("SELECT rel_path FROM scan_items WHERE kind='skipped' ORDER BY rel_path"));
                Assert.Equal(new[] { "b.msg", "c.xlsm", "d.eml" }, store.Connection.Query<string>("""
                    SELECT s.rel_path FROM ingest_jobs j JOIN sources s ON j.target='source:' || s.id
                    WHERE j.kind='extract' AND j.state='queued' AND s.rel_path<>'a.md' ORDER BY s.rel_path
                    """));
            }
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, recursive: true);
        }
    }
}
