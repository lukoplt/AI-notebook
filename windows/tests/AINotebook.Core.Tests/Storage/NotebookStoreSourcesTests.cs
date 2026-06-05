using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreSourcesTests
{
    private static (NotebookStore store, long nbId) Fresh()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N");
        return (store, nb.Id!.Value);
    }

    [Fact]
    public void CreateSourceDefaultsToPendingAndTrimsTitle()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "  Doc  ", uri: null, rawPath: "/tmp/x");
            Assert.Equal(SourceStatus.Pending, s.Status);
            Assert.Equal("Doc", s.Title);
        }
    }

    [Fact]
    public void CreateSourceRejectsEmptyTitle()
    {
        var (store, nb) = Fresh();
        using (store)
            Assert.Throws<StoreException.InvalidSourceTitle>(
                () => store.CreateSource(nb, SourceType.Text, "  ", null, null));
    }

    [Fact]
    public void UpdateSourceStatusPersistsAndUnknownThrows()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Pdf, "p", null, null);
            store.UpdateSourceStatus(s.Id!.Value, SourceStatus.Error, "boom");
            var reloaded = store.Source(s.Id!.Value)!;
            Assert.Equal(SourceStatus.Error, reloaded.Status);
            Assert.Equal("boom", reloaded.Error);
            Assert.Throws<StoreException.SourceNotFound>(
                () => store.UpdateSourceStatus(99999, SourceStatus.Ready, null));
        }
    }

    [Fact]
    public void UpdateSourceTitleChangesTitleAndSyncsFts()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "OldTitle", null, null);
            store.UpdateSourceTitle(s.Id!.Value, "BrandNewTitle");
            Assert.Equal("BrandNewTitle", store.Source(s.Id!.Value)!.Title);

            // The sources_au trigger must keep sources_fts in sync with the new title.
            using var cmd = store.Connection.CreateCommand();
            cmd.CommandText = "SELECT count(*) FROM sources_fts WHERE sources_fts MATCH $q";
            cmd.Parameters.AddWithValue("$q", "BrandNewTitle");
            Assert.Equal(1L, (long)cmd.ExecuteScalar()!);
        }
    }

    [Fact]
    public void ReplaceChunksClearsThenReinsertsWithOrdZeroToN()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "t", null, null);
            store.ReplaceChunks(s.Id!.Value, new[]
            {
                new ChunkDraft("first", 1, null),
                new ChunkDraft("second", 1, 2),
            });
            // Replace again with a single chunk -> old ones cleared
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft("only", 1, null) });
            var chunks = store.Chunks(s.Id!.Value);
            Assert.Single(chunks);
            Assert.Equal(0, chunks[0].Ord);
            Assert.Equal("only", chunks[0].Text);
        }
    }

    [Fact]
    public void DeleteSourceCascadesChunks()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "t", null, null);
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft("a", 1, null) });
            store.DeleteSource(s.Id!.Value);
            Assert.Empty(store.Chunks(s.Id!.Value));
            Assert.Throws<StoreException.SourceNotFound>(() => store.DeleteSource(s.Id!.Value));
        }
    }

    [Fact]
    public void SourceSummaryDefaultsToNullThenRoundTrips()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            var s = store.CreateSource(nb, SourceType.Text, "t", null, null);
            Assert.Null(store.SourceSummary(s.Id!.Value));
            store.SetSourceSummary(s.Id!.Value, "A short summary.");
            Assert.Equal("A short summary.", store.SourceSummary(s.Id!.Value));
        }
    }

    [Fact]
    public void SourcesExcludesShadowNotesButIncludingShadowReturnsThem()
    {
        var (store, nb) = Fresh();
        using (store)
        {
            store.CreateSource(nb, SourceType.Text, "real", null, null);
            store.CreateSource(nb, SourceType.Note, "shadow", null, null);
            Assert.Single(store.Sources(nb));
            Assert.Equal("real", store.Sources(nb).Single().Title);
            Assert.Equal(2, store.SourcesIncludingShadow(nb).Count);
        }
    }
}
