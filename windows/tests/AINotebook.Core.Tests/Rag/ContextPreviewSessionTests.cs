using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public sealed class ContextPreviewSessionTests
{
    [Fact]
    public void EvictionAndOversizeRejection()
    {
        var cache = new ContextPreviewSession(2, 6);
        Assert.True(cache.Retain(Encoding.UTF8.GetBytes("á"), 1, 1));
        Assert.True(cache.Retain("bb"u8.ToArray(), 1, 2));
        _ = cache.Sent(1, 1);
        Assert.True(cache.Retain("cc"u8.ToArray(), 1, 3));
        Assert.Null(cache.Sent(1, 1));
        Assert.Equal("bb"u8.ToArray(), cache.Sent(1, 2));
        Assert.False(cache.Retain(new byte[7], 1, 4));
        Assert.False(cache.Retain(new byte[7], 1, 2));
        Assert.Equal("bb"u8.ToArray(), cache.Sent(1, 2));
        Assert.Equal(4, cache.RetainedBytes);
    }

    [Fact]
    public void StaleCompletionCannotReplaceNewDraft()
    {
        var cache = new ContextPreviewSession();
        byte[] a = Enumerable.Repeat((byte)1, 32).ToArray(), b = Enumerable.Repeat((byte)2, 32).ToArray();
        ulong first = cache.BeginDraft(1, a), second = cache.BeginDraft(2, b);
        Assert.False(cache.CompleteDraft(first, a, "old"u8.ToArray()));
        Assert.False(cache.CompleteDraft(second, a, "wrong key"u8.ToArray()));
        Assert.True(cache.CompleteDraft(second, b, "new"u8.ToArray()));
        Assert.Equal("new"u8.ToArray(), cache.Draft(b));
        Assert.Null(cache.Draft(a));
        cache.Clear(1);
        Assert.Equal("new"u8.ToArray(), cache.Draft(b));
        cache.Clear(2);
        Assert.Null(cache.Draft(b));
        Assert.False(cache.CompleteDraft(second, b, "late"u8.ToArray()));
    }

    [Fact]
    public void DraftPressureSameKeyGenerationsAndSessionClear()
    {
        var cache = new ContextPreviewSession(2, 4);
        byte[] key = Enumerable.Repeat((byte)1, 32).ToArray();
        ulong first = cache.BeginDraft(1, key), second = cache.BeginDraft(1, key);
        Assert.False(cache.CompleteDraft(first, key, [9]));
        Assert.True(cache.CompleteDraft(second, key, [1, 2, 3, 4]));
        Assert.False(cache.Retain([8], 2, 1));
        cache.Clear(2);
        Assert.False(cache.PromoteDraft(2, 2));
        Assert.Equal(second, cache.Generation);
        Assert.Equal(1L, cache.DraftSessionId);
        Assert.Equal(4, cache.RetainedBytes);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, cache.Draft(key));
        Assert.Null(cache.Sent(2, 2));
    }

    [Fact]
    public void EmptyDraftAtZeroByteLimitCanBePromoted()
    {
        var cache = new ContextPreviewSession(1, 0);
        byte[] key = new byte[32];
        ulong generation = cache.BeginDraft(1, key);
        Assert.True(cache.CompleteDraft(generation, key, []));
        Assert.True(cache.PromoteDraft(1, 1));
        Assert.Equal(Array.Empty<byte>(), cache.Sent(1, 1));
        Assert.Null(cache.Draft(key));
        Assert.Null(cache.DraftSessionId);
        Assert.Equal(generation + 1, cache.Generation);
        Assert.Equal(0, cache.RetainedBytes);
    }

    [Fact]
    public void PromoteDraftTransfersReadyBytesWithoutDoubleCounting()
    {
        var cache = new ContextPreviewSession(2, 4);
        byte[] key = new byte[32];
        Assert.False(cache.PromoteDraft(1, 2));
        Assert.Equal(0UL, cache.Generation);
        Assert.True(cache.Retain([1, 2], 2, 1));
        ulong generation = cache.BeginDraft(1, key);
        Assert.False(cache.PromoteDraft(1, 2));
        Assert.Equal(generation, cache.Generation);
        Assert.Equal(1L, cache.DraftSessionId);
        Assert.True(cache.CompleteDraft(generation, key, [3, 4]));

        Assert.True(cache.PromoteDraft(1, 2));
        Assert.Equal(new byte[] { 1, 2 }, cache.Sent(2, 1));
        Assert.Equal(new byte[] { 3, 4 }, cache.Sent(1, 2));
        Assert.Equal(4, cache.RetainedBytes);
        Assert.Null(cache.Draft(key));
        Assert.Null(cache.DraftSessionId);
        Assert.Equal(generation + 1, cache.Generation);
        Assert.False(cache.CompleteDraft(generation, key, [9]));
        Assert.False(cache.PromoteDraft(1, 3));
        Assert.Null(cache.Sent(1, 3));
        Assert.Equal(generation + 1, cache.Generation);
    }

    [Fact]
    public void ConcurrentPromotionsTransferDraftExactlyOnce()
    {
        var cache = new ContextPreviewSession(32, 32);
        byte[] key = new byte[32];
        ulong generation = cache.BeginDraft(1, key);
        Assert.True(cache.CompleteDraft(generation, key, [7]));
        var promoted = new System.Collections.Concurrent.ConcurrentBag<int>();
        Parallel.For(0, 32, assistantId =>
        {
            if (cache.PromoteDraft(1, assistantId)) promoted.Add(assistantId);
        });
        int winner = Assert.Single(promoted);
        Assert.Equal(new byte[] { 7 }, cache.Sent(1, winner));
        Assert.Single(Enumerable.Range(0, 32), id => cache.Sent(1, id) is not null);
        Assert.Null(cache.Draft(key));
        Assert.Null(cache.DraftSessionId);
        Assert.Equal(generation + 1, cache.Generation);
        Assert.Equal(1, cache.RetainedBytes);
    }

    [Fact]
    public void SharedPreviewOperations()
    {
        var cases = ContextPackFixtures.Cases("preview");
        Assert.Equal(13, cases.Length);
        foreach (var row in cases)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            var cache = new ContextPreviewSession(input.TryGetProperty("maxTurns", out var turns) ? turns.GetInt32() : 5,
                input.TryGetProperty("maxBytes", out var bytes) ? bytes.GetInt32() : 33_554_432);
            var identities = new Dictionary<(long Session, long Assistant), int>();
            byte[]? currentKey = null;
            int index = 0;
            foreach (var op in input.GetProperty("operations").EnumerateArray())
            {
                object? result = null;
                string kind = op.GetProperty("kind").GetString()!;
                long Session() => op.GetProperty("sessionId").GetInt64();
                long Assistant() => op.GetProperty("assistantId").GetInt64();
                switch (kind)
                {
                    case "retain":
                        var payload = Payload(op.GetProperty("payload"));
                        bool kept = cache.Retain(payload, Session(), Assistant());
                        result = kept;
                        if (kept)
                        {
                            identities[(Session(), Assistant())] = index;
                            // Mutating the caller's buffer cannot alter the retained snapshot.
                            byte firstByte = payload.Length == 0 ? (byte)0 : payload[0];
                            if (payload.Length > 0) payload[0] ^= 255;
                            var saved = cache.Sent(Session(), Assistant())!;
                            if (saved.Length > 0) Assert.Equal(firstByte, saved[0]);
                        }
                        break;
                    case "sent": result = cache.Sent(Session(), Assistant()) is not null; break;
                    case "beginDraft":
                        currentKey = Key(op);
                        result = cache.BeginDraft(Session(), currentKey);
                        break;
                    case "completeDraft":
                        result = cache.CompleteDraft(op.GetProperty("generation").GetUInt64(), Key(op), Payload(op.GetProperty("payload")));
                        break;
                    case "draft": result = cache.Draft(Key(op)) is not null; break;
                    case "changeIntent":
                        bool same = currentKey is not null && currentKey.SequenceEqual(Key(op));
                        result = same;
                        if (!same) { cache.InvalidateDraft(); currentKey = null; }
                        break;
                    case "invalidateDraft": cache.InvalidateDraft(); currentKey = null; break;
                    case "clear":
                        bool active = cache.DraftSessionId == Session();
                        cache.Clear(Session());
                        if (active) currentKey = null;
                        break;
                    case "promoteDraft":
                        bool promoted = cache.PromoteDraft(Session(), Assistant());
                        result = promoted;
                        if (promoted)
                        {
                            currentKey = null;
                            identities[(Session(), Assistant())] = index;
                        }
                        break;
                    default: Assert.Fail(name + ": unknown operation " + kind); break;
                }
                var retainedEntries = new List<object>();
                var retainedIds = new List<long>();
                foreach (var identity in identities.OrderBy(p => p.Value))
                {
                    var retained = cache.Sent(identity.Key.Session, identity.Key.Assistant);
                    if (retained is null) continue;
                    retainedEntries.Add(new { sessionId = identity.Key.Session, assistantId = identity.Key.Assistant, bytes = retained.Length });
                    retainedIds.Add(identity.Key.Assistant);
                    if (retained.Length > 0)
                    {
                        byte firstByte = retained[0];
                        retained[0] ^= 255;
                        Assert.Equal(firstByte, cache.Sent(identity.Key.Session, identity.Key.Assistant)![0]);
                    }
                }
                var currentDraft = currentKey is null ? null : cache.Draft(currentKey);
                var actual = JsonSerializer.SerializeToElement(new
                {
                    retained = retainedEntries, retainedIds, retainedBytes = cache.RetainedBytes,
                    draftBytes = currentDraft?.Length ?? 0, draftReady = currentDraft is not null,
                    draftSessionId = cache.DraftSessionId, generation = cache.Generation, result
                });
                ContextPackBuilderTests.EqualJson(row.GetProperty("expected").GetProperty("states")[index], actual, name + ".states[" + index + "]");
                index++;
            }
        }
    }

    [Fact]
    public void ByteBudgetIsGlobalAcrossSessions()
    {
        var cache = new ContextPreviewSession();
        var bytes = new byte[12 * 1024 * 1024];
        cache.Retain(bytes, 1, 1); cache.Retain(bytes, 2, 2); cache.Retain(bytes, 1, 3);
        Assert.Null(cache.Sent(1, 1));
        Assert.NotNull(cache.Sent(2, 2));
        Assert.NotNull(cache.Sent(1, 3));
        Assert.Equal(24 * 1024 * 1024, cache.RetainedBytes);
    }

    [Fact]
    public void DraftBuffersAreCopiesAndOversizeDoesNotEvict()
    {
        var cache = new ContextPreviewSession(5, 6);
        cache.Retain("ss"u8.ToArray(), 1, 1);
        byte[] key = new byte[32], originalKey = key.ToArray(), bytes = "ab"u8.ToArray();
        ulong generation = cache.BeginDraft(1, key);
        key[0] = 99;
        Assert.True(cache.CompleteDraft(generation, originalKey, bytes));
        bytes[0] = 99;
        Assert.Equal("ab"u8.ToArray(), cache.Draft(originalKey));
        cache.Draft(originalKey)![0] = 88;
        Assert.Equal("ab"u8.ToArray(), cache.Draft(originalKey));
        Assert.False(cache.CompleteDraft(generation, originalKey, new byte[7]));
        Assert.Equal("ab"u8.ToArray(), cache.Draft(originalKey));
        Assert.Equal("ss"u8.ToArray(), cache.Sent(1, 1));
        Assert.Equal(4, cache.RetainedBytes);
    }

    [Fact]
    public void InvalidLimitsAndKeysAreRejectedAndZeroByteLimitWorks()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new ContextPreviewSession(0));
        Assert.Throws<ArgumentOutOfRangeException>(() => new ContextPreviewSession(maxBytes: -1));
        var cache = new ContextPreviewSession(maxBytes: 0);
        Assert.Throws<ArgumentException>(() => cache.BeginDraft(1, new byte[31]));
        Assert.Throws<ArgumentException>(() => cache.BeginDraft(1, new byte[33]));
        Assert.Equal(0UL, cache.Generation);
        Assert.False(cache.Retain([1], 1, 1));
        Assert.True(cache.Retain([], 1, 2));
        byte[] key = new byte[32];
        ulong generation = cache.BeginDraft(1, key);
        Assert.True(cache.CompleteDraft(generation, key, []));
        Assert.NotNull(cache.Draft(key));
        Assert.Equal(0, cache.RetainedBytes);
    }

    [Fact]
    public void ConcurrentOperationsRemainBoundedAndOnlyLatestDraftCompletes()
    {
        var cache = new ContextPreviewSession(5, 100);
        Parallel.For(0, 100, i => cache.Retain(new byte[10], i % 2, i));
        Assert.InRange(cache.RetainedBytes, 0, 100);
        Assert.InRange(Enumerable.Range(0, 100).Count(i => cache.Sent(i % 2, i) is not null), 1, 10);
        var generations = new System.Collections.Concurrent.ConcurrentBag<(ulong Generation, byte[] Key)>();
        Parallel.For(0, 32, i =>
        {
            byte[] key = Enumerable.Repeat((byte)i, 32).ToArray();
            generations.Add((cache.BeginDraft(1, key), key));
        });
        ulong latest = generations.Max(p => p.Generation);
        foreach (var item in generations)
            Assert.Equal(item.Generation == latest, cache.CompleteDraft(item.Generation, item.Key, [1]));
        Assert.Equal(latest, cache.Generation);
    }

    private static byte[] Key(JsonElement op)
    {
        if (!op.TryGetProperty("intent", out var intent)) return Convert.FromHexString(op.GetProperty("key").GetString()!);
        var node = JsonNode.Parse(intent.GetRawText())!.AsObject();
        node.Remove("displayLanguage");
        if (node["scope"] is JsonObject scope)
            foreach (string field in new[] { "sourceIds", "folderIds" })
                if (scope[field] is JsonArray values)
                    scope[field] = new JsonArray(values.Select(v => v!.GetValue<long>()).Distinct().Order().Select(v => JsonValue.Create(v) as JsonNode).ToArray());
        return SHA256.HashData(PreparedContextRequestJson.CanonicalBytes(JsonSerializer.SerializeToElement(node)));
    }

    private static byte[] Payload(JsonElement payload)
    {
        var unit = Encoding.UTF8.GetBytes(payload.GetProperty("text").GetString()!);
        int count = payload.TryGetProperty("repeat", out var repeat) ? repeat.GetInt32() : 1;
        var result = new byte[checked(unit.Length * count)];
        for (int index = 0; index < result.Length; index += unit.Length) unit.CopyTo(result, index);
        return result;
    }
}
