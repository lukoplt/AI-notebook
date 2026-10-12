using System.Text.Json;
using System.Text.Json.Nodes;

namespace AINotebook.Core.Tests.Helpers;

/// <summary>
/// Frozen job fixture cases that pinned five attempts for extract jobs, replaced by <c>ingestion-retry-cap-v1</c> §1a (its
/// <c>supersedes</c> map: whole replacement cases). The frozen files stay byte-identical; consumers swap in exactly the
/// listed cases (same as macOS RetryCapSupersession).
/// </summary>
internal static class RetryCapSupersession
{
    private static JsonElement Map() => SharedFixtures.Json("contracts/ingestion-retry-cap-v1.json").GetProperty("supersedes");

    /// <summary>The case, or its replacement when the retry cap supersedes it.</summary>
    public static JsonElement Apply(JsonElement row, string fixture) =>
        Map().TryGetProperty(fixture, out var cases) && row.TryGetProperty("name", out var name)
            && cases.TryGetProperty(name.GetString()!, out var replacement) ? replacement.Clone() : row;

    /// <summary>The frozen fixture document with every superseded case replaced.</summary>
    public static JsonElement Document(string fixture)
    {
        var root = JsonNode.Parse(SharedFixtures.Json("contracts/" + fixture).GetRawText())!.AsObject();
        var cases = new JsonArray();
        foreach (var row in SharedFixtures.Json("contracts/" + fixture).GetProperty("cases").EnumerateArray())
            cases.Add(JsonNode.Parse(Apply(row, fixture).GetRawText()));
        root["cases"] = cases;
        return JsonSerializer.SerializeToElement(root);
    }
}
