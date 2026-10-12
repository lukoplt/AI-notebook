using System.Text.Json;

namespace AINotebook.Core.Rag;

public sealed class RagTuningException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

/// <summary>
/// Versioned runtime retrieval/packing parameters carried from the benchmark decision
/// (benchmark-v1 §8 <c>tuning</c>). A pending decision is exactly v1 (32/16/6000).
/// </summary>
public sealed record RagRuntimeTuning
{
    public int FetchK { get; }
    public int TopK { get; }
    public int EvidenceShareBp { get; }

    public RagRuntimeTuning(int fetchK, int topK, int evidenceShareBp)
    {
        if (fetchK < topK || topK <= 0 || fetchK > 1024 || evidenceShareBp < 0 || evidenceShareBp > 10000)
            throw new RagTuningException("invalidTuning");
        FetchK = fetchK;
        TopK = topK;
        EvidenceShareBp = evidenceShareBp;
    }

    public static RagRuntimeTuning V1 { get; } =
        new(RagContractV1.Retrieval.FetchK, 16, RagContractV1.Pack.EvidenceShareBp);

    private static readonly Lazy<RagRuntimeTuning> Cached = new(() =>
        DecodeDecision(EmbeddingProfiles.ReadBenchmarkResource("embedding-decision-v1.json")));

    /// <summary>The shipped decision's parameters (no database access).</summary>
    public static RagRuntimeTuning Bundled() => Cached.Value;

    public static RagRuntimeTuning DecodeDecision(ReadOnlySpan<byte> bytes)
    {
        try
        {
            using var document = JsonDocument.Parse(bytes.ToArray());
            var root = document.RootElement;
            string? status = root.GetProperty("status").GetString();
            if (status == "pending") return V1;
            if (status != "accepted") throw new RagTuningException("invalidTuning");
            var p = root.GetProperty("parameters");
            return new(p.GetProperty("fetchK").GetInt32(), p.GetProperty("topK").GetInt32(), p.GetProperty("evidenceShareBp").GetInt32());
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            throw new RagTuningException("invalidTuning");
        }
    }
}
