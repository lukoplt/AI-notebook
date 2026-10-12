using System.ComponentModel;
using System.Xml.Linq;
using AINotebook.Core;
using AINotebook.Core.Models;

namespace AINotebook.App.Services;

/// tools/windows-typecheck only: LocalizedStrings backed by the .resw XML (the real one uses the WinAppSDK ResourceManager).
public sealed class LocalizedStrings : ILocalizedStrings
{
    private Dictionary<string, string> _map = Load("en.resw");
    public event PropertyChangedEventHandler? PropertyChanged;
    public LocalizedStrings() { }
    public LocalizedStrings(ISettingsService settings) => SetLanguage(settings.Language);
    private static Dictionary<string, string> Load(string path) => XDocument.Load(path).Root!.Elements("data")
        .ToDictionary(e => (string)e.Attribute("name")!, e => (string)e.Element("value")!);
    public void SetLanguage(AppLanguage language)
    {
        _map = Load(language == AppLanguage.Czech ? "cs.resw" : "en.resw");
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }
    public string this[string key] => Get(key);
    public string Get(string key) => _map.TryGetValue(key, out var v) ? v : key;
    public string Get(StringKey key) { var n = key.ToString(); return Get(char.ToLowerInvariant(n[0]) + n[1..]); }
}
