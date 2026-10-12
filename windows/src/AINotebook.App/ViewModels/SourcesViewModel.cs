using System.Collections.ObjectModel;
using System.Globalization;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;  // IChatStreaming
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public sealed partial class SourcesViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly Func<StringKey, string> _text;
    private readonly IChatStreaming _chatStreaming;
    private readonly ISettingsService _settings;
    private readonly DispatcherQueue? _dispatcher;
    private readonly IngestionService _ingestion;
    private readonly FolderIngestionRuntime _runtime;
    private FolderScanner? _rulesScanner;
    private int _reloadQueued;
    private bool _attached;
    private long _notebookId;
    // The shown error came from a failed reload (a later successful reload clears it); action errors stay until dismissed.
    private bool _errorFromLoad;

    /// <summary>The notebook shown; the indexing status follows it (never an aggregate over notebooks).</summary>
    public long NotebookId
    {
        get => _notebookId;
        set
        {
            _notebookId = value;
            Indexing.NotebookId = value;
        }
    }

    /// <summary>Per-notebook indexing status (contract indexing-status-v1) for the status strip.</summary>
    public IndexingStatusWatcher Indexing { get; }

    /// <summary>"Checking…" and "No changes · N files up to date" for user-requested folder scans.</summary>
    public FolderScanFeedback ScanFeedback { get; } = new();

    /// <summary>Wall clock for the folder-row feedback (tests substitute it).</summary>
    internal Func<DateTimeOffset> Now { get; set; } = () => DateTimeOffset.UtcNow;

    /// <summary>The status strip at the top of the panel (spec §4).</summary>
    [ObservableProperty]
    public partial IndexingStripDisplay IndexingDisplay { get; private set; } = IndexingStripDisplay.Hidden;

    /// <summary>"Open settings" on a blocked status: the section that fixes it.</summary>
    public event Action<SettingsSection>? SettingsRequested;

    /// <summary>Loose (non-folder) sources; folder members live in their <see cref="FolderRowViewModel.Members"/>.</summary>
    public ObservableCollection<SourceItem> Sources { get; } = new();

    /// <summary>
    /// The single virtualized list: each folder row, then (when expanded) its loaded members and a footer,
    /// then the loose sources. Replaced wholesale on reload; patched in place on expand / collapse / load more.
    /// </summary>
    [ObservableProperty]
    public partial ObservableCollection<object> Rows { get; set; } = new();

    /// <summary>Expanded folders and how many members each has loaded; survives reloads.</summary>
    private readonly Dictionary<long, int> _expanded = new();

    /// <summary>Persisted folders of this notebook with their coverage snapshot (shown above the sources).</summary>
    public ObservableCollection<FolderRowViewModel> FolderRows { get; } = new();

    [ObservableProperty]
    public partial bool IsEmpty { get; set; } = true;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial bool IsBulkMode { get; set; }

    /// <summary>Loose sources shown only with this tag (macOS SourceListView parity); null = all.</summary>
    [ObservableProperty]
    public partial long? TagFilterId { get; set; }

    partial void OnTagFilterIdChanged(long? value) => Rows = new ObservableCollection<object>(Flatten(FolderRows, FilterByTag(Sources, value)));

    /// <summary>Loose sources carrying <paramref name="tagId"/> (all when null).</summary>
    public static IEnumerable<SourceItem> FilterByTag(IEnumerable<SourceItem> sources, long? tagId) =>
        tagId is long id ? sources.Where(s => s.Tags.Any(t => t.Id == id)) : sources;

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
    partial void OnErrorMessageChanged(string? value)
    {
        _errorFromLoad = false; // any direct assignment is an action error (or a dismissal); SetLoadError re-marks
        OnPropertyChanged(nameof(HasError));
    }

    private void SetLoadError(string message)
    {
        ErrorMessage = message;
        _errorFromLoad = true;
    }

    // B8: global tag list for the manage-tags dialog.
    public ObservableCollection<Tag> AllTags { get; } = new();

    /// <summary>Loose sources plus every loaded folder member (bulk selection spans both).</summary>
    public IEnumerable<SourceItem> AllSourceItems => Sources.Concat(FolderRows.SelectMany(r => r.Members));

    public IReadOnlyList<long> SelectedSourceIds =>
        AllSourceItems.Where(s => s.IsSelected).Select(s => s.Id).ToList();

    public SourcesViewModel(NotebookStore store, LocalizedStrings strings,
                            IChatStreaming chatStreaming, ISettingsService settings,
                            IngestionService ingestion, FolderIngestionRuntime runtime)
        : this(store, strings.Get, chatStreaming, settings, ingestion, runtime, DispatcherQueue.GetForCurrentThread())
    {
    }

    /// <param name="dispatcher">UI queue; null applies results inline (App.Tests).</param>
    /// <param name="fetchStatus">Status source; defaults to the runtime (tests substitute it).</param>
    internal SourcesViewModel(NotebookStore store, Func<StringKey, string> text,
                              IChatStreaming chatStreaming, ISettingsService settings,
                              IngestionService ingestion, FolderIngestionRuntime runtime, DispatcherQueue? dispatcher,
                              Func<long, CancellationToken, Task<IndexingStatus>>? fetchStatus = null)
    {
        _store = store;
        _text = text;
        _chatStreaming = chatStreaming;
        _settings = settings;
        _ingestion = ingestion;
        _runtime = runtime;
        _dispatcher = dispatcher;
        Indexing = new IndexingStatusWatcher(fetchStatus ?? ((nb, ct) => runtime.IndexingStatusAsync(nb, ct)), store, dispatcher)
        {
            ExtraPolling = () => ScanFeedback.NeedsTicks,
        };
        Indexing.Refreshed += OnIndexingStatus;
        // A failed status read shows its real message (once per failure streak; a dismissal is not undone by the poll).
        Indexing.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(IndexingStatusWatcher.LoadError) && Indexing.LoadError is { } error) ErrorMessage = error;
        };
    }

    private void OnUi(Action action)
    {
        if (_dispatcher is null || _dispatcher.HasThreadAccess) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    /// <summary>An empty notebook has neither loose sources nor persisted folders (a skipped-only folder still shows).</summary>
    public static bool ComputeIsEmpty(int sourceCount, int folderCount) => sourceCount == 0 && folderCount == 0;

    /// <summary>Flattened list order: folder, its loaded members and footer when expanded, then loose sources.</summary>
    public static List<object> Flatten(IEnumerable<FolderRowViewModel> folders, IEnumerable<SourceItem> loose)
    {
        var rows = new List<object>();
        foreach (var folder in folders)
        {
            rows.Add(folder);
            if (!folder.IsExpanded) continue;
            rows.AddRange(folder.Members);
            rows.Add(folder.Footer);
        }
        rows.AddRange(loose);
        return rows;
    }

    private sealed record LoadedSource(Source Source, string? Summary, List<Tag> Tags);

    private LoadedSource LoadDetails(Source source) =>
        new(source, _store.SourceSummary(source.Id!.Value), _store.TagsForSource(source.Id!.Value).ToList());

    /// <summary>Reads <paramref name="count"/> members from <paramref name="offset"/> in store-sized pages (call off the UI thread).</summary>
    private (List<LoadedSource> Members, int Total) LoadMembers(long folderId, int offset, int count)
    {
        var members = new List<LoadedSource>();
        int total = 0;
        while (true)
        {
            int limit = Math.Min(NotebookStore.FolderMembersMaxLimit, Math.Max(1, count - members.Count));
            var page = _store.FolderMembers(folderId, offset + members.Count, limit);
            total = page.Total;
            members.AddRange(page.Members.Select(LoadDetails));
            if (page.Members.Count == 0 || !page.HasMore || members.Count >= count) break;
        }
        return (members, total);
    }

    /// <summary>Sources of the notebook whose extraction was given up (refreshed by every load).</summary>
    private IReadOnlySet<long> _gaveUp = new HashSet<long>();

    private SourceItem MakeItem(LoadedSource loaded)
    {
        var item = new SourceItem(loaded.Source, _text)
        {
            Summary = loaded.Summary, IsBulkMode = IsBulkMode, IsGaveUp = _gaveUp.Contains(loaded.Source.Id!.Value),
        };
        foreach (var t in loaded.Tags) item.Tags.Add(t);
        return item;
    }

    /// <summary>Expands (loading the first page lazily) or collapses one folder's member list.</summary>
    public async Task ToggleFolderAsync(FolderRowViewModel row)
    {
        long id = row.Folder.Id;
        if (row.IsExpanded)
        {
            row.IsExpanded = false;
            lock (_expanded) _expanded.Remove(id);
            int index = Rows.IndexOf(row);
            int removed = row.Members.Count + 1; // members and footer
            row.Members.Clear();
            if (index < 0) return;
            if (removed > NotebookStore.FolderMembersPageSize)
                Rows = new ObservableCollection<object>(Flatten(FolderRows, FilterByTag(Sources, TagFilterId))); // one reset beats thousands of removals
            else
                for (int i = 0; i < removed && index + 1 < Rows.Count; i++) Rows.RemoveAt(index + 1);
            return;
        }
        row.IsExpanded = true;
        lock (_expanded) _expanded[id] = NotebookStore.FolderMembersPageSize;
        row.Footer.IsLoading = true;
        int at = Rows.IndexOf(row);
        if (at >= 0) Rows.Insert(at + 1, row.Footer);
        await AppendMembersAsync(row);
    }

    /// <summary>Loads the next page of an expanded folder's members.</summary>
    public async Task LoadMoreMembersAsync(FolderFooterRow footer)
    {
        var row = FolderRows.FirstOrDefault(r => r.Folder.Id == footer.FolderId);
        if (row is null || !row.IsExpanded || footer.IsLoading) return;
        footer.IsLoading = true;
        await AppendMembersAsync(row);
    }

    private async Task AppendMembersAsync(FolderRowViewModel row)
    {
        long id = row.Folder.Id;
        int offset = row.Members.Count;
        try
        {
            var (members, total) = await Task.Run(() => LoadMembers(id, offset, NotebookStore.FolderMembersPageSize));
            // A reload or collapse while loading replaced or closed this row; its own load wins.
            if (!row.IsExpanded || !FolderRows.Contains(row) || row.Members.Count != offset) return;
            int at = Rows.IndexOf(row.Footer);
            foreach (var loaded in members)
            {
                var item = MakeItem(loaded);
                row.Members.Add(item);
                if (at >= 0) Rows.Insert(at++, item);
            }
            row.Footer.Total = total;
            row.Footer.Shown = row.Members.Count;
            lock (_expanded) if (_expanded.ContainsKey(id)) _expanded[id] = Math.Max(row.Members.Count, NotebookStore.FolderMembersPageSize);
        }
        catch (Exception ex) { ShowError(ex); }
        finally { row.Footer.IsLoading = false; }
    }

    /// <summary>The refreshed published SHA-256; a URL is never stored as a content hash.</summary>
    public static string SyncHashAfterRefresh(Source refreshed) =>
        refreshed.ContentHash ?? throw new InvalidOperationException("The refreshed source has no published content hash.");

    /// <summary>Subscribe to post-commit ingestion changes while the page is visible; the runtime keeps running.</summary>
    public void Attach()
    {
        if (_attached) return;
        _attached = true;
        _store.FolderIngestionChanged += OnFolderIngestionChanged;
        Indexing.Start();
    }

    public void Detach()
    {
        if (!_attached) return;
        _attached = false;
        _store.FolderIngestionChanged -= OnFolderIngestionChanged;
        Indexing.Stop();
    }

    // ---------------------------------------------------------------- indexing status strip

    /// <summary>Files counted as searchable for "Searchable · N files": folder coverage plus ready loose sources.</summary>
    public int SearchableFiles => FolderRows.Sum(r => r.Coverage.Searchable) + Sources.Count(s => s.Status == SourceStatus.Ready);

    private void OnIndexingStatus()
    {
        UpdateFolderFeedback();
        UpdateIndexingDisplay();
    }

    private void UpdateIndexingDisplay() => IndexingDisplay = IndexingStatusPresenter.Present(Indexing.Status, SearchableFiles, _text);

    /// <summary>Checks pending folder scans against the runtime's last outcome and refreshes every folder row.</summary>
    internal void UpdateFolderFeedback()
    {
        var now = Now();
        foreach (long folderId in ScanFeedback.PendingFolderIds)
            ScanFeedback.Observe(folderId, _runtime.LastScanOutcome(folderId), now);
        ScanFeedback.Expire(now);
        foreach (var row in FolderRows) ApplyFeedback(row, now);
    }

    private void ApplyFeedback(FolderRowViewModel row, DateTimeOffset now)
    {
        row.IsChecking = ScanFeedback.IsChecking(row.Folder.Id, row.Folder.ScanState);
        row.ScanCaption = !row.IsChecking && ScanFeedback.Caption(row.Folder.Id, now) is { } outcome
            ? IndexingStatusPresenter.ScanOutcomeCaption(outcome, _text) : null;
    }

    /// <summary>The strip's button: Retry now / Build index (runtime), or Open settings (shell navigation).</summary>
    public async Task RunIndexingActionAsync()
    {
        var display = IndexingDisplay;
        switch (display.Action)
        {
            case IndexingStripAction.OpenSettings when display.SettingsTarget is { } section:
                SettingsRequested?.Invoke(section);
                return;
            case IndexingStripAction.RetryNow or IndexingStripAction.BuildIndex:
                await RetryIndexingNowAsync();
                return;
        }
    }

    /// <summary>"Retry now" / "Build index": restarts a failed runtime, expedites a waiting retry or requests a build.</summary>
    public async Task RetryIndexingNowAsync()
    {
        long notebook = NotebookId;
        try { await Task.Run(() => _runtime.RetryIndexingNowAsync(notebook)); }
        catch (Exception ex) { ShowMessage(ex); }
        await Indexing.RefreshAsync();
    }

    /// <summary>"Retry" on a failed source, folder member or loose: its failure budget starts over (ingestion-retry-cap-v1 §5).</summary>
    public async Task RetrySourceAsync(SourceItem item)
    {
        if (!item.CanRetry) return;
        try { await Task.Run(() => _runtime.RetryFailedSourceAsync(item.Id)); }
        catch (Exception ex) { ShowMessage(ex); }
        await LoadAsync();
        await Indexing.RefreshAsync();
    }

    /// <summary>"Retry all failed" next to "N files couldn't be read".</summary>
    public async Task RetryAllFailedAsync()
    {
        long notebook = NotebookId;
        try { await Task.Run(() => _runtime.RetryFailedSourcesAsync(notebook)); }
        catch (Exception ex) { ShowMessage(ex); }
        await LoadAsync();
        await Indexing.RefreshAsync();
    }

    private void OnFolderIngestionChanged(long notebookId)
    {
        if (notebookId != NotebookId || Interlocked.Exchange(ref _reloadQueued, 1) == 1) return;
        // Coalesce bursts of observations into one presentation reload.
        _ = Task.Run(async () =>
        {
            await Task.Delay(250).ConfigureAwait(false);
            Interlocked.Exchange(ref _reloadQueued, 0);
            if (_attached) await LoadAsync().ConfigureAwait(false);
        });
    }

    public async Task AddFolderAsync(string path)
    {
        try
        {
            await _runtime.AddFolderAsync(NotebookId, path);
            await LoadAsync();
        }
        catch (Exception ex) { ShowError(ex); }
    }

    /// <summary>Scan now / Verify all: the row shows "Checking…" at once, then the outcome caption.</summary>
    public async Task ScanFolderAsync(long id, bool verifyAll)
    {
        ScanFeedback.Begin(id, _runtime.LastScanOutcome(id), Now());
        OnUi(UpdateFolderFeedback);
        try { await _runtime.ScanNowAsync(id, verifyAll); }
        catch (Exception ex)
        {
            ScanFeedback.Cancel(id);
            OnUi(UpdateFolderFeedback);
            ShowError(ex);
        }
        await Indexing.RefreshAsync();
    }

    public async Task SetFolderWatchingAsync(long id, bool enabled)
    {
        try { await _runtime.SetWatchingAsync(id, enabled); }
        catch (Exception ex)
        {
            // Roll the displayed toggle back to the persisted value.
            var row = FolderRows.FirstOrDefault(r => r.Folder.Id == id);
            OnUi(() => row?.SetWatchSilently(!enabled));
            ShowError(ex);
        }
    }

    /// <summary>Removes the folder from the notebook (database rows only; files on disk are kept).</summary>
    public async Task RemoveFolderAsync(long id)
    {
        try
        {
            await _runtime.RemoveFolderAsync(id);
            await LoadAsync();
        }
        catch (Exception ex) { ShowError(ex); }
    }

    public async Task SaveFolderRulesAsync(long id, FolderRules rules)
    {
        _rulesScanner ??= new FolderScanner(_store, new NativeFolderFileSystem(), UnicodeTables.LoadBundled());
        await _rulesScanner.ApplyRulesAsync(id, rules, DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        await LoadAsync();
    }

    /// <summary>Persisted folder error code (folder_sources.last_scan_error) to localized text; unknown → read error.</summary>
    public static StringKey FolderErrorKey(string? code) => code switch
    {
        "overlappingRoot" => StringKey.FolderOverlapError,
        "fileLimit" or "officeLimit" or "textLimit" or "pageLimit" or "chunkLimit" or "cellLimit" => StringKey.FolderLimitError,
        "unsupportedEncoding" => StringKey.FolderEncodingError,
        "corruptArchive" or "invalidRelationship" or "invalidCell" => StringKey.FolderDocumentError,
        "unsupportedSyntax" => StringKey.FolderRulesInvalid,
        _ => StringKey.FolderReadError
    };

    /// <summary>Maps persisted error codes to localized text; raw codes never become unexplained English.</summary>
    public static StringKey FolderErrorKey(Exception error) => error switch
    {
        StorageV19Exception { Code: "overlappingRoot" } => StringKey.FolderOverlapError,
        FolderIngestionException { Code: "fileLimit" or "officeLimit" or "textLimit" or "pageLimit" or "chunkLimit" or "cellLimit" }
            => StringKey.FolderLimitError,
        FolderIngestionException { Code: "unsupportedEncoding" } => StringKey.FolderEncodingError,
        FolderIngestionException { Code: "corruptArchive" or "invalidRelationship" or "invalidCell" } => StringKey.FolderDocumentError,
        FolderIngestionException { Code: "unsupportedSyntax" } => StringKey.FolderRulesInvalid,
        _ => StringKey.FolderReadError
    };

    private void ShowError(Exception ex)
    {
        string text = _text(FolderErrorKey(ex));
        OnUi(() => ErrorMessage = text);
    }

    /// <summary>The exception's own message (runtime and provider failures have no folder error code).</summary>
    private void ShowMessage(Exception ex)
    {
        string text = string.IsNullOrWhiteSpace(ex.Message) ? ex.GetType().Name : ex.Message;
        OnUi(() => ErrorMessage = text);
    }

    public async Task LoadAsync()
    {
        try
        {
            // Store access is synchronous + single-connection; run off the UI thread.
            // Only loose sources load eagerly (with summary and tags, Tier 2b); folder members are
            // paged per expanded folder so a folder with thousands of files never loads in full.
            long notebook = NotebookId;
            Dictionary<long, int> expanded;
            lock (_expanded) expanded = new Dictionary<long, int>(_expanded);
            _gaveUp = await Task.Run(() => _store.GaveUpSourceIds(notebook));
            var rows = await Task.Run(() => _store.LooseSources(notebook).Select(LoadDetails).ToList());
            var allTagRows = await Task.Run(() => _store.Tags().ToList());
            var folders = await Task.Run(() => _store.Folders(notebook)
                .Select(f => (Folder: f, Coverage: _store.Coverage(notebook,
                    new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long> { f.Id })),
                    Members: expanded.TryGetValue(f.Id, out int count)
                        ? LoadMembers(f.Id, 0, Math.Max(count, NotebookStore.FolderMembersPageSize))
                        : ((List<LoadedSource> Members, int Total)?)null))
                .ToList());
            void Apply()
            {
                // A late load for a previously selected notebook must not overwrite the current rows.
                if (notebook != NotebookId) return;
                FolderRows.Clear();
                lock (_expanded)
                {
                    foreach (var stale in _expanded.Keys.Where(k => folders.All(f => f.Folder.Id != k)).ToList())
                        _expanded.Remove(stale);
                }
                foreach (var (folder, coverage, members) in folders)
                {
                    var row = new FolderRowViewModel(folder, coverage, _text);
                    row.WatchChanged = (changed, enabled) => SetFolderWatchingAsync(changed.Folder.Id, enabled);
                    bool stillExpanded;
                    lock (_expanded) stillExpanded = _expanded.ContainsKey(folder.Id); // may have collapsed meanwhile
                    if (members is { } loaded && stillExpanded)
                    {
                        row.IsExpanded = true;
                        foreach (var member in loaded.Members) row.Members.Add(MakeItem(member));
                        row.Footer.Total = loaded.Total;
                        row.Footer.Shown = row.Members.Count;
                    }
                    else if (stillExpanded)
                    {
                        // Expanded after this load's snapshot: the old row's page is dropped, so show it collapsed.
                        lock (_expanded) _expanded.Remove(folder.Id);
                    }
                    FolderRows.Add(row);
                }
                Sources.Clear();
                foreach (var loaded in rows) Sources.Add(MakeItem(loaded));
                if (TagFilterId is long filter && allTagRows.All(t => t.Id != filter)) TagFilterId = null;
                Rows = new ObservableCollection<object>(Flatten(FolderRows, FilterByTag(Sources, TagFilterId)));
                IsEmpty = ComputeIsEmpty(Sources.Count, FolderRows.Count);
                AllTags.Clear();
                foreach (var t in allTagRows) AllTags.Add(t);
                // A successful reload clears only a previous reload failure, never a fresh action error.
                if (_errorFromLoad) ErrorMessage = null;
                UpdateFolderFeedback();
                UpdateIndexingDisplay();
            }
            OnUi(Apply);
        }
        catch (Exception ex)
        {
            // May run on a thread-pool continuation (ingestion change reloads): marshal like the success path.
            string message = string.IsNullOrWhiteSpace(ex.Message) ? ex.GetType().Name : ex.Message;
            OnUi(() => SetLoadError(message));
        }
    }

    // B8: toggle a tag on a source; create it first if it doesn't exist yet.
    public Tag GetOrCreateTag(string name)
    {
        var trimmed = name.Trim();
        var existing = AllTags.FirstOrDefault(t =>
            string.Equals(t.Name, trimmed, StringComparison.OrdinalIgnoreCase));
        if (existing is not null) return existing;
        var created = _store.CreateTag(trimmed);
        AllTags.Add(created);
        return created;
    }

    // B8: toggle a tag on/off for a source and persist.
    public void ToggleSourceTag(SourceItem item, Tag tag)
    {
        var had = item.Tags.Any(t => t.Id == tag.Id);
        if (had) item.Tags.Remove(item.Tags.First(t => t.Id == tag.Id));
        else item.Tags.Add(tag);
        _store.SetSourceTags(item.Id, item.Tags.Select(t => t.Id).ToList());
    }

    // B8: refresh the tag list for one source from the store (after bulk edits).
    public void RefreshSourceTags(SourceItem item)
    {
        item.Tags.Clear();
        foreach (var t in _store.TagsForSource(item.Id)) item.Tags.Add(t);
    }

    [RelayCommand]
    public async Task DeleteAsync(long id)
    {
        try
        {
            await Task.Run(() => _store.DeleteSource(id));
            await LoadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
    }

    [RelayCommand]
    private void ToggleBulkMode()
    {
        IsBulkMode = !IsBulkMode;
        foreach (var s in AllSourceItems)
        {
            s.IsBulkMode = IsBulkMode;
            if (!IsBulkMode) s.IsSelected = false;
        }
    }

    [RelayCommand]
    private async Task BulkDeleteAsync()
    {
        var ids = SelectedSourceIds.ToList();
        if (ids.Count == 0) return;
        try
        {
            await Task.Run(() => { foreach (var id in ids) _store.DeleteSource(id); });
            IsBulkMode = false;
            await LoadAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
    }

    // W-2 (B6): summarize every selected source.
    [RelayCommand]
    private async Task BulkSummarizeAsync()
    {
        var items = AllSourceItems.Where(s => s.IsSelected && !s.HasSummary).ToList();
        if (items.Count == 0) return;
        var summarizer = new SourceSummarizer(_store, _chatStreaming, _settings.SelectedChatModel);
        foreach (var item in items)
        {
            item.IsSummarizing = true;
            try
            {
                var text = await Task.Run(() => summarizer.SummarizeAsync(item.Id));
                OnUi(() => item.Summary = text);
            }
            catch (Exception ex) { ErrorMessage = ex.Message; }
            finally
            {
                OnUi(() => item.IsSummarizing = false);
            }
        }
        IsBulkMode = false;
    }

    // E2: re-crawl a URL source.
    [RelayCommand]
    public async Task RefreshUrlAsync(SourceItem? item)
    {
        if (item is null || !item.IsUrl) return;
        item.IsRefreshing = true;
        try
        {
            await Task.Run(() => _ingestion.ReIngestAsync(item.Id));
            // Keep the published SHA-256 of the refreshed revision; only the timestamp changes here.
            var refreshed = _store.Source(item.Id) ?? throw new InvalidOperationException("Source disappeared during refresh.");
            _store.UpdateSourceSyncInfo(item.Id, DateTime.UtcNow, SyncHashAfterRefresh(refreshed));
            await LoadAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.Message; }
        finally { item.IsRefreshing = false; }
    }

    // Tier 2b: lazily generate + persist a per-source summary on demand.
    [RelayCommand]
    public async Task SummarizeAsync(SourceItem? item)
    {
        if (item is null || item.IsSummarizing || item.HasSummary) return;
        item.IsSummarizing = true;
        try
        {
            var summarizer = new SourceSummarizer(
                _store, _chatStreaming, _settings.SelectedChatModel);
            var text = await Task.Run(() => summarizer.SummarizeAsync(item.Id));
            OnUi(() => item.Summary = text);
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.Message;
        }
        finally
        {
            OnUi(() => item.IsSummarizing = false);
        }
    }
}

/// <summary>A label and its integer count, kept as separate accessible text elements.</summary>
public sealed record FolderCount(string Label, string Value);

/// <summary>
/// One persisted folder: watch toggle, last full scan, and coverage on separate corpus and freshness lines
/// (never summed). An incomplete (partial) inventory is prefixed with "At least".
/// </summary>
public sealed partial class FolderRowViewModel : ObservableObject
{
    private readonly Func<StringKey, string> _text;
    private bool _silent;

    public FolderRowViewModel(FolderSource folder, CoverageSnapshot coverage, Func<StringKey, string> text)
    {
        Folder = folder;
        Coverage = coverage;
        _text = text;
        _silent = true;
        WatchEnabled = folder.Draft.WatchEnabled;
        _silent = false;
        Footer = new FolderFooterRow(folder.Id, text);
    }

    /// <summary>Members are collapsed by default and loaded page by page only while expanded.</summary>
    [ObservableProperty]
    public partial bool IsExpanded { get; set; }

    partial void OnIsExpandedChanged(bool value)
    {
        OnPropertyChanged(nameof(ExpandGlyph));
        OnPropertyChanged(nameof(ToggleLabel));
    }

    /// <summary>Loaded member rows, sorted by relative path (store order).</summary>
    public List<SourceItem> Members { get; } = new();

    /// <summary>Count, "load more" and empty-folder row shown after the members.</summary>
    public FolderFooterRow Footer { get; }

    public string ExpandGlyph => IsExpanded ? "\uE70D" : "\uE76C"; // ChevronDown / ChevronRight
    public string ToggleLabel => _text(IsExpanded ? StringKey.FolderHideFiles : StringKey.FolderShowFiles);

    public FolderSource Folder { get; }
    public CoverageSnapshot Coverage { get; }

    [ObservableProperty]
    public partial bool WatchEnabled { get; set; }

    /// <summary>Invoked for user toggles (not for programmatic rollbacks).</summary>
    public Func<FolderRowViewModel, bool, Task>? WatchChanged { get; set; }

    partial void OnWatchEnabledChanged(bool value)
    {
        if (!_silent) _ = WatchChanged?.Invoke(this, value);
    }

    internal void SetWatchSilently(bool value)
    {
        _silent = true;
        try { WatchEnabled = value; }
        finally { _silent = false; }
    }

    public string DisplayName => Folder.Draft.DisplayName;
    public string RootPath => Folder.Draft.RootPath;

    /// <summary>UI redesign §2.3: total files of the corpus (never mixed with the freshness counts).</summary>
    public int TotalFiles => Coverage.Searchable + Coverage.NotSearchable + Coverage.Skipped + Coverage.Missing + Coverage.Unavailable;
    /// <summary>Files that failed extraction or their last refresh.</summary>
    public int ErrorCount => Coverage.Error + Coverage.RefreshError;

    /// <summary>One compact status line for the panel row: "Files: 1 204 · Errors: 3" ("At least" when partial).</summary>
    public string SummaryText
    {
        get
        {
            string files = string.Format(CultureInfo.CurrentCulture, _text(StringKey.FolderSummaryFiles),
                TotalFiles.ToString("N0", CultureInfo.CurrentCulture));
            if (LowerBoundText is { } atLeast) files = atLeast + " " + files;
            return ErrorCount > 0
                ? files + " · " + string.Format(CultureInfo.CurrentCulture, _text(StringKey.FolderSummaryErrors), ErrorCount)
                : files;
        }
    }

    /// <summary>Tooltip with the detailed counts (root, last full scan, corpus and freshness lines).</summary>
    public string DetailText => string.Join(Environment.NewLine, new[]
    {
        RootPath,
        LastScanLabel + " " + LastScanValue,
        string.Join(" · ", CorpusCounts.Select(c => c.Label + " " + c.Value)),
        string.Join(" · ", FreshnessCounts.Select(c => c.Label + " " + c.Value)),
    });

    public string MoreLabel => _text(StringKey.ShellMore);
    public string WatchLabel => _text(StringKey.FolderWatchEnabled);
    public string ScanNowLabel => _text(StringKey.FolderScanNow);
    public string VerifyAllLabel => _text(StringKey.FolderVerifyAll);
    public string RulesLabel => _text(StringKey.FolderRulesTitle);
    public string RemoveLabel => _text(StringKey.FolderRemoveButton);
    public string LastScanLabel => _text(StringKey.FolderLastFullScan);

    public string LastScanValue => Folder.LastFullScanAt is long at
        ? DateTimeOffset.FromUnixTimeSeconds(at).ToLocalTime().ToString("g", CultureInfo.CurrentCulture)
        : _text(StringKey.FolderNeverScanned);

    /// <summary>"At least" when the inventory is a lower bound (incomplete scan), including an empty partial folder.</summary>
    public string? LowerBoundText => Coverage.IsLowerBound ? _text(StringKey.FolderAtLeast) : null;

    public IReadOnlyList<FolderCount> CorpusCounts =>
    [
        Count(StringKey.FolderSearchable, Coverage.Searchable),
        Count(StringKey.FolderNotSearchable, Coverage.NotSearchable),
        Count(StringKey.FolderSkipped, Coverage.Skipped),
        Count(StringKey.FolderMissing, Coverage.Missing),
        Count(StringKey.FolderUnavailable, Coverage.Unavailable),
    ];

    public IReadOnlyList<FolderCount> FreshnessCounts =>
    [
        Count(StringKey.FolderCurrent, Coverage.Current),
        Count(StringKey.FolderRefreshPending, Coverage.RefreshPending),
        Count(StringKey.FolderRefreshError, Coverage.RefreshError),
    ];

    /// <summary>
    /// Localized scan warning: the root is unavailable, the last scan failed (its persisted code explained), or the scan
    /// was partial (some subfolders could not be read; the counts are a lower bound).
    /// </summary>
    public string? ErrorText => Folder.ScanState switch
    {
        "unavailable" => _text(StringKey.FolderUnavailable),
        "error" => _text(SourcesViewModel.FolderErrorKey(Folder.LastScanError)),
        "partial" => _text(StringKey.FolderReadError),
        _ => null
    };

    /// <summary>"Checking…" with a spinner: optimistic after Scan now / Verify all, or while the folder scans.</summary>
    [ObservableProperty]
    public partial bool IsChecking { get; set; }

    /// <summary>Transient outcome of a requested scan ("No changes · N files up to date" / "N files changed").</summary>
    [ObservableProperty]
    public partial string? ScanCaption { get; set; }

    public string CheckingText => _text(StringKey.FolderChecking);

    private FolderCount Count(StringKey key, int value) => new(_text(key), value.ToString(CultureInfo.CurrentCulture));
}

/// <summary>The row after an expanded folder's members: "Files: shown / total", load more, or the empty-folder note.</summary>
public sealed partial class FolderFooterRow : ObservableObject
{
    private readonly Func<StringKey, string> _text;

    public FolderFooterRow(long folderId, Func<StringKey, string> text)
    {
        FolderId = folderId;
        _text = text;
    }

    public long FolderId { get; }

    [ObservableProperty]
    public partial int Shown { get; set; }

    [ObservableProperty]
    public partial int Total { get; set; }

    [ObservableProperty]
    public partial bool IsLoading { get; set; }

    partial void OnShownChanged(int value) => Refresh();
    partial void OnTotalChanged(int value) => Refresh();
    partial void OnIsLoadingChanged(bool value)
    {
        OnPropertyChanged(nameof(HasMore));
        OnPropertyChanged(nameof(IsEmptyFolder));
    }

    private void Refresh()
    {
        OnPropertyChanged(nameof(CountText));
        OnPropertyChanged(nameof(HasMore));
        OnPropertyChanged(nameof(IsEmptyFolder));
    }

    public bool HasMore => !IsLoading && Shown < Total;
    public bool IsEmptyFolder => !IsLoading && Total == 0;
    public string CountText => CountTextFor(Shown, Total, _text);
    public string LoadMoreLabel => _text(StringKey.FolderLoadMoreFiles);
    public string NoFilesText => _text(StringKey.FolderNoFiles);

    /// <summary>Same tokens and plain integers as macOS AppText.folderFilesCount.</summary>
    public static string CountTextFor(int shown, int total, Func<StringKey, string> text) =>
        text(StringKey.FolderFilesCount)
            .Replace("{shown}", shown.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("{total}", total.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal);
}
