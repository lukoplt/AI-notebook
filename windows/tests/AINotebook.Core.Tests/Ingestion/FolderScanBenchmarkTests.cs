using System.Diagnostics;
using System.Globalization;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Storage;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Opt-in large-folder rescan benchmark (AINOTEBOOK_SCAN_BENCH=1): a file-backed database with ~8,000 already
/// ingested files (ready + published), then a no-change rescan and a 1 %-changed rescan through the real
/// <see cref="FolderScanner"/>. A handler emulates the status strip: every <see cref="NotebookStore.IndexingStatusChanged"/>
/// re-reads the notebook's status synchronously. Without the variable it returns immediately (xunit 2 has no dynamic skip).
/// </summary>
[Trait("Category", "Benchmark")]
public sealed class FolderScanBenchmarkTests(ITestOutputHelper output)
{
    private static int Setting(string name, int fallback) =>
        int.TryParse(Environment.GetEnvironmentVariable("AINOTEBOOK_SCAN_BENCH_" + name), NumberStyles.Integer,
            CultureInfo.InvariantCulture, out int value) ? value : fallback;

    [Fact]
    public async Task LargeFolderRescan()
    {
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_SCAN_BENCH") != "1") return;
        int dirs = Setting("DIRS", 40), subdirs = Setting("SUBDIRS", 4), perDir = Setting("FILES", 50);
        int unsupportedEvery = Setting("UNSUPPORTED_EVERY", 20), chunksPerSource = Setting("CHUNKS", 8);
        string directory = Environment.GetEnvironmentVariable("AINOTEBOOK_SCAN_BENCH_DIR") ?? Path.GetTempPath();
        string path = Path.Combine(directory, $"scan-bench-cs-{Guid.NewGuid():N}.sqlite");
        var tables = UnicodeTables.LoadBundled();
        try
        {
            using var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null);
            var fs = BenchFS.Make(dirs, subdirs, perDir, unsupportedEvery, new HashSet<string>(StringComparer.Ordinal));
            long notebookId = store.CreateNotebook("bench").Id!.Value;
            var folder = store.CreateFolder(notebookId, new FolderDraft("/bench", "Bench", FolderRules.Defaults.IncludeExts,
                FolderRules.Defaults.IgnoreGlobs, "{}", "cp1250", true), fs, 0);

            // Initial ingest: the real scanner creates every source, then SQL marks them ready + published.
            await Scan(store, folder.Id, fs, tables, "seed");
            int eligible = Seed(store, folder.Id, fs, chunksPerSource);
            int total = fs.Files.Count;
            Assert.True(eligible > total * 9 / 10);

            var counter = new SqlCounter();
            int ingestionNotes = 0, statusNotes = 0;
            long statusReloadTicks = 0;
            store.FolderIngestionChanged += _ => Interlocked.Increment(ref ingestionNotes);
            store.IndexingStatusChanged += _ =>
            {
                Interlocked.Increment(ref statusNotes);
                long start = Stopwatch.GetTimestamp();
                counter.Paused = true;
                store.IndexingStatus(notebookId, 10);
                counter.Paused = false;
                Interlocked.Add(ref statusReloadTicks, Stopwatch.GetTimestamp() - start);
            };
            lock (store.Gate) counter.Attach(store.Connection);

            async Task Measure(string label, BenchFS tree, int expectQueued)
            {
                counter.Reset();
                ingestionNotes = 0;
                statusNotes = 0;
                statusReloadTicks = 0;
                long before = QueuedExtracts(store);
                long start = Stopwatch.GetTimestamp();
                await Scan(store, folder.Id, tree, tables, label);
                double ms = Stopwatch.GetElapsedTime(start).TotalMilliseconds;
                var (statements, transactions, commits) = counter.Snapshot;
                Assert.Equal(expectQueued, QueuedExtracts(store) - before);
                Assert.Equal("idle", store.Folder(folder.Id)!.ScanState);
                long seen;
                lock (store.Gate)
                    seen = store.Connection.ExecuteScalar<long>("""
                        SELECT count(*) FROM scan_items WHERE folder_id=$id
                          AND seen_generation=(SELECT scan_generation FROM folder_sources WHERE id=$id)
                        """, new { id = folder.Id });
                Assert.Equal(total, seen);
                output.WriteLine(string.Format(CultureInfo.InvariantCulture,
                    "SCAN-BENCH dotnet {0} files={1} eligible={2}: {3:F0} ms, transactions={4} (writes={5}), statements={6}, FolderIngestionChanged={7}, IndexingStatusChanged={8}, status reloads {9:F0} ms",
                    label, total, eligible, ms, transactions, commits, statements, ingestionNotes, statusNotes,
                    statusReloadTicks * 1000.0 / Stopwatch.Frequency));
            }

            await Measure("no-change", fs, 0);
            string[] paths;
            lock (store.Gate)
                paths = store.Connection.Query<string>("SELECT rel_path FROM sources ORDER BY id").ToArray();
            var changed = new HashSet<string>(Enumerable.Range(0, (paths.Length + 99) / 100).Select(i => paths[i * 100]), StringComparer.Ordinal);
            await Measure("changed-1pct", BenchFS.Make(dirs, subdirs, perDir, unsupportedEvery, changed), changed.Count);
            lock (store.Gate) counter.Detach(store.Connection);
        }
        finally
        {
            SqliteConnection.ClearAllPools();
            foreach (string suffix in new[] { "", "-journal", "-wal", "-shm" }) File.Delete(path + suffix);
        }
    }

    private static long QueuedExtracts(NotebookStore store)
    {
        lock (store.Gate)
            return store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'");
    }

    private static async Task Scan(NotebookStore store, long folderId, BenchFS fs, UnicodeTables tables, string token)
    {
        long job = store.RequestFolderScan(folderId, false, 10);
        Assert.NotNull(store.ClaimJob(10, token, job));
        await new FolderScanner(store, fs, tables, new BenchClock()).ScanAsync(folderId, false, new JobFence(job, token), 10);
    }

    private static int Seed(NotebookStore store, long folderId, BenchFS fs, int chunksPerSource)
    {
        lock (store.Gate)
        {
            var c = store.Connection;
            using var tx = c.BeginTransaction();
            c.Execute("DROP TRIGGER chunks_ai", transaction: tx);
            var rows = c.Query<(long Id, string RelPath)>("SELECT id,rel_path FROM sources WHERE folder_id=$folderId",
                new { folderId }, tx).ToArray();
            foreach (var (id, relPath) in rows)
            {
                string hash = BenchFS.HashOf(relPath, fs.Files[relPath]);
                long revisionId = c.ExecuteScalar<long>("""
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES ($id,1,$hash,'',1,2,'2026-10-10 00:00:00.000'); SELECT last_insert_rowid();
                    """, new { id, hash }, tx);
                c.Execute("UPDATE sources SET current_revision=$revisionId,published_revision_id=$revisionId,status='ready',content_hash=$hash WHERE id=$id",
                    new { id, revisionId, hash }, tx);
                for (int ord = 0; ord < chunksPerSource; ord++)
                    c.Execute("""
                        INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang)
                        VALUES ($id,$ord,$text,8,$revisionId,$a,$b,'cs')
                        """, new { id, ord, text = $"source {id} chunk {ord} smlouva faktura report", revisionId, a = ord * 40, b = ord * 40 + 40 }, tx);
            }
            c.Execute("UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE kind='extract'", transaction: tx);
            c.Execute("CREATE TRIGGER chunks_ai AFTER INSERT ON source_chunks BEGIN INSERT INTO chunks_fts(rowid,text,chunk_id) VALUES(new.id,new.text,new.id); END",
                transaction: tx);
            tx.Commit();
            return rows.Length;
        }
    }

    /// <summary>Counts statements, BEGINs and committed write transactions on the store's connection.</summary>
    private sealed class SqlCounter
    {
        private long _statements, _transactions, _commits;
        public volatile bool Paused;

        public void Attach(SqliteConnection connection)
        {
            SQLitePCL.raw.sqlite3_trace(connection.Handle, (SQLitePCL.delegate_trace)((_, statement) =>
            {
                if (Paused) return;
                Interlocked.Increment(ref _statements);
                if (statement.utf8_to_string().StartsWith("BEGIN", StringComparison.Ordinal)) Interlocked.Increment(ref _transactions);
            }), null);
            SQLitePCL.raw.sqlite3_commit_hook(connection.Handle, _ =>
            {
                if (!Paused) Interlocked.Increment(ref _commits);
                return 0;
            }, null);
        }

        public static void DetachHooks(SqliteConnection connection)
        {
            SQLitePCL.raw.sqlite3_trace(connection.Handle, (SQLitePCL.delegate_trace?)null, null);
            SQLitePCL.raw.sqlite3_commit_hook(connection.Handle, null, null);
        }

        public void Detach(SqliteConnection connection) => DetachHooks(connection);

        public void Reset()
        {
            Interlocked.Exchange(ref _statements, 0);
            Interlocked.Exchange(ref _transactions, 0);
            Interlocked.Exchange(ref _commits, 0);
        }

        public (long Statements, long Transactions, long Commits) Snapshot =>
            (Interlocked.Read(ref _statements), Interlocked.Read(ref _transactions), Interlocked.Read(ref _commits));
    }

    private sealed class BenchClock : IIngestLeaseClock
    {
        public long Now => 10;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.Delay(1000, ct);
    }

    /// <summary>In-memory tree; hashes derive from path and mtime, so a changed mtime is changed content.</summary>
    private sealed class BenchFS(Dictionary<string, FolderEntry[]> directories, Dictionary<string, FileStamp> files) : IFolderFileSystem
    {
        public Dictionary<string, FileStamp> Files { get; } = files;

        public static string HashOf(string path, FileStamp stamp) =>
            $"h:{path}:{stamp.MtimeNs.ToString(CultureInfo.InvariantCulture)}";

        public static BenchFS Make(int dirs, int subdirs, int perDir, int unsupportedEvery, HashSet<string> changed)
        {
            string[] eligible = ["md", "pdf", "docx", "txt", "xlsx", "eml"], unsupported = ["png", "zip", "exe"];
            var directories = new Dictionary<string, FolderEntry[]>(StringComparer.Ordinal);
            var files = new Dictionary<string, FileStamp>(StringComparer.Ordinal);
            static FolderEntry Dir(string path) => new(path, true, false, new FileStamp("dir:" + path, 0, 0));
            int index = 0;
            directories[""] = Enumerable.Range(0, dirs).Select(d => Dir($"d{d:D3}")).ToArray();
            for (int d = 0; d < dirs; d++)
            {
                string top = $"d{d:D3}";
                directories[top] = Enumerable.Range(0, subdirs).Select(s => Dir($"{top}/s{s}")).ToArray();
                for (int s = 0; s < subdirs; s++)
                {
                    string dir = $"{top}/s{s}";
                    var entries = new FolderEntry[perDir];
                    for (int f = 0; f < perDir; f++)
                    {
                        index++;
                        string ext = index % unsupportedEvery == 0 ? unsupported[index % unsupported.Length] : eligible[index % eligible.Length];
                        string path = $"{dir}/file-{f}.{ext}";
                        var stamp = new FileStamp($"f{index}", changed.Contains(path) ? 2_000 : 1_000, 1_000 + index % 997);
                        files[path] = stamp;
                        entries[f] = new FolderEntry(path, false, false, stamp);
                    }
                    directories[dir] = entries;
                }
            }
            return new BenchFS(directories, files);
        }

        public FolderIdentity Resolve(string rootPath) => new("bench", ["bench"], "root");
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) =>
            directories.TryGetValue(directory, out var entries) ? entries : [];
        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp("root", 0, 0)
            : directories.ContainsKey(relativePath) ? new FileStamp("dir:" + relativePath, 0, 0)
            : Files.TryGetValue(relativePath, out var stamp) ? stamp : throw new FileNotFoundException(relativePath);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) =>
            Files.TryGetValue(relativePath, out var stamp) ? new FolderRead([], stamp, HashOf(relativePath, stamp))
            : throw new FileNotFoundException(relativePath);
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new NotSupportedException();
    }
}
