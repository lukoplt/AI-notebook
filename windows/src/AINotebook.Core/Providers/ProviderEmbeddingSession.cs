using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Providers;

public interface IEmbeddingSessionPreparing
{
    /// <summary>
    /// Captures provider configuration, credential and adapter once for a pinned
    /// generation identity. Validation (format, consent, capability, endpoint
    /// revision) happens before any request can be constructed.
    /// </summary>
    Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity, CancellationToken ct = default);
}

/// <summary>
/// One immutable embedding target. Later settings edits never reach it. Legacy and "1" identities
/// keep their raw-input client path; a WP7 named profile embeds through the strict complete-input
/// pipeline with the purpose-specific prefix and the frozen effective limit.
/// </summary>
public sealed class ProviderEmbeddingSession
{
    /// <summary>Retrieval diagnostic for legacy generations, which have no provable historical endpoint.</summary>
    public const string LegacyEndpointUnverified = "legacyEndpointUnverified";

    private readonly IEmbeddingProducing? _client;
    private readonly string _model;
    private readonly string _rawFormat = EmbeddingQueryFormat.V1;
    private readonly EmbeddingProfile? _profile;
    private readonly StrictEmbeddingPipeline? _pipeline;
    private readonly OllamaBenchmarkClient? _verifier;

    public string StorageKey { get; }
    public string EndpointRevision { get; }
    /// <summary>Null for a verified modern identity; <see cref="LegacyEndpointUnverified"/> for legacy.</summary>
    public string? Status { get; }
    /// <summary>The full captured modern identity; null for legacy sessions.</summary>
    public GenerationIdentity? Identity { get; }
    /// <summary>The frozen WP7 effective input limit; null outside named profiles.</summary>
    public int? EffectiveLimit { get; }
    public EmbeddingProfile? Profile => _profile;

    /// <param name="rawFormat">The generation's raw format (legacy, 1 or 2; embedding-raw-format-v2).</param>
    internal ProviderEmbeddingSession(IEmbeddingProducing client, string model, string storageKey,
        string endpointRevision, string? status = null, GenerationIdentity? identity = null, string rawFormat = EmbeddingQueryFormat.V1)
    {
        _client = client;
        _model = model;
        _rawFormat = rawFormat;
        StorageKey = storageKey;
        EndpointRevision = endpointRevision;
        Status = status;
        Identity = identity;
    }

