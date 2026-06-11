using System.Runtime.CompilerServices;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Globalization;
using Windows.Storage;

namespace AINotebook.App.Services;

public sealed partial class SettingsService : ObservableObject, ISettingsService
{
    private readonly ApplicationDataContainer _store = ApplicationData.Current.LocalSettings;

    private const string KeyLanguage = "language";
    private const string KeyOnboarding = "hasCompletedOnboarding";
    private const string KeyChatModel = "selectedChatModel";
    private const string KeyEmbeddingModel = "selectedEmbeddingModel";
    private const string KeyChatProviderId = "selectedChatProviderId";
    private const string KeyEmbeddingProviderId = "selectedEmbeddingProviderId";

    public SettingsService()
    {
        var stored = _store.Values[KeyLanguage] as string;
        _language = AppLanguageExtensions.FromRawValue(stored ?? "")
            ?? LocaleDetection.DetectInitialLanguage(ApplicationLanguages.Languages);

        _hasCompletedOnboarding = _store.Values[KeyOnboarding] as bool? ?? false;
        _selectedChatModel = _store.Values[KeyChatModel] as string ?? "llama3.2:3b";
        _selectedEmbeddingModel = _store.Values[KeyEmbeddingModel] as string ?? "nomic-embed-text";
        _selectedChatProviderId = _store.Values[KeyChatProviderId] as string ?? ProviderConfig.OllamaId;
        _selectedEmbeddingProviderId = _store.Values[KeyEmbeddingProviderId] as string ?? ProviderConfig.OllamaId;
    }

    private AppLanguage _language;
    public AppLanguage Language
    {
        get => _language;
        set { if (SetField(ref _language, value)) _store.Values[KeyLanguage] = value.RawValue(); }
    }

    private bool _hasCompletedOnboarding;
    public bool HasCompletedOnboarding
    {
        get => _hasCompletedOnboarding;
        set { if (SetField(ref _hasCompletedOnboarding, value)) _store.Values[KeyOnboarding] = value; }
    }

    private string _selectedChatModel;
    public string SelectedChatModel
    {
        get => _selectedChatModel;
        set { if (SetField(ref _selectedChatModel, value)) _store.Values[KeyChatModel] = value; }
    }

    private string _selectedEmbeddingModel;
    public string SelectedEmbeddingModel
    {
        get => _selectedEmbeddingModel;
        set { if (SetField(ref _selectedEmbeddingModel, value)) _store.Values[KeyEmbeddingModel] = value; }
    }

    private string _selectedChatProviderId;
    public string SelectedChatProviderId
    {
        get => _selectedChatProviderId;
        set { if (SetField(ref _selectedChatProviderId, value)) _store.Values[KeyChatProviderId] = value; }
    }

    private string _selectedEmbeddingProviderId;
    public string SelectedEmbeddingProviderId
    {
        get => _selectedEmbeddingProviderId;
        set { if (SetField(ref _selectedEmbeddingProviderId, value)) _store.Values[KeyEmbeddingProviderId] = value; }
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}
