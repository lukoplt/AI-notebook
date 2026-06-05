using System.Collections.ObjectModel;
using AINotebook.Core.Ollama;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class ModelManagementViewModel : ObservableObject
{
    private readonly OllamaClient _ollama;

    public ObservableCollection<OllamaModelItem> Models { get; } = new();

    [ObservableProperty]
    public partial string PullName { get; set; } = "";

    [ObservableProperty]
    public partial bool Working { get; set; }

    [ObservableProperty]
    public partial string PullProgress { get; set; } = "";

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    public ModelManagementViewModel(OllamaClient ollama) => _ollama = ollama;

    public async Task ReloadAsync()
    {
        try
        {
            var models = await _ollama.ListModelsAsync();
            Models.Clear();
            foreach (var m in models) Models.Add(new OllamaModelItem(m));
            ErrorMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
    }

    [RelayCommand]
    public async Task DeleteAsync(string name)
    {
        Working = true;
        try
        {
            await _ollama.DeleteModelAsync(name);
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
        finally { Working = false; }
    }

    [RelayCommand]
    public async Task PullAsync()
    {
        var name = PullName.Trim();
        if (name.Length == 0) return;
        Working = true;
        PullProgress = "Starting…";
        try
        {
            await foreach (var ev in _ollama.PullModelAsync(name))
                PullProgress = ev.Status;
            PullName = "";
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
        finally
        {
            Working = false;
            PullProgress = "";
        }
    }
}
