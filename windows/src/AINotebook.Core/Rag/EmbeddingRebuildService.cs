using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Explicit, recoverable profile rebuild (benchmark-v1 §8 <c>rebuild</c>): stage every notebook, then
/// synchronously write journal → activate atomically → persist selection → clear journal. Failures before
/// activation keep every old active generation and selection; a committed activation whose persistence
/// failed keeps the journal for <see cref="Recover"/>.
/// </summary>
public sealed class EmbeddingRebuildService(NotebookStore store, EmbeddingRebuildJournal journal,
    Func<EmbeddingModelChoice> current, Action<EmbeddingModelChoice> persist,
    Func<long, EmbeddingModelChoice, CancellationToken, Task<IndexGeneration>> stage, Func<long> now,
    Func<EmbeddingModelChoice, CancellationToken, Task>? verifyBeforeActivation = null)
{
    private readonly SemaphoreSlim _busy = new(1, 1);

    public async Task RebuildAsync(EmbeddingModelChoice requested, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(requested);
        if (!await _busy.WaitAsync(0, ct)) throw new EmbeddingRecommendationException("rebuildInProgress");
        try
        {
            ct.ThrowIfCancellationRequested();
            if (requested.ProfileId is null) throw new EmbeddingRecommendationException("profileRequired");
            if (EmbeddingRecommendation.Selection(requested.ProfileId) != requested)
                throw new EmbeddingRecommendationException("profileIdentityMismatch");
            var previous = current();
            var notebookIds = store.Notebooks().Select(n => n.Id!.Value).Order().ToArray();
            var targets = new List<EmbeddingRebuildTarget>();
            bool journalWritten = false;
            try
            {
                foreach (long notebookId in notebookIds)
                {
                    ct.ThrowIfCancellationRequested();
                    // The settings callbacks run on the caller's context: no ConfigureAwait(false) here.
                    var generation = await stage(notebookId, requested, ct);
                    targets.Add(new(notebookId, generation.Id));
                    ct.ThrowIfCancellationRequested();
                }
                if (verifyBeforeActivation is not null)
                {
                    await verifyBeforeActivation(requested, ct);
                }
                ct.ThrowIfCancellationRequested();
                // From here to persistence nothing awaits and nothing checks cancellation.
                journal.Write(new EmbeddingRebuildRecord(1, previous, requested, targets.ToArray()));
                journalWritten = true;
                store.ActivateEmbeddingRebuild(targets, requested, now());
            }
            catch
            {
                RetireBuilding(targets);
                if (journalWritten) journal.Clear();
                throw;
            }
            try { persist(requested); }
            catch (Exception error)
            {
                throw new EmbeddingRecommendationException("selectionPersistenceFailed", error);
            }
            journal.Clear();
        }
        finally { _busy.Release(); }
    }

    /// <summary>
    /// Startup recovery, before router/worker construction. All targets active with the requested identity →
    /// persist and clear; all still building or retired → retire staged, keep the previous selection, clear;
    /// anything else → <c>rebuildRecoveryConflict</c> and the journal stays for inspection. Idempotent.
    /// </summary>
    public void Recover()
    {
        if (!_busy.Wait(0)) throw new EmbeddingRecommendationException("rebuildInProgress");
        try
        {
            var record = journal.Read();
            if (record is null) return;
            var generations = record.Targets.Select(t => (Target: t, Generation: store.Generation(t.GenerationId))).ToArray();
            bool owned = generations.All(g => g.Generation is not null && g.Generation.NotebookId == g.Target.NotebookId);
            if (owned && generations.All(g => g.Generation!.State == "active" && Matches(g.Generation, record.Requested)))
            {
                try { persist(record.Requested); }
                catch (Exception error) { throw new EmbeddingRecommendationException("selectionPersistenceFailed", error); }
                journal.Clear();
                return;
            }
            if (owned && generations.All(g => g.Generation!.State is "building" or "retired"))
            {
                RetireBuilding(record.Targets);
                journal.Clear();
                return;
            }
            throw new EmbeddingRecommendationException("rebuildRecoveryConflict");
        }
        finally { _busy.Release(); }
    }

    private static bool Matches(IndexGeneration generation, EmbeddingModelChoice requested)
    {
        if (generation.Identity.ProviderId != requested.ProviderId || generation.Identity.Model != requested.Model
            || requested.ProfileId is null)
            return false;
        try
        {
            EmbeddingProfiles.Require(requested.ProfileId).ValidateIdentity(generation.Identity.Model, generation.Identity.Dims,
                generation.Identity.QueryFormatVersion, generation.Identity.DocFormatVersion);
            return true;
        }
        catch (EmbeddingProfileException) { return false; }
    }

    /// <summary>Retires only this operation's still-building targets; never deletes vectors or runs GC.</summary>
    private void RetireBuilding(IEnumerable<EmbeddingRebuildTarget> targets)
    {
        foreach (var target in targets)
        {
            try
            {
                if (store.Generation(target.GenerationId) is { State: "building" }) store.RetireGeneration(target.GenerationId);
            }
            catch (StorageV19Exception) { /* keep the original failure */ }
        }
    }
}
