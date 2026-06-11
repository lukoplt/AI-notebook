namespace AINotebook.Core.Providers;

public record ProviderConfig(
    string Id,
    ProviderType Type,
    string Name,
    string BaseUrl,
    bool Enabled,
    bool PrivacyAcknowledged,
    DateTime CreatedAt)
{
    // Well-known ID for the built-in Ollama provider — never deleted.
    public static readonly string OllamaId = "00000000-0000-0000-0000-000000000000";

    public bool IsOllama => Id == OllamaId;
    public bool IsCloud => Type == ProviderType.Anthropic
                        || Type == ProviderType.OpenAI
                        || Type == ProviderType.OpenAICompatible;
}

public record ProviderModelInfo(string Id, string? DisplayName)
{
    public string Label => DisplayName is { Length: > 0 } d ? d : Id;
}
