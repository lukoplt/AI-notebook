using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

/// <summary>
/// FR-A8: shape/existence tests for <see cref="ProviderConsentException"/>. The
/// throwing behavior itself (router gating) is exercised in the App layer
/// (ProviderRouterOpenWebUITests / ProviderRouterEmbedCompositeKeyTests) since
/// ProviderRouter lives in AINotebook.App, not Core.
/// </summary>
public class ProviderExceptionsTests
{
    [Fact]
    public void ProviderConsentException_is_a_ProviderException()
    {
        var ex = new ProviderConsentException("consent required");
        Assert.IsAssignableFrom<ProviderException>(ex);
    }

    [Fact]
    public void ProviderConsentException_preserves_message()
    {
        var ex = new ProviderConsentException("Provider not enabled — confirm data sharing in Settings");
        Assert.Equal("Provider not enabled — confirm data sharing in Settings", ex.Message);
    }

    [Fact]
    public void ProviderConsentException_is_sealed_like_sibling_exceptions()
    {
        // Mirrors ProviderAuthException/ProviderRateLimitException/ProviderRefusalException style.
        Assert.True(typeof(ProviderConsentException).IsSealed);
        Assert.True(typeof(ProviderException).IsAssignableFrom(typeof(ProviderConsentException)));
    }
}
