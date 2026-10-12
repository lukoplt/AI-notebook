using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Providers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>
/// Lease clock advanced only by the test. <c>Advance(_, wake: false)</c> models a suspended process:
/// time passes the lease while no renewal timer fires.
/// </summary>
internal sealed class DrainLeaseClock(long now) : IIngestLeaseClock
{
    private readonly object _lock = new();
    private readonly List<(long Until, TaskCompletionSource Tcs)> _waiters = [];
    private long _now = now;

    public long Now { get { lock (_lock) return _now; } }

    public Task WaitUntilAsync(long deadline, CancellationToken ct)
    {
        lock (_lock)
        {
            ct.ThrowIfCancellationRequested();
            if (_now >= deadline) return Task.CompletedTask;
            var entry = (deadline, new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
            _waiters.Add(entry);
            ct.Register(() =>
            {
                lock (_lock) _waiters.Remove(entry);
                entry.Item2.TrySetCanceled(ct);
            });
            return entry.Item2.Task;
        }
    }

    /// <summary>Waits until a renewal timer is armed, so a time jump never races its arming.</summary>
    public async Task WaitForTimerAsync()
    {
        while (true)
        {
            lock (_lock) if (_waiters.Count > 0) return;
            await Task.Delay(1);
        }
    }

    public void Advance(long seconds, bool wake)
    {
        var due = new List<TaskCompletionSource>();
        lock (_lock)
        {
            _now += seconds;
            if (wake)
                foreach (var waiter in _waiters.Where(w => w.Until <= _now).ToArray())
                {
                    _waiters.Remove(waiter);
                    due.Add(waiter.Tcs);
                }
        }
        foreach (var tcs in due) tcs.TrySetResult();
    }
}

/// <summary>Fixture strict transport recording formatted inputs and native dimensions.</summary>
internal sealed class DrainTransport(float[] vector, int promptTokens, params Func<Task>[] hooks) : IStrictEmbeddingTransport
{
    private readonly object _lock = new();
    private readonly Queue<Func<Task>> _hooks = new(hooks);
    private readonly List<string> _requests = [];
    private readonly List<int> _nativeDims = [];

    public string[] Requests { get { lock (_lock) return _requests.ToArray(); } }
    public int[] NativeDims { get { lock (_lock) return _nativeDims.ToArray(); } }

    public async Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit,
        CancellationToken ct = default)
    {
        Func<Task>? hook;
        lock (_lock)
        {
            _requests.Add(input);
            _nativeDims.Add(nativeDims);
            hook = _hooks.Count > 0 ? _hooks.Dequeue() : null;
        }
        if (hook is not null) await hook();
        ct.ThrowIfCancellationRequested();
        return new StrictEmbeddingResult(vector.ToArray(), promptTokens, null, null);
    }
}

/// <summary>The case's <c>/api/tags</c> and <c>/api/show</c>, derived exactly as profile capture does.</summary>
internal sealed class DrainDiscovery(JsonElement c)
{
    public const string Root = "http://127.0.0.1:11434";
    private readonly (string Name, string? Digest)[] _rows = c.GetProperty("tags").GetProperty("models").EnumerateArray()
        .Select(m => (m.GetProperty("name").GetString()!, (string?)m.GetProperty("digest").GetString())).ToArray();
    private readonly string _show = c.GetProperty("show").GetRawText();

    public PreparedEmbeddingProfile Prepared(EmbeddingModelChoice selection, DrainTransport transport)
    {
        var profile = EmbeddingProfiles.Require(selection.ProfileId!);
        int context = ProviderLimitPolicy.ContextWindowFromOllamaShow(_show) ?? throw new EmbeddingProfileException("modelMetadataUnavailable");
        int limit = Math.Min(profile.MaxInputTokens, context);
        var identity = EmbeddingRecommendation.Identity(selection, EmbeddingEndpointRevision.Make(ProviderType.Ollama, Root),
            EmbeddingProfileCapture.ExactDigest(_rows, profile.Model), "2", limit);
        return new PreparedEmbeddingProfile(identity, Session(identity, transport));
    }

