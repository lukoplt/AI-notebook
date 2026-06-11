namespace AINotebook.Core.Providers;

public enum ProviderType { Ollama, Anthropic, OpenAI, OpenAICompatible }

public static class ProviderTypeExtensions
{
    public static string ToStorageString(this ProviderType t) => t switch
    {
        ProviderType.Ollama => "ollama",
        ProviderType.Anthropic => "anthropic",
        ProviderType.OpenAI => "openai",
        ProviderType.OpenAICompatible => "openai_compatible",
        _ => throw new ArgumentOutOfRangeException(nameof(t))
    };

    public static ProviderType FromStorageString(string s) => s switch
    {
        "ollama" => ProviderType.Ollama,
        "anthropic" => ProviderType.Anthropic,
        "openai" => ProviderType.OpenAI,
        "openai_compatible" => ProviderType.OpenAICompatible,
        _ => ProviderType.OpenAICompatible
    };

    public static string DefaultBaseUrl(this ProviderType t) => t switch
    {
        ProviderType.Ollama => "http://127.0.0.1:11434",
        ProviderType.Anthropic => "https://api.anthropic.com",
        ProviderType.OpenAI => "https://api.openai.com",
        ProviderType.OpenAICompatible => "",
        _ => ""
    };

    public static bool SupportsEmbeddings(this ProviderType t) =>
        t != ProviderType.Anthropic;
}
