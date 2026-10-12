using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Providers.Routing;

/// <summary>Captures provider state before awaiting metadata or sending data.</summary>
public sealed class ProviderRouter : IChatStreaming, IEmbeddingProducing, IChatSessionPreparing, IEmbeddingSessionPreparing
{
    private readonly NotebookStore _store;
    private readonly Func<(string ProviderId, string Model)> _chatSelection;
    private readonly Func<(string ProviderId, string Model)> _embeddingSelection;
    private readonly Func<string, string?> _loadSecret;
    private readonly HttpClient _http;
    private readonly object _cacheGate = new();
    private readonly Dictionary<CacheKey, Adapters> _adapters = new();
    private readonly record struct CacheKey(string Id, ProviderType Type, string Root, string Fingerprint);
    private sealed record Adapters(IChatStreaming Chat, IEmbeddingProducing? Embedding);
    // Deliberately not a positional record: diagnostic ToString must never expose credentials.
    private sealed class Target(ProviderConfig config, string model, string? key, ProviderModelLimits? limits)
    {
        public ProviderConfig Config { get; } = config;
        public string Model { get; } = model;
        public string? Key { get; } = key;
        public ProviderModelLimits? Limits { get; } = limits;
    }

    public ProviderRouter(NotebookStore store, Func<(string ProviderId, string Model)> chatSelection,
        Func<(string ProviderId, string Model)> embeddingSelection, Func<string, string?> loadSecret, HttpClient http)
    {
        _store = store;
        _chatSelection = chatSelection;
        _embeddingSelection = embeddingSelection;
        _loadSecret = loadSecret;
        _http = http;
    }

    public async Task<ProviderChatSession> PrepareChatAsync(string? model = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Target target;
        lock (_store.Gate)
        {
            var selection = _chatSelection();
            if (model is not null)
                selection = QualifiedChatModel(model) ?? (selection.ProviderId, model);
            target = Capture(selection.ProviderId, selection.Model);
        }
        var adapter = Adapter(target).Chat;
        var limits = await ResolveCapturedLimitsAsync(target, false, ct).ConfigureAwait(false);
        return new(target.Config.Id, target.Model, limits, adapter);
    }

