using System.Text.Json;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class RetrievalScopeTests
{
    public static IEnumerable<object[]> Cases() => FixtureCases("cases");
    public static IEnumerable<object[]> UnionCases() => FixtureCases("unionCases");

    private static IEnumerable<object[]> FixtureCases(string key) =>
        SharedFixtures.Json("contracts/scope-v1.json").GetProperty(key).EnumerateArray()
            .Select(c => new object[] { c.GetProperty("name").GetString()!, c });

    [Theory]
    [MemberData(nameof(Cases))]
    public void SharedCases(string name, JsonElement item)
    {
        var raw = item.GetProperty("json").GetRawText();
        if (item.TryGetProperty("error", out var error) && error.GetBoolean())
        {
            Assert.Throws<JsonException>(() => RetrievalScopeJson.Deserialize(raw));
            return;
        }
        var scope = RetrievalScopeJson.Deserialize(raw);
        Assert.Equal(item.GetProperty("isEmptySelection").GetBoolean(), scope.IsEmptySelection);
        var expected = item.TryGetProperty("canonical", out var canonical) ? canonical : item.GetProperty("json");
        using var encoded = JsonDocument.Parse(RetrievalScopeJson.Serialize(scope));
        Assert.True(JsonElement.DeepEquals(expected, encoded.RootElement), name);
        Assert.Equal(scope, RetrievalScopeJson.Deserialize(encoded.RootElement.GetRawText()));
    }

    [Theory]
    [MemberData(nameof(UnionCases))]
    public void SharedUnions(string name, JsonElement item)
    {
        var inputs = item.GetProperty("inputs").EnumerateArray()
            .Select(c => RetrievalScopeJson.Deserialize(c.GetRawText()));
        var union = RetrievalScope.Union(inputs);
        var expected = item.GetProperty("expected");
        Assert.Equal(RetrievalScopeJson.Deserialize(expected.GetRawText()), union);
        using var encoded = JsonDocument.Parse(RetrievalScopeJson.Serialize(union));
        Assert.True(JsonElement.DeepEquals(expected, encoded.RootElement), name);
    }

    [Fact]
    public void SelectionEqualityAndHashAreBySetContents()
    {
        var first = new RetrievalScope.Selection(new HashSet<long> { 3, 1 }, new HashSet<long> { 9 });
        var second = new RetrievalScope.Selection(new HashSet<long> { 1, 3 }, new HashSet<long> { 9 });
        Assert.Equal(first, second);
        Assert.Equal(first.GetHashCode(), second.GetHashCode());
        Assert.Single(new HashSet<RetrievalScope> { first, second });
        Assert.NotEqual(first, new RetrievalScope.Selection(new HashSet<long> { 1 }, new HashSet<long> { 9 }));
        Assert.NotEqual(first, new RetrievalScope.Selection(new HashSet<long> { 1, 3 }, new HashSet<long>()));
        Assert.NotEqual<RetrievalScope>(new RetrievalScope.All(), new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long>()));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{\"kind\":42}")]
    [InlineData("{\"kind\":\"selection\",\"sourceIds\":[]}")]
    [InlineData("{\"kind\":\"selection\",\"sourceIds\":null,\"folderIds\":[]}")]
    [InlineData("{\"kind\":\"selection\",\"sourceIds\":[true],\"folderIds\":[]}")]
    public void MalformedScopesThrowJsonException(string raw) =>
        Assert.Throws<JsonException>(() => RetrievalScopeJson.Deserialize(raw));

    [Theory]
    [InlineData("1.0", 1L)]
    [InlineData("1e3", 1000L)]
    [InlineData("-1", -1L)]
    [InlineData("9223372036854775807", long.MaxValue)]
    [InlineData("-9223372036854775808", long.MinValue)]
    [InlineData("1.0000000000000000000000000000001", 1L)]
    [InlineData("1e-1000", 0L)]
    public void ScopeNumbersMatchSwiftJsonDecoder(string token, long expected)
    {
        // Scope uses ordinary Swift Codable, unlike the strict citations codec.
        var raw = $"{{\"kind\":\"selection\",\"sourceIds\":[{token}],\"folderIds\":[]}}";
        var scope = Assert.IsType<RetrievalScope.Selection>(RetrievalScopeJson.Deserialize(raw));
        Assert.Equal(expected, Assert.Single(scope.SourceIds));
    }

    [Theory]
    [InlineData("1.5")]
    [InlineData("9223372036854775807.0")]
    [InlineData("1e1000")]
    public void NonIntegralOrOverflowingScopeNumbersFail(string token)
    {
        var raw = $"{{\"kind\":\"selection\",\"sourceIds\":[{token}],\"folderIds\":[]}}";
        Assert.Throws<JsonException>(() => RetrievalScopeJson.Deserialize(raw));
    }
}