    /// <summary>Captured modern WP7 session; <paramref name="pipeline"/> owns the captured strict transport.</summary>
    internal ProviderEmbeddingSession(string storageKey, string endpointRevision, GenerationIdentity identity,
        EmbeddingProfile profile, StrictEmbeddingPipeline pipeline, int effectiveLimit, OllamaBenchmarkClient? verifier = null)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ArgumentNullException.ThrowIfNull(profile);
        ArgumentNullException.ThrowIfNull(pipeline);
        if (effectiveLimit != profile.ValidateIdentity(identity.Model, identity.Dims, identity.QueryFormatVersion, identity.DocFormatVersion))
            throw new EmbeddingProfileException("profileIdentityMismatch");
        _model = identity.Model;
        _profile = profile;
        _pipeline = pipeline;
        _verifier = verifier;
        StorageKey = storageKey;
        EndpointRevision = endpointRevision;
        Identity = identity;
        EffectiveLimit = effectiveLimit;
    }

    /// <summary>Query-purpose embedding (retrieval).</summary>
    public Task<float[][]> EmbedAsync(IReadOnlyList<string> inputs, CancellationToken ct = default)
        => _pipeline is null
            ? _client!.EmbedAsync(_model, inputs.Select(t => RawEmbeddingFormat.Query(t, _model, _rawFormat)).ToArray(), ct)
            : EmbedProfileAsync(inputs, EmbeddingPurpose.Query, ct);

    /// <summary>Document-purpose embedding (ingestion/staging). Legacy formats have no purpose split.</summary>
    public Task<float[][]> EmbedDocumentsAsync(IReadOnlyList<string> inputs, CancellationToken ct = default)
        => _pipeline is null
            ? _client!.EmbedAsync(_model, inputs.Select(t => RawEmbeddingFormat.Document(t, _model, _rawFormat)).ToArray(), ct)
            : EmbedProfileAsync(inputs, EmbeddingPurpose.Document, ct);

    /// <summary>
    /// Re-reads <c>/api/tags</c> on the captured root before a publication: a changed, missing or
    /// removed digest throws <c>embeddingModelChanged</c>. Sessions without a recorded digest are not WP7 sessions.
    /// </summary>
    public Task VerifyModelAsync(CancellationToken ct = default)
    {
        if (_verifier is null || Identity is null || _profile is null) return Task.CompletedTask;
        return EmbeddingProfileCapture.VerifyDigestAsync(_verifier, Identity, ct);
    }

    /// <summary>
    /// The one raw-input adapter mapping, shared by router query sessions and WP6 folder captures.
    /// <paramref name="ollama"/> lets the router reuse its cached client; null for an unsupported type.
    /// </summary>
    internal static IEmbeddingProducing? RawAdapter(ProviderType type, string root, string? apiKey, HttpClient http,
        OllamaClient? ollama = null) => type switch
    {
        ProviderType.Ollama => new OllamaEmbeddingAdapter(ollama ?? new OllamaClient(http, new Uri(root))),
        ProviderType.OpenAI or ProviderType.OpenAICompatible => new OpenAIEmbeddingAdapter(http, root, apiKey),
        _ => null
    };

    /// <summary>
    /// Captures a raw-input (<c>legacy</c>/<c>1</c>) session for an already validated provider configuration:
    /// normalized root, shared endpoint revision and the <c>providerId:model</c> storage key.
    /// </summary>
    internal static ProviderEmbeddingSession CaptureRaw(ProviderConfig config, string model, string? apiKey, HttpClient http,
        string format = EmbeddingQueryFormat.V1)
    {
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(http);
        string root = ProviderApiRoot.Normalize(config.BaseUrl);
        // Validate that the captured root supports embeddings before any request is attempted.
        _ = ProviderApiRoot.Build(config.Type, root, ProviderEndpoint.Embeddings);
        var adapter = RawAdapter(config.Type, root, apiKey, http) ?? throw new ProviderConfigurationException("unsupportedEndpoint");
        return new ProviderEmbeddingSession(adapter, model, config.Id + ":" + model, EmbeddingEndpointRevision.Make(config.Type, root),
            rawFormat: format);
    }

    private async Task<float[][]> EmbedProfileAsync(IReadOnlyList<string> inputs, EmbeddingPurpose purpose, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(inputs);
        var result = new float[inputs.Count][];
        for (int i = 0; i < inputs.Count; i++)
            result[i] = (await _pipeline!.EmbedAsync(inputs[i], _profile!, purpose, EffectiveLimit!.Value, ct).ConfigureAwait(false)).Vector;
        return result;
    }
}

public static class EmbeddingEndpointRevision
{
    /// <summary>
    /// Lowercase hex SHA-256 of UTF-8 (provider type storage value + LF + normalized
    /// API root). Credentials are excluded: key rotation keeps vectors usable, while
    /// a changed root or type does not.
    /// </summary>
    public static string Make(ProviderType type, string normalizedRoot)
    {
        ArgumentNullException.ThrowIfNull(normalizedRoot);
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(type.ToStorageString() + "\n" + normalizedRoot)));
    }
}

/// <summary>Identity input formats implemented by WP5; WP7 adds named model-specific formats.</summary>
public static class EmbeddingQueryFormat
{
    public const string Legacy = "legacy";
    public const string V1 = "1";
    /// <summary>Raw format with task prefixes and a document path header (embedding-raw-format-v2).</summary>
    public const string V2 = "2";
    /// <summary>Prefix of every WP7 named-profile format string (benchmark-v1 §2).</summary>
    public const string ProfilePrefix = "wp7:";

    public static bool IsSupported(string version) => version is Legacy or V1 or V2;

    /// <summary>The catalog profile named by a WP7 format string, or null when it is not one.</summary>
    public static EmbeddingProfile? Profile(string version)
    {
        if (!version.StartsWith(ProfilePrefix, StringComparison.Ordinal)) return null;
        int end = version.IndexOf(':', ProfilePrefix.Length);
        if (end < 0) return null;
        string id = version[ProfilePrefix.Length..end];
        return EmbeddingProfiles.Bundled().FirstOrDefault(p => string.Equals(p.Id, id, StringComparison.Ordinal));
    }

    /// <summary>WP3 marks migrated legacy generations with 'legacy' provider and endpoint identity.</summary>
    public static bool IsLegacyIdentity(GenerationIdentity identity) =>
        identity.ProviderId == "legacy" && identity.EndpointRevision == "legacy";
}
