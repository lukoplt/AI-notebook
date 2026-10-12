using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

/// <summary>
/// Indexing status of ONE notebook (contract indexing-status-v1), for the Sources strip and the right-panel dot. Refreshes
/// on <see cref="NotebookStore.IndexingStatusChanged"/> for that notebook only (raised on any thread, marshalled to the
/// UI dispatcher) and polls about once a second only while the status is active (scanning / extracting / embedding /
/// retrying) or <see cref="ExtraPolling"/> asks for it. No WinUI controls, so App.Tests cover it.
/// </summary>
public sealed partial class IndexingStatusWatcher : ObservableObject
{
    private readonly Func<long, CancellationToken, Task<IndexingStatus>> _fetch;
    private readonly NotebookStore? _store;
    private readonly DispatcherQueue? _dispatcher;
    private readonly object _gate = new();
    private CancellationTokenSource? _loop;
    private long? _notebookId;
    private int _refreshQueued;
    private long _requests;

    /// <param name="dispatcher">UI queue; null applies results inline (tests).</param>
    public IndexingStatusWatcher(Func<long, CancellationToken, Task<IndexingStatus>> fetch, NotebookStore? store,
        DispatcherQueue? dispatcher)
    {
        _fetch = fetch ?? throw new ArgumentNullException(nameof(fetch));
        _store = store;
        _dispatcher = dispatcher;
    }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Additional reason to keep polling (e.g. a folder row waiting for its scan outcome).</summary>
    public Func<bool>? ExtraPolling { get; set; }

    /// <summary>Latest status of <see cref="NotebookId"/>; null before the first load or without a notebook.</summary>
    [ObservableProperty]
    public partial IndexingStatus? Status { get; private set; }

    /// <summary>Raised on the UI thread after every applied read (even when the status did not change).</summary>
    public event Action? Refreshed;

    /// <summary>Message of the last failed status read (cleared by the next successful one).</summary>
    [ObservableProperty]
    public partial string? LoadError { get; private set; }

    public bool IsRunning
    {
        get { lock (_gate) return _loop is not null; }
    }

    /// <summary>The watched notebook; changing it drops the previous status and reloads.</summary>
    public long? NotebookId
    {
        get { lock (_gate) return _notebookId; }
        set
        {
            lock (_gate)
            {
                if (_notebookId == value) return;
                _notebookId = value;
            }
            OnUi(() => { Status = null; LoadError = null; Refreshed?.Invoke(); });
            _ = RefreshAsync();
        }
    }

    /// <summary>True while the next tick should re-read the status.</summary>
    internal bool ShouldPoll => NotebookId is not null && (Status?.IsActive == true || ExtraPolling?.Invoke() == true);

    public void Start()
    {
        CancellationTokenSource loop;
        lock (_gate)
        {
            if (_loop is not null) return;
            _loop = loop = new CancellationTokenSource();
        }
        if (_store is not null) _store.IndexingStatusChanged += OnStatusChanged;
        _ = Task.Run(() => PollAsync(loop.Token), CancellationToken.None);
        _ = RefreshAsync();
    }

    public void Stop()
    {
        CancellationTokenSource? loop;
        lock (_gate)
        {
            loop = _loop;
            _loop = null;
        }
        if (loop is null) return;
        if (_store is not null) _store.IndexingStatusChanged -= OnStatusChanged;
        loop.Cancel();
        loop.Dispose();
    }

    /// <summary>Store signal (any thread): only the watched notebook counts; bursts coalesce into one read.</summary>
    internal void OnStatusChanged(long notebookId)
    {
        if (notebookId != NotebookId || Interlocked.Exchange(ref _refreshQueued, 1) == 1) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(100).ConfigureAwait(false);
            Interlocked.Exchange(ref _refreshQueued, 0);
            await RefreshAsync().ConfigureAwait(false);
        });
    }

    /// <summary>Reads the status off the UI thread; a result for a notebook no longer watched (or overtaken) is dropped.</summary>
    public async Task RefreshAsync()
    {
        long? notebook = NotebookId;
        long request = Interlocked.Increment(ref _requests);
        if (notebook is not long id)
        {
            OnUi(() => Status = null);
            return;
        }
        try
        {
            var status = await Task.Run(() => _fetch(id, CancellationToken.None)).ConfigureAwait(false);
            OnUi(() =>
            {
                if (NotebookId != id || request < Interlocked.Read(ref _requests) && Status is not null) return;
                Status = status;
                LoadError = null;
                Refreshed?.Invoke();
            });
        }
        catch (Exception error)
        {
            string message = string.IsNullOrWhiteSpace(error.Message) ? error.GetType().Name : error.Message;
            OnUi(() => { if (NotebookId == id) LoadError = message; });
        }
    }

    private async Task PollAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await Task.Delay(PollInterval, ct).ConfigureAwait(false);
                if (ShouldPoll) await RefreshAsync().ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) { }
    }

    private void OnUi(Action action)
    {
        if (_dispatcher is null || _dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }
}
