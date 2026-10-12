using System.Diagnostics;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Providers;

/// <summary>Prompt/output counts reported by one non-streaming Ollama generation (benchmark-v1 §3).</summary>
public sealed record ChatTokenObservation(string Text, int? PromptTokens, int? OutputTokens);

/// <summary>Observation method labels. No <c>/api/tokenize</c> endpoint exists or is assumed.</summary>
public static class ChatTokenMethods
{
    public const string OllamaRawPrompt = "ollama-raw-prompt";
    public const string OllamaChatPrompt = "ollama-chat-prompt";
    public const string OllamaEmbedPrompt = "ollama-embed-prompt";
    public const string DocumentedTokenizer = "documented-tokenizer";
}

/// <summary>A resolved count with its provenance; tokenizer fields are null for provider-observed counts.</summary>
public sealed record ObservedTokenCount(int Tokens, string Method, string? TokenizerId,
    string? TokenizerRevision, string? TokenizerAssetsSha256);

public static class ChatTokenCounting
{
    /// <summary>
    /// The provider count when present; otherwise the documented offline tokenizer (labelled
    /// <c>documented-tokenizer</c>, never Ollama-exact); otherwise <c>tokenCountUnavailable</c>.
    /// </summary>
    public static async Task<ObservedTokenCount> ResolveAsync(ChatTokenObservation observation, string providerMethod,
        string text, OfflineTokenizerClient? fallback, string? tokenizerId, string requestId, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(observation);
        if (observation.PromptTokens is int tokens) return new(tokens, providerMethod, null, null, null);
        if (fallback is null || tokenizerId is null) throw new EmbeddingProfileException("tokenCountUnavailable");
        var counted = await fallback.CountDetailedAsync(requestId, tokenizerId, text, ct).ConfigureAwait(false);
        return new(counted.Tokens, ChatTokenMethods.DocumentedTokenizer, counted.TokenizerId, counted.Revision, counted.AssetsSha256);
    }
}

/// <summary>
/// Strict benchmark/calibration HTTP for Ollama. The root is normalized and captured once; the
/// raw compatibility client (<see cref="OllamaClient"/>) is untouched.
/// </summary>
public sealed class OllamaBenchmarkClient : IStrictEmbeddingTransport
{
    public const string LengthRejectionError = "the input length exceeds the context length";

    private readonly HttpClient _http;

    public string Root { get; }

    public OllamaBenchmarkClient(Uri baseUrl, HttpClient http)
    {
        ArgumentNullException.ThrowIfNull(baseUrl);
        _http = http ?? throw new ArgumentNullException(nameof(http));
        Root = ProviderApiRoot.Normalize(baseUrl.OriginalString);
    }

