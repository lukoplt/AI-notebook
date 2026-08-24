using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// FR-E1 watched folder. The event-driven paths are exercised by writing real
/// files and waiting for the watcher, so they are polled with a generous
/// timeout rather than a fixed sleep — the service debounces 500 ms before it
/// touches anything.
/// </summary>
public class FolderWatchServiceTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "watch-" + Guid.NewGuid());

    public FolderWatchServiceTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try { Directory.Delete(_dir, recursive: true); } catch { }
    }

    private (NotebookStore store, IngestionService ingestion, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, new IngestionService(store), store.CreateNotebook("NB").Id!.Value);
    }

    /// Polls until <paramref name="predicate"/> holds or the timeout expires.
    private static async Task<bool> Eventually(Func<bool> predicate, int timeoutMs = 15000)
    {
        var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (predicate()) return true;
            await Task.Delay(100);
        }
        return predicate();
    }

    [Fact]
    public void EnableAndDisableReportTheWatchedFolderAndClearItAgain()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        using var watcher = new FolderWatchService(store, ingestion);

        Assert.False(watcher.IsActive);
        Assert.Null(watcher.WatchedFolder);

        watcher.Enable(nb, _dir);
        Assert.True(watcher.IsActive);
        Assert.Equal(_dir, watcher.WatchedFolder);

        watcher.Disable();
        Assert.False(watcher.IsActive);
        Assert.Null(watcher.WatchedFolder);
    }

    [Fact]
    public void EnablingTwiceSwitchesFoldersInsteadOfLeakingTheFirstWatcher()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        var second = Path.Combine(_dir, "nested");
        Directory.CreateDirectory(second);
        using var watcher = new FolderWatchService(store, ingestion);

        watcher.Enable(nb, _dir);
        watcher.Enable(nb, second);

        Assert.Equal(second, watcher.WatchedFolder);
        Assert.True(watcher.IsActive);
    }

    [Fact]
    public void DisableIsIdempotentAndSafeBeforeAnyEnable()
    {
        var (store, ingestion, _) = NewStore();
        using var __ = store;
        var watcher = new FolderWatchService(store, ingestion);

        watcher.Disable();
        watcher.Disable();
        watcher.Dispose();
        watcher.Dispose();

        Assert.False(watcher.IsActive);
    }

    [Fact]
    public async Task ANewSupportedFileIsIngestedAndStampedWithItsContentHash()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        using var watcher = new FolderWatchService(store, ingestion);
        watcher.Enable(nb, _dir);

        await File.WriteAllTextAsync(Path.Combine(_dir, "memo.txt"), "Watched content.");

        Assert.True(await Eventually(() => store.Sources(nb).Count == 1),
            "the watcher never ingested the new file");
        var source = store.Sources(nb).Single();
        Assert.Equal("memo", source.Title);
        Assert.Equal(SourceType.Text, source.Type);
        Assert.True(await Eventually(() => store.Source(source.Id!.Value)!.ContentHash is not null),
            "the sync stamp was never written");
        Assert.NotNull(store.Source(source.Id!.Value)!.LastSyncedAt);
    }

    [Fact]
    public async Task AFileTypeTheAppCannotReadIsIgnored()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        using var watcher = new FolderWatchService(store, ingestion);
        watcher.Enable(nb, _dir);

        await File.WriteAllTextAsync(Path.Combine(_dir, "photo.jpeg"), "not text");
        await File.WriteAllTextAsync(Path.Combine(_dir, "memo.txt"), "text");

        // The .txt is the tripwire: once it has landed, the .jpeg has had at
        // least as long to be (wrongly) picked up.
        Assert.True(await Eventually(() => store.Sources(nb).Any(s => s.Title == "memo")));
        Assert.DoesNotContain(store.Sources(nb), s => s.Title == "photo");
    }

    [Fact]
    public async Task NothingIsIngestedAfterTheWatcherIsDisabled()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        using var watcher = new FolderWatchService(store, ingestion);

        watcher.Enable(nb, _dir);
        watcher.Disable();
        await File.WriteAllTextAsync(Path.Combine(_dir, "after.txt"), "content");
        await Task.Delay(2000);

        Assert.Empty(store.Sources(nb));
    }

    [Fact]
    public async Task ReindexingAnUnchangedFileIsSkippedButAnEditIsPickedUp()
    {
        var (store, ingestion, nb) = NewStore();
        using var _ = store;
        var path = Path.Combine(_dir, "memo.txt");
        await File.WriteAllTextAsync(path, "Original body.");

        using var watcher = new FolderWatchService(store, ingestion);
        watcher.Enable(nb, _dir);

        // Touch without changing content: the hash matches, so nothing to do.
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow);
        Assert.True(await Eventually(() => store.Sources(nb).Count == 1),
            "the initial ingest never happened");
        var source = store.Sources(nb).Single();
        var firstHash = await Eventually(() => store.Source(source.Id!.Value)!.ContentHash is not null)
            ? store.Source(source.Id!.Value)!.ContentHash
            : null;
        Assert.NotNull(firstHash);

        // Now genuinely change it — the hash differs, so it is re-ingested.
        await File.WriteAllTextAsync(path, "Completely different body text now.");

        Assert.True(await Eventually(() => store.Source(source.Id!.Value)!.ContentHash != firstHash),
            "the edit was never re-ingested");
        // Still one source: an edit updates in place rather than duplicating.
        Assert.Single(store.Sources(nb));
    }
}
