using System.Text.Json;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class JobHandoffTests
{
    public static IEnumerable<object[]> HandoffCases()
    {
        var contract = RetryCapSupersession.Document("storage-job-handoff-v1.json");
        Assert.Equal("storage-job-handoff", contract.GetProperty("contract").GetString());
        Assert.Equal(1, contract.GetProperty("version").GetInt32());
        var visited = new HashSet<string>();
        foreach (var fixture in contract.GetProperty("cases").EnumerateArray())
        {
            string name = fixture.GetProperty("name").GetString()!;
            Assert.True(visited.Add(name), name);
            yield return [name];
        }
        Assert.NotEmpty(visited);
    }

    [Theory]
    [MemberData(nameof(HandoffCases))]
    public void SharedHandoffCases(string name)
    {
        var contract = RetryCapSupersession.Document("storage-job-handoff-v1.json");
        var fixture = contract.GetProperty("cases").EnumerateArray()
            .Single(c => c.GetProperty("name").GetString() == name);
        Assert.Equal("trace", fixture.GetProperty("operation").GetString());
        using var store = V19TestStore.Create();
        lock (store.Gate)
        {
            foreach (var sql in contract.GetProperty("setupSql").EnumerateArray())
                store.Connection.Execute(sql.GetString()!);
            if (fixture.TryGetProperty("setupSql", out var setup))
                foreach (var sql in setup.EnumerateArray()) store.Connection.Execute(sql.GetString()!);
        }
        var input = fixture.GetProperty("input");
        var draft = input.GetProperty("draft");
        var jobDraft = new IngestJobDraft(draft.GetProperty("kind").GetString()!,
            draft.GetProperty("target").GetString()!, OptionalLong(draft, "targetRevision"),
            draft.GetProperty("optionsJSON").GetString()!);
        long id = store.EnqueueJob(jobDraft, input.GetProperty("enqueueAt").GetInt64());
        var events = input.GetProperty("events").EnumerateArray().ToArray();
        var snapshots = fixture.GetProperty("expected").GetProperty("snapshots").EnumerateArray().ToArray();
        Assert.Equal(events.Length, snapshots.Length);
        for (int index = 0; index < events.Length; index++)
        {
            var e = events[index];
            var expected = snapshots[index];
            long at = e.GetProperty("at").GetInt64();
            var fence = new JobFence(id, OptionalString(e, "token") ?? "unused");
            bool accepted;
            int? requeuedCount = null, recoveredCount = null;
            switch (e.GetProperty("op").GetString())
            {
                case "claim": accepted = store.ClaimJob(at, fence.LeaseToken, id) is not null; break;
                case "fail": accepted = store.FailJob(fence, e.GetProperty("error").GetString()!, at); break;
                case "retry": accepted = store.RetryJob(id, at); break;
                case "requeue":
                    requeuedCount = store.RequeueRetryableJobs(at);
                    accepted = requeuedCount > 0;
                    break;
                case "recover":
                    recoveredCount = store.RecoverExpiredJobs(at);
                    accepted = recoveredCount > 0;
                    break;
                case "updateOptions": accepted = store.CoalesceQueuedJobOptions(id, e.GetProperty("optionsJSON").GetString()!); break;
                case "retarget": accepted = store.RetargetEmbedJob(fence, e.GetProperty("generationId").GetInt64(), at); break;
                case "complete":
                    long? generationId = OptionalLong(e, "generationId");
                    accepted = store.CompleteJob(fence, at, generationId is null ? null : $"generation:{generationId}");
                    break;
                case "setSourceError":
                    lock (store.Gate)
                        accepted = store.Connection.Execute("UPDATE sources SET status='error',error=$error WHERE id=$sourceId",
                            new { sourceId = e.GetProperty("sourceId").GetInt64(), error = e.GetProperty("error").GetString()! }) == 1;
                    break;
                case "supersedeSource":
                    long sourceId = e.GetProperty("sourceId").GetInt64();
                    store.InsertRevision(sourceId, new(e.GetProperty("contentHash").GetString()!,
                        e.GetProperty("canonicalText").GetString()!, 1, 2), at);
                    lock (store.Gate)
                        accepted = store.Connection.Execute("UPDATE sources SET status='error',error=$error WHERE id=$sourceId",
                            new { sourceId, error = e.GetProperty("error").GetString()! }) == 1;
                    break;
                case "supersedeJob":
                    long successor = store.EnqueueJob(jobDraft, at);
                    Assert.NotNull(store.ClaimJob(at, fence.LeaseToken, successor));
                    if (OptionalString(e, "error") is string error)
                        Assert.True(store.FailJob(new(successor, fence.LeaseToken), error, at));
                    accepted = true;
                    break;
                case "deleteNotebook":
                    lock (store.Gate)
                        accepted = store.Connection.Execute("DELETE FROM notebooks WHERE id=$id",
                            new { id = e.GetProperty("notebookId").GetInt64() }) == 1;
                    break;
                case "pause": store.PauseJob(id); accepted = true; break;
                case "resume": store.ResumeJob(id, at); accepted = true; break;
                default: throw new InvalidOperationException($"Unknown shared handoff event: {e.GetProperty("op").GetString()}");
            }
            var job = Assert.IsType<IngestJob>(store.Job(id));
            var actualJob = JsonSerializer.SerializeToElement(new
            {
                id = job.Id, kind = job.Draft.Kind, target = job.Draft.Target,
                targetRevision = job.Draft.TargetRevision, optionsJSON = job.Draft.OptionsJson,
                state = job.State, attempts = job.Attempts, nextRetryAt = job.NextRetryAt,
                leaseUntil = job.LeaseUntil, leaseToken = job.LeaseToken, error = job.Error
            });
            string label = $"{name} event {index}: {e.GetProperty("op").GetString()}";
            Assert.True(JsonElement.DeepEquals(expected.GetProperty("job"), actualJob),
                $"{label} job expected {expected.GetProperty("job")} actual {actualJob}");
            Assert.Equal(expected.GetProperty("accepted").GetBoolean(), accepted);
            Assert.Equal(OptionalLong(expected, "requeuedCount"), requeuedCount);
            Assert.Equal(OptionalLong(expected, "recoveredCount"), recoveredCount);
            lock (store.Gate)
            {
                var source = store.Connection.QuerySingle("""
                    SELECT id,status,error,current_revision,published_revision_id FROM sources WHERE id=$id
                    """, new { id = expected.GetProperty("source").GetProperty("id").GetInt64() });
                var actualSource = JsonSerializer.SerializeToElement(new
                {
                    id = (long)source.id, status = (string)source.status, error = (string?)source.error,
                    currentRevision = (long?)source.current_revision, publishedRevisionId = (long?)source.published_revision_id
                });
                Assert.True(JsonElement.DeepEquals(expected.GetProperty("source"), actualSource),
                    $"{label} source expected {expected.GetProperty("source")} actual {actualSource}");
                Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
            }
        }
    }

    private static long? OptionalLong(JsonElement value, string property)
        => value.TryGetProperty(property, out var item) && item.ValueKind != JsonValueKind.Null ? item.GetInt64() : null;

    private static string? OptionalString(JsonElement value, string property)
        => value.TryGetProperty(property, out var item) && item.ValueKind != JsonValueKind.Null ? item.GetString() : null;

    private static void Seed(NotebookStore store, bool hasRevision = true)
    {
        lock (store.Gate)
            store.Connection.Execute("""
                INSERT INTO notebooks(id,name,created_at,updated_at)
                VALUES(1,'one','2026-01-02 03:04:05.000','2026-01-02 03:04:05.000'),
                      (2,'two','2026-01-02 03:04:05.000','2026-01-02 03:04:05.000');
                INSERT INTO sources(id,notebook_id,type,title,status,ingested_at)
                VALUES(1,1,'text','old source','pending','2026-01-02 03:04:05.000');
                INSERT INTO folder_sources(id,notebook_id,root_path,display_name,path_identity,include_exts,ignore_globs,limits,created_at)
                VALUES(1,1,'/docs','Docs','{"volumeId":"test","components":["docs"],"rootFileId":"root-1"}','[]','[]','{}','2026-01-02 03:04:05.000');
                INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,dims,normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                VALUES(1,1,'legacy','legacy','m',2,'legacy','legacy','legacy','legacy','building','2026-01-02 03:04:05.000'),
                      (2,2,'legacy','legacy','m',2,'legacy','legacy','legacy','legacy','building','2026-01-02 03:04:05.000');
                """);
        if (hasRevision)
            store.CommitForegroundRevision(1, new("old", "old", 1, 2), [new("old", 1, null, 0, 3, null, false)], 0, "seed");
    }

    private static T Scalar<T>(NotebookStore store, string sql)
    {
        lock (store.Gate) return store.Connection.ExecuteScalar<T>(sql)!;
    }

    private static void Source(NotebookStore store, string status, string? error, long? current, long? published)
    {
        Assert.Equal(status, Scalar<string>(store, "SELECT status FROM sources WHERE id=1"));
        Assert.Equal(error, Scalar<string?>(store, "SELECT error FROM sources WHERE id=1"));
        Assert.Equal(current, Scalar<long?>(store, "SELECT current_revision FROM sources WHERE id=1"));
        Assert.Equal(published, Scalar<long?>(store, "SELECT published_revision_id FROM sources WHERE id=1"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void RetryPreservesPublishedRevisionAndDueTime(bool hasRevision)
    {
        using var store = V19TestStore.Create();
        Seed(store, hasRevision);
        long? revision = Scalar<long?>(store, "SELECT current_revision FROM sources WHERE id=1");
        long id = store.EnqueueJob(new("extract", "source:1", revision), 0);
        Assert.NotNull(store.ClaimJob(0, "first", id));
        const long failAt = 10, dueAt = 70;
        string[] statuses = ["error", "pending", "chunking"];
        Assert.True(store.FailJob(new(id, "first"), "io", failAt));
        Source(store, statuses[0], "io", revision, revision);
        var failed = store.Job(id)!;
        Assert.Equal("failed", failed.State);
        Assert.Equal(dueAt, failed.NextRetryAt);
        Assert.Equal(0, store.RequeueRetryableJobs(dueAt - 1));
        Assert.Equal(failed, store.Job(id));
        Assert.Null(store.ClaimJob(dueAt, "cannot-skip-requeue", id));
        Assert.Equal(1, store.RequeueRetryableJobs(dueAt));
        Source(store, statuses[1], null, revision, revision);
        Assert.Equal("queued", store.Job(id)!.State);
        Assert.Equal("io", store.Job(id)!.Error);
        Assert.Equal(1, store.Job(id)!.Attempts);
        Assert.Equal(dueAt, store.Job(id)!.NextRetryAt);
        Assert.Equal(0, store.RequeueRetryableJobs(dueAt));
        var claimed = Assert.IsType<IngestJob>(store.ClaimJob(dueAt, "second", id));
        Assert.Equal(2, claimed.Attempts);
        Assert.Null(claimed.NextRetryAt);
        Source(store, statuses[2], null, revision, revision);
        if (hasRevision) Assert.Equal("old", Scalar<string>(store, "SELECT text FROM source_chunks"));
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void StaleClaimAndRetryPreserveNewerError(bool hasRevision)
    {
        foreach (bool retry in new[] { false, true })
        {
            using var store = V19TestStore.Create();
            Seed(store, hasRevision);
            long? previous = Scalar<long?>(store, "SELECT current_revision FROM sources WHERE id=1");
            long id = store.EnqueueJob(new("extract", "source:1", previous), 0);
            if (retry)
            {
                Assert.NotNull(store.ClaimJob(0, "old", id));
                Assert.True(store.FailJob(new(id, "old"), "old failure", 10));
            }
            long current = store.InsertRevision(1, new("new", "new", 1, 2), 20).Id;
            const string error = "newer failure";
            lock (store.Gate) store.Connection.Execute("UPDATE sources SET status='error',error=$error WHERE id=1", new { error });
            if (retry) Assert.Equal(0, store.RequeueRetryableJobs(70));
            else Assert.Null(store.ClaimJob(70, "stale", id));
            Assert.Equal("cancelled", store.Job(id)!.State);
            Assert.Equal(retry ? 1 : 0, store.Job(id)!.Attempts);
            Assert.Null(store.Job(id)!.NextRetryAt);
            Source(store, "error", error, current, previous);
        }
    }

    [Fact]
    public void OptionsFreezeAfterFirstClaimAndRejectInvalidJson()
    {
        using var store = V19TestStore.Create();
        Seed(store);
        const string initial = "{\"verifyAll\":false}", coalesced = "{\"verifyAll\":true}";
        long id = store.EnqueueJob(new("scan", "folder:1", null, initial), 100);
        Assert.True(store.CoalesceQueuedJobOptions(id, coalesced));
        Assert.Equal(coalesced, store.Job(id)!.Draft.OptionsJson);
        store.PauseJob(id);
        Assert.False(store.CoalesceQueuedJobOptions(id, initial));
        store.ResumeJob(id, 0);
        Assert.Equal(100, store.Job(id)!.NextRetryAt);
        Assert.Null(store.ClaimJob(99, "early", id));
        Assert.NotNull(store.ClaimJob(100, "owner", id));
        Assert.False(store.CoalesceQueuedJobOptions(id, initial));
        Assert.True(store.FailJob(new(id, "owner"), "io", 101));
        Assert.False(store.CoalesceQueuedJobOptions(id, initial));
        Assert.True(store.RetryJob(id, 161));
        Assert.False(store.CoalesceQueuedJobOptions(id, initial));
        Assert.Equal(coalesced, store.Job(id)!.Draft.OptionsJson);
        long successor = store.EnqueueJob(new("scan", "folder:1", null, initial), 161);
        Assert.True(store.CoalesceQueuedJobOptions(successor, coalesced));
        Assert.Equal(1, store.Job(id)!.Attempts);
        foreach (string invalid in new[] { "", "null", "[]", "false", "{broken" })
        {
            Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.EnqueueJob(new("scan", "folder:1", null, invalid), 0)).Code);
            Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.CoalesceQueuedJobOptions(successor, invalid)).Code);
        }
    }

    [Fact]
    public void RetargetAndCompleteValidateFenceNotebookAndTarget()
    {
        using var store = V19TestStore.Create();
        Seed(store);
        const string options = "{\"selection\":{\"providerId\":\"ollama\",\"model\":\"multilingual\",\"endpointRevision\":\"local-1\"},\"copyExisting\":true}";
        long id = store.EnqueueJob(new("embed", "notebook:1", null, options), 0);
        var claimed = Assert.IsType<IngestJob>(store.ClaimJob(0, "owner", id));
        Assert.False(store.CompleteJob(new(id, "other"), 1, "generation:1"));
        Assert.False(store.CompleteJob(new(id, "owner"), 300, "generation:1"));
        foreach (string target in new[] { "generation:2", "generation:999", "source:1", "notebook:1" })
        {
            Assert.Throws<StorageV19Exception>(() => store.CompleteJob(new(id, "owner"), 1, target));
            Assert.Equal(claimed, store.Job(id));
        }
        Assert.True(store.CompleteJob(new(id, "owner"), 1, "generation:1"));
        var done = store.Job(id)!;
        Assert.Equal("done", done.State);
        Assert.Equal("generation:1", done.Draft.Target);
        Assert.Equal(options, done.Draft.OptionsJson);
        Assert.Equal(claimed.Attempts, done.Attempts);
        Assert.Null(done.LeaseToken);
        Assert.False(store.CompleteJob(new(id, "owner"), 2, "generation:1"));
        long valid = store.EnqueueJob(new("embed", "notebook:1", null), 0);
        Assert.NotNull(store.ClaimJob(0, "valid", valid));
        long orphan = store.EnqueueJob(new("embed", "notebook:2", null), 0);
        lock (store.Gate) store.Connection.Execute("DELETE FROM notebooks WHERE id=2");
        Assert.Null(store.ClaimJob(0, "orphan", orphan));
        Assert.Equal("cancelled", store.Job(orphan)!.State);
        Assert.Equal(0, store.Job(orphan)!.Attempts);
        foreach (string target in new[] { "notebook:0", "notebook:01", "notebook:-1", "notebook:+1", "notebook:1:2", "notebook:9223372036854775808" })
            Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.EnqueueJob(new("embed", target, null), 0)).Code);
        foreach (string kind in new[] { "scan", "extract", "gc" })
            Assert.Equal("invalidValue", Assert.Throws<StorageV19Exception>(() => store.EnqueueJob(new(kind, "notebook:1", null), 0)).Code);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void SourceStatusAndJobTransitionRollbackTogether(bool retry)
    {
        using var store = V19TestStore.Create();
        Seed(store);
        long? revision = Scalar<long?>(store, "SELECT current_revision FROM sources WHERE id=1");
        long id = store.EnqueueJob(new("extract", "source:1", revision), 0);
        if (retry)
        {
            store.ClaimJob(0, "owner", id);
            Assert.True(store.FailJob(new(id, "owner"), "io", 10));
        }
        var before = store.Job(id);
        lock (store.Gate) store.Connection.Execute("""
            CREATE TRIGGER reject_status BEFORE UPDATE OF status ON sources
            BEGIN SELECT RAISE(ABORT,'injected status failure'); END;
            """);
        if (retry) Assert.Throws<SqliteException>(() => store.RequeueRetryableJobs(70));
        else Assert.Throws<SqliteException>(() => store.ClaimJob(70, "new", id));
        Assert.Equal(before, store.Job(id));
        Source(store, retry ? "error" : "ready", retry ? "io" : null, revision, revision);
    }
}
