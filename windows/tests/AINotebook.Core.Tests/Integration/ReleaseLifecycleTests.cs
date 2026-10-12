using AINotebook.Core.Ingestion;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Integration;

/// <summary>
/// WP9: restart reconciliation, cancelled extraction + resume with a new job, deletion after a completed scan and
/// immediate rule revocation, each over a fresh upgraded six-file tree.
/// </summary>
public sealed class ReleaseLifecycleTests
{
    private static async Task Run(Func<ReleaseHarness, Task> test)
    {
        var h = await ReleaseHarness.OpenAsync();
        try { await test(h); }
        finally
        {
            await h.CloseAsync();
            h.RemoveTemporaryFiles();
        }
    }

    [Fact]
    public Task RestartReconcilesChangesMadeWhileStopped() => Run(async h =>
    {
        var row = h.Fixture.CaseNamed("restart-reconcile");
        var before = h.Source(row.RelPath!);
        var answer = await h.SendAsync(await h.PrepareAsync());
        string snapshots = CitationsCodec.Encode(answer.Citations)!;

        await h.CloseAsync();
        h.Append(row.Name);
        await h.ReopenAsync();
        // Reopening alone changes nothing; only reconciliation rescans.
        Assert.Equal(before.PublishedRevisionId, h.Source(row.RelPath!).PublishedRevisionId);
        await h.ReconcileAsync();
        await h.DrainAsync();

        var after = h.Source(row.RelPath!);
        Assert.Equal(row.Expected.SameSource, after.Id == before.Id);
        Assert.Equal(row.Expected.NewRevision, after.PublishedRevisionId != before.PublishedRevisionId);
        Assert.EndsWith(row.Append!, h.Store.Revision(after.PublishedRevisionId!.Value)!.Draft.CanonicalText);
        Assert.Equal(snapshots, CitationsCodec.Encode(h.Store.Messages(h.SessionId).Last().Citations));
        Assert.Single(h.Store.Folders(h.NotebookId));
        Assert.Equal(row.Expected.Files, h.Store.Sources(h.NotebookId).Count(s => s.FolderId == h.FolderId));
        var prepared = await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable, prepared.Request.Coverage.Corpus.Searchable);
        Assert.Contains(prepared.Request.CitationMap,
            c => c.SourceId == before.Id && c.Text!.Contains("WP9-RESTART", StringComparison.Ordinal));
    });

    [Fact]
    public Task CancelMidExtractionThenResumeWithNewJob() => Run(async h =>
    {
        var row = h.Fixture.CaseNamed("cancel-resume");
        var old = h.Source(row.RelPath!);
        long oldRevisionId = Assert.IsType<long>(old.PublishedRevisionId);
        string oldText = h.Store.Revision(oldRevisionId)!.Draft.CanonicalText;
        h.Append(row.Name);
        await h.ScanOnlyAsync();
        string target = $"source:{old.Id}";
        var job = Assert.Single(h.Store.DueJobs("extract", h.Clock.Now, 32).Where(j => j.Draft.Target == target));
        h.Gate.Arm();
        var queue = h.Queue;
        var worker = h.Worker;
        var attempt = queue.RunOneAsync("extract", 1, (j, f, ct) => worker.ExecuteAsync(j, f, ct));
        try
        {
            await h.Gate.WaitUntilEnteredAsync();
            Assert.Equal("running", h.Store.Job(job.Id)!.State);
            Assert.Equal(1, h.Store.Job(job.Id)!.Attempts);
        }
        finally
        {
            // User cancellation: durably cancels the fenced attempt (terminal, not a pause).
            await queue.CancelAsync(job.Id);
            h.Gate.Release();
            try { await attempt; } catch (OperationCanceledException) { }
        }
        var cancelled = h.Store.Job(job.Id)!;
        Assert.Equal(row.Expected.CancelledState, cancelled.State);
        Assert.Null(cancelled.LeaseToken);
        Assert.Null(cancelled.LeaseUntil);
        Assert.Equal(old.CurrentRevision, h.Source(row.RelPath!).CurrentRevision);
        Assert.Equal(row.Expected.OldRevisionRetained, h.Source(row.RelPath!).PublishedRevisionId == oldRevisionId);
        Assert.Equal(oldText, h.Store.Revision(oldRevisionId)!.Draft.CanonicalText);
        var oldPack = await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable, oldPack.Request.Coverage.Corpus.Searchable);
        Assert.Contains(oldPack.Request.CitationMap, c => c.SourceId == old.Id && c.RevisionId == oldRevisionId);

        // Resume = restart + a new verified scan scheduling a NEW extraction job.
        await h.CloseAsync();
        await h.ReopenAsync();
        await h.ScanOnlyAsync();
        var retry = Assert.Single(h.Store.DueJobs("extract", h.Clock.Now, 32).Where(j => j.Draft.Target == target));
        Assert.Equal(row.Expected.NewJob, retry.Id != job.Id);
        Assert.Equal(0, retry.Attempts);
        await h.DrainAsync();
        Assert.Equal("done", h.Store.Job(retry.Id)!.State);
        Assert.Equal(1, h.Store.Job(retry.Id)!.Attempts);
        long freshRevisionId = Assert.IsType<long>(h.Source(row.RelPath!).PublishedRevisionId);
        Assert.Equal(row.Expected.NewRevision, freshRevisionId != oldRevisionId);
        Assert.EndsWith(row.Append!, h.Store.Revision(freshRevisionId)!.Draft.CanonicalText);
        Assert.Equal(row.Expected.CancelledState, h.Store.Job(job.Id)!.State);
        var fresh = await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable, fresh.Request.Coverage.Corpus.Searchable);
        Assert.Contains(fresh.Request.CitationMap,
            c => c.SourceId == old.Id && c.Text!.Contains("WP9-RESUME", StringComparison.Ordinal));
    });

    [Fact]
    public Task DeletionBecomesMissingAfterCompletedScanAndKeepsCitation() => Run(async h =>
    {
        var row = h.Fixture.CaseNamed("delete-completed-scan");
        var source = h.Source(row.RelPath!);
        var one = await h.PrepareAsync(new RetrievalScope.Selection(
            new HashSet<long> { Assert.IsType<long>(source.Id) }, new HashSet<long>()));
        var answer = await h.SendAsync(one);
        string snapshot = answer.Citations[0].Text!;
        h.Delete(row.RelPath!);
        Assert.Equal(row.Expected.Before, h.Source(row.RelPath!).Availability);
        await h.ScanOnlyAsync();
        await h.DrainAsync();
        var folder = Assert.Single(h.Store.Folders(h.NotebookId));
        Assert.Equal("idle", folder.ScanState);
        Assert.NotNull(folder.LastFullScanAt);
        Assert.Equal(row.Expected.After, h.Source(row.RelPath!).Availability);
        var pack = await h.PrepareAsync();
        Assert.Equal(row.Expected.Searchable, pack.Request.Coverage.Corpus.Searchable);
        Assert.Equal(row.Expected.Missing, pack.Request.Coverage.Corpus.Missing);
        Assert.DoesNotContain(pack.Request.CitationMap, c => c.SourceId == source.Id);
        using (var pool = await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.DoesNotContain(pool.Vector, c => c.Reference.SourceId == source.Id);
            Assert.DoesNotContain(pool.Lexical, c => c.Reference.SourceId == source.Id);
        }
        await h.CloseAsync();
        await h.ReopenAsync();
        Assert.Equal(row.Expected.OldCitationReadable,
            h.Store.Messages(h.SessionId).Last().Citations[0].Text == snapshot);
    });

    [Fact]
    public Task RulesImmediatelyRevokeAllBranchesMapAndOverview() => Run(async h =>
    {
        var row = h.Fixture.CaseNamed("rules-restrict");
        var source = h.Source(row.RelPath!);
        using (var warm = await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.Contains(warm.Vector, c => c.Reference.SourceId == source.Id);
            Assert.Contains(warm.Lexical, c => c.Reference.SourceId == source.Id);
        }
        var defaults = FolderRules.Defaults;
        var rules = defaults with { IgnoreGlobs = defaults.IgnoreGlobs.Append(row.Pattern!).ToArray() };
        await h.Scanner.ApplyRulesAsync(h.FolderId, rules, h.Clock.Now);
        // No scan/drain between applying rules and observing every surface.
        Assert.Equal(row.Expected.Eligible, h.Source(row.RelPath!).Eligible);
        Assert.Equal(row.Expected.Availability, h.Source(row.RelPath!).Availability);
        using (var pool = await h.PoolAsync("RE-DE-2026-061"))
        {
            Assert.Equal(row.Expected.VectorIncludes, pool.Vector.Any(c => c.Reference.SourceId == source.Id));
            Assert.Equal(row.Expected.LexicalIncludes, pool.Lexical.Any(c => c.Reference.SourceId == source.Id));
        }
        var answer = await h.PrepareAsync();
        Assert.DoesNotContain(answer.Request.CitationMap, c => c.SourceId == source.Id);
        Assert.Equal(row.Expected.Searchable, answer.Request.Coverage.Corpus.Searchable);
        Assert.Equal(row.Expected.MapIncludes, answer.Request.Messages.SelectMany(m => m.Sections)
            .Where(s => s.Kind == "map").Any(s => s.Text.Contains(row.RelPath!, StringComparison.Ordinal)));
        var overview = await h.PrepareAsync(mode: "overview");
        Assert.Equal(row.Expected.OverviewIncludes, overview.Request.CitationMap.Any(c => c.SourceId == source.Id));
        Assert.Equal(row.Expected.Searchable, overview.Request.Coverage.Corpus.Searchable);
        // A stale explicit selection of the excluded file never broadens scope.
        var only = await h.PrepareAsync(new RetrievalScope.Selection(
            new HashSet<long> { Assert.IsType<long>(source.Id) }, new HashSet<long>()));
        Assert.Empty(only.Request.CitationMap);
        Assert.DoesNotContain(only.Request.Messages.SelectMany(m => m.Sections), s => s.Kind == "evidence");
    });
}
