using System.Text.Json;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Tests.Helpers;

internal static class ContextPackFixtures
{
    public static JsonSerializerOptions Options { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
    };

    public static JsonElement[] Cases(string kind) =>
        SharedFixtures.Json("contracts/context-pack-v1.json").GetProperty("cases")
            .EnumerateArray().Where(row => row.GetProperty("kind").GetString() == kind)
            .Select(row => row.Clone()).ToArray();

    public static ContextPackInput Input(string name) => Cases("build")
        .Single(row => row.GetProperty("name").GetString() == name)
        .GetProperty("input").Deserialize<ContextPackInput>(Options)!;
}
