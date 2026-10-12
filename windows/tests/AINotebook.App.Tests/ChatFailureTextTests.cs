using System.Net.Http;
using System.Text.Json;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.App.Tests;

/// Shared chat failure presentation of the chat page and the notes chat panel.
public class ChatFailureTextTests
{
    private static string Format(Exception ex) => ChatFailureText.Format(ex, key => key.ToString());

    public static TheoryData<Exception, string> KnownCategories() => new()
    {
        { new ContextPackException("contextTooSmall"), nameof(StringKey.ContextTooSmall) },
        { new ProviderConsentException("consent"), nameof(StringKey.ErrorConsentRequired) },
        { new ProviderContextTooLongException(), nameof(StringKey.ProviderContextTooLong) },
        { new ProviderConfigurationException("invalidBaseURL"), nameof(StringKey.ProviderInvalidRoot) },
        { new ProviderConfigurationException("missingProvider"), nameof(StringKey.ProviderSelectionUnavailable) },
        { new StalePreparedRequestException(), nameof(StringKey.ProviderRequestFailed) },
        { new HttpRequestException("secret URL"), nameof(StringKey.ProviderConnectionFailed) },
        { new JsonException("secret body"), nameof(StringKey.ProviderResponseInvalid) },
    };

    [Theory]
    [MemberData(nameof(KnownCategories))]
    public void KnownFailuresUseLocalizedCategories(Exception ex, string expected) =>
        Assert.Equal(expected, Format(ex));

    [Fact]
    public void UnknownFailuresShowGenericTextAndLogTheDetails()
    {
        var logged = new List<string>();
        var ex = new InvalidOperationException("SQLite error near /Users/secret/path");
        string text = ChatFailureText.Format(ex, key => key.ToString(), logged.Add);
        Assert.Equal(nameof(StringKey.ProviderRequestFailed), text);
        Assert.DoesNotContain("secret", text);
        Assert.Contains(logged, line => line.Contains("SQLite error near /Users/secret/path"));
    }

    [Fact]
    public void KnownFailuresAreNotLogged()
    {
        var logged = new List<string>();
        ChatFailureText.Format(new HttpRequestException("x"), key => key.ToString(), logged.Add);
        Assert.Empty(logged);
    }

    [Fact]
    public void OnlyContextTooSmallKeepsTheDraft()
    {
        Assert.True(ChatFailureText.KeepsDraft(new ContextPackException("contextTooSmall")));
        Assert.False(ChatFailureText.KeepsDraft(new ContextPackException("invalidInput")));
        Assert.False(ChatFailureText.KeepsDraft(new HttpRequestException()));
    }
}
