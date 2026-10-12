using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class StorageIntegrationTests
{
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private static readonly HashSet<string> Names = ["replacement", "no-vector-provider-call", "empty-note", "scalar-text", "pdf-pages", "model-switch",
        "reingest-during-embedding", "reindex-keeps-active", "citation-after-gc", "restart", "scalar-empty", "scalar-whitespace", "scalar-combining",
        "scalar-supplementary", "scalar-repeated", "scalar-overlap", "scalar-long-word", "scalar-pdf-crossing", "superseded-extraction", "renew-running-extraction"];
    private static JsonElement[] Cases(params string[] names)
    {
        var all = SharedFixtures.Json("contracts/storage-integration-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.NotEmpty(all);
        Assert.All(all, c => { Assert.Contains(c.GetProperty("name").GetString()!, Names); Assert.Contains(c.GetProperty("operation").GetString(), new[] { "integration", "scalar" }); });
        return names.Select(name => Assert.Single(all, c => c.GetProperty("name").GetString() == name)).ToArray();
    }
    private static void Equal(JsonElement expected, object? actual)
    {
        var json = JsonSerializer.SerializeToElement(actual, JsonOptions);
        Assert.True(JsonElement.DeepEquals(expected, json), $"Expected {expected.GetRawText()}, actual {json.GetRawText()}");
    }
    private static T Scalar<T>(NotebookStore store, string sql, object? args = null)
    {
        lock (store.Gate) return store.Connection.ExecuteScalar<T>(sql, args)!;
    }
    private static long NewNotebook(NotebookStore store) => store.CreateNotebook("integration").Id!.Value;
    private static string TempDirectory()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"storage-integration-{Guid.NewGuid():N}"); Directory.CreateDirectory(directory); return directory;
    }
    private static void AssertPointers(JsonElement expected, Source source) => Equal(expected, new { source.CurrentRevision, source.PublishedRevisionId });
    private static void AssertFreshSource(NotebookStore store, Source returned)
    {
        var persisted = Assert.IsType<Source>(store.Source(returned.Id!.Value));
        Assert.NotNull(returned.CurrentRevision); Assert.Equal(returned.CurrentRevision, returned.PublishedRevisionId);
        Assert.Equal(persisted.CurrentRevision, returned.CurrentRevision); Assert.Equal(persisted.PublishedRevisionId, returned.PublishedRevisionId);
    }
    private static object[] ChunkProjection(IEnumerable<RevisionChunkDraft> chunks) => chunks.Select(c => (object)new { text = c.Text, start = c.CharStart, end = c.CharEnd, c.PageHint, c.TokenCount }).ToArray();
    private static object[] ChunkProjection(IEnumerable<SourceChunk> chunks) => chunks.Select(c => (object)new { text = c.Text, start = c.CharStart, end = c.CharEnd, c.PageHint, c.TokenCount }).ToArray();
    private static void ExpectedOps(JsonElement c, params string[] expected) => Assert.Equal(expected, c.GetProperty("events").EnumerateArray().Select(e => e.GetProperty("op").GetString()).ToArray());

    private sealed class NoEmbeddingClient : IEmbeddingProducing
    {
        public int Calls { get; private set; }
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        { Calls++; throw new InvalidOperationException("Lexical-only search must not call an embedder"); }
    }
    private sealed class FixedClient(Func<string, float[]> vector) : IEmbeddingProducing
    {
        public List<string> Models { get; } = [];
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        { Models.Add(model); return Task.FromResult(inputs.Select(_ => vector(model)).ToArray()); }
    }
    private sealed record EmbeddingCall(string Model, string[] Inputs, TaskCompletionSource<float[][]> Completion);
    private sealed class BarrierClient : IEmbeddingProducing
    {
        private readonly Channel<EmbeddingCall> _calls = Channel.CreateUnbounded<EmbeddingCall>();
        public int Calls { get; private set; }
        public bool OneCallOnly { get; init; }
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Calls++;
            if (OneCallOnly && Calls > 1) throw new InvalidOperationException("Stale batch must stop this drain before retrying newest work.");
            var completion = new TaskCompletionSource<float[][]>(TaskCreationOptions.RunContinuationsAsynchronously);
            Assert.True(_calls.Writer.TryWrite(new(model, inputs.ToArray(), completion)));
            return completion.Task.WaitAsync(ct);
        }
        public Task<EmbeddingCall> Next() => _calls.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
    }
    private sealed class FixedExtractor(ExtractedText text) : ITextExtractor
    {
        public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind) => Task.FromResult(text);
    }
    private sealed class BarrierExtractor : ITextExtractor
    {
        private readonly Channel<TaskCompletionSource<ExtractedText>> _calls = Channel.CreateUnbounded<TaskCompletionSource<ExtractedText>>();
        public Task<ExtractedText> ExtractAsync(Uri url, SourceType kind)
        {
            var completion = new TaskCompletionSource<ExtractedText>(TaskCreationOptions.RunContinuationsAsynchronously);
            Assert.True(_calls.Writer.TryWrite(completion)); return completion.Task;
        }
        public Task<TaskCompletionSource<ExtractedText>> Next() => _calls.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10));
    }
    private sealed class ManualClock : IIngestLeaseClock
    {
        private readonly object _gate = new();
        private long _now;
        private readonly List<(long Deadline, TaskCompletionSource Completion)> _waiting = [];
        private readonly Channel<long> _requests = Channel.CreateUnbounded<long>();
        public long Now { get { lock (_gate) return _now; } }
        public Task WaitUntilAsync(long deadline, CancellationToken ct)
        {
            lock (_gate)
            {
                _requests.Writer.TryWrite(deadline);
                if (_now >= deadline) return Task.CompletedTask;
                var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                _waiting.Add((deadline, completion)); return completion.Task.WaitAsync(ct);
            }
        }
        public void Set(long now, bool wake = true)
        {
            lock (_gate)
            {
                _now = now;
                if (!wake) return;
                foreach (var waiter in _waiting.Where(w => w.Deadline <= now).ToArray())
                { waiter.Completion.TrySetResult(); _waiting.Remove(waiter); }
            }
        }
        public async Task WaitForRequest(long deadline)
        {
            while (await _requests.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(10)) != deadline) { }
        }
    }

    [Fact]
    public async Task ReplacementAndLexicalOnlyFromSharedFixture()
    {
        foreach (var c in Cases("replacement", "no-vector-provider-call"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            long nb = NewNotebook(store);
            long source = store.CreateSource(nb, SourceType.Text, "x", null, null).Id!.Value;
            long oldId = 0;
            var hits = new List<IReadOnlyList<RetrievalHit>>();
            var client = new NoEmbeddingClient();
            string key = c.TryGetProperty("modelKey", out var model) ? model.GetString()! : "unconfigured";
            var retriever = new Retriever(store, client, key);
            foreach (var e in c.GetProperty("events").EnumerateArray())
            {
                switch (e.GetProperty("op").GetString())
                {
                    case "replaceChunks": case "publish": store.ReplaceChunks(source, [new(e.GetProperty("text").GetString()!, 1)]); break;
                    case "captureOldChunk": oldId = Assert.Single(store.Chunks(source)).Id!.Value; break;
                    case "search": hits.Add(await retriever.SearchAsync(nb, e.GetProperty("query").GetString()!)); break;
                    default: throw new InvalidOperationException("Unknown replacement event.");
                }
            }
            var expected = c.GetProperty("expected");
            foreach (var p in expected.EnumerateObject())
            {
                object? actual = p.Name switch
                {
                    "retainedOldChunkCount" => Scalar<int>(store, "SELECT count(*) FROM source_chunks WHERE id=$id", new { id = oldId }),
                    "oldHits" => hits[0].Count, "newHits" => hits[1].Count, "hits" => Assert.Single(hits).Count,
                    "visibleTexts" => store.Chunks(source).Select(chunk => chunk.Text).ToArray(), "providerCalls" => client.Calls,
                    "returnedSourcePointersEqual" => store.Source(source)!.CurrentRevision is not null && store.Source(source)!.CurrentRevision == store.Source(source)!.PublishedRevisionId,
                    _ => throw new InvalidOperationException($"Unknown replacement projection {p.Name}.")
                };
                Equal(p.Value, actual);
            }
            Assert.All(hits.Last(), hit => Assert.Equal(source, hit.SourceId));
            Assert.Empty(await retriever.SearchAsync(nb, store.Chunks(source)[0].Text, sourceIds: Array.Empty<long>()));
            Assert.Equal(0, client.Calls);
        }
        foreach (var c in Cases("superseded-extraction", "renew-running-extraction"))
        {
            RunExtractionFixture(c);
            await RunAsynchronousExtraction(c);
        }
    }

    [Fact]
    public async Task ScalarAndPDFSpans()
    {
        var scalarCases = Cases("scalar-empty", "scalar-whitespace", "scalar-combining", "scalar-supplementary", "scalar-repeated", "scalar-overlap", "scalar-long-word", "scalar-pdf-crossing");
        foreach (var c in scalarCases)
        {
            var starts = c.GetProperty("pageStarts").EnumerateArray().Select(p => (Offset: p[0].GetInt32(), Page: p[1].GetInt32())).ToArray();
            Equal(c.GetProperty("expected").GetProperty("chunks"), ChunkProjection(ScalarChunker.Chunk(c.GetProperty("text").GetString()!, starts, c.GetProperty("window").GetInt32(), c.GetProperty("overlap").GetInt32())));
        }
        foreach (var c in Cases("scalar-text", "pdf-pages"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            long nb = NewNotebook(store);
            Source source;
            if (c.GetProperty("name").GetString() == "scalar-text")
                source = await new IngestionService(store).IngestRawTextAsync("scalar", c.GetProperty("text").GetString()!, nb);
            else
            {
                var extractor = new FixedExtractor(new("PDF", c.GetProperty("extractedText").GetString()!, c.GetProperty("pageHints").EnumerateArray().Select(h => h.GetInt32()).ToArray()));
                source = await new IngestionService(store, pdf: extractor).IngestFileAsync(new Uri(Path.Combine(Path.GetTempPath(), "fixture.pdf")), nb);
                var pageStarts = new List<int[]>(); int offset = 0;
                var pages = c.GetProperty("pages").EnumerateArray().Select(p => p.GetString()!).ToArray();
                var hints = c.GetProperty("pageHints").EnumerateArray().Select(p => p.GetInt32()).ToArray();
                for (int i = 0; i < pages.Length; i++) { pageStarts.Add([offset, hints[i]]); offset += pages[i].EnumerateRunes().Count() + 2; }
                Equal(c.GetProperty("expected").GetProperty("pageStarts"), pageStarts);
            }
            AssertFreshSource(store, source);
            var revision = store.Revision(source.PublishedRevisionId!.Value)!;
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("canonicalText").GetString(), revision.Draft.CanonicalText);
            Assert.Equal(expected.GetProperty("scalarCount").GetInt32(), revision.Draft.CanonicalText.EnumerateRunes().Count());
            Equal(expected.GetProperty("chunks"), ChunkProjection(store.Chunks(source.Id!.Value)));
            Assert.Equal(1, revision.Draft.TextFormatVersion); Assert.Equal(2, revision.Draft.ChunkerVersion);
        }
        foreach (string extension in new[] { "docx", "pptx", "xlsx" })
        {
            using var store = new NotebookStore(StorePath.InMemory);
            var source = await new IngestionService(store, office: new FixedExtractor(new("Office", "A😀éZ")))
                .IngestFileAsync(new Uri(Path.Combine(Path.GetTempPath(), "fixture." + extension)), NewNotebook(store));
            AssertFreshSource(store, source);
            var revision = store.Revision(source.PublishedRevisionId!.Value)!;
            Assert.Equal("A😀éZ", revision.Draft.CanonicalText); Assert.Equal(1, revision.Draft.TextFormatVersion); Assert.Equal(1, revision.Draft.ChunkerVersion);
            Assert.All(store.Chunks(source.Id!.Value), chunk => { Assert.Null(chunk.CharStart); Assert.Null(chunk.CharEnd); });
        }
    }

    [Fact]
    public async Task EmptyNotePublishesEmptyRevision()
    {
        foreach (var c in Cases("empty-note"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            var note = store.CreateNote(NewNotebook(store), "Note", c.GetProperty("initialBody").GetString()!);
            var indexer = new NoteIndexer(store, leaseClock: new ManualClock());
            long? previous = null;
            foreach (var e in c.GetProperty("events").EnumerateArray())
            {
                Assert.Equal("indexNote", e.GetProperty("op").GetString());
                store.UpdateNote(note.Id!.Value, note.Title, e.GetProperty("body").GetString()!);
                await indexer.IndexAsync(note.Id.Value);
                var source = store.Source(store.Note(note.Id.Value)!.AutoSourceId!.Value)!;
                if (previous is not null) Assert.NotEqual(previous, source.PublishedRevisionId);
                previous = source.PublishedRevisionId;
            }
            var shadow = store.Source(store.Note(note.Id!.Value)!.AutoSourceId!.Value);
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("shadowSourceExists").GetBoolean(), shadow is not null);
            Assert.Equal(expected.GetProperty("published").GetBoolean(), shadow!.PublishedRevisionId is not null);
            Assert.Equal(expected.GetProperty("visibleChunks").GetInt32(), store.Chunks(shadow.Id!.Value).Count);
            Assert.Equal(c.GetProperty("body").GetString(), store.Revision(shadow.PublishedRevisionId!.Value)!.Draft.CanonicalText);
            Assert.Equal(2, Scalar<int>(store, "SELECT count(*) FROM source_revisions WHERE source_id=$id", new { id = shadow.Id }));
        }
    }

    [Fact]
    public async Task EmptyNoteStopsRetrievingPreviousVectorEvidence()
    {
        var c = Assert.Single(Cases("empty-note"));
        ExpectedOps(c, "indexNote", "indexNote");
        using var store = new NotebookStore(StorePath.InMemory);
        long notebookId = NewNotebook(store);
        string initialBody = c.GetProperty("initialBody").GetString()!;
        var note = store.CreateNote(notebookId, "Note", initialBody);
        var indexer = new NoteIndexer(store, leaseClock: new ManualClock());
        await indexer.IndexAsync(note.Id!.Value);
        long sourceId = store.Note(note.Id.Value)!.AutoSourceId!.Value;
        var oldChunk = Assert.Single(store.Chunks(sourceId));
        var client = new FixedClient(_ => [1, 0]);
        var embedder = new Embedder(store, client, "empty-note");
        Assert.Equal(1, await embedder.EmbedAllPendingAsync());
        var originalGeneration = Assert.IsType<IndexGeneration>(store.ActiveGeneration(notebookId));
        Assert.Equal(oldChunk.Id, Assert.Single(store.Embeddings(notebookId, "empty-note")).ChunkId);
        var retriever = new Retriever(store, client, "empty-note");
        Assert.Equal(oldChunk.Id, Assert.Single(await retriever.SearchAsync(notebookId, initialBody)).ChunkId);
        var originalCalls = client.Models.ToArray();

        store.UpdateNote(note.Id.Value, note.Title, c.GetProperty("body").GetString()!);
        await indexer.IndexAsync(note.Id.Value);
        var source = Assert.IsType<Source>(store.Source(sourceId));
        var revision = Assert.IsType<SourceRevision>(store.Revision(source.PublishedRevisionId!.Value));
        Assert.Equal(c.GetProperty("body").GetString(), revision.Draft.CanonicalText);
        int expectedEmptyCount = c.GetProperty("expected").GetProperty("visibleChunks").GetInt32();
        Assert.Equal(expectedEmptyCount, store.Chunks(sourceId).Count);

        // Even without a provider batch, the drain must retire the stale vector generation.
        Assert.Equal(expectedEmptyCount, await embedder.EmbedAllPendingAsync());
        Assert.Equal(originalCalls, client.Models.ToArray());
        var currentGeneration = Assert.IsType<IndexGeneration>(store.ActiveGeneration(notebookId));
        Assert.NotEqual(originalGeneration.Id, currentGeneration.Id);
        var manifest = Assert.Single(store.Manifest(currentGeneration.Id));
        Assert.Equal(sourceId, manifest.SourceId);
        Assert.Equal(revision.Id, manifest.RevisionId);
        Assert.Equal("done", manifest.State);
        Assert.Empty(store.Embeddings(notebookId, "empty-note"));
        Assert.Equal(expectedEmptyCount, (await retriever.SearchAsync(notebookId, initialBody)).Count);
        Assert.Equal(1, Scalar<int>(store, "SELECT count(*) FROM source_chunks WHERE id=$id", new { id = oldChunk.Id }));
    }

    [Fact]
    public async Task EmbeddingDrainAndModelSwitch()
    {
        foreach (var c in Cases("model-switch"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            long nb = NewNotebook(store);
            string selected = "";
            var keys = c.GetProperty("keys").EnumerateArray().Select(k => k.GetString()!).ToArray();
            var vectors = c.GetProperty("vectors").EnumerateArray().Select(v => v.EnumerateArray().Select(x => x.GetSingle()).ToArray()).ToArray();
            var client = new FixedClient(key => vectors[Array.IndexOf(keys, key)]);
            var embedder = new Embedder(store, client, () => selected);
            foreach (var e in c.GetProperty("events").EnumerateArray())
            {
                switch (e.GetProperty("op").GetString())
                {
                    case "publish": AssertFreshSource(store, await new IngestionService(store).IngestRawTextAsync("model", e.GetProperty("text").GetString()!, nb)); break;
                    case "selectModel": selected = e.GetProperty("key").GetString()!; break;
                    case "drain":
                        Assert.Equal(1, await embedder.EmbedAllPendingAsync());
                        Equal(e.GetProperty("vector"), Assert.Single(store.Embeddings(nb, selected)).Vector.Values);
                        break;
                    default: throw new InvalidOperationException("Unknown model-switch event.");
                }
            }
            var expected = c.GetProperty("expected");
            Equal(expected.GetProperty("expectedCalls"), client.Models);
            Assert.Equal(expected.GetProperty("activeModelKey").GetString(), store.ActiveGeneration(nb)!.Identity.Model);
            Assert.Equal(expected.GetProperty("onlyBActive").GetBoolean(), store.ActiveGeneration(nb)!.Identity.Model == keys[1]);
            Assert.Equal(expected.GetProperty("activeCount").GetInt32(), Scalar<int>(store, "SELECT count(*) FROM index_generations WHERE state='active'"));
        }
        // Selection changes while the first provider is suspended must leave its completed work inactive.
        using var suspendedStore = new NotebookStore(StorePath.InMemory);
        long notebook = NewNotebook(suspendedStore);
        await new IngestionService(suspendedStore).IngestRawTextAsync("switch", "currentword", notebook);
        string selection = "provider-A:m";
        var barrier = new BarrierClient();
        var task = new Embedder(suspendedStore, barrier, () => selection).EmbedAllPendingAsync();
        var call = await barrier.Next();
        selection = "provider-B:m";
        call.Completion.SetResult([[1f, 0f]]);
        Assert.Equal(1, await task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal("provider-A:m", call.Model); Assert.Null(suspendedStore.ActiveGeneration(notebook));
        Assert.Equal("building", Scalar<string>(suspendedStore, "SELECT state FROM index_generations WHERE model='provider-A:m'"));
        Assert.Equal(1, await new Embedder(suspendedStore, new FixedClient(_ => [0f, 1f]), () => selection).EmbedAllPendingAsync());
        Assert.Equal("provider-B:m", suspendedStore.ActiveGeneration(notebook)!.Identity.Model);
    }

    [Fact]
    public async Task ReingestDuringEmbeddingDropsStaleBatch()
    {
        foreach (var c in Cases("reingest-during-embedding"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            ExpectedOps(c, "beginEmbedBatch", "publish", "resumeEmbedBatch", "reconcile");
            var events = c.GetProperty("events").EnumerateArray().ToArray();
            var client = new BarrierClient { OneCallOnly = true };
            var pending = new Embedder(store, client, "m").EmbedAllPendingAsync();
            var call = await client.Next();
            Assert.Equal("m", call.Model); Assert.Equal(new[] { "old" }, call.Inputs);
            Assert.Equal(c.GetProperty("capturedRevisionId").GetInt64(), events[0].GetProperty("revisionId").GetInt64());
            Equal(events[0].GetProperty("chunkIds"), store.UnembeddedChunks("m", 16).Select(ch => ch.Id!.Value).ToArray());
            var text = events[1].GetProperty("text").GetString()!;
            store.CommitForegroundRevision(events[1].GetProperty("sourceId").GetInt64(), new("new", text, 1, 2), ScalarChunker.Chunk(text),
                events[1].GetProperty("at").GetInt64(), events[1].GetProperty("token").GetString()!);
            var returned = store.Source(1)!;
            call.Completion.SetResult(events[2].GetProperty("vectors").EnumerateArray().Select(v => v.EnumerateArray().Select(x => x.GetSingle()).ToArray()).ToArray());
            Assert.Equal(0, await pending.WaitAsync(TimeSpan.FromSeconds(10)));
            store.ReconcileManifest(events[3].GetProperty("generationId").GetInt64());
            var expected = c.GetProperty("expected");
            Assert.Equal(expected.GetProperty("staleWrites").GetInt32(), Scalar<int>(store, "SELECT count(*) FROM chunk_embeddings WHERE generation_id=2 AND chunk_id=1001"));
            Assert.Equal(expected.GetProperty("activeId").GetInt64(), store.ActiveGeneration(1)!.Id);
            Assert.Equal(expected.GetProperty("pendingRevisionId").GetInt64(), Assert.Single(store.Manifest(2)).RevisionId);
            Assert.Equal("pending", Assert.Single(store.Manifest(2)).State);
            Assert.Equal(expected.GetProperty("publishedRevisionId").GetInt64(), returned.PublishedRevisionId);
            AssertPointers(expected.GetProperty("returnedSource"), returned);
        }
    }

    [Fact]
    public async Task ReindexKeepsActiveWhileWorkIsEmpty()
    {
        foreach (var c in Cases("reindex-keeps-active"))
        {
            using var store = new NotebookStore(StorePath.InMemory);
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            ExpectedOps(c, "deleteAllEmbeddings", "inspectWork", "drain");
            var events = c.GetProperty("events").EnumerateArray().ToArray();
            string key = c.GetProperty("modelKey").GetString()!;
            var pin = store.PinQuery(1, key);
            try
            {
                store.DeleteAllEmbeddings(events[0].GetProperty("modelKey").GetString()!);
                Equal(c.GetProperty("expected").GetProperty("afterRequest"), new
                {
                    activeId = store.ActiveGeneration(1)!.Id,
                    buildingId = Scalar<long>(store, "SELECT id FROM index_generations WHERE state='building'"),
                    buildingVectorCount = Scalar<int>(store, "SELECT count(*) FROM chunk_embeddings e JOIN index_generations g ON g.id=e.generation_id WHERE g.state='building'"),
                    workVectorCount = store.Embeddings(1, events[1].GetProperty("modelKey").GetString()!).Count
                });
                Assert.Single(store.PinnedEmbeddings(pin)); Assert.Equal(1, store.UnembeddedCount(key));
                var vector = events[2].GetProperty("vector").EnumerateArray().Select(v => v.GetSingle()).ToArray();
                Assert.Equal(1, await new Embedder(store, new FixedClient(_ => vector), events[2].GetProperty("modelKey").GetString()!).EmbedAllPendingAsync());
                Equal(c.GetProperty("expected").GetProperty("afterFill"), new { activeId = store.ActiveGeneration(1)!.Id, previousState = store.Generation(1)!.State, newState = store.Generation(2)!.State });
                Assert.Single(store.PinnedEmbeddings(pin));
            }
            finally { store.ReleaseQuery(pin); }
        }
    }

    [Fact]
    public async Task PinnedQuerySurvivesActivationAndGC()
    {
        foreach (string outcome in new[] { "success", "failure", "cancel" })
        {
            using var store = new NotebookStore(StorePath.InMemory);
            V19TestStore.Seed(store, Cases("restart")[0].GetProperty("setupSql"));
            string selected = "m";
            var client = new BarrierClient();
            using var cancellation = new CancellationTokenSource();
            var search = new Retriever(store, client, () => selected).SearchAsync(1, "old", ct: cancellation.Token);
            var call = await client.Next(); Assert.Equal("m", call.Model);
            store.CommitForegroundRevision(1, new("new", "new", 1, 2), [new("new", 1, null, 0, 3, null, false)], 1, "replacement");
            long newChunk = Assert.Single(store.Chunks(1)).Id!.Value;
            store.StoreEmbedding(newChunk, "m", new([0f, 1f]));
            selected = "changed-during-query";
            store.GarbageCollect(1);
            Assert.NotNull(store.Generation(1)); Assert.NotNull(store.Revision(101));
            if (outcome == "success")
            {
                call.Completion.SetResult([[1f, 0f]]);
                var hits = await search.WaitAsync(TimeSpan.FromSeconds(10));
                Assert.Equal(1001, Assert.Single(hits).ChunkId); Assert.Contains("old", hits[0].Snippet);
                Assert.Equal(1, client.Calls);
            }
            else if (outcome == "failure")
            {
                call.Completion.SetException(new InvalidOperationException("provider failed"));
                await Assert.ThrowsAsync<InvalidOperationException>(async () => await search.WaitAsync(TimeSpan.FromSeconds(10)));
            }
            else
            {
                cancellation.Cancel();
                await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await search.WaitAsync(TimeSpan.FromSeconds(10)));
            }
            store.GarbageCollect(1);
            Assert.Null(store.Generation(1)); Assert.Null(store.Revision(101));
            Assert.NotNull(store.Source(1)!.PublishedRevisionId);
        }
    }

    [Fact]
    public async Task ProductionUpgradeAndCitationReopen()
    {
        var upgrades = SharedFixtures.Json("contracts/storage-v19.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.NotEmpty(upgrades);
        foreach (var c in upgrades)
        {
            string directory = TempDirectory(), path = Path.Combine(directory, "db.sqlite");
            File.Copy(SharedFixtures.Path("storage/v18.sqlite"), path);
            string? key = c.GetProperty("configuredModelKey").GetString();
            NotebookStore? store = null;
            try
            {
                store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: key);
                V19TestStore.AssertQueries(store, c.GetProperty("queries"));
                string legacyJson = Scalar<string>(store, "SELECT citations_json FROM messages WHERE id=41");
                var legacy = Assert.Single(store.Messages(31).Single(m => m.Id == 41).Citations); Assert.False(legacy.IsV2);
                store.Dispose(); store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: key);
                V19TestStore.AssertQueries(store, c.GetProperty("queries"));
                Assert.Equal(legacyJson, Scalar<string>(store, "SELECT citations_json FROM messages WHERE id=41"));
                long notebook = NewNotebook(store);
                var source = await new IngestionService(store).IngestRawTextAsync("import", "evidenceword", notebook);
                AssertFreshSource(store, source);
                await new Embedder(store, new FixedClient(_ => [1f, 0f]), "integration-model").EmbedAllPendingAsync();
                var hit = Assert.Single(await new Retriever(store, new FixedClient(_ => [1f, 0f]), "integration-model").SearchAsync(notebook, "evidenceword"));
                var session = store.CreateChatSession(notebook, "saved");
                var chunk = Assert.Single(store.Chunks(source.Id!.Value));
                var citation = new Citation(1, hit.ChunkId, hit.SourceId, "evidenceword") { Text = "evidenceword", RevisionId = chunk.RevisionId,
                    ChunkIds = [hit.ChunkId], Spans = [new(chunk.CharStart!.Value, chunk.CharEnd!.Value, null, null)] };
                store.AppendMessage(new(null, session.Id!.Value, ChatRole.Assistant, "answer", [citation], DateTime.UtcNow));
                store.DeleteSource(source.Id.Value); store.GarbageCollect(notebook);
                store.Dispose(); store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: key);
                Assert.Null(store.Source(source.Id.Value));
                var saved = Assert.Single(Assert.Single(store.Messages(session.Id.Value)).Citations);
                Assert.True(saved.IsV2); Assert.Equal(citation.Text, saved.Text); Assert.Equal(citation.Spans, saved.Spans);
                Assert.Equal(citation.RevisionId, saved.RevisionId); Assert.Equal(citation.ChunkIds, saved.ChunkIds);
                Assert.Equal(legacyJson, Scalar<string>(store, "SELECT citations_json FROM messages WHERE id=41"));
                lock (store.Gate) Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
            }
            finally { store?.Dispose(); Directory.Delete(directory, true); }
        }
        RunRestartAndCitationFixtures();
    }

    private static void RunRestartAndCitationFixtures()
    {
        var restart = Cases("restart")[0];
        var citationCase = Cases("citation-after-gc")[0];
        string directory = TempDirectory(), path = Path.Combine(directory, "db.sqlite");
        NotebookStore store = new(new StorePath(path));
        try
        {
            V19TestStore.Seed(store, restart.GetProperty("setupSql"));
            int captured = 0;
            foreach (var e in restart.GetProperty("events").EnumerateArray())
            {
                switch (e.GetProperty("op").GetString())
                {
                    case "capturePointers":
                        Equal(restart.GetProperty("expected").GetProperty(captured++ == 0 ? "before" : "after"),
                            new { store.Source(1)!.CurrentRevision, store.Source(1)!.PublishedRevisionId, activeId = store.ActiveGeneration(1)!.Id }); break;
                    case "close": store.Dispose(); break;
                    case "reopen": store = new(new StorePath(path)); break;
                    default: throw new InvalidOperationException("Unknown restart fixture event.");
                }
            }
            Assert.Equal(2, captured);
            var citation = Assert.Single(CitationsCodec.Decode("[" + citationCase.GetProperty("citation").GetRawText() + "]"));
            Assert.Equal(2, citationCase.GetProperty("citationVersion").GetInt32()); Assert.True(citation.IsV2);
            Assert.Equal(citationCase.GetProperty("revisionId").GetInt64(), citation.RevisionId);
            Assert.Equal(citationCase.GetProperty("sourceId").GetInt64(), citation.SourceId);
            Assert.Equal(citationCase.GetProperty("chunkId").GetInt64(), citation.ChunkId);
            long session = store.CreateChatSession(1, "snapshot").Id!.Value;
            foreach (var e in citationCase.GetProperty("events").EnumerateArray())
            {
                switch (e.GetProperty("op").GetString())
                {
                    case "persistCitation": store.AppendMessage(new(null, session, ChatRole.Assistant, "saved", [citation], DateTime.UtcNow)); break;
                    case "deleteSource": store.DeleteSource(e.GetProperty("sourceId").GetInt64()); break;
                    case "garbageCollect": store.GarbageCollect(e.GetProperty("notebookId").GetInt64()); break;
                    case "reopen": store.Dispose(); store = new(new StorePath(path)); break;
                    case "readCitation":
                        var saved = Assert.Single(Assert.Single(store.Messages(session)).Citations);
                        Assert.Equal(citationCase.GetProperty("expected").GetProperty("text").GetString(), saved.Text);
                        Assert.Equal(citation.Spans, saved.Spans); Assert.Equal(citation.RevisionId, saved.RevisionId); Assert.Equal(citation.ChunkIds, saved.ChunkIds);
                        break;
                    default: throw new InvalidOperationException("Unknown citation fixture event.");
                }
            }
            Assert.Equal(citationCase.GetProperty("expected").GetProperty("sourceExists").GetBoolean(), store.Source(citation.SourceId) is not null);
        }
        finally { store.Dispose(); Directory.Delete(directory, true); }
    }

    private static RevisionDraft RevisionDraftFrom(JsonElement value) => new(value.GetProperty("contentHash").GetString()!, value.GetProperty("canonicalText").GetString()!,
        value.GetProperty("textFormatVersion").GetInt32(), value.GetProperty("chunkerVersion").GetInt32());
    private static RevisionChunkDraft[] RevisionChunksFrom(JsonElement value) => value.EnumerateArray().Select(c => new RevisionChunkDraft(c.GetProperty("text").GetString()!,
        c.GetProperty("tokenCount").GetInt32(), OptionalInt(c.GetProperty("pageHint")), OptionalInt(c.GetProperty("charStart")), OptionalInt(c.GetProperty("charEnd")),
        c.GetProperty("lang").GetString(), c.GetProperty("langInherited").GetBoolean())).ToArray();
    private static int? OptionalInt(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt32();

    private static void RunExtractionFixture(JsonElement c)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        V19TestStore.Seed(store, c.GetProperty("setupSql"));
        long source = c.GetProperty("sourceId").GetInt64();
        var fences = new Dictionary<string, JobFence>();
        var results = new Dictionary<string, SourceRevision?>();
        long? leaseBefore = null;
        var events = c.GetProperty("events").EnumerateArray().ToArray();
        var snapshots = c.GetProperty("expected").GetProperty("snapshots").EnumerateArray().ToArray();
        Assert.NotEmpty(events); Assert.Equal(events.Length, snapshots.Length);
        for (int i = 0; i < events.Length; i++)
        {
            var e = events[i];
            string token = e.GetProperty("token").GetString()!; long at = e.GetProperty("at").GetInt64();
            object? result;
            switch (e.GetProperty("op").GetString())
            {
                case "begin": fences[token] = store.BeginExtraction(source, at, token); result = true; break;
                case "renew": result = store.RenewJob(fences[token], at); break;
                case "commit":
                    leaseBefore = store.Job(fences[token].JobId)!.LeaseUntil;
                    results[token] = store.CommitExtraction(source, RevisionDraftFrom(e.GetProperty("draft")), RevisionChunksFrom(e.GetProperty("chunks")), fences[token], at);
                    result = results[token]?.Id; break;
                default: throw new InvalidOperationException("Unknown extraction fixture event.");
            }
            AssertExtractionProjection(store, snapshots[i], source, fences, results, fences[token].JobId, result, leaseBefore);
        }
        var final = c.GetProperty("expected");
        AssertExtractionProjection(store, final, source, fences, results, fences.Values.Last().JobId, null, leaseBefore);
        if (c.TryGetProperty("withoutRenewal", out var without))
        {
            using var other = new NotebookStore(StorePath.InMemory); V19TestStore.Seed(other, c.GetProperty("setupSql"));
            var begin = events[0]; var commit = events.Last();
            var fence = other.BeginExtraction(source, begin.GetProperty("at").GetInt64(), begin.GetProperty("token").GetString()!);
            var result = other.CommitExtraction(source, RevisionDraftFrom(commit.GetProperty("draft")), RevisionChunksFrom(commit.GetProperty("chunks")), fence, without.GetProperty("commitAt").GetInt64());
            Equal(without.GetProperty("result"), result?.Id);
            Equal(without.GetProperty("newRevisionCount"), Scalar<int>(other, "SELECT count(*) FROM source_revisions WHERE id<>101"));
            Equal(without.GetProperty("publishedRevisionId"), other.Source(source)!.PublishedRevisionId);
        }
    }

    private static void AssertExtractionProjection(NotebookStore store, JsonElement expected, long source, Dictionary<string, JobFence> fences,
        Dictionary<string, SourceRevision?> results, long jobId, object? result, long? leaseBefore)
    {
        var job = store.Job(jobId)!;
        foreach (var p in expected.EnumerateObject())
        {
            if (p.Name == "snapshots") continue; // Every snapshot is asserted immediately after its event.
            if (p.Name == "returnedSource") { AssertPointers(p.Value, store.Source(source)!); continue; }
            object? actual = p.Name switch
            {
                "currentRevision" => store.Source(source)!.CurrentRevision, "publishedRevisionId" => store.Source(source)!.PublishedRevisionId,
                "result" => result, "resultA" => results["A"]?.Id, "resultB" => results["B"]?.Id,
                "revisionId" => results.Values.Last(v => v is not null)!.Id,
                "publishedText" => store.Revision(store.Source(source)!.PublishedRevisionId!.Value)!.Draft.CanonicalText,
                "newRevisionCount" => Scalar<int>(store, "SELECT count(*) FROM source_revisions WHERE source_id=$source AND id<>101", new { source }),
                "jobStates" => fences.ToDictionary(kv => kv.Key, kv => store.Job(kv.Value.JobId)!.State),
                "state" or "jobState" => job.State, "attempts" => job.Attempts, "nextRetryAt" => job.NextRetryAt, "leaseUntil" => job.LeaseUntil,
                "leaseToken" => job.LeaseToken, "leaseUntilBeforeCommit" => leaseBefore,
                _ => throw new InvalidOperationException($"Unknown extraction projection {p.Name}.")
            };
            Equal(p.Value, actual);
        }
    }

    private static async Task RunAsynchronousExtraction(JsonElement c)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        V19TestStore.Seed(store, c.GetProperty("setupSql"));
        long source = c.GetProperty("sourceId").GetInt64();
        lock (store.Gate) store.Connection.Execute("UPDATE sources SET raw_path=$path WHERE id=$source", new { source, path = Path.Combine(Path.GetTempPath(), "fixture.txt") });
        var extractor = new BarrierExtractor(); var clock = new ManualClock(); int notifications = 0;
        var service = new IngestionService(store, plain: extractor, onChunksWritten: () => { Interlocked.Increment(ref notifications); return Task.CompletedTask; }, leaseClock: clock);
        var events = c.GetProperty("events").EnumerateArray().ToArray();
        var first = service.ReIngestAsync(source); var firstExtraction = await extractor.Next();
        await clock.WaitForRequest(60);
        if (c.GetProperty("name").GetString() == "superseded-extraction")
        {
            clock.Set(events[1].GetProperty("at").GetInt64());
            var second = service.ReIngestAsync(source); var secondExtraction = await extractor.Next();
            clock.Set(events[2].GetProperty("at").GetInt64());
            secondExtraction.SetResult(new("fixture", events[2].GetProperty("draft").GetProperty("canonicalText").GetString()!));
            var returnedB = await second.WaitAsync(TimeSpan.FromSeconds(10));
            clock.Set(events[3].GetProperty("at").GetInt64());
            firstExtraction.SetResult(new("fixture", events[3].GetProperty("draft").GetProperty("canonicalText").GetString()!));
            var returnedA = await first.WaitAsync(TimeSpan.FromSeconds(10));
            AssertPointers(c.GetProperty("expected").GetProperty("returnedSource"), returnedA);
            AssertPointers(c.GetProperty("expected").GetProperty("returnedSource"), returnedB);
            Assert.Equal(c.GetProperty("expected").GetProperty("publishedText").GetString(), store.Revision(returnedB.PublishedRevisionId!.Value)!.Draft.CanonicalText);
            Assert.Equal(c.GetProperty("expected").GetProperty("newRevisionCount").GetInt32(), Scalar<int>(store, "SELECT count(*) FROM source_revisions WHERE id<>101"));
            Assert.Equal("cancelled", store.Job(1)!.State); Assert.Equal("done", store.Job(2)!.State);
        }
        else
        {
            clock.Set(events[1].GetProperty("at").GetInt64());
            await clock.WaitForRequest(120);
            Assert.Equal(c.GetProperty("expected").GetProperty("leaseUntilBeforeCommit").GetInt64(), store.Job(1)!.LeaseUntil);
            Assert.Equal(c.GetProperty("expected").GetProperty("attempts").GetInt32(), store.Job(1)!.Attempts);
            clock.Set(events[2].GetProperty("at").GetInt64(), wake: false);
            firstExtraction.SetResult(new("fixture", events[2].GetProperty("draft").GetProperty("canonicalText").GetString()!));
            var returned = await first.WaitAsync(TimeSpan.FromSeconds(10));
            AssertPointers(c.GetProperty("expected").GetProperty("returnedSource"), returned);
            Assert.Equal("done", store.Job(1)!.State);
        }
        Assert.Equal(1, notifications);
        AssertFreshSource(store, store.Source(source)!);
    }
}
