using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Ingestion;
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
    private readonly LocalizedStrings _strings;
    private readonly IChatStreaming _chatStreaming;
    private readonly ISettingsService _settings;
    private readonly DispatcherQueue _dispatcher;
    private readonly IngestionService _ingestion;
    private readonly FolderWatchService _folderWatch;

    public long NotebookId { get; set; }

    public ObservableCollection<SourceItem> Sources { get; } = new();

    [ObservableProperty]
    public partial bool IsEmpty { get; set; } = true;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    [ObservableProperty]
    public partial bool IsBulkMode { get; set; }

    [ObservableProperty]
    public partial bool IsFolderWatchActive { get; set; }

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
    partial void OnErrorMessageChanged(string? value) => OnPropertyChanged(nameof(HasError));

    // B8: global tag list for the manage-tags dialog.
    public ObservableCollection<Tag> AllTags { get; } = new();

    public IReadOnlyList<long> SelectedSourceIds =>
        Sources.Where(s => s.IsSelected).Select(s => s.Id).ToList();

    public SourcesViewModel(NotebookStore store, LocalizedStrings strings,
                            IChatStreaming chatStreaming, ISettingsService settings,
                            IngestionService ingestion, FolderWatchService folderWatch)
    {
        _store = store;
        _strings = strings;
        _chatStreaming = chatStreaming;
        _settings = settings;
        _ingestion = ingestion;
        _folderWatch = folderWatch;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    public async Task LoadAsync()
    {
        try
        {
            // Store access is synchronous + single-connection; run off the UI thread.
            // Pair each source with its persisted summary (Tier 2b).
            var rows = await Task.Run(() =>
                _store.Sources(NotebookId)
                      .Select(s => (Source: s, Summary: _store.SourceSummary(s.Id!.Value),
                                   Tags: _store.TagsForSource(s.Id!.Value).ToList()))
                      .ToList());
            var allTagRows = await Task.Run(() => _store.Tags().ToList());
            void Apply()
            {
                Sources.Clear();
                foreach (var (s, summary, tags) in rows)
                {
                    var item = new SourceItem(s, _strings) { Summary = summary };
                    foreach (var t in tags) item.Tags.Add(t);
                    Sources.Add(item);
                }
                IsEmpty = Sources.Count == 0;
                AllTags.Clear();
                foreach (var t in allTagRows) AllTags.Add(t);
                ErrorMessage = null;
            }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Apply); else Apply();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
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
            ErrorMessage = ex.ToString();
        }
    }

    [RelayCommand]
    private void ToggleBulkMode()
    {
        IsBulkMode = !IsBulkMode;
        if (!IsBulkMode)
            foreach (var s in Sources) s.IsSelected = false;
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
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
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
            var hash = await ComputeHashAsync(item.Source.Uri!);
            _store.UpdateSourceSyncInfo(item.Id, DateTime.UtcNow, hash);
            await LoadAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        finally { item.IsRefreshing = false; }
    }

    // E1: toggle folder watch.
    [RelayCommand]
    public async Task ToggleFolderWatchAsync()
    {
        if (_folderWatch.IsActive)
        {
            _folderWatch.Disable();
            IsFolderWatchActive = false;
        }
        else
        {
            // Pick a folder via Windows file picker in the View; this is a no-op if no folder was chosen.
            FolderWatchRequested?.Invoke();
        }
        await Task.CompletedTask;
    }

    public Action? FolderWatchRequested { get; set; }

    public void EnableFolderWatch(string folder)
    {
        _folderWatch.Enable(NotebookId, folder);
        IsFolderWatchActive = true;
    }

    private static async Task<string> ComputeHashAsync(string uriOrPath)
    {
        if (uriOrPath.StartsWith("http", StringComparison.OrdinalIgnoreCase))
            return uriOrPath; // URL: use URI as identity (no local file to hash)
        using var fs = new System.IO.FileStream(uriOrPath, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite);
        var hash = await System.Security.Cryptography.MD5.HashDataAsync(fs);
        return Convert.ToHexString(hash);
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
            void Apply() { item.Summary = text; }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Apply); else Apply();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
        finally
        {
            void Done() { item.IsSummarizing = false; }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Done); else Done();
        }
    }
}
