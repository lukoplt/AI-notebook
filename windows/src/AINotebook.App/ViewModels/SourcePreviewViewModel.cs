using System.Collections.ObjectModel;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public sealed partial class SourcePreviewViewModel : ObservableObject
{
    private readonly NotebookStore _store;

    [ObservableProperty] public partial Source? Source { get; set; }
    [ObservableProperty] public partial bool IsLoading { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public ObservableCollection<SourceChunk> Chunks { get; } = new();
    public string Title => Source?.Title ?? "";
    public int ChunkCount => Chunks.Count;

    public SourcePreviewViewModel(NotebookStore store) => _store = store;

    public async Task LoadAsync(Source source)
    {
        Source = source;
        IsLoading = true;
        Chunks.Clear();
        try
        {
            var chunks = await Task.Run(() => _store.Chunks(source.Id!.Value));
            foreach (var c in chunks) Chunks.Add(c);
            OnPropertyChanged(nameof(ChunkCount));
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        finally { IsLoading = false; }
    }
}
