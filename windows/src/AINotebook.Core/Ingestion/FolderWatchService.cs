using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Raw recursive native watch. It only forwards event kinds (created, changed, deleted, renamed; overflow on Error);
/// there is no debounce, hashing or extraction here — the runtime owns scheduling. Every handler is subscribed
/// before raising is enabled; disposal disables, unsubscribes and invalidates the callback.
/// </summary>
public sealed class NativeFolderWatchHandle : IFolderWatchHandle
{
    private readonly Action<string> _signal;
    private readonly object _gate = new();
    private FileSystemWatcher? _watcher;
    private int _valid = 1;

    public NativeFolderWatchHandle(string folder, Action<string> signal)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        WatchedFolder = folder;
        _signal = signal ?? throw new ArgumentNullException(nameof(signal));
    }

    public string WatchedFolder { get; }

    public bool IsActive
    {
        get { lock (_gate) return _watcher is { EnableRaisingEvents: true }; }
    }

    public void Start()
    {
        lock (_gate)
        {
            if (Volatile.Read(ref _valid) == 0) throw new ObjectDisposedException(nameof(NativeFolderWatchHandle));
            if (_watcher is not null) return;
            var watcher = new FileSystemWatcher(WatchedFolder)
            {
                IncludeSubdirectories = true,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size
            };
            watcher.Created += OnCreated;
            watcher.Changed += OnChanged;
            watcher.Deleted += OnDeleted;
            watcher.Renamed += OnRenamed;
            watcher.Error += OnError;
            _watcher = watcher;
            watcher.EnableRaisingEvents = true;
        }
    }

    public void Dispose()
    {
        FileSystemWatcher? watcher;
        lock (_gate)
        {
            Interlocked.Exchange(ref _valid, 0);
            watcher = _watcher;
            _watcher = null;
        }
        if (watcher is null) return;
        watcher.EnableRaisingEvents = false;
        watcher.Created -= OnCreated;
        watcher.Changed -= OnChanged;
        watcher.Deleted -= OnDeleted;
        watcher.Renamed -= OnRenamed;
        watcher.Error -= OnError;
        watcher.Dispose();
    }

    private void OnCreated(object? sender, FileSystemEventArgs e) => Raise("created");
    private void OnChanged(object? sender, FileSystemEventArgs e) => Raise("changed");
    private void OnDeleted(object? sender, FileSystemEventArgs e) => Raise("deleted");
    private void OnRenamed(object? sender, RenamedEventArgs e) => Raise("renamed");
    // A buffer overflow (or any watcher error) means events were lost: request a full re-hashing scan.
    private void OnError(object? sender, ErrorEventArgs e) => Raise("overflow");

    /// <summary>Test seam for platform events that cannot be produced on demand (overflow).</summary>
    internal void RaiseForTests(string kind) => Raise(kind);

    private void Raise(string kind)
    {
        if (Volatile.Read(ref _valid) == 0) return;
        try { _signal(kind); }
        catch (Exception error) { System.Diagnostics.Trace.TraceError("Folder watch signal failed: {0}", error.GetType().Name); }
    }
}

/// <summary>
/// Deprecated E1 facade, kept for existing view callers until the persisted folder UI replaces them. It delegates to
/// the durable runtime (persisted folder, recursive watch, scans); it never extracts, hashes or re-ingests itself.
/// Commands run in the background, in order, and record failures in <see cref="LastError"/>.
/// </summary>
public sealed class FolderWatchService : IDisposable
{
    private readonly FolderIngestionRuntime _runtime;
    private readonly object _gate = new();
    private long? _folderId;
    private Task _pending = Task.CompletedTask;

    public FolderWatchService(FolderIngestionRuntime runtime) =>
        _runtime = runtime ?? throw new ArgumentNullException(nameof(runtime));

    public bool IsActive { get { lock (_gate) return WatchedFolder is not null; } }
    public string? WatchedFolder { get; private set; }
    public Exception? LastError { get; private set; }

    public void Enable(long notebookId, string folder)
    {
        ArgumentException.ThrowIfNullOrEmpty(folder);
        Disable();
        lock (_gate)
        {
            WatchedFolder = folder;
            Enqueue(async () =>
            {
                // Re-enabling a persisted root resumes its watch instead of adding an overlapping duplicate.
                var existing = _runtime.Store.Folders(notebookId)
                    .FirstOrDefault(f => StringComparer.Ordinal.Equals(f.Draft.RootPath, folder));
                long id;
                if (existing is not null)
                {
                    id = existing.Id;
                    await _runtime.SetWatchingAsync(id, true).ConfigureAwait(false);
                    await _runtime.ScanNowAsync(id, false).ConfigureAwait(false);
                }
                else id = (await _runtime.AddFolderAsync(notebookId, folder).ConfigureAwait(false)).Id;
                // Commands are serialized: a Disable issued meanwhile runs next and releases exactly this folder.
                lock (_gate) _folderId = id;
            });
        }
    }

    public void Disable()
    {
        lock (_gate)
        {
            if (WatchedFolder is null) return;
            WatchedFolder = null;
            Enqueue(async () =>
            {
                long? folderId;
                lock (_gate)
                {
                    folderId = _folderId;
                    _folderId = null;
                }
                if (folderId is long id) await _runtime.SetWatchingAsync(id, false).ConfigureAwait(false);
            });
        }
    }

    /// <summary>Test seam: completes when every previously issued command has finished.</summary>
    internal Task WhenIdleAsync()
    {
        lock (_gate) return _pending;
    }

    public void Dispose() => Disable();

    private void Enqueue(Func<Task> command)
    {
        // Caller holds _gate. Commands are serialized; a failure is recorded and never breaks the chain.
        _pending = _pending.ContinueWith(async _ =>
        {
            try { await command().ConfigureAwait(false); }
            catch (Exception error) { LastError = error; }
        }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
    }
}
