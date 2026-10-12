using System.Text.Json;
using System.Text.Json.Serialization;
using AINotebook.Core.Models;

namespace AINotebook.Core.Storage;

/// <summary>
/// Lossy messages.citations_json reader shared with Swift: legacy arrays or v2
/// envelopes. Invalid items are skipped independently; invalid payloads yield [].
/// Non-finite numbers and unpaired surrogate escapes invalidate the whole payload,
/// including when they appear in unknown fields.
/// </summary>
public static class CitationsCodec
{
    private const long MaxJsonSafeInteger = 9_007_199_254_740_991;
    private static readonly JsonSerializerOptions EncodeOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public static IReadOnlyList<Citation> Decode(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return Array.Empty<Citation>();
        try
        {
            using var document = JsonDocument.Parse(raw);
            ValidatePayload(document.RootElement);
            var items = document.RootElement;
            if (items.ValueKind == JsonValueKind.Object)
            {
                ReadInteger(items.GetProperty("v"), 2, 2);
                items = items.GetProperty("items");
            }
            if (items.ValueKind != JsonValueKind.Array) return Array.Empty<Citation>();
            var citations = new List<Citation>();
            foreach (var item in items.EnumerateArray())
            {
                try { citations.Add(ReadCitation(item)); }
                catch (Exception exception) when (IsInvalidJson(exception)) { }
            }
            return citations;
        }
        catch (Exception exception) when (IsInvalidJson(exception))
        {
            return Array.Empty<Citation>();
        }
        catch (ArgumentException)
        {
            // JsonDocument cannot transcode a .NET string with isolated UTF-16 surrogates.
            return Array.Empty<Citation>();
        }
    }

    public static string? Encode(IReadOnlyList<Citation> citations)
    {
        if (citations.Count == 0) return null;
        var items = citations.Select(CitationOut.From).ToArray();
        return citations.Any(c => c.IsV2)
            ? JsonSerializer.Serialize(new V2Out(2, items), EncodeOptions)
            : JsonSerializer.Serialize(items, EncodeOptions);
    }

    private static bool IsInvalidJson(Exception exception) =>
        exception is JsonException or InvalidOperationException or KeyNotFoundException;

    private static void ValidatePayload(JsonElement value)
    {
        switch (value.ValueKind)
        {
            case JsonValueKind.Object:
                foreach (var property in value.EnumerateObject())
                {
                    // Decoding a property name also validates its surrogate escapes.
                    _ = property.Name;
                    ValidatePayload(property.Value);
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in value.EnumerateArray()) ValidatePayload(item);
                break;
            case JsonValueKind.String:
                _ = value.GetString();
                break;
            case JsonValueKind.Number:
                if (!value.TryGetDouble(out var number) || !double.IsFinite(number))
                    throw new JsonException("Number token must be finite as a double.");
                break;
        }
    }

    private static Citation ReadCitation(JsonElement item)
    {
        var marker = (int)ReadInteger(item.GetProperty("marker"), 1, int.MaxValue);
        var chunkId = ReadInteger(item.GetProperty("chunkId"), 0, MaxJsonSafeInteger);
        var sourceId = ReadInteger(item.GetProperty("sourceId"), 0, MaxJsonSafeInteger);
        var snippet = ReadString(item.GetProperty("snippet"));
        return new Citation(marker, chunkId, sourceId, snippet)
        {
            FolderId = OptionalInteger(item, "folderId", MaxJsonSafeInteger),
            RevisionId = OptionalInteger(item, "revisionId", MaxJsonSafeInteger),
            RelPath = OptionalString(item, "relPath"),
            DisplayName = OptionalString(item, "displayName"),
            Text = OptionalString(item, "text"),
            Spans = ReadList(item, "spans", ReadSpan),
            ChunkIds = ReadList(item, "chunkIds", value => ReadInteger(value, 0, MaxJsonSafeInteger))
        };
    }

