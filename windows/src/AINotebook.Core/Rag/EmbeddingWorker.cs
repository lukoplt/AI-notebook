namespace AINotebook.Core.Rag;

/// Coalescing background drain runner. Kick() is idempotent: while a drain is
/// in flight, additional kicks set a "run again when this finishes" flag.
public sealed class EmbeddingWorker
{
    private readonly Embedder _embedder;
    private readonly object _gate = new();
    private Task? _inFlight;
    private bool _pendingKick;

    public Exception? LastError { get; private set; }
    public int TotalEmbedded { get; private set; }

    public EmbeddingWorker(Embedder embedder) => _embedder = embedder;

    public void Kick()
    {
        lock (_gate)
        {
            if (_inFlight is null)
                _inFlight = Task.Run(DrainAsync);
            else
                _pendingKick = true;
        }
    }

    private async Task DrainAsync()
    {
        do
        {
            lock (_gate) _pendingKick = false;
            try
            {
                var n = await _embedder.EmbedAllPendingAsync();
                lock (_gate)
                {
                    TotalEmbedded += n;
                    LastError = null;
                }
            }
            catch (Exception e)
            {
                lock (_gate) LastError = e;
            }
        }
        while (ReadPending());

        lock (_gate) _inFlight = null;
    }

    private bool ReadPending()
    {
        lock (_gate) return _pendingKick;
    }

    /// Test-only: wait until the current drain finishes (returns immediately if none).
    public async Task WaitUntilIdleAsync()
    {
        Task? task;
        lock (_gate) task = _inFlight;
        if (task is not null) await task;
    }
}
