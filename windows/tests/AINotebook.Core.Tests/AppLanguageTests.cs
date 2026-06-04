using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests;

public class AppLanguageTests
{
    [Fact] // testAllCases
    public void AllCases() =>
        Assert.Equal(new[] { AppLanguage.English, AppLanguage.Czech }, Enum.GetValues<AppLanguage>());

    [Fact] // testRawValues
    public void RawValues()
    {
        Assert.Equal("en", AppLanguageExtensions.RawValue(AppLanguage.English));
        Assert.Equal("cs", AppLanguageExtensions.RawValue(AppLanguage.Czech));
    }

    [Fact] // testDisplayNames
    public void DisplayNames()
    {
        Assert.Equal("English", AppLanguageExtensions.DisplayName(AppLanguage.English));
        Assert.Equal("Čeština", AppLanguageExtensions.DisplayName(AppLanguage.Czech));
    }
}
