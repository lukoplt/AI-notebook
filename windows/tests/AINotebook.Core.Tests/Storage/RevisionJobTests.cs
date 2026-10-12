using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class RevisionJobTests
{
    private static readonly HashSet<string> CaseNames = ["scalar-spans", "immutable", "empty-publication", "old-chunks-retained", "wrong-source",
        "stale-revision-publication", "revision-not-current", "publish-rollback", "double-publish", "invalid-span-range", "invalid-span-order",
        "invalid-span-null", "invalid-span-text", "superseded-extraction", "renew-running-extraction", "lease-timeline", "token-fence", "expiry-fence",
        "exhaustion", "expired-fifth", "pause-resume-cancel", "claim-order", "restart-reclaim", "two-connections-single-claim"];

    private static JsonElement[] Cases(params string[] names)
    {
        var all = SharedFixtures.Json("contracts/storage-jobs-revisions-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.NotEmpty(all);
        Assert.All(all, c => Assert.Contains(c.GetProperty("name").GetString()!, CaseNames));
        Assert.All(all, c => Assert.Contains(c.GetProperty("operation").GetString(), new[] { "publish", "jobs", "extraction", "revision-update" }));
        return names.Select(name => RetryCapSupersession.Apply(Assert.Single(all, c => c.GetProperty("name").GetString() == name),
            "storage-jobs-revisions-v1.json")).ToArray();
    }

    private static long? NullableLong(JsonElement v) => v.ValueKind == JsonValueKind.Null ? null : v.GetInt64();
    private static int? NullableInt(JsonElement v) => v.ValueKind == JsonValueKind.Null ? null : v.GetInt32();
    private static RevisionDraft Draft(JsonElement v) => new(v.GetProperty("contentHash").GetString()!, v.GetProperty("canonicalText").GetString()!,
        v.GetProperty("textFormatVersion").GetInt32(), v.GetProperty("chunkerVersion").GetInt32());
    private static RevisionChunkDraft[] Chunks(JsonElement v) => v.EnumerateArray().Select(c => new RevisionChunkDraft(c.GetProperty("text").GetString()!,
        c.GetProperty("tokenCount").GetInt32(), NullableInt(c.GetProperty("pageHint")), NullableInt(c.GetProperty("charStart")), NullableInt(c.GetProperty("charEnd")),
        c.GetProperty("lang").GetString(), c.GetProperty("langInherited").GetBoolean())).ToArray();
    private static void Equal(JsonElement expected, object? actual)
    {
        var json = JsonSerializer.SerializeToElement(actual);
        Assert.True(JsonElement.DeepEquals(expected, json), $"Expected {expected.GetRawText()}, actual {json.GetRawText()}");
    }
    private static T Scalar<T>(NotebookStore store, string sql, object? args = null)
    {
        lock (store.Gate) return store.Connection.ExecuteScalar<T>(sql, args)!;
    }
    private static string TempDirectory()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"revision-jobs-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return directory;
    }

    [Fact]
    public void FencedPublicationAndScalarSpans()
    {
        foreach (var c in Cases("scalar-spans", "invalid-span-range", "invalid-span-order", "invalid-span-null", "invalid-span-text")) RunPublication(c);
    }

    [Fact]
    public void LeaseTimelineAndBackoff()
    {
        foreach (var c in Cases("lease-timeline", "token-fence")) RunJobs(c);
    }

    [Fact]
    public void LeaseExpiryAndExhaustion()
    {
        foreach (var c in Cases("expiry-fence", "exhaustion", "expired-fifth")) RunJobs(c);
    }

    [Fact]
    public void PauseResumeCancelAndOrdering()
    {
        foreach (var c in Cases("pause-resume-cancel", "claim-order")) RunJobs(c);
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, Cases("lease-timeline")[0].GetProperty("setupSql"));
        long delayed = store.EnqueueJob(new("extract", "source:1", 101), 100);
        store.PauseJob(delayed);
        store.ResumeJob(delayed, 1);
        Assert.Equal(100, store.Job(delayed)!.NextRetryAt);
        Assert.Null(store.ClaimJob(99, "early", delayed));
        Assert.NotNull(store.ClaimJob(100, "owner", delayed));
        Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.CompleteJob(new(delayed, "owner"), 101)).Code);
        Assert.Equal("running", store.Job(delayed)!.State);
        Assert.False(store.CancelJob(new(delayed, "other"), 101));
        Assert.True(store.CancelJob(new(delayed, "owner"), 101));
        Assert.False(store.CompleteJob(new(delayed, "owner"), 101));
        Assert.Equal("cancelled", store.Job(delayed)!.State);
        lock (store.Gate)
            store.Connection.Execute("""
                INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                VALUES(1,1,'legacy','legacy','m',2,'legacy','legacy','legacy','legacy','retired','2026-01-02 03:04:05.000')
                """);
        long management = store.EnqueueJob(new("gc", "generation:1", null), 0);
        Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.ClaimJob(0, "", management)).Code);
        Assert.Equal(0, store.Job(management)!.Attempts);
        Assert.NotNull(store.ClaimJob(0, "gc-owner", management));
        Assert.True(store.CompleteJob(new(management, "gc-owner"), 1));
        Assert.Equal("done", store.Job(management)!.State);
        Assert.Null(store.Job(management)!.NextRetryAt);
        Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.ResumeJob(management, 2)).Code);
        long orphanSource = store.CreateSource(1, SourceType.Text, "removed before claim", null, null).Id!.Value;
        long orphan = store.EnqueueJob(new("extract", $"source:{orphanSource}", null), 10);
        store.DeleteSource(orphanSource);
        long valid = store.EnqueueJob(new("gc", "generation:1", null), 10);
        Assert.Equal(valid, store.ClaimJob(10, "valid-after-orphan")!.Id);
        Assert.Equal("cancelled", store.Job(orphan)!.State);
        Assert.Equal(0, store.Job(orphan)!.Attempts);
        Assert.Null(store.Job(orphan)!.LeaseToken);
        Assert.Equal("running", store.Job(valid)!.State);
        Assert.Equal(1, store.Job(valid)!.Attempts);
    }

    [Fact]
    public void ImmutableRevisionAndRollback()
    {
        var immutable = Cases("immutable")[0];
        using (var store = V19TestStore.Create())
        {
            V19TestStore.Seed(store, immutable.GetProperty("setupSql"));
            lock (store.Gate)
            {
                var error = Assert.Throws<SqliteException>(() => store.Connection.Execute(immutable.GetProperty("sql").GetString()!));
                Assert.Contains(immutable.GetProperty("expectedSqlError").GetString()!, error.Message);
            }
            AssertProjection(store, immutable.GetProperty("expected"), 1, 101, null);
        }
        foreach (var c in Cases("publish-rollback", "wrong-source")) RunPublication(c);
        using (var store = V19TestStore.Create())
        {
            V19TestStore.Seed(store, Cases("scalar-spans")[0].GetProperty("setupSql"));
            lock (store.Gate)
                store.Connection.Execute("CREATE TRIGGER fail_publication BEFORE INSERT ON source_chunks WHEN new.revision_id<>101 BEGIN SELECT RAISE(ABORT,'injected publication failure'); END");
            var draft = new RevisionDraft("new-hash", "new", 1, 2);
            RevisionChunkDraft[] chunks = [new("new", 1, null, 0, 3, null, false)];
            Assert.Throws<SqliteException>(() => store.CommitForegroundRevision(1, draft, chunks, 1, "foreground"));
            Assert.Equal(101, Scalar<long>(store, "SELECT current_revision FROM sources WHERE id=1"));
            Assert.Equal(101, Scalar<long>(store, "SELECT published_revision_id FROM sources WHERE id=1"));
            Assert.Equal(1, Scalar<int>(store, "SELECT count(*) FROM source_revisions"));
            Assert.Equal(1, Scalar<int>(store, "SELECT count(*) FROM source_chunks"));
            Assert.Equal(0, Scalar<int>(store, "SELECT count(*) FROM ingest_jobs"));
            lock (store.Gate) store.Connection.Execute("DROP TRIGGER fail_publication");
            var revision = store.CommitForegroundRevision(1, draft, chunks, 2, "foreground-success");
            Assert.Equal(102, revision.Id);
            Assert.Equal("done", Scalar<string>(store, "SELECT state FROM ingest_jobs"));
        }
    }

    [Fact]
    public void EmptyAndStalePublication()
    {
        foreach (var c in Cases("empty-publication", "old-chunks-retained", "stale-revision-publication", "revision-not-current", "double-publish")) RunPublication(c);
        foreach (var c in Cases("superseded-extraction", "renew-running-extraction")) RunExtraction(c);
    }

    [Fact]
    public void RestartReclaim()
    {
        foreach (var c in Cases("restart-reclaim")) RunJobs(c, fileBacked: true);
    }

    [Fact]
    public async Task TwoConnectionsClaimOnce()
    {
        foreach (var c in Cases("two-connections-single-claim"))
        {
            string directory = TempDirectory();
            try
            {
                using var first = V19TestStore.Reopen(directory);
                V19TestStore.Seed(first, c.GetProperty("setupSql"));
                long id = first.EnqueueJob(new(c.GetProperty("kind").GetString()!, c.GetProperty("target").GetString()!, NullableLong(c.GetProperty("targetRevision"))), c.GetProperty("enqueueAt").GetInt64());
                using var second = V19TestStore.Reopen(directory);
                Assert.NotSame(first.Gate, second.Gate);
                lock (first.Gate)
                    lock (second.Gate)
                        Assert.NotSame(first.Connection, second.Connection);
                var events = c.GetProperty("events").EnumerateArray().ToArray();
                Assert.Equal(2, events.Length);
                Assert.Equal("release-both-connections-before-claim", c.GetProperty("synchronization").GetString());
                using var barrier = new Barrier(2);
                var claims = await Task.WhenAll(events.Select(e => Task.Run(() =>
                {
                    Assert.Equal("claim", e.GetProperty("op").GetString());
                    var connection = e.GetProperty("connection").GetInt32() switch { 1 => first, 2 => second, _ => throw new InvalidOperationException("Unknown fixture connection.") };
                    Assert.True(barrier.SignalAndWait(TimeSpan.FromSeconds(10)));
                    return connection.ClaimJob(e.GetProperty("at").GetInt64(), e.GetProperty("token").GetString()!, id);
                })));
                var expected = c.GetProperty("expected");
                Assert.Equal(expected.GetProperty("successfulClaims").GetInt32(), claims.Count(j => j is not null));
                var winner = Assert.Single(claims.OfType<IngestJob>());
                var persisted = Assert.IsType<IngestJob>(first.Job(id));
                Assert.Equal(winner, persisted);
                Assert.Equal(expected.GetProperty("attempts").GetInt32(), persisted.Attempts);
                Assert.Equal(expected.GetProperty("state").GetString(), persisted.State);
                Equal(expected.GetProperty("nextRetryAt"), persisted.NextRetryAt);
                Equal(expected.GetProperty("leaseUntil"), persisted.LeaseUntil);
                Assert.Contains(persisted.LeaseToken, expected.GetProperty("winningTokens").EnumerateArray().Select(v => v.GetString()));
            }
            finally { Directory.Delete(directory, true); }
        }
    }

    private static void RunPublication(JsonElement c)
    {
        Assert.Equal("publish", c.GetProperty("operation").GetString());
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, c.GetProperty("setupSql"));
        long source = c.GetProperty("sourceId").GetInt64();
        long now = c.GetProperty("now").GetInt64();
        long revision;
        var laterDrafts = new List<RevisionDraft>();
        if (c.TryGetProperty("revisionDrafts", out var drafts))
        {
            Assert.NotEmpty(drafts.EnumerateArray());
            revision = c.GetProperty("publishRevisionId").GetInt64();
            long claimedRevision = c.GetProperty("targetRevision").GetInt64();
            bool targetInserted = false;
            foreach (var draft in drafts.EnumerateArray())
            {
                if (targetInserted) laterDrafts.Add(Draft(draft));
                else targetInserted = store.InsertRevision(source, Draft(draft), now).Id == claimedRevision;
            }
            Assert.True(targetInserted, "The publication fixture must create its targeted revision before claim.");
        }
        else revision = c.TryGetProperty("draft", out var singleDraft)
            ? store.InsertRevision(source, Draft(singleDraft), now).Id : c.GetProperty("revisionId").GetInt64();
        long jobSource = c.TryGetProperty("jobSourceId", out var owner) ? owner.GetInt64() : source;
        string target = c.TryGetProperty("target", out var targetValue) ? targetValue.GetString()! : $"source:{jobSource}";
        long targetRevision = c.TryGetProperty("targetRevision", out var targetRev) ? targetRev.GetInt64() : revision;
        long job = store.EnqueueJob(new("extract", target, targetRevision), now);
        string token = c.GetProperty("leaseToken").GetString()!;
        var lease = Assert.IsType<IngestJob>(store.ClaimJob(now, token, job));
        Assert.Equal(1, lease.Attempts);
        // Supersede after claim so these cases continue to exercise the publication fence.
        foreach (var draft in laterDrafts) store.InsertRevision(source, draft, now);
        var chunks = Chunks(c.GetProperty("chunks"));
        if (c.GetProperty("name").GetString() == "scalar-spans")
        {
            Assert.False(store.PublishRevision(source, revision, chunks, new(job, "stale"), now + 1));
            Assert.Equal(0, Scalar<int>(store, "SELECT count(*) FROM source_chunks WHERE revision_id=$id", new { id = revision }));
        }
        var times = c.TryGetProperty("publishTimes", out var publishTimes)
            ? publishTimes.EnumerateArray().Select(t => t.GetInt64()).ToArray() : [now + 1];
        var results = new List<bool>();
        foreach (long time in times)
        {
            if (c.TryGetProperty("expectedError", out var error))
                Assert.Equal(error.GetString(), Assert.Throws<StorageV19Exception>(() => store.PublishRevision(source, revision, chunks, new(job, token), time)).Code);
            else results.Add(store.PublishRevision(source, revision, chunks, new(job, token), time));
        }
        long observedSource = c.GetProperty("expected").TryGetProperty("observedSourceId", out var observed) ? observed.GetInt64() : source;
        AssertProjection(store, c.GetProperty("expected"), observedSource, revision, job, results.Count == 1 ? results[0] : null, results);
        if (!c.TryGetProperty("expectedError", out _) && results.Any(value => value))
        {
            var persisted = Assert.IsType<SourceRevision>(store.Revision(revision));
            Assert.Equal(revision, persisted.Id);
            Assert.Equal(source, persisted.SourceId);
            Assert.Equal(now, persisted.CreatedAt);
            Assert.Equal(Draft(c.GetProperty("draft")), persisted.Draft);
            lock (store.Gate)
            {
                var rows = store.Connection.Query("SELECT text,token_count,page_hint,char_start,char_end,lang,lang_inherited,ord FROM source_chunks WHERE revision_id=$id ORDER BY ord", new { id = revision }).ToArray();
                Assert.Equal(chunks.Length, rows.Length);
                for (int i = 0; i < rows.Length; i++)
                {
                    var row = rows[i]; var chunk = chunks[i];
                    Assert.Equal(chunk.Text, (string)row.text); Assert.Equal(chunk.TokenCount, (int)(long)row.token_count);
                    Assert.Equal(chunk.PageHint, (int?)(long?)row.page_hint); Assert.Equal(chunk.CharStart, (int?)(long?)row.char_start);
                    Assert.Equal(chunk.CharEnd, (int?)(long?)row.char_end); Assert.Equal(chunk.Lang, (string?)row.lang);
                    Assert.Equal(chunk.LangInherited, (long)row.lang_inherited != 0); Assert.Equal(i, (long)row.ord);
                }
            }
        }
        if (c.TryGetProperty("expectedSqlError", out var sqlError))
        {
            lock (store.Gate)
            {
                var error = Assert.Throws<SqliteException>(() => store.Connection.Execute("UPDATE sources SET published_revision_id=$revision WHERE id=$source", new { revision, source }));
                Assert.Contains(sqlError.GetString()!, error.Message);
            }
            AssertProjection(store, c.GetProperty("expected"), observedSource, revision, job);
        }
    }

    private static void AssertProjection(NotebookStore store, JsonElement expected, long source, long revision, long? job,
        object? result = null, IReadOnlyList<bool>? results = null, IReadOnlyDictionary<string, JobFence>? fences = null)
    {
        foreach (var p in expected.EnumerateObject())
        {
            object? actual = p.Name switch
            {
                "revisionId" => revision,
                "observedSourceId" => source,
                "canonicalText" => store.Revision(revision)!.Draft.CanonicalText,
                "scalarCount" => store.Revision(revision)!.Draft.CanonicalText.EnumerateRunes().Count(),
                "currentRevision" => Scalar<long?>(store, "SELECT current_revision FROM sources WHERE id=$source", new { source }),
                "publishedRevisionId" => Scalar<long?>(store, "SELECT published_revision_id FROM sources WHERE id=$source", new { source }),
                "chunkCount" => Scalar<int>(store, "SELECT count(*) FROM source_chunks WHERE revision_id=$revision", new { revision }),
                "jobState" => store.Job(job!.Value)!.State,
                "attempts" => store.Job(job!.Value)!.Attempts,
                "result" => result,
                "results" => results,
                "newRevisionCount" => Scalar<int>(store, "SELECT count(*) FROM source_revisions WHERE source_id=$source AND id<>101", new { source }),
                "publishedText" => Scalar<string>(store, "SELECT r.canonical_text FROM source_revisions r JOIN sources s ON s.published_revision_id=r.id WHERE s.id=$source", new { source }),
                "visibleChunkIds" => Query<long>(store, "SELECT c.id FROM source_chunks c JOIN sources s ON c.revision_id=s.published_revision_id WHERE s.id=$source ORDER BY c.ord", source),
                "visibleTexts" => Query<string>(store, "SELECT c.text FROM source_chunks c JOIN sources s ON c.revision_id=s.published_revision_id WHERE s.id=$source ORDER BY c.ord", source),
                "retainedChunkIds" => Query<long>(store, "SELECT id FROM source_chunks WHERE source_id=$source AND revision_id=101 ORDER BY id", source),
                "jobStates" => fences!.ToDictionary(kv => kv.Key, kv => store.Job(kv.Value.JobId)!.State),
                _ => throw new InvalidOperationException($"Unhandled revision projection {p.Name}.")
            };
            Equal(p.Value, actual);
        }
    }

    private static T[] Query<T>(NotebookStore store, string sql, long source)
    {
        lock (store.Gate) return store.Connection.Query<T>(sql, new { source }).ToArray();
    }

    private static void RunJobs(JsonElement c, bool fileBacked = false)
    {
        Assert.Equal("jobs", c.GetProperty("operation").GetString());
        string? directory = fileBacked ? TempDirectory() : null;
        NotebookStore store = fileBacked ? V19TestStore.Reopen(directory!) : V19TestStore.Create();
        try
        {
            V19TestStore.Seed(store, c.GetProperty("setupSql"));
            long? jobId = null;
            if (c.TryGetProperty("jobs", out var jobs))
            {
                Assert.NotEmpty(jobs.EnumerateArray());
                foreach (var j in jobs.EnumerateArray())
                {
                    long id = store.EnqueueJob(new(j.GetProperty("kind").GetString()!, j.GetProperty("target").GetString()!, NullableLong(j.GetProperty("targetRevision"))), j.GetProperty("nextRetryAt").GetInt64());
                    Assert.Equal(j.GetProperty("id").GetInt64(), id);
                }
            }
            else jobId = store.EnqueueJob(new(c.GetProperty("kind").GetString()!, c.GetProperty("target").GetString()!, NullableLong(c.GetProperty("targetRevision"))), c.GetProperty("enqueueAt").GetInt64());
            if (c.TryGetProperty("publishedRevisionIdBefore", out var before)) Equal(before, Scalar<long?>(store, "SELECT published_revision_id FROM sources WHERE id=1"));
            var events = c.GetProperty("events").EnumerateArray().ToArray();
            var snapshots = c.GetProperty("expected").GetProperty("snapshots").EnumerateArray().ToArray();
            Assert.NotEmpty(events); Assert.Equal(events.Length, snapshots.Length);
            var claimedIds = new List<long>();
            var claimTimes = new List<long>();
            var retryTimes = new List<long?>();
            for (int i = 0; i < events.Length; i++)
            {
                var e = events[i];
                long at = e.GetProperty("at").GetInt64();
                string? token = e.GetProperty("token").GetString();
                string? thrownCode = null;
                bool result = false;
                long? observedJob = jobId;
                try
                {
                    switch (e.GetProperty("op").GetString())
                    {
                        case "claim":
                            var claimed = store.ClaimJob(at, token!, jobId);
                            result = claimed is not null;
                            if (claimed is not null) { claimedIds.Add(claimed.Id); claimTimes.Add(at); observedJob = claimed.Id; }
                            break;
                        case "renew": result = store.RenewJob(new(jobId!.Value, token!), at); break;
                        case "fail":
                            result = store.FailJob(new(jobId!.Value, token!), e.GetProperty("error").GetString()!, at);
                            // One retry time per accepted failure (a rejected stale failure records nothing).
                            if (result) retryTimes.Add(store.Job(jobId.Value)!.NextRetryAt);
                            break;
                        case "retry": result = store.RetryJob(jobId!.Value, at); break;
                        case "complete": result = store.CompleteJob(new(jobId!.Value, token!), at); break;
                        case "recover": result = store.RecoverExpiredJobs(at) > 0; break;
                        case "pause": store.PauseJob(jobId!.Value); result = true; break;
                        case "resume": store.ResumeJob(jobId!.Value, at); result = true; break;
                        case "cancel": store.CancelJob(jobId!.Value); result = true; break;
                        case "publish": result = store.PublishRevision(1, c.GetProperty("targetRevision").GetInt64(), [], new(jobId!.Value, token!), at); break;
                        case "reopen":
                            Assert.NotNull(directory);
                            store.Dispose(); store = V19TestStore.Reopen(directory!); result = true;
                            break;
                        default: throw new InvalidOperationException($"Unhandled job event {e.GetProperty("op").GetString()}.");
                    }
                }
                catch (StorageV19Exception error) { thrownCode = error.Code; }
                if (e.TryGetProperty("expectedError", out var expectedError)) Assert.Equal(expectedError.GetString(), thrownCode);
                else Assert.Null(thrownCode);
                AssertJobSnapshot(store.Job(observedJob!.Value)!, snapshots[i], result, thrownCode);
            }
            var expected = c.GetProperty("expected");
            foreach (var field in expected.EnumerateObject())
            {
                switch (field.Name)
                {
                    case "snapshots": break;
                    case "claimedJobIds": Equal(field.Value, claimedIds); break;
                    default: throw new InvalidOperationException($"Unhandled job expected field {field.Name}.");
                }
            }
            if (c.TryGetProperty("startTimes", out var starts)) Equal(starts, claimTimes);
            if (c.TryGetProperty("retryTimes", out var retries)) Equal(retries, retryTimes);
            if (c.TryGetProperty("expectedClaims", out var count)) Assert.Equal(count.GetInt32(), claimedIds.Count);
            if (c.TryGetProperty("expectedPublishedRevisionId", out var published)) Equal(published, Scalar<long?>(store, "SELECT published_revision_id FROM sources WHERE id=1"));
            if (fileBacked)
            {
                Assert.False(store.CompleteJob(new(jobId!.Value, "A"), 361));
                Assert.False(store.FailJob(new(jobId.Value, "A"), "late failure", 361));
                Assert.Equal("B", store.Job(jobId.Value)!.LeaseToken);
                Assert.Equal("running", store.Job(jobId.Value)!.State);
            }
        }
        finally { store.Dispose(); if (directory is not null) Directory.Delete(directory, true); }
    }

    private static void AssertJobSnapshot(IngestJob job, JsonElement expected, object? result, string? error = null)
    {
        foreach (var p in expected.EnumerateObject())
        {
            object? actual = p.Name switch
            {
                "jobId" => job.Id, "state" => job.State, "attempts" => job.Attempts, "nextRetryAt" => job.NextRetryAt,
                "leaseUntil" => job.LeaseUntil, "leaseToken" => job.LeaseToken, "error" => job.Error,
                "result" => result, "expectedError" => error,
                _ => throw new InvalidOperationException($"Unhandled job snapshot field {p.Name}.")
            };
            Equal(p.Value, actual);
        }
    }

    private static void RunExtraction(JsonElement c)
    {
        Assert.Equal("extraction", c.GetProperty("operation").GetString());
        using var store = V19TestStore.Create();
        V19TestStore.Seed(store, c.GetProperty("setupSql"));
        long source = c.GetProperty("sourceId").GetInt64();
        var fences = new Dictionary<string, JobFence>();
        var committed = new Dictionary<string, SourceRevision?>();
        long? leaseBeforeCommit = null;
        var events = c.GetProperty("events").EnumerateArray().ToArray();
        var expected = c.GetProperty("expected");
        var snapshots = expected.GetProperty("snapshots").EnumerateArray().ToArray();
        Assert.NotEmpty(events); Assert.Equal(events.Length, snapshots.Length);
        for (int i = 0; i < events.Length; i++)
        {
            var e = events[i];
            string token = e.GetProperty("token").GetString()!;
            long at = e.GetProperty("at").GetInt64();
            object? result;
            switch (e.GetProperty("op").GetString())
            {
                case "begin": fences[token] = store.BeginExtraction(source, at, token); result = true; break;
                case "renew": result = store.RenewJob(fences[token], at); break;
                case "commit":
                    leaseBeforeCommit = store.Job(fences[token].JobId)!.LeaseUntil;
                    committed[token] = store.CommitExtraction(source, Draft(e.GetProperty("draft")), Chunks(e.GetProperty("chunks")), fences[token], at);
                    result = committed[token]?.Id;
                    break;
                default: throw new InvalidOperationException($"Unhandled extraction event {e.GetProperty("op").GetString()}.");
            }
            if (snapshots[i].TryGetProperty("state", out _)) AssertJobSnapshot(store.Job(fences[token].JobId)!, snapshots[i], result);
            else AssertProjection(store, snapshots[i], source, committed.Values.LastOrDefault(v => v is not null)?.Id ?? 101,
                fences[token].JobId, result, fences: fences);
        }
        long revision = committed.Values.LastOrDefault(v => v is not null)?.Id ?? 101;
        long jobId = fences.Values.Last().JobId;
        foreach (var p in expected.EnumerateObject())
        {
            switch (p.Name)
            {
                case "snapshots": break;
                case "resultA": Equal(p.Value, committed["A"]?.Id); break;
                case "resultB": Equal(p.Value, committed["B"]?.Id); break;
                case "leaseUntilBeforeCommit": Equal(p.Value, leaseBeforeCommit); break;
                case "returnedSource": AssertProjection(store, p.Value, source, revision, jobId); break;
                default:
                    var one = JsonSerializer.SerializeToElement(new Dictionary<string, JsonElement> { [p.Name] = p.Value });
                    AssertProjection(store, one, source, revision, jobId, fences: fences);
                    break;
            }
        }
        if (c.TryGetProperty("withoutRenewal", out var without))
        {
            using var unrenewed = V19TestStore.Create();
            V19TestStore.Seed(unrenewed, c.GetProperty("setupSql"));
            var begin = events.First(e => e.GetProperty("op").GetString() == "begin");
            var commit = events.Last(e => e.GetProperty("op").GetString() == "commit");
            var fence = unrenewed.BeginExtraction(source, begin.GetProperty("at").GetInt64(), begin.GetProperty("token").GetString()!);
            var result = unrenewed.CommitExtraction(source, Draft(commit.GetProperty("draft")), Chunks(commit.GetProperty("chunks")), fence, without.GetProperty("commitAt").GetInt64());
            Equal(without.GetProperty("result"), result?.Id);
            Equal(without.GetProperty("newRevisionCount"), Scalar<int>(unrenewed, "SELECT count(*) FROM source_revisions WHERE id<>101"));
            Equal(without.GetProperty("publishedRevisionId"), Scalar<long?>(unrenewed, "SELECT published_revision_id FROM sources WHERE id=1"));
        }
        if (fences.TryGetValue("B", out var newer))
        {
            Assert.False(store.FailJob(fences["A"], "obsolete extractor failure", 4));
            Assert.False(store.CancelJob(fences["A"], 4));
            Assert.Equal("ready", Scalar<string>(store, "SELECT status FROM sources WHERE id=1"));
            Assert.Null(Scalar<string?>(store, "SELECT error FROM sources WHERE id=1"));
            Assert.Equal("done", store.Job(newer.JobId)!.State);
        }
    }
}
