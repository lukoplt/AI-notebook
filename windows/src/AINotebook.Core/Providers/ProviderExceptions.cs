namespace AINotebook.Core.Providers;

public class ProviderException(string message, Exception? inner = null) : Exception(message, inner);
public sealed class ProviderAuthException(string message) : ProviderException(message);
public sealed class ProviderRateLimitException(string message) : ProviderException(message);
public sealed class ProviderRefusalException(string message) : ProviderException(message);
