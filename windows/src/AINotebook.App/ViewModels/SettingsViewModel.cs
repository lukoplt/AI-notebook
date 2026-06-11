using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly NotebookStore _store;
    private readonly ProviderRouter _router;
    private readonly EmbeddingWorker _worker;

    // Models for the currently-selected providers
    public ObservableCollection<string> AvailableChatModels { get; } = new();
    public ObservableCollection<string> AvailableEmbeddingModels { get; } = new();

    // Configured providers
    public ObservableCollection<ProviderConfig> Providers { get; } = new();

    [ObservableProperty]
    public partial bool ChatModelsAvailable { get; set; }

    [ObservableProperty]
    public partial bool EmbeddingModelsAvailable { get; set; }

    [ObservableProperty]
    public partial string? SettingsError { get; set; }

    public string Version => AINotebookVersion.Current;

    public AppLanguage[] Languages { get; } = [AppLanguage.English, AppLanguage.Czech];

    public SettingsViewModel(
        ISettingsService settings, NotebookStore store, ProviderRouter router, EmbeddingWorker worker)
    {
        _settings = settings;
        _store = store;
        _router = router;
        _worker = worker;
    }

    // ── Language ────────────────────────────────────────────────────────────

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

    // ── Provider selection ───────────────────────────────────────────────────

    public string SelectedChatProviderId
    {
        get => _settings.SelectedChatProviderId;
        set
        {
            if (_settings.SelectedChatProviderId != value)
            {
                _settings.SelectedChatProviderId = value;
                OnPropertyChanged();
            }
        }
    }

    public string SelectedEmbeddingProviderId
    {
        get => _settings.SelectedEmbeddingProviderId;
        set
        {
            if (_settings.SelectedEmbeddingProviderId != value)
            {
                _settings.SelectedEmbeddingProviderId = value;
                OnPropertyChanged();
            }
        }
    }

    // ── Model selection ─────────────────────────────────────────────────────

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
            }
        }
    }

    // ── Data loading ─────────────────────────────────────────────────────────

    public async Task RefreshAllAsync()
    {
        await RefreshProvidersAsync();
        await Task.WhenAll(
            RefreshChatModelsAsync(),
            RefreshEmbeddingModelsAsync());
    }

    public async Task RefreshProvidersAsync()
    {
        try
        {
            var list = await Task.Run(() => _store.Providers());
            Providers.Clear();
            foreach (var p in list) Providers.Add(p);
        }
        catch (Exception ex) { SettingsError = ex.ToString(); }
    }

    public async Task RefreshChatModelsAsync()
    {
        try
        {
            var models = await _router.ListModelsAsync(_settings.SelectedChatProviderId);
            var names = models.Select(m => m.DisplayName ?? m.Id)
                              .OrderBy(n => n, StringComparer.Ordinal).ToList();
            AvailableChatModels.Clear();
            foreach (var n in names) AvailableChatModels.Add(n);
            if (!AvailableChatModels.Contains(SelectedChatModel)) AvailableChatModels.Add(SelectedChatModel);
            ChatModelsAvailable = AvailableChatModels.Count > 0;
        }
        catch
        {
            AvailableChatModels.Clear();
            ChatModelsAvailable = false;
        }
    }

    public async Task RefreshEmbeddingModelsAsync()
    {
        try
        {
            var providerId = _settings.SelectedEmbeddingProviderId;
            var cfg = _store.Provider(providerId);
            // Only providers that support embeddings expose an embedding model picker.
            if (cfg is not null && !cfg.Type.SupportsEmbeddings())
            {
                AvailableEmbeddingModels.Clear();
                EmbeddingModelsAvailable = false;
                return;
            }
            var models = await _router.ListModelsAsync(providerId);
            var names = models.Select(m => m.DisplayName ?? m.Id)
                              .OrderBy(n => n, StringComparer.Ordinal).ToList();
            AvailableEmbeddingModels.Clear();
            foreach (var n in names) AvailableEmbeddingModels.Add(n);
            if (!AvailableEmbeddingModels.Contains(SelectedEmbeddingModel))
                AvailableEmbeddingModels.Add(SelectedEmbeddingModel);
            EmbeddingModelsAvailable = AvailableEmbeddingModels.Count > 0;
        }
        catch
        {
            AvailableEmbeddingModels.Clear();
            EmbeddingModelsAvailable = false;
        }
    }

    // Legacy compatibility — keep the old name for callers that only care about Ollama refresh.
    public Task RefreshModelsAsync() => RefreshAllAsync();

    [RelayCommand]
    public async Task ReembedAllAsync()
    {
        try
        {
            var key = _router.CurrentEmbeddingKey;
            await Task.Run(() => _store.DeleteAllEmbeddings(key));
            _worker.Kick();
            SettingsError = null;
        }
        catch (Exception ex)
        {
            SettingsError = ex.ToString();
        }
    }
}
