using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

public class ProviderTypeTests
{
    [Fact]
    public void OpenWebUI_storage_string_roundtrips()
    {
        Assert.Equal("openwebui", ProviderType.OpenWebUI.ToStorageString());
        Assert.Equal(ProviderType.OpenWebUI, ProviderTypeExtensions.FromStorageString("openwebui"));
    }

    [Fact]
    public void Unknown_storage_string_still_falls_back_to_OpenAICompatible()
    {
        Assert.Equal(ProviderType.OpenAICompatible, ProviderTypeExtensions.FromStorageString("something_else"));
    }

    [Fact]
    public void OpenWebUI_has_empty_default_base_url()
    {
        Assert.Equal("", ProviderType.OpenWebUI.DefaultBaseUrl());
    }

    [Fact]
    public void OpenWebUI_does_not_support_embeddings()
    {
        Assert.False(ProviderType.OpenWebUI.SupportsEmbeddings());
    }

    [Fact]
    public void OpenWebUI_config_counts_as_cloud()
    {
        var cfg = new ProviderConfig(
            "some-id", ProviderType.OpenWebUI, "LAN server",
            "http://192.168.1.50:3000", true, false, DateTime.UtcNow);
        Assert.True(cfg.IsCloud);
    }

    // Regression net: the four existing types keep their storage behavior.
    [Theory]
    [InlineData(ProviderType.Ollama, "ollama")]
    [InlineData(ProviderType.Anthropic, "anthropic")]
    [InlineData(ProviderType.OpenAI, "openai")]
    [InlineData(ProviderType.OpenAICompatible, "openai_compatible")]
    public void Existing_types_roundtrip(ProviderType t, string s)
    {
        Assert.Equal(s, t.ToStorageString());
        Assert.Equal(t, ProviderTypeExtensions.FromStorageString(s));
    }
}
