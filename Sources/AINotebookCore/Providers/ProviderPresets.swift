public struct ProviderPreset: Equatable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let helpKey: String
}

public enum ProviderPresets {
    public static let all: [ProviderPreset] = [
        .init(id: "lmstudio", name: "LM Studio", baseURL: "http://localhost:1234/v1", helpKey: "providerPresetLocalHelp"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", helpKey: "providerPresetRemoteHelp"),
        .init(id: "vllm", name: "vLLM", baseURL: "http://localhost:8000/v1", helpKey: "providerPresetLocalHelp"),
        .init(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", helpKey: "providerPresetRemoteHelp"),
        .init(id: "mistral", name: "Mistral", baseURL: "https://api.mistral.ai/v1", helpKey: "providerPresetRemoteHelp"),
        .init(id: "together", name: "Together", baseURL: "https://api.together.ai/v1", helpKey: "providerPresetRemoteHelp"),
        .init(id: "custom", name: "Custom", baseURL: "", helpKey: "providerPresetCustomHelp")
    ]
}
