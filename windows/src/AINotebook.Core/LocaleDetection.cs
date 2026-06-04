using AINotebook.Core.Models;

namespace AINotebook.Core;

public static class LocaleDetection
{
    /// Czech if any preferred entry starts with "cs" (case-insensitive),
    /// otherwise English.
    public static AppLanguage DetectInitialLanguage(IEnumerable<string> preferred)
    {
        foreach (var entry in preferred)
        {
            if (entry.StartsWith("cs", StringComparison.OrdinalIgnoreCase))
                return AppLanguage.Czech;
        }
        return AppLanguage.English;
    }
}