    public async Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit,
        CancellationToken ct = default)
    {
        string body = JsonSerializer.Serialize(new
        {
            model,
            input = new[] { input },
            dimensions = nativeDims,
            truncate = false,
            options = new { num_ctx = inputLimit },
        });
        var (status, text) = await SendAsync(HttpMethod.Post, "api/embed", body, ct).ConfigureAwait(false);
        if (status != 200)
        {
            if (status == 400 && IsLengthRejection(text)) throw new EmbeddingInputTooLongException();
            throw new EmbeddingProfileException("providerError", status);
        }
        using var document = Parse(text);
        var root = document.RootElement;
        if (!root.TryGetProperty("embeddings", out var embeddings) || embeddings.ValueKind != JsonValueKind.Array)
            throw new EmbeddingProfileException("invalidResponse");
        if (embeddings.GetArrayLength() != 1) throw new EmbeddingProfileException("invalidEmbedding");
        var row = embeddings[0];
        if (row.ValueKind != JsonValueKind.Array) throw new EmbeddingProfileException("invalidResponse");
        if (row.GetArrayLength() != nativeDims) throw new EmbeddingProfileException("invalidEmbedding");
        var vector = new float[nativeDims];
        int i = 0;
        foreach (var x in row.EnumerateArray())
        {
            if (x.ValueKind != JsonValueKind.Number) throw new EmbeddingProfileException("invalidResponse");
            float value = (float)x.GetDouble();
            if (!float.IsFinite(value)) throw new EmbeddingProfileException("invalidEmbedding");
            vector[i++] = value;
        }
        return new StrictEmbeddingResult(vector, Count(root, "prompt_eval_count"),
            Duration(root, "total_duration"), Duration(root, "load_duration"));
    }

    /// <summary><c>POST /api/generate</c> with a raw prompt (no template), non-streaming, temperature 0.</summary>
    public async Task<ChatTokenObservation> ObserveRawAsync(string model, string text, ChatRequestOptions options,
        CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        string body = JsonSerializer.Serialize(new
        {
            model,
            prompt = text,
            raw = true,
            stream = false,
            options = new { num_ctx = options.RuntimeContext, num_predict = options.MaxOutputTokens, temperature = 0 },
        });
        using var document = await PostForObservationAsync("api/generate", body, ct).ConfigureAwait(false);
        var root = document.RootElement;
        if (!root.TryGetProperty("response", out var response) || response.ValueKind != JsonValueKind.String)
            throw new EmbeddingProfileException("invalidResponse");
        return new(response.GetString()!, Count(root, "prompt_eval_count"), Count(root, "eval_count"));
    }

    /// <summary><c>POST /api/chat</c> with the frozen messages, non-streaming, temperature 0, no raw flag.</summary>
    public async Task<ChatTokenObservation> ObserveChatAsync(string model, IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(messages);
        ArgumentNullException.ThrowIfNull(options);
        options.Validate();
        string body = JsonSerializer.Serialize(new
        {
            model,
            messages = messages.Select(m => new { role = m.Role.RawValue(), content = m.Content }).ToArray(),
            stream = false,
            options = new { num_ctx = options.RuntimeContext, num_predict = options.MaxOutputTokens, temperature = 0 },
        });
        using var document = await PostForObservationAsync("api/chat", body, ct).ConfigureAwait(false);
        var root = document.RootElement;
        if (!root.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object
            || !message.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.String)
            throw new EmbeddingProfileException("invalidResponse");
        return new(content.GetString()!, Count(root, "prompt_eval_count"), Count(root, "eval_count"));
    }

    /// <summary><c>GET /api/tags</c> rows as (name, digest-or-null).</summary>
    public async Task<IReadOnlyList<(string Name, string? Digest)>> TagsAsync(CancellationToken ct = default)
    {
        var (status, text) = await SendAsync(HttpMethod.Get, "api/tags", null, ct).ConfigureAwait(false);
        if (status != 200) throw new EmbeddingProfileException("providerError", status);
        using var document = Parse(text);
        if (!document.RootElement.TryGetProperty("models", out var models) || models.ValueKind != JsonValueKind.Array)
            throw new EmbeddingProfileException("invalidResponse");
        var rows = new List<(string, string?)>();
        foreach (var row in models.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String)
                throw new EmbeddingProfileException("invalidResponse");
            string? digest = row.TryGetProperty("digest", out var d) && d.ValueKind == JsonValueKind.String ? d.GetString() : null;
            rows.Add((name.GetString()!, digest));
        }
        return rows;
    }

    /// <summary><c>POST /api/show</c>; the context limit uses WP2's frozen metadata parser.</summary>
    public async Task<int> ContextLengthAsync(string model, CancellationToken ct = default)
    {
        var (status, text) = await SendAsync(HttpMethod.Post, "api/show", JsonSerializer.Serialize(new { model }), ct).ConfigureAwait(false);
        if (status != 200) throw new EmbeddingProfileException("providerError", status);
        int? window;
        try { window = ProviderLimitPolicy.ContextWindowFromOllamaShow(text); }
        catch (JsonException) { throw new EmbeddingProfileException("modelMetadataUnavailable"); }
        return window ?? throw new EmbeddingProfileException("modelMetadataUnavailable");
    }

    /// <summary>SHA-256 (lowercase hex) of the model's <c>/api/show</c> template, or null when it has none.</summary>
    public async Task<string?> TemplateSha256Async(string model, CancellationToken ct = default)
    {
        var (status, text) = await SendAsync(HttpMethod.Post, "api/show", JsonSerializer.Serialize(new { model }), ct).ConfigureAwait(false);
        if (status != 200) throw new EmbeddingProfileException("providerError", status);
        using var document = Parse(text);
        return document.RootElement.TryGetProperty("template", out var template) && template.ValueKind == JsonValueKind.String
            ? Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(template.GetString()!)))
            : null;
    }

    /// <summary><c>GET /api/version</c>, or null when the server does not report one.</summary>
    public async Task<string?> VersionAsync(CancellationToken ct = default)
    {
        var (status, text) = await SendAsync(HttpMethod.Get, "api/version", null, ct).ConfigureAwait(false);
        if (status != 200) return null;
        using var document = Parse(text);
        return document.RootElement.TryGetProperty("version", out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
    }

    private async Task<JsonDocument> PostForObservationAsync(string path, string body, CancellationToken ct)
    {
        var (status, text) = await SendAsync(HttpMethod.Post, path, body, ct).ConfigureAwait(false);
        if (status != 200) throw new EmbeddingProfileException("providerError", status);
        return Parse(text);
    }

    private async Task<(int Status, string Body)> SendAsync(HttpMethod method, string path, string? body, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        using var request = new HttpRequestMessage(method, ProviderApiRoot.BuildOllama(Root, path));
        if (body is not null) request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        try
        {
            using var response = await _http.SendAsync(request, ct).ConfigureAwait(false);
            string text = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            return ((int)response.StatusCode, text);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception error) when (error is HttpRequestException or OperationCanceledException or IOException)
        {
            // Transport failures and client timeouts are provider errors; never echo provider data.
            throw new EmbeddingProfileException("providerError");
        }
    }

    private static bool IsLengthRejection(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            return document.RootElement.ValueKind == JsonValueKind.Object
                && document.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind == JsonValueKind.String
                && string.Equals(error.GetString(), LengthRejectionError, StringComparison.Ordinal);
        }
        catch (JsonException) { return false; }
    }

    private static JsonDocument Parse(string text)
    {
        JsonDocument document;
        try { document = JsonDocument.Parse(text); }
        catch (JsonException) { throw new EmbeddingProfileException("invalidResponse"); }
        if (document.RootElement.ValueKind != JsonValueKind.Object)
        {
            document.Dispose();
            throw new EmbeddingProfileException("invalidResponse");
        }
        return document;
    }

    /// <summary>Optional count: missing/null → null; negative, fractional or non-number → invalidTokenCount.</summary>
    private static int? Count(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out long n) || n < 0 || n > int.MaxValue)
            throw new EmbeddingProfileException("invalidTokenCount");
        return (int)n;
    }

    private static long? Duration(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out long n) || n < 0)
            throw new EmbeddingProfileException("invalidResponse");
        return n;
    }
}

