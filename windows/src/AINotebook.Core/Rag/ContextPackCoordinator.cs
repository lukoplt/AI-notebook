using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Models;

namespace AINotebook.Core.Rag;

// MARK: - WP8 ports

/// <summary>One retrieval identity from the pinned candidate pool, in fused order.</summary>
public sealed record PackHit(long ChunkId, long SourceId, long RevisionId, long RrfMicro);

/// <summary>
/// A pinned read: owns scope/revision/generation leases plus the materialized scope,
/// coverage and history input. Disposal releases every lease (the plan's <c>finish</c>).
/// </summary>
public interface IPackReadSession : IAsyncDisposable
{
    ContextPackInput Input { get; }
    Task<PackHit[]> SearchAsync(string question, int fetchK, CancellationToken ct);
    Task<PackPassage[]> HydrateAsync(PackHit[] hits, CancellationToken ct);
    Task<PackPassage[]> OverviewAsync(CancellationToken ct);
    Task<PackPassage[]> NeighboursAsync(PackPassage[] passages, CancellationToken ct);
}

public interface IPackDataSource
{
    Task<IPackReadSession> PinAsync(PackIntent intent, PackModel model, CancellationToken ct);
}

/// <summary>A frozen provider endpoint/model/options. No credentials are observable.</summary>
public interface IPreparedPackTransport
{
    PackModel Model { get; }

    /// <summary>
    /// WP8 addition (Swift parity): the model key persisted on the assistant row,
    /// e.g. <c>providerId:model</c> for router sessions. Defaults to the raw model.
    /// </summary>
    string StorageModel => Model.Model;

    IAsyncEnumerable<string> StreamAsync(PreparedContextRequest request, CancellationToken ct);
}

/// <summary>The live selection's identity and limits, resolved without freezing.</summary>
public sealed record PackTransportDescription(PackModel Model, long ConfigurationRevision);

public interface IPackTransportFactory
{
    Task<IPreparedPackTransport> FreezeAsync(PackIntent intent, CancellationToken ct);

    /// <summary>
    /// WP8 addition (Swift parity): lets an intent be captured, and its key derived, from the
    /// live selection before anything is frozen. <paramref name="requestedModel"/> uses the
    /// router's existing raw/provider-qualified override semantics.
    /// </summary>
    Task<PackTransportDescription> DescribeAsync(string? requestedModel, CancellationToken ct);
}

/// <summary>
/// Everything a turn depends on, captured before preparation. <see cref="PackIntentKey"/>
/// lets the UI detect any change since a preview was built.
/// </summary>
public sealed record PackIntent(long NotebookId, long SessionId, string Question, string Mode,
    RetrievalScope Scope, string ProviderId, string Model, long ProviderConfigurationRevision,
    int RuntimeContext, int MaxOutputTokens, int? EvidenceBudgetCap, int FetchK, int TopK,
    string NotebookInstructions, string? InstructionsOverride, string? CurrentNoteContent,
    bool UseWebSearch, string HistoryFingerprint, string ScopeFingerprint,
    long? RegenerateUserId, long? ReplacesAssistantId,
    // WP8 addition (Swift parity): an edit-and-resend rewrites RegenerateUserId's text with
    // Question in the commit transaction; a plain regenerate never does.
    bool EditUserText = false)
{
    /// <summary>Existing precedence: a nonblank persona override replaces the notebook's instructions.</summary>
    public string EffectiveInstructions =>
        InstructionsOverride is { } value && !ContextPackRendering.IsBlank(value) ? value : NotebookInstructions;
}

