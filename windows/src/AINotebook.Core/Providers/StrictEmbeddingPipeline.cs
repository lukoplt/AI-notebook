using AINotebook.Core.Rag;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Providers;

/// <summary>One strict <c>/api/embed</c> response: exactly one native-dimension vector plus optional counts.</summary>
public sealed record StrictEmbeddingResult(float[] Vector, int? PromptTokens, long? TotalDurationNs, long? LoadDurationNs);

public interface IStrictEmbeddingTransport
{
    Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default);
}

/// <summary>Exact documented-tokenizer count (offline fallback when a provider omits its count).</summary>
public interface IExactTokenCounter
{
    Task<int> CountAsync(string text, string tokenizerId, CancellationToken ct = default);
}

/// <summary>The single typed server-length rejection (HTTP 400, exact Ollama error text).</summary>
public sealed class EmbeddingInputTooLongException() : Exception("inputTooLong");

public sealed record EmbeddedPart(int Start, int End, int Tokens);

public sealed record EmbeddedInput(float[] Vector, IReadOnlyList<EmbeddedPart> Parts, int SuccessfulTokens, int RejectedRequests);

/// <summary>Captured profile discovery: the full modern identity plus its immutable session.</summary>
public sealed record PreparedEmbeddingProfile(GenerationIdentity Identity, ProviderEmbeddingSession Session);

/// <summary><c>Kind</c> is request, response, lengthRejected or partAccepted (benchmark-v1 §3).</summary>
public sealed record EmbeddingTelemetryEvent(string Kind, EmbeddingPurpose Purpose, int? Tokens = null, int? Start = null, int? End = null)
{
    public const string Request = "request";
    public const string Response = "response";
    public const string LengthRejected = "lengthRejected";
    public const string PartAccepted = "partAccepted";
}

/// <summary>Nonthrowing by contract: an observer failure can never drop embedding work.</summary>
public interface IEmbeddingTelemetryObserver
{
    ValueTask RecordAsync(EmbeddingTelemetryEvent observation);
}

/// <summary>Telemetry for one purpose, reduced from the ordered event stream (benchmark-v1 §3).</summary>
public sealed record EmbeddingTelemetrySnapshot(long? ServiceTokens, long SuccessfulTokens, int RequestCount,
    int RejectedRequests, int SplitParts, int UncountedRequests, string ServiceTokenStatus)
{
    public static EmbeddingTelemetrySnapshot FromEvents(IEnumerable<EmbeddingTelemetryEvent> events, EmbeddingPurpose purpose)
    {
        ArgumentNullException.ThrowIfNull(events);
        int requests = 0, rejected = 0, parts = 0, counted = 0;
        long successful = 0, service = 0;
        foreach (var e in events)
        {
            if (e.Purpose != purpose) continue;
            switch (e.Kind)
            {
                case EmbeddingTelemetryEvent.Request: requests = checked(requests + 1); break;
                case EmbeddingTelemetryEvent.LengthRejected: rejected = checked(rejected + 1); break;
                case EmbeddingTelemetryEvent.Response when e.Tokens is int tokens:
                    counted = checked(counted + 1);
                    service = checked(service + tokens);
                    break;
                case EmbeddingTelemetryEvent.PartAccepted:
                    parts = checked(parts + 1);
                    successful = checked(successful + (e.Tokens ?? throw new EmbeddingProfileException("invalidTokenCount")));
                    break;
            }
        }
        int uncounted = requests - counted;
        if (uncounted < 0) throw new EmbeddingProfileException("invalidSamples");
        string status = uncounted == 0 ? "measured" : counted > 0 ? "partial" : "not_available";
        return new(uncounted == 0 ? service : null, successful, requests, rejected, parts, uncounted, status);
    }
}

/// <summary>
/// Complete-input embedding (benchmark-v1 §3): format once per part, strict request, typed length
/// rejection or an over-limit exact count bisects by scalars, accepted leaves pool once.
/// </summary>
public sealed class StrictEmbeddingPipeline(IStrictEmbeddingTransport transport, IExactTokenCounter? counter = null,
    IEmbeddingTelemetryObserver? observer = null)
{
    private readonly IStrictEmbeddingTransport _transport = transport ?? throw new ArgumentNullException(nameof(transport));

    public async Task<EmbeddedInput> EmbedAsync(string text, EmbeddingProfile profile, EmbeddingPurpose purpose,
        int effectiveLimit, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(profile);
        EmbeddingInput.RequireValidText(text);
        if (text.Length == 0) throw new EmbeddingProfileException("emptyInput");
        if (effectiveLimit < 1 || effectiveLimit > profile.MaxInputTokens)
            throw new EmbeddingProfileException("invalidEffectiveLimit");

        var leaves = new List<(float[] Vector, EmbeddedPart Part)>();
        int rejected = 0;

        async Task Visit(string raw, int start)
        {
            ct.ThrowIfCancellationRequested();
            string formatted = profile.Format(raw, purpose);
            await Record(new(EmbeddingTelemetryEvent.Request, purpose)).ConfigureAwait(false);
            StrictEmbeddingResult? response;
            try
            {
                response = await _transport.EmbedAsync(profile.Model, formatted, profile.NativeDims, effectiveLimit, ct)
                    .ConfigureAwait(false);
            }
            catch (EmbeddingInputTooLongException)
            {
                rejected++;
                await Record(new(EmbeddingTelemetryEvent.LengthRejected, purpose)).ConfigureAwait(false);
                response = null;
            }
            if (response is not null)
            {
                var vector = EmbeddingInput.Project(response.Vector, profile.NativeDims, profile.Dims);
                if (response.PromptTokens < 0) throw new EmbeddingProfileException("invalidTokenCount");
                await Record(new(EmbeddingTelemetryEvent.Response, purpose, response.PromptTokens)).ConfigureAwait(false);
                int count = response.PromptTokens
                    ?? (counter is not null
                        ? await counter.CountAsync(formatted, profile.TokenizerId, ct).ConfigureAwait(false)
                        : throw new EmbeddingProfileException("tokenCountUnavailable"));
                if (count < 0) throw new EmbeddingProfileException("invalidTokenCount");
                if (count <= effectiveLimit)
                {
                    var part = new EmbeddedPart(start, start + EmbeddingInput.ScalarCount(raw), count);
                    leaves.Add((vector, part));
                    await Record(new(EmbeddingTelemetryEvent.PartAccepted, purpose, count, part.Start, part.End)).ConfigureAwait(false);
                    return;
                }
                // A successful response above the profile ceiling: its service tokens were recorded,
                // but the whole input is split and contributes no useful leaf tokens.
            }
            var (left, right) = EmbeddingInput.Bisect(raw);
            await Visit(left, start).ConfigureAwait(false);
            await Visit(right, start + EmbeddingInput.ScalarCount(left)).ConfigureAwait(false);
        }

        await Visit(text, 0).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var pooled = EmbeddingInput.Pool(leaves.Select(x => x.Vector).ToArray(),
            leaves.Select(x => x.Part.End - x.Part.Start).ToArray());
        return new EmbeddedInput(pooled, leaves.Select(x => x.Part).ToArray(),
            checked(leaves.Sum(x => x.Part.Tokens)), rejected);
    }

    private async ValueTask Record(EmbeddingTelemetryEvent e)
    {
        if (observer is null) return;
        try { await observer.RecordAsync(e).ConfigureAwait(false); }
        catch (Exception) { /* Observers are nonthrowing by contract; a faulty one never drops work. */ }
    }
}
