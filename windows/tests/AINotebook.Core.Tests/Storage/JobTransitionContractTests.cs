using System.Text.Json;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class JobTransitionContractTests
{
    private static readonly HashSet<string> ExpectedCaseNames =
    [
        "first-start-increments-attempts", "second-start-increments-once", "fifth-attempt-may-start",
        "failure-backoff-from-started-count", "fourth-failure-backoff-480-seconds", "fifth-failure-terminal",
        "failed-retry-before-backoff-rejected", "failed-retry-at-backoff-no-increment", "exhausted-failure-cannot-retry",
        "expiry-backoff-without-increment", "fifth-expiry-terminal", "live-lease-cannot-expire",
        "renew-after-60-seconds-no-increment", "expired-worker-cannot-renew", "replaced-worker-cannot-renew",
        "replaced-worker-cannot-publish", "replaced-worker-cannot-fail-replacement", "expired-worker-cannot-publish",
        "replacement-publishes-with-current-token", "superseded-revision-cancels-current-worker",
        "queued-cannot-start-before-backoff"
    ];

    [Fact]
    public void AllFrozenJobTransitionsRunAgainstTheStore()
    {
        var fixture = RetryCapSupersession.Document("job-transitions-v1.json");
        Assert.Equal("job-transitions", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        var visited = new HashSet<string>();
        foreach (var c in fixture.GetProperty("cases").EnumerateArray())
        {
            string name = c.GetProperty("name").GetString()!;
            Assert.Contains(name, ExpectedCaseNames);
            Assert.True(visited.Add(name), $"Duplicate job transition case: {name}");
            RunCase(name, c);
        }
        Assert.Equal(21, visited.Count);
        Assert.True(ExpectedCaseNames.SetEquals(visited), "Every frozen job transition must run.");
    }

    private static void RunCase(string name, JsonElement c)
    {
        using var store = V19TestStore.Create();
        var input = c.GetProperty("input");
        var initial = input.GetProperty("job");
        var e = input.GetProperty("event");
        long revision = initial.GetProperty("targetRevision").GetInt64();
        long requested = e.TryGetProperty("requestedRevision", out var requestedValue) ? requestedValue.GetInt64() : revision;
        lock (store.Gate)
        {
            using var transaction = store.Connection.BeginTransaction();
            store.Connection.Execute("""
                INSERT INTO notebooks(id,name,created_at,updated_at)
                VALUES(1,'contract','2026-01-02 03:04:05.000','2026-01-02 03:04:05.000');
                INSERT INTO sources(id,notebook_id,type,title,status,ingested_at)
                VALUES(1,1,'text','contract source','chunking','2026-01-02 03:04:05.000');
                INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES($revision,1,1,'first-hash','',1,2,'2026-01-02 03:04:05.000');
                """, new { revision }, transaction);
            if (requested != revision)
                store.Connection.Execute("""
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES($requested,1,2,'newer-hash','',1,2,'2026-01-02 03:04:05.000')
                    """, new { requested }, transaction);
            store.Connection.Execute("""
                UPDATE sources SET current_revision=$requested WHERE id=1;
                INSERT INTO ingest_jobs(id,kind,target,target_revision,state,attempts,next_retry_at,lease_until,lease_token)
                VALUES(1,'extract','source:1',$revision,$state,$attempts,$retry,$lease,$token)
                """, new
                {
                    requested, revision,
                    state = initial.GetProperty("state").GetString(),
                    attempts = initial.GetProperty("attempts").GetInt32(),
                    retry = NullableLong(initial.GetProperty("nextRetryAt")),
                    lease = NullableLong(initial.GetProperty("leaseUntil")),
                    token = initial.GetProperty("leaseToken").GetString()
                }, transaction);
            transaction.Commit();
        }

        long now = e.GetProperty("now").GetInt64();
        string token = e.TryGetProperty("leaseToken", out var leaseToken) ? leaseToken.GetString()! : "unused";
        bool published = false;
        bool accepted;
        switch (e.GetProperty("kind").GetString())
        {
            case "start": accepted = store.ClaimJob(now, token, 1) is not null; break;
            case "fail": accepted = store.FailJob(new(1, token), "fixture failure", now); break;
            case "retry": accepted = store.RequeueRetryableJobs(now) == 1; break;
            case "expire": accepted = store.RecoverExpiredJobs(now) == 1; break;
            case "renew": accepted = store.RenewJob(new(1, token), now); break;
            case "publish":
                published = store.PublishRevision(1, revision, [], new(1, token), now);
                // A live worker that cancels its superseded target accepted the event without publication.
                accepted = published || store.Job(1)!.State == "cancelled";
                break;
            default: throw new InvalidOperationException($"Unhandled job transition event in {name}: {e.GetProperty("kind")}");
        }

        var job = Assert.IsType<IngestJob>(store.Job(1));
        var actual = JsonSerializer.SerializeToElement(new
        {
            job = new
            {
                state = job.State, attempts = job.Attempts, nextRetryAt = job.NextRetryAt,
                leaseUntil = job.LeaseUntil, leaseToken = job.LeaseToken, targetRevision = job.Draft.TargetRevision
            },
            accepted, published
        });
        var expected = c.GetProperty("expected");
        Assert.True(JsonElement.DeepEquals(expected, actual),
            $"{name}: expected {expected.GetRawText()}, actual {actual.GetRawText()}");
        lock (store.Gate)
        {
            long? publishedRevision = store.Connection.ExecuteScalar<long?>("SELECT published_revision_id FROM sources WHERE id=1");
            Assert.Equal(published ? revision : (long?)null, publishedRevision);
        }
    }

    private static long? NullableLong(JsonElement value) => value.ValueKind == JsonValueKind.Null ? null : value.GetInt64();
}
