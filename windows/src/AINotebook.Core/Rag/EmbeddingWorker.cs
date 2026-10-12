namespace AINotebook.Core.Rag;

/// Coalescing background drain runner. Kick() is idempotent: while a drain is
/// in flight, additional kicks set a "run again when this finishes" flag.
public sealed class EmbeddingWorker
{
    private readonly Func<CancellationToken, Task<int>> _drain;
    private readonly object _gate = new();
    private Task? _inFlight;
    private bool _pendingKick;

    public Exception? LastError { get; private set; }
    public int TotalEmbedded { get; private set; }

    /// Legacy compatibility worker over an isolated Embedder (tests only; not registered in production).
    public EmbeddingWorker(Embedder embedder)
    {
        ArgumentNullException.ThrowIfNull(embedder);
        _drain = ct => embedder.EmbedAllPendingAsync(ct);
    }

    /// Production worker: a kick wakes durable generation work (e.g. FolderIngestionRuntime.RequestEmbeddingWorkAsync);
    /// it never also runs the legacy Embedder.
    public EmbeddingWorker(Func<CancellationToken, Task<int>> drain) =>
        _drain = drain ?? throw new ArgumentNullException(nameof(drain));

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
                var n = await _drain(CancellationToken.None);
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
