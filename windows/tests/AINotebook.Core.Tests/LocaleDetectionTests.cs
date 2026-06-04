using AINotebook.Core;
using AINotebook.Core.Models;
using Xunit;

namespace AINotebook.Core.Tests;

public class LocaleDetectionTests
{
    [Fact] // testCzechPreferredReturnsCzech
    public void CzechPreferredReturnsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "cs-CZ", "en-US" }));

    [Fact] // testCzechWithoutRegionReturnsCzech
    public void CzechWithoutRegionReturnsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "cs" }));

    [Fact] // testEnglishPreferredReturnsEnglish
    public void EnglishPreferredReturnsEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(new[] { "en-US" }));

    [Fact] // testUnknownLanguageDefaultsToEnglish
    public void UnknownLanguageDefaultsToEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(new[] { "ja-JP", "ko-KR" }));

    [Fact] // testEmptyDefaultsToEnglish
    public void EmptyDefaultsToEnglish() =>
        Assert.Equal(AppLanguage.English, LocaleDetection.DetectInitialLanguage(Array.Empty<string>()));

    [Fact] // testCzechSecondInListStillCountsAsCzech (Czech anywhere wins)
    public void CzechSecondInListStillCountsAsCzech() =>
        Assert.Equal(AppLanguage.Czech, LocaleDetection.DetectInitialLanguage(new[] { "en-US", "cs-CZ" }));
}
