using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class EmbeddingGenerationException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

/// <summary>
/// Stages one complete embedding generation for a notebook through a document-purpose session
/// (benchmark-v1 §8 <c>stage</c>). Staging never activates and never deletes an existing vector;
/// on failure it retires only a generation it created itself.
/// </summary>
public static class EmbeddingGenerationBuilder
{
    /// <summary>
    /// Validates that the session's entire captured identity equals <paramref name="identity"/> before any
    /// generation exists or any request is sent, then stages with <c>EmbedDocumentsAsync</c>.
    /// </summary>
    public static Task<IndexGeneration> StageAsync(NotebookStore store, long notebookId,
        GenerationIdentity identity, ProviderEmbeddingSession session, Func<long> now,
        IndexGeneration? existingGeneration = null, bool reuseActive = false, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(session);
        ArgumentNullException.ThrowIfNull(identity);
        // A legacy session (no identity) cannot stage a modern identity; storage key or endpoint alone is insufficient.
        if (session.Identity is not { } captured || captured != identity
            || !string.Equals(session.EndpointRevision, identity.EndpointRevision, StringComparison.Ordinal))
            throw new EmbeddingGenerationException("profileIdentityMismatch");
        return StageAsync(store, notebookId, identity, now, session.EmbedDocumentsAsync, existingGeneration, reuseActive, ct);
    }

    internal static async Task<IndexGeneration> StageAsync(NotebookStore store, long notebookId,
        GenerationIdentity identity, Func<long> now,
        Func<IReadOnlyList<string>, CancellationToken, Task<float[][]>> embedDocuments,
        IndexGeneration? existingGeneration = null, bool reuseActive = false, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(now);
        ArgumentNullException.ThrowIfNull(embedDocuments);
        ct.ThrowIfCancellationRequested();
        foreach (var source in store.SourcesIncludingShadow(notebookId)
                     .Where(x => x.Availability == "present" && x.Eligible && x.CurrentRevision is not null))
            if (source.CurrentRevision != source.PublishedRevisionId)
                throw new EmbeddingGenerationException("refreshPending");
        if (existingGeneration is not null)
        {
            var stored = store.Generation(existingGeneration.Id);
            if (stored is null || stored.NotebookId != notebookId || stored.Identity != identity || stored.State != "building")
                throw new EmbeddingGenerationException("invalidGeneration");
        }
        var generation = existingGeneration ?? store.CreateGeneration(notebookId, identity, now());
        try
        {
            if (reuseActive && store.ActiveGeneration(notebookId) is { } active && active.Identity == identity)
            {
                // The only direct connection operation: inside the store gate and one transaction, no await.
                lock (store.Gate)
                {
                    using var tx = store.Connection.BeginTransaction(deferred: false);
                    GenerationSQL.CopyUnchangedVectors(store.Connection, tx, active.Id, generation.Id, null);
                    tx.Commit();
                }
            }
            foreach (var entry in store.Manifest(generation.Id).OrderBy(x => x.SourceId).Where(x => x.State == "pending").ToArray())
            {
                ct.ThrowIfCancellationRequested();
                // One source's chunk snapshot at a time keeps memory bounded.
                var chunks = store.Chunks(entry.SourceId);
                if (chunks.Any(x => x.RevisionId != entry.RevisionId)) throw new EmbeddingGenerationException("staleRevision");
                foreach (var chunk in chunks)
                {
                    ct.ThrowIfCancellationRequested();
                    // Canonical chunk text, never mutable enrichment text: the format identity names no enrichment.
                    var vectors = await embedDocuments([chunk.Text], ct).ConfigureAwait(false);
                    ct.ThrowIfCancellationRequested();
                    RequireCurrent(store.Source(entry.SourceId), entry.RevisionId, requirePresent: true);
                    if (vectors is not { Length: 1 } || vectors[0] is null || vectors[0].Length != identity.Dims || chunk.Id is not long id)
                        throw new EmbeddingGenerationException("invalidEmbedding");
                    try { store.StoreGenerationEmbedding(generation.Id, id, new EmbeddingVector(vectors[0])); }
                    catch (StorageV19Exception error) when (error.Code == "invalidVector")
                    {
                        throw new EmbeddingGenerationException("invalidEmbedding");
                    }
                    catch (StorageV19Exception error) when (error.Code == "staleRevision")
                    {
                        throw new EmbeddingGenerationException("staleRevision");
                    }
                }
                ct.ThrowIfCancellationRequested();
                RequireCurrent(store.Source(entry.SourceId), entry.RevisionId, requirePresent: false);
                store.SetManifest(generation.Id, [new ManifestEntry(entry.SourceId, entry.RevisionId, "done", null)]);
            }
            return store.Generation(generation.Id) ?? generation;
        }
        catch
        {
            // Caller-owned generations belong to a fenced worker; only it may retire them.
            if (existingGeneration is null)
                try { store.RetireGeneration(generation.Id); } catch { /* Preserve the original stage failure. */ }
            throw;
        }
    }

    private static void RequireCurrent(Source? current, long revisionId, bool requirePresent)
    {
        if (current is null || current.CurrentRevision != revisionId || current.PublishedRevisionId != revisionId
            || (requirePresent && (current.Availability != "present" || !current.Eligible)))
            throw new EmbeddingGenerationException("staleRevision");
    }
}
