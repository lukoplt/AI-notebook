using System.Text.Json;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Providers;

public sealed record ProviderModelLimits(string ProviderId, string Model, int? ContextWindow,
    int RuntimeContext, int MaxOutputTokens, string Source)
{
    public bool IsAssumed => Source == "auto" && ContextWindow is null;
    public ChatRequestOptions Options => new(RuntimeContext, MaxOutputTokens);

    public void Validate()
    {
        if (string.IsNullOrWhiteSpace(ProviderId) || string.IsNullOrWhiteSpace(Model) ||
            Source is not ("auto" or "user") || ContextWindow <= 0 ||
            RuntimeContext <= 0 || MaxOutputTokens <= 0 || MaxOutputTokens >= RuntimeContext ||
            RuntimeContext > ContextWindow)
            throw new ProviderConfigurationException("invalidLimits");
    }
}

public static class ProviderLimitPolicy
{
    /// <summary>Automatic metadata belongs to a provider type and normalized API root.</summary>
    internal static bool HasSameEndpoint(ProviderConfig left, ProviderConfig right) =>
        left.Type == right.Type && string.Equals(EndpointRoot(left.BaseUrl), EndpointRoot(right.BaseUrl),
            StringComparison.Ordinal);

    private static string EndpointRoot(string root)
    {
        try { return ProviderApiRoot.Normalize(root); }
        catch (ProviderConfigurationException) { return root; }
    }

    /// <summary>provider-listing-limits-v1: a window the provider's own model listing advertises for an
    /// OpenWebUI / OpenAI-compatible model raises the runtime context up to this cap.</summary>
    public const int ListedRuntimeCap = 32_768;
    public static readonly IReadOnlySet<ProviderType> ListingTypes = new HashSet<ProviderType> { ProviderType.OpenWebUI, ProviderType.OpenAICompatible };

    /// <summary>provider-listing-limits-v1 key paths, in priority order.</summary>
    public static readonly IReadOnlyList<string[]> ListingKeyPaths =
    [
        ["context_length"], ["max_model_len"], ["max_context_length"], ["context_window"], ["max_input_tokens"],
        ["top_provider", "context_length"], ["info", "params", "num_ctx"],
        ["openai", "context_length"], ["openai", "max_model_len"], ["openai", "max_context_length"],
        ["openai", "context_window"], ["openai", "max_input_tokens"],
    ];

    /// <summary>The first valid integer window (2…2³¹−1) of one listing item; null when none.</summary>
    public static int? ContextWindowFromListingItem(JsonElement item)
    {
        foreach (var path in ListingKeyPaths)
        {
            var value = item;
            bool found = true;
            foreach (var key in path)
            {
                if (value.ValueKind != JsonValueKind.Object || !value.TryGetProperty(key, out value)) { found = false; break; }
            }
            if (found && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out long window) && window is >= 2 and <= int.MaxValue)
                return (int)window;
        }
        return null;
    }

    /// <summary>The window of the first <c>data</c> item whose <c>id</c> equals <paramref name="model"/> exactly;
    /// null when unknown. Malformed JSON throws <see cref="JsonException"/> (callers treat any failure as unknown).</summary>
    public static int? ContextWindowFromModelListing(string json, string model)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array)
            return null;
        foreach (var item in data.EnumerateArray())
            if (item.ValueKind == JsonValueKind.Object && item.TryGetProperty("id", out var id)
                && id.ValueKind == JsonValueKind.String && string.Equals(id.GetString(), model, StringComparison.Ordinal))
                return ContextWindowFromListingItem(item);
        return null;
    }

    /// <summary><paramref name="listed"/>: <paramref name="contextWindow"/> comes from the provider's model listing
    /// (provider-listing-limits-v1). Every other window (Ollama show, the known OpenAI table) never raises the 8 192 default.</summary>
    public static ProviderModelLimits Automatic(string providerId, ProviderType type,
        string model, int? contextWindow, bool listed = false)
    {
        int? known = type == ProviderType.OpenAI &&
            model is "gpt-4o-mini" or "gpt-4o-mini-2024-07-18" ? 128_000 : null;
        var window = contextWindow ?? known;
        if (window < 2) throw new ProviderConfigurationException("invalidLimits");
        var runtime = listed && contextWindow is int listedWindow && ListingTypes.Contains(type)
            ? Math.Min(listedWindow, ListedRuntimeCap)
            : Math.Min(RagContractV1.Providers.DefaultRuntimeContext, window ?? int.MaxValue);
        var output = Math.Min(RagContractV1.Providers.DefaultMaxOutputTokens, runtime - 1);
        var result = new ProviderModelLimits(providerId, model, window, runtime, output, "auto");
        result.Validate();
        return result;
    }

    public static int? ContextWindowFromOllamaShow(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object ||
                !root.TryGetProperty("model_info", out var info) || info.ValueKind != JsonValueKind.Object ||
                !info.TryGetProperty("general.architecture", out var architecture) ||
                architecture.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(architecture.GetString()) ||
                !info.TryGetProperty(architecture.GetString() + ".context_length", out var length) ||
                length.ValueKind != JsonValueKind.Number || !length.TryGetInt32(out var window) || window < 2)
                return null;
            return window;
        }
        catch (JsonException)
        {
            // Expose a stable decoding error without echoing provider response data.
            throw new JsonException("Invalid Ollama model metadata.");
        }
    }
}
