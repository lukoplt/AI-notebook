using AINotebook.Core.Rag;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    /// <summary>
    /// Activates one staged generation per notebook in a single transaction under the store gate
    /// (benchmark-v1 §8 <c>rebuild</c>). The target set must cover exactly the current notebooks; any
    /// failure rolls back every activation, so no partially activated set is ever published.
    /// </summary>
    public void ActivateEmbeddingRebuild(IReadOnlyList<EmbeddingRebuildTarget> targets, EmbeddingModelChoice requested, long now)
    {
        ArgumentNullException.ThrowIfNull(targets);
        ArgumentNullException.ThrowIfNull(requested);
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            ValidateEmbeddingRebuildTargets(_conn, tx, targets, requested);
            foreach (var target in targets.OrderBy(x => x.NotebookId))
                GenerationSQL.Activate(_conn, tx, target.GenerationId, null, now);
            tx.Commit();
        }
    }

    private static void ValidateEmbeddingRebuildTargets(SqliteConnection c, SqliteTransaction tx,
        IReadOnlyList<EmbeddingRebuildTarget> targets, EmbeddingModelChoice requested)
    {
        if (requested.ProfileId is null) throw new EmbeddingRecommendationException("profileRequired");
        EmbeddingProfile profile;
        try { profile = EmbeddingProfiles.Require(requested.ProfileId); }
        catch (EmbeddingProfileException) { throw new EmbeddingRecommendationException("unknownProfile"); }
        if (targets.Select(t => t.NotebookId).Distinct().Count() != targets.Count
            || targets.Select(t => t.GenerationId).Distinct().Count() != targets.Count)
            throw new EmbeddingRecommendationException("invalidGeneration");
        var notebooks = c.Query<long>("SELECT id FROM notebooks ORDER BY id", transaction: tx).ToArray();
        if (!notebooks.SequenceEqual(targets.Select(t => t.NotebookId).Order()))
            throw new EmbeddingRecommendationException("rebuildScopeChanged");
        foreach (var target in targets)
        {
            var generation = GenerationSQL.Read(c, tx, target.GenerationId);
            if (generation is null || generation.NotebookId != target.NotebookId || generation.State != "building"
                || generation.Identity.ProviderId != requested.ProviderId || generation.Identity.Model != requested.Model
                || generation.Identity.Normalization != "l2")
                throw new EmbeddingRecommendationException("invalidGeneration");
            try
            {
                profile.ValidateIdentity(generation.Identity.Model, generation.Identity.Dims,
                    generation.Identity.QueryFormatVersion, generation.Identity.DocFormatVersion);
            }
            catch (EmbeddingProfileException) { throw new EmbeddingRecommendationException("invalidGeneration"); }
        }
    }
}