    /// <summary>Resume of a stored identity: exact catalog profile, ctx parsed from the stored formats.</summary>
    public static ProviderEmbeddingSession Session(GenerationIdentity identity, DrainTransport transport)
    {
        var profile = EmbeddingQueryFormat.Profile(identity.QueryFormatVersion) ?? throw new EmbeddingProfileException("profileIdentityMismatch");
        int limit = profile.ValidateIdentity(identity.Model, identity.Dims, identity.QueryFormatVersion, identity.DocFormatVersion);
        return new ProviderEmbeddingSession(identity.ProviderId + ":" + identity.Model, identity.EndpointRevision, identity, profile,
            new StrictEmbeddingPipeline(transport), limit);
    }
}

public sealed class ProfileEmbeddingDrainTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-default-v1.json");

    private static JsonElement[] DrainCases() =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == "drain").ToArray();

    private static JsonElement Case(string name) => DrainCases().Single(c => c.GetProperty("name").GetString() == name);

    private static GenerationIdentity? Identity(JsonElement e) =>
        e.ValueKind == JsonValueKind.Null ? null : OllamaBenchmarkClientTests.Identity(e);

    private static EmbeddingModelChoice Choice(JsonElement e) => new(e.GetProperty("providerId").GetString()!,
        e.GetProperty("model").GetString()!, e.GetProperty("profileId").ValueKind == JsonValueKind.Null ? null : e.GetProperty("profileId").GetString());

    private static RevisionDraft Draft(string text) =>
        new(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text))), text, 1, 2);

    private static string Code(Exception error) => error switch
    {
        ProfileEmbeddingDrainException e => e.Code,
        EmbeddingGenerationException e => e.Code,
        EmbeddingProfileException e => e.Code,
        OperationCanceledException => "cancelled",
        _ => "unexpected:" + error
    };

    private static DrainTransport Transport(JsonElement c, params Func<Task>[] hooks)
    {
        var spec = c.GetProperty("transport");
        return new DrainTransport(EmbeddingProfileTests.Vector(spec.GetProperty("vector")), spec.GetProperty("promptTokens").GetInt32(), hooks);
    }

    /// <summary>A complete active generation of <paramref name="identity"/> over the notebook's published corpus.</summary>
    private static async Task<IndexGeneration> ActivateAsync(NotebookStore store, long notebookId, GenerationIdentity identity, long now)
    {
        var generation = await EmbeddingGenerationBuilder.StageAsync(store, notebookId, identity, () => now,
            (inputs, ct) => Task.FromResult(inputs.Select(_ => Unit(identity.Dims)).ToArray()));
        store.ActivateGeneration(generation.Id, now);
        return generation;
    }

    private static float[] Unit(int dims)
    {
        var v = new float[dims];
        v[0] = 1;
        return v;
    }

    private static int VectorRows(NotebookStore store, IEnumerable<long> generations)
    {
        lock (store.Gate)
            return generations.Sum(id => store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM chunk_embeddings WHERE generation_id=$id", new { id }));
    }

    private static string? JobState(NotebookStore store, IEnumerable<long> generations)
    {
        lock (store.Gate)
            return generations.Select(id => store.Connection.QuerySingleOrDefault<string?>(
                "SELECT state FROM ingest_jobs WHERE kind='embed' AND target=$target ORDER BY id DESC LIMIT 1",
                new { target = "generation:" + id })).LastOrDefault(s => s is not null);
    }

    private static long MaxGenerationId(NotebookStore store)
    {
        lock (store.Gate) return store.Connection.ExecuteScalar<long>("SELECT coalesce(max(id),0) FROM index_generations");
    }

    [Fact]
    public async Task SharedDrainCases()
    {
        Assert.Equal(new[] { "fresh-import", "restart-no-work", "same-model-other-dims", "legacy-no-profile", "refresh-pending",
            "lost-lease", "selected-profile-changed", "changed-active-during-request" },
            DrainCases().Select(c => c.GetProperty("name").GetString()));
        foreach (var c in DrainCases()) await RunDrainCaseAsync(c);
    }

    private static async Task RunDrainCaseAsync(JsonElement c)
    {
        string name = c.GetProperty("name").GetString()!;
        var expected = c.GetProperty("expected");
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook(name, "").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "doc", null, null).Id!.Value;
        string text = c.GetProperty("canonicalText").GetString()!;
        var revisions = c.GetProperty("source");
        for (int r = 0; r < revisions.GetProperty("publishedRevision").GetInt32(); r++)
            store.CommitForegroundRevision(sourceId, Draft(text), ScalarChunker.Chunk(text), r, "fixture-extract-" + r);
        IndexGeneration? previous = null;
        if (Identity(c.GetProperty("activeBefore")) is { } before) previous = await ActivateAsync(store, notebookId, before, 5);
        if (revisions.GetProperty("currentRevision").GetInt32() > revisions.GetProperty("publishedRevision").GetInt32())
            store.InsertRevision(sourceId, Draft("refresh"), 6);
        long setupMax = MaxGenerationId(store);

        var clock = new DrainLeaseClock(100);
        var selection = Choice(c.GetProperty("selection"));
        long? otherId = null;
        var hooks = new List<Func<Task>>();
        foreach (var e in c.GetProperty("events").EnumerateArray())
        {
            Assert.Equal("request", e.GetProperty("after").GetString());
            switch (e.GetProperty("kind").GetString())
            {
                case "advanceClock":
                    long seconds = e.GetProperty("seconds").GetInt64();
                    hooks.Add(async () => { await clock.WaitForTimerAsync(); clock.Advance(seconds, wake: false); });
                    break;
                case "changeSelection":
                    var next = Choice(e.GetProperty("selection"));
                    hooks.Add(() => { Volatile.Write(ref selection, next); return Task.CompletedTask; });
                    break;
                case "activateOther":
                    var other = Identity(e.GetProperty("identity"))!;
                    hooks.Add(() =>
                    {
                        var g = store.CreateGeneration(notebookId, other, clock.Now);
                        foreach (var chunk in store.Chunks(sourceId))
                            store.StoreGenerationEmbedding(g.Id, chunk.Id!.Value, new EmbeddingVector(Unit(other.Dims)));
                        store.SetManifest(g.Id, store.Manifest(g.Id).Select(m => m with { State = "done", Reason = null }).ToArray());
                        store.ActivateGeneration(g.Id, clock.Now);
                        otherId = g.Id;
                        return Task.CompletedTask;
                    });
                    break;
                default: Assert.Fail("unknown event " + e);
                    break;
            }
        }
        var transport = Transport(c, hooks.ToArray());
        var discovery = new DrainDiscovery(c);
        int prepares = 0, resumes = 0;
        var drain = new ProfileEmbeddingDrain(store, () => Volatile.Read(ref selection),
            (chosen, ct) => { Interlocked.Increment(ref prepares); return Task.FromResult(discovery.Prepared(chosen, transport)); },
            (stored, ct) => { Interlocked.Increment(ref resumes); return Task.FromResult(DrainDiscovery.Session(stored, transport)); },
            clock);

        int? result = null;
        Exception? thrown = null;
        try { result = await drain.RunAsync(); }
        catch (Exception error) { thrown = error; }

        Assert.True((expected.TryGetProperty("error", out var err) ? err.GetString() : null) == (thrown is null ? null : Code(thrown)),
            $"{name}: error {(thrown is null ? "none" : Code(thrown))}");
        if (thrown is null)
            Assert.Equal(expected.GetProperty("result").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("result").GetInt32(), result);
        Assert.Equal(expected.GetProperty("requests").EnumerateArray().Select(x => x.GetString()!).ToArray(), transport.Requests);
        if (expected.TryGetProperty("nativeDims", out var native)) Assert.Equal(new[] { native.GetInt32() }, transport.NativeDims);
        // WP0 scheduler sweep: an expired attempt is requeued with backoff, never published.
        store.RecoverExpiredJobs(clock.Now);
        long[] created;
        lock (store.Gate)
            created = store.Connection.Query<long>("SELECT id FROM index_generations WHERE id>$setupMax ORDER BY id", new { setupMax })
                .Where(id => id != otherId).ToArray();
        Assert.True(expected.GetProperty("rowsWritten").GetInt32() == VectorRows(store, created), name + ": rowsWritten");
        Assert.True((expected.GetProperty("jobState").ValueKind == JsonValueKind.Null ? null : expected.GetProperty("jobState").GetString())
            == JobState(store, created), name + ": jobState " + JobState(store, created));
        var active = store.ActiveGeneration(notebookId);
        Assert.Equal(Identity(expected.GetProperty("activeIdentity")), active?.Identity);
        Assert.True(expected.GetProperty("published").GetBoolean() == (active is not null && created.Contains(active.Id)), name + ": published");
        if (expected.TryGetProperty("activeGenerationUnchanged", out var unchanged) && unchanged.GetBoolean())
        {
            Assert.Equal(previous?.Id, active?.Id);
            Assert.Equal(0, prepares + resumes);
        }
        if (expected.TryGetProperty("previousActiveRetired", out var retired) && retired.GetBoolean())
            Assert.Equal("retired", store.Generation(previous!.Id)!.State);
        if (expected.TryGetProperty("dims", out var dims) && expected.GetProperty("published").GetBoolean())
        {
            Assert.Equal(dims.GetInt32(), active!.Identity.Dims);
            Assert.Equal(expected.GetProperty("queryFormatVersion").GetString(), active.Identity.QueryFormatVersion);
            Assert.Equal(expected.GetProperty("docFormatVersion").GetString(), active.Identity.DocFormatVersion);
            byte[] bytes;
            lock (store.Gate)
                bytes = store.Connection.QuerySingle<byte[]>("SELECT embedding FROM chunk_embeddings WHERE generation_id=$id", new { id = active.Id });
            var values = EmbeddingVector.FromBytes(bytes).Values;
            Assert.Equal(dims.GetInt32(), values.Length);
            Assert.Equal(1f, values[0], 1e-6f);
            Assert.All(values.Skip(1), v => Assert.Equal(0f, v, 1e-6f));
        }
        if (expected.GetProperty("result").ValueKind == JsonValueKind.Null && !expected.TryGetProperty("error", out _))
        {
            Assert.Null(result);
            Assert.Equal(0, prepares + resumes); // legacy: untouched
        }
    }

    [Fact]
    public async Task ReopenedFileStoreWithPersistedSelectionDoesNoProviderWork()
    {
        var c = Case("fresh-import");
        string dir = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        try
        {
            var path = new StorePath(Path.Combine(dir, "db.sqlite"));
            var persisted = Choice(c.GetProperty("selection"));
            string text = c.GetProperty("canonicalText").GetString()!;
            var transport = Transport(c);
            var discovery = new DrainDiscovery(c);
            int prepares = 0, resumes = 0;
            ProfileEmbeddingDrain Drain(NotebookStore s) => new(s, () => persisted,
                (chosen, ct) => { prepares++; return Task.FromResult(discovery.Prepared(chosen, transport)); },
                (stored, ct) => { resumes++; return Task.FromResult(DrainDiscovery.Session(stored, transport)); },
                new DrainLeaseClock(100));
            long notebookId, generationId;
            using (var first = new NotebookStore(path, configuredEmbeddingModelKey: null))
            {
                notebookId = first.CreateNotebook("file", "").Id!.Value;
                long sourceId = first.CreateSource(notebookId, SourceType.Text, "doc", null, null).Id!.Value;
                first.CommitForegroundRevision(sourceId, Draft(text), ScalarChunker.Chunk(text), 1, "fixture-extract");
                Assert.Equal(1, await Drain(first).RunAsync());
                generationId = first.ActiveGeneration(notebookId)!.Id;
            }
            using var reopened = new NotebookStore(path, configuredEmbeddingModelKey: null);
            Assert.Empty(reopened.ProfileEmbeddingWork(persisted));
            Assert.Equal(0, await Drain(reopened).RunAsync());
            Assert.Equal(new[] { "search_document: Záruka platí." }, transport.Requests);
            Assert.Equal(1, prepares);
            Assert.Equal(0, resumes);
            Assert.Equal(generationId, reopened.ActiveGeneration(notebookId)!.Id);
        }
        finally
        {
            Microsoft.Data.Sqlite.SqliteConnection.ClearAllPools();
            try { Directory.Delete(dir, recursive: true); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task MatchingActiveIdentityResumesAndEmbedsOnlyNewRevisions()
    {
        var c = Case("restart-no-work");
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("resume", "").Id!.Value;
        long a = store.CreateSource(notebookId, SourceType.Text, "a", null, null).Id!.Value;
        store.CommitForegroundRevision(a, Draft("alpha"), ScalarChunker.Chunk("alpha"), 1, "extract-a");
        var stored = Identity(c.GetProperty("activeBefore"))!;
        var old = await ActivateAsync(store, notebookId, stored, 2);
        long b = store.CreateSource(notebookId, SourceType.Text, "b", null, null).Id!.Value;
        store.CommitForegroundRevision(b, Draft("beta"), ScalarChunker.Chunk("beta"), 3, "extract-b");
        var selection = Choice(c.GetProperty("selection"));
        Assert.Equal(new[] { notebookId }, store.ProfileEmbeddingWork(selection));
        var transport = Transport(c);
        int prepares = 0, resumes = 0;
        var drain = new ProfileEmbeddingDrain(store, () => selection,
            (_, _) => { prepares++; throw new EmbeddingProfileException("unexpectedPrepare"); },
            (identity, _) =>
            {
                resumes++;
                Assert.Equal(stored, identity);
                return Task.FromResult(DrainDiscovery.Session(identity, transport));
            }, new DrainLeaseClock(100));
        Assert.Equal(1, await drain.RunAsync());
        Assert.Equal(new[] { "search_document: beta" }, transport.Requests);
        Assert.Equal(0, prepares);
        Assert.Equal(1, resumes);
        var active = store.ActiveGeneration(notebookId)!;
        Assert.NotEqual(old.Id, active.Id);
        Assert.Equal(stored, active.Identity); // ctx suffix and digest preserved
        Assert.Equal("retired", store.Generation(old.Id)!.State);
        Assert.Equal(2, VectorRows(store, [active.Id]));
    }

    [Theory]
    [InlineData(true, new long[] { 250, 200 })]
    [InlineData(false, new long[] { 301 })]
    public async Task RenewalKeepsLongRequestPublishableAndLostRenewalNeverPublishes(bool publishes, long[] steps)
    {
        var c = Case("fresh-import");
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("renew", "").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "doc", null, null).Id!.Value;
        store.CommitForegroundRevision(sourceId, Draft("x"), ScalarChunker.Chunk("x"), 1, "extract");
        var clock = new DrainLeaseClock(100);
        var transport = Transport(c, async () =>
        {
            foreach (long step in steps)
            {
                // The renewal re-arms its timer only after the woken renewal reached the store.
                await clock.WaitForTimerAsync();
                clock.Advance(step, wake: true);
            }
        });
        var selection = Choice(c.GetProperty("selection"));
        var discovery = new DrainDiscovery(c);
        var drain = new ProfileEmbeddingDrain(store, () => selection,
            (chosen, _) => Task.FromResult(discovery.Prepared(chosen, transport)),
            (stored, _) => Task.FromResult(DrainDiscovery.Session(stored, transport)), clock);
        if (publishes)
        {
            Assert.Equal(1, await drain.RunAsync());
            Assert.NotNull(store.ActiveGeneration(notebookId));
        }
        else
        {
            var error = await Assert.ThrowsAsync<ProfileEmbeddingDrainException>(() => drain.RunAsync());
            Assert.Equal("leaseLost", error.Code);
            Assert.Null(store.ActiveGeneration(notebookId));
        }
    }

    [Fact]
    public async Task EmptyNotebookAndLegacySelectionAreNotWork()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        store.CreateNotebook("empty", "");
        var selection = EmbeddingRecommendation.Selection("nomic-v2-256");
        Assert.Empty(store.ProfileEmbeddingWork(selection));
        Assert.Empty(store.ProfileEmbeddingWork(selection with { Model = "nomic-embed-text", ProfileId = null }));
        var drain = new ProfileEmbeddingDrain(store, () => selection,
            (_, _) => throw new EmbeddingProfileException("unexpectedPrepare"),
            (_, _) => throw new EmbeddingProfileException("unexpectedResume"), new DrainLeaseClock(1));
        Assert.Equal(0, await drain.RunAsync());
    }
}