    public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        var session = await PrepareChatAsync(QualifiedChatModel(model) is null ? null : model, ct).ConfigureAwait(false);
        await foreach (var token in session.StreamAsync(messages, ct).ConfigureAwait(false)) yield return token;
    }

    public async IAsyncEnumerable<string> StreamAsync(string model, IReadOnlyList<ChatTurn> messages,
        ChatRequestOptions options, [EnumeratorCancellation] CancellationToken ct = default)
    {
        options.Validate();
        var session = (await PrepareChatAsync(QualifiedChatModel(model) is null ? null : model, ct).ConfigureAwait(false)).WithOptions(options);
        await foreach (var token in session.StreamAsync(messages, ct).ConfigureAwait(false)) yield return token;
    }

    public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Target target;
        lock (_store.Gate)
        {
            var selection = Split(model) ?? _embeddingSelection();
            target = Capture(selection.ProviderId, selection.Model);
        }
        if (!target.Config.Type.SupportsEmbeddings()) throw new ProviderConfigurationException("unsupportedEndpoint");
        return Adapter(target).Embedding!.EmbedAsync(target.Model, inputs, ct);
    }

    /// <summary>
    /// Captures a generation-bound embedding session. Config, credential, normalized
    /// root and adapter are read once under the store gate; nothing is sent here.
    /// Legacy identities keep their whole stored model key: a registered provider-id
    /// prefix is split at the first colon; a UUID or provider-type prefix with no such
    /// provider names a removed provider and is never guessed; any other key (a bare
    /// model or a bare tag like <c>nomic-embed-text:latest</c>) is, whole, a model of
    /// the selected embedding provider captured now.
    /// </summary>
    public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(identity);
        ct.ThrowIfCancellationRequested();
        if (identity.QueryFormatVersion.StartsWith(EmbeddingQueryFormat.ProfilePrefix, StringComparison.Ordinal))
            return ResumeEmbeddingProfileAsync(identity, ct);
        if (!EmbeddingQueryFormat.IsSupported(identity.QueryFormatVersion))
            throw new RetrievalException("unsupportedQueryFormat");
        bool legacy = EmbeddingQueryFormat.IsLegacyIdentity(identity);
        Target target;
        lock (_store.Gate)
        {
            if (legacy)
            {
                var selection = LegacyEmbeddingTarget(identity.Model);
                target = Capture(selection.ProviderId, selection.Model);
            }
            else target = Capture(identity.ProviderId, identity.Model);
        }
        if (!target.Config.Type.SupportsEmbeddings()) throw new ProviderConfigurationException("unsupportedEndpoint");
        string endpoint = EmbeddingEndpointRevision.Make(target.Config.Type, target.Config.BaseUrl);
        // Never send a query to a different endpoint just to find out whether it works.
        if (!legacy && !string.Equals(endpoint, identity.EndpointRevision, StringComparison.Ordinal))
            throw new RetrievalException("endpointRevisionMismatch");
        var adapter = Adapter(target).Embedding!;
        return Task.FromResult(legacy
            ? new ProviderEmbeddingSession(adapter, target.Model, identity.Model, identity.EndpointRevision,
                ProviderEmbeddingSession.LegacyEndpointUnverified, rawFormat: identity.QueryFormatVersion)
            : new ProviderEmbeddingSession(adapter, target.Model, target.Config.Id + ":" + target.Model, endpoint,
                identity: identity, rawFormat: identity.QueryFormatVersion));
    }

    /// <summary>
    /// WP7 named-profile discovery (benchmark-v1 §3 <c>prepare</c>). Provider config and root are
    /// snapshotted once under the store gate; <c>/api/tags</c>, <c>/api/show</c> and every later
    /// embed use that captured root, whatever Settings does meanwhile.
    /// </summary>
    public async Task<PreparedEmbeddingProfile> PrepareEmbeddingProfileAsync(string providerId, string profileId,
        IEmbeddingTelemetryObserver? observer = null, IExactTokenCounter? counter = null, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var profile = EmbeddingProfiles.Require(profileId);
        EmbeddingProviderSnapshot snapshot;
        lock (_store.Gate) snapshot = ProfileSnapshot(providerId);
        var captured = await EmbeddingProfileCapture.CaptureAsync(snapshot, profile, _http, ct).ConfigureAwait(false);
        var session = new ProviderEmbeddingSession(snapshot.ProviderId + ":" + profile.Model, captured.Identity.EndpointRevision,
            captured.Identity, profile, new StrictEmbeddingPipeline(captured.Client, counter, observer), captured.EffectiveLimit,
            captured.Client);
        return new PreparedEmbeddingProfile(captured.Identity, session);
    }

    /// <summary>
    /// Opens a stored WP7 identity (benchmark-v1 §3 <c>resume</c>): validates profile agreement and the
    /// endpoint before any request, re-reads only <c>/api/tags</c> to prove the recorded digest, and keeps
    /// the stored ctx suffix — never re-probes the context.
    /// </summary>
    private async Task<ProviderEmbeddingSession> ResumeEmbeddingProfileAsync(GenerationIdentity identity, CancellationToken ct)
    {
        var profile = EmbeddingQueryFormat.Profile(identity.QueryFormatVersion)
            ?? throw new RetrievalException("unsupportedQueryFormat");
        int limit = profile.ValidateIdentity(identity.Model, identity.Dims, identity.QueryFormatVersion, identity.DocFormatVersion);
        if (identity.Normalization != "l2" || identity.ChunkerVersion != "2")
            throw new EmbeddingProfileException("profileIdentityMismatch");
        if (EmbeddingProfileCapture.NormalizeDigest(identity.ModelDigest) is null)
            throw new EmbeddingProfileException("embeddingModelChanged");
        EmbeddingProviderSnapshot snapshot;
        lock (_store.Gate) snapshot = ProfileSnapshot(identity.ProviderId);
        if (snapshot.Type != ProviderType.Ollama || !snapshot.Enabled || !snapshot.Consented || !snapshot.EmbeddingCapable)
            throw new EmbeddingProfileException("unsupportedEmbeddingProfile");
        if (!string.Equals(EmbeddingEndpointRevision.Make(snapshot.Type, snapshot.Root), identity.EndpointRevision, StringComparison.Ordinal))
            throw new RetrievalException("endpointRevisionMismatch");
        var client = new OllamaBenchmarkClient(new Uri(snapshot.Root), _http);
        await EmbeddingProfileCapture.VerifyDigestAsync(client, identity, ct).ConfigureAwait(false);
        return new ProviderEmbeddingSession(identity.ProviderId + ":" + identity.Model, identity.EndpointRevision, identity,
            profile, new StrictEmbeddingPipeline(client), limit, client);
    }

    /// <summary>Caller holds <c>_store.Gate</c>.</summary>
    private EmbeddingProviderSnapshot ProfileSnapshot(string providerId)
    {
        var config = _store.Provider(providerId) ?? throw new ProviderConfigurationException("missingProvider");
        return new(config.Id, config.Type, ProviderApiRoot.Normalize(config.BaseUrl), config.Enabled,
            !config.IsCloud || config.PrivacyAcknowledged, config.Type.SupportsEmbeddings());
    }

    public Task<IReadOnlyList<ProviderModelInfo>> DiscoverModelsAsync(string providerId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Target target;
        lock (_store.Gate) target = Capture(providerId, "discovery");
        return DiscoverAndRecordAsync(target, ct);
    }

    /// <summary>provider-listing-limits-v1: advertised windows become automatic limits (never over a user choice,
    /// and only while the endpoint that answered is still the configured one).</summary>
    private async Task<IReadOnlyList<ProviderModelInfo>> DiscoverAndRecordAsync(Target target, CancellationToken ct)
    {
        var models = await ProviderDiscovery.DiscoverAsync(_http, target.Config.Type, target.Config.BaseUrl, target.Key, ct)
            .ConfigureAwait(false);
        var listed = models.Where(m => m.ContextWindow is not null).ToArray();
        if (!ProviderLimitPolicy.ListingTypes.Contains(target.Config.Type) || listed.Length == 0) return models;
        lock (_store.Gate)
        {
            var current = _store.Provider(target.Config.Id);
            if (current is null || !ProviderLimitPolicy.HasSameEndpoint(target.Config, current)) return models;
            foreach (var model in listed)
            {
                ProviderModelLimits limits;
                try { limits = ProviderLimitPolicy.Automatic(target.Config.Id, target.Config.Type, model.Id, model.ContextWindow, listed: true); }
                catch (ProviderConfigurationException) { continue; }
                _store.SaveProviderModelLimits(limits);
            }
        }
        return models;
    }

    public Task<ProviderProbeResult> ProbeAsync(ProviderType type, string baseUrl, string? apiKey, CancellationToken ct = default) =>
        ProviderDiscovery.ProbeAsync(_http, type, baseUrl, apiKey, ct);

    public Task<ProviderModelLimits> ResolveLimitsAsync(string providerId, string model, bool refresh = false, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        Target target;
        lock (_store.Gate) target = Capture(providerId, model);
        return ResolveCapturedLimitsAsync(target, refresh, ct);
    }

    private Target Capture(string providerId, string model)
    {
        var config = _store.Provider(providerId) ?? throw new ProviderConfigurationException("missingProvider");
        if (!config.Enabled) throw new ProviderConfigurationException("disabledProvider");
        config = config with { BaseUrl = ProviderApiRoot.Normalize(config.BaseUrl) };
        if (config.IsCloud && !config.PrivacyAcknowledged)
            throw new ProviderConsentException("Confirm data sharing in Settings.");
        if (string.IsNullOrWhiteSpace(model)) throw new ProviderConfigurationException("invalidLimits");
        return new(config, model, config.Type == ProviderType.Ollama ? null : _loadSecret(providerId), _store.ProviderModelLimits(providerId, model));
    }

    private async Task<ProviderModelLimits> ResolveCapturedLimitsAsync(Target target, bool refresh, CancellationToken ct)
    {
        if (target.Limits is { } saved && (saved.Source == "user" || !refresh)) return saved;
        int? window = null;
        bool listed = false;
        if (refresh && ProviderLimitPolicy.ListingTypes.Contains(target.Config.Type))
        {
            // provider-listing-limits-v1: an explicit refresh reads the model listing; any failure other than
            // cancellation leaves the window unknown.
            try
            {
                var json = await OpenAIStyleWire.ListingJsonAsync(_http, target.Config.BaseUrl,
                    target.Config.Type == ProviderType.OpenWebUI ? ProviderType.OpenWebUI : ProviderType.OpenAICompatible,
                    target.Key, ct).ConfigureAwait(false);
                window = ProviderLimitPolicy.ContextWindowFromModelListing(json, target.Model);
                listed = window is not null;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception) { window = null; }
        }
        else if (target.Config.Type == ProviderType.Ollama)
        {
            try
            {
                var json = await new OllamaClient(_http, new Uri(target.Config.BaseUrl)).ShowAsync(target.Model, ct).ConfigureAwait(false);
                window = ProviderLimitPolicy.ContextWindowFromOllamaShow(json);
            }
            catch (OllamaException.HttpStatus ex) when (ex.Code is 404 or 405 or 501) { }
        }
        ct.ThrowIfCancellationRequested();
        var limits = ProviderLimitPolicy.Automatic(target.Config.Id, target.Config.Type, target.Model, window, listed);
        lock (_store.Gate)
        {
            // A concurrent explicit override remains authoritative across endpoint edits.
            var currentLimits = _store.ProviderModelLimits(target.Config.Id, target.Model);
            if (currentLimits?.Source == "user") return currentLimits;
            var current = _store.Provider(target.Config.Id);
            if (current is null || !ProviderLimitPolicy.HasSameEndpoint(target.Config, current))
                return limits; // Keep the captured session, without caching stale metadata.
            _store.SaveProviderModelLimits(limits);
            return _store.ProviderModelLimits(target.Config.Id, target.Model)!;
        }
    }

    private Adapters Adapter(Target target)
    {
        var cfg = target.Config;
        var fingerprint = target.Key is null ? "absent" : Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(target.Key))).ToLowerInvariant();
        var key = new CacheKey(cfg.Id, cfg.Type, cfg.BaseUrl, fingerprint);
        lock (_cacheGate)
        {
            if (_adapters.TryGetValue(key, out var cached)) return cached;
            var ollama = cfg.Type == ProviderType.Ollama ? new OllamaClient(_http, new Uri(cfg.BaseUrl)) : null;
            IChatStreaming chat = cfg.Type switch
            {
                ProviderType.Ollama => new OllamaChatAdapter(ollama!),
                ProviderType.Anthropic => new AnthropicChatAdapter(_http, cfg.BaseUrl, target.Key ?? ""),
                ProviderType.OpenWebUI => new OpenWebUIChatAdapter(_http, cfg.BaseUrl, target.Key),
                _ => new OpenAIChatAdapter(_http, cfg.BaseUrl, target.Key)
            };
            IEmbeddingProducing? embedding = ProviderEmbeddingSession.RawAdapter(cfg.Type, cfg.BaseUrl, target.Key, _http, ollama);
            // Sessions keep their adapters alive; evicting the cache never disposes them.
            foreach (var stale in _adapters.Keys.Where(k => k.Id == cfg.Id).ToArray()) _adapters.Remove(stale);
            return _adapters[key] = new(chat, embedding);
        }
    }

    private (string ProviderId, string Model)? QualifiedChatModel(string model)
    {
        var split = Split(model);
        return split is { } value && (_store.Provider(value.ProviderId) is not null || Guid.TryParse(value.ProviderId, out _)) ? split : null;
    }

    /// <summary>Caller holds <c>_store.Gate</c>.</summary>
    private (string ProviderId, string Model) LegacyEmbeddingTarget(string storedKey)
    {
        if (Split(storedKey) is { } qualified)
        {
            if (_store.Provider(qualified.ProviderId) is not null) return qualified;
            if (Guid.TryParseExact(qualified.ProviderId, "D", out _) || IsProviderType(qualified.ProviderId))
                throw new RetrievalException("legacyProviderUnresolved");
        }
        return (_embeddingSelection().ProviderId, storedKey);
    }

    private static bool IsProviderType(string value) =>
        Enum.GetValues<ProviderType>().Any(type => string.Equals(type.ToStorageString(), value, StringComparison.Ordinal));

    private static (string ProviderId, string Model)? Split(string model)
    {
        var colon = model.IndexOf(':');
        return colon > 0 ? (model[..colon], model[(colon + 1)..]) : null;
    }
}
