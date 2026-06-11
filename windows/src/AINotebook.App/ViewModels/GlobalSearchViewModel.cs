using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class GlobalSearchViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _t;

    [ObservableProperty] public partial string Query { get; set; } = "";
    [ObservableProperty] public partial bool IsSearching { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public ObservableCollection<NoteSearchHit> Notes { get; } = new();
    public ObservableCollection<SourceSearchHit> Sources { get; } = new();

    public bool HasResults => Notes.Count > 0 || Sources.Count > 0;
    public bool IsEmpty => !IsSearching && !HasResults && !string.IsNullOrWhiteSpace(Query);

    // Raised when user clicks a note result — navigate to that note.
    public event Action<long>? NoteSelected;

    public GlobalSearchViewModel(NotebookStore store, ILocalizedStrings t)
    {
        _store = store;
        _t = t;
    }

    partial void OnQueryChanged(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            Notes.Clear();
            Sources.Clear();
            OnPropertyChanged(nameof(HasResults));
            OnPropertyChanged(nameof(IsEmpty));
        }
    }

    [RelayCommand]
    private async Task SearchAsync()
    {
        var q = Query.Trim();
        if (string.IsNullOrEmpty(q)) return;
        IsSearching = true;
        ErrorMessage = null;
        try
        {
            var result = await Task.Run(() => _store.GlobalSearch(q));
            Notes.Clear();
            foreach (var n in result.Notes) Notes.Add(n);
            Sources.Clear();
            foreach (var s in result.Sources) Sources.Add(s);
            OnPropertyChanged(nameof(HasResults));
            OnPropertyChanged(nameof(IsEmpty));
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        finally { IsSearching = false; }
    }

    [RelayCommand]
    private void OpenNote(NoteSearchHit? hit)
    {
        if (hit is null) return;
        NoteSelected?.Invoke(hit.NoteId);
    }
}
