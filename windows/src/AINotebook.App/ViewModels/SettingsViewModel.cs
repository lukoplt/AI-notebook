using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly NotebookStore _store;
    private readonly OllamaClient _ollama;
    private readonly EmbeddingWorker _worker;

    public ObservableCollection<string> AvailableModels { get; } = new();

    [ObservableProperty]
    public partial bool ModelsAvailable { get; set; }

    [ObservableProperty]
    public partial string? SettingsError { get; set; }

    public string Version => AINotebookVersion.Current;

    public AppLanguage[] Languages { get; } = { AppLanguage.English, AppLanguage.Czech };

    public SettingsViewModel(
        ISettingsService settings, NotebookStore store, OllamaClient ollama, EmbeddingWorker worker)
    {
        _settings = settings;
        _store = store;
        _ollama = ollama;
        _worker = worker;
    }

    // --- Two-way passthroughs to the persisted settings service ---

    public AppLanguage Language
    {
        get => _settings.Language;
        set
        {
            if (_settings.Language == value) return;
            _settings.Language = value;
            Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride =
                value.RawValue() == "cs" ? "cs-CZ" : "en-US";
            OnPropertyChanged();
        }
    }

    public string SelectedChatModel
    {
        get => _settings.SelectedChatModel;
        set { if (_settings.SelectedChatModel != value) { _settings.SelectedChatModel = value; OnPropertyChanged(); } }
    }

    public string SelectedEmbeddingModel
    {
        get => _settings.SelectedEmbeddingModel;
        set
        {
            if (_settings.SelectedEmbeddingModel != value)
            {
                _settings.SelectedEmbeddingModel = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(SelectedEmbeddingModel));
            }
        }
    }

    public async Task RefreshModelsAsync()
    {
        try
        {
            var models = await _ollama.ListModelsAsync();
            var names = models.Select(m => m.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();
            AvailableModels.Clear();
            foreach (var n in names) AvailableModels.Add(n);
            ModelsAvailable = AvailableModels.Count > 0;
        }
        catch
        {
            AvailableModels.Clear();
            ModelsAvailable = false;
        }
    }

    [RelayCommand]
    public async Task ReembedAllAsync()
    {
        try
        {
            await Task.Run(() => _store.DeleteAllEmbeddings(_settings.SelectedEmbeddingModel));
            _worker.Kick();
            SettingsError = null;
        }
        catch (Exception ex)
        {
            SettingsError = ex.ToString();
        }
    }
}