/// <summary>Immutable provider state captured once for profile discovery.</summary>
public sealed record EmbeddingProviderSnapshot(string ProviderId, ProviderType Type, string Root, bool Enabled,
    bool Consented, bool EmbeddingCapable);

/// <summary>
/// Captured named-profile discovery (benchmark-v1 §3 <c>prepare</c>/<c>resume</c>/<c>publish</c>):
/// exact <c>/api/tags</c> row, normalized digest, <c>/api/show</c> context, frozen effective limit.
/// </summary>
public sealed class EmbeddingProfileCapture
{
    public GenerationIdentity Identity { get; }
    public int EffectiveLimit { get; }
    public EmbeddingProfile Profile { get; }
    public OllamaBenchmarkClient Client { get; }

    private EmbeddingProfileCapture(GenerationIdentity identity, int effectiveLimit, EmbeddingProfile profile, OllamaBenchmarkClient client)
    {
        Identity = identity;
        EffectiveLimit = effectiveLimit;
        Profile = profile;
        Client = client;
    }

    public static async Task<EmbeddingProfileCapture> CaptureAsync(EmbeddingProviderSnapshot provider, EmbeddingProfile profile,
        HttpClient http, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(provider);
        ArgumentNullException.ThrowIfNull(profile);
        if (provider.Type != ProviderType.Ollama || !provider.Enabled || !provider.Consented || !provider.EmbeddingCapable)
            throw new EmbeddingProfileException("unsupportedEmbeddingProfile");
        ct.ThrowIfCancellationRequested();
        var client = new OllamaBenchmarkClient(new Uri(provider.Root), http);
        var digest = ExactDigest(await client.TagsAsync(ct).ConfigureAwait(false), profile.Model)
            ?? throw new EmbeddingProfileException("embeddingModelUnavailable");
        int context = await client.ContextLengthAsync(profile.Model, ct).ConfigureAwait(false);
        int limit = Math.Min(profile.MaxInputTokens, context);
        var identity = new GenerationIdentity(provider.ProviderId, EmbeddingEndpointRevision.Make(provider.Type, client.Root),
            profile.Model, digest, profile.Dims, "l2", profile.FormatVersion(EmbeddingPurpose.Query, limit),
            profile.FormatVersion(EmbeddingPurpose.Document, limit), "2");
        return new(identity, limit, profile, client);
    }

