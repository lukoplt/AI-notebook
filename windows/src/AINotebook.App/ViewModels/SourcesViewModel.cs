using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public sealed partial class SourcesViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly LocalizedStrings _strings;
    private readonly DispatcherQueue _dispatcher;

    public long NotebookId { get; set; }

    public ObservableCollection<SourceItem> Sources { get; } = new();

    [ObservableProperty]
    public partial bool IsEmpty { get; set; } = true;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    public SourcesViewModel(NotebookStore store, LocalizedStrings strings)
    {
        _store = store;
        _strings = strings;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    public async Task LoadAsync()
    {
        try
        {
            // Store access is synchronous + single-connection; run off the UI thread.
            var rows = await Task.Run(() => _store.Sources(NotebookId));
            void Apply()
            {
                Sources.Clear();
                foreach (var s in rows) Sources.Add(new SourceItem(s, _strings));
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
}
