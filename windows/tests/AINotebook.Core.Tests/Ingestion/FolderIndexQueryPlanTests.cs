using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Every batch commit reconciles the building generation; on a large folder that must not rewrite an
/// already settled manifest (no-op upserts dirty pages and invalidate retrieval caches per batch).
/// </summary>
public sealed class FolderIndexQueryPlanTests
{
    private static readonly GenerationIdentity Identity = new("local", "1", "m", null, 2, "l2", "1", "1", "2");

    private static long TotalChanges(NotebookStore store) =>
        store.Connection.ExecuteScalar<long>("SELECT total_changes()");

    [Fact]
    public void ReconcilingAnUnchangedBuildWritesNothing()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("settle").Id!.Value;
        var sources = new[] { "a", "b", "c" }.Select(title =>
        {
            long id = store.CreateSource(notebook, SourceType.Text, title, null, null).Id!.Value;
            store.CommitForegroundRevision(id, new RevisionDraft(title, "text " + title, 1, 2), ScalarChunker.Chunk("text " + title), 0, title);
            return id;
        }).ToArray();
        var generation = store.CreateGeneration(notebook, Identity, 0);
        store.Connection.Execute("UPDATE sources SET availability='missing' WHERE id=$id", new { id = sources[1] });
        store.Connection.Execute("UPDATE sources SET eligible=0 WHERE id=$id", new { id = sources[2] });
        store.ReconcileManifest(generation.Id);
        Assert.Equal(["pending", "excluded", "excluded"], store.Manifest(generation.Id).Select(e => e.State));
        Assert.Equal([null, "missing", "ineligible"], store.Manifest(generation.Id).Select(e => e.Reason));
        long before = TotalChanges(store);
        store.ReconcileManifest(generation.Id);
        Assert.Equal(before, TotalChanges(store));
        // A returning source becomes pending again.
        store.Connection.Execute("UPDATE sources SET availability='present' WHERE id=$id", new { id = sources[1] });
        store.ReconcileManifest(generation.Id);
        Assert.Equal(["pending", "pending", "excluded"], store.Manifest(generation.Id).Select(e => e.State));
    }

    /// <summary>
    /// A build round resumes after its keyset cursor on the manifest primary key and reaches chunks only through
    /// idx_chunks_revision_ord with the spreadsheet cap as a range bound; it never sorts every pending chunk.
    /// </summary>
    [Fact]
    public void RoundCandidatesUseKeysetAndNeverSort()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        var details = store.Connection.Query("EXPLAIN QUERY PLAN " + NotebookStore.CandidatesSql,
                new { generationId = 1L, afterSource = 0L, priorityClass = 0, afterOrd = -1L, limit = 64 })
            .Select(row => (string)row.detail).ToArray();
        Assert.DoesNotContain(details, d => d.StartsWith("SCAN", StringComparison.Ordinal));
        Assert.DoesNotContain(details, d => d.Contains("TEMP B-TREE", StringComparison.Ordinal));
        Assert.Contains(details, d => d.Contains("index_generation_manifest", StringComparison.Ordinal) && d.Contains("source_id>", StringComparison.Ordinal));
        Assert.Contains(details, d => d.Contains("idx_chunks_revision_ord", StringComparison.Ordinal) && d.Contains("ord<", StringComparison.Ordinal));
    }

    /// <summary>Dedup lookups probe the ledger by (generation, hash), then verify by primary keys.</summary>
    [Fact]
    public void ExistingVectorLookupUsesTheHashIndex()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        var details = store.Connection.Query("EXPLAIN QUERY PLAN " + NotebookStore.ExistingVectorSql,
                new { generationId = 1L, hash = "h", text = "t" })
            .Select(row => (string)row.detail).ToArray();
        Assert.DoesNotContain(details, d => d.StartsWith("SCAN", StringComparison.Ordinal));
        Assert.Contains(details, d => d.Contains("idx_generation_text_hashes_hash", StringComparison.Ordinal));
    }

    /// <summary>The status strip re-reads progress every second while indexing runs: count from indexes only.</summary>
    [Fact]
    public void ChunkProgressCountsFromIndexesOnly()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        var details = store.Connection.Query("EXPLAIN QUERY PLAN " + NotebookStore.ChunkProgressSql, new { generationId = 1L })
            .Select(row => (string)row.detail).ToArray();
        Assert.DoesNotContain(details, d => d.StartsWith("SCAN", StringComparison.Ordinal));
        Assert.Contains(details, d => d.Contains("COVERING INDEX idx_chunks_revision_ord", StringComparison.Ordinal));
    }
}
