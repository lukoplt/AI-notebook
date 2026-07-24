namespace AINotebook.Core.Providers;

public class ProviderException(string message, Exception? inner = null) : Exception(message, inner);
public sealed class ProviderAuthException(string message) : ProviderException(message);
/// <summary>
/// A 429 from the provider. <see cref="RetryAfter"/> carries the server's
/// Retry-After hint when it sent one, so <c>ChatEngine</c> can wait the
/// requested interval instead of hammering back after its own short backoff.
/// Mirrors Sources/AINotebookCore/Providers/ProviderError.swift's
/// <c>.rateLimit(retryAfterSeconds:)</c>.
/// </summary>
public sealed class ProviderRateLimitException(string message, TimeSpan? retryAfter = null)
    : ProviderException(message)
{
    public TimeSpan? RetryAfter { get; } = retryAfter;
}
public sealed class ProviderRefusalException(string message) : ProviderException(message);

/// <summary>
/// Thrown by <c>ProviderRouter</c> (FR-A8, defense-in-depth) when a cloud/network
/// provider is selected for chat or embeddings but the user has never acknowledged
/// the privacy gate for it. Terminal — callers must not blindly retry it, since
/// retrying cannot grant consent. Mirrors Sources/AINotebookCore/Providers/ProviderError.swift's
/// <c>.consentRequired</c> case.
/// </summary>
public sealed class ProviderConsentException(string message) : ProviderException(message);
