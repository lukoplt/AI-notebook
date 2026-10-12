namespace AINotebook.Core.Providers;

public sealed record ProviderPreset(string Id, string Name, string BaseUrl, string HelpKey);

public static class ProviderPresets
{
    public static IReadOnlyList<ProviderPreset> All { get; } = Array.AsReadOnly<ProviderPreset>([
        new("lmstudio", "LM Studio", "http://localhost:1234/v1", "providerPresetLocalHelp"),
        new("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", "providerPresetRemoteHelp"),
        new("vllm", "vLLM", "http://localhost:8000/v1", "providerPresetLocalHelp"),
        new("groq", "Groq", "https://api.groq.com/openai/v1", "providerPresetRemoteHelp"),
        new("mistral", "Mistral", "https://api.mistral.ai/v1", "providerPresetRemoteHelp"),
        new("together", "Together", "https://api.together.ai/v1", "providerPresetRemoteHelp"),
        new("custom", "Custom", "", "providerPresetCustomHelp")
    ]);
}
