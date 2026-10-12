using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderLimitPolicyTests
{
    [Fact]
    public void SharedLimits()
    {
        foreach (var c in SharedFixtures.Json("contracts/provider-limits-v1.json").GetProperty("cases").EnumerateArray())
        {
            int? window = c.GetProperty("window").ValueKind == JsonValueKind.Null ? null : c.GetProperty("window").GetInt32();
            var model = c.GetProperty("model").GetString()!;
            if (c.TryGetProperty("user", out var user))
            {
                var value = new ProviderModelLimits("p", model, window, user.GetProperty("runtimeContext").GetInt32(), user.GetProperty("maxOutputTokens").GetInt32(), "user");
                Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(value.Validate).Code);
                continue;
            }
            if (c.TryGetProperty("show", out var show))
                Assert.Equal(window, ProviderLimitPolicy.ContextWindowFromOllamaShow(show.GetRawText()));
            var limits = ProviderLimitPolicy.Automatic("p", ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!), model, window);
            var e = c.GetProperty("expected");
            Assert.Equal(e.GetProperty("contextWindow").ValueKind == JsonValueKind.Null ? (int?)null : e.GetProperty("contextWindow").GetInt32(), limits.ContextWindow);
            Assert.Equal(e.GetProperty("runtimeContext").GetInt32(), limits.RuntimeContext);
            Assert.Equal(e.GetProperty("maxOutputTokens").GetInt32(), limits.MaxOutputTokens);
            Assert.Equal(e.GetProperty("source").GetString(), limits.Source);
            Assert.Equal(e.GetProperty("isAssumed").GetBoolean(), limits.IsAssumed);
        }
    }
    /// <summary>provider-listing-limits-v1: windows advertised by OpenWebUI / OpenAI-compatible listings.</summary>
    [Fact]
    public void SharedListingLimits()
    {
        var fixture = SharedFixtures.Json("contracts/provider-listing-limits-v1.json");
        Assert.Equal(ProviderLimitPolicy.ListedRuntimeCap, fixture.GetProperty("listedRuntimeCap").GetInt32());
        Assert.Equal(ProviderLimitPolicy.ListingTypes.OrderBy(t => t),
            fixture.GetProperty("listingTypes").EnumerateArray().Select(t => ProviderTypeExtensions.FromStorageString(t.GetString()!)).OrderBy(t => t));
        Assert.Equal(ProviderLimitPolicy.ListingKeyPaths.Select(p => string.Join('.', p)),
            fixture.GetProperty("keyPaths").EnumerateArray().Select(p => string.Join('.', p.EnumerateArray().Select(k => k.GetString()))));
        var cases = fixture.GetProperty("cases").EnumerateArray().ToList();
        Assert.Equal(19, cases.Count);
        foreach (var c in cases)
        {
            string name = c.GetProperty("name").GetString()!;
            var type = ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!);
            string model = c.GetProperty("model").GetString()!, listing = c.GetProperty("listing").GetString()!;
            var expected = c.GetProperty("expected");
            int? window = null;
            if (expected.TryGetProperty("error", out _))
                Assert.ThrowsAny<JsonException>(() => ProviderLimitPolicy.ContextWindowFromModelListing(listing, model));
            else if (ProviderLimitPolicy.ListingTypes.Contains(type))
            {
                window = ProviderLimitPolicy.ContextWindowFromModelListing(listing, model);
                var w = expected.GetProperty("window");
                Assert.True((w.ValueKind == JsonValueKind.Null ? (int?)null : w.GetInt32()) == window, name);
            }
            var limits = ProviderLimitPolicy.Automatic("p", type, model, window, listed: true);
            var row = expected.GetProperty("limits");
            Assert.True((row.GetProperty("contextWindow").ValueKind == JsonValueKind.Null ? (int?)null : row.GetProperty("contextWindow").GetInt32())
                == limits.ContextWindow, name);
            Assert.True(row.GetProperty("runtimeContext").GetInt32() == limits.RuntimeContext, name);
            Assert.True(row.GetProperty("maxOutputTokens").GetInt32() == limits.MaxOutputTokens, name);
            Assert.True(row.GetProperty("source").GetString() == limits.Source, name);
            Assert.True(row.GetProperty("isAssumed").GetBoolean() == limits.IsAssumed, name);
        }
        // Unlisted windows keep the frozen rule: advertised context never raises the runtime.
        Assert.Equal(8192, ProviderLimitPolicy.Automatic("p", ProviderType.Ollama, "m", 32_768, listed: true).RuntimeContext);
        Assert.Equal(8192, ProviderLimitPolicy.Automatic("p", ProviderType.OpenWebUI, "m", 131_072).RuntimeContext);
    }

    [Fact]
    public void Presets()
    {
        var rows = SharedFixtures.Json("contracts/provider-presets-v1.json").GetProperty("cases").EnumerateArray().ToArray();
        Assert.Equal(rows.Length, ProviderPresets.All.Count);
        for (var i = 0; i < rows.Length; i++)
        {
            Assert.Equal(rows[i].GetProperty("name").GetString(), ProviderPresets.All[i].Id);
            Assert.Equal(rows[i].GetProperty("label").GetString(), ProviderPresets.All[i].Name);
            Assert.Equal(rows[i].GetProperty("baseURL").GetString(), ProviderPresets.All[i].BaseUrl);
            Assert.Equal(rows[i].GetProperty("helpKey").GetString(), ProviderPresets.All[i].HelpKey);
        }
    }

    [Theory]
    [InlineData("", "m", "auto")]
    [InlineData(" ", "m", "auto")]
    [InlineData("p", "\t", "auto")]
    [InlineData("p", "m", "other")]
    public void InvalidIdentityOrSourceIsRejected(string provider, string model, string source)
    {
        var limits = new ProviderModelLimits(provider, model, null, 8192, 1024, source);
        Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(limits.Validate).Code);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(0)]
    [InlineData(1)]
    public void UnusableSuppliedCeilingIsRejected(int window) =>
        Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(() =>
            ProviderLimitPolicy.Automatic("p", ProviderType.Ollama, "m", window)).Code);

    [Fact]
    public void SuppliedCeilingWinsAndOptionsPreserveExactLimits()
    {
        var limits = ProviderLimitPolicy.Automatic("p", ProviderType.OpenAI, "gpt-4o-mini", 512);
        Assert.Equal(512, limits.ContextWindow);
        Assert.Equal(new ChatRequestOptions(512, 511), limits.Options);
        Assert.False(new ProviderModelLimits("p", "m", null, 4096, 333, "user").IsAssumed);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[]")]
    [InlineData("{\"model_info\":null}")]
    [InlineData("{\"model_info\":[]}")]
    [InlineData("{\"model_info\":{\"general.architecture\":3}}")]
    [InlineData("{\"model_info\":{\"general.architecture\":\"llama\",\"llama.context_length\":\"8192\"}}")]
    public void InvalidMetadataHasNoCeiling(string json) =>
        Assert.Null(ProviderLimitPolicy.ContextWindowFromOllamaShow(json));

    [Fact]
    public void MalformedMetadataThrows() =>
        Assert.Throws<JsonException>(() => ProviderLimitPolicy.ContextWindowFromOllamaShow("{"));
}
