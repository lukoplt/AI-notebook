using AINotebook.Core.Rag;

namespace AINotebook.Core.Providers;

public sealed record ChatRequestOptions(int RuntimeContext, int MaxOutputTokens)
{
    public static ChatRequestOptions Defaults { get; } = new(
        RagContractV1.Providers.DefaultRuntimeContext,
        RagContractV1.Providers.DefaultMaxOutputTokens);

    public void Validate()
    {
        if (RuntimeContext <= 0 || MaxOutputTokens <= 0 || MaxOutputTokens >= RuntimeContext)
            throw new ProviderConfigurationException("invalidLimits");
    }
}
