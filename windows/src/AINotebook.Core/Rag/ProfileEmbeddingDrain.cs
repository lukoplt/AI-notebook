using System.Runtime.ExceptionServices;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>
/// Typed outcome of a profile drain that could not publish (benchmark-v1 §8 <c>drain</c>):
/// <c>leaseLost</c>, <c>selectionChanged</c>, <c>activeChanged</c> or <c>invalidGeneration</c>.
/// </summary>
public sealed class ProfileEmbeddingDrainException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

/// <summary>
/// Ordinary (non-rebuild) embedding work for a selected named WP7 profile. It runs as the first step of
/// <see cref="Embedder.EmbedAllPendingAsync"/>, so <see cref="EmbeddingWorker"/> stays the single coalescing entry
/// point. Each notebook with work keeps a matching active identity (resumed, ctx and digest preserved) or uses one
/// prepared identity per run; the build is staged under a freshly claimed, renewed lease and published only through
/// the fenced activation. A legacy selection returns null (the legacy drain then runs).
/// </summary>
public sealed class ProfileEmbeddingDrain(NotebookStore store, Func<EmbeddingModelChoice> selection,
    Func<EmbeddingModelChoice, CancellationToken, Task<PreparedEmbeddingProfile>> prepare,
    Func<GenerationIdentity, CancellationToken, Task<ProviderEmbeddingSession>> resume, IIngestLeaseClock? clock = null)
{
    /// <summary>Lease renewal cadence in seconds (the WP3 lease lasts 300 seconds).</summary>
    public const long RenewalInterval = 60;

    private readonly NotebookStore _store = store ?? throw new ArgumentNullException(nameof(store));
    private readonly Func<EmbeddingModelChoice> _selection = selection ?? throw new ArgumentNullException(nameof(selection));
    private readonly Func<EmbeddingModelChoice, CancellationToken, Task<PreparedEmbeddingProfile>> _prepare =
        prepare ?? throw new ArgumentNullException(nameof(prepare));
    private readonly Func<GenerationIdentity, CancellationToken, Task<ProviderEmbeddingSession>> _resume =
        resume ?? throw new ArgumentNullException(nameof(resume));
    private readonly IIngestLeaseClock _clock = clock ?? new SystemIngestLeaseClock();

    /// <summary>
    /// Null for a legacy selection; otherwise the number of vectors embedded. A failure in one notebook does not
    /// starve the next; the first such error is rethrown at the end. Cancellation, provider discovery failure and a
    /// changed selection stop the run immediately.
    /// </summary>
    public async Task<int?> RunAsync(CancellationToken ct = default)
    {
        var selected = _selection();
        if (selected.ProfileId is null) return null;
        var profile = EmbeddingProfiles.Require(selected.ProfileId);
        PreparedEmbeddingProfile? prepared = null;
        int written = 0;
        Exception? deferred = null;
        foreach (long notebookId in _store.ProfileEmbeddingWork(selected))
        {
            ct.ThrowIfCancellationRequested();
            var previous = _store.ActiveGeneration(notebookId);
            try
            {
                GenerationIdentity identity;
                ProviderEmbeddingSession session;
                if (previous is not null && NotebookStore.ProfileIdentityMatches(previous.Identity, selected, profile))
                {
                    session = await _resume(previous.Identity, ct).ConfigureAwait(false);
                    identity = previous.Identity;
                }
                else
                {
                    if (prepared is null)
                    {
                        try { prepared = await _prepare(selected, ct).ConfigureAwait(false); }
                        catch (Exception error) when (error is not OperationCanceledException)
                        {
                            throw new DiscoveryFailure(error);
                        }
                    }
                    identity = prepared.Identity;
                    session = prepared.Session;
                }
                ct.ThrowIfCancellationRequested();
                if (!Same(_selection(), selected)) throw new ProfileEmbeddingDrainException("selectionChanged");
                written += await BuildAsync(notebookId, identity, session, previous?.Id, ct).ConfigureAwait(false);
            }
            catch (DiscoveryFailure failure) { ExceptionDispatchInfo.Throw(failure.InnerException!); }
            catch (ProfileEmbeddingDrainException error) when (error.Code == "selectionChanged") { throw; }
            catch (OperationCanceledException) { throw; }
            catch (Exception error) { deferred ??= error; }
        }
        if (deferred is not null) ExceptionDispatchInfo.Throw(deferred);
        return written;
    }

    private async Task<int> BuildAsync(long notebookId, GenerationIdentity identity, ProviderEmbeddingSession session,
        long? previousActiveId, CancellationToken ct)
    {
        // Same guard as the public staging overload: the whole captured identity, never a storage key alone.
        if (session.Identity is not { } captured || captured != identity
            || !string.Equals(session.EndpointRevision, identity.EndpointRevision, StringComparison.Ordinal))
            throw new EmbeddingGenerationException("profileIdentityMismatch");
        var (generation, fence) = _store.BeginProfileEmbedding(notebookId, identity, _clock.Now, Guid.NewGuid().ToString("N"));
        var progress = new Progress();
        using var stage = CancellationTokenSource.CreateLinkedTokenSource(ct);
        using var renewalStop = new CancellationTokenSource();
        var renewal = RenewAsync(fence, stage, progress, renewalStop.Token);
        Exception? failure = null;
        try
        {
            await EmbeddingGenerationBuilder.StageAsync(_store, notebookId, identity, () => _clock.Now,
                async (inputs, token) =>
                {
                    var vectors = await session.EmbedDocumentsAsync(inputs, token).ConfigureAwait(false);
                    Interlocked.Add(ref progress.Embedded, vectors.Length);
                    return vectors;
                }, generation, reuseActive: true, stage.Token).ConfigureAwait(false);
        }
        catch (Exception error) { failure = error; }
        renewalStop.Cancel();
        await renewal.ConfigureAwait(false);
        if (Volatile.Read(ref progress.LeaseLost)) throw new ProfileEmbeddingDrainException("leaseLost");
        if (failure is not null)
        {
            if (failure is OperationCanceledException || ct.IsCancellationRequested)
            {
                try { _store.CancelJob(fence, _clock.Now); } catch (Exception) { /* Preserve the cancellation. */ }
                ct.ThrowIfCancellationRequested();
            }
            else
                try { _store.FailEmbeddingJob(fence, FailureCode(failure), _clock.Now); } catch (Exception) { /* Preserve the failure. */ }
            ExceptionDispatchInfo.Throw(failure);
        }
        ProfileActivationOutcome outcome;
        try
        {
            // The selection is re-read after the last await, inside the publication transaction.
            outcome = _store.ProfileActivation(generation.Id, previousActiveId, fence, _selection(), _clock.Now);
        }
        catch (Exception error)
        {
            try { _store.FailEmbeddingJob(fence, FailureCode(error), _clock.Now); } catch (Exception) { /* Preserve the failure. */ }
            throw;
        }
        return outcome switch
        {
            ProfileActivationOutcome.Activated => Volatile.Read(ref progress.Embedded),
            ProfileActivationOutcome.LeaseLost => throw new ProfileEmbeddingDrainException("leaseLost"),
            ProfileActivationOutcome.SelectionChanged => throw new ProfileEmbeddingDrainException("selectionChanged"),
            ProfileActivationOutcome.ActiveChanged => throw new ProfileEmbeddingDrainException("activeChanged"),
            _ => throw new ProfileEmbeddingDrainException("invalidGeneration")
        };
    }

    /// <summary>Renews every <see cref="RenewalInterval"/> seconds; a failed renewal cancels the in-flight stage.</summary>
    private async Task RenewAsync(JobFence fence, CancellationTokenSource stage, Progress progress, CancellationToken ct)
    {
        try
        {
            while (true)
            {
                await _clock.WaitUntilAsync(_clock.Now + RenewalInterval, ct).ConfigureAwait(false);
                if (!_store.RenewJob(fence, _clock.Now))
                {
                    Volatile.Write(ref progress.LeaseLost, true);
                    stage.Cancel();
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
        catch (Exception)
        {
            Volatile.Write(ref progress.LeaseLost, true);
            stage.Cancel();
        }
    }

    /// <summary>Sanitized job error: typed codes only, never provider text.</summary>
    internal static string FailureCode(Exception error) => error switch
    {
        EmbeddingGenerationException e => e.Code,
        EmbeddingProfileException e => e.Code,
        StorageV19Exception e => e.Code,
        _ => "provider-error"
    };

    private static bool Same(EmbeddingModelChoice a, EmbeddingModelChoice b) =>
        string.Equals(a.ProviderId, b.ProviderId, StringComparison.Ordinal)
        && string.Equals(a.Model, b.Model, StringComparison.Ordinal)
        && string.Equals(a.ProfileId, b.ProfileId, StringComparison.Ordinal);

    private sealed class Progress
    {
        public int Embedded;
        public bool LeaseLost;
    }

    private sealed class DiscoveryFailure(Exception inner) : Exception(inner.Message, inner);
}
