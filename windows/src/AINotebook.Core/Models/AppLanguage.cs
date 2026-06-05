namespace AINotebook.Core.Models;

public enum AppLanguage { English, Czech }

public static class AppLanguageExtensions
{
    public static string RawValue(this AppLanguage language) => language switch
    {
        AppLanguage.English => "en",
        AppLanguage.Czech => "cs",
        _ => "en",
    };

    public static string DisplayName(this AppLanguage language) => language switch
    {
        AppLanguage.English => "English",
        AppLanguage.Czech => "Čeština",
        _ => "English",
    };

    // Returns null on unknown raw value (does NOT throw); Task 26's AppLanguageTests
    // and LocaleDetection bind to this nullable form.
    public static AppLanguage? FromRawValue(string raw) => raw switch
    {
        "en" => AppLanguage.English,
        "cs" => AppLanguage.Czech,
        _ => null,
    };
}
