using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

/// <summary>
/// WP4 release gate: the real production detector must reproduce every field of the Python
/// reference result on the committed held-out replay (and, when tools/lang/evaluate_detector.py
/// --native-parity supplies AINOTEBOOK_LANG_RELEASE_INPUT, on every held-out example).
/// <c>features</c>, <c>wordScalars</c> and <c>words</c> are compared through the fixture's canonical SHA-256 digests.
/// </summary>
public sealed class LanguageReleaseTests
{
    [Fact]
    public void ProductionReleaseCases()
    {
        var detector = LanguageDetector.LoadBundled();
        Assert.True(detector.IsAvailable, "production artifact must load");
        var paths = new List<string> { SharedFixtures.Path("contracts/lang-release-v1.json") };
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_LANG_RELEASE_INPUT") is string directory)
        {
            paths.AddRange(Directory.GetFiles(directory, "*.json").Order(StringComparer.Ordinal));
            Assert.True(paths.Count > 1, "full replay must not be empty");
        }
        int evaluated = 0;
        var mismatches = new List<string>();
        var details = new StringBuilder();
        foreach (var file in paths)
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
            Assert.Equal("lang-release", doc.RootElement.GetProperty("contract").GetString());
            foreach (var c in doc.RootElement.GetProperty("cases").EnumerateArray())
            {
                string input = c.GetProperty("input").GetString()!;
                string name = c.GetProperty("name").GetString()!;
                JsonNode actual;
                if (c.GetProperty("mode").GetString() == "text")
                {
                    var result = detector.DetectText(input);
                    Assert.NotNull(result);
                    actual = CompactText(JsonSerializer.SerializeToNode(result, LanguageFixtureAssert.Json)!);
                }
                else
                {
                    var result = detector.DetectDocument(input);
                    Assert.NotNull(result);
                    actual = CompactDocument(JsonSerializer.SerializeToNode(result, LanguageFixtureAssert.Json)!);
                }
                var expected = JsonNode.Parse(c.GetProperty("expected").GetRawText());
                if (!JsonNode.DeepEquals(expected, actual))
                {
                    if (mismatches.Count < 5)
                        details.Append($"{name}\nexpected: {Truncate(expected!.ToJsonString())}\nactual: {Truncate(actual.ToJsonString())}\n");
                    mismatches.Add(name);
                }
                evaluated++;
            }
        }
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_LANG_RELEASE_SUMMARY") is string summaryPath)
        {
            var summary = new JsonObject
            {
                ["cases"] = evaluated,
                ["files"] = paths.Count,
                ["firstMismatches"] = new JsonArray(mismatches.Take(20).Select(m => (JsonNode)JsonValue.Create(m)!).ToArray()),
                ["mismatches"] = mismatches.Count,
            };
            File.WriteAllText(summaryPath, summary.ToJsonString());
        }
        Assert.True(evaluated > 0);
        Assert.True(mismatches.Count == 0, $"release replay mismatches ({mismatches.Count}):\n{details}");
    }

    [Fact]
    public void CompactionDigestsMatchTheCanonicalDefinition()
    {
        var text = JsonNode.Parse("""
            {"features":[[{"symbols":[-2],"count":3},{"symbols":[97],"count":12}],[{"symbols":[-1,97],"count":3}],[]],
             "wordScalars":[[97,98],[269]],"words":["ab","č"],"label":"und"}
            """)!;
        var compact = CompactText(text);
        Assert.Equal("sha256:" + Sha256Hex("-2:3;97:12|-1,97:3|"), compact["features"]!.GetValue<string>());
        Assert.Equal("sha256:" + Sha256Hex("97,98;269"), compact["wordScalars"]!.GetValue<string>());
        Assert.Equal("sha256:" + Sha256Hex("ab\0č"), compact["words"]!.GetValue<string>());
        Assert.Equal("und", compact["label"]!.GetValue<string>());
    }

    private static string Truncate(string value) => value.Length <= 4000 ? value : value[..4000];

    private static string Sha256Hex(string text) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    private static string Integers(JsonNode? array) =>
        string.Join(",", array!.AsArray().Select(Number));

    // Integers only: their JSON text is the canonical decimal form.
    private static string Number(JsonNode? value) => value!.AsValue().ToJsonString();

    internal static JsonNode CompactText(JsonNode node)
    {
        var obj = node.AsObject();
        string features = string.Join("|", obj["features"]!.AsArray().Select(order => string.Join(";",
            order!.AsArray().Select(entry => Integers(entry!["symbols"]) + ":" +
                Number(entry!["count"])))));
        string words = string.Join(";", obj["wordScalars"]!.AsArray().Select(Integers));
        obj["features"] = "sha256:" + Sha256Hex(features);
        obj["wordScalars"] = "sha256:" + Sha256Hex(words);
        obj["words"] = "sha256:" + Sha256Hex(string.Join('\0', obj["words"]!.AsArray().Select(w => w!.GetValue<string>())));
        return obj;
    }

    internal static JsonNode CompactDocument(JsonNode node)
    {
        foreach (var window in node["windows"]!.AsArray())
            window!["expected"] = CompactText(window["expected"]!.DeepClone());
        return node;
    }
}
