using System.ComponentModel;
using AINotebook.Core;
using AINotebook.Core.Models;
using Microsoft.Windows.ApplicationModel.Resources;
using Windows.Globalization;

namespace AINotebook.App.Services;

public sealed class LocalizedStrings : ILocalizedStrings
{
    private readonly ResourceManager _rm = new();
    private ResourceContext _ctx;
    private ResourceMap _map;

    public event PropertyChangedEventHandler? PropertyChanged;

    public LocalizedStrings(ISettingsService settings)
    {
        _ctx = _rm.CreateResourceContext();
        _map = _rm.MainResourceMap.GetSubtree("Resources");
        SetLanguage(settings.Language);

        // Live-switch when the user changes language in Settings.
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ISettingsService.Language))
                SetLanguage(settings.Language);
        };
    }

    public void SetLanguage(AppLanguage language)
    {
        var bcp47 = language == AppLanguage.Czech ? "cs-CZ" : "en-US";
        ApplicationLanguages.PrimaryLanguageOverride = bcp47;
        _ctx = _rm.CreateResourceContext();
        _ctx.QualifierValues["Language"] = bcp47;
        // Notify all bindings on the indexer to re-pull every visible string.
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }

    public string this[string key] => Get(key);

    public string Get(string key)
    {
        try { return _map.GetValue(key, _ctx).ValueAsString; }
        catch { return key; } // fall back to the key name if missing (dev-visible)
    }

    // Convenience: StringKey (PascalCase) -> camelCase .resw key -> Get(string).
    public string Get(StringKey key)
    {
        var name = key.ToString();
        var camel = char.ToLowerInvariant(name[0]) + name[1..];
        return Get(camel);
    }
}
