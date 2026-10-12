using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;

namespace AINotebook.Core.Tests.Language;

internal static class LanguageFixtureAssert
{
    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never
    };

    internal static void Equal<T>(JsonElement expected, T actual, string name)
    {
        var a = JsonSerializer.SerializeToNode(actual, Json);
        var e = JsonNode.Parse(expected.GetRawText());
        Assert.True(JsonNode.DeepEquals(e, a), $"{name}\nexpected: {e}\nactual: {a}");
    }
}
