using AINotebook.Core.Ingestion;

namespace AINotebook.App.ViewModels;

/// <summary>
/// Folder-row feedback for "Scan now" / "Verify all" (spec §4): an optimistic "Checking…" from the click until the
/// runtime reports a newer <see cref="FolderScanOutcome"/> (or <see cref="CheckTimeout"/> passes), then a transient
/// caption for <see cref="CaptionDuration"/>. Per folder id, so it survives the panel's row reloads. Thread-safe (the
/// status poll reads <see cref="NeedsTicks"/> off the UI thread).
/// </summary>
public sealed class FolderScanFeedback
{
    private sealed record Pending(long? BaselineFinishedAt, DateTimeOffset StartedAt);

    private readonly Dictionary<long, Pending> _pending = new();
    private readonly Dictionary<long, (FolderScanOutcome Outcome, DateTimeOffset Until)> _captions = new();
    private readonly object _gate = new();

    public TimeSpan CaptionDuration { get; init; } = TimeSpan.FromSeconds(4);

    /// <summary>A scan that never reports (e.g. the job failed) stops spinning after this.</summary>
    public TimeSpan CheckTimeout { get; init; } = TimeSpan.FromMinutes(2);

    public IReadOnlyList<long> PendingFolderIds
    {
        get { lock (_gate) return _pending.Keys.ToArray(); }
    }

    /// <summary>The user asked for a scan; <paramref name="baseline"/> is the outcome known before the click.</summary>
    public void Begin(long folderId, FolderScanOutcome? baseline, DateTimeOffset now)
    {
        lock (_gate)
        {
            _pending[folderId] = new Pending(baseline?.FinishedAt, now);
            _captions.Remove(folderId);
        }
    }

    /// <summary>The request itself failed: no spinner, no caption.</summary>
    public void Cancel(long folderId)
    {
        lock (_gate) _pending.Remove(folderId);
    }

    /// <summary>
    /// Feeds the folder's latest outcome; a newer one than the baseline ends "Checking…" and starts the caption.
    /// True when the row's presentation changed.
    /// </summary>
    public bool Observe(long folderId, FolderScanOutcome? latest, DateTimeOffset now)
    {
        lock (_gate) return ObserveLocked(folderId, latest, now);
    }

    private bool ObserveLocked(long folderId, FolderScanOutcome? latest, DateTimeOffset now)
    {
        if (!_pending.TryGetValue(folderId, out var pending)) return false;
        if (latest is not null && (pending.BaselineFinishedAt is not long before || latest.FinishedAt > before))
        {
            _pending.Remove(folderId);
            _captions[folderId] = (latest, now + CaptionDuration);
            return true;
        }
        if (now - pending.StartedAt < CheckTimeout) return false;
        _pending.Remove(folderId);
        return true;
    }

    /// <summary>Optimistic local state, or the folder's persisted scan state says it is scanning.</summary>
    public bool IsChecking(long folderId, string? scanState)
    {
        lock (_gate) return _pending.ContainsKey(folderId) || string.Equals(scanState, "scanning", StringComparison.Ordinal);
    }

    /// <summary>The finished scan to caption, until it expires.</summary>
    public FolderScanOutcome? Caption(long folderId, DateTimeOffset now)
    {
        lock (_gate)
        {
            if (!_captions.TryGetValue(folderId, out var caption)) return null;
            if (now < caption.Until) return caption.Outcome;
            _captions.Remove(folderId);
            return null;
        }
    }

    /// <summary>Something still needs a periodic re-check (a pending scan or a caption to expire).</summary>
    public bool NeedsTicks
    {
        get { lock (_gate) return _pending.Count > 0 || _captions.Count > 0; }
    }

    /// <summary>Drops expired captions; true when one expired.</summary>
    public bool Expire(DateTimeOffset now)
    {
        lock (_gate)
        {
            var expired = _captions.Where(c => now >= c.Value.Until).Select(c => c.Key).ToList();
            foreach (long id in expired) _captions.Remove(id);
            return expired.Count > 0;
        }
    }
}
