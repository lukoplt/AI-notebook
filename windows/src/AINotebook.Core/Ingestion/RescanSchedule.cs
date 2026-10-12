namespace AINotebook.Core.Ingestion;

/// <summary>
/// Debounced rescan deadline on a monotonic millisecond clock: <c>min(last + 500, first + 5000)</c>.
/// Continuous signals cannot postpone the first deadline past the maximum coalesce window. Signals
/// that arrive while a scan runs accumulate a separate trailing pair, scheduling exactly one follow-up.
/// Not thread-safe; the owning runtime serializes access.
/// </summary>
public sealed class RescanSchedule
{
    private const long Debounce = 500;
    private const long MaximumCoalesce = 5000;

    public long? DueAt { get; private set; }
    internal bool Running { get; private set; }
    internal long? FirstSignal { get; private set; }
    internal long? LastSignal { get; private set; }
    internal long? TrailingFirstSignal { get; private set; }
    internal long? TrailingLastSignal { get; private set; }
    internal int StartedScanCount { get; private set; }

    public void Signal(long milliseconds)
    {
        if (Running)
        {
            TrailingFirstSignal ??= milliseconds;
            TrailingLastSignal = milliseconds;
            return;
        }
        FirstSignal ??= milliseconds;
        LastSignal = milliseconds;
        DueAt = Deadline(FirstSignal.Value, milliseconds);
    }

    public bool IsDue(long milliseconds) => !Running && DueAt is long due && due <= milliseconds;

    public void Started()
    {
        Running = true;
        DueAt = null;
        FirstSignal = null;
        LastSignal = null;
        StartedScanCount++;
    }

    public void Finished(long milliseconds)
    {
        Running = false;
        FirstSignal = TrailingFirstSignal;
        LastSignal = TrailingLastSignal;
        TrailingFirstSignal = null;
        TrailingLastSignal = null;
        DueAt = FirstSignal is long first && LastSignal is long last ? Deadline(first, last) : null;
    }

    private static long Deadline(long first, long last) => Math.Min(checked(last + Debounce), checked(first + MaximumCoalesce));
}
