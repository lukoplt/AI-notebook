using System.Runtime.CompilerServices;
using AINotebook.Core;
using AINotebook.Core.Models;
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

    public SettingsService()
    {
        // Initial language: stored value, else Core locale detection over preferred langs.
        var stored = _store.Values[KeyLanguage] as string;
        _language = AppLanguageExtensions.FromRawValue(stored ?? "")
            ?? LocaleDetection.DetectInitialLanguage(ApplicationLanguages.Languages);

        _hasCompletedOnboarding = _store.Values[KeyOnboarding] as bool? ?? false;
        _selectedChatModel = _store.Values[KeyChatModel] as string ?? "llama3.2:3b";
        _selectedEmbeddingModel = _store.Values[KeyEmbeddingModel] as string ?? "nomic-embed-text";
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

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}