    /// <summary>Re-reads only <c>/api/tags</c>; a changed, missing or removed digest is <c>embeddingModelChanged</c>.</summary>
    public static async Task VerifyDigestAsync(OllamaBenchmarkClient client, GenerationIdentity identity, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentNullException.ThrowIfNull(identity);
        if (NormalizeDigest(identity.ModelDigest) is not { } recorded) throw new EmbeddingProfileException("embeddingModelChanged");
        var current = ExactDigest(await client.TagsAsync(ct).ConfigureAwait(false), identity.Model);
        if (!string.Equals(current, recorded, StringComparison.Ordinal)) throw new EmbeddingProfileException("embeddingModelChanged");
    }

    /// <summary>
    /// Exactly one row named <paramref name="model"/>, or — only for an untagged model — <c>model:latest</c>;
    /// no substring or prefix matching. Returns the normalized digest, or null.
    /// </summary>
    internal static string? ExactDigest(IReadOnlyList<(string Name, string? Digest)> rows, string model)
    {
        bool untagged = !model.Contains(':');
        var matches = rows.Where(r => string.Equals(r.Name, model, StringComparison.Ordinal)
            || (untagged && string.Equals(r.Name, model + ":latest", StringComparison.Ordinal))).ToArray();
        return matches.Length == 1 ? NormalizeDigest(matches[0].Digest) : null;
    }

    /// <summary>64 lowercase hex, or <c>sha256:</c> + 64 lowercase hex → <c>sha256:&lt;hex&gt;</c>; else null.</summary>
    public static string? NormalizeDigest(string? digest)
    {
        if (digest is null) return null;
        string hex = digest.StartsWith("sha256:", StringComparison.Ordinal) ? digest[7..] : digest;
        return hex.Length == 64 && hex.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') ? "sha256:" + hex : null;
    }
}

/// <summary>One newline-JSON exchange with the offline tokenizer helper (benchmark-v1 §7).</summary>
public interface IOfflineTokenizerChannel
{
    Task<string> ExchangeAsync(string requestLine, CancellationToken ct);
}

public sealed record OfflineTokenCount(string RequestId, int Tokens, string TokenizerId, string Revision, string AssetsSha256);

/// <summary>Documented offline tokenizer counts; requests and responses are matched by request ID.</summary>
public sealed class OfflineTokenizerClient(IOfflineTokenizerChannel channel) : IExactTokenCounter
{
    private readonly IOfflineTokenizerChannel _channel = channel ?? throw new ArgumentNullException(nameof(channel));
    private long _next;

