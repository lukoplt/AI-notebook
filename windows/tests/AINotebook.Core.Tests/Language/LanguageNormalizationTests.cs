using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class LanguageNormalizationTests
{
    [Fact]
    public void EveryNormalizationField()
    {
        var tables = UnicodeTables.LoadBundled();
        var cases = SharedFixtures.Json("contracts/lang-normalize-v1.json").GetProperty("cases");
        Assert.Equal(44, cases.GetArrayLength());
        foreach (var item in cases.EnumerateArray())
        {
            int[] stream = item.TryGetProperty("input", out var text)
                ? LanguageNormalization.Stream(text.GetString()!, tables, 5_000_000)
                : LanguageNormalization.Stream(item.GetProperty("utf16Units").EnumerateArray()
                    .Select(value => value.GetUInt16()).ToArray(), tables, 5_000_000);
            LanguageFixtureAssert.Equal(item.GetProperty("expected"),
                LanguageNormalization.Classify(stream, tables), item.GetProperty("name").GetString()!);
        }
    }

    [Fact]
    public void EveryRuntimeNormalizationField()
    {
        var tables = UnicodeTables.LoadBundled();
        var cases = SharedFixtures.Json("contracts/lang-runtime-v1.json").GetProperty("cases").EnumerateArray()
            .Where(item => item.GetProperty("operation").GetString() == "normalize").ToArray();
        Assert.Equal(5, cases.Length);
        foreach (var item in cases)
        {
            var input = item.GetProperty("input");
            var stream = LanguageNormalization.Stream(input.GetProperty("utf16Units").EnumerateArray()
                .Select(value => value.GetUInt16()).ToArray(), tables, input.GetProperty("inputCap").GetInt32());
            var scalars = input.GetProperty("mode").GetString() == "text"
                ? stream.Take(input.GetProperty("textCap").GetInt32()).ToArray()
                : stream;
            var words = LanguageNormalization.Classify(scalars, tables);
            LanguageFixtureAssert.Equal(item.GetProperty("expected"), new
            {
                Stream = stream,
                Scalars = scalars,
                words.Words,
                words.WordScalars,
                words.BoundaryWords,
                words.LetterCount,
                words.WordCount
            }, item.GetProperty("name").GetString()!);
        }
    }

    [Fact]
    public void StringWithUnpairedSurrogatesUsesTheExplicitDecoder()
    {
        var tables = UnicodeTables.LoadBundled();
        const string text = "\uD800A\uD801\uDC00\uDC00B\uD800";
        var units = text.Select(value => (ushort)value).ToArray();
        Assert.Equal(new[] { 0xFFFD, 65, 0x10400, 0xFFFD, 66, 0xFFFD },
            LanguageNormalization.Decode(units, 8));
        Assert.Equal(new[] { 0xFFFD, 65, 0x10400 }, LanguageNormalization.Decode(units, 3));
        Assert.Equal(new[] { 0xFFFD, 97, 0x10428, 0xFFFD, 98, 0xFFFD },
            LanguageNormalization.Stream(text, tables, 8));
        foreach (int cap in new[] { 1, 2, 3, 8 })
            Assert.Equal(LanguageNormalization.Stream(units, tables, cap),
                LanguageNormalization.Stream(text, tables, cap));
    }
}
