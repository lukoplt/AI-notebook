using System.Globalization;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

/// <summary>The contract-only, deterministic UTF-8 representation retained by previews.</summary>
public static class PreparedContextRequestJson
{
    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    public static byte[] Encode(PreparedContextRequest request) => CanonicalBytes(Element(request));

    public static JsonElement Element(PreparedContextRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        var options = new Dictionary<string, int>();
        if (request.Options.NumCtx is { } numCtx) options.Add("numCtx", numCtx);
        if (request.Options.MaxTokens is { } maxTokens) options.Add("maxTokens", maxTokens);

        // Citation serialization belongs to the existing v2 codec. Its envelope is
        // a storage concern; prepared requests contain only the ordered items.
        string encodedCitations = CitationsCodec.Encode(request.CitationMap.OrderBy(c => c.Marker).ToArray()) ?? "[]";
        using var citations = JsonDocument.Parse(encodedCitations);
        var items = citations.RootElement.ValueKind == JsonValueKind.Array
            ? citations.RootElement : citations.RootElement.GetProperty("items");

        return JsonSerializer.SerializeToElement(new
        {
            request.EstimatorVersion,
            model = new
            {
                request.Model.ProviderId,
                request.Model.Model,
                request.Model.RuntimeContext,
                request.Model.MaxOutputTokens,
                request.Model.ContextWindowKnown
            },
            request.Messages,
            options,
            citationMap = items,
            request.Included,
            request.Omitted,
            request.Coverage,
            // A missing active generation is an explicit null in the frozen DTO.
            request.GenerationId,
            sourceRevisions = OrderedRevisions(request.SourceRevisions)
        }, Options);
    }

    public static PreparedContextRequest Decode(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        // Validate ignored fields too, including non-finite number tokens and
        // malformed surrogate escapes, before decoding the request projection.
        _ = CanonicalBytes(root);
        var citationItems = root.GetProperty("citationMap");
        if (citationItems.ValueKind != JsonValueKind.Array)
            throw new JsonException("A prepared citation map must be an array.");
        var citations = CitationsCodec.Decode(citationItems.GetRawText()).ToArray();
        if (citations.Length != citationItems.GetArrayLength())
            throw new JsonException("A prepared citation map contains an invalid item.");

        return new PreparedContextRequest(
            root.GetProperty("estimatorVersion").GetInt32(),
            Read<PreparedPackModel>(root, "model"),
            Read<PackMessage[]>(root, "messages"),
            Read<PackOptions>(root, "options"),
            citations.OrderBy(c => c.Marker).ToArray(),
            Read<PackItem[]>(root, "included"),
            Read<PackOmission[]>(root, "omitted"),
            Read<PackCoverage>(root, "coverage"),
            root.GetProperty("generationId").ValueKind == JsonValueKind.Null
                ? null : root.GetProperty("generationId").GetInt64(),
            OrderedRevisions(Read<PackSourceRevision[]>(root, "sourceRevisions")));
    }

    /// <summary>
    /// Compact JSON with scalar-ordered keys, literal UTF-8 Unicode, and only
    /// JSON-required escapes. This also supplies the byte representation for
    /// session sizing and draft-intent hashing.
    /// </summary>
    public static byte[] CanonicalBytes(JsonElement element)
    {
        var output = new StringBuilder();
        Write(element, output);
        return new UTF8Encoding(false, true).GetBytes(output.ToString());
    }

    private static T Read<T>(JsonElement root, string name) =>
        root.GetProperty(name).Deserialize<T>(Options)
        ?? throw new JsonException($"Missing prepared request field: {name}.");

    private static PackSourceRevision[] OrderedRevisions(IEnumerable<PackSourceRevision> revisions) =>
        revisions.Distinct().OrderBy(r => r.SourceId).ThenBy(r => r.RevisionId).ToArray();

    private static void Write(JsonElement element, StringBuilder output)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                output.Append('{');
                bool firstProperty = true;
                foreach (var property in element.EnumerateObject().OrderBy(p => p.Name,
                    Comparer<string>.Create(ContextPackAlgorithms.CompareScalars)))
                {
                    if (!firstProperty) output.Append(',');
                    firstProperty = false;
                    WriteString(property.Name, output);
                    output.Append(':');
                    Write(property.Value, output);
                }
                output.Append('}');
                break;
            case JsonValueKind.Array:
                output.Append('[');
                bool firstItem = true;
                foreach (var item in element.EnumerateArray())
                {
                    if (!firstItem) output.Append(',');
                    firstItem = false;
                    Write(item, output);
                }
                output.Append(']');
                break;
            case JsonValueKind.String:
                WriteString(element.GetString()!, output);
                break;
            case JsonValueKind.Number:
                if (!element.TryGetDouble(out var number) || !double.IsFinite(number))
                    throw new JsonException("JSON numbers must be finite.");
                // Contract numeric fields are integers. Preserve their exact token
                // rather than routing JSON-safe 64-bit IDs through floating point.
                output.Append(element.GetRawText());
                break;
            case JsonValueKind.True:
                output.Append("true");
                break;
            case JsonValueKind.False:
                output.Append("false");
                break;
            case JsonValueKind.Null:
                output.Append("null");
                break;
            default:
                throw new JsonException("Undefined values cannot be written as JSON.");
        }
    }

    private static void WriteString(string value, StringBuilder output)
    {
        output.Append('"');
        foreach (char unit in value)
        {
            switch (unit)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                default:
                    if (unit < 0x20)
                        output.Append("\\u").Append(((int)unit).ToString("x4", CultureInfo.InvariantCulture));
                    else
                        output.Append(unit);
                    break;
            }
        }
        output.Append('"');
    }
}
