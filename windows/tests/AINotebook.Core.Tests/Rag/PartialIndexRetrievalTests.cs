using System.Text.Json;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>retrieval-partial-v1: semantic retrieval from a building generation while nothing is active.</summary>
public sealed class PartialIndexRetrievalTests
{
    /// <summary>Scripted query session: checks the pinned endpoint revision like the provider router.</summary>
    private sealed class ScriptedProvider(string endpoint, float[]? reply) : IEmbeddingProducing, IEmbeddingSessionPreparing
    {
        private int _calls;
        internal int Calls => Volatile.Read(ref _calls);

        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        {
            Interlocked.Increment(ref _calls);
            if (reply is null) throw new HttpRequestException("provider unavailable");
            return Task.FromResult(inputs.Select(_ => reply).ToArray());
        }

        public Task<ProviderEmbeddingSession> PrepareEmbeddingAsync(GenerationIdentity identity, CancellationToken ct = default)
        {
            if (identity.EndpointRevision != endpoint) throw new RetrievalException("endpointRevisionMismatch");
            return Task.FromResult(new ProviderEmbeddingSession(this, identity.Model,
                identity.ProviderId + ":" + identity.Model, endpoint));
        }
    }

    private static JsonElement Fixture() => SharedFixtures.Json("contracts/retrieval-partial-v1.json");

    public static IEnumerable<object[]> CaseNames() => Fixture().GetProperty("cases").EnumerateArray()
        .Select(c => new object[] { c.GetProperty("name").GetString()! });

    [Theory]
    [MemberData(nameof(CaseNames))]
    public async Task SharedPartialIndexCase(string name)
    {
        var fixture = Fixture();
        var c = fixture.GetProperty("cases").EnumerateArray().Single(x => x.GetProperty("name").GetString() == name);
        var expected = c.GetProperty("expected");
        var selection = fixture.GetProperty("selection");
        string modelKey = selection.GetProperty("providerId").GetString() + ":" + selection.GetProperty("model").GetString();
        using var store = V19TestStore.Create();
        Seed(store, fixture.GetProperty("seed"), c);
        var provider = c.GetProperty("provider");
        float[]? reply = provider.GetProperty("kind").GetString() == "vector"
            ? provider.GetProperty("vector").EnumerateArray().Select(v => v.GetSingle()).ToArray() : null;
        var client = new ScriptedProvider(c.GetProperty("sessionEndpointRevision").GetString()!, reply);
        var retriever = new Retriever(store, client, modelKey, fixture.GetProperty("rrfK").GetInt32());

        using var pool = await retriever.SearchAsync(fixture.GetProperty("notebookId").GetInt64(),
            fixture.GetProperty("query").GetString()!, new RetrievalScope.All(), fixture.GetProperty("fetchK").GetInt32());

        var snapshot = Assert.IsType<ResolvedRetrievalScope>(pool.Snapshot);
        long? generationId = expected.GetProperty("generationId").ValueKind == JsonValueKind.Null
            ? null : expected.GetProperty("generationId").GetInt64();
        Assert.Equal(generationId, snapshot.Generation?.Id);
        Assert.Equal(generationId, snapshot.Pin.GenerationId);
        Assert.Equal(expected.GetProperty("generationState").ValueKind == JsonValueKind.Null
            ? null : expected.GetProperty("generationState").GetString(), snapshot.Generation?.State);
        var revisions = expected.GetProperty("vectorRevisions").EnumerateArray()
            .ToDictionary(r => r.GetProperty("sourceId").GetInt64(), r => r.GetProperty("revisionId").GetInt64());
        Assert.Equal(revisions.OrderBy(p => p.Key), snapshot.Pin.VectorRevisions.OrderBy(p => p.Key));
        Assert.Equal(expected.GetProperty("vectorStatus").GetString(), pool.Diagnostics.VectorStatus);
        Assert.Equal(expected.GetProperty("embedCalls").GetInt32(), client.Calls);
        Assert.Equal(expected.GetProperty("embeddingError").GetBoolean(), pool.EmbeddingFailure is not null);
        Assert.Equal(Ids(expected, "lexicalChunkIds"), pool.Lexical.Select(x => x.Reference.ChunkId));
        Assert.Equal(Ids(expected, "vectorChunkIds"), pool.Vector.Select(x => x.Reference.ChunkId));
        Assert.Equal(expected.GetProperty("fused").EnumerateArray()
                .Select(f => (f.GetProperty("chunkId").GetInt64(), f.GetProperty("rrfMicro").GetInt64())),
            pool.Fused.Select(f => (f.Reference.ChunkId, f.RrfMicro)));
        if (snapshot.Generation?.State == "building")
        {
            // Partial pins never take an epoch-keyed matrix (every build write bumps the epoch),
            // but they are served by the generation's resident, revision-checked matrix, which
            // grows pair by pair as the build completes sources (retrieval-resident-v1 §5).
            Assert.Null(snapshot.CacheKey);
            if (pool.Diagnostics.VectorStatus == "used") Assert.False(pool.Diagnostics.Streamed);
        }
    }

