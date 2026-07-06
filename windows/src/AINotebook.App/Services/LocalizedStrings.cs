using System.ComponentModel;
using AINotebook.Core;
using AINotebook.Core.Models;
using Microsoft.Windows.ApplicationModel.Resources;

namespace AINotebook.App.Services;

public sealed class LocalizedStrings : ILocalizedStrings
{
    // Unpackaged builds ship the app PRI as AINotebook.App.pri; the
    // parameterless ResourceManager ctor only probes resources.pri.
    private static ResourceManager CreateResourceManager()
    {
        var appPri = Path.Combine(AppContext.BaseDirectory, "AINotebook.App.pri");
        return File.Exists(appPri) ? new ResourceManager(appPri) : new ResourceManager();
    }

    private readonly ResourceManager _rm = CreateResourceManager();
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
        // Do NOT set ApplicationLanguages.PrimaryLanguageOverride here: it
        // requires MSIX package identity and throws in this unpackaged app.
        // The Language qualifier on the resource context does the switching.
        var bcp47 = language == AppLanguage.Czech ? "cs-CZ" : "en-US";
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
