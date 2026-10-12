using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class CitationsCodecTests
{
    private const long MaxSafeInteger = 9_007_199_254_740_991;
    private const string LegacyItem = """{"marker":1,"chunkId":10,"sourceId":2,"snippet":"ok"}""";
    private static readonly JsonSerializerOptions ExpectedOptions = new() { PropertyNameCaseInsensitive = true };

    public static IEnumerable<object?[]> Cases() =>
        SharedFixtures.Json("contracts/citations-v2.json").GetProperty("cases").EnumerateArray()
            .Select(c => new object?[] { c.GetProperty("name").GetString(),
                c.GetProperty("stored").GetString(), c.GetProperty("expected").GetRawText() });

    [Fact]
    public void SharedFixtureContainsAll27Cases() => Assert.Equal(27, Cases().Count());

    [Theory]
    [MemberData(nameof(Cases))]
    public void SharedFixtureCases(string name, string? stored, string expectedJson)
    {
        var expected = JsonSerializer.Deserialize<Citation[]>(expectedJson, ExpectedOptions)!;
        var actual = CitationsCodec.Decode(stored);
        AssertCitationsEqual(expected, actual);
        var encoded = CitationsCodec.Encode(actual);
        AssertCitationsEqual(expected, CitationsCodec.Decode(encoded));
        if (expected.Length == 0)
            Assert.Null(encoded);
        else
        {
            using var document = JsonDocument.Parse(encoded!);
            var items = document.RootElement.ValueKind == JsonValueKind.Array
                ? document.RootElement : document.RootElement.GetProperty("items");
            using var expectedDocument = JsonDocument.Parse(expectedJson);
            Assert.True(JsonElement.DeepEquals(expectedDocument.RootElement, items), name);
        }
    }

    [Fact]
    public void EncodeEmptyIsNull() => Assert.Null(CitationsCodec.Encode([]));

    [Fact]
    public void LegacyOnlyEncodesAsArrayWithoutOptionalKeys()
    {
        var citation = new Citation(1, 10, 2, "ok");
        Assert.False(citation.IsV2);
        var raw = CitationsCodec.Encode([citation]);
        Assert.StartsWith("[", raw);
        using var actual = JsonDocument.Parse(raw!);
        using var expected = JsonDocument.Parse($"[{LegacyItem}]");
        Assert.True(JsonElement.DeepEquals(expected.RootElement, actual.RootElement));
    }

    [Fact]
    public void V2RoundTripPreservesAllFieldsAndLegacyItems()
    {
        Citation[] citations = [new(1, 11, 2, "legacy"), new(2, 10, 2, "s")
        {
            FolderId = 5, RelPath = "smlouvy/česká.pdf", DisplayName = "česká.pdf", RevisionId = 7,
            Spans = [new(3, 9, null, null), new(10, MaxSafeInteger, 0, int.MaxValue)],
            ChunkIds = [10, MaxSafeInteger], Text = "full passage"
        }];
        var raw = CitationsCodec.Encode(citations);
        Assert.StartsWith("{", raw);
        using var doc = JsonDocument.Parse(raw!);
        Assert.Equal(2, doc.RootElement.GetProperty("v").GetInt32());
        var spans = doc.RootElement.GetProperty("items")[1].GetProperty("spans");
        Assert.False(spans[0].TryGetProperty("pageFrom", out _));
        Assert.False(spans[0].TryGetProperty("pageTo", out _));
        AssertCitationsEqual(citations, CitationsCodec.Decode(raw));
    }

    [Theory]
    [InlineData("folderId", "0")]
    [InlineData("revisionId", "0")]
    [InlineData("relPath", "\"\"")]
    [InlineData("displayName", "\"\"")]
    [InlineData("text", "\"\"")]
    [InlineData("spans", "[{\"start\":0,\"end\":1}]")]
    [InlineData("chunkIds", "[0]")]
    public void EachV2FieldSelectsEnvelope(string field, string value)
    {
        var citation = Assert.Single(CitationsCodec.Decode($"[{WithField(field, value)}]"));
        Assert.True(citation.IsV2);
        Assert.StartsWith("{", CitationsCodec.Encode([citation]));
    }

    [Fact]
    public void NullOptionalsAndEmptyListsAreAbsent()
    {
        var item = JsonNode.Parse(LegacyItem)!.AsObject();
        foreach (var field in new[] { "folderId", "revisionId", "relPath", "displayName", "text", "spans", "chunkIds" })
            item[field] = null;
        var citation = Assert.Single(CitationsCodec.Decode($"[{item}]"));
        AssertCitationsEqual([new(1, 10, 2, "ok")], [citation]);
        Assert.False(citation.IsV2);
        item["spans"] = new JsonArray();
        item["chunkIds"] = new JsonArray();
        citation = Assert.Single(CitationsCodec.Decode($"[{item}]"));
        Assert.False(citation.IsV2);
        Assert.StartsWith("[", CitationsCodec.Encode([citation]));
    }

    public static IEnumerable<object[]> IntegerFields()
    {
        yield return ["marker", 1L, (long)int.MaxValue];
        foreach (var field in new[] { "chunkId", "sourceId", "folderId", "revisionId", "chunkIds", "start", "end" })
            yield return [field, field == "end" ? 1L : 0L, field == "start" ? MaxSafeInteger - 1 : MaxSafeInteger];
        yield return ["pageFrom", 0L, (long)int.MaxValue];
        yield return ["pageTo", 0L, (long)int.MaxValue];
    }

    [Theory]
    [MemberData(nameof(IntegerFields))]
    public void IntegersAreStrictAndRangeChecked(string field, long min, long max)
    {
        foreach (var valid in new[] { min, max })
            Assert.Single(CitationsCodec.Decode($"[{WithInteger(field, valid.ToString(System.Globalization.CultureInfo.InvariantCulture))}]"));
        foreach (var invalid in new[] { "true", "false", "\"1\"", "{}", "[]", "1.0", "1e0", "1E0", "1.5", "9223372036854775808", (min - 1).ToString(), (max + 1).ToString() })
        {
            var decoded = CitationsCodec.Decode($"[{WithInteger(field, invalid)},{LegacyItem}]");
            AssertCitationsEqual([new(1, 10, 2, "ok")], decoded);
        }
    }

    [Theory]
    [InlineData("marker")]
    [InlineData("chunkId")]
    [InlineData("sourceId")]
    [InlineData("snippet")]
    public void RequiredFieldsRejectMissingAndNull(string field)
    {
        var item = JsonNode.Parse(LegacyItem)!.AsObject();
        item.Remove(field);
        Assert.Empty(CitationsCodec.Decode($"[{item}]"));
        item[field] = null;
        Assert.Empty(CitationsCodec.Decode($"[{item}]"));
    }

    [Theory]
    [InlineData("snippet")]
    [InlineData("relPath")]
    [InlineData("displayName")]
    [InlineData("text")]
    public void StringsRejectWrongKinds(string field)
    {
        foreach (var value in new[] { "true", "1", "[]", "{}" })
            AssertCitationsEqual([new(1, 10, 2, "ok")],
                CitationsCodec.Decode($"[{WithField(field, value)},{LegacyItem}]"));
    }

    [Theory]
    [InlineData("spans", "{}")]
    [InlineData("spans", "\"oops\"")]
    [InlineData("spans", "[{\"start\":0,\"end\":1},null]")]
    [InlineData("spans", "[{\"start\":0,\"end\":1},{}]")]
    [InlineData("spans", "[{\"start\":1,\"end\":1}]")]
    [InlineData("spans", "[{\"start\":2,\"end\":1}]")]
    [InlineData("spans", "[{\"start\":0,\"end\":1,\"pageFrom\":3,\"pageTo\":2}]")]
    [InlineData("chunkIds", "{}")]
    [InlineData("chunkIds", "[10,null]")]
    [InlineData("chunkIds", "[10,1.0]")]
    public void ListsAreAllOrNothingPerItem(string field, string value) =>
        AssertCitationsEqual([new(1, 10, 2, "ok")],
            CitationsCodec.Decode($"[{WithField(field, value)},{LegacyItem}]"));

    [Theory]
    [InlineData("2.0")]
    [InlineData("2e0")]
    [InlineData("2E0")]
    [InlineData("true")]
    [InlineData("\"2\"")]
    [InlineData("null")]
    [InlineData("3")]
    public void EnvelopeVersionMustBeStrictIntegerTwo(string version) =>
        Assert.Empty(CitationsCodec.Decode($"{{\"v\":{version},\"items\":[{LegacyItem}]}}"));

    [Theory]
    [InlineData("null")]
    [InlineData("true")]
    [InlineData("\"text\"")]
    [InlineData("{}")]
    [InlineData("{\"v\":2}")]
    [InlineData("{\"items\":[]}")]
    [InlineData("[null,false,42,[],{}]")]
    public void InvalidRootsAndItemsNeverThrow(string raw) => Assert.Empty(CitationsCodec.Decode(raw));

    [Fact]
    public void InvalidUtf16NeverThrows()
    {
        // .NET strings can contain isolated surrogates even though Swift strings cannot.
        var surrogate = new string((char)0xD800, 1);
        Assert.Empty(CitationsCodec.Decode(surrogate));
        Assert.Empty(CitationsCodec.Decode("\"" + surrogate + "\""));
        Assert.Empty(CitationsCodec.Decode("[{\"marker\":1,\"chunkId\":10,\"sourceId\":2,\"snippet\":\"\\uD800\"}]"));
    }

    [Fact]
    public void UnknownFieldsAndNullPagesAreIgnored()
    {
        var raw = """{"v":2,"future":true,"items":[{"marker":1,"chunkId":10,"sourceId":2,"snippet":"ok","future":{},"spans":[{"start":0,"end":1,"pageFrom":null,"pageTo":null,"future":true}]}]}""";
        AssertCitationsEqual([new(1, 10, 2, "ok") { Spans = [new(0, 1, null, null)] }], CitationsCodec.Decode(raw));
    }

    [Fact]
    public void CorruptRowStillLoadsWithEmptyCitations()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var sessionId = CreateSession(store);
        InsertRaw(store, sessionId, "{broken");
        var message = Assert.Single(store.Messages(sessionId));
        Assert.Equal("hi", message.Content);
        Assert.Empty(message.Citations);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void MixedValidInvalidRowRoundTripsThroughStore(bool v2)
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var sessionId = CreateSession(store);
        var item = v2 ? WithField("spans", "[{\"start\":3,\"end\":9007199254740991}]") : LegacyItem;
        var items = $"[{item},{{\"marker\":\"x\"}}]";
        InsertRaw(store, sessionId, v2 ? $"{{\"v\":2,\"items\":{items}}}" : items);
        var loaded = Assert.Single(store.Messages(sessionId));
        Citation expected = new(1, 10, 2, "ok");
        if (v2) expected = expected with { Spans = [new(3, MaxSafeInteger, null, null)] };
        AssertCitationsEqual([expected], loaded.Citations);
        var destination = CreateSession(store);
        store.AppendMessage(loaded with { Id = null, SessionId = destination });
        AssertCitationsEqual([expected], Assert.Single(store.Messages(destination)).Citations);
        lock (store.Gate)
        {
            var stored = store.Connection.ExecuteScalar<string>(
                "SELECT citations_json FROM messages WHERE session_id=$sid", new { sid = destination });
            Assert.StartsWith(v2 ? "{" : "[", stored);
        }
    }

    private static long CreateSession(NotebookStore store) =>
        store.CreateChatSession(store.CreateNotebook("N").Id!.Value, "S").Id!.Value;

    private static void InsertRaw(NotebookStore store, long sessionId, string raw)
    {
        lock (store.Gate)
            store.Connection.Execute("""
                INSERT INTO messages(session_id, role, content, citations_json, created_at)
                VALUES($sid, 'assistant', 'hi', $raw, $created)
                """, new { sid = sessionId, raw, created = SqliteDate.ToDb(DateTime.UtcNow) });
    }

    private static string WithField(string field, string value)
    {
        var item = JsonNode.Parse(LegacyItem)!.AsObject();
        item[field] = JsonNode.Parse(value);
        return item.ToJsonString();
    }

    private static string WithInteger(string field, string token) => field switch
    {
        "chunkIds" => WithField(field, $"[{token}]"),
        "start" => WithField("spans", $"[{{\"start\":{token},\"end\":{MaxSafeInteger}}}]"),
        "end" => WithField("spans", $"[{{\"start\":0,\"end\":{token}}}]"),
        "pageFrom" or "pageTo" => WithField("spans", $"[{{\"start\":0,\"end\":1,\"{field}\":{token}}}]"),
        _ => WithField(field, token)
    };

    private static void AssertCitationsEqual(IReadOnlyList<Citation> expected, IReadOnlyList<Citation> actual)
    {
        Assert.Equal(expected.Count, actual.Count);
        for (var i = 0; i < expected.Count; i++)
        {
            var e = expected[i];
            var a = actual[i];
            Assert.Equal(e.Marker, a.Marker);
            Assert.Equal(e.ChunkId, a.ChunkId);
            Assert.Equal(e.SourceId, a.SourceId);
            Assert.Equal(e.Snippet, a.Snippet);
            Assert.Equal(e.FolderId, a.FolderId);
            Assert.Equal(e.RelPath, a.RelPath);
            Assert.Equal(e.DisplayName, a.DisplayName);
            Assert.Equal(e.RevisionId, a.RevisionId);
            Assert.Equal<CitationSpan>(e.Spans, a.Spans);
            Assert.Equal<long>(e.ChunkIds, a.ChunkIds);
            Assert.Equal(e.Text, a.Text);
            Assert.Equal(e.IsV2, a.IsV2);
        }
    }
}
