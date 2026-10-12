using System.Globalization;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Eval;

public sealed record EvalQueryRow(string QueryId, string Text, string Language, string CaseType,
    string Status, int FilesInScope, int CandidatesWithChunks, IReadOnlyList<EvalSpan> Lexical,
    IReadOnlyList<EvalSpan> Vector, IReadOnlyList<EvalSpan> Fused,
    IReadOnlyDictionary<string, EvalMetric> Metrics);

public sealed record EvalCapabilities(string PackedEvidence, string Overview);

public sealed record EvalTiming(long? WarmRetrievalMs, long? EndToEndMs, long? ColdCacheMs);

/// <summary>A deterministic retrieval measurement artifact, independent of providers and the CLI.</summary>
public sealed record EvalReportV1(int SchemaVersion, string CorpusId, string CorpusHash, string Platform,
    string RetrievalVersion, string ChunkerVersion, string Mode, string? Model, int? Dimensions,
    int TopK, int FetchK, int Documents, int QueriesTotal, int OverviewQueries, int AbsentQueries,
    int EmptySelectionQueries, IReadOnlyDictionary<string, EvalMetric> Metrics,
    IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> ByLanguage,
    IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> ByCaseType,
    IReadOnlyList<EvalQueryRow> Queries, EvalCapabilities Capabilities, EvalTiming Timing)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    public static EvalReportV1 Assemble(EvalCorpus corpus, string corpusHash, string platform,
        string mode, string? model, int? dimensions, int topK, int fetchK,
        IReadOnlyList<EvalQueryRow> rows, bool hasPackingHook)
    {
        static IReadOnlyDictionary<string, EvalMetric> Aggregate(IEnumerable<EvalQueryRow> group)
        {
            var groupRows = group.ToArray();
            return EvalMetrics.Names.ToDictionary(name => name,
                name => EvalMetrics.Aggregate(groupRows.Select(row => row.Metrics[name])),
                StringComparer.Ordinal);
        }

        IReadOnlyDictionary<string, IReadOnlyDictionary<string, EvalMetric>> GroupBy(
            Func<EvalQueryRow, string> key)
        {
            var groups = new SortedDictionary<string, IReadOnlyDictionary<string, EvalMetric>>(StringComparer.Ordinal);
            foreach (var group in rows.GroupBy(key, StringComparer.Ordinal))
                groups.Add(group.Key, Aggregate(group));
            return groups;
        }

        return new EvalReportV1(1, corpus.CorpusId, corpusHash, platform,
            "legacy-fts-eval-rrf-v1", "eval-scalars-v1", mode, model, dimensions, topK, fetchK,
            corpus.Documents.Count, rows.Count, rows.Count(row => row.CaseType == "overview"),
            rows.Count(row => row.CaseType == "absent"), rows.Count(row => row.CaseType == "empty_selection"),
            Aggregate(rows), GroupBy(row => row.Language), GroupBy(row => row.CaseType), rows.ToArray(),
            new EvalCapabilities(hasPackingHook ? "measured" : "not_available", "not_available"),
            new EvalTiming(null, null, null));
    }

    /// <summary>UTF-8 without BOM, ordinally sorted object keys, explicit nulls and one final LF.</summary>
    public byte[] JsonBytes()
    {
        var element = JsonSerializer.SerializeToElement(this, JsonOptions);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions
        {
            Indented = true,
            NewLine = "\n",
            Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
        }))
        {
            WriteSorted(writer, element);
        }
        stream.WriteByte((byte)'\n');
        return stream.ToArray();
    }

    private static void WriteSorted(Utf8JsonWriter writer, JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in value.EnumerateObject().OrderBy(p => p.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteSorted(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in value.EnumerateArray()) WriteSorted(writer, item);
                writer.WriteEndArray();
                break;
            default:
                value.WriteTo(writer);
                break;
        }
    }

    public string Markdown()
    {
        static string Number(int? value) => value?.ToString(CultureInfo.InvariantCulture) ?? "—";
        static string Escape(string value) => value.Replace("\\", "\\\\").Replace("|", "\\|")
            .Replace("\r", " ").Replace("\n", " ");

        var lines = new List<string>
        {
            "# Multilingual retrieval eval v1", "",
            $"Corpus: {Escape(CorpusId)} ({Number(Documents)} documents, {Number(QueriesTotal)} queries)",
            $"Backend: {Escape(RetrievalVersion)}; chunker: {Escape(ChunkerVersion)}; mode: {Escape(Mode)}",
            $"topK: {Number(TopK)}; fetchK per branch: {Number(FetchK)}",
            "Recall aggregation: micro (pooled gold evidence items).", "",
            "| metric | found | total | recall bp | status |",
            "|---|---:|---:|---:|---|"
        };
        foreach (var name in EvalMetrics.Names)
        {
            var metric = Metrics[name];
            lines.Add($"| {name} | {Number(metric.Found)} | {Number(metric.Total)} | {Number(metric.RecallBp)} | {Escape(metric.Status)} |");
        }
        lines.Add("");
        lines.Add("| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |");
        lines.Add("|---|---|---|---:|---:|---:|---:|");
        foreach (var row in Queries)
        {
            lines.Add($"| {Escape(row.QueryId)} | {Escape(row.Text)} | {Escape(row.Status)} | " +
                $"{Number(row.Metrics["lexical_recall_at_top_k"].RecallBp)} | " +
                $"{Number(row.Metrics["hybrid_recall_at_top_k"].RecallBp)} | " +
                $"{Number(row.Metrics["candidate_recall_at_fetch_k"].RecallBp)} | " +
                $"{Number(row.Metrics["packed_evidence_recall"].RecallBp)} |");
        }
        lines.Add("");
        lines.Add("Candidate recall uses the full union of the per-branch fetchK lists.");
        lines.Add("Unavailable packing/overview measurements are not scores; WP8 supplies those adapters.");
        return string.Join('\n', lines) + '\n';
    }
}
