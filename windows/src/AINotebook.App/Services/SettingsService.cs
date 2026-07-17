using System.Runtime.CompilerServices;
using System.Text.Json;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// File-backed settings store (%APPDATA%\AINotebook\settings.json).
/// Windows.Storage.ApplicationData requires MSIX package identity, which this
/// app does not have (WindowsPackageType=None) — calling it throws before the
/// first window exists, so settings must live in a plain file instead.
/// </summary>
public sealed partial class SettingsService : ObservableObject, ISettingsService
{
    private sealed class SettingsFile
    {
        public string? Language { get; set; }
        public bool? HasCompletedOnboarding { get; set; }
        public string? SelectedChatModel { get; set; }
        public string? SelectedEmbeddingModel { get; set; }
        public string? SelectedChatProviderId { get; set; }
        public string? SelectedEmbeddingProviderId { get; set; }
        public bool? AutoCheckUpdates { get; set; }
        public string? LastUpdateCheckUtc { get; set; }
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private readonly string _path;
    private readonly SettingsFile _file;

    public SettingsService() : this(DefaultPath()) { }

    internal SettingsService(string path)
    {
        _path = path;
        _file = Load(path);

        // First-run language is English; the OS locale is not consulted.
        // Users who want Czech choose it in Settings, and it persists here.
        _language = AppLanguageExtensions.FromRawValue(_file.Language ?? "")
            ?? AppLanguage.English;

        _hasCompletedOnboarding = _file.HasCompletedOnboarding ?? false;
        _selectedChatModel = _file.SelectedChatModel ?? "llama3.2:3b";
        _selectedEmbeddingModel = _file.SelectedEmbeddingModel ?? "nomic-embed-text";
        _selectedChatProviderId = _file.SelectedChatProviderId ?? ProviderConfig.OllamaId;
        _selectedEmbeddingProviderId = _file.SelectedEmbeddingProviderId ?? ProviderConfig.OllamaId;
        _autoCheckUpdates = _file.AutoCheckUpdates ?? true;
        _lastUpdateCheckUtc = DateTimeOffset.TryParse(_file.LastUpdateCheckUtc, null, System.Globalization.DateTimeStyles.RoundtripKind, out var t) ? t : null;
    }

    private static string DefaultPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var container = Path.Combine(appData, "AINotebook");
        Directory.CreateDirectory(container);
        return Path.Combine(container, "settings.json");
    }

    private static SettingsFile Load(string path)
    {
        try
        {
            if (File.Exists(path))
                return JsonSerializer.Deserialize<SettingsFile>(File.ReadAllText(path)) ?? new SettingsFile();
        }
        catch (Exception ex)
        {
            // A corrupt settings file must not prevent startup; fall back to defaults.
            System.Diagnostics.Debug.WriteLine($"SettingsService: failed to read {path}: {ex.Message}");
        }
        return new SettingsFile();
    }

    private void Save()
    {
        try
        {
            File.WriteAllText(_path, JsonSerializer.Serialize(_file, JsonOptions));
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"SettingsService: failed to write {_path}: {ex.Message}");
        }
    }

    private AppLanguage _language;
    public AppLanguage Language
    {
        get => _language;
        set { if (SetField(ref _language, value)) { _file.Language = value.RawValue(); Save(); } }
    }

    private bool _hasCompletedOnboarding;
    public bool HasCompletedOnboarding
    {
        get => _hasCompletedOnboarding;
        set { if (SetField(ref _hasCompletedOnboarding, value)) { _file.HasCompletedOnboarding = value; Save(); } }
    }

    private string _selectedChatModel;
    public string SelectedChatModel
    {
        get => _selectedChatModel;
        set { if (SetField(ref _selectedChatModel, value)) { _file.SelectedChatModel = value; Save(); } }
    }

    private string _selectedEmbeddingModel;
    public string SelectedEmbeddingModel
    {
        get => _selectedEmbeddingModel;
        set { if (SetField(ref _selectedEmbeddingModel, value)) { _file.SelectedEmbeddingModel = value; Save(); } }
    }

    private string _selectedChatProviderId;
    public string SelectedChatProviderId
    {
        get => _selectedChatProviderId;
        set { if (SetField(ref _selectedChatProviderId, value)) { _file.SelectedChatProviderId = value; Save(); } }
    }

    private string _selectedEmbeddingProviderId;
    public string SelectedEmbeddingProviderId
    {
        get => _selectedEmbeddingProviderId;
        set { if (SetField(ref _selectedEmbeddingProviderId, value)) { _file.SelectedEmbeddingProviderId = value; Save(); } }
    }

    private bool _autoCheckUpdates;
    public bool AutoCheckUpdates
    {
        get => _autoCheckUpdates;
        set { if (SetField(ref _autoCheckUpdates, value)) { _file.AutoCheckUpdates = value; Save(); } }
    }

    private DateTimeOffset? _lastUpdateCheckUtc;
    public DateTimeOffset? LastUpdateCheckUtc
    {
        get => _lastUpdateCheckUtc;
        set { if (SetField(ref _lastUpdateCheckUtc, value)) { _file.LastUpdateCheckUtc = value?.ToString("o"); Save(); } }
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}
