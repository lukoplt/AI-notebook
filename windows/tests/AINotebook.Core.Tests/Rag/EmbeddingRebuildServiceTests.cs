using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class EmbeddingRebuildServiceTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/embedding-default-v1.json");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static readonly EmbeddingModelChoice Old = new(ProviderConfig.OllamaId, "nomic-embed-text", null);
    private static readonly GenerationIdentity OldIdentity = new(ProviderConfig.OllamaId, "endpoint-v1:test", "nomic-embed-text",
        null, 768, "l2", "1", "1", "2");

    private static string TempDir() => Directory.CreateTempSubdirectory("wp7-rebuild-").FullName;

    [Fact]
    public void InvalidSecondTargetRollsBackFirstActivation()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var selection = EmbeddingRecommendation.Selection("nomic-v2-256");
        var identity = EmbeddingRecommendation.Identity(selection, "endpoint-v1:test", null, "1");
        long a = store.CreateNotebook("a").Id!.Value, b = store.CreateNotebook("b").Id!.Value;
        var oldA = store.CreateGeneration(a, identity, 1); var oldB = store.CreateGeneration(b, identity, 1);
        store.ActivateGeneration(oldA.Id, 2); store.ActivateGeneration(oldB.Id, 2);
        var nextA = store.CreateGeneration(a, identity, 3);
        var e = Assert.Throws<EmbeddingRecommendationException>(() => store.ActivateEmbeddingRebuild(
            [new(a, nextA.Id), new(b, long.MaxValue)], selection, 4));
        Assert.Equal("invalidGeneration", e.Code);
        Assert.Equal(oldA.Id, store.ActiveGeneration(a)!.Id);
        Assert.Equal(oldB.Id, store.ActiveGeneration(b)!.Id);
        Assert.Equal("building", store.Generation(nextA.Id)!.State);
    }

    [Fact]
    public async Task RecoveryFinishesCommittedSelectionAndIsIdempotent()
    {
        string dir = TempDir();
        try
        {
            using var store = new NotebookStore(StorePath.InMemory);
            store.CreateNotebook("one");
            var next = EmbeddingRecommendation.Selection("nomic-v2-256");
            var selected = Old; bool fail = true;
            var journal = new EmbeddingRebuildJournal(Path.Combine(dir, EmbeddingRebuildJournal.FileName));
            var service = new EmbeddingRebuildService(store, journal, () => selected,
                value => { if (fail) throw new IOException("write failed"); selected = value; },
                (notebookId, selection, ct) => Task.FromResult(store.CreateGeneration(notebookId,
                    EmbeddingRecommendation.Identity(selection, "endpoint-v1:test", null, "1"), 1)), () => 2);
            var e = await Assert.ThrowsAsync<EmbeddingRecommendationException>(() => service.RebuildAsync(next));
            Assert.Equal("selectionPersistenceFailed", e.Code);
            Assert.Equal(Old, selected); Assert.NotNull(journal.Read());
            fail = false; service.Recover(); service.Recover();
            Assert.Equal(next, selected); Assert.Null(journal.Read());
        }
        finally { Directory.Delete(dir, true); }
    }

    private sealed class Harness : IDisposable
    {
        public readonly NotebookStore Store = new(StorePath.InMemory);
        public readonly string Dir = TempDir();
        public readonly EmbeddingRebuildJournal Journal;
        public readonly Dictionary<long, long> OldActive = [];
        public readonly List<long> Staged = [];
        public readonly EmbeddingModelChoice Requested = EmbeddingRecommendation.Selection("nomic-v2-256");
        public readonly GenerationIdentity NewIdentity;
        public EmbeddingModelChoice Selected = Old;
        public bool FailPersist;
        public Func<int, long, CancellationToken, Task<IndexGeneration>>? Stage;
        public Func<EmbeddingModelChoice, CancellationToken, Task>? Verify;
        private int _calls;

        public Harness(int notebooks)
        {
            Journal = new(Path.Combine(Dir, EmbeddingRebuildJournal.FileName));
            NewIdentity = EmbeddingRecommendation.Identity(Requested, "endpoint-v1:test", null, "2");
            for (int i = 0; i < notebooks; i++)
            {
                long id = Store.CreateNotebook("n" + i).Id!.Value;
                var old = Store.CreateGeneration(id, OldIdentity, 1);
                Store.ActivateGeneration(old.Id, 1);
                OldActive[id] = old.Id;
            }
        }

        public IndexGeneration Create(long notebookId)
        {
            var g = Store.CreateGeneration(notebookId, NewIdentity, 3);
            lock (Staged) Staged.Add(g.Id);
            return g;
        }

        public EmbeddingRebuildService Service() => new(Store, Journal, () => Selected,
            value => { if (FailPersist) throw new IOException("settings write failed"); Selected = value; },
            (notebookId, selection, ct) =>
            {
                Assert.Equal(Requested, selection);
                int call = Interlocked.Increment(ref _calls);
                return Stage is null ? Task.FromResult(Create(notebookId)) : Stage(call, notebookId, ct);
            }, () => 4, Verify);

        public IReadOnlyList<EmbeddingRebuildTarget> StageAll() =>
            OldActive.Keys.Order().Select(id => new EmbeddingRebuildTarget(id, Create(id).Id)).ToArray();

        public void Dispose()
        {
            Store.Dispose();
            Directory.Delete(Dir, true);
        }
    }

    private static async Task<string?> Capture(Func<Task> action)
    {
        try { await action(); return null; }
        catch (OperationCanceledException) { return "cancelled"; }
        catch (EmbeddingRecommendationException e) { return e.Code; }
    }

    [Fact]
    public async Task SharedRebuildCases()
    {
        int n = 0;
        foreach (var c in Cases("rebuild"))
        {
            string name = c.GetProperty("name").GetString()!;
            var op = c.GetProperty("operation");
            string? failAt = op.GetProperty("failAt").ValueKind == JsonValueKind.Null ? null : op.GetProperty("failAt").GetString();
            int notebook = op.TryGetProperty("notebook", out var nb) ? nb.GetInt32() : 0;
            int recover = op.TryGetProperty("recover", out var r) ? r.GetInt32() : 0;
            using var h = new Harness(c.GetProperty("notebooks").GetInt32());
            using var cts = new CancellationTokenSource();
            string? error = null;
            switch (failAt)
            {
                case null:
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested));
                    break;
                case "stage":
                    // Like the real builder, a failing stage retires the generation it created itself.
                    h.Stage = (call, id, ct) =>
                    {
                        var g = h.Create(id);
                        if (call != notebook) return Task.FromResult(g);
                        h.Store.RetireGeneration(g.Id);
                        throw new EmbeddingRecommendationException("stageFailed");
                    };
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested));
                    break;
                case "cancelAfterStage":
                case "cancelBeforeJournal":
                    int cancelAt = failAt == "cancelAfterStage" ? notebook : h.OldActive.Count;
                    h.Stage = (call, id, ct) => { var g = h.Create(id); if (call == cancelAt) cts.Cancel(); return Task.FromResult(g); };
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested, cts.Token));
                    break;
                case "cancelBeforeStage":
                    cts.Cancel();
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested, cts.Token));
                    break;
                case "activationTarget":
                    h.Stage = (call, id, ct) =>
                    {
                        var g = h.Create(id);
                        if (call == notebook) h.Store.RetireGeneration(g.Id);
                        return Task.FromResult(g);
                    };
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested));
                    break;
                case "addNotebookDuringStage":
                    h.Stage = (call, id, ct) => { if (call == 1) h.Store.CreateNotebook("late"); return Task.FromResult(h.Create(id)); };
                    error = await Capture(() => h.Service().RebuildAsync(h.Requested));
                    break;
                case "persist":
                    h.FailPersist = true;
                    var persisting = h.Service();
                    error = await Capture(() => persisting.RebuildAsync(h.Requested));
                    h.FailPersist = false;
                    for (int i = 0; i < recover; i++) persisting.Recover();
                    break;
                case "crashAfterActivation":
                {
                    var targets = h.StageAll();
                    h.Journal.Write(new(1, Old, h.Requested, targets));
                    h.Store.ActivateEmbeddingRebuild(targets, h.Requested, 4);
                    var reopened = h.Service();
                    for (int i = 0; i < recover; i++) error ??= await Capture(() => { reopened.Recover(); return Task.CompletedTask; });
                    break;
                }
                case "crashAfterJournal":
                {
                    h.Journal.Write(new(1, Old, h.Requested, h.StageAll()));
                    var reopened = h.Service();
                    for (int i = 0; i < recover; i++) error ??= await Capture(() => { reopened.Recover(); return Task.CompletedTask; });
                    break;
                }
                case "mixedJournalTargets":
                {
                    var targets = h.StageAll();
                    h.Store.ActivateGeneration(targets[0].GenerationId, 4);
                    h.Journal.Write(new(1, Old, h.Requested, targets));
                    var reopened = h.Service();
                    for (int i = 0; i < recover; i++) error ??= await Capture(() => { reopened.Recover(); return Task.CompletedTask; });
                    break;
                }
                case "concurrentRebuild":
                {
                    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                    h.Stage = async (call, id, ct) => { entered.TrySetResult(); await release.Task; return h.Create(id); };
                    var service = h.Service();
                    var first = service.RebuildAsync(h.Requested);
                    await entered.Task;
                    error = await Capture(() => service.RebuildAsync(h.Requested));
                    release.SetResult();
                    await first;
                    break;
                }
                default: throw new InvalidOperationException(failAt);
            }

            var expectedError = c.GetProperty("expectedError");
            Assert.True(expectedError.ValueKind == JsonValueKind.Null ? error is null : expectedError.GetString() == error, $"{name}: {error}");
            var notebooks = h.OldActive.Keys.Order().ToArray();
            var staged = h.Staged.ToHashSet();
            switch (c.GetProperty("expectedActive").GetString())
            {
                case "old":
                    Assert.All(notebooks, id => Assert.Equal(h.OldActive[id], h.Store.ActiveGeneration(id)!.Id));
                    break;
                case "new":
                    Assert.All(notebooks, id => Assert.Contains(h.Store.ActiveGeneration(id)!.Id, staged));
                    Assert.All(h.OldActive.Values, id => Assert.Equal("retired", h.Store.Generation(id)!.State));
                    break;
                case "mixed":
                    Assert.Contains(h.Store.ActiveGeneration(notebooks[0])!.Id, staged);
                    Assert.Equal(h.OldActive[notebooks[1]], h.Store.ActiveGeneration(notebooks[1])!.Id);
                    break;
                case "none":
                    Assert.Empty(notebooks);
                    break;
                default: throw new InvalidOperationException(name);
            }
            Assert.Equal(c.GetProperty("expectedSelection").GetString() == "new" ? h.Requested : Old, h.Selected);
            Assert.Equal(c.GetProperty("journalRetained").GetBoolean(), h.Journal.Read() is not null);
            var stagedState = c.GetProperty("expectedStagedState");
            if (stagedState.ValueKind != JsonValueKind.Null)
            {
                Assert.NotEmpty(staged);
                Assert.All(staged, id => Assert.Equal(stagedState.GetString(), h.Store.Generation(id)!.State));
            }
            else if (failAt is null or "cancelBeforeStage") Assert.Empty(staged);
            n++;
        }
        Assert.Equal(15, n);
    }

    [Fact]
    public async Task PublicationRevalidatesTheCapturedDigest()
    {
        var strict = SharedFixtures.Json("contracts/embedding-strict-v1.json");
        int n = 0;
        foreach (var c in strict.GetProperty("cases").EnumerateArray().Where(x => x.GetProperty("kind").GetString() == "publish"))
        {
            string name = c.GetProperty("name").GetString()!;
            var identity = OllamaBenchmarkClientTests.Identity(c.GetProperty("identity"));
            using var h = new Harness(1);
            var handler = new OllamaBenchmarkClientTests.ScriptHandler().Reply(200, c.GetProperty("tags").GetRawText());
            using var http = new HttpClient(handler);
            var client = new OllamaBenchmarkClient(new Uri("http://127.0.0.1:11434"), http);
            h.Verify = (selection, ct) => EmbeddingProfileCapture.VerifyDigestAsync(client, identity, ct);
            string? error = null;
            try { await h.Service().RebuildAsync(h.Requested); }
            catch (EmbeddingProfileException e) { error = e.Code; }
            var expected = c.GetProperty("expected");
            Assert.True(expected.GetProperty("error").ValueKind == JsonValueKind.Null ? error is null
                : expected.GetProperty("error").GetString() == error, $"{name}: {error}");
            long notebook = h.OldActive.Keys.Single();
            bool unchanged = h.Store.ActiveGeneration(notebook)!.Id == h.OldActive[notebook];
            Assert.Equal(expected.GetProperty("activeGenerationUnchanged").GetBoolean(), unchanged);
            Assert.Equal(expected.GetProperty("activated").GetBoolean(), h.Staged.Any(id => h.Store.Generation(id)!.State == "active"));
            Assert.Single(handler.Requests);
            n++;
        }
        Assert.Equal(2, n);
    }

    [Fact]
    public void JournalRoundTripsAndRejectsCorruption()
    {
        string dir = TempDir();
        try
        {
            var journal = new EmbeddingRebuildJournal(Path.Combine(dir, "nested", EmbeddingRebuildJournal.FileName));
            Assert.Null(journal.Read());
            journal.Clear();
            var record = new EmbeddingRebuildRecord(1, Old, EmbeddingRecommendation.Selection("bge-m3-1024"), [new(1, 7), new(2, 8)]);
            journal.Write(record);
            var read = journal.Read()!;
            Assert.Equal(record.Previous, read.Previous);
            Assert.Equal(record.Requested, read.Requested);
            Assert.Equal(record.Targets, read.Targets);
            Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(journal.Path)!, "*.tmp"));
            string text = File.ReadAllText(journal.Path);
            Assert.DoesNotContain("http", text);
            File.WriteAllText(journal.Path, "{\"version\":");
            Assert.Equal("invalidJournal", Assert.Throws<EmbeddingRecommendationException>(() => journal.Read()).Code);
            File.WriteAllText(journal.Path, text.Replace("\"version\":1", "\"version\":2"));
            Assert.Equal("invalidJournal", Assert.Throws<EmbeddingRecommendationException>(() => journal.Read()).Code);
            Assert.Equal("invalidJournal", Assert.Throws<EmbeddingRecommendationException>(() =>
                journal.Write(record with { Targets = [new(1, 7), new(1, 8)] })).Code);
            journal.Clear();
            Assert.Null(journal.Read());
        }
        finally { Directory.Delete(dir, true); }
    }
}
