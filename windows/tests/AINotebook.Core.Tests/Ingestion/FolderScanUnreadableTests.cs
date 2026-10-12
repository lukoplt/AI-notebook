using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// A file that cannot be read during a scan is not observed; only its directory becomes incomplete (contract
/// ingestion-scan-perf-v1 §5, fixture ingestion-scan-cadence-v1 operation <c>unreadable-file</c>), exactly as on macOS.
/// </summary>
public sealed class FolderScanUnreadableTests
{
    private static readonly Lazy<UnicodeTables> Tables = new(UnicodeTables.LoadBundled);
    private static readonly string[] TreeFiles = ["a.md", "b.md", "sub/b.md", "sub/c.md"];

    private sealed class Identity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => new("test", ["docs"], "root-1");
    }

    /// <summary>The fixed fixture tree; reading <c>Failing</c> throws <c>Failure</c>.</summary>
    private sealed class TreeFS(string failing, Exception failure) : IFolderFileSystem
    {
        public List<string> Reads { get; } = [];
        private static FileStamp FileStamp(string path) => new("id:" + path, 1, path.Length);
        private static FolderEntry File(string path) => new(path, false, false, FileStamp(path));

        public FolderIdentity Resolve(string rootPath) => new Identity().Resolve(rootPath);
        public bool CaseSensitive(FolderSource root) => true;
        public IReadOnlyList<FolderEntry> List(FolderSource root, string directory) => directory switch
        {
            "" => [File("a.md"), File("b.md"), new FolderEntry("sub", true, false, new FileStamp("dir:sub", 0, 0))],
            "sub" => [File("sub/b.md"), File("sub/c.md")],
            _ => throw new DirectoryNotFoundException(directory),
        };
        public FileStamp Stat(FolderSource root, string relativePath) =>
            relativePath.Length == 0 ? new FileStamp("root-1", 0, 0)
            : relativePath == "sub" ? new FileStamp("dir:sub", 0, 0)
            : TreeFiles.Contains(relativePath) ? FileStamp(relativePath) : throw new FileNotFoundException(relativePath);
        public FolderRead Hash(FolderSource root, string relativePath, long maxBytes)
        {
            Reads.Add(relativePath);
            if (relativePath == failing) throw failure;
            return new FolderRead([], FileStamp(relativePath), "h:" + relativePath);
        }
        public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) =>
            throw new NotSupportedException("scanner must not snapshot file bodies");
    }

    private sealed class Clock : IIngestLeaseClock
    {
        public long Now => 10;
        public Task WaitUntilAsync(long deadline, CancellationToken ct) => Task.CompletedTask;
    }

    private static Exception Failure(string error) => error switch
    {
        "permissionDenied" => new UnauthorizedAccessException("denied"),
        "vanished" => new FileNotFoundException("gone"),
        "changedDuringRead" => new FolderIngestionException("changedDuringExtraction"),
        "becameLink" => new FolderIngestionException("interiorLink"),
        _ => throw new InvalidOperationException("unknown error " + error),
    };

    private static async Task<(NotebookStore Store, TreeFS FS)> Scan(IEnumerable<string> known, string failing, Exception failure)
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("nb").Id!.Value;
        var folder = store.CreateFolder(notebook, new FolderDraft("/docs", "Docs", ["md"], [], "{}", "cp1250", true), new Identity(), 0);
        foreach (string path in known)
        {
            long id = store.CreateSource(notebook, SourceType.Markdown, path, null, null).Id!.Value;
            store.AttachSource(id, folder.Id, path);
            store.CommitForegroundRevision(id, new RevisionDraft("h", "old", 1, 2), ScalarChunker.Chunk("old"), 0, "seed");
        }
        long job = store.RequestFolderScan(folder.Id, false, 10);
        Assert.NotNull(store.ClaimJob(10, "scan", job));
        var fs = new TreeFS(failing, failure);
        await new FolderScanner(store, fs, Tables.Value, new Clock()).ScanAsync(folder.Id, false, new JobFence(job, "scan"), 10);
        return (store, fs);
    }

    /// <summary>The fixture projection: folder state, this scan's inventory, sources and queued extractions.</summary>
    private static string Projection(NotebookStore store)
    {
        lock (store.Gate)
        {
            var folder = store.Connection.QuerySingle("SELECT scan_state, scan_generation, last_scan_error FROM folder_sources");
            long generation = (long)folder.scan_generation;
            var value = new Dictionary<string, object?>
            {
                ["folder"] = new Dictionary<string, object?> { ["lastScanError"] = (string?)folder.last_scan_error, ["scanState"] = (string)folder.scan_state },
                ["inventory"] = store.Connection.Query<string>(
                    "SELECT rel_path FROM scan_items WHERE seen_generation=$generation ORDER BY rel_path", new { generation }).ToArray(),
                ["queuedExtracts"] = store.Connection.Query<string>("""
                    SELECT s.rel_path FROM ingest_jobs j JOIN sources s ON j.target='source:'||s.id
                    WHERE j.kind='extract' AND j.state='queued' ORDER BY s.rel_path
                    """).ToArray(),
                ["sources"] = store.Connection.Query("SELECT rel_path, status, availability, eligible FROM sources ORDER BY rel_path")
                    .Select(row => new Dictionary<string, object?>
                    {
                        ["availability"] = (string)row.availability, ["eligible"] = (long)row.eligible != 0,
                        ["relPath"] = (string)row.rel_path, ["status"] = (string)row.status,
                    }).ToArray(),
            };
            return JsonSerializer.Serialize(value);
        }
    }

    [Fact]
    public async Task UnreadableFileFixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-scan-cadence-v1.json");
        int count = 0;
        foreach (var row in fixture.GetProperty("cases").EnumerateArray())
        {
            if (row.GetProperty("operation").GetString() != "unreadable-file") continue;
            count++;
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            string failing = input.GetProperty("failing").GetString()!;
            var known = input.GetProperty("known").EnumerateArray().Select(value => value.GetString()!).ToArray();
            var (store, fs) = await Scan(known, failing, Failure(input.GetProperty("error").GetString()!));
            using (store)
            {
                Assert.Contains(failing, fs.Reads);
                Assert.True(Normalize(row.GetProperty("expected").GetRawText()) == Normalize(Projection(store)),
                    $"{name}: {Projection(store)}");
            }
        }
        Assert.Equal(8, count);
    }

    /// <summary>A Windows sharing / lock violation (plain IOException) is unreadable too, never a scan error.</summary>
    [Fact]
    public async Task LockedFileOnlyMakesItsDirectoryIncomplete()
    {
        foreach (bool isKnown in new[] { false, true })
        {
            string[] known = isKnown ? ["b.md", "sub/gone.md"] : ["sub/gone.md"];
            var (store, _) = await Scan(known, "b.md", new IOException("The process cannot access the file because it is being used by another process."));
            using (store)
            {
                var folder = store.Folder(1)!;
                Assert.Equal("partial", folder.ScanState);
                Assert.Null(folder.LastScanError);
                lock (store.Gate)
                {
                    Assert.Equal(new[] { "a.md", "sub/b.md", "sub/c.md" }, store.Connection.Query<string>(
                        "SELECT rel_path FROM scan_items WHERE seen_generation=$generation ORDER BY rel_path",
                        new { generation = folder.ScanGeneration }).ToArray());
                    Assert.Equal("missing", store.Connection.QuerySingle<string>("SELECT availability FROM sources WHERE rel_path='sub/gone.md'"));
                    var b = store.Connection.QuerySingleOrDefault("SELECT status, availability FROM sources WHERE rel_path='b.md'");
                    if (isKnown)
                    {
                        Assert.Equal("ready", (string)b!.status);
                        Assert.Equal(0L, store.Connection.ExecuteScalar<long>("""
                            SELECT count(*) FROM ingest_jobs j JOIN sources s ON j.target='source:'||s.id
                            WHERE j.kind='extract' AND j.state='queued' AND s.rel_path='b.md'
                            """));
                    }
                    else Assert.Null(b);
                }
            }
        }
    }

    private static string Normalize(string json) => JsonSerializer.Serialize(Sort(JsonDocument.Parse(json).RootElement));

    private static object? Sort(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => new SortedDictionary<string, object?>(
            element.EnumerateObject().ToDictionary(p => p.Name, p => Sort(p.Value)), StringComparer.Ordinal),
        JsonValueKind.Array => element.EnumerateArray().Select(Sort).ToArray(),
        JsonValueKind.String => element.GetString(),
        JsonValueKind.Number => element.GetInt64(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => null,
    };
}
