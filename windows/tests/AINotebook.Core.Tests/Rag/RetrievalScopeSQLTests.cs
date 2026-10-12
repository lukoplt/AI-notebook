using System.Text.Json;
using Dapper;
using AINotebook.Core.Storage;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;
using Microsoft.Data.Sqlite;
namespace AINotebook.Core.Tests.Rag;

public sealed class RetrievalScopeSQLTests
{
    [Fact]
    public void AllSharedScopesAndRevisionRules()
    {
        foreach (var c in RetrievalFixtureStore.Cases().Where(c => !c.TryGetProperty("events", out _)))
        {
            using var store = RetrievalFixtureStore.Create(c.GetProperty("name").GetString()!);
            var scope = RetrievalScopeJson.Deserialize(c.GetProperty("scope").GetRawText());
            using var snapshot = ScopeResolver.Resolve(store, c.GetProperty("notebookId").GetInt64(), scope, "m");
            if (scope.IsEmptySelection)
            {
                Assert.Null(snapshot);
                Assert.Equal(0, RetrievalFixtureStore.SqlStatementCount(store));
                lock (store.Gate)
                {
                    using var registry = GenerationPinRegistry.Acquire(store.RetrievalDatabaseId);
                    Assert.Empty(registry.Pins);
                }
                continue;
            }
            Assert.NotNull(snapshot);
            var reader = store.MakeRetrievalReader();
            var lexical = reader.Lexical(snapshot, "\"needle\"", 32);
            var vector = new List<long>();
            long after = 0;
            while (true)
            {
                var page = reader.VectorPage(snapshot, after, 1);
                if (page.Count == 0) break;
                after = page[^1].Reference.ChunkId;
                vector.AddRange(page.Select(x => x.Reference.ChunkId));
            }
            Assert.Equal(c.GetProperty("publishedChunkIds").EnumerateArray().Select(x => x.GetInt64()), lexical.Select(x => x.ChunkId).Order());
            Assert.Equal(c.GetProperty("vectorChunkIds").EnumerateArray().Select(x => x.GetInt64()), vector.Order());
        }
    }
    /// <summary>The lexical branch ranks a bounded bm25 window before filtering; when the filters
    /// leave fewer than limit rows it widens the window, so out-of-scope matches that rank first
    /// can never hide in-scope ones (same rows and order as an unbounded MATCH).</summary>
    [Fact]
    public void LexicalWindowWidensPastOutOfScopeMatches()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long notebookId = store.CreateNotebook("w", "").Id!.Value;
        int outside = RetrievalReadStore.LexicalWindow(4) + 40;
        long inside = 0;
        var insideChunks = new List<long>();
        lock (store.Gate)
        {
            var sources = new List<long>();
            foreach (var (index, count) in new[] { (0, outside), (1, 3) })
            {
                long source = store.Connection.ExecuteScalar<long>(
                    "INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES (@nb,'text',@t,'ready','2026-10-11 00:00:00.000') RETURNING id",
                    new { nb = notebookId, t = "s" + index });
                long revision = store.Connection.ExecuteScalar<long>("""
                    INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES (@s,1,@h,'',1,2,'2026-10-11 00:00:00.000') RETURNING id
                    """, new { s = source, h = "h" + source });
                store.Connection.Execute("UPDATE sources SET current_revision=@r,published_revision_id=@r WHERE id=@s", new { r = revision, s = source });
                for (int ord = 0; ord < count; ord++)
                    store.Connection.Execute("INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id) VALUES (@s,@o,'needle hay stack',3,@r)",
                        new { s = source, o = ord, r = revision });
                sources.Add(source);
            }
            inside = sources[1];
            insideChunks.AddRange(store.Connection.Query<long>("SELECT id FROM source_chunks WHERE source_id=@s ORDER BY id", new { s = inside }));
        }
        using var snapshot = ScopeResolver.Resolve(store, notebookId,
            new RetrievalScope.Selection(new HashSet<long> { inside }, new HashSet<long>()), "m")!;
        var lexical = store.MakeRetrievalReader().Lexical(snapshot, "\"needle\"", 4);
        Assert.Equal(insideChunks, lexical.Select(x => x.ChunkId));
    }

