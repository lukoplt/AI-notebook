using System;
using System.Net.Http;
using System.Text.Json;
using AINotebook.App.Services;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;

namespace AINotebook.App.ViewModels;

/// <summary>
/// Localized, actionable chat failure text chosen by exception type (Core messages are
/// plain English; Core cannot reach .resw). Shared by the chat page and the notes chat
/// panel so both surfaces present the same categories. FR-A8 consent, WP2 provider
/// categories (including the context-length rejection) and WP8 contextTooSmall get
/// localized text. Anything else shows the generic localized request-failed text: raw
/// exception text can carry response bodies, SQL, paths or user input, so its details go
/// only to the debug log (macOS providerErrorText follows the same rule).
/// </summary>
internal static class ChatFailureText
{
    internal static string Format(Exception ex, Func<StringKey, string> localize, Action<string>? log = null) => ex switch
    {
        ContextPackException { Code: "contextTooSmall" } => localize(StringKey.ContextTooSmall),
        ProviderConsentException => localize(StringKey.ErrorConsentRequired),
        ProviderContextTooLongException => localize(StringKey.ProviderContextTooLong),
        ProviderConfigurationException { Code: "invalidBaseURL" } => localize(StringKey.ProviderInvalidRoot),
        ProviderConfigurationException { Code: "invalidLimits" } => localize(StringKey.ProviderLimitsInvalid),
        ProviderConfigurationException { Code: "missingProvider" or "disabledProvider" } => localize(StringKey.ProviderSelectionUnavailable),
        ProviderConfigurationException { Code: "unsupportedEndpoint" } => localize(StringKey.ProviderEndpointUnsupported),
        StalePreparedRequestException or PreparedRequestConsumedException or ChatSendInProgressException
            => localize(StringKey.ProviderRequestFailed),
        HttpRequestException => localize(StringKey.ProviderConnectionFailed),
        JsonException => localize(StringKey.ProviderResponseInvalid),
        _ => Unknown(ex, localize, log ?? (line => System.Diagnostics.Debug.WriteLine(line)))
    };

    private static string Unknown(Exception ex, Func<StringKey, string> localize, Action<string> log)
    {
        log($"Chat request failed: {ex}");
        return localize(StringKey.ProviderRequestFailed);
    }

    /// <summary>WP8 preparation failed before any row was written; the draft must survive.</summary>
    internal static bool KeepsDraft(Exception ex) => ex is ContextPackException { Code: "contextTooSmall" };
}
