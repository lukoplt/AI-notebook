using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class StorageCatalogTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly HashSet<string> Operations = ["overlap", "relative-paths", "inventory-upsert", "membership", "remove-folder", "coverage", "evidence-cap", "limits"];

    private sealed class FakeIdentity(Dictionary<string, FolderIdentity> values) : IFolderPathIdentity
    {
        public List<string> ResolvedPaths { get; } = [];
        public FolderIdentity Resolve(string path)
        {
            ResolvedPaths.Add(path);
            return values[path];
        }
    }

    private static JsonElement[] Cases(params string[] operations)
    {
        var cases = SharedFixtures.Json("contracts/storage-catalog-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.NotEmpty(cases);
        Assert.All(cases, c => Assert.Contains(c.GetProperty("operation").GetString()!, Operations));
        var selected = cases.Where(c => operations.Contains(c.GetProperty("operation").GetString())).ToArray();
        foreach (string operation in operations)
            Assert.Contains(selected, c => c.GetProperty("operation").GetString() == operation);
        return selected;
    }

    private static FolderDraft Draft(string path) => new(path, "Docs", ["md"], [], "{}", "cp1250", true);
    private static long[] Ids(JsonElement value) => value.EnumerateArray().Select(v => v.GetInt64()).ToArray();
    private static string[] Strings(JsonElement value) => value.EnumerateArray().Select(v => v.GetString()!).ToArray();
    private static long? OptionalLong(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt64();
    private static int? OptionalInt(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt32();
    private static void EqualJson(JsonElement expected, object? actual)
    {
        var json = JsonSerializer.SerializeToElement(actual, JsonOptions);
        Assert.True(JsonElement.DeepEquals(expected, json), $"Expected {expected.GetRawText()}, actual {json.GetRawText()}");
    }

    private static void ExpectError(JsonElement action, Action operation)
    {
        if (action.TryGetProperty("expectedError", out var error) && error.ValueKind != JsonValueKind.Null)
            Assert.Equal(error.GetString(), Assert.Throws<StorageV19Exception>(operation).Code);
        else operation();
    }

    [Fact]
    public void RootObjectIdentitySurvivesReopenAndRemainsSeparateFromPathOverlap()
    {
        var fixture = Assert.Single(SharedFixtures.Json("contracts/ingestion-scan-v1.json")
            .GetProperty("cases").EnumerateArray(), c => c.GetProperty("name").GetString() == "same-path-root-replaced");
        Assert.Equal("identity", fixture.GetProperty("operation").GetString());
        var input = fixture.GetProperty("input");
        string path = input.GetProperty("selectedPath").GetString()!;
        var persisted = JsonSerializer.Deserialize<FolderIdentity>(input.GetProperty("persistedIdentity"), JsonOptions)!;
        var replacement = JsonSerializer.Deserialize<FolderIdentity>(input.GetProperty("openedIdentity"), JsonOptions)!;
        Assert.Equal(persisted.VolumeId, replacement.VolumeId);
        Assert.Equal(persisted.Components, replacement.Components);
        Assert.NotEqual(persisted.RootFileId, replacement.RootFileId);
        string directory = Path.Combine(Path.GetTempPath(), $"folder-identity-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            long notebook;
            long folderId;
            using (var store = V19TestStore.Reopen(directory))
            {
                notebook = store.CreateNotebook("root identity").Id!.Value;
                folderId = store.CreateFolder(notebook, Draft(path), new FakeIdentity(new() { [path] = persisted }), 0).Id;
                lock (store.Gate)
                {
                    var json = JsonDocument.Parse(store.Connection.ExecuteScalar<string>(
                        "SELECT path_identity FROM folder_sources WHERE id=$folderId", new { folderId })!);
                    using (json) EqualJson(input.GetProperty("persistedIdentity"), json.RootElement);
                }
            }
            using (var reopened = V19TestStore.Reopen(directory))
            {
                var saved = Assert.Single(reopened.Folders(notebook));
                EqualJson(input.GetProperty("persistedIdentity"), saved.Identity);
                var adapter = new FakeIdentity(new() { [path] = replacement });
                reopened.UpdateFolder(folderId, saved.Draft with { DisplayName = "Renamed" }, adapter);
                EqualJson(input.GetProperty("persistedIdentity"), Assert.Single(reopened.Folders(notebook)).Identity);
                Assert.Empty(adapter.ResolvedPaths);
                Assert.Equal("overlappingRoot", Assert.Throws<StorageV19Exception>(() =>
                    reopened.CreateFolder(notebook, Draft(path), adapter, 1)).Code);
                Assert.Single(reopened.Folders(notebook));
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void OverlapAndCapFixtures()
    {
        foreach (var c in Cases("overlap"))
        {
            string? directory = null;
            NotebookStore? store = null;
            try
            {
                bool reopen = c.TryGetProperty("reopen", out var r) && r.GetBoolean();
                if (reopen)
                {
                    directory = Path.Combine(Path.GetTempPath(), $"catalog-{Guid.NewGuid():N}");
                    Directory.CreateDirectory(directory);
                    store = V19TestStore.Reopen(directory);
                }
                else store = V19TestStore.Create();
                V19TestStore.Seed(store, c.GetProperty("setupSql"));
                long notebook = store.CreateNotebook("paths").Id!.Value;
                Assert.Equal(c.GetProperty("notebookId").GetInt64(), notebook);
                long secondNotebook = c.TryGetProperty("secondNotebookId", out var secondId)
                    ? store.CreateNotebook("other").Id!.Value : notebook;
                if (secondId.ValueKind != JsonValueKind.Undefined) Assert.Equal(secondId.GetInt64(), secondNotebook);
                string first = c.GetProperty("firstPath").GetString()!;
                string second = c.GetProperty("secondPath").GetString()!;
                string volume = c.GetProperty("volume").GetString()!;
                var adapter = new FakeIdentity(new()
                {
                    [first] = new(volume, Strings(c.GetProperty("firstComponents")), "root-1"),
                    [second] = new(c.TryGetProperty("secondVolume", out var v) ? v.GetString()! : volume,
                        Strings(c.GetProperty("secondComponents")), "root-2")
                });
                store.CreateFolder(notebook, Draft(first), adapter, 0);
                if (reopen)
                {
                    store.Dispose();
                    store = V19TestStore.Reopen(directory!);
                    adapter = new FakeIdentity(c.GetProperty("afterReopenIdentities").EnumerateArray().ToDictionary(
                        v => v.GetProperty("rootPath").GetString()!,
                        v => new FolderIdentity(v.GetProperty("volumeId").GetString()!, Strings(v.GetProperty("components")), "root-2")));
                }
                ExpectError(c, () => store.CreateFolder(secondNotebook, Draft(second), adapter, 0));
                var expected = c.GetProperty("expected");
                Assert.Equal(expected.GetProperty("folderCount").GetInt32(),
                    store.Folders(notebook).Count + (secondNotebook == notebook ? 0 : store.Folders(secondNotebook).Count));
                if (expected.TryGetProperty("folderCountsByNotebook", out var counts))
                    foreach (var count in counts.EnumerateObject())
                        Assert.Equal(count.Value.GetInt32(), store.Folders(long.Parse(count.Name)).Count);
                if (expected.TryGetProperty("persistedIdentity", out var identity))
                {
                    var saved = Assert.Single(store.Folders(notebook)).Identity;
                    var fullIdentity = JsonSerializer.SerializeToElement(new FolderIdentity(
                        identity.GetProperty("volumeId").GetString()!, Strings(identity.GetProperty("components")),
                        identity.TryGetProperty("rootFileId", out var root) ? root.GetString()! : "root-1"), JsonOptions);
                    EqualJson(fullIdentity, saved);
                }
                if (expected.TryGetProperty("resolvedPathsAfterReopen", out var paths))
                    EqualJson(paths, adapter.ResolvedPaths);
                store.SetEvidenceBudgetCap(notebook, 0);
                Assert.Equal(0, store.EvidenceBudgetCap(notebook));
                Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.SetEvidenceBudgetCap(notebook, -1)).Code);
                Assert.Equal(0, store.EvidenceBudgetCap(notebook));
            }
            finally
            {
                store?.Dispose();
                if (directory is not null) Directory.Delete(directory, true);
            }
        }
    }

    [Fact]
    public void RelativePathsAndInventory()
    {
        foreach (var c in Cases("relative-paths", "inventory-upsert"))
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            var expected = c.GetProperty("expected");
            switch (c.GetProperty("operation").GetString())
            {
                case "relative-paths":
                    long notebook = store.CreateNotebook("paths").Id!.Value;
                    var folder = store.CreateFolder(notebook, Draft("/docs"), new FakeIdentity(new() { ["/docs"] = new("v", ["docs"], "root-1") }), 0);
                    long source = store.CreateSource(notebook, SourceType.Text, "path target", null, null).Id!.Value;
                    int rejected = 0;
                    Assert.NotEmpty(c.GetProperty("paths").EnumerateArray());
                    foreach (var path in c.GetProperty("paths").EnumerateArray())
                    {
                        string relative = path.GetProperty("path").GetString()!;
                        ExpectError(path, () => store.UpsertScanItems(folder.Id, [new(folder.Id, relative, "eligible", null, null, null, 1)]));
                        ExpectError(path, () => store.AttachSource(source, folder.Id, relative));
                        if (!path.GetProperty("valid").GetBoolean())
                        {
                            rejected++;
                            lock (store.Gate)
                            {
                                Assert.Null(store.Connection.ExecuteScalar<long?>("SELECT folder_id FROM sources WHERE id=$id", new { id = source }));
                                Assert.Null(store.Connection.ExecuteScalar<string?>("SELECT rel_path FROM sources WHERE id=$id", new { id = source }));
                                Assert.Throws<SqliteException>(() => store.Connection.Execute(
                                    "UPDATE sources SET folder_id=$folder,rel_path=$relative WHERE id=$id", new { folder = folder.Id, relative, id = source }));
                                Assert.Throws<SqliteException>(() => store.Connection.Execute(
                                    """
                                    INSERT INTO sources(notebook_id,type,title,status,ingested_at,folder_id,rel_path)
                                    VALUES($notebook,'text','invalid path','pending','2026-01-02 03:04:05.000',$folder,$relative)
                                    """, new { notebook, folder = folder.Id, relative }));
                                Assert.Equal(1, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM sources"));
                                Assert.Null(store.Connection.ExecuteScalar<long?>("SELECT folder_id FROM sources WHERE id=$id", new { id = source }));
                                Assert.Null(store.Connection.ExecuteScalar<string?>("SELECT rel_path FROM sources WHERE id=$id", new { id = source }));
                            }
                        }
                        else
                        {
                            lock (store.Gate)
                            {
                                Assert.Equal(folder.Id, store.Connection.ExecuteScalar<long?>("SELECT folder_id FROM sources WHERE id=$id", new { id = source }));
                                Assert.Equal(relative, store.Connection.ExecuteScalar<string?>("SELECT rel_path FROM sources WHERE id=$id", new { id = source }));
                            }
                        }
                    }
                    EqualJson(expected.GetProperty("acceptedPaths"), store.ScanItems(folder.Id).Select(i => i.RelPath).ToArray());
                    Assert.Equal(expected.GetProperty("rejectedCount").GetInt32(), rejected);
                    break;
                case "inventory-upsert":
                    long folderId = c.GetProperty("folderId").GetInt64();
                    var items = c.GetProperty("items").EnumerateArray().Select(ScanItemFrom).ToArray();
                    Assert.NotEmpty(items);
                    store.UpsertScanItems(folderId, items);
                    Assert.Equal(expected.GetProperty("rowCount").GetInt32(), store.ScanItems(folderId).Count);
                    EqualJson(expected.GetProperty("items"), store.ScanItems(folderId));
                    // A later invalid row must roll back every prior row in the same batch.
                    Assert.Equal("invalidPath", Assert.Throws<StorageV19Exception>(() => store.UpsertScanItems(folderId,
                        [new(folderId, "new.md", "eligible", null, 3, 30, 3), new(folderId, "../bad", "eligible", null, null, null, 3)])).Code);
                    EqualJson(expected.GetProperty("items"), store.ScanItems(folderId));
                    break;
                default: throw new InvalidOperationException("Unhandled inventory fixture operation.");
            }
        }
        AssertFolderUpdates();
    }

    private static ScanItem ScanItemFrom(JsonElement item) => new(
        item.GetProperty("folderId").GetInt64(), item.GetProperty("relPath").GetString()!, item.GetProperty("kind").GetString()!,
        item.GetProperty("skipReason").GetString(), OptionalLong(item.GetProperty("mtime")), OptionalLong(item.GetProperty("sizeBytes")),
        item.GetProperty("seenGeneration").GetInt64());

    private static void AssertFolderUpdates()
    {
        using var store = V19TestStore.Create();
        long notebook = store.CreateNotebook("updates").Id!.Value;
        var adapter = new FakeIdentity(new() { ["/docs"] = new("v", ["docs"], "root-1"), ["/new"] = new("v", ["new"], "root-2") });
        var folder = store.CreateFolder(notebook, Draft("/docs"), adapter, 100);
        lock (store.Gate)
            store.Connection.Execute("UPDATE folder_sources SET scan_state='partial',scan_generation=7,last_full_scan_at=90,last_scan_error='offline' WHERE id=$id", new { id = folder.Id });
        var changed = folder.Draft with { DisplayName = "Renamed", IncludeExts = ["md", "txt"], WatchEnabled = false };
        // No mapping exists: resolving an unchanged root would throw and fail the test.
        store.UpdateFolder(folder.Id, changed, new FakeIdentity([]));
        var result = Assert.Single(store.Folders(notebook));
        EqualJson(JsonSerializer.SerializeToElement(changed, JsonOptions), result.Draft);
        EqualJson(JsonSerializer.SerializeToElement(folder.Identity, JsonOptions), result.Identity);
        Assert.Equal("partial", result.ScanState);
        Assert.Equal(7, result.ScanGeneration);
        Assert.Equal(90, result.LastFullScanAt);
        Assert.Equal("offline", result.LastScanError);
        Assert.Equal(100, result.CreatedAt);
        store.UpsertScanItems(folder.Id, [new(folder.Id, "one.md", "eligible", null, null, null, 7)]);
        Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.UpdateFolder(folder.Id, changed with { RootPath = "/new" }, adapter)).Code);
        Assert.Equal("/docs", Assert.Single(store.Folders(notebook)).Draft.RootPath);
        Assert.Throws<KeyNotFoundException>(() => store.CreateFolder(notebook, Draft("/unresolvable"), adapter, 200));
        Assert.Single(store.Folders(notebook));
    }

    [Fact]
    public void FolderDeleteOnlyCascadesDatabase()
    {
        foreach (var c in Cases("remove-folder"))
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            string directory = Path.Combine(Path.GetTempPath(), $"catalog-files-{Guid.NewGuid():N}");
            Directory.CreateDirectory(directory);
            try
            {
                var existing = c.GetProperty("filesystem").GetProperty("existingPaths").EnumerateArray()
                    .Select(p => Path.Combine(directory, p.GetString()!.TrimStart('/'))).ToArray();
                Directory.CreateDirectory(existing[0]);
                foreach (string path in existing.Skip(1)) File.WriteAllText(path, "keep original contents");
                lock (store.Gate)
                    store.Connection.Execute("UPDATE folder_sources SET root_path=$path WHERE id=$id", new { path = existing[0], id = c.GetProperty("folderId").GetInt64() });
                var before = existing.ToDictionary(path => path, FileFingerprint);
                store.DeleteFolder(c.GetProperty("folderId").GetInt64());
                var expected = c.GetProperty("expected");
                lock (store.Gate)
                {
                    EqualJson(expected.GetProperty("folderIds"), store.Connection.Query<long>("SELECT id FROM folder_sources ORDER BY id").ToArray());
                    EqualJson(expected.GetProperty("sourceIds"), store.Connection.Query<long>("SELECT id FROM sources ORDER BY id").ToArray());
                    foreach (var (field, table) in new[] { ("scanItemCount", "scan_items"), ("revisionCount", "source_revisions"), ("chunkCount", "source_chunks"),
                        ("vectorCount", "chunk_embeddings"), ("manifestCount", "index_generation_manifest"), ("jobCount", "ingest_jobs") })
                        Assert.Equal(expected.GetProperty(field).GetInt32(), store.Connection.ExecuteScalar<int>($"SELECT count(*) FROM {table}"));
                    EqualJson(expected.GetProperty("sourceSetMemberIds"), store.Connection.Query<long>("SELECT source_id FROM source_set_members ORDER BY source_id").ToArray());
                    EqualJson(expected.GetProperty("sourceSetFolderIds"), store.Connection.Query<long>("SELECT folder_id FROM source_set_folders ORDER BY folder_id").ToArray());
                    EqualJson(expected.GetProperty("sourceSetIds"), store.Connection.Query<long>("SELECT id FROM source_sets ORDER BY id").ToArray());
                    EqualJson(expected.GetProperty("generationIds"), store.Connection.Query<long>("SELECT id FROM index_generations ORDER BY id").ToArray());
                }
                Assert.Equal(expected.GetProperty("filesystemDeleteOperations").GetInt32(), existing.Count(path => !File.Exists(path) && !Directory.Exists(path)));
                Assert.Equal(expected.GetProperty("filesystemWriteOperations").GetInt32(), existing.Count(path => FileFingerprint(path) != before[path]));
            }
            finally { Directory.Delete(directory, true); }
        }
    }

    private static string FileFingerprint(string path) => Directory.Exists(path)
        ? $"directory:{Directory.GetLastWriteTimeUtc(path).Ticks}"
        : File.Exists(path) ? $"{File.GetLastWriteTimeUtc(path).Ticks}:{Convert.ToHexString(File.ReadAllBytes(path))}" : "absent";

    [Fact]
    public void MembershipAtomicity()
    {
        foreach (var c in Cases("membership"))
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            Assert.NotEmpty(c.GetProperty("events").EnumerateArray());
            foreach (var e in c.GetProperty("events").EnumerateArray())
            {
                ExpectError(e, () =>
                {
                    switch (e.GetProperty("op").GetString())
                    {
                        case "setSourceSetMembers": store.SetSourceSetMembers(e.GetProperty("setId").GetInt64(), Ids(e.GetProperty("sourceIds"))); break;
                        case "setSourceSetFolders": store.SetSourceSetFolders(e.GetProperty("setId").GetInt64(), Ids(e.GetProperty("folderIds"))); break;
                        case "attachSource": store.AttachSource(e.GetProperty("sourceId").GetInt64(), e.GetProperty("folderId").GetInt64(), e.GetProperty("relPath").GetString()!); break;
                        default: throw new InvalidOperationException("Unhandled membership fixture operation.");
                    }
                });
                AssertMembership(store, e.GetProperty("expected"));
            }
            AssertMembership(store, c.GetProperty("expected"));
            lock (store.Gate)
            {
                Assert.Throws<SqliteException>(() => store.Connection.Execute("INSERT INTO source_set_folders(set_id,folder_id) VALUES(1,2)"));
                Assert.Throws<SqliteException>(() => store.Connection.Execute("UPDATE source_set_folders SET folder_id=2 WHERE set_id=1 AND folder_id=1"));
            }
            AssertMembership(store, c.GetProperty("expected"));
        }
    }

    private static void AssertMembership(NotebookStore store, JsonElement expected)
    {
        EqualJson(expected.GetProperty("sourceIds"), store.SourceSetMembers(1).Order().ToArray());
        EqualJson(expected.GetProperty("folderIds"), store.SourceSetFolders(1).Order().ToArray());
        lock (store.Gate)
        {
            EqualJson(expected.GetProperty("source2FolderId"), store.Connection.ExecuteScalar<long?>("SELECT folder_id FROM sources WHERE id=2"));
            EqualJson(expected.GetProperty("source2RelPath"), store.Connection.ExecuteScalar<string?>("SELECT rel_path FROM sources WHERE id=2"));
        }
    }

    [Fact]
    public void CoverageSnapshot()
    {
        var cases = Cases("coverage").Where(c => c.GetProperty("name").GetString() is "coverage" or "coverage-no-generation").ToArray();
        Assert.NotEmpty(cases);
        foreach (var c in cases) AssertCoverage(c);
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, cases[0].GetProperty("setupSql"));
        lock (store.Gate)
            store.Connection.Execute("UPDATE sources SET status='chunking' WHERE id=1");
        var observedRefresh = store.Coverage(1, new RetrievalScope.Selection(new HashSet<long> { 1 }, new HashSet<long>()));
        EqualJson(JsonSerializer.SerializeToElement(new { searchable = 1, notSearchable = 0, current = 0, pending = 0, error = 0, skipped = 0,
            missing = 0, unavailable = 0, refreshPending = 1, refreshError = 0, isLowerBound = true }), observedRefresh);
    }

    [Fact]
    public void CoverageScopeIsolation()
    {
        var cases = Cases("coverage").Where(c => c.GetProperty("name").GetString() is not ("coverage" or "coverage-no-generation")).ToArray();
        Assert.NotEmpty(cases);
        foreach (var c in cases) AssertCoverage(c);
    }

    private static void AssertCoverage(JsonElement c)
    {
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, c.GetProperty("setupSql"));
        EqualJson(c.GetProperty("expected"), store.Coverage(c.GetProperty("notebookId").GetInt64(), RetrievalScopeJson.Deserialize(c.GetProperty("scope").GetRawText())));
    }

    [Fact]
    public void ModelLimitsAndEvidenceCap()
    {
        foreach (var c in Cases("evidence-cap", "limits"))
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            if (c.GetProperty("operation").GetString() == "evidence-cap")
            {
                long notebook = c.GetProperty("notebookId").GetInt64();
                var values = c.GetProperty("values").EnumerateArray().ToArray();
                var expectedValues = c.GetProperty("expectedValues").EnumerateArray().ToArray();
                var errors = c.GetProperty("expectedErrors").EnumerateArray().ToArray();
                Assert.NotEmpty(values);
                Assert.Equal(values.Length, expectedValues.Length);
                Assert.Equal(values.Length, errors.Length);
                for (int i = 0; i < values.Length; i++)
                {
                    int? value = OptionalInt(values[i]);
                    if (errors[i].ValueKind != JsonValueKind.Null)
                        Assert.Equal(errors[i].GetString(), Assert.Throws<StorageV19Exception>(() => store.SetEvidenceBudgetCap(notebook, value)).Code);
                    else store.SetEvidenceBudgetCap(notebook, value);
                    EqualJson(expectedValues[i], store.EvidenceBudgetCap(notebook));
                }
                Assert.Equal(c.GetProperty("expectedError").GetString(), errors.Last(e => e.ValueKind != JsonValueKind.Null).GetString());
                EqualJson(c.GetProperty("expected").GetProperty("value"), store.EvidenceBudgetCap(notebook));
            }
            else
            {
                string providerRows;
                lock (store.Gate) providerRows = JsonSerializer.Serialize(store.Connection.Query("SELECT * FROM providers ORDER BY id").ToArray());
                Assert.NotEmpty(c.GetProperty("events").EnumerateArray());
                foreach (var e in c.GetProperty("events").EnumerateArray())
                {
                    switch (e.GetProperty("op").GetString())
                    {
                        case "get":
                            EqualJson(e.GetProperty("expected"), store.ModelLimits(e.GetProperty("providerId").GetString()!, e.GetProperty("model").GetString()!));
                            break;
                        case "set":
                            var limits = LimitsFrom(e.GetProperty("limits"));
                            if (e.TryGetProperty("before", out var before)) EqualJson(before, store.ModelLimits(limits.ProviderId, limits.Model));
                            ExpectError(e, () => store.SetModelLimits(limits));
                            if (e.TryGetProperty("expected", out var expected)) EqualJson(expected, store.ModelLimits(limits.ProviderId, limits.Model));
                            if (e.TryGetProperty("expectedRecords", out var records)) AssertLimits(store, records);
                            break;
                        default: throw new InvalidOperationException("Unhandled model-limits fixture operation.");
                    }
                }
                var keys = c.GetProperty("readKeys").EnumerateArray().ToArray();
                Assert.NotEmpty(keys);
                EqualJson(c.GetProperty("expected").GetProperty("records"), keys.Select(k => store.ModelLimits(k.GetProperty("providerId").GetString()!, k.GetProperty("model").GetString()!)).ToArray());
                EqualJson(c.GetProperty("after"), store.ModelLimits(c.GetProperty("before").GetProperty("providerId").GetString()!, c.GetProperty("before").GetProperty("model").GetString()!));
                lock (store.Gate) Assert.Equal(providerRows, JsonSerializer.Serialize(store.Connection.Query("SELECT * FROM providers ORDER BY id").ToArray()));
            }
        }
    }

    private static ProviderModelLimits LimitsFrom(JsonElement value) => new(value.GetProperty("providerId").GetString()!, value.GetProperty("model").GetString()!,
        OptionalInt(value.GetProperty("contextWindow")), value.GetProperty("runtimeContext").GetInt32(), value.GetProperty("maxOutputTokens").GetInt32(), value.GetProperty("source").GetString()!);

    private static void AssertLimits(NotebookStore store, JsonElement records)
    {
        Assert.NotEmpty(records.EnumerateArray());
        foreach (var expected in records.EnumerateArray())
            EqualJson(expected, store.ModelLimits(expected.GetProperty("providerId").GetString()!, expected.GetProperty("model").GetString()!));
        lock (store.Gate)
            Assert.Equal(records.GetArrayLength(), store.Connection.ExecuteScalar<int>("SELECT count(*) FROM provider_model_limits"));
    }
}
