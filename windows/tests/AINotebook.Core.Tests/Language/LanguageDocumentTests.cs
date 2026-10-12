using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class LanguageDocumentTests
{
    private static LanguageDetector Detector()
    {
        var fixture = SharedFixtures.Json("contracts/lang-score-v1.json");
        return LanguageDetector.CreateForTests(Encoding.UTF8.GetBytes(fixture.GetProperty("model").GetRawText() + "\n"), UnicodeTables.LoadBundled());
    }

    [Fact]
    public void EveryDocumentIntermediate()
    {
        var detector = Detector();
        var cases = SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("mode").GetString() == "document").ToArray();
        Assert.Equal(9, cases.Length);
        foreach (var c in cases)
        {
            string input = c.GetProperty("input").GetString()!;
            var result = detector.DetectDocument(input);
            Assert.NotNull(result);
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), detector.DetectDocument(input.Select(x => (ushort)x).ToArray()),
                c.GetProperty("name").GetString()! + " UTF16");
        }
    }

    [Fact]
    public void SupplementalWindowAndAggregationCases()
    {
        int tested = 0;
        foreach (var c in SharedFixtures.Json("contracts/lang-runtime-v1.json").GetProperty("cases").EnumerateArray())
        {
            var input = c.GetProperty("input");
            switch (c.GetProperty("operation").GetString())
            {
                case "windows":
                    var ranges = LanguageDocument.Ranges(input.GetProperty("length").GetInt32(), input.GetProperty("count").GetInt32(), input.GetProperty("size").GetInt32());
                    LanguageFixtureAssert.Equal(c.GetProperty("expected"), ranges.Select(r => new[] { r.Start, r.End }).ToArray(), c.GetProperty("name").GetString()!);
                    for (int i = 1; i < ranges.Length; i++) Assert.True(ranges[i - 1].End <= ranges[i].Start);
                    tested++;
                    break;
                case "aggregate":
                    var result = LanguageDocument.Aggregate(input.GetProperty("targets").EnumerateArray().Select(x => x.GetString()!).ToArray(),
                        input.GetProperty("labels").EnumerateArray().Select(x => x.GetString()!).ToArray(),
                        input.GetProperty("letters").EnumerateArray().Select(x => x.GetInt64()).ToArray());
                    LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
                    tested++;
                    break;
            }
        }
        Assert.Equal(8, tested);
    }

    [Fact]
    public void DocumentSamplingPrecedesTextModeCap()
    {
        var fixture = SharedFixtures.Json("contracts/lang-score-v1.json");
        var model = JsonNode.Parse(fixture.GetProperty("model").GetRawText())!;
        model["parameters"]!["textCapScalars"] = 14;
        var detector = LanguageDetector.CreateForTests(Encoding.UTF8.GetBytes(model.ToJsonString() + "\n"), UnicodeTables.LoadBundled());
        foreach (var c in fixture.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("mode").GetString() == "document"))
        {
            string input = c.GetProperty("input").GetString()!;
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), detector.DetectDocument(input), c.GetProperty("name").GetString()!);
            var windows = c.GetProperty("expected").GetProperty("windows");
            if (windows.GetArrayLength() > 0)
                LanguageFixtureAssert.Equal(windows[0].GetProperty("expected"), detector.DetectText(input), "text cap uses the first 14 scalars");
        }
    }

    [Fact]
    public async Task ConcurrentDocumentsAndNestedSnapshotsAreIndependent()
    {
        var detector = Detector();
        const string input = "aaaa aaaa aaaa bbbb bbbb bbbb cccc cccc cccc";
        var original = detector.DetectDocument(input);
        Assert.NotNull(original);
        var expected = JsonSerializer.SerializeToElement(original, LanguageFixtureAssert.Json);
        var results = await Task.WhenAll(Enumerable.Range(0, 24).Select(_ => Task.Run(() => detector.DetectDocument(input))));
        foreach (var result in results) LanguageFixtureAssert.Equal(expected, result, "concurrent document");
        original.Windows[0].Expected.WordScalars[0][0] = 0;
        original.Windows[0].Expected.Profiles["xa"].OrderScores[0] = 999;
        original.Windows[0] = new LanguageWindow(0, 0, original.Windows[0].Expected);
        foreach (var result in results) LanguageFixtureAssert.Equal(expected, result, "isolated document");
        LanguageFixtureAssert.Equal(expected, detector.DetectDocument(input), "subsequent document");
    }
}
