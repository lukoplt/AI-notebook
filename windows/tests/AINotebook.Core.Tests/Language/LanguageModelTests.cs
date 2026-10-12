using System.Text;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class LanguageModelTests
{
    [Fact]
    public void EveryArtifactValidationCase()
    {
        var tables = UnicodeTables.LoadBundled();
        var cases = SharedFixtures.Json("contracts/lang-artifact-validation-v1.json").GetProperty("cases");
        Assert.Equal(104, cases.GetArrayLength());
        Assert.Equal(40, cases.EnumerateArray().Count(c => !c.TryGetProperty("rawManifestProperties", out _)));
        Assert.Equal(64, cases.EnumerateArray().Count(c => c.TryGetProperty("rawManifestProperties", out _)));
        var bundle = SharedFixtures.Json("lang/loading-bundle-v1.json");
        Assert.Equal("lang-loading-bundle", bundle.GetProperty("contract").GetString());
        Assert.Equal(1, bundle.GetProperty("testOnly").GetInt32());
        var resources = bundle.GetProperty("resources").EnumerateObject().ToDictionary(
            property => property.Name, property => Convert.FromBase64String(property.Value.GetString()!), StringComparer.Ordinal);
        foreach (var name in bundle.GetProperty("sharedUnicodeResources").EnumerateArray())
            resources.Add(name.GetString()!, LanguageDetector.ReadBundledResource(name.GetString()!));
        const string manifestName = "lang-detector-v1.manifest.json";
        string manifest = Encoding.UTF8.GetString(resources[manifestName]);
        Assert.StartsWith("{", manifest);
        foreach (var c in cases.EnumerateArray())
        {
            if (c.TryGetProperty("rawManifestProperties", out var properties))
            {
                Assert.False(c.TryGetProperty("rawArtifact", out _) || c.TryGetProperty("rawBytesBase64", out _));
                resources[manifestName] = Encoding.UTF8.GetBytes("{" + properties.GetString()! + manifest[1..]);
                var detector = LanguageDetector.Load(name => resources[name]);
                Assert.True(c.GetProperty("valid").GetBoolean() == detector.IsAvailable, c.GetProperty("name").GetString());
                continue;
            }
            bool text = c.TryGetProperty("rawArtifact", out var raw);
            Assert.NotEqual(text, c.TryGetProperty("rawBytesBase64", out var base64));
            byte[] bytes = text ? Encoding.UTF8.GetBytes(raw.GetString()!) : Convert.FromBase64String(base64.GetString()!);
            var error = Record.Exception(() => LanguageModel.Parse(bytes, tables, true));
            if (c.GetProperty("valid").GetBoolean()) Assert.Null(error);
            else Assert.True(error is InvalidDataException, $"{c.GetProperty("name").GetString()}: {error?.ToString() ?? "accepted invalid artifact"}");
        }
    }

    [Fact]
    public void EverySharedJsonValidationCase()
    {
        var cases = SharedFixtures.Json("contracts/lang-json-validation-v1.json").GetProperty("cases");
        Assert.Equal(18, cases.GetArrayLength());
        foreach (var c in cases.EnumerateArray())
        {
            var error = Record.Exception(() =>
            {
                using var document = LanguageJson.Parse(Encoding.UTF8.GetBytes(c.GetProperty("rawJson").GetString()!));
            });
            if (c.GetProperty("valid").GetBoolean()) Assert.Null(error);
            else Assert.True(error is InvalidDataException, $"{c.GetProperty("name").GetString()}: {error?.ToString() ?? "accepted invalid JSON"}");
        }
    }

    [Fact]
    public void ProductionLoadingRejectsSyntheticModel()
    {
        var fixture = SharedFixtures.Json("contracts/lang-score-v1.json");
        byte[] data = Encoding.UTF8.GetBytes(fixture.GetProperty("model").GetRawText() + "\n");
        Assert.Throws<InvalidDataException>(() => LanguageModel.Parse(data, UnicodeTables.LoadBundled(), false));
    }

    [Theory]
    [InlineData("\"\\ud800\"")]
    [InlineData("\"\\udc00\"")]
    [InlineData("9223372036854775808")]
    [InlineData("-9223372036854775809")]
    [InlineData("1e0")]
    [InlineData("1.0")]
    public void StrictParserRejectsInvalidTokensBeforeSchema(string token)
    {
        byte[] bytes = Encoding.UTF8.GetBytes("{\"value\":" + token + "}\n");
        Assert.Throws<InvalidDataException>(() => LanguageJson.Parse(bytes));
    }

    [Fact]
    public void StrictParserRetainsValidSurrogatePairAndIntegerExtremes()
    {
        using var document = LanguageJson.Parse("{\"pair\":\"\\ud801\\udc00\",\"min\":-9223372036854775808,\"max\":9223372036854775807}\n"u8);
        Assert.Equal("𐐀", document.RootElement.GetProperty("pair").GetString());
        Assert.Equal(long.MinValue, document.RootElement.GetProperty("min").GetInt64());
        Assert.Equal(long.MaxValue, document.RootElement.GetProperty("max").GetInt64());
    }
}
