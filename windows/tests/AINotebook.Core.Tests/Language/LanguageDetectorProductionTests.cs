using AINotebook.Core.Language;
using Xunit;

namespace AINotebook.Core.Tests.Language;

/// <summary>
/// The trained production artifact is embedded from Sources/AINotebookCore/Resources/Language.
/// Mirrors Swift LanguageDetectorTests.testBundleAvailabilityTracksProductionResources: when the
/// artifact is present it must load and verify (a validator/trainer mismatch made it silently
/// unavailable once).
/// </summary>
public class LanguageDetectorProductionTests
{
    [Fact]
    public void BundledProductionArtifactLoadsAndDetectsDocuments()
    {
        var detector = LanguageDetector.LoadBundled();
        Assert.True(detector.IsAvailable);
        var czech = detector.DetectDocument(string.Join(" ", Enumerable.Repeat(
            "Dodavatel zajistí přejímku snímačů a předá kalibrační listy odběrateli do konce měsíce.", 12)));
        Assert.NotNull(czech);
        Assert.Equal("cs", czech!.Label);
    }
}
