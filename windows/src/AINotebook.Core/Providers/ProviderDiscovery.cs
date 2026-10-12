using System.Text.Json;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Providers;

public enum ProviderProbeStatus { Verified, ListingUnsupported, Failed }

public sealed record ProviderProbeResult(ProviderProbeStatus Status,
    IReadOnlyList<ProviderModelInfo> Models, string? ErrorCode, string? Detail)
{
    public bool GenerationVerified => false;
}

public sealed class ProviderListingUnsupportedException() : Exception("Model listing is unavailable.");

internal static class ProviderDiscovery
{
    internal static async Task<IReadOnlyList<ProviderModelInfo>> DiscoverAsync(
        HttpClient http, ProviderType type, string baseUrl, string? apiKey, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var root = ProviderApiRoot.Normalize(baseUrl);
        try
        {
            return type switch
            {
                ProviderType.Ollama => (await new OllamaClient(http, new Uri(root)).ListModelsAsync(ct))
                    .Select(model => new ProviderModelInfo(model.Name, null)).ToArray(),
                ProviderType.Anthropic => await AnthropicChatAdapter.ListModelsAsync(http, root, apiKey ?? "", ct),
                ProviderType.OpenAI => (await OpenAIChatAdapter.ListModelsAsync(http, root, apiKey, ct))
                    .Select(model => model with { ContextWindow = null }).ToArray(),
                ProviderType.OpenAICompatible => await OpenAIChatAdapter.ListModelsAsync(http, root, apiKey, ct),
                ProviderType.OpenWebUI => await OpenWebUIChatAdapter.ListModelsAsync(http, root, apiKey, ct),
                _ => throw new ProviderConfigurationException("unsupportedEndpoint")
            };
        }
        catch (ProviderHttpException ex) when (ex.StatusCode is 404 or 405 or 501)
        {
            throw new ProviderListingUnsupportedException();
        }
        catch (OllamaException.HttpStatus ex) when (ex.Code is 404 or 405 or 501)
        {
            throw new ProviderListingUnsupportedException();
        }
    }

    internal static async Task<ProviderProbeResult> ProbeAsync(
        HttpClient http, ProviderType type, string baseUrl, string? apiKey, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        try
        {
            var models = await DiscoverAsync(http, type, baseUrl, apiKey, ct);
            return new(ProviderProbeStatus.Verified, models, null, null);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (ProviderListingUnsupportedException)
        {
            return new(ProviderProbeStatus.ListingUnsupported, [], null, "Model listing is unavailable.");
        }
        catch (Exception ex)
        {
            // Provider response bodies, request headers and exception text can
            // contain credentials. Only local descriptions and status numbers
            // cross this boundary into Settings.
            var (code, detail) = ex switch
            {
                ProviderConfigurationException { Code: "invalidBaseURL" } =>
                    ("invalidBaseURL", "Invalid API root."),
                ProviderAuthException => ("auth", "Authentication failed."),
                OllamaException.HttpStatus { Code: 401 or 403 } => ("auth", "Authentication failed."),
                ProviderHttpException status => ("http", $"HTTP {status.StatusCode}."),
                OllamaException.HttpStatus status => ("http", $"HTTP {status.Code}."),
                ProviderRateLimitException => ("http", "HTTP 429."),
                JsonException or OllamaException.Decoding => ("decoding", "Invalid model listing response."),
                _ => ("transport", "Unable to retrieve the model listing.")
            };
            return new(ProviderProbeStatus.Failed, [], code, detail);
        }
    }
}
