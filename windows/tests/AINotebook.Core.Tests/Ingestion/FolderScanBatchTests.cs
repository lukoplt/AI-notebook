using System.Globalization;
using System.Text;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Batched scan observations (contract ingestion-scan-perf-v1 §1–2).</summary>
public sealed class FolderScanBatchTests
{
    private static readonly Lazy<UnicodeTables> Tables = new(UnicodeTables.LoadBundled);

    private static NotebookStore MakeStore()
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        store.CreateNotebook("nb");
        store.CreateFolder(1, new FolderDraft("/batch", "Batch", ["md", "txt"], [], "{}", "cp1250", true), new FlatFS([]), 0);
        return store;
    }

    private static Dictionary<string, FileStamp> Files(int count) =>
        Enumerable.Range(0, count).ToDictionary(
            index => $"f{index:D4}.{(index % 10 == 9 ? "png" : "md")}",
            index => new FileStamp($"id{index}", 1, 10 + index), StringComparer.Ordinal);

    private static async Task Scan(NotebookStore store, FlatFS fs, string token)
    {
        long job = store.RequestFolderScan(1, false, 10);
        Assert.NotNull(store.ClaimJob(10, token, job));
        await new FolderScanner(store, fs, Tables.Value, new Clock()).ScanAsync(1, false, new JobFence(job, token), 10);
    }

    private static void PublishAll(NotebookStore store, FlatFS fs)
    {
        lock (store.Gate)
        {
            var c = store.Connection;
            foreach (var (id, relPath) in c.Query<(long, string)>("SELECT id,rel_path FROM sources WHERE folder_id=1").ToArray())
            {
                string hash = FlatFS.HashOf(relPath, fs.Files[relPath]);
                long revision = c.ExecuteScalar<long>("""
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES ($id,1,$hash,'',1,2,'2026-10-10 00:00:00.000'); SELECT last_insert_rowid();
                    """, new { id, hash });
                c.Execute("UPDATE sources SET current_revision=$revision,published_revision_id=$revision,status='ready',content_hash=$hash WHERE id=$id",
                    new { id, revision, hash });
            }
            c.Execute("UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE kind='extract'");
        }
    }

    private sealed class Tally(NotebookStore store)
    {
        public int Ingestion, Status;
        public Tally Attach()
        {
            store.FolderIngestionChanged += _ => Interlocked.Increment(ref Ingestion);
            store.IndexingStatusChanged += _ => Interlocked.Increment(ref Status);
            return this;
        }
    }

    /// <summary>Write transactions and statements that modify sources/scan_items rows.</summary>
    private sealed class WriteTrace
    {
        public int Writes, RowWrites;
        public WriteTrace Attach(NotebookStore store)
        {
            lock (store.Gate)
                SQLitePCL.raw.sqlite3_trace(store.Connection.Handle, (SQLitePCL.delegate_trace)((_, statement) =>
                {
                    string sql = statement.utf8_to_string();
                    if (sql.StartsWith("BEGIN IMMEDIATE", StringComparison.Ordinal)) Interlocked.Increment(ref Writes);
                    if (sql.StartsWith("UPDATE sources", StringComparison.Ordinal) ||
                        sql.TrimStart().StartsWith("INSERT INTO scan_items", StringComparison.Ordinal))
                        Interlocked.Increment(ref RowWrites);
                }), null);
            return this;
        }
    }

    [Fact]
    public async Task NoChangeRescanBatchesAndSkipsUnchangedRows()
    {
        using var store = MakeStore();
        var fs = new FlatFS(Files(600));
        await Scan(store, fs, "seed");
        PublishAll(store, fs);
        var notes = new Tally(store).Attach();
        var trace = new WriteTrace().Attach(store);
        await Scan(store, fs, "again");

        // request + claim + begin + ceil(600 / 256) batches + finish, never one transaction per file.
        int batches = (600 + FolderScanner.ObserveBatchSize - 1) / FolderScanner.ObserveBatchSize;
        Assert.True(trace.Writes <= 3 + batches + 1, $"writes={trace.Writes}");
        Assert.Equal(0, trace.RowWrites);
        Assert.Equal(3, notes.Ingestion);
        // Every catalog signal carries a status signal; at least one more reports files seen.
        Assert.True(notes.Status >= 3 + 1, $"status={notes.Status}");
        var folder = store.Folder(1)!;
        Assert.Equal("idle", folder.ScanState);
        lock (store.Gate)
        {
            Assert.Equal(600, store.Connection.ExecuteScalar<long>(
                "SELECT count(*) FROM scan_items WHERE folder_id=1 AND seen_generation=$g", new { g = folder.ScanGeneration }));
            Assert.Equal(0, store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE state='queued'"));
        }
    }

    [Fact]
    public async Task ChangedFilesInBatchPostOneCatalogSignalPerBatch()
    {
        using var store = MakeStore();
        var fs = new FlatFS(Files(300));
        await Scan(store, fs, "seed");
        PublishAll(store, fs);
        fs.Files["f0000.md"] = new FileStamp("id0", 2, 10);
        fs.Files["f0001.md"] = new FileStamp("id1", 2, 11);
        var notes = new Tally(store).Attach();
        await Scan(store, fs, "again");
        lock (store.Gate)
            Assert.Equal(2, store.Connection.ExecuteScalar<long>("SELECT count(*) FROM ingest_jobs WHERE kind='extract' AND state='queued'"));
        // request + begin + the first batch (contains both changes) + finish.
        Assert.Equal(4, notes.Ingestion);
    }

    [Fact]
    public async Task BatchMatchesPerFileObservations()
    {
        async Task<(NotebookStore, ScanTicket)> Prepared()
        {
            var store = MakeStore();
            var fs = new FlatFS(Files(20));
            await Scan(store, fs, "seed");
            PublishAll(store, fs);
            lock (store.Gate) store.Connection.Execute("UPDATE sources SET status='pending' WHERE rel_path='f0003.md'");
            long job = store.RequestFolderScan(1, false, 10);
            store.ClaimJob(10, "t", job);
            return (store, store.BeginFolderScan(1, new JobFence(job, "t"), 10)!);
        }
        var observations = new[]
        {
            FolderScanObservation.File(new FolderObservation("f0000.md", new FileStamp("id0", 1, 10), "eligible", null, null)),
            FolderScanObservation.File(new FolderObservation("f0001.md", new FileStamp("id1", 5, 11), "eligible", null, "changed")),
            FolderScanObservation.File(new FolderObservation("f0002.md", new FileStamp("id2", 1, 12), "eligible", null,
                FlatFS.HashOf("f0002.md", new FileStamp("id2", 1, 12)))),
            FolderScanObservation.File(new FolderObservation("f0003.md", new FileStamp("id3", 1, 13), "eligible", null, null)),
            FolderScanObservation.File(new FolderObservation("f0004.md", new FileStamp("id4", 1, 14), "skipped", "over_limit", null)),
            FolderScanObservation.File(new FolderObservation("f0009.png", new FileStamp("id9", 1, 19), "skipped", "unsupported_ext", null)),
            FolderScanObservation.File(new FolderObservation("f0019.png", new FileStamp("id19", 3, 29), "skipped", "unsupported_ext", null)),
            FolderScanObservation.File(new FolderObservation("new.md", new FileStamp("n", 1, 1), "eligible", null, "n1")),
            FolderScanObservation.InteriorLink("f0005.md", new FileStamp("l5", 1, 0)),
            FolderScanObservation.InteriorLink("unknown-link.md", new FileStamp("l", 1, 0)),
        };
        var (batched, batchTicket) = await Prepared();
        using (batched)
        {
            var notes = new Tally(batched).Attach();
            Assert.Equal(new FolderObserveBatchResult(6, 3), batched.ObserveFolderFiles(batchTicket, observations, 11));
            Assert.Equal(1, notes.Ingestion);
            var (single, singleTicket) = await Prepared();
            using (single)
            {
                foreach (var item in observations)
                {
                    if (item.KnownOnly && !single.HasFolderSource(1, item.Observation.RelPath)) continue;
                    single.ObserveFolderFile(singleTicket, item.Observation, 11);
                }
                Assert.Equal(Projection(single), Projection(batched));
            }
        }
    }

    [Fact]
    public void StaleBatchCommitsNothingAndPostsNothing()
    {
        using var store = MakeStore();
        long job = store.RequestFolderScan(1, false, 10);
        store.ClaimJob(10, "t", job);
        var ticket = store.BeginFolderScan(1, new JobFence(job, "t"), 10)!;
        var notes = new Tally(store).Attach();
        var stale = ticket with { Fence = new JobFence(job, "other") };
        Assert.Equal("staleLease", Assert.Throws<StorageV19Exception>(() => store.ObserveFolderFiles(stale,
            [FolderScanObservation.File(new FolderObservation("a.md", new FileStamp("a", 1, 1), "eligible", null, "a"))], 11)).Code);
        // An invalid observation rejects the whole batch before any write.
        Assert.ThrowsAny<Exception>(() => store.ObserveFolderFiles(ticket,
        [
            FolderScanObservation.File(new FolderObservation("ok.md", new FileStamp("a", 1, 1), "eligible", null, "a")),
            FolderScanObservation.File(new FolderObservation("../bad.md", new FileStamp("b", 1, 1), "eligible", null, "b")),
        ], 11));
        Assert.Empty(store.ScanItems(1));
        Assert.Equal(0, notes.Ingestion);
        Assert.Equal(0, notes.Status);
        Assert.Equal(new FolderObserveBatchResult(0, 0), store.ObserveFolderFiles(ticket, [], 11));
        Assert.Equal(0, notes.Status);
    }

    private static string Projection(NotebookStore store)
    {
        lock (store.Gate)
        {
            var c = store.Connection;
            var text = new StringBuilder();
            void Rows(string sql)
            {
                foreach (IDictionary<string, object?> row in c.Query(sql))
                    text.AppendLine(string.Join("|", row.Select(pair => $"{pair.Key}={Convert.ToString(pair.Value, CultureInfo.InvariantCulture)}")));
            }
            Rows("""
                SELECT id,rel_path,status,error,availability,eligible,mtime,size_bytes,content_hash,current_revision,published_revision_id
                FROM sources ORDER BY id
                """);
            Rows("SELECT * FROM scan_items ORDER BY rel_path");
            Rows("SELECT id,kind,target,target_revision,state,next_retry_at FROM ingest_jobs ORDER BY id");
            return text.ToString();
        }
    }

    private sealed class Clock : IIngestLeaseClock
    {
        public long Now => 10;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.CompletedTask;
    }

    /// <summary>Flat in-memory folder; hashes derive from path and mtime.</summary>
    private sealed class FlatFS(Dictionary<string, FileStamp> files) : IFolderFileSystem
    {
        public Dictionary<string, FileStamp> Files { get; } = files;
        public static string HashOf(string path, FileStamp stamp) => $"h:{path}:{stamp.MtimeNs.ToString(CultureInfo.InvariantCulture)}";
        public FolderIdentity Resolve(string rootPath) => new("batch", ["batch"], "root");
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => directory.Length != 0 ? []
            : Files.Keys.Order(StringComparer.Ordinal).Select(path => new FolderEntry(path, false, false, Files[path])).ToArray();
        public FileStamp Stat(FolderSource root, string relativePath) => relativePath.Length == 0 ? new FileStamp("root", 0, 0)
            : Files.TryGetValue(relativePath, out var stamp) ? stamp : throw new FileNotFoundException(relativePath);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) =>
            Files.TryGetValue(relativePath, out var stamp) ? new FolderRead([], stamp, HashOf(relativePath, stamp))
            : throw new FileNotFoundException(relativePath);
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) => throw new NotSupportedException();
    }
}