    private static CitationSpan ReadSpan(JsonElement item)
    {
        var start = ReadInteger(item.GetProperty("start"), 0, MaxJsonSafeInteger);
        var end = ReadInteger(item.GetProperty("end"), 0, MaxJsonSafeInteger);
        var pageFrom = (int?)OptionalInteger(item, "pageFrom", int.MaxValue);
        var pageTo = (int?)OptionalInteger(item, "pageTo", int.MaxValue);
        if (start >= end || (pageFrom.HasValue && pageTo.HasValue && pageFrom > pageTo))
            throw new JsonException("Invalid citation span bounds.");
        return new CitationSpan(start, end, pageFrom, pageTo);
    }

    private static long ReadInteger(JsonElement value, long min, long max)
    {
        if (value.ValueKind != JsonValueKind.Number
            || value.GetRawText().IndexOfAny(['.', 'e', 'E']) >= 0
            || !value.TryGetInt64(out var number) || number < min || number > max)
            throw new JsonException("Expected an integer token within the contract range.");
        return number;
    }

    private static string ReadString(JsonElement value) => value.ValueKind == JsonValueKind.String
        ? value.GetString()! : throw new JsonException("Expected a string.");

    private static bool HasValue(JsonElement item, string key, out JsonElement value) =>
        item.TryGetProperty(key, out value) && value.ValueKind != JsonValueKind.Null;

    private static long? OptionalInteger(JsonElement item, string key, long max) =>
        HasValue(item, key, out var value) ? ReadInteger(value, 0, max) : null;

    private static string? OptionalString(JsonElement item, string key) =>
        HasValue(item, key, out var value) ? ReadString(value) : null;

    private static IReadOnlyList<T> ReadList<T>(JsonElement item, string key, Func<JsonElement, T> read)
    {
        if (!HasValue(item, key, out var value)) return Array.Empty<T>();
        // EnumerateArray rejects wrong kinds; any invalid member rejects the item.
        return value.EnumerateArray().Select(read).ToArray();
    }

    // Encoding DTOs keep the storage keys independent of model naming and omit
    // empty lists (as well as null optionals), just like Swift's custom encoder.
    private sealed record V2Out(
        [property: JsonPropertyName("v")] int Version,
        [property: JsonPropertyName("items")] CitationOut[] Items);

    private sealed record SpanOut(
        [property: JsonPropertyName("start")] long Start,
        [property: JsonPropertyName("end")] long End,
        [property: JsonPropertyName("pageFrom")] int? PageFrom,
        [property: JsonPropertyName("pageTo")] int? PageTo);

    private sealed record CitationOut(
        [property: JsonPropertyName("marker")] int Marker,
        [property: JsonPropertyName("chunkId")] long ChunkId,
        [property: JsonPropertyName("sourceId")] long SourceId,
        [property: JsonPropertyName("snippet")] string Snippet,
        [property: JsonPropertyName("folderId")] long? FolderId,
        [property: JsonPropertyName("relPath")] string? RelPath,
        [property: JsonPropertyName("displayName")] string? DisplayName,
        [property: JsonPropertyName("revisionId")] long? RevisionId,
        [property: JsonPropertyName("spans")] SpanOut[]? Spans,
        [property: JsonPropertyName("chunkIds")] IReadOnlyList<long>? ChunkIds,
        [property: JsonPropertyName("text")] string? Text)
    {
        public static CitationOut From(Citation citation) => new(
            citation.Marker, citation.ChunkId, citation.SourceId, citation.Snippet,
            citation.FolderId, citation.RelPath, citation.DisplayName, citation.RevisionId,
            citation.Spans.Count == 0 ? null : citation.Spans.Select(s => new SpanOut(s.Start, s.End, s.PageFrom, s.PageTo)).ToArray(),
            citation.ChunkIds.Count == 0 ? null : citation.ChunkIds, citation.Text);
    }
}
