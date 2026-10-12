using System.Text;
using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class EvidenceHydratorTests
{
    [Fact]
    public void ScalarEvidenceFixture()
    {
        var f = SharedFixtures.Json("contracts/retrieval-evidence-v1.json");
        int executed = 0;
        foreach (var c in f.GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("row", out var r)) continue;
            executed++;
            int? Optional(string key) => r.TryGetProperty(key, out var x) && x.ValueKind != JsonValueKind.Null ? x.GetInt32() : null;
            var row = new ChunkEvidenceRow(new(1020, 1, 102, 0),
                r.TryGetProperty("canonicalText", out var text) ? text.GetString()! : f.GetProperty("canonicalText").GetString()!,
                r.GetProperty("chunkText").GetString()!, Optional("start"), Optional("end"), Optional("pageHint"), r.GetProperty("chunkerVersion").GetInt32());
            if (c.TryGetProperty("expectedError", out var error))
                Assert.Equal(error.GetString(), Assert.Throws<RetrievalException>(() => EvidenceHydrator.Passage(row, false)).Code);
            else
            {
                var evidence = EvidenceHydrator.Passage(row, false);
                Assert.Equal(c.GetProperty("expectedText").GetString(), evidence.Text);
                Assert.Equal(c.GetProperty("expectedSnippet").GetString(), evidence.DisplaySnippet);
                Assert.Equal(c.GetProperty("expectedSpans").EnumerateArray().Select(s => (s.GetProperty("start").GetInt64(), s.GetProperty("end").GetInt64())),
                    evidence.Spans.Select(s => (s.Start, s.End)));
                Assert.False(evidence.IsNeighbour);
                if (c.GetProperty("name").GetString() == "snippet")
                {
                    Assert.Equal(241, evidence.Text.EnumerateRunes().Count());
                    Assert.Equal(240, evidence.DisplaySnippet.EnumerateRunes().Count());
                }
            }
        }
        Assert.Equal(5, executed);
    }

    [Fact]
    public void PublishedNeighboursRetainTheirOwnRevision()
    {
        foreach (string name in new[] { "published-neighbours", "old-vector" })
        {
            var c = Case(name);
            using var store = EvidenceStore();
            using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
            var center = Reference(c.GetProperty("reference"));
            var passages = new EvidenceHydrator(store.MakeRetrievalReader()).Hydrate(snapshot, new[] { center }, c.GetProperty("radius").GetInt32());
            var expected = new List<(long, long, bool)> { (center.ChunkId, center.RevisionId, false) };
            expected.AddRange(c.GetProperty("expectedNeighbours").EnumerateArray().Select(n =>
                (n.GetProperty("chunkId").GetInt64(), n.GetProperty("revisionId").GetInt64(), true)));
            Assert.Equal(expected, passages.Select(p => (p.Reference.ChunkId, p.Reference.RevisionId, p.IsNeighbour)));
            // A neighbour of an old vector hit carries the published revision, never the hit's revision.
            if (c.TryGetProperty("publishedRevisionId", out var published))
                Assert.All(passages.Where(p => p.IsNeighbour), p => Assert.Equal(published.GetInt64(), p.Reference.RevisionId));
            var chunks = SharedFixtures.Json("contracts/retrieval-evidence-v1.json").GetProperty("chunks").EnumerateArray()
                .ToDictionary(x => x.GetProperty("chunkId").GetInt64(), x => x.GetProperty("chunkText").GetString());
            foreach (var passage in passages.Where(p => p.Reference.RevisionId == 102))
                Assert.Equal(chunks[passage.Reference.ChunkId], passage.Text);
        }
    }

    [Fact]
    public void DirectHitsAreNotRepeatedAsNeighbours()
    {
        using var store = EvidenceStore();
        using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        var hydrator = new EvidenceHydrator(store.MakeRetrievalReader());
        var passages = hydrator.Hydrate(snapshot, new ChunkReference[] { new(1022, 1, 102, 2), new(1021, 1, 102, 1), new(1022, 1, 102, 2) });
        Assert.Equal(new[] { (1022L, false), (1021L, false), (1020L, true) },
            passages.Select(p => (p.Reference.ChunkId, p.IsNeighbour)));
        Assert.Empty(hydrator.Hydrate(snapshot, Array.Empty<ChunkReference>()));
        Assert.Equal(new[] { 1021L }, hydrator.Hydrate(snapshot, new ChunkReference[] { new(1021, 1, 102, 1) }, 0).Select(p => p.Reference.ChunkId));
        Assert.Equal("invalidRadius", Assert.Throws<RetrievalException>(() =>
            hydrator.Hydrate(snapshot, new ChunkReference[] { new(1021, 1, 102, 1) }, -1)).Code);
    }

    [Fact]
    public void WrongRevisionFails()
    {
        var c = Case("wrong-revision");
        using var store = EvidenceStore();
        using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        var hydrator = new EvidenceHydrator(store.MakeRetrievalReader());
        // Validation covers every identity before any partial result is returned.
        var error = Assert.Throws<RetrievalException>(() => hydrator.Hydrate(snapshot,
            new[] { new ChunkReference(1021, 1, 102, 1), Reference(c.GetProperty("reference")) }));
        Assert.Equal(c.GetProperty("expectedError").GetString(), error.Code);
        Assert.Equal("revisionMismatch", Assert.Throws<RetrievalException>(() => hydrator.Hydrate(snapshot,
            new ChunkReference[] { new(1021, 1, 102, 1), new(1021, 1, 101, 1) })).Code);
    }

    [Fact]
    public void RevokedSourceReturnsNoEvidence()
    {
        var c = Case("revoked");
        using var store = EvidenceStore();
        using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        lock (store.Gate)
            foreach (var e in c.GetProperty("events").EnumerateArray())
            {
                Assert.Equal("setAvailability", e.GetProperty("kind").GetString());
                store.Connection.Execute("UPDATE sources SET availability=$value WHERE id=$source",
                    new { value = e.GetProperty("value").GetString(), source = e.GetProperty("sourceId").GetInt64() });
            }
        var passages = new EvidenceHydrator(store.MakeRetrievalReader()).Hydrate(snapshot, new[] { Reference(c.GetProperty("reference")) });
        Assert.Equal(c.GetProperty("expectedPassages").GetArrayLength(), passages.Count);
        Assert.Empty(passages);
    }

    [Fact]
    public void QueryPinProtectsRetiredEvidenceUntilDispose()
    {
        var c = Case("gc-pin");
        var reference = Reference(c.GetProperty("reference"));
        using var store = RetrievalFixtureStore.Create();
        var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        Assert.Equal(c.GetProperty("publishedRevisionId").GetInt64(), snapshot.Pin.LexicalRevisions[reference.SourceId]);
        store.RetireGeneration(c.GetProperty("retireGenerationId").GetInt64());
        store.GarbageCollect(1);
        AssertIds(store, "source_chunks", "id", c, "retainedChunkIds", present: true);
        AssertIds(store, "source_revisions", "id", c, "retainedRevisionIds", present: true);
        var passages = new EvidenceHydrator(store.MakeRetrievalReader()).Hydrate(snapshot, new[] { reference }, 0);
        Assert.Equal(new[] { c.GetProperty("expectedText").GetString() }, passages.Select(p => p.Text));
        snapshot.Dispose();
        store.GarbageCollect(1);
        AssertGcPinCollected(store, c);
    }

    [Fact]
    public async Task DisposeDuringHydrationKeepsOperationBorrow()
    {
        var c = Case("gc-pin");
        var reference = Reference(c.GetProperty("reference"));
        string directory = Path.Combine(Path.GetTempPath(), "wp5-evidence-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            using var first = V19TestStore.Reopen(directory);
            RetrievalFixtureStore.Seed(first);
            using var second = V19TestStore.Reopen(directory);
            var snapshot = ScopeResolver.Resolve(first, 1, new RetrievalScope.All(), "m")!;
            var reader = first.MakeRetrievalReader();
            var borrowed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var resume = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            int reads = 0;
            reader.BeforeEvidenceRead = () =>
            {
                if (Interlocked.Increment(ref reads) != 1) return;
                borrowed.TrySetResult();
                Assert.True(resume.Task.Wait(TimeSpan.FromSeconds(15)));
            };
            var hydration = Task.Run(() => new EvidenceHydrator(reader).Hydrate(snapshot, new[] { reference }));
            await borrowed.Task.WaitAsync(TimeSpan.FromSeconds(15));
            snapshot.Dispose();
            Assert.Throws<RetrievalException>(() => snapshot.AcquireOperation());
            second.RetireGeneration(c.GetProperty("retireGenerationId").GetInt64());
            second.GarbageCollect(1);
            AssertIds(second, "source_revisions", "id", c, "retainedRevisionIds", present: true);
            AssertIds(second, "source_chunks", "id", c, "retainedChunkIds", present: true);
            resume.SetResult();
            var passages = await hydration.WaitAsync(TimeSpan.FromSeconds(15));
            Assert.Equal(c.GetProperty("expectedText").GetString(), passages.First(p => !p.IsNeighbour).Text);
            second.GarbageCollect(1);
            AssertGcPinCollected(second, c);
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    private static void AssertGcPinCollected(NotebookStore store, JsonElement c)
    {
        lock (store.Gate)
        {
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=$id",
                new { id = c.GetProperty("deletedGenerationId").GetInt64() }));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=$id",
                new { id = c.GetProperty("deletedRevisionId").GetInt64() }));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_chunks WHERE id=$id",
                new { id = c.GetProperty("deletedChunkId").GetInt64() }));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM chunk_embeddings WHERE chunk_id=$id",
                new { id = c.GetProperty("deletedVectorChunkId").GetInt64() }));
        }
        AssertIds(store, "source_chunks", "id", c, "survivingChunkIds", present: true);
        AssertIds(store, "source_revisions", "id", c, "survivingRevisionIds", present: true);
        lock (store.Gate)
            Assert.Equal(c.GetProperty("currentRevisionId").GetInt64(),
                store.Connection.ExecuteScalar<long>("SELECT published_revision_id FROM sources WHERE id=1"));
    }

    private static void AssertIds(NotebookStore store, string table, string column, JsonElement c, string key, bool present)
    {
        lock (store.Gate)
            foreach (var id in c.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()))
                Assert.Equal(present ? 1 : 0, store.Connection.ExecuteScalar<int>(
                    $"SELECT count(*) FROM {table} WHERE {column}=$id", new { id }));
    }

    private static JsonElement Case(string name) => SharedFixtures.Json("contracts/retrieval-evidence-v1.json")
        .GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name);

    private static ChunkReference Reference(JsonElement r) => new(r.GetProperty("chunkId").GetInt64(),
        r.GetProperty("sourceId").GetInt64(), r.GetProperty("revisionId").GetInt64(), r.GetProperty("ord").GetInt32());

    /// <summary>
    /// The shared scope seed, with published revision 102 rewritten to the shared
    /// evidence revision: canonical scalar text plus its three offset chunks.
    /// </summary>
    private static NotebookStore EvidenceStore()
    {
        var f = SharedFixtures.Json("contracts/retrieval-evidence-v1.json");
        var store = RetrievalFixtureStore.Create();
        try
        {
            lock (store.Gate)
            {
                using var tx = store.Connection.BeginTransaction();
                long revision = f.GetProperty("revisionId").GetInt64(), source = f.GetProperty("sourceId").GetInt64();
                // Revisions are immutable: replace the seed revision wholesale, then
                // restore the source pointers and the retired generation's manifest row.
                var original = store.Connection.QuerySingle(
                    "SELECT revision,content_hash,created_at FROM source_revisions WHERE id=$revision", new { revision }, tx);
                var manifest = store.Connection.Query(
                    "SELECT generation_id,state FROM index_generation_manifest WHERE revision_id=$revision", new { revision }, tx).ToArray();
                store.Connection.Execute("UPDATE sources SET current_revision=NULL,published_revision_id=NULL WHERE id=$source", new { source }, tx);
                store.Connection.Execute("DELETE FROM index_generation_manifest WHERE revision_id=$revision", new { revision }, tx);
                store.Connection.Execute("DELETE FROM source_chunks WHERE revision_id=$revision", new { revision }, tx);
                store.Connection.Execute("DELETE FROM source_revisions WHERE id=$revision", new { revision }, tx);
                store.Connection.Execute("""
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES($revision,$source,$ordinal,$hash,$text,1,2,$created)
                    """, new { revision, source, ordinal = (long)original.revision, hash = (string)original.content_hash,
                    text = f.GetProperty("canonicalText").GetString(), created = (string)original.created_at }, tx);
                foreach (var chunk in f.GetProperty("chunks").EnumerateArray())
                {
                    Assert.Equal(revision, chunk.GetProperty("revisionId").GetInt64());
                    store.Connection.Execute("""
                        INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end)
                        VALUES($id,$source,$revision,$ord,$text,4,$start,$end)
                        """, new
                    {
                        id = chunk.GetProperty("chunkId").GetInt64(), source = chunk.GetProperty("sourceId").GetInt64(), revision,
                        ord = chunk.GetProperty("ord").GetInt32(), text = chunk.GetProperty("chunkText").GetString(),
                        start = chunk.GetProperty("start").GetInt32(), end = chunk.GetProperty("end").GetInt32(),
                    }, tx);
                }
                foreach (var row in manifest)
                    store.Connection.Execute("""
                        INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES($generation,$source,$revision,$state)
                        """, new { generation = (long)row.generation_id, source, revision, state = (string)row.state }, tx);
                store.Connection.Execute("UPDATE sources SET current_revision=$revision,published_revision_id=$revision WHERE id=$source",
                    new { source, revision }, tx);
                tx.Commit();
            }
            return store;
        }
        catch { store.Dispose(); throw; }
    }
}
