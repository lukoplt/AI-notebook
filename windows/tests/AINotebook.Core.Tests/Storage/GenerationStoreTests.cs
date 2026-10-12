using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class GenerationStoreTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly HashSet<string> Names = ["pending-blocks", "changed-current-blocks", "new-source-blocks", "missing-vector-blocks", "wrong-dim-blocks",
        "cross-notebook-blocks", "excluded-requires-reason", "single-active", "retire", "pin-retains-retired", "release-then-gc", "published-lexical-retained",
        "building-retained", "cancelled-job-reference", "legacy-partial-preserved", "copy-successor", "vector-normalization", "pin-cross-store"];
    private static JsonElement[] Cases(params string[] names)
    {
        var all = SharedFixtures.Json("contracts/storage-generations-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.NotEmpty(all);
        Assert.All(all, c => { Assert.Contains(c.GetProperty("name").GetString()!, Names); Assert.Equal("generation", c.GetProperty("operation").GetString()); });
        return names.Select(name => Assert.Single(all, c => c.GetProperty("name").GetString() == name)).ToArray();
    }
    private static GenerationIdentity Identity(JsonElement value) => new(value.GetProperty("providerId").GetString()!, value.GetProperty("endpointRevision").GetString()!,
        value.GetProperty("model").GetString()!, value.GetProperty("modelDigest").GetString(), value.GetProperty("dims").GetInt32(), value.GetProperty("normalization").GetString()!,
        value.GetProperty("queryFormatVersion").GetString()!, value.GetProperty("docFormatVersion").GetString()!, value.GetProperty("chunkerVersion").GetString()!);
    private static GenerationIdentity LegacyIdentity() => Identity(SharedFixtures.Json("contracts/storage-generations-v1.json").GetProperty("identity"));
    private static int? OptionalInt(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt32();
    private static EmbeddingVector Vector(JsonElement value) => new(value.EnumerateArray().Select(v => v.ValueKind == JsonValueKind.Number ? v.GetSingle() :
        v.GetString() switch { "NaN" => float.NaN, "Infinity" => float.PositiveInfinity, _ => throw new InvalidOperationException("Unknown nonfinite vector fixture value.") }).ToArray());
    private static ManifestEntry[] Entries(JsonElement value) => value.EnumerateArray().Select(e => new ManifestEntry(e.GetProperty("sourceId").GetInt64(),
        e.GetProperty("revisionId").GetInt64(), e.GetProperty("state").GetString()!, e.GetProperty("reason").GetString())).ToArray();
    private static RevisionDraft Draft(JsonElement value) => new(value.GetProperty("contentHash").GetString()!, value.GetProperty("canonicalText").GetString()!,
        value.GetProperty("textFormatVersion").GetInt32(), value.GetProperty("chunkerVersion").GetInt32());
    private static RevisionChunkDraft[] Chunks(JsonElement value) => value.EnumerateArray().Select(c => new RevisionChunkDraft(c.GetProperty("text").GetString()!,
        c.GetProperty("tokenCount").GetInt32(), OptionalInt(c.GetProperty("pageHint")), OptionalInt(c.GetProperty("charStart")), OptionalInt(c.GetProperty("charEnd")),
        c.GetProperty("lang").GetString(), c.GetProperty("langInherited").GetBoolean())).ToArray();
    private static void Equal(JsonElement expected, object? actual)
    {
        var json = JsonSerializer.SerializeToElement(actual, JsonOptions);
        Assert.True(JsonElement.DeepEquals(expected, json), $"Expected {expected.GetRawText()}, actual {json.GetRawText()}");
    }
    private static T Scalar<T>(NotebookStore store, string sql, object? args = null)
    {
        lock (store.Gate) return store.Connection.ExecuteScalar<T>(sql, args)!;
    }
    private static T[] Query<T>(NotebookStore store, string sql)
    {
        lock (store.Gate) return store.Connection.Query<T>(sql).ToArray();
    }
    private static string TempDirectory()
    {
        string path = Path.Combine(Path.GetTempPath(), $"generations-{Guid.NewGuid():N}"); Directory.CreateDirectory(path); return path;
    }
    private static void InTransaction(NotebookStore store, Action<SqliteConnection, SqliteTransaction> action)
    {
        lock (store.Gate)
        {
            using var tx = store.Connection.BeginTransaction(deferred: false);
            action(store.Connection, tx); tx.Commit();
        }
    }

    [Fact]
    public void SingleActiveAndPinnedRetirement()
    {
        foreach (var c in Cases("single-active", "retire", "pin-retains-retired", "release-then-gc")) RunCase(c);
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, Cases("single-active")[0].GetProperty("setupSql"));
        var g = store.CreateGeneration(1, LegacyIdentity(), 0);
        Assert.Equal("building", g.State); Assert.Equal(0, g.CreatedAt); Assert.Null(g.ActivatedAt);
        Assert.Equal(LegacyIdentity(), g.Identity);
        Assert.Equal(new ManifestEntry(1, 101, "pending", null), Assert.Single(store.Manifest(g.Id)));
        Assert.Equal("generationNotReady", Assert.Throws<StorageV19Exception>(() => store.ActivateGeneration(g.Id, 1)).Code);
        store.StoreGenerationEmbedding(g.Id, 1001, new([1f, 0f]));
        store.SetManifest(g.Id, [new(1, 101, "done", null)]);
        store.ActivateGeneration(g.Id, 1);
        var pin = store.PinQuery(1, "m");
        Assert.Equal(g.Id, pin.GenerationId); Assert.Equal("m", pin.ModelKey); Assert.Equal(2, pin.Dims);
        Assert.Equal(101, pin.LexicalRevisions[1]); Assert.Equal(101, pin.VectorRevisions[1]);
        var forged = new QueryPin(pin.Token, 999, 999, "other-model", 1,
            new Dictionary<long, long> { [999] = 999 }, new Dictionary<long, long> { [999] = 999 });
        var savedEmbedding = Assert.Single(store.PinnedEmbeddings(forged));
        Assert.Equal(1001, savedEmbedding.ChunkId); Assert.Equal(1, savedEmbedding.SourceId);
        Assert.Equal(new[] { 1f, 0f }, savedEmbedding.Vector.Values);
        store.RetireGeneration(g.Id);
        store.GarbageCollect(1);
        Assert.NotNull(store.Generation(g.Id)); Assert.Single(store.PinnedEmbeddings(pin));
        store.ReleaseQuery(pin); store.ReleaseQuery(pin);
        Assert.Empty(store.PinnedEmbeddings(pin));
        store.GarbageCollect(1);
        Assert.Null(store.Generation(g.Id)); Assert.NotNull(store.Revision(101));
        using var isolated = V19TestStore.Create();
        V19TestStore.Seed(isolated, Cases("single-active")[0].GetProperty("setupSql"));
        using var otherMemory = V19TestStore.Create();
        V19TestStore.Seed(otherMemory, Cases("single-active")[0].GetProperty("setupSql"));
        var isolatedPin = isolated.PinQuery(1, "m");
        try
        {
            Assert.Empty(otherMemory.PinnedEmbeddings(isolatedPin));
            otherMemory.ReleaseQuery(isolatedPin);
            isolated.RetireGeneration(1);
            isolated.GarbageCollect(1);
            otherMemory.RetireGeneration(1);
            otherMemory.GarbageCollect(1);
            Assert.Null(otherMemory.Generation(1));
            Assert.NotNull(isolated.Generation(1));
            Assert.Equal(1001, Assert.Single(isolated.PinnedEmbeddings(isolatedPin)).ChunkId);
        }
        finally { isolated.ReleaseQuery(isolatedPin); }
    }

    [Fact]
    public void ActivationPreconditions()
    {
        foreach (var c in Cases("pending-blocks", "missing-vector-blocks", "wrong-dim-blocks", "cross-notebook-blocks", "excluded-requires-reason", "vector-normalization")) RunCase(c);
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, Cases("single-active")[0].GetProperty("setupSql"));
        store.StoreGenerationEmbedding(2, 1001, new([1f, 0f]));
        store.SetManifest(2, [new(1, 101, "done", null)]);
        long job = store.EnqueueJob(new("embed", "generation:2", null), 0);
        Assert.NotNull(store.ClaimJob(0, "worker", job));
        Assert.Equal("staleLease", Assert.Throws<StorageV19Exception>(() => InTransaction(store,
            (c, tx) => GenerationSQL.Activate(c, tx, 2, new(job, "stale"), 1))).Code);
        Assert.Equal(1, store.ActiveGeneration(1)!.Id); Assert.Equal("running", store.Job(job)!.State);
        Assert.Equal("staleLease", Assert.Throws<StorageV19Exception>(() => InTransaction(store,
            (c, tx) => GenerationSQL.Activate(c, tx, 2, new(job, "worker"), 300))).Code);
        Assert.Equal(1, store.ActiveGeneration(1)!.Id); Assert.Equal("running", store.Job(job)!.State);
        InTransaction(store, (c, tx) => GenerationSQL.Activate(c, tx, 2, new(job, "worker"), 2));
        Assert.Equal(2, store.ActiveGeneration(1)!.Id); Assert.Equal("done", store.Job(job)!.State);
        Assert.Null(store.Job(job)!.LeaseToken);
        Assert.Throws<StorageV19Exception>(() => store.StoreGenerationEmbedding(2, 1001, new([0f, 1f])));
        Assert.Throws<StorageV19Exception>(() => store.SetManifest(2, [new(1, 101, "excluded", "changed")]));
        Assert.Equal("0000803F00000000", Scalar<string>(store, "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=2"));
        Assert.Equal("done", Assert.Single(store.Manifest(2)).State);
    }

    [Fact]
    public void RevisionChangesRequireReconcile()
    {
        foreach (var c in Cases("changed-current-blocks", "new-source-blocks")) RunCase(c);
    }

    [Fact]
    public async Task TwoActivationsLeaveOneActive()
    {
        var fixture = Cases("single-active")[0];
        string directory = TempDirectory();
        try
        {
            using var first = V19TestStore.Reopen(directory);
            V19TestStore.Seed(first, fixture.GetProperty("setupSql"));
            storeReady(first, 2);
            var third = first.CreateGeneration(1, LegacyIdentity(), 0);
            storeReady(first, third.Id);
            using var second = V19TestStore.Reopen(directory);
            using var barrier = new Barrier(2);
            await Task.WhenAll(Task.Run(() => { Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(10))); first.ActivateGeneration(2, 1); }),
                Task.Run(() => { Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(10))); second.ActivateGeneration(third.Id, 1); }));
            Assert.Equal(fixture.GetProperty("expected").GetProperty("activeCount").GetInt32(), Scalar<int>(first, "SELECT count(*) FROM index_generations WHERE notebook_id=1 AND state='active'"));
            var states = new[] { first.Generation(2)!.State, first.Generation(third.Id)!.State };
            Assert.Equal(new[] { "active", "retired" }, states.Order());
            Assert.Contains(first.ActiveGeneration(1)!.Id, new[] { 2L, third.Id });
            Assert.Equal("retired", first.Generation(1)!.State);
        }
        finally { Directory.Delete(directory, true); }
        static void storeReady(NotebookStore store, long id)
        {
            store.StoreGenerationEmbedding(id, 1001, new([1f, 0f])); store.SetManifest(id, [new(1, 101, "done", null)]);
        }
    }

    [Fact]
    public void GCProtectedSets()
    {
        foreach (var c in Cases("published-lexical-retained", "building-retained", "cancelled-job-reference")) RunCase(c);
        foreach (string state in new[] { "queued", "running", "paused", "failed" })
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, Cases("cancelled-job-reference")[0].GetProperty("setupSql"));
            // Start the old extraction before the source advances; stale jobs cannot be claimed.
            lock (store.Gate) store.Connection.Execute("UPDATE sources SET current_revision=101 WHERE id=1");
            long job = store.EnqueueJob(new("extract", "source:1", 101), 0);
            if (state is "running" or "failed") Assert.NotNull(store.ClaimJob(0, "protected", job));
            if (state == "paused") store.PauseJob(job);
            if (state == "failed")
            {
                Assert.True(store.FailJob(new(job, "protected"), "retryable", 0));
                Assert.Equal("failed", store.Job(job)!.State);
                Assert.Equal(60, store.Job(job)!.NextRetryAt);
            }
            lock (store.Gate) store.Connection.Execute("UPDATE sources SET current_revision=102 WHERE id=1");
            store.RetireGeneration(1); store.GarbageCollect(1);
            Assert.NotNull(store.Revision(101)); Assert.Equal(1, Scalar<int>(store, "SELECT count(*) FROM source_chunks WHERE revision_id=101"));
            if (state == "failed")
            {
                Assert.False(store.RetryJob(job, 60));
                Assert.Equal("cancelled", store.Job(job)!.State);
            }
            else store.CancelJob(job);
            store.GarbageCollect(1);
            Assert.Null(store.Revision(101)); Assert.NotNull(store.Revision(102));
        }
        using (var store = V19TestStore.Create())
        {
            V19TestStore.Seed(store, Cases("published-lexical-retained")[0].GetProperty("setupSql"));
            store.RetireGeneration(1); store.GarbageCollect(1);
            var pin = store.PinQuery(1, "not-active");
            Assert.Null(pin.GenerationId); Assert.Empty(pin.VectorRevisions); Assert.Equal(101, pin.LexicalRevisions[1]);
            var current = store.CommitForegroundRevision(1, new("new", "new", 1, 2), [new("new", 1, null, 0, 3, null, false)], 1, "lexical-replacement");
            store.GarbageCollect(1); Assert.NotNull(store.Revision(101)); Assert.NotNull(store.Revision(current.Id));
            store.ReleaseQuery(pin); store.GarbageCollect(1); Assert.Null(store.Revision(101)); Assert.NotNull(store.Revision(current.Id));
        }
    }

    [Fact]
    public async Task PinAcrossSecondStoreGC()
    {
        var fixture = Cases("pin-cross-store")[0];
        var interleavings = fixture.GetProperty("interleavings").EnumerateArray().ToArray();
        Assert.Equal(2, interleavings.Length);
        foreach (var ordering in interleavings)
        {
            string directory = TempDirectory();
            try
            {
                using var first = V19TestStore.Reopen(directory);
                V19TestStore.Seed(first, fixture.GetProperty("setupSql"));
                using var second = V19TestStore.Reopen(directory);
                QueryPin pin;
                using var entered = new ManualResetEventSlim();
                var labels = ordering.EnumerateArray().Select(v => v.GetString()!).ToArray();
                if (labels[0] == "storeA.pin.registryLock")
                {
                    Assert.Equal(new[] { "storeA.pin.registryLock", "storeB.gc.waitRegistry", "storeA.pin.readAndRegister", "storeA.pin.commitAndUnlock", "storeB.gc.lockReadCommit" }, labels);
                    Task<GarbageCollectionResult> gc;
                    lock (first.Gate)
                    {
                        using var registry = GenerationPinRegistry.Acquire(GenerationPinRegistry.Identity(first.Connection));
                        gc = Task.Run(() => { entered.Set(); return second.GarbageCollect(1); });
                        Assert.True(entered.Wait(TimeSpan.FromSeconds(10))); Assert.False(gc.IsCompleted);
                        pin = first.PinQuery(1, "m");
                    }
                    await gc.WaitAsync(TimeSpan.FromSeconds(10));
                }
                else
                {
                    Assert.Equal(new[] { "storeB.gc.registryLock", "storeA.pin.waitRegistry", "storeB.gc.readCommitAndUnlock", "storeA.pin.lockReadAndRegister" }, labels);
                    Task<QueryPin> pinTask;
                    lock (second.Gate)
                    {
                        using var registry = GenerationPinRegistry.Acquire(GenerationPinRegistry.Identity(second.Connection));
                        pinTask = Task.Run(() => { entered.Set(); return first.PinQuery(1, "m"); });
                        Assert.True(entered.Wait(TimeSpan.FromSeconds(10))); Assert.False(pinTask.IsCompleted);
                        second.GarbageCollect(1);
                    }
                    pin = await pinTask.WaitAsync(TimeSpan.FromSeconds(10));
                }
                RunEvents(first, fixture, second, new() { ["oldPin"] = pin }, skipInitialPin: true);
            }
            finally { Directory.Delete(directory, true); }
        }
        AssertAliasPinRetention(fixture, symbolicLink: true);
        AssertAliasPinRetention(fixture, symbolicLink: false);
    }

    private static void AssertAliasPinRetention(JsonElement fixture, bool symbolicLink)
    {
        string directory = TempDirectory();
        try
        {
            string actual = Path.Combine(directory, "Real");
            Directory.CreateDirectory(actual);
            using var first = V19TestStore.Reopen(actual);
            V19TestStore.Seed(first, fixture.GetProperty("setupSql"));
            string alias = Path.Combine(directory, symbolicLink ? "Linked" : "rEAL");
            if (symbolicLink)
            {
                try { Directory.CreateSymbolicLink(alias, actual); }
                catch (UnauthorizedAccessException) when (OperatingSystem.IsWindows()) { return; }
                catch (PlatformNotSupportedException) when (OperatingSystem.IsWindows()) { return; }
            }
            else if (!File.Exists(Path.Combine(alias, "db.sqlite"))) return; // The volume may distinguish case.
            Assert.True(File.Exists(Path.Combine(alias, "db.sqlite")));
            using var second = V19TestStore.Reopen(alias);
            Assert.Equal(1, second.ActiveGeneration(1)!.Id);
            var pin = first.PinQuery(1, "m");
            try
            {
                second.RetireGeneration(1);
                second.GarbageCollect(1);
                Assert.NotNull(first.Generation(1));
                Assert.Equal(1001, Assert.Single(first.PinnedEmbeddings(pin)).ChunkId);
            }
            finally { first.ReleaseQuery(pin); }
            second.GarbageCollect(1);
            Assert.Null(first.Generation(1));
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void LegacyIncompleteAndSuccessorCopy()
    {
        foreach (var c in Cases("legacy-partial-preserved", "copy-successor")) RunCase(c);
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, Cases("copy-successor")[0].GetProperty("setupSql"));
        var mismatch = store.CreateGeneration(1, LegacyIdentity() with { EndpointRevision = "changed" }, 0);
        Assert.Throws<StorageV19Exception>(() => InTransaction(store, (c, tx) => GenerationSQL.CopyUnchangedVectors(c, tx, 1, mismatch.Id, null)));
        Assert.Equal(0, Scalar<int>(store, "SELECT count(*) FROM chunk_embeddings WHERE generation_id=$id", new { id = mismatch.Id }));
        InTransaction(store, (c, tx) => GenerationSQL.CopyUnchangedVectors(c, tx, 1, 2, 1001));
        Assert.Equal("pending", Assert.Single(store.Manifest(2)).State);
        Assert.Equal(0, Scalar<int>(store, "SELECT count(*) FROM chunk_embeddings WHERE generation_id=2"));
        store.StoreGenerationEmbedding(2, 1001, new([0f, 0f]));
        Assert.Equal("0000000000000000", Scalar<string>(store, "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=2"));
    }

    private static void RunCase(JsonElement c)
    {
        if (c.TryGetProperty("fixture", out var fixture))
        {
            Assert.Equal("storage/v18.sqlite", fixture.GetString());
            var (store, directory, _) = V19TestStore.UpgradeCopy(c.GetProperty("configuredModelKey").GetString());
            try { RunEvents(store, c); }
            finally { store.Dispose(); Directory.Delete(directory, true); }
        }
        else
        {
            using var store = V19TestStore.Create();
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            RunEvents(store, c);
        }
    }

    private static void RunEvents(NotebookStore first, JsonElement c, NotebookStore? second = null, Dictionary<string, QueryPin>? existingPins = null, bool skipInitialPin = false)
    {
        var pins = existingPins ?? [];
        var released = new HashSet<string>();
        IReadOnlyList<StoredEmbedding> pinned = [];
        GarbageCollectionResult? gc = null;
        var errors = new List<string?>();
        var allErrors = new List<string>();
        string? initialHex = null, initialState = null;
        long[]? buildingEvidence = null, whilePinned = null;
        object? vectors = null, manifestRows = null;
        var events = c.GetProperty("events").EnumerateArray().ToArray();
        Assert.NotEmpty(events);
        try
        {
            for (int i = 0; i < events.Length; i++)
            {
                var e = events[i];
                var store = e.TryGetProperty("store", out var owner) ? owner.GetString() switch
                {
                    "A" => first, "B" => second ?? throw new InvalidOperationException("Second store missing."), _ => throw new InvalidOperationException("Unknown fixture store.")
                } : first;
                string? actualError = null;
                if (skipInitialPin && i == 0)
                {
                    Assert.Equal("pinQuery", e.GetProperty("op").GetString());
                    Assert.Equal(e.GetProperty("notebookId").GetInt64(), pins[e.GetProperty("saveAs").GetString()!].NotebookId);
                    continue;
                }
                try
                {
                    switch (e.GetProperty("op").GetString())
                    {
                        case "activate": store.ActivateGeneration(e.GetProperty("generationId").GetInt64(), e.GetProperty("at").GetInt64()); break;
                        case "retire": store.RetireGeneration(e.GetProperty("generationId").GetInt64()); break;
                        case "storeEmbedding": store.StoreGenerationEmbedding(e.GetProperty("generationId").GetInt64(), e.GetProperty("chunkId").GetInt64(), Vector(e.GetProperty("vector"))); break;
                        case "setManifest": store.SetManifest(e.GetProperty("generationId").GetInt64(), Entries(e.GetProperty("entries"))); break;
                        case "reconcile": store.ReconcileManifest(e.GetProperty("generationId").GetInt64()); break;
                        case "executeSql": V19TestStore.Seed(store, e.GetProperty("sql")); break;
                        case "commitForegroundRevision": store.CommitForegroundRevision(e.GetProperty("sourceId").GetInt64(), Draft(e.GetProperty("draft")), Chunks(e.GetProperty("chunks")), e.GetProperty("at").GetInt64(), e.GetProperty("token").GetString()!); break;
                        case "pinQuery": pins[e.GetProperty("saveAs").GetString()!] = store.PinQuery(e.GetProperty("notebookId").GetInt64(), e.GetProperty("modelKey").GetString()!); break;
                        case "releaseQuery":
                            string key = e.GetProperty("pin").GetString()!;
                            store.ReleaseQuery(pins[key]); released.Add(key);
                            break;
                        case "pinnedEmbeddings": pinned = store.PinnedEmbeddings(pins[e.GetProperty("pin").GetString()!]); break;
                        case "garbageCollect":
                            gc = store.GarbageCollect(e.GetProperty("notebookId").GetInt64());
                            if (pins.Keys.Any(k => !released.Contains(k))) whilePinned = Query<long>(store, "SELECT id FROM index_generations WHERE notebook_id=1 ORDER BY id");
                            break;
                        case "copyUnchangedVectors":
                            long? excluded = e.GetProperty("excludingChunkId").ValueKind == JsonValueKind.Null ? null : e.GetProperty("excludingChunkId").GetInt64();
                            InTransaction(store, (connection, tx) => GenerationSQL.CopyUnchangedVectors(connection, tx, e.GetProperty("fromGenerationId").GetInt64(), e.GetProperty("toGenerationId").GetInt64(), excluded));
                            break;
                        case "inspect":
                            long id = e.GetProperty("generationId").GetInt64();
                            initialHex = Scalar<string>(store, "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=$id ORDER BY chunk_id", new { id });
                            initialState = Assert.Single(store.Manifest(id)).State;
                            break;
                        case "inspectEvidence":
                            lock (store.Gate)
                                buildingEvidence = store.Connection.Query<long>("""
                                    SELECT c.id FROM source_chunks c JOIN index_generation_manifest m ON m.revision_id=c.revision_id
                                    JOIN chunk_embeddings e ON e.chunk_id=c.id AND e.generation_id=m.generation_id
                                    WHERE m.generation_id=$id AND m.state='done' ORDER BY c.id
                                    """, new { id = e.GetProperty("generationId").GetInt64() }).ToArray();
                            break;
                        case "upgrade": Assert.Equal(c.GetProperty("configuredModelKey").GetString(), e.GetProperty("configuredModelKey").GetString()); break;
                        case "inspectSource":
                            long source = e.GetProperty("sourceId").GetInt64();
                            Assert.Equal(c.GetProperty("sourceId").GetInt64(), source);
                            lock (store.Gate)
                            {
                                vectors = store.Connection.Query("""
                                    SELECT ce.chunk_id,g.model,g.dims,hex(ce.embedding) AS bytes FROM chunk_embeddings ce
                                    JOIN source_chunks sc ON sc.id=ce.chunk_id JOIN index_generations g ON g.id=ce.generation_id
                                    WHERE sc.source_id=$source ORDER BY ce.chunk_id,g.model,g.dims
                                    """, new { source }).Select(r => new object[] { (long)r.chunk_id, (string)r.model, (long)r.dims, (string)r.bytes }).ToArray();
                                manifestRows = store.Connection.Query("""
                                    SELECT g.model,g.dims,m.state,m.reason FROM index_generation_manifest m JOIN index_generations g ON g.id=m.generation_id
                                    WHERE m.source_id=$source ORDER BY g.model,g.dims
                                    """, new { source }).Select(r => new object?[] { (string)r.model, (long)r.dims, (string)r.state, (string?)r.reason }).ToArray();
                            }
                            break;
                        default: throw new InvalidOperationException($"Unhandled generation fixture event {e.GetProperty("op").GetString()}.");
                    }
                }
                catch (StorageV19Exception error) { actualError = error.Code; allErrors.Add(error.Code); }
                if (e.TryGetProperty("expectedError", out var expectedError))
                {
                    Assert.Equal(expectedError.GetString(), actualError); errors.Add(actualError);
                }
                else if (events.Length == 1 && c.TryGetProperty("expectedError", out var topError)) Assert.Equal(topError.GetString(), actualError);
                else Assert.Null(actualError);
            }
            if (c.TryGetProperty("expectedError", out var errorCode)) Assert.Contains(errorCode.GetString(), allErrors);
            if (c.TryGetProperty("identity", out var identity)) Assert.Equal(Identity(identity), first.Generation(2)!.Identity);
            var expected = c.GetProperty("expected");
            foreach (var p in expected.EnumerateObject())
            {
                object? actual = p.Name switch
                {
                    "activeId" => first.ActiveGeneration(1)?.Id,
                    "activeCount" => Scalar<int>(first, "SELECT count(*) FROM index_generations WHERE notebook_id=1 AND state='active'"),
                    "manifestState" => Assert.Single(first.Manifest(2)).State,
                    "manifestRowCount" => first.Manifest(2).Count,
                    "manifestAfterReconcile" => first.Manifest(2).OrderBy(m => m.SourceId).ToArray(),
                    "previousState" or "state" => first.Generation(1)!.State,
                    "newState" => first.Generation(2)!.State,
                    "reason" => Assert.Single(first.Manifest(2)).Reason,
                    "currentRevision" => Scalar<long?>(first, "SELECT current_revision FROM sources WHERE id=1"),
                    "publishedRevisionId" => Scalar<long?>(first, "SELECT published_revision_id FROM sources WHERE id=1"),
                    "vectorCount" => Scalar<int>(first, "SELECT count(*) FROM chunk_embeddings WHERE generation_id=2"),
                    "generationIds" or "generationIdsAfterRelease" => Query<long>(first, "SELECT id FROM index_generations WHERE notebook_id=1 ORDER BY id"),
                    "generationIdsWhilePinned" => whilePinned,
                    "revisionIds" => Query<long>(first, "SELECT id FROM source_revisions WHERE source_id=1 ORDER BY id"),
                    "chunkIds" => Query<long>(first, "SELECT id FROM source_chunks WHERE source_id=1 ORDER BY id"),
                    "jobIds" => Query<long>(first, "SELECT id FROM ingest_jobs ORDER BY id"),
                    "gc" => gc,
                    "pinnedChunkIds" => pinned.Select(v => v.ChunkId).Order().ToArray(),
                    "pinnedRevisionIds" => pins["oldPin"].VectorRevisions.Values.Distinct().Order().ToArray(),
                    "oldVectorHex" => Convert.ToHexString(Assert.Single(pinned).Vector.ToBytes()),
                    "errors" => errors,
                    "vectors" => vectors,
                    "manifestRows" => manifestRows,
                    "initialVectorHex" => initialHex,
                    "initialManifestState" => initialState,
                    "buildingEvidenceChunkIds" => buildingEvidence,
                    "retainedCopiedChunkIds" => Query<long>(first, "SELECT chunk_id FROM chunk_embeddings WHERE generation_id=2 ORDER BY chunk_id"),
                    "embeddingHex" => Scalar<string>(first, "SELECT hex(embedding) FROM chunk_embeddings WHERE generation_id=2"),
                    "deadlock" => false, // Both ordered concurrent calls completed within their bounded waits above.
                    _ => throw new InvalidOperationException($"Unhandled generation expected field {p.Name}.")
                };
                Equal(p.Value, actual);
            }
            if (c.GetProperty("name").GetString() == "vector-normalization")
            {
                var normalized = new[] { 0.6f, 0.8f }.SelectMany(value =>
                {
                    var bytes = BitConverter.GetBytes(value); if (!BitConverter.IsLittleEndian) Array.Reverse(bytes); return bytes;
                }).ToArray();
                Assert.Equal(normalized, Scalar<byte[]>(first, "SELECT embedding FROM chunk_embeddings WHERE generation_id=2"));
                var vectorsInput = c.GetProperty("vectors").EnumerateArray().ToArray();
                Assert.Equal(events.Length, vectorsInput.Length);
                for (int i = 0; i < vectorsInput.Length; i++) Assert.True(JsonElement.DeepEquals(vectorsInput[i], events[i].GetProperty("vector")));
            }
        }
        finally
        {
            foreach (var pin in pins.Values) first.ReleaseQuery(pin);
        }
    }
}
