using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Integration;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>
/// Contract chat-during-scan-v1: a chat turn while a folder check (and the extraction it
/// queues) runs answers from the last published state, and never fails because the check
/// changes the catalog underneath it. Mirrors Tests/AINotebookCoreTests/ChatDuringScanTests.swift.
/// </summary>
public sealed class ChatDuringScanTests
{
    private sealed class FixedIdentity : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => new("chat-scan", ["chat-scan"], "root");
    }

    /// <summary>Never called: no generation exists, so retrieval is lexical only.</summary>
    private sealed class UnusedEmbedder : IEmbeddingProducing
    {
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default) =>
            throw new InvalidOperationException("no query embedding without a generation");
    }

    private sealed record Fixture(NotebookStore Store, long NotebookId, long SessionId, long FolderId, ChatEngine Engine);

    private static Fixture Make()
    {
        var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("Folder chat").Id!.Value;
        long sessionId = store.CreateChatSession(notebookId, "chat").Id!.Value;
        var folder = store.CreateFolder(notebookId, new FolderDraft("/chat-scan", "Docs", FolderRules.Defaults.IncludeExts,
            FolderRules.Defaults.IgnoreGlobs, "{}", "cp1250", false), new FixedIdentity(), 1);
        var transport = new ReleaseTransport(new PackModel("test", "chat", 16_384, 1_024, true, "ollama"), "Answer [1].");
        var retriever = new Retriever(store, new UnusedEmbedder(), () => "none:none", new VectorMatrixCache(), null);
        var engine = new ChatEngine(store,
            new ContextPackCoordinator(new CompatibilityPackDataSource(store, retriever), new ReleaseTransportFactory(transport)),
            new ContextPreviewSession(), "chat");
        return new Fixture(store, notebookId, sessionId, folder.Id, engine);
    }

    private static FolderScanObservation Observation(string path, long mtime, string? hash) =>
        FolderScanObservation.File(new FolderObservation(path, new FileStamp("id:" + path, mtime, 100), "eligible", null, hash));

    private static ScanTicket BeginScan(Fixture f, string token)
    {
        long job = f.Store.RequestFolderScan(f.FolderId, false, 2);
        Assert.NotNull(f.Store.ClaimJob(2, token, job));
        return f.Store.BeginFolderScan(f.FolderId, new JobFence(job, token), 2)!;
    }

    private static readonly ScanCompletion Complete = new([""], [], false, null);

    /// <summary>Publishes revision text (one chunk per paragraph) for a folder source, as extraction would.</summary>
    private static long Publish(NotebookStore store, long folderId, string path, int revision, params string[] paragraphs)
    {
        lock (store.Gate)
        {
            var c = store.Connection;
            long sourceId = c.ExecuteScalar<long>("SELECT id FROM sources WHERE folder_id=$folderId AND rel_path=$path",
                new { folderId, path });
            long revisionId = c.ExecuteScalar<long>("""
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES ($sourceId,$revision,$hash,$text,1,2,'2026-10-11 00:00:00.000') RETURNING id
                """, new { sourceId, revision, hash = $"h-{path}-{revision}", text = string.Concat(paragraphs) });
            int offset = 0;
            for (int ord = 0; ord < paragraphs.Length; ord++)
            {
                int length = paragraphs[ord].EnumerateRunes().Count();
                c.Execute("""
                    INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang)
                    VALUES ($sourceId,$ord,$text,$tokens,$revisionId,$start,$end,'en')
                    """, new { sourceId, ord, text = paragraphs[ord], tokens = Math.Max(1, length / 4), revisionId,
                        start = offset, end = offset + length });
                offset += length;
            }
            c.Execute("""
                UPDATE sources SET current_revision=$revisionId,published_revision_id=$revisionId,status='ready',
                    content_hash=$hash,error=NULL WHERE id=$sourceId
                """, new { revisionId, hash = $"h-{path}-{revision}", sourceId });
            c.Execute("UPDATE ingest_jobs SET state='done',lease_token=NULL,lease_until=NULL WHERE target=$target",
                new { target = $"source:{sourceId}" });
            return revisionId;
        }
    }

    private static (long Alpha, long Beta) SeedIndexedFolder(Fixture f)
    {
        var ticket = BeginScan(f, "seed");
        f.Store.ObserveFolderFiles(ticket, [Observation("alpha.txt", 10, "h-alpha.txt-1"), Observation("beta.txt", 10, "h-beta.txt-1")], 2);
        Assert.True(f.Store.FinishFolderScan(ticket, Complete, 3));
        long alpha = Publish(f.Store, f.FolderId, "alpha.txt", 1, "Alpha contract signed in March. ", "Alpha payment terms are net thirty.");
        long beta = Publish(f.Store, f.FolderId, "beta.txt", 1, "Beta contract draft from April. ", "Beta delivery schedule.");
        return (alpha, beta);
    }

    private static async Task<PreparedPackHandle> PrepareTurn(Fixture f, string question = "contract")
    {
        var intent = await f.Engine.CaptureIntentAsync(f.SessionId, f.NotebookId, question, new RetrievalScope.All());
        return await f.Engine.PrepareAsync(intent);
    }

    [Fact]
    public async Task ChatTurnDuringScanAnswersFromThePreviousPublishedState()
    {
        var f = Make();
        var (alpha, beta) = SeedIndexedFolder(f);
        var before = await PrepareTurn(f);
        Assert.Equal([alpha, beta], before.Request.SourceRevisions.Select(r => r.RevisionId));

        // The periodic check is half way: beta changed, gamma appeared, alpha not reached yet.
        var ticket = BeginScan(f, "check");
        f.Store.ObserveFolderFiles(ticket, [Observation("beta.txt", 20, "h-beta.txt-2"), Observation("gamma.txt", 20, "h-gamma.txt-1")], 4);
        Assert.Equal("scanning", f.Store.Folder(f.FolderId)!.ScanState);

        var during = await PrepareTurn(f);
        Assert.Equal(before.Request.SourceRevisions, during.Request.SourceRevisions);
        Assert.All(during.Request.CitationMap, c => Assert.Contains(c.RevisionId!.Value, new[] { alpha, beta }));
        var corpus = during.Request.Coverage.Corpus;
        Assert.Equal(2, corpus.Searchable);
        Assert.Equal(1, corpus.Pending);
        Assert.Equal(corpus.FilesInScope, corpus.Searchable + corpus.Pending + corpus.Error);
        var fresh = await f.Engine.CaptureIntentAsync(f.SessionId, f.NotebookId, "contract", new RetrievalScope.All());
        var reply = await f.Engine.SendPreparedAsync(during, PackIntentKey.Make(fresh), null, null);
        Assert.NotEmpty(reply.Citations);
        Assert.All(reply.Citations, c => Assert.Contains(c.RevisionId!.Value, new[] { alpha, beta }));

        // Only the finished check marks alpha missing; the next turn no longer cites it.
        Assert.True(f.Store.FinishFolderScan(ticket, Complete, 5));
        var after = await PrepareTurn(f);
        Assert.Equal([beta], after.Request.SourceRevisions.Select(r => r.RevisionId));
    }

    [Fact]
    public async Task NewEvidenceDoesNotStaleButARevocationDoesAndSendReprepares()
    {
        var f = Make();
        SeedIndexedFolder(f);
        var intent = await f.Engine.CaptureIntentAsync(f.SessionId, f.NotebookId, "contract", new RetrievalScope.All());
        var handle = await f.Engine.PrepareAsync(intent);
        var ticket = BeginScan(f, "check");
        f.Store.ObserveFolderFiles(ticket, [Observation("gamma.txt", 20, "h-gamma.txt-1")], 4);
        Publish(f.Store, f.FolderId, "gamma.txt", 1, "Gamma contract. ");
        var fresh = await f.Engine.CaptureIntentAsync(f.SessionId, f.NotebookId, "contract", new RetrievalScope.All());
        Assert.Equal(handle.Key, PackIntentKey.Make(fresh));

        lock (f.Store.Gate) f.Store.Connection.Execute("UPDATE sources SET eligible=0 WHERE rel_path='alpha.txt'");
        await Assert.ThrowsAsync<StalePreparedRequestException>(() => f.Engine.SendPreparedAsync(handle, handle.Key, null, null));
        Assert.Empty(f.Store.Messages(f.SessionId));
        var reply = await f.Engine.SendAsync(f.SessionId, f.NotebookId, "contract", new RetrievalScope.All());
        Assert.Equal(ChatRole.Assistant, reply.Role);
        Assert.Equal(2, f.Store.Messages(f.SessionId).Count);
    }

    /// <summary>
    /// Scan batches and first publications run on a background thread while turns are sent; every
    /// turn completes, none fails with a ContextPackException or a stale request.
    /// </summary>
    [Fact]
    public async Task NoChatFailureWhileAFolderCheckRunsConcurrently()
    {
        var f = Make();
        SeedIndexedFolder(f);
        var ticket = BeginScan(f, "check");
        var background = Task.Run(async () =>
        {
            int published = 0;
            for (int batch = 0; batch < 40; batch++)
            {
                var paths = Enumerable.Range(0, 8).Select(i => $"batch-{batch}/file-{i}.txt").ToArray();
                f.Store.ObserveFolderFiles(ticket, paths.Select(p => Observation(p, 30, $"h-{p}-1")).ToArray(), 6);
                if (batch % 2 == 0)
                {
                    Publish(f.Store, f.FolderId, paths[0], 1, $"Batch {batch} contract appendix. ");
                    published++;
                }
                await Task.Delay(5);
            }
            f.Store.FinishFolderScan(ticket, Complete, 7);
            return published;
        });
        var failures = new List<string>();
        for (int turn = 0; turn < 12; turn++)
        {
            try { await f.Engine.SendAsync(f.SessionId, f.NotebookId, $"contract question {turn}", new RetrievalScope.All()); }
            catch (Exception ex) { failures.Add(ex.GetType().Name); }
        }
        Assert.True(await background > 0);
        Assert.Empty(failures);
        Assert.Equal(24, f.Store.Messages(f.SessionId).Count);
    }

    // MARK: Shared fixture

    private static string FixtureFingerprint(JsonElement state)
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("fixture").Id!.Value;
        lock (store.Gate)
        {
            var c = store.Connection;
            foreach (var folder in state.GetProperty("folders").EnumerateArray())
            {
                long id = folder.GetInt64();
                c.Execute("""
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,
                        ignore_globs,limits,encoding_fallback,watch_enabled,created_at)
                    VALUES($id,$notebookId,$root,$identity,$name,'[]','[]','{}','cp1250',0,'2026-10-11 00:00:00.000')
                    """, new { id, notebookId, root = $"/f{id}",
                        identity = $"{{\"volumeId\":\"v\",\"components\":[\"f{id}\"],\"rootFileId\":\"r{id}\"}}", name = $"F{id}" });
            }
            foreach (var row in state.GetProperty("sources").EnumerateArray())
            {
                long id = row.GetProperty("id").GetInt64();
                c.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                    VALUES($id,$notebookId,'text',$title,'ready','2026-10-11 00:00:00.000',$folder,$rel,$availability,$eligible)
                    """, new { id, notebookId, title = $"s{id}", folder = row.GetProperty("folderId").GetInt64(),
                        rel = $"s{id}.txt", availability = row.GetProperty("availability").GetString(),
                        eligible = row.GetProperty("eligible").GetBoolean() ? 1 : 0 });
                if (row.GetProperty("published").GetBoolean())
                {
                    long revision = c.ExecuteScalar<long>("""
                        INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES ($id,1,'h','t',1,2,'2026-10-11 00:00:00.000') RETURNING id
                        """, new { id });
                    c.Execute("UPDATE sources SET published_revision_id=$revision,current_revision=$revision WHERE id=$id",
                        new { revision, id });
                }
            }
        }
        return store.ContextScopeFingerprint(notebookId, new RetrievalScope.All());
    }

    [Fact]
    public void SharedFixture()
    {
        var fixture = SharedFixtures.Json("contracts/chat-during-scan-v1.json");
        Assert.Equal("chat-during-scan", fixture.GetProperty("contract").GetString());
        Assert.Equal(ChatSessionState.StaleRepreparations, fixture.GetProperty("staleRepreparations").GetInt32());
        var counts = new Dictionary<string, int>();
        foreach (var row in fixture.GetProperty("cases").EnumerateArray())
        {
            string name = row.GetProperty("name").GetString()!, operation = row.GetProperty("operation").GetString()!;
            var input = row.GetProperty("input");
            var expected = row.GetProperty("expected");
            counts[operation] = counts.GetValueOrDefault(operation) + 1;
            switch (operation)
            {
                case "coverage":
                    var s = input.GetProperty("snapshot");
                    int I(string key) => s.GetProperty(key).GetInt32();
                    var c = CompatibilityPackDataSource.NormalizedCoverage(new CoverageSnapshot(I("searchable"), I("pending"),
                        I("error"), I("skipped"), I("missing"), I("unavailable"), I("refreshPending"), I("refreshError"),
                        s.GetProperty("isLowerBound").GetBoolean()), input.GetProperty("pinnedFiles").GetInt32());
                    int E(string key) => expected.GetProperty(key).GetInt32();
                    Assert.True(new PackCorpusCoverage(E("filesInScope"), E("searchable"), E("pending"), E("error"), E("skipped"),
                        E("missing"), E("unavailable"), E("refreshPending"), E("refreshError"),
                        expected.GetProperty("partial").GetBoolean()) == c, name);
                    break;
                case "scope-stale":
                    bool stale = FixtureFingerprint(input.GetProperty("before")) != FixtureFingerprint(input.GetProperty("after"));
                    Assert.True(expected.GetProperty("stale").GetBoolean() == stale, name);
                    break;
                default:
                    throw new InvalidOperationException("unknown operation " + operation);
            }
        }
        Assert.Equal(7, counts["coverage"]);
        Assert.Equal(11, counts["scope-stale"]);
    }
}