public static class PackIntentKey
{
    /// <summary>
    /// SHA-256 of the canonical intent JSON (scalar-sorted keys, explicit nulls, sorted
    /// scope IDs). <c>editUserText</c> appears only when true, so ordinary intents hash
    /// exactly like the shared reference intent. The preimage is not retained.
    /// </summary>
    public static byte[] Make(PackIntent intent)
    {
        ArgumentNullException.ThrowIfNull(intent);
        var (kind, sources, folders) = ScopeParts(intent.Scope);
        var node = new JsonObject
        {
            ["notebookId"] = intent.NotebookId,
            ["sessionId"] = intent.SessionId,
            ["question"] = intent.Question,
            ["mode"] = intent.Mode,
            ["scope"] = new JsonObject
            {
                ["kind"] = kind,
                ["sourceIds"] = new JsonArray(sources.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()),
                ["folderIds"] = new JsonArray(folders.Select(id => (JsonNode)JsonValue.Create(id)).ToArray()),
            },
            ["providerId"] = intent.ProviderId,
            ["model"] = intent.Model,
            ["providerConfigurationRevision"] = intent.ProviderConfigurationRevision,
            ["runtimeContext"] = intent.RuntimeContext,
            ["maxOutputTokens"] = intent.MaxOutputTokens,
            ["evidenceBudgetCap"] = intent.EvidenceBudgetCap,
            ["fetchK"] = intent.FetchK,
            ["topK"] = intent.TopK,
            ["notebookInstructions"] = intent.NotebookInstructions,
            ["instructionsOverride"] = intent.InstructionsOverride,
            ["currentNoteContent"] = intent.CurrentNoteContent,
            ["useWebSearch"] = intent.UseWebSearch,
            ["historyFingerprint"] = intent.HistoryFingerprint,
            ["scopeFingerprint"] = intent.ScopeFingerprint,
            ["regenerateUserId"] = intent.RegenerateUserId,
            ["replacesAssistantId"] = intent.ReplacesAssistantId,
        };
        if (intent.EditUserText) node["editUserText"] = true;
        return SHA256.HashData(PreparedContextRequestJson.CanonicalBytes(JsonSerializer.SerializeToElement(node)));
    }

    internal static (string Kind, long[] SourceIds, long[] FolderIds) ScopeParts(RetrievalScope scope) => scope switch
    {
        RetrievalScope.All => ("all", [], []),
        RetrievalScope.Selection s => ("selection", s.SourceIds.Order().ToArray(), s.FolderIds.Order().ToArray()),
        _ => throw new ArgumentException("Unknown retrieval scope.", nameof(scope))
    };
}

/// <summary>The prepared request no longer matches the captured intent, history or scope.</summary>
public sealed class StalePreparedRequestException() : Exception("stalePreparedRequest");

/// <summary>A prepared handle is one-shot; it cannot be streamed twice.</summary>
public sealed class PreparedRequestConsumedException() : Exception("preparedRequestConsumed");

/// <summary>Another turn of this session is already being sent.</summary>
public sealed class ChatSendInProgressException() : Exception("sendInProgress");

/// <summary>Click-time original resolution. Only available/changed decisions carry a path.</summary>
public sealed record ResolvedCitationOriginal
{
    public ResolvedCitationOriginal(CitationOriginalDecision decision, string? path = null, long? noteId = null)
    {
        Decision = decision;
        Path = decision is CitationOriginalDecision.Available or CitationOriginalDecision.Changed ? path : null;
        NoteId = noteId;
    }

    public CitationOriginalDecision Decision { get; }
    /// <summary>The validated native file path; never set for unsafe/unavailable.</summary>
    public string? Path { get; }
    /// <summary>Note citations keep note navigation instead of a file path.</summary>
    public long? NoteId { get; }
}

public interface ICitationOriginalResolver
{
    Task<ResolvedCitationOriginal> ResolveAsync(long notebookId, Citation citation, CancellationToken ct = default);
}

// MARK: - Prepared handle

/// <summary>Opaque and one-shot. Not serializable; its transport owns the frozen provider session.</summary>
public sealed class PreparedPackHandle
{
    private readonly byte[] _key;
    private int _consumed;

    internal PreparedPackHandle(PackIntent intent, byte[] key, PreparedContextRequest request, IPreparedPackTransport transport)
    {
        Intent = intent;
        _key = key.ToArray();
        Request = request;
        Transport = transport;
    }

    public PackIntent Intent { get; }
    public byte[] Key => _key.ToArray();
    public PreparedContextRequest Request { get; }
    public IPreparedPackTransport Transport { get; }
    public bool IsConsumed => Volatile.Read(ref _consumed) != 0;

    /// <summary>The memory-only preview wrapper; providerType comes from the frozen transport.</summary>
    public ContextPreviewSnapshot Snapshot => new(Request, Transport.Model.ProviderType);

    internal bool KeyEquals(byte[]? key) => key is not null && _key.AsSpan().SequenceEqual(key);

    /// <summary>Atomically marks the handle consumed; false when it already was.</summary>
    internal bool TryConsume() => Interlocked.Exchange(ref _consumed, 1) == 0;
}

// MARK: - Coordinator

/// <summary>
/// Pins provider and retrieval state, collects evidence and builds the exact request a
/// later send streams. Preparation never writes chat rows.
/// </summary>
public sealed class ContextPackCoordinator
{
    private readonly Func<ContextPackInput, PreparedContextRequest> _build;

    public ContextPackCoordinator(IPackDataSource data, IPackTransportFactory transports)
        : this(data, transports, null) { }

