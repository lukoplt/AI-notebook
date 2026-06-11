using System.Collections.ObjectModel;
using AINotebook.App.Services;
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

    public long NotebookId { get; set; }

    public ObservableCollection<SourceItem> Sources { get; } = new();

    [ObservableProperty]
    public partial bool IsEmpty { get; set; } = true;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
    partial void OnErrorMessageChanged(string? value) => OnPropertyChanged(nameof(HasError));

    public SourcesViewModel(NotebookStore store, LocalizedStrings strings,
                            IChatStreaming chatStreaming, ISettingsService settings)
    {
        _store = store;
        _strings = strings;
        _chatStreaming = chatStreaming;
        _settings = settings;
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
                      .Select(s => (Source: s, Summary: _store.SourceSummary(s.Id!.Value)))
                      .ToList());
            void Apply()
            {
                Sources.Clear();
                foreach (var (s, summary) in rows)
                    Sources.Add(new SourceItem(s, _strings) { Summary = summary });
                IsEmpty = Sources.Count == 0;
                ErrorMessage = null;
            }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Apply); else Apply();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
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
