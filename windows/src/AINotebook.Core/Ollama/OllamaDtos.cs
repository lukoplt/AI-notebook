using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Ollama;

/// Single shared serializer config. NO global naming policy — snake_case is
/// applied per-property via [JsonPropertyName]; nulls in options/request are
/// omitted (mirrors Swift JSONEncoder's default skip-nil behavior).
public static class OllamaJson
{
    public static readonly JsonSerializerOptions Options = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = false,
    };
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum OllamaChatRole
{
    [JsonStringEnumMemberName("system")] System,
    [JsonStringEnumMemberName("user")] User,
    [JsonStringEnumMemberName("assistant")] Assistant,
}

public sealed record OllamaChatMessage(
    [property: JsonPropertyName("role")] OllamaChatRole Role,
    [property: JsonPropertyName("content")] string Content);

public sealed record OllamaChatOptions(
    [property: JsonPropertyName("temperature")] double? Temperature = null,
    [property: JsonPropertyName("num_ctx")] int? NumCtx = null);

public sealed record OllamaChatRequest(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("messages")] IReadOnlyList<OllamaChatMessage> Messages,
    [property: JsonPropertyName("stream")] bool Stream = true,
    [property: JsonPropertyName("options")] OllamaChatOptions? Options = null);

public sealed record OllamaChatChunk(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("created_at")] string CreatedAt,
    [property: JsonPropertyName("message")] OllamaChatMessage Message,
    [property: JsonPropertyName("done")] bool Done);

public sealed record OllamaEmbedRequest(
    [property: JsonPropertyName("model")] string Model,
    [property: JsonPropertyName("input")] IReadOnlyList<string> Input);

public sealed record OllamaEmbedResponse(
    [property: JsonPropertyName("embeddings")] double[][] Embeddings);

public sealed record OllamaModelDetails(
    [property: JsonPropertyName("format")] string? Format = null,
    [property: JsonPropertyName("family")] string? Family = null,
    [property: JsonPropertyName("parameter_size")] string? ParameterSize = null,
    [property: JsonPropertyName("quantization_level")] string? QuantizationLevel = null);

public sealed record OllamaModel(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("modified_at")] string ModifiedAt,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("digest")] string Digest,
    [property: JsonPropertyName("details")] OllamaModelDetails Details);

public sealed record OllamaModelList(
    [property: JsonPropertyName("models")] IReadOnlyList<OllamaModel> Models);

public sealed record OllamaPullEvent(
    [property: JsonPropertyName("status")] string Status,
    [property: JsonPropertyName("digest")] string? Digest = null,
    [property: JsonPropertyName("total")] long? Total = null,
    [property: JsonPropertyName("completed")] long? Completed = null)
{
    // Client-side derived progress; null unless total>0 and both present.
    [JsonIgnore]
    public double? FractionComplete =>
        Total is { } t && Completed is { } c && t > 0 ? (double)c / t : null;

    [JsonIgnore]
    public bool IsTerminalSuccess => Status == "success";
}
