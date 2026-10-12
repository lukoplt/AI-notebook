using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class IngestionQueueTests
{
    private static readonly string[] JobOps =
        ["claim", "claim-race", "claim-many", "recover-expired", "renew", "fail", "publish", "user-retry", "requeue-retryable"];
    private static readonly string[] AdmissionOps =
        ["acquire", "release", "cancel-waiter", "memory-pressure", "begin-chat", "end-chat", "background-batch", "query-embedding"];

    [Fact]
    public void CoalesceHasMaximumDeadline()
    {
        var schedule = new RescanSchedule();
        for (long t = 0; t <= 4900; t += 100) schedule.Signal(t);
        Assert.Equal(5000, schedule.DueAt);
        schedule.Started(); schedule.Signal(5100); schedule.Finished(5200);
        Assert.Equal(5600, schedule.DueAt);

        var names = new List<string>();
        foreach (var row in Cases("schedule"))
        {
            names.Add(Name(row));
            Assert.Equal("monotonic-milliseconds", row.GetProperty("input").GetProperty("clockUnit").GetString());
            var replay = new RescanSchedule();
            AssertJson(row.GetProperty("input").GetProperty("seed"), Project(replay), Name(row) + " seed");
            int index = 0;
            foreach (var e in Events(row))
            {
                long at = e.GetProperty("at").GetInt64();
                switch (Op(e))
                {
                    case "signal": replay.Signal(at); break;
                    case "started": replay.Started(); break;
                    case "finished": replay.Finished(at); break;
                    case "tick": Assert.False(replay.IsDue(at)); break;
                    default: Assert.Fail("Unknown schedule operation " + Op(e)); break;
                }
                AssertJson(e.GetProperty("expected"), Project(replay), $"{Name(row)} event {index++}");
            }
            AssertJson(row.GetProperty("expected"), Project(replay), Name(row));
        }
        Assert.Equal(new[] { "debounce", "max-coalesce", "signal-during-scan" }, names);

        static JsonElement Project(RescanSchedule s) => JsonSerializer.SerializeToElement(new
        {
            dueAt = s.DueAt, running = s.Running, firstSignal = s.FirstSignal, lastSignal = s.LastSignal,
            trailingFirstSignal = s.TrailingFirstSignal, trailingLastSignal = s.TrailingLastSignal,
            startedScanCount = s.StartedScanCount
        });
    }

    [Fact]
    public void FailuresRequeueAtDeadlineAndExhaustAfterThreeStarts()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebookId = store.CreateNotebook("retries").Id!.Value;
        long sourceId = store.CreateSource(notebookId, SourceType.Text, "kept", null, null).Id!.Value;
        var published = store.CommitForegroundRevision(sourceId,
            new RevisionDraft("kept-hash", "kept", 1, 2),
            new[] { new RevisionChunkDraft("kept", 1, null, 0, 4, null, false) }, 0, "seed");
        var fence = store.BeginExtraction(sourceId, 100, "attempt-1");
        long jobId = fence.JobId;
        long startedAt = 100;
        const int last = ExtractionRetryBudget.ExtractMaxAttempts;
        for (int attempt = 1; attempt <= last; attempt++)
        {
            var running = store.Job(jobId)!;
            Assert.Equal("running", running.State);
            Assert.Equal(attempt, running.Attempts);
            Assert.Null(running.NextRetryAt);
            long failedAt = startedAt + 1;
            Assert.True(store.FailJob(fence, "extract-failed", failedAt));
            var failed = store.Job(jobId)!;
            Assert.Equal("failed", failed.State);
            Assert.Equal(attempt, failed.Attempts);
            Assert.Null(failed.LeaseToken);
            Assert.Null(failed.LeaseUntil);
            Assert.Equal(published.Id, store.Source(sourceId)!.PublishedRevisionId);
            Assert.Equal(new[] { "kept" }, store.Chunks(sourceId).Select(c => c.Text));
            if (attempt < last)
            {
                long retryAt = failedAt + (1L << attempt) * 30;
                Assert.Equal(retryAt, failed.NextRetryAt);
                Assert.Equal(0, store.RequeueRetryableJobs(retryAt - 1));
                Assert.Null(store.ClaimJob(retryAt - 1, $"too-early-{attempt}", jobId));
                Assert.Equal(1, store.RequeueRetryableJobs(retryAt));
                var queued = store.Job(jobId)!;
                Assert.Equal("queued", queued.State);
                Assert.Equal(attempt, queued.Attempts);
                Assert.Equal(retryAt, queued.NextRetryAt);
                string token = $"attempt-{attempt + 1}";
                var claimed = store.ClaimJob(retryAt, token, jobId)!;
                Assert.Equal(attempt + 1, claimed.Attempts);
                fence = new JobFence(jobId, token);
                startedAt = retryAt;
            }
            else
            {
                Assert.Null(failed.NextRetryAt);
                Assert.Equal(0, store.RequeueRetryableJobs(failedAt + 10_000));
                Assert.Null(store.ClaimJob(failedAt + 10_000, "sixth", jobId));
                Assert.Equal(last, store.Job(jobId)!.Attempts);
            }
        }
        long retryId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{sourceId}", published.Id),
            startedAt + 20_000);
        Assert.NotEqual(jobId, retryId);
        Assert.Equal(0, store.Job(retryId)!.Attempts);
        Assert.Equal("failed", store.Job(jobId)!.State);
    }

    [Fact]
    public async Task EveryJobTransition()
    {
        var all = SharedFixtures.Json("contracts/ingestion-jobs-v1.json");
        Assert.Equal("ingestion-jobs", all.GetProperty("contract").GetString());
        var rows = all.GetProperty("cases").EnumerateArray().ToArray();
        Assert.All(rows, r => Assert.Contains(Op(r), new[] { "jobs", "admission", "schedule" }));
        Assert.Equal(rows.Length, rows.Select(Name).Distinct().Count());
        var names = new List<string>();
        foreach (var row in Cases("jobs"))
        {
            names.Add(Name(row));
            using var harness = new JobHarness(row);
            await harness.ReplayAsync();
        }
        Assert.Equal(new[] { "two-claims", "restart-expiry", "renew-60", "stale-fail", "stale-publish", "token-unique",
            "exhausted-user-retry" }, names);
    }

    [Fact]
    public async Task TwoDatabaseClaimers()
    {
        // Real two-connection races with a barrier immediately before the atomic claim.
        for (int round = 0; round < 10; round++)
        {
            using var harness = new JobHarness(Cases("jobs").Single(c => Name(c) == "two-claims"));
            await harness.ReplayAsync();
        }

        // Two queues on two stores racing for one candidate: exactly one executes.
        using var dir = new TempDir();
        string path = Path.Combine(dir.Path, "db.sqlite");
        long sourceId;
        using (var seed = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null))
        {
            long notebook = seed.CreateNotebook("race").Id!.Value;
            sourceId = seed.CreateSource(notebook, SourceType.Text, "s", null, null).Id!.Value;
            seed.EnqueueJob(new IngestJobDraft("extract", $"source:{sourceId}", null), 0);
        }
        using var a = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null);
        using var b = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null);
        using var barrier = new Barrier(2);
        int executed = 0;
        Task<bool> Run(NotebookStore store, string token) => Task.Run(async () =>
        {
            var queue = new JobQueue(store, new ManualClock(0), new IngestionAdmission(), () => { barrier.SignalAndWait(); return token; });
            return await queue.RunOneAsync("extract", 0, (_, _, _) => { Interlocked.Increment(ref executed); return Task.CompletedTask; });
        });
        var results = await Task.WhenAll(Run(a, "queue-a"), Run(b, "queue-b"));
        Assert.Equal(1, results.Count(r => r));
        Assert.Equal(1, executed);
        Assert.Contains(a.Job(1)!.LeaseToken, new[] { "queue-a", "queue-b" });
    }

    [Fact]
    public async Task RenewalAndRestart()
    {
        using var dir = new TempDir();
        string path = Path.Combine(dir.Path, "db.sqlite");
        long jobId;
        using (var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null))
        {
            long notebook = store.CreateNotebook("renew").Id!.Value;
            long source = store.CreateSource(notebook, SourceType.Text, "s", null, null).Id!.Value;
            jobId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
            var clock = new ManualClock(0);
            var queue = new JobQueue(store, clock, new IngestionAdmission(), () => "lease-a");
            var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            var run = queue.RunOneAsync("extract", 10, async (job, fence, ct) =>
            {
                started.SetResult();
                await release.Task.WaitAsync(ct);
            });
            await started.Task;
            Assert.Equal(300, store.Job(jobId)!.LeaseUntil);
            await clock.WaiterAt(60);
            clock.Advance(60);
            await clock.WaiterAt(120);
            Assert.Equal(360, store.Job(jobId)!.LeaseUntil);
            Assert.Equal(1, store.Job(jobId)!.Attempts);
            clock.Advance(120);
            await clock.WaiterAt(180);
            Assert.Equal(420, store.Job(jobId)!.LeaseUntil);
            // Shutdown cancels the attempt but leaves the job to lease recovery; it is not discarded.
            await queue.StopAsync();
            Assert.True(await run);
            Assert.Equal("running", store.Job(jobId)!.State);
            Assert.False(await queue.RunOneAsync("extract", 10, (_, _, _) => Task.CompletedTask));
        }
        // A replacement process recovers the expired lease and claims a second attempt.
        using (var replacement = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: null))
        {
            var clock = new ManualClock(419);
            var queue = new JobQueue(replacement, clock, new IngestionAdmission(), () => "lease-b");
            Assert.False(await queue.RunOneAsync("extract", 10, (_, _, _) => Task.CompletedTask));
            Assert.Equal("running", replacement.Job(jobId)!.State);
            clock.Advance(420);
            Assert.False(await queue.RunOneAsync("extract", 10, (_, _, _) => Task.CompletedTask));
            var expired = replacement.Job(jobId)!;
            Assert.Equal(("queued", 1, 480L), (expired.State, expired.Attempts, expired.NextRetryAt!.Value));
            clock.Advance(480);
            IngestJob? seen = null;
            Assert.True(await queue.RunOneAsync("extract", 10, (job, _, _) => { seen = job; return Task.CompletedTask; }));
            Assert.Equal(2, seen!.Attempts);
            Assert.Equal("lease-b", seen.LeaseToken);
        }
    }

    [Fact]
    public async Task ThreeAttemptsAndNewUserRetry()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("five").Id!.Value;
        long source = store.CreateSource(notebook, SourceType.Text, "s", null, null).Id!.Value;
        long jobId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        var clock = new ManualClock(0);
        int token = 0;
        var queue = new JobQueue(store, clock, new IngestionAdmission(), () => $"attempt-{++token}");
        const int last = ExtractionRetryBudget.ExtractMaxAttempts; // ingestion-retry-cap-v1: the third failure is terminal
        for (int attempt = 1; attempt <= last; attempt++)
        {
            Assert.True(await queue.RunOneAsync("extract", 10, (_, _, _) => throw new FolderIngestionException("corruptArchive")));
            var failed = store.Job(jobId)!;
            Assert.Equal(("failed", attempt, "corruptArchive"), (failed.State, failed.Attempts, failed.Error));
            if (attempt < last)
            {
                Assert.False(await queue.RunOneAsync("extract", 10, (_, _, _) => Task.CompletedTask));
                clock.Advance(failed.NextRetryAt!.Value);
            }
            else Assert.Null(failed.NextRetryAt);
        }
        clock.Advance(100_000);
        Assert.False(await queue.RunOneAsync("extract", 10, (_, _, _) => Task.CompletedTask));
        Assert.Equal(last, token);
        Assert.Equal(SourceStatus.Error, store.Source(source)!.Status);
        long retry = store.RetryExhaustedJob(jobId, clock.Now)!.Value;
        Assert.NotEqual(jobId, retry);
        Assert.Equal(("queued", 0), (store.Job(retry)!.State, store.Job(retry)!.Attempts));
        Assert.Equal(("failed", last), (store.Job(jobId)!.State, store.Job(jobId)!.Attempts));
        Assert.Equal(SourceStatus.Pending, store.Source(source)!.Status);
        Assert.Null(store.RetryExhaustedJob(retry, clock.Now)); // not exhausted: no new row
        Assert.True(await queue.RunOneAsync("extract", 10, (job, _, _) => { Assert.Equal(retry, job.Id); return Task.CompletedTask; }));
    }

    [Fact]
    public async Task MemoryAndConcurrency()
    {
        foreach (string name in new[] { "concurrency-two", "memory-one", "oversize-runs-alone", "memory-pressure-clears" })
            await new AdmissionHarness(Cases("admission").Single(c => Name(c) == name)).ReplayAsync();

        var limits = IngestionLimits.Defaults;
        Assert.Equal(100 * 4 + (long)limits.TextScalars * 8 + (long)limits.Chunks * 256,
            IngestionAdmission.ExtractionReservation(100, "md", limits));
        Assert.Equal(limits.FileBytes * 4 + (long)limits.TextScalars * 8 + (long)limits.Chunks * 256 + limits.OfficeBytes,
            IngestionAdmission.ExtractionReservation(long.MaxValue, "docx", limits));
        // A maximum Office/PDF extraction occupies the default budget alone.
        Assert.True(2 * IngestionAdmission.ExtractionReservation(limits.FileBytes, "pdf", limits) > 536870912);

        // The queue reserves before claiming: a third extraction neither starts nor claims its job.
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("mem").Id!.Value;
        var jobs = Enumerable.Range(0, 3).Select(i =>
        {
            long source = store.CreateSource(notebook, SourceType.Text, $"s{i}", null, null).Id!.Value;
            return store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        }).ToArray();
        var admission = new IngestionAdmission();
        var queue = new JobQueue(store, new ManualClock(0), admission);
        var gates = jobs.ToDictionary(id => id, _ => new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
        var started = new List<long>();
        Func<IngestJob, JobFence, CancellationToken, Task> execute = async (job, _, ct) =>
        {
            lock (started) started.Add(job.Id);
            await gates[job.Id].Task.WaitAsync(ct);
        };
        var first = queue.RunOneAsync("extract", 10, execute);
        var second = queue.RunOneAsync("extract", 10, execute);
        await WaitUntil(() => { lock (started) return started.Count == 2; });
        var third = queue.RunOneAsync("extract", 10, execute);
        await WaitUntil(() => admission.WaitingBytes.Count == 1);
        Assert.Equal(0, store.Job(jobs[2])!.Attempts);
        Assert.Equal(2, admission.Reservations.Count);
        gates[jobs[0]].SetResult();
        Assert.True(await first);
        await WaitUntil(() => { lock (started) return started.Count == 3; });
        Assert.Equal(1, store.Job(jobs[2])!.Attempts);
        gates[jobs[1]].SetResult();
        gates[jobs[2]].SetResult();
        Assert.True(await second);
        Assert.True(await third);
        Assert.Empty(admission.Reservations);
    }

    [Fact]
    public async Task ChatTokensAndCancellation()
    {
        foreach (string name in new[] { "chat-two-tokens", "chat-query-unblocked", "cancel-releases", "cancel-waiter" })
            await new AdmissionHarness(Cases("admission").Single(c => Name(c) == name)).ReplayAsync();

        // User cancellation of a running refresh is fenced and never leaves the source refresh-pending forever.
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("cancel").Id!.Value;
        long source = store.CreateSource(notebook, SourceType.Text, "s", null, null).Id!.Value;
        var revision = store.CommitForegroundRevision(source, new RevisionDraft("h", "old", 1, 2), ScalarChunker.Chunk("old"), 0, "seed");
        long jobId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", revision.Id), 1);
        var admission = new IngestionAdmission();
        var queue = new JobQueue(store, new ManualClock(1), admission, () => "lease-a");
        using var user = new CancellationTokenSource();
        var running = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var run = queue.RunOneAsync("extract", 10, async (_, _, ct) =>
        {
            running.SetResult();
            await Task.Delay(Timeout.Infinite, ct);
        }, user.Token);
        await running.Task;
        Assert.Equal(SourceStatus.Chunking, store.Source(source)!.Status);
        user.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
        Assert.Equal("cancelled", store.Job(jobId)!.State);
        var cancelled = store.Source(source)!;
        Assert.Equal((SourceStatus.Error, "cancelled"), (cancelled.Status, cancelled.Error));
        var coverage = store.Coverage(notebook, new RetrievalScope.All());
        Assert.Equal((1, 0, 1), (coverage.Searchable, coverage.RefreshPending, coverage.RefreshError));
        Assert.Empty(admission.Reservations);
        // JobQueue.CancelAsync cancels a locally running attempt through its fence; per-job reservations size permits.
        var second = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", revision.Id), 3);
        long reserved = 0;
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var queue2 = new JobQueue(store, new ManualClock(3), admission, () => "lease-b");
        var local = queue2.RunOneAsync("extract", (job, _) => Task.FromResult(reserved = 1234 + job.Id), async (_, _, ct) =>
        {
            started.SetResult();
            await Task.Delay(Timeout.Infinite, ct);
        });
        await started.Task;
        Assert.Equal(1234 + second, Assert.Single(admission.Reservations).Bytes);
        Assert.True(await queue2.CancelAsync(second));
        Assert.True(await local);
        Assert.Equal("cancelled", store.Job(second)!.State);
        Assert.Empty(admission.Reservations);
        Assert.Equal(1234 + second, reserved);
        // A queued job is cancelled without a fence.
        var third = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", revision.Id), 4);
        Assert.True(await queue2.CancelAsync(third));
        Assert.Equal("cancelled", store.Job(third)!.State);
        // A stale fence cannot cancel (or mark) anything.
        Assert.False(store.CancelIngestJob(jobId, new JobFence(jobId, "lease-a"), 2));
        Assert.False(store.CancelIngestJob(jobId, null, 2)); // a cancelled (or running) job needs no unfenced cancel
    }

    [Fact]
    public async Task NoResourceLeakOnLostLease()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("lost").Id!.Value;
        long source = store.CreateSource(notebook, SourceType.Text, "s", null, null).Id!.Value;
        long jobId = store.EnqueueJob(new IngestJobDraft("extract", $"source:{source}", null), 0);
        var clock = new ManualClock(0);
        var admission = new IngestionAdmission();
        var queue = new JobQueue(store, clock, admission, () => "lease-a");
        var running = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        bool observedCancel = false;
        var run = queue.RunOneAsync("extract", 10, async (_, _, ct) =>
        {
            running.SetResult();
            try { await Task.Delay(Timeout.Infinite, ct); }
            catch (OperationCanceledException) { observedCancel = true; throw; }
        });
        await running.Task;
        await clock.WaiterAt(60);
        // A replacement owner took the job; the old renewal fails and cancels the attempt.
        lock (store.Gate) store.Connection.Execute("UPDATE ingest_jobs SET lease_token='lease-b' WHERE id=$jobId", new { jobId });
        clock.Advance(60);
        Assert.True(await run);
        Assert.True(observedCancel);
        var job = store.Job(jobId)!;
        Assert.Equal(("running", "lease-b", 300L, (string?)null), (job.State, job.LeaseToken, job.LeaseUntil!.Value, job.Error));
        Assert.Empty(admission.Reservations);
        Assert.Equal(0, clock.PendingWaiters);
        Assert.Equal(SourceStatus.Chunking, store.Source(source)!.Status);
    }

    private static async Task WaitUntil(Func<bool> condition)
    {
        for (int i = 0; i < 2000 && !condition(); i++) await Task.Yield();
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            Assert.True(DateTime.UtcNow < deadline, "condition not reached");
            await Task.Delay(1);
        }
    }

    private sealed class JobHarness : IDisposable
    {
        private readonly JsonElement _row;
        private readonly TempDir _dir = new();
        private readonly string _path;
        private readonly Dictionary<string, string> _normalize = new(StringComparer.Ordinal);
        private NotebookStore _store;

        public JobHarness(JsonElement row)
        {
            _row = row;
            _path = Path.Combine(_dir.Path, "db.sqlite");
            _store = new NotebookStore(new StorePath(_path), configuredEmbeddingModelKey: null);
            var input = row.GetProperty("input");
            if (input.TryGetProperty("tokenNormalization", out var normalization))
                foreach (var p in normalization.EnumerateObject()) _normalize[p.Name] = p.Value.GetString()!;
            foreach (var notebook in input.GetProperty("notebookIds").EnumerateArray())
                Assert.Equal(notebook.GetInt64(), _store.CreateNotebook("jobs").Id);
            foreach (var folder in input.GetProperty("folderIds").EnumerateArray())
                Assert.Equal(folder.GetInt64(), _store.CreateFolder(1, new FolderDraft($"/f{folder.GetInt64()}", "F", ["md"], [], "{}", "cp1250", true),
                    new FixedIdentity(new FolderIdentity("v", [$"f{folder.GetInt64()}"], "r")), 0).Id);
            lock (_store.Gate)
            {
                var c = _store.Connection;
                using var tx = c.BeginTransaction();
                foreach (var s in input.GetProperty("sources").EnumerateArray())
                    c.Execute("""
                        INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                        VALUES($id,$notebook,'markdown','s',$status,'2026-01-01 00:00:00.000',$folder,$path,$availability,$eligible)
                        """, new
                    {
                        id = s.GetProperty("id").GetInt64(), notebook = s.GetProperty("notebookId").GetInt64(),
                        status = s.GetProperty("status").GetString(), folder = s.GetProperty("folderId").GetInt64(),
                        path = $"s{s.GetProperty("id").GetInt64()}.md", availability = s.GetProperty("availability").GetString(),
                        eligible = s.GetProperty("eligible").GetBoolean()
                    }, tx);
                foreach (var r in input.GetProperty("revisions").EnumerateArray())
                {
                    long id = r.GetProperty("id").GetInt64();
                    long source = r.GetProperty("sourceId").GetInt64();
                    c.Execute("""
                        INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                        VALUES($id,$source,1,'h',$text,1,2,'2026-01-01 00:00:00.000')
                        """, new { id, source, text = r.GetProperty("canonicalText").GetString() }, tx);
                    int ord = 0;
                    foreach (var ch in r.GetProperty("chunks").EnumerateArray())
                        c.Execute("""
                            INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end)
                            VALUES($chunk,$source,$id,$ord,$text,1,$start,$end)
                            """, new
                        {
                            chunk = ch.GetProperty("id").GetInt64(), source, id, ord = ord++, text = ch.GetProperty("text").GetString(),
                            start = ch.GetProperty("start").GetInt64(), end = ch.GetProperty("end").GetInt64()
                        }, tx);
                }
                foreach (var s in input.GetProperty("sources").EnumerateArray())
                    c.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id", new
                    {
                        id = s.GetProperty("id").GetInt64(), current = Long(s, "currentRevision"), published = Long(s, "publishedRevisionId")
                    }, tx);
                foreach (var j in input.GetProperty("jobs").EnumerateArray())
                    c.Execute("""
                        INSERT INTO ingest_jobs(id,kind,target,target_revision,attempts,next_retry_at,state,lease_until,lease_token,error,options_json)
                        VALUES($id,$kind,$target,$revision,$attempts,$retry,$state,$until,$token,$error,$options)
                        """, new
                    {
                        id = j.GetProperty("id").GetInt64(), kind = j.GetProperty("kind").GetString(), target = j.GetProperty("target").GetString(),
                        revision = Long(j, "targetRevision"), attempts = j.GetProperty("attempts").GetInt64(), retry = Long(j, "nextRetryAt"),
                        state = j.GetProperty("state").GetString(), until = Long(j, "leaseUntil"), token = Str(j, "leaseToken"),
                        error = Str(j, "error"), options = j.GetProperty("options").GetRawText()
                    }, tx);
                tx.Commit();
            }
        }

        public void Dispose()
        {
            _store.Dispose();
            _dir.Dispose();
        }

        public async Task ReplayAsync()
        {
            int index = 0;
            foreach (var e in Events(_row))
            {
                string op = Op(e);
                Assert.Contains(op, JobOps);
                long at = e.GetProperty("at").GetInt64();
                var before = Published();
                var extra = new Dictionary<string, object?>();
                bool accepted = true;
                switch (op)
                {
                    case "claim":
                        accepted = _store.ClaimJob(at, Str(e, "leaseToken")!, e.GetProperty("jobId").GetInt64()) is not null;
                        break;
                    case "claim-race":
                        Assert.Equal("before-atomic-claim", Str(e, "barrier"));
                        var contenders = e.GetProperty("contenders").EnumerateArray().ToArray();
                        Assert.Equal(2, contenders.Length);
                        using (var other = new NotebookStore(new StorePath(_path), configuredEmbeddingModelKey: null))
                        using (var barrier = new Barrier(2))
                        {
                            var stores = new[] { _store, other };
                            var results = await Task.WhenAll(contenders.Select((c, i) => Task.Run(() =>
                            {
                                barrier.SignalAndWait();
                                return stores[i].ClaimJob(at, Str(c, "leaseToken")!, e.GetProperty("jobId").GetInt64());
                            })));
                            string stored = _store.Job(e.GetProperty("jobId").GetInt64())!.LeaseToken!;
                            Assert.Single(contenders, c => Str(c, "leaseToken") == stored);
                            extra["winnerTokenCount"] = 1;
                            extra["acceptedCount"] = results.Count(r => r is not null);
                            extra["rejectedCount"] = results.Count(r => r is null);
                        }
                        break;
                    case "claim-many":
                        var sequence = new Queue<string>(e.GetProperty("tokenSequence").EnumerateArray().Select(t => t.GetString()!));
                        var issued = new List<string>();
                        var queue = new JobQueue(_store, new ManualClock(at), new IngestionAdmission(), () =>
                        {
                            string token = sequence.Dequeue();
                            issued.Add(token);
                            return token;
                        });
                        var claimed = new List<long>();
                        foreach (var _ in e.GetProperty("jobIds").EnumerateArray())
                            Assert.True(await queue.RunOneAsync("extract", 0, (job, _, _) => { claimed.Add(job.Id); return Task.CompletedTask; }));
                        Assert.Equal(e.GetProperty("jobIds").EnumerateArray().Select(j => j.GetInt64()), claimed);
                        Assert.Equal(issued.Count, issued.Distinct().Count());
                        extra["issuedLeaseTokens"] = issued;
                        break;
                    case "recover-expired":
                        if (Str(e, "process") == "replacement")
                        {
                            _store.Dispose();
                            _store = new NotebookStore(new StorePath(_path), configuredEmbeddingModelKey: null);
                        }
                        _store.RecoverExpiredJobs(at);
                        break;
                    case "renew":
                        accepted = _store.RenewJob(Fence(e), at);
                        break;
                    case "fail":
                        accepted = _store.FailJob(Fence(e), Str(e, "error")!, at);
                        break;
                    case "publish":
                        var draft = e.GetProperty("revisionDraft");
                        string text = draft.GetProperty("canonicalText").GetString()!;
                        accepted = _store.CommitExtraction(101, new RevisionDraft("new-hash", text, 1, 2),
                            draft.GetProperty("chunks").EnumerateArray().Select(ch => new RevisionChunkDraft(ch.GetProperty("text").GetString()!,
                                1, null, ch.GetProperty("start").GetInt32(), ch.GetProperty("end").GetInt32(), null, false)).ToArray(),
                            Fence(e), at) is not null;
                        break;
                    case "user-retry":
                        Assert.Equal(e.GetProperty("newJobId").GetInt64(), _store.RetryExhaustedJob(e.GetProperty("jobId").GetInt64(), at));
                        break;
                    case "requeue-retryable":
                        _store.RequeueRetryableJobs(at);
                        break;
                    default:
                        Assert.Fail("Unknown job operation " + op);
                        break;
                }
                var published = Published().Where(p => !before.Contains(p)).Select(p => p.Revision).Order().ToArray();
                AssertJson(e.GetProperty("expected"), Project(accepted, published, extra), $"{Name(_row)} event {index}");
                index++;
            }
        }

        private static JobFence Fence(JsonElement e) => new(e.GetProperty("jobId").GetInt64(), Str(e, "leaseToken")!);

        private HashSet<(long Source, long Revision)> Published()
        {
            lock (_store.Gate)
                return _store.Connection.Query<(long, long)>(
                    "SELECT id,published_revision_id FROM sources WHERE published_revision_id IS NOT NULL").ToHashSet();
        }

        private JsonElement Project(bool accepted, long[] published, Dictionary<string, object?> extra)
        {
            lock (_store.Gate)
            {
                var c = _store.Connection;
                var result = new Dictionary<string, object?>
                {
                    ["accepted"] = accepted,
                    ["publishedRevisionIds"] = published,
                    ["jobs"] = c.Query("SELECT * FROM ingest_jobs ORDER BY id").Select(j => new
                    {
                        id = (long)j.id, kind = (string)j.kind, target = (string)j.target, targetRevision = (long?)j.target_revision,
                        state = (string)j.state, attempts = (long)j.attempts,
                        leaseToken = j.lease_token is null ? null : _normalize.GetValueOrDefault((string)j.lease_token, (string)j.lease_token),
                        leaseUntil = (long?)j.lease_until, nextRetryAt = (long?)j.next_retry_at, error = (string?)j.error,
                        options = JsonDocument.Parse((string)j.options_json).RootElement.Clone()
                    }).ToArray(),
                    ["sources"] = c.Query("SELECT * FROM sources ORDER BY id").Select(s => new
                    {
                        id = (long)s.id, notebookId = (long)s.notebook_id, folderId = (long?)s.folder_id,
                        availability = (string)s.availability, eligible = (long)s.eligible != 0, status = (string)s.status,
                        currentRevision = (long?)s.current_revision, publishedRevisionId = (long?)s.published_revision_id
                    }).ToArray()
                };
                foreach (var (key, value) in extra) result[key] = value;
                return JsonSerializer.SerializeToElement(result);
            }
        }
    }

    private sealed class AdmissionHarness(JsonElement row)
    {
        private readonly IngestionAdmission _admission = new(row.GetProperty("input").GetProperty("maxExtractions").GetInt32(),
            row.GetProperty("input").GetProperty("memoryBytes").GetInt64());
        private readonly Dictionary<Guid, string> _names = new();
        private readonly Dictionary<string, Guid> _chat = new(StringComparer.Ordinal);
        private readonly List<(string RequestId, long Bytes, string Token, Task<Guid> Task, CancellationTokenSource Cts)> _pending = [];
        private readonly List<(string BatchId, Task Task)> _batches = [];
        private readonly List<string> _backgroundWaiters = [];
        private readonly List<string> _started = [];
        private readonly List<string> _queries = [];
        private readonly List<string> _cancelled = [];
        private int _providerCalls;

        public async Task ReplayAsync()
        {
            var seed = row.GetProperty("input").GetProperty("seed");
            foreach (string key in new[] { "reservations", "waiters", "chatTokens" })
                Assert.Equal(0, seed.GetProperty(key).GetArrayLength());
            Assert.False(seed.GetProperty("memoryPressure").GetBoolean());
            int index = 0;
            foreach (var e in Events(row))
            {
                string op = Op(e);
                Assert.Contains(op, AdmissionOps);
                switch (op)
                {
                    case "acquire":
                        var cts = new CancellationTokenSource();
                        _pending.Add((Str(e, "requestId")!, e.GetProperty("bytes").GetInt64(), Str(e, "token")!,
                            _admission.AcquireExtractionAsync(e.GetProperty("bytes").GetInt64(), cts.Token), cts));
                        break;
                    case "release":
                        var released = _names.Where(p => p.Value == Str(e, "token")).Select(p => p.Key).ToArray();
                        if (Str(e, "reason") == "duplicate-release") Assert.DoesNotContain(_admission.Reservations, r => released.Contains(r.Token));
                        foreach (var token in released) _admission.ReleaseExtraction(token);
                        break;
                    case "cancel-waiter":
                        var waiter = _pending.Single(p => p.RequestId == Str(e, "requestId"));
                        waiter.Cts.Cancel();
                        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => waiter.Task);
                        _pending.Remove(waiter);
                        _cancelled.Add(waiter.RequestId);
                        break;
                    case "memory-pressure":
                        _admission.SetMemoryPressure(e.GetProperty("blocked").GetBoolean());
                        break;
                    case "begin-chat":
                        _chat[Str(e, "token")!] = _admission.BeginChat();
                        break;
                    case "end-chat":
                        _admission.EndChat(_chat[Str(e, "token")!]);
                        _chat.Remove(Str(e, "token")!);
                        break;
                    case "background-batch":
                        _batches.Add((Str(e, "batchId")!, _admission.WaitForBackgroundBatchAsync()));
                        _backgroundWaiters.Add(Str(e, "batchId")!);
                        break;
                    case "query-embedding":
                        // Question embedding never consults the background gate.
                        _queries.Add(Str(e, "text")!);
                        _providerCalls++;
                        break;
                }
                Settle();
                AssertJson(e.GetProperty("expected"), Project(), $"{Name(row)} event {index++}");
            }
            foreach (var p in _pending) p.Cts.Dispose();
        }

        private void Settle()
        {
            foreach (var p in _pending.Where(p => p.Task.IsCompletedSuccessfully).ToArray())
            {
                _names[p.Task.Result] = p.Token;
                _pending.Remove(p);
            }
            foreach (var b in _batches.Where(b => b.Task.IsCompletedSuccessfully).ToArray())
            {
                _batches.Remove(b);
                _backgroundWaiters.Remove(b.BatchId);
                _started.Add(b.BatchId);
                _providerCalls++;
            }
            Assert.Equal(_pending.Select(p => p.Bytes), _admission.WaitingBytes);
            Assert.Equal(_backgroundWaiters.Count, _admission.BackgroundWaiters);
        }

        private JsonElement Project() => JsonSerializer.SerializeToElement(new
        {
            reservations = _admission.Reservations.Select(r => new { token = _names[r.Token], bytes = r.Bytes }).ToArray(),
            waiters = _pending.Select(p => new { requestId = p.RequestId, bytes = p.Bytes, token = p.Token }).ToArray(),
            chatTokens = _admission.ChatTokens.Select(t => _chat.Single(p => p.Value == t).Key).ToArray(),
            backgroundWaiters = _backgroundWaiters.ToArray(),
            startedBackgroundBatches = _started.ToArray(),
            queryInputs = _queries.ToArray(),
            cancelledWaiters = _cancelled.ToArray(),
            providerCallCount = _providerCalls,
            memoryPressure = _admission.MemoryPressure
        });
    }

    /// <summary>Deterministic lease clock: waits complete only when the test advances time.</summary>
    /// <summary>
    /// A candidate whose reservation (or claim) throws must not stall every later job of its kind: it is skipped for
    /// <see cref="JobQueue.PreClaimDeferral"/> lease-clock seconds (ingestion-memory-pressure-v1 §5).
    /// </summary>
    [Fact]
    public async Task ThrowingCandidateDoesNotStallLaterJobs()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("poison").Id!.Value;
        long a = store.CreateSource(notebook, SourceType.Text, "a", null, null).Id!.Value;
        long b = store.CreateSource(notebook, SourceType.Text, "b", null, null).Id!.Value;
        long poisoned = store.EnqueueJob(new IngestJobDraft("extract", $"source:{a}", null), 0);
        long healthy = store.EnqueueJob(new IngestJobDraft("extract", $"source:{b}", null), 0);
        var clock = new ManualClock(0);
        var admission = new IngestionAdmission();
        var queue = new JobQueue(store, clock, admission);
        Func<IngestJob, CancellationToken, Task<long>> reservation = (job, _) =>
            job.Id == poisoned ? throw new InvalidDataException("poison") : Task.FromResult(1L);
        var ran = new List<long>();
        Func<IngestJob, JobFence, CancellationToken, Task> execute = (job, _, _) => { lock (ran) ran.Add(job.Id); return Task.CompletedTask; };

        await Assert.ThrowsAsync<InvalidDataException>(() => queue.RunOneAsync("extract", reservation, execute));
        Assert.True(await queue.RunOneAsync("extract", reservation, execute));
        Assert.Equal([healthy], ran);
        Assert.False(await queue.RunOneAsync("extract", reservation, execute));
        Assert.Equal(("queued", 0), (store.Job(poisoned)!.State, store.Job(poisoned)!.Attempts));
        Assert.Empty(admission.Reservations);
        clock.Advance(JobQueue.PreClaimDeferral);
        await Assert.ThrowsAsync<InvalidDataException>(() => queue.RunOneAsync("extract", reservation, execute));
        Assert.Equal([healthy], ran);
    }

    private sealed class ManualClock(long now) : IIngestLeaseClock
    {
        private readonly object _gate = new();
        private readonly List<(long Deadline, TaskCompletionSource Completion)> _waits = [];
        private long _now = now;

        public long Now { get { lock (_gate) return _now; } }
        public int PendingWaiters { get { lock (_gate) return _waits.Count(w => !w.Completion.Task.IsCompleted); } }

        public Task WaitUntilAsync(long deadline, CancellationToken ct)
        {
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            lock (_gate)
            {
                if (deadline <= _now) return Task.CompletedTask;
                _waits.Add((deadline, completion));
            }
            ct.Register(() =>
            {
                lock (_gate) _waits.RemoveAll(w => w.Completion == completion);
                completion.TrySetCanceled(ct);
            });
            return completion.Task;
        }

        public void Advance(long to)
        {
            (long, TaskCompletionSource)[] due;
            lock (_gate)
            {
                _now = to;
                due = _waits.Where(w => w.Deadline <= to).ToArray();
                _waits.RemoveAll(w => w.Deadline <= to);
            }
            foreach (var (_, completion) in due) completion.TrySetResult();
        }

        public Task WaiterAt(long deadline) => WaitUntil(() =>
        {
            lock (_gate) return _waits.Any(w => w.Deadline == deadline);
        });
    }

    private sealed class FixedIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public FolderIdentity Resolve(string rootPath) => identity;
    }

    private sealed class TempDir : IDisposable
    {
        public string Path { get; } = Directory.CreateDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(),
            "wp6-queue-" + Guid.NewGuid().ToString("N"))).FullName;
        public void Dispose()
        {
            try { Directory.Delete(Path, true); } catch (IOException) { }
        }
    }

    private static IEnumerable<JsonElement> Cases(string operation) =>
        SharedFixtures.Json("contracts/ingestion-jobs-v1.json").GetProperty("cases").EnumerateArray().Where(c => Op(c) == operation).ToArray();
    private static IEnumerable<JsonElement> Events(JsonElement row) => row.GetProperty("input").GetProperty("events").EnumerateArray().ToArray();
    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string Op(JsonElement row) => row.GetProperty("operation").GetString()!;
    private static string? Str(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    private static long? Long(JsonElement e, string key) => e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;

    private static void AssertJson(JsonElement expected, JsonElement actual, string path)
    {
        if (expected.ValueKind == JsonValueKind.Number)
        {
            Assert.True(actual.ValueKind == JsonValueKind.Number && expected.GetInt64() == actual.GetInt64(), $"{path}: expected {expected} got {actual}");
            return;
        }
        Assert.True(expected.ValueKind == actual.ValueKind, $"{path}: expected {expected} got {actual}");
        switch (expected.ValueKind)
        {
            case JsonValueKind.Object:
                var keys = expected.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal).ToArray();
                Assert.True(keys.SequenceEqual(actual.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal)),
                    $"{path}: keys expected [{string.Join(",", keys)}] got {actual}");
                foreach (string key in keys) AssertJson(expected.GetProperty(key), actual.GetProperty(key), path + "." + key);
                break;
            case JsonValueKind.Array:
                Assert.True(expected.GetArrayLength() == actual.GetArrayLength(), $"{path}: expected {expected} got {actual}");
                int index = 0;
                foreach (var (e, a) in expected.EnumerateArray().Zip(actual.EnumerateArray()))
                    AssertJson(e, a, $"{path}[{index++}]");
                break;
            case JsonValueKind.String:
                Assert.True(expected.GetString() == actual.GetString(), $"{path}: expected {expected} got {actual}");
                break;
        }
    }
}
