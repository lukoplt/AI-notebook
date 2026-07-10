namespace AINotebook.Core.Providers;

public class ProviderException(string message, Exception? inner = null) : Exception(message, inner);
public sealed class ProviderAuthException(string message) : ProviderException(message);
public sealed class ProviderRateLimitException(string message) : ProviderException(message);
public sealed class ProviderRefusalException(string message) : ProviderException(message);

/// <summary>
/// Thrown by <c>ProviderRouter</c> (FR-A8, defense-in-depth) when a cloud/network
/// provider is selected for chat or embeddings but the user has never acknowledged
/// the privacy gate for it. Terminal — callers must not blindly retry it, since
/// retrying cannot grant consent. Mirrors Sources/AINotebookCore/Providers/ProviderError.swift's
/// <c>.consentRequired</c> case.
/// </summary>
public sealed class ProviderConsentException(string message) : ProviderException(message);