    /// <summary>Context pack, citations and hydration take the partial pin unchanged.</summary>
    [Fact]
    public async Task PartialPinHydratesEvidence()
    {
        var fixture = Fixture();
        var c = fixture.GetProperty("cases").EnumerateArray().Single(x => x.GetProperty("name").GetString() == "building-partial");
        using var store = V19TestStore.Create();
        Seed(store, fixture.GetProperty("seed"), c);
        var retriever = new Retriever(store, new ScriptedProvider("e1", [1, 0, 0]), "p:m");
        var hits = await retriever.SearchAsync(1, "kiwi", 8);
        Assert.Equal(c.GetProperty("expected").GetProperty("fused").EnumerateArray().Select(f => f.GetProperty("chunkId").GetInt64()),
            hits.Select(h => h.ChunkId));
        Assert.All(hits, h => Assert.False(string.IsNullOrEmpty(h.Snippet)));
        Assert.DoesNotContain(hits, h => h.ChunkId is 301 or 511 or 611);
    }

    private static long[] Ids(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetInt64()).ToArray();

    private static object? Value(JsonElement row, string key) => row.GetProperty(key).ValueKind switch
    {
        JsonValueKind.Null => null,
        JsonValueKind.Number => row.GetProperty(key).GetInt64(),
        _ => row.GetProperty(key).GetString(),
    };

    private static void Seed(NotebookStore store, JsonElement seed, JsonElement world)
    {
        void Insert(Microsoft.Data.Sqlite.SqliteTransaction tx, string table, JsonElement row, params (string Key, string Column)[] columns)
        {
            var args = new DynamicParameters();
            for (int i = 0; i < columns.Length; i++) args.Add("p" + i, Value(row, columns[i].Key));
            store.Connection.Execute($"INSERT INTO {table}({string.Join(",", columns.Select(x => x.Column))}) " +
                $"VALUES({string.Join(",", columns.Select((_, i) => "$p" + i))})", args, tx);
        }
        lock (store.Gate)
        {
            using var tx = store.Connection.BeginTransaction();
            foreach (var n in seed.GetProperty("notebooks").EnumerateArray())
                Insert(tx, "notebooks", n, ("id", "id"), ("name", "name"), ("createdAt", "created_at"), ("updatedAt", "updated_at"));
            foreach (var s in seed.GetProperty("sources").EnumerateArray())
                Insert(tx, "sources", s, ("id", "id"), ("notebookId", "notebook_id"), ("type", "type"), ("title", "title"),
                    ("status", "status"), ("ingestedAt", "ingested_at"), ("availability", "availability"), ("eligible", "eligible"));
            foreach (var r in seed.GetProperty("revisions").EnumerateArray())
                Insert(tx, "source_revisions", r, ("id", "id"), ("sourceId", "source_id"), ("revision", "revision"),
                    ("contentHash", "content_hash"), ("canonicalText", "canonical_text"), ("textFormatVersion", "text_format_version"),
                    ("chunkerVersion", "chunker_version"), ("createdAt", "created_at"));
            foreach (var s in seed.GetProperty("sources").EnumerateArray())
                store.Connection.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id",
                    new { id = s.GetProperty("id").GetInt64(), current = Value(s, "currentRevision"), published = Value(s, "publishedRevisionId") }, tx);
            foreach (var ch in seed.GetProperty("chunks").EnumerateArray())
                Insert(tx, "source_chunks", ch, ("id", "id"), ("sourceId", "source_id"), ("revisionId", "revision_id"),
                    ("ord", "ord"), ("text", "text"), ("tokenCount", "token_count"));
            foreach (var g in world.GetProperty("generations").EnumerateArray())
                Insert(tx, "index_generations", g, ("id", "id"), ("notebookId", "notebook_id"), ("providerId", "provider_id"),
                    ("endpointRevision", "endpoint_revision"), ("model", "model"), ("modelDigest", "model_digest"), ("dims", "dims"),
                    ("normalization", "normalization"), ("queryFormatVersion", "query_format_version"),
                    ("docFormatVersion", "doc_format_version"), ("chunkerVersion", "chunker_version"), ("state", "state"),
                    ("createdAt", "created_at"));
            foreach (var m in world.GetProperty("manifest").EnumerateArray())
                Insert(tx, "index_generation_manifest", m, ("generationId", "generation_id"), ("sourceId", "source_id"),
                    ("revisionId", "revision_id"), ("state", "state"), ("reason", "reason"));
            foreach (var e in world.GetProperty("embeddings").EnumerateArray())
            {
                byte[] blob = e.GetProperty("vector").EnumerateArray()
                    .SelectMany(v => BitConverter.GetBytes(BitConverter.SingleToInt32Bits(v.GetSingle()))).ToArray();
                if (!BitConverter.IsLittleEndian) throw new PlatformNotSupportedException();
                store.Connection.Execute("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($chunk,$generation,$blob)",
                    new { chunk = e.GetProperty("chunkId").GetInt64(), generation = e.GetProperty("generationId").GetInt64(), blob }, tx);
            }
            tx.Commit();
        }
    }
}
