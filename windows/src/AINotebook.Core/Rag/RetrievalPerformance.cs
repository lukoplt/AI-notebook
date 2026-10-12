using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Rag;

public sealed record SyntheticRetrievalChunk(long ChunkId, long SourceId, int Ord, string Text, float[] Vector);

public sealed record SyntheticRetrievalHandle(long NotebookId, long GenerationId, int ChunkCount, int Dims);

/// <summary>
/// Deterministic benchmark corpus shared with macOS (retrieval-perf-v1). Logical row
/// IDs are fixture identities; Populate returns the database's actual IDs.
/// </summary>
public static class SyntheticRetrievalCorpus
{
    private const int RowsPerSource = 100;
    private const long MaximumVectorBytes = 8_388_608;
    public const string Model = "synthetic";

    public static SyntheticRetrievalChunk Row(int index, int dims, int seed = 17)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(index);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(dims);
        ArgumentOutOfRangeException.ThrowIfNegative(seed);
        var vector = new float[dims];
        vector[(index % dims + seed % dims) % dims] = 1;
        return new(index + 1L, 1 + index / RowsPerSource, index % RowsPerSource,
            $"synthetic {index} needle{index % 97}", vector);
    }

    /// <summary>
    /// Builds one fresh benchmark notebook: 100 chunks per source, one LF-joined
    /// version-2 revision per source with scalar spans, a building legacy generation
    /// (model "synthetic"), one-hot vectors written per source in one gated
    /// transaction, done manifests, and activation only after every source is complete.
    /// At most one source's vectors are materialized at a time.
    /// </summary>
    public static SyntheticRetrievalHandle Populate(NotebookStore store, int chunkCount, int dims, int seed = 17)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(chunkCount);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(dims);
        if ((long)dims * sizeof(float) > MaximumVectorBytes) throw new ArgumentOutOfRangeException(nameof(dims));
        ArgumentOutOfRangeException.ThrowIfNegative(seed);

        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        long notebookId = store.CreateNotebook("Synthetic retrieval benchmark").Id!.Value;
        var generation = store.CreateGeneration(notebookId,
            new GenerationIdentity("legacy", "legacy", Model, null, dims, "legacy", "legacy", "legacy", "legacy"), now);
        for (int first = 0; first < chunkCount; first += RowsPerSource)
        {
            int count = Math.Min(RowsPerSource, chunkCount - first);
            var rows = Enumerable.Range(first, count).Select(index => Row(index, dims, seed)).ToArray();
            long sourceId = store.CreateSource(notebookId, SourceType.Text, $"synthetic-{rows[0].SourceId}.txt", null, null).Id!.Value;
            var canonical = new StringBuilder();
            var chunks = new List<RevisionChunkDraft>(count);
            int scalar = 0;
            foreach (var row in rows)
            {
                if (canonical.Length > 0) { canonical.Append('\n'); scalar++; }
                int start = scalar;
                canonical.Append(row.Text);
                scalar += row.Text.EnumerateRunes().Count();
                chunks.Add(new RevisionChunkDraft(row.Text, 3, null, start, scalar, null, false));
            }
            string text = canonical.ToString();
            var revision = store.CommitForegroundRevision(sourceId,
                new RevisionDraft(Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text))), text, 1, 2),
                chunks, now, "synthetic-benchmark");
            lock (store.Gate)
            {
                using var transaction = store.Connection.BeginTransaction(deferred: false);
                long[] chunkIds = store.Connection.Query<long>(
                    "SELECT id FROM source_chunks WHERE revision_id=$revision ORDER BY ord",
                    new { revision = revision.Id }, transaction).ToArray();
                if (chunkIds.Length != count) throw new InvalidOperationException("Synthetic chunk set mismatch.");
                GenerationSQL.SetManifest(store.Connection, transaction, generation.Id,
                    [new ManifestEntry(sourceId, revision.Id, "pending", null)]);
                for (int i = 0; i < count; i++)
                    GenerationSQL.StoreEmbedding(store.Connection, transaction, generation.Id, chunkIds[i], new EmbeddingVector(rows[i].Vector));
                GenerationSQL.SetManifest(store.Connection, transaction, generation.Id,
                    [new ManifestEntry(sourceId, revision.Id, "done", null)]);
                transaction.Commit();
            }
        }
        store.ActivateGeneration(generation.Id, now);
        return new(notebookId, generation.Id, chunkCount, dims);
    }
}

public sealed record RetrievalPerformanceSample(double QueryEmbeddingMs, double WarmRetrievalMs, double HydrationMs)
{
    /// <summary>End-to-end sum; never use it as the warm retrieval figure.</summary>
    public double EndToEndMs => QueryEmbeddingMs + WarmRetrievalMs + HydrationMs;
}

/// <summary>Post-embedding phase timing hooks for WP7; reports no hardware claims itself.</summary>
public static class RetrievalPerformance
{
    /// <summary>Production clock: Stopwatch timestamps at Stopwatch.Frequency.</summary>
    public static Task<RetrievalPerformanceSample> MeasureAsync(ResolvedRetrievalScope snapshot, Func<Task<float[]>> embedding,
        Func<float[], Task<PinnedRetrievalCandidates>> retrieval, Func<PinnedRetrievalCandidates, Task> hydration)
        => MeasureAsync(snapshot, embedding, retrieval, hydration, Stopwatch.Frequency, Stopwatch.GetTimestamp);

    /// <summary>
    /// Owns the snapshot from entry and the returned pool; both are released on
    /// success and failure (releases are idempotent). Query embedding is reported
    /// separately and never included in the warm retrieval phase.
    /// </summary>
    public static async Task<RetrievalPerformanceSample> MeasureAsync(ResolvedRetrievalScope snapshot,
        Func<Task<float[]>> embedding, Func<float[], Task<PinnedRetrievalCandidates>> retrieval,
        Func<PinnedRetrievalCandidates, Task> hydration, long ticksPerSecond, Func<long> now)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        using var ownedSnapshot = snapshot;
        ArgumentNullException.ThrowIfNull(embedding);
        ArgumentNullException.ThrowIfNull(retrieval);
        ArgumentNullException.ThrowIfNull(hydration);
        ArgumentNullException.ThrowIfNull(now);
        if (ticksPerSecond <= 0) throw new RetrievalException("invalidMeasurementInput");
        long t0 = now();
        var vector = await embedding().ConfigureAwait(false);
        long t1 = now();
        using var pool = await retrieval(vector).ConfigureAwait(false);
        long t2 = now();
        await hydration(pool).ConfigureAwait(false);
        long t3 = now();
        if (t1 < t0 || t2 < t1 || t3 < t2) throw new RetrievalException("invalidMeasurementInput");
        double Milliseconds(long from, long to) => (to - from) * 1000.0 / ticksPerSecond;
        return new(Milliseconds(t0, t1), Milliseconds(t1, t2), Milliseconds(t2, t3));
    }

    /// <summary>Nearest-rank p95: sorted sample at index ceil(0.95 n) - 1.</summary>
    public static double Percentile95(IReadOnlyList<double> samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Count == 0) throw new ArgumentException("At least one sample is required.", nameof(samples));
        var sorted = samples.Order().ToArray();
        return sorted[(int)Math.Ceiling(0.95 * sorted.Length) - 1];
    }
}
