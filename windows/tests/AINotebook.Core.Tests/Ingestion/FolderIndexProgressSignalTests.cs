using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// A committed background batch is indexing progress, not a catalog change: it raises the status-only event,
/// coalesced to at most one per interval per notebook (leading edge plus one trailing raise), so a fast build does
/// not make every observer reload several times per second.
/// </summary>
public sealed class FolderIndexProgressSignalTests
{
    private static readonly EmbeddingSelection Selection = new("local", "1", "m", null, 2, "l2", "1", "1", "2");

    [Fact]
    public async Task BatchCommitsRaiseCoalescedStatusSignalsOnly()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null)
        {
            IndexingProgressInterval = TimeSpan.FromMilliseconds(300)
        };
        long notebook = store.CreateNotebook("signal").Id!.Value;
        var chunks = new[] { "a", "b", "c", "d" }.Select(title =>
        {
            long source = store.CreateSource(notebook, SourceType.Text, title, null, null).Id!.Value;
            var revision = store.CommitForegroundRevision(source, new RevisionDraft(title, "text " + title, 1, 2),
                ScalarChunker.Chunk("text " + title), 0, title);
            return (Chunk: store.Chunks(source).Single().Id!.Value, Revision: revision.Id);
        }).ToArray();
        long jobId = store.RequestEmbeddingBuild(notebook, Selection, copyExisting: false, 0);
        long generationId = long.Parse(store.Job(jobId)!.Draft.Target["generation:".Length..], System.Globalization.CultureInfo.InvariantCulture);
        Assert.NotNull(store.ClaimJob(1, "owner", jobId));
        var fence = new JobFence(jobId, "owner");
        var catalog = new List<long>();
        var status = new List<long>();
        store.FolderIngestionChanged += id => { lock (catalog) catalog.Add(id); };
        store.IndexingStatusChanged += id => { lock (status) status.Add(id); };
        long[] Status() { lock (status) return status.ToArray(); }

        foreach (var (chunk, revision) in chunks.Take(3))
            Assert.True(store.CommitEmbeddingBatch(generationId, [chunk], [revision], [[1f, 0f]], fence, 2));
        lock (catalog) Assert.Empty(catalog); // a batch commit is not a catalog mutation
        Assert.Equal([notebook], Status()); // the first batch of a window raises at once; the rest coalesce
        await Task.Delay(600);
        Assert.Equal([notebook, notebook], Status()); // one trailing raise carries the coalesced batches
        Assert.Equal(3, store.GenerationProgress(notebook).Done);
        // After a quiet interval the next batch raises immediately again, with nothing trailing.
        await Task.Delay(400);
        Assert.True(store.CommitEmbeddingBatch(generationId, [chunks[3].Chunk], [chunks[3].Revision], [[0f, 1f]], fence, 2));
        Assert.Equal([notebook, notebook, notebook], Status());
        await Task.Delay(600);
        Assert.Equal(3, Status().Length);
    }
}
