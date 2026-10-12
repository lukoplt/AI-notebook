using System.Globalization;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>Result of one fenced profile publication attempt (benchmark-v1 §8 <c>drain</c>).</summary>
internal enum ProfileActivationOutcome { Activated, LeaseLost, SelectionChanged, ActiveChanged, InvalidGeneration }

public sealed partial class NotebookStore
{
    /// <summary>
    /// Notebooks (ascending) whose ordinary embedding work the selected named profile still owes: an eligible
    /// present source has a published revision absent from (or not done in) a matching active generation, or no
    /// active generation matches the selection. Empty notebooks and legacy selections are never work; a source
    /// whose current revision is ahead of its published one is not work by itself. IDs are materialized under the
    /// gate before the caller's first await.
    /// </summary>
    public IReadOnlyList<long> ProfileEmbeddingWork(EmbeddingModelChoice selection)
    {
        ArgumentNullException.ThrowIfNull(selection);
        if (selection.ProfileId is null) return [];
        var profile = EmbeddingProfiles.Require(selection.ProfileId);
        lock (_gate)
        {
            var notebooks = _conn.Query<long>("""
                SELECT DISTINCT notebook_id FROM sources
                WHERE availability='present' AND eligible=1 AND published_revision_id IS NOT NULL
                ORDER BY notebook_id
                """).ToArray();
            var work = new List<long>();
            foreach (long notebookId in notebooks)
            {
                var active = ActiveGenerationLocked(null, notebookId);
                if (active is null || !ProfileIdentityMatches(active.Identity, selection, profile) || _conn.ExecuteScalar<bool>("""
                    SELECT EXISTS(SELECT 1 FROM sources s
                        WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1
                          AND s.published_revision_id IS NOT NULL
                          AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m
                              WHERE m.generation_id=$generationId AND m.source_id=s.id
                                AND m.revision_id=s.published_revision_id AND m.state='done'))
                    """, new { notebookId, generationId = active.Id }))
                    work.Add(notebookId);
            }
            return work.AsReadOnly();
        }
    }

    /// <summary>
    /// One gate + transaction: creates the building generation, enqueues its embed job and claims exactly that
    /// job, so a lease exists before the first embedding request and no scheduler can claim in between.
    /// Options carry the nonsecret WP6 selection.
    /// </summary>
    public (IndexGeneration Generation, JobFence Fence) BeginProfileEmbedding(long notebookId, GenerationIdentity identity,
        long now, string leaseToken)
    {
        ArgumentNullException.ThrowIfNull(identity);
        IndexGeneration generation;
        long jobId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            generation = GenerationSQL.Create(_conn, tx, notebookId, identity, now);
            var selection = new EmbeddingSelection(identity.ProviderId, identity.EndpointRevision, identity.Model, identity.ModelDigest,
                identity.Dims, identity.Normalization, identity.QueryFormatVersion, identity.DocFormatVersion, identity.ChunkerVersion);
            jobId = RevisionJobSQL.EnqueueJob(_conn, tx, new IngestJobDraft("embed",
                "generation:" + generation.Id.ToString(CultureInfo.InvariantCulture), null,
                IngestionGenerationSQL.SerializeOptions(selection, copyExisting: true)), now);
            var job = RevisionJobSQL.ClaimJob(_conn, tx, now, leaseToken, jobId);
            if (job is null || job.Id != jobId) throw new StorageV19Exception("staleLease");
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return (generation, new JobFence(jobId, leaseToken));
    }

    /// <summary>
    /// One gate + transaction: requires the live fence, the still-selected profile bundle and an unchanged active
    /// generation, then activates through the fenced WP3 kernel, which completes the job. A stale selection or a
    /// newer active generation cancels the owned attempt and returns false; staged data stays for orderly retirement.
    /// </summary>
    public bool ActivateProfileEmbedding(long generationId, long? previousActiveId, JobFence fence,
        EmbeddingModelChoice selected, long now)
        => ProfileActivation(generationId, previousActiveId, fence, selected, now) == ProfileActivationOutcome.Activated;

    internal ProfileActivationOutcome ProfileActivation(long generationId, long? previousActiveId, JobFence fence,
        EmbeddingModelChoice selected, long now)
    {
        ArgumentNullException.ThrowIfNull(fence);
        ArgumentNullException.ThrowIfNull(selected);
        ProfileActivationOutcome outcome;
        long? notebookId = null;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
            var generation = GenerationSQL.Read(_conn, tx, generationId);
            if (job is null || job.Draft.Kind != "embed"
                || job.Draft.Target != "generation:" + generationId.ToString(CultureInfo.InvariantCulture))
                outcome = ProfileActivationOutcome.LeaseLost;
            else if (generation is null || generation.State != "building")
                outcome = ProfileActivationOutcome.InvalidGeneration;
            else if (selected.ProfileId is null
                || !ProfileIdentityMatches(generation.Identity, selected, EmbeddingProfiles.Require(selected.ProfileId)))
                outcome = ProfileActivationOutcome.SelectionChanged;
            else if (ActiveGenerationLocked(tx, generation.NotebookId)?.Id != previousActiveId)
                outcome = ProfileActivationOutcome.ActiveChanged;
            else
            {
                GenerationSQL.Activate(_conn, tx, generationId, fence, now);
                outcome = ProfileActivationOutcome.Activated;
            }
            if (outcome is not ProfileActivationOutcome.Activated and not ProfileActivationOutcome.LeaseLost)
                RevisionJobSQL.CancelJob(_conn, tx, fence, now);
            if (outcome is not ProfileActivationOutcome.LeaseLost and not ProfileActivationOutcome.InvalidGeneration)
                notebookId = generation!.NotebookId;
            tx.Commit();
        }
        if (notebookId is long notebook) NotifyFolderIngestionChanged(notebook);
        return outcome;
    }

    /// <summary>
    /// Exact (ordinal) provider/model/profile agreement with fixed dimensions and both format strings; the
    /// effective ctx limit is read from (and preserved by) the stored identity.
    /// </summary>
    internal static bool ProfileIdentityMatches(GenerationIdentity identity, EmbeddingModelChoice selection, EmbeddingProfile profile)
    {
        if (!string.Equals(selection.ProfileId, profile.Id, StringComparison.Ordinal)
            || !string.Equals(identity.ProviderId, selection.ProviderId, StringComparison.Ordinal)
            || !string.Equals(identity.Model, selection.Model, StringComparison.Ordinal)
            || EmbeddingQueryFormat.Profile(identity.QueryFormatVersion)?.Id != profile.Id
            || identity.Normalization != "l2" || identity.ChunkerVersion != "2")
            return false;
        try
        {
            profile.ValidateIdentity(identity.Model, identity.Dims, identity.QueryFormatVersion, identity.DocFormatVersion);
            return true;
        }
        catch (EmbeddingProfileException) { return false; }
    }

    /// <summary>Caller holds <c>_gate</c>.</summary>
    private IndexGeneration? ActiveGenerationLocked(SqliteTransaction? tx, long notebookId)
    {
        long? id = _conn.QuerySingleOrDefault<long?>(
            "SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'", new { notebookId }, tx);
        return id is long value ? GenerationSQL.Read(_conn, tx, value) : null;
    }
}