    public async Task<int> CountAsync(string text, string tokenizerId, CancellationToken ct = default) =>
        (await CountDetailedAsync("r" + Interlocked.Increment(ref _next).ToString(System.Globalization.CultureInfo.InvariantCulture),
            tokenizerId, text, ct).ConfigureAwait(false)).Tokens;

    public async Task<OfflineTokenCount> CountDetailedAsync(string requestId, string tokenizerId, string text, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrEmpty(requestId);
        ArgumentException.ThrowIfNullOrEmpty(tokenizerId);
        EmbeddingInput.RequireValidText(text);
        string line = JsonSerializer.Serialize(new { requestId, text, tokenizerId });
        string reply = await _channel.ExchangeAsync(line, ct).ConfigureAwait(false);
        try
        {
            using var document = JsonDocument.Parse(reply);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) throw new EmbeddingProfileException("tokenizerUnavailable");
            if (root.TryGetProperty("error", out var error))
                throw new EmbeddingProfileException(error.GetString() is "unknownTokenizer" or "invalidRequest"
                    ? error.GetString()! : "tokenizerUnavailable");
            if (Text(root, "requestId") != requestId || Text(root, "tokenizerId") != tokenizerId
                || Text(root, "revision") is not { Length: > 0 } revision
                || EmbeddingProfileCapture.NormalizeDigest(Text(root, "assetsSha256")) is null
                || Text(root, "assetsSha256")!.StartsWith("sha256:", StringComparison.Ordinal)
                || !root.TryGetProperty("tokens", out var tokens) || tokens.ValueKind != JsonValueKind.Number
                || !tokens.TryGetInt32(out int count) || count < 0)
                throw new EmbeddingProfileException("tokenizerUnavailable");
            return new(requestId, count, tokenizerId, revision, Text(root, "assetsSha256")!);
        }
        catch (JsonException) { throw new EmbeddingProfileException("tokenizerUnavailable"); }
    }

    private static string? Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
}

/// <summary>
/// Runs <c>tools/benchmark/tokenize_offline.py --root DIR</c> with an argument array (no shell),
/// writes requests on stdin and reads one response line each. Text is never logged.
/// </summary>
public sealed class OfflineTokenizerProcess : IOfflineTokenizerChannel, IDisposable
{
    private readonly Process _process;
    private readonly SemaphoreSlim _gate = new(1, 1);

    private OfflineTokenizerProcess(Process process) => _process = process;

    public static OfflineTokenizerProcess Start(string python, string scriptPath, string root)
    {
        var info = new ProcessStartInfo(python)
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = new UTF8Encoding(false),
            StandardErrorEncoding = new UTF8Encoding(false),
            CreateNoWindow = true,
        };
        info.ArgumentList.Add(scriptPath);
        info.ArgumentList.Add("--root");
        info.ArgumentList.Add(root);
        info.Environment["HF_HUB_OFFLINE"] = "1";
        info.Environment["TRANSFORMERS_OFFLINE"] = "1";
        var process = Process.Start(info) ?? throw new EmbeddingProfileException("tokenizerUnavailable");
        return new(process);
    }

    public async Task<string> ExchangeAsync(string requestLine, CancellationToken ct)
    {
        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            using var kill = ct.Register(() => { try { _process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
            try
            {
                await _process.StandardInput.WriteAsync(requestLine + "\n").ConfigureAwait(false);
                await _process.StandardInput.FlushAsync(ct).ConfigureAwait(false);
                string? line = await _process.StandardOutput.ReadLineAsync(ct).ConfigureAwait(false);
                ct.ThrowIfCancellationRequested();
                return line ?? throw new EmbeddingProfileException("tokenizerUnavailable");
            }
            catch (IOException) { ct.ThrowIfCancellationRequested(); throw new EmbeddingProfileException("tokenizerUnavailable"); }
        }
        finally { _gate.Release(); }
    }

    public void Dispose()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.StandardInput.Close();
                if (!_process.WaitForExit(2000)) _process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException) { }
        _process.Dispose();
        _gate.Dispose();
    }
}