    /// <summary>Test seam: observes the pure build without changing it.</summary>
    internal ContextPackCoordinator(IPackDataSource data, IPackTransportFactory transports,
        Func<ContextPackInput, PreparedContextRequest>? build)
    {
        Data = data ?? throw new ArgumentNullException(nameof(data));
        Transports = transports ?? throw new ArgumentNullException(nameof(transports));
        _build = build ?? (input => ContextPackBuilder.Build(input));
    }

    public IPackDataSource Data { get; }
    public IPackTransportFactory Transports { get; }

    /// <summary>Same transports and build, different pinned-data source.</summary>
    internal ContextPackCoordinator WithData(IPackDataSource data) => new(data, Transports, _build);

    public Task<PackTransportDescription> DescribeAsync(string? requestedModel, CancellationToken ct = default) =>
        Transports.DescribeAsync(requestedModel, ct);

    public async Task<PreparedPackHandle> PrepareAsync(PackIntent intent, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(intent);
        ct.ThrowIfCancellationRequested();
        var transport = await Transports.FreezeAsync(intent, ct).ConfigureAwait(false);
        await using var read = await Data.PinAsync(intent, transport.Model, ct).ConfigureAwait(false);
        // Retrieval uses only the current question; Overview and an empty selection never embed it.
        PackPassage[] candidates = [], neighbours = [], overview = [];
        if (intent.Scope.IsEmptySelection)
        {
            // Never widen an empty selection.
        }
        else if (intent.Mode == "overview")
            overview = await read.OverviewAsync(ct).ConfigureAwait(false);
        else
        {
            var hits = await read.SearchAsync(intent.Question, intent.FetchK, ct).ConfigureAwait(false);
            candidates = await read.HydrateAsync(hits, ct).ConfigureAwait(false);
            neighbours = await read.NeighboursAsync(candidates, ct).ConfigureAwait(false);
        }
        ct.ThrowIfCancellationRequested();
        // The materialized input is read immediately before the pure build; `with` copies
        // every other field, and the DTO's init setters copy the evidence arrays.
        var input = read.Input;
        input = intent.Scope.IsEmptySelection
            ? input with { Candidates = [], Neighbours = [], OverviewCandidates = [], FolderMap = [] }
            : input with { Candidates = candidates, Neighbours = neighbours, OverviewCandidates = overview };
        var request = _build(input);
        return new PreparedPackHandle(intent, PackIntentKey.Make(intent), request, transport);
    }
}

// MARK: - History

public static class ContextHistory
{
    /// <summary>
    /// Adjacent complete user→assistant exchanges ordered by persisted ID, oldest first.
    /// Trailing unanswered users and the regenerate/edit target pair are excluded; the
    /// turn ID is the user row's ID.
    /// </summary>
    public static PackHistoryTurn[] Turns(IEnumerable<ChatMessage> messages,
        long? excludingUserId = null, long? excludingAssistantId = null)
    {
        var ordered = messages
            .Where(m => m.Id is long id && m.Role != ChatRole.System && id != excludingUserId && id != excludingAssistantId)
            .OrderBy(m => m.Id!.Value).ToArray();
        var turns = new List<PackHistoryTurn>();
        int index = 0;
        while (index + 1 < ordered.Length)
        {
            var user = ordered[index];
            var assistant = ordered[index + 1];
            if (user.Role == ChatRole.User && assistant.Role == ChatRole.Assistant)
            {
                turns.Add(new(user.Id!.Value, user.Content, assistant.Content));
                index += 2;
            }
            else index++;
        }
        return turns.ToArray();
    }
}

// MARK: - Preview wrapper bytes

/// <summary>Memory-only <c>{providerType, request}</c> wrapper, canonical like the prepared request.</summary>
public static class ContextPreviewSnapshotJson
{
    public static byte[] Encode(ContextPreviewSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var node = new JsonObject
        {
            ["providerType"] = snapshot.ProviderType,
            ["request"] = JsonNode.Parse(PreparedContextRequestJson.Encode(snapshot.Request)),
        };
        return PreparedContextRequestJson.CanonicalBytes(JsonSerializer.SerializeToElement(node));
    }

    public static ContextPreviewSnapshot Decode(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        // Validates the whole wrapper (non-finite numbers, malformed escapes) first.
        _ = PreparedContextRequestJson.CanonicalBytes(root);
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("providerType", out var type) || type.ValueKind != JsonValueKind.String
            || !root.TryGetProperty("request", out var request) || request.ValueKind != JsonValueKind.Object)
            throw new JsonException("A preview snapshot requires providerType and request.");
        return new ContextPreviewSnapshot(
            PreparedContextRequestJson.Decode(PreparedContextRequestJson.CanonicalBytes(request)),
            type.GetString()!);
    }
}