[Fact]
public void OperationBorrowSurvivesOwnerDispose()
{
    var c=SharedFixtures.Json("contracts/retrieval-evidence-v1.json").GetProperty("cases").EnumerateArray()
        .Single(x=>x.GetProperty("name").GetString()=="gc-pin");
    var r=c.GetProperty("reference");
    var reference=new ChunkReference(r.GetProperty("chunkId").GetInt64(),r.GetProperty("sourceId").GetInt64(),
        r.GetProperty("revisionId").GetInt64(),r.GetProperty("ord").GetInt32());
    using var store=RetrievalFixtureStore.Create();
    var snapshot=ScopeResolver.Resolve(store,1,new RetrievalScope.All(),"m")!;
    using var operation=snapshot.AcquireOperation();
    snapshot.Dispose();
    Assert.Throws<RetrievalException>(()=>snapshot.AcquireOperation());
    store.RetireGeneration(c.GetProperty("retireGenerationId").GetInt64());
    store.GarbageCollect(1);
    var rows=store.MakeRetrievalReader().EvidenceRows(operation,new[] {reference});
    Assert.Equal(new[] {c.GetProperty("expectedText").GetString()},rows.Select(x=>x.ChunkText));
    operation.Dispose();
    store.GarbageCollect(1);
    lock(store.Gate)
        Assert.Equal(0,store.Connection.ExecuteScalar<int>(
            "SELECT count(*) FROM source_revisions WHERE id=$id",new {id=reference.RevisionId}));
}

    [Fact]
    public void RevocationsAndPublication()
    {
        var cases = RetrievalFixtureStore.Cases().Where(c => c.TryGetProperty("events", out _)).ToArray();
        Assert.Equal(6, cases.Length);
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            using var store = RetrievalFixtureStore.Create(name);
            var scope = RetrievalScopeJson.Deserialize(c.GetProperty("scope").GetRawText());
            using var snapshot = ScopeResolver.Resolve(store, c.GetProperty("notebookId").GetInt64(), scope, "m")!;
            var reader = store.MakeRetrievalReader();
            AssertArrays("publishedChunkIds", "vectorChunkIds");
            var initialSources = reader.PermittedSourceIds(snapshot).Order().ToArray();
            Assert.Equal(snapshot.Sources.Select(s => s.SourceId).Order(), initialSources);
            if (scope is RetrievalScope.All)
                Assert.Contains(6, initialSources); // No published revision is still in scope.
            RetrievalFixtureStore.ApplyEvent(name, store);
            AssertArrays("afterPublishedChunkIds", "afterVectorChunkIds");
            var expectedSources = initialSources.Where(id => c.GetProperty("events").EnumerateArray().All(e =>
                !((e.GetProperty("kind").GetString() is "setAvailability" or "setEligible") && e.GetProperty("sourceId").GetInt64() == id)
                && !(e.GetProperty("kind").GetString() == "setFolder" && scope is RetrievalScope.Selection selected
                    && e.GetProperty("sourceId").GetInt64() == id && !selected.SourceIds.Contains(id)
                    && !selected.FolderIds.Contains(e.GetProperty("folderId").GetInt64())))).ToArray();
            Assert.Equal(expectedSources, reader.PermittedSourceIds(snapshot).Order());
            Assert.Equal(expectedSources.Where(id => snapshot.Sources.Single(s => s.SourceId == id).PublishedRevisionId is not null),
                reader.Metadata(snapshot).Select(s => s.SourceId).Order());
            foreach (var reference in reader.Lexical(snapshot, "\"needle\"", 32))
                Assert.Equal(reference.RevisionId, Assert.Single(reader.EvidenceRows(snapshot, [reference])).Reference.RevisionId);
            continue;

            void AssertArrays(string lexicalKey, string vectorKey)
            {
                Assert.Equal(c.GetProperty(lexicalKey).EnumerateArray().Select(x => x.GetInt64()),
                    reader.Lexical(snapshot, "\"needle\"", 32).Select(x => x.ChunkId).Order());
                Assert.Equal(c.GetProperty(vectorKey).EnumerateArray().Select(x => x.GetInt64()),
                    reader.VectorPage(snapshot, 0, 32).Select(x => x.Reference.ChunkId).Order());
            }
        }
        using (var store = RetrievalFixtureStore.Create())
        using (var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!)
        {
            int permittedQueries = 0;
            var trace = store.RetrievalStatementExecuted;
            store.RetrievalStatementExecuted = sql =>
            {
                trace?.Invoke(sql);
                if (sql.StartsWith("SELECT s.id FROM sources s WHERE ", StringComparison.Ordinal)
                    && ++permittedQueries == 2)
                    RetrievalFixtureStore.ApplyEvent("revoke-eligible", store);
            };
            var page = store.MakeRetrievalReader().VectorPage(snapshot, 0, 1);
            Assert.Equal(4010, Assert.Single(page).Reference.ChunkId);
            Assert.True(permittedQueries >= 3, "A revoked first row must refill the page before returning");
        }
    }

    [Fact]
    public void EpochObservesAllMutationTablesAndRollback()
    {
        using var store = RetrievalFixtureStore.Create();
        var reader = store.MakeRetrievalReader();
        const string time = "2026-01-01 00:00:00.000";
        var mutations = new (string Table, string? Setup, string Insert, string? Update, string Delete)[]
        {
            ("notebooks", null, "INSERT INTO notebooks(id,name,created_at,updated_at) VALUES(9000,'epoch',$time,$time)",
                "UPDATE notebooks SET name='changed' WHERE id=9000", "DELETE FROM notebooks WHERE id=9000"),
            ("sources", null, "INSERT INTO sources(id,notebook_id,type,title,status,ingested_at) VALUES(9000,1,'text','epoch','ready',$time)",
                "UPDATE sources SET eligible=0 WHERE id=9000", "DELETE FROM sources WHERE id=9000"),
            ("source_revisions", null, "INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at) VALUES(9000,4,99,'epoch','needle epoch',1,1,$time)",
                null, "DELETE FROM source_revisions WHERE id=9000"),
            ("source_chunks", null, "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES(9000,4,401,99,'needle epoch',2)",
                "UPDATE source_chunks SET context='changed' WHERE id=9000", "DELETE FROM source_chunks WHERE id=9000"),
            ("chunk_embeddings", "INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES(9000,1,102,1,'needle epoch',2)",
                "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES(9000,91,X'0000803F00000000')",
                "UPDATE chunk_embeddings SET embedding=X'000000000000803F' WHERE chunk_id=9000 AND generation_id=91",
                "DELETE FROM chunk_embeddings WHERE chunk_id=9000 AND generation_id=91"),
            ("index_generations", null, "INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at) VALUES(9000,1,'legacy','legacy','m',2,'legacy','legacy','legacy','legacy','building',$time)",
                "UPDATE index_generations SET state='failed' WHERE id=9000", "DELETE FROM index_generations WHERE id=9000"),
            ("index_generation_manifest", null, "INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES(91,4,401,'pending')",
                "UPDATE index_generation_manifest SET state='excluded',reason='epoch' WHERE generation_id=91 AND source_id=4",
                "DELETE FROM index_generation_manifest WHERE generation_id=91 AND source_id=4"),
            ("folder_sources", null, "INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at) VALUES(9000,1,'/fixture/epoch','{\"volumeId\":\"fixture\",\"components\":[\"fixture\",\"epoch\"]}','epoch','[\"txt\"]','[]','{}',$time)",
                "UPDATE folder_sources SET watch_enabled=0 WHERE id=9000", "DELETE FROM folder_sources WHERE id=9000"),
            ("source_set_members", "INSERT INTO source_sets(id,notebook_id,name,created_at) VALUES(9000,1,'epoch',$time)",
                "INSERT INTO source_set_members(set_id,source_id) VALUES(9000,1)",
                "UPDATE source_set_members SET source_id=4 WHERE set_id=9000 AND source_id=1",
                "DELETE FROM source_set_members WHERE set_id=9000 AND source_id=4"),
            ("source_set_folders", "INSERT INTO source_sets(id,notebook_id,name,created_at) VALUES(9000,1,'epoch',$time)",
                "INSERT INTO source_set_folders(set_id,folder_id) VALUES(9000,10)",
                "UPDATE source_set_folders SET folder_id=20 WHERE set_id=9000 AND folder_id=10",
                "DELETE FROM source_set_folders WHERE set_id=9000 AND folder_id=20")
        };
        lock (store.Gate)
        {
            Assert.Equal(mutations.SelectMany(m => new[] { "insert", "update", "delete" }.Select(e => $"rag_{m.Table}_{e}")).Order(),
                store.Connection.Query<string>("SELECT name FROM sqlite_temp_master WHERE type='trigger' AND name GLOB 'rag_*'").Order());
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM main.sqlite_master WHERE type='trigger' AND name GLOB 'rag_*'"));
            Assert.Equal(2, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM json_each('[1,2]')"));
            foreach (var m in mutations)
            {
                using var tx = store.Connection.BeginTransaction();
                if (m.Setup is not null) store.Connection.Execute(m.Setup, new { time }, tx);
                ulong beforeCase = reader.ObservedEpoch();
                Change(m.Insert);
                if (m.Update is not null) Change(m.Update);
                else
                {
                    ulong beforeRejected = reader.ObservedEpoch();
                    Assert.Throws<SqliteException>(() => store.Connection.Execute("UPDATE source_revisions SET canonical_text='changed' WHERE id=9000", transaction: tx));
                    Assert.Equal(beforeRejected, reader.ObservedEpoch());
                }
                Change(m.Delete);
                tx.Rollback();
                Assert.True(reader.ObservedEpoch() > beforeCase, m.Table);
                continue;
                void Change(string sql)
                {
                    ulong before = reader.ObservedEpoch();
                    Assert.Equal(1, store.Connection.Execute(sql, new { time }, tx));
                    Assert.True(reader.ObservedEpoch() > before, $"No invalidation: {m.Table}: {sql}");
                }
            }
            using (var tx = store.Connection.BeginTransaction())
            {
                ulong before = reader.ObservedEpoch();
                store.Connection.Execute("UPDATE sources SET eligible=0 WHERE id=1", transaction: tx);
                Assert.True(reader.ObservedEpoch() > before);
                tx.Rollback();
                Assert.Equal(1, store.Connection.ExecuteScalar<int>("SELECT eligible FROM sources WHERE id=1"));
                Assert.True(reader.ObservedEpoch() > before);
            }
            using (var tx = store.Connection.BeginTransaction())
            {
                ulong before = reader.ObservedEpoch();
                store.Connection.Execute("DELETE FROM folder_sources WHERE id=10", transaction: tx);
                Assert.True(reader.ObservedEpoch() > before + 1); // Cascaded children also invalidate.
                foreach (string sql in new[] {
                    "SELECT count(*) FROM sources WHERE id IN (1,2)",
                    "SELECT count(*) FROM source_revisions WHERE source_id IN (1,2)",
                    "SELECT count(*) FROM source_chunks WHERE source_id IN (1,2)",
                    "SELECT count(*) FROM index_generation_manifest WHERE source_id IN (1,2)",
                    "SELECT count(*) FROM chunk_embeddings WHERE chunk_id IN (1010,1020,2010)" })
                    Assert.Equal(0, store.Connection.ExecuteScalar<int>(sql, transaction: tx));
                tx.Rollback();
                Assert.Equal(2, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM sources WHERE id IN (1,2)"));
            }
        }
    }

    [Fact]
    public async Task CrossStoreInvalidationAndGC()
    {
        string directory = Path.Combine(Path.GetTempPath(), "wp5-scope-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            using var first = V19TestStore.Reopen(directory);
            RetrievalFixtureStore.Seed(first);
            using var second = V19TestStore.Reopen(directory);
            Assert.Equal(first.RetrievalDatabaseId, second.RetrievalDatabaseId);
            var reader = first.MakeRetrievalReader();
            using var snapshot = ScopeResolver.Resolve(first, 1, new RetrievalScope.All(), "m")!;
            ulong before = reader.CurrentEpoch(snapshot);
            using var barrier = new Barrier(2);
            Task writer = Task.Run(() =>
            {
                Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(15)));
                second.RetireGeneration(90);
                RetrievalFixtureStore.ApplyEvent("revoke-eligible", second);
                second.GarbageCollect(1);
                Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(15)));
            });
            Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(15)));
            Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(15)));
            await writer;
            Assert.True(reader.CurrentEpoch(snapshot) > before);
            Assert.DoesNotContain(1, reader.PermittedSourceIds(snapshot));
            lock (first.Gate)
            {
                Assert.Equal(1, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=90"));
                Assert.Equal(1, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=101"));
                Assert.Equal(1, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_chunks WHERE id=1010"));
            }
            // An uninstrumented external connection proves data_version fallback,
            // independently of the shared epoch incremented by store TEMP triggers.
            ulong observed = reader.ObservedEpoch();
            lock (second.Gate)
            {
                using var external = new SqliteConnection(new SqliteConnectionStringBuilder {
                    DataSource = Path.Combine(directory, "db.sqlite"), Pooling = false }.ToString());
                external.Open();
                external.Execute("UPDATE sources SET title='external' WHERE id=4");
            }
            Assert.Equal(observed, reader.ObservedEpoch());
            Assert.True(reader.CurrentEpoch(snapshot) > observed);
            snapshot.Dispose();
            second.GarbageCollect(1);
            lock (first.Gate)
            {
                Assert.Equal(0, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=90"));
                Assert.Equal(0, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=101"));
                Assert.Equal(0, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_chunks WHERE id=1010"));
                Assert.Equal(0, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM chunk_embeddings WHERE chunk_id=1010"));
                Assert.Equal(1, first.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=102"));
            }
            string closedDirectory = Path.Combine(directory, "closed");
            Directory.CreateDirectory(closedDirectory);
            var priorKey = CaptureClosedDatabaseKey(closedDirectory);
            GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
            lock (first.Gate)
            {
                using var external = new SqliteConnection(new SqliteConnectionStringBuilder {
                    DataSource = Path.Combine(closedDirectory, "db.sqlite"), Pooling = false }.ToString());
                external.Open();
                external.Execute("UPDATE chunk_embeddings SET embedding=X'000000000000803F' WHERE chunk_id=1010 AND generation_id=90");
            }
            using var reopened = V19TestStore.Reopen(closedDirectory);
            using var nextSnapshot = ScopeResolver.Resolve(reopened, 1, new RetrievalScope.All(), "m")!;
            Assert.NotNull(nextSnapshot.CacheKey);
            Assert.Equal(priorKey.DatabaseId, nextSnapshot.CacheKey.DatabaseId);
            Assert.Equal(priorKey.GenerationId, nextSnapshot.CacheKey.GenerationId);
            Assert.True(nextSnapshot.CacheKey.Epoch > priorKey.Epoch, "Reopening must invalidate matrices from a closed connection interval");
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
    private static RetrievalCacheKey CaptureClosedDatabaseKey(string directory)
    {
        using var store = V19TestStore.Reopen(directory);
        RetrievalFixtureStore.Seed(store);
        using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        return snapshot.CacheKey!;
    }

    [Fact]
    public void PagedReaderBoundAndInvalidBlobProgress()
    {
        using var store = RetrievalFixtureStore.Create();
        // Keep the fixture generation/source identities, extending its manifest revision.
        // First 1024 rows valid, next 1024 malformed, final 1026 valid.
        lock (store.Gate)
        {
            using var tx = store.Connection.BeginTransaction();
            store.Connection.Execute("DELETE FROM chunk_embeddings WHERE generation_id=90", transaction: tx);
            for (int i = 0; i < 3074; i++)
            {
                long id = 10000 + i;
                store.Connection.Execute("INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES($id,1,101,$ord,'needle page',2)",
                    new { id, ord = i + 1 }, tx);
                byte[] blob = i is >= 1024 and < 2048 ? [1] : [0, 0, 128, 63, 0, 0, 0, 0];
                store.Connection.Execute("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($id,90,$blob)", new { id, blob }, tx);
            }
            tx.Commit();
        }
        using var snapshot = ScopeResolver.Resolve(store, 1, new RetrievalScope.All(), "m")!;
        using var operation = snapshot.AcquireOperation();
        var reader = store.MakeRetrievalReader();
        Assert.Equal(3074, reader.VectorCount(snapshot));
        long after = 0;
        int scanned = 0, invalidOnlyPages = 0, pages = 0;
        while (true)
        {
            var page = reader.RawVectorPage(operation, after, 1024);
            Assert.InRange(page.Rows.Count, 0, 1024);
            Assert.InRange(page.PayloadBytes, 0, 8_388_608);
            Assert.Equal(page.Rows.Sum(r => r.Blob?.Length ?? 0), page.PayloadBytes);
            Assert.All(page.Rows.Where(r => r.Blob is not null), r => Assert.Equal(8, r.Blob!.Length));
            scanned += page.Rows.Count;
            if (page.Rows.Count > 0)
            {
                Assert.True(page.LastScannedChunkId > after);
                Assert.Equal(page.Rows[^1].Reference.ChunkId, page.LastScannedChunkId);
                if (page.Rows.All(r => r.Blob is null)) invalidOnlyPages++;
            }
            else Assert.Equal(after, page.LastScannedChunkId);
            after = page.LastScannedChunkId;
            Assert.True(++pages <= 5, "Cursor failed to progress");
            if (page.Exhausted) break;
        }
        Assert.Equal(3074, scanned);
        Assert.Equal(1, invalidOnlyPages);
        Assert.Equal(13073, after);
        var validIds = new List<long>();
        after = 0;
        do
        {
            var page = reader.VectorPage(snapshot, after, 1024);
            if (page.Count == 0) break;
            Assert.True(page[^1].Reference.ChunkId > after);
            validIds.AddRange(page.Select(r => r.Reference.ChunkId));
            after = page[^1].Reference.ChunkId;
            Assert.True(validIds.Count <= 2050);
        } while (true);
        Assert.Equal(Enumerable.Range(0, 3074).Where(i => i < 1024 || i >= 2048).Select(i => 10000L + i), validIds);
        Assert.Equal(2050, validIds.Count);
    }

    [Fact]
    public void CallbackFailureDoesNotRegisterPin()
    {
        using var store = RetrievalFixtureStore.Create();
        Assert.Throws<InvalidOperationException>(() => store.WithQueryPin<int>(1, "m", (_, _, _) => throw new InvalidOperationException("fixture failure")));
        lock (store.Gate)
        {
            using var registry = GenerationPinRegistry.Acquire(store.RetrievalDatabaseId);
            Assert.Empty(registry.Pins);
        }
        store.RetireGeneration(90);
        store.GarbageCollect(1);
        lock (store.Gate)
        {
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=101"));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_chunks WHERE id=1010"));
            Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM index_generations WHERE id=90"));
            Assert.Equal(1, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM source_revisions WHERE id=102"));
        }
    }
}
