using System.ComponentModel;
using AINotebook.Core;

namespace AINotebook.App.Services;

public interface ILocalizedStrings : INotifyPropertyChanged
{
    /// Lookup by the mac AppText.Key case name (e.g. "noNotebookSelected").
    string this[string key] { get; }
    string Get(string key);
    /// Compile-time-checked lookup by the StringKey enum (PascalCase mirror of the
    /// mac AppText.Key cases). Used by the onboarding/sources/settings tasks (M3.5/
    /// M3.6/M4/M9). Maps StringKey -> the camelCase .resw key, then calls Get(string).
    string Get(StringKey key);
    void SetLanguage(AppLanguage language);
}
