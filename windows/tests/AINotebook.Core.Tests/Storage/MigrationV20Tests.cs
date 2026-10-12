using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Tests.Ingestion;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>Shared <c>storage-v20</c> schema: the dedup ledger (<c>embedding-plan-v1</c> §5).</summary>
public sealed class MigrationV20Tests
{
    private static JsonElement Queries(string name)
    {
        var root = SharedFixtures.Json("contracts/storage-v20.json");
        Assert.Equal("v20_embedding_dedup", root.GetProperty("migration").GetString());
        return root.GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == name).GetProperty("queries");
    }

    [Fact]
    public void FreshSchemaMatchesSharedFixture()
    {
        using var store = V19TestStore.Create();
        V19TestStore.AssertQueries(store, Queries("fresh-schema"));
        Assert.Equal("ok", store.Connection.ExecuteScalar<string>("PRAGMA integrity_check"));
        Assert.Throws<SqliteException>(() => store.Connection.Execute("INSERT INTO generation_text_hashes VALUES (1,1,'short',0)"));
    }

    [Fact]
    public void UpgradeFromV18AddsAnEmptyLedger()
    {
        var (store, directory, _) = V19TestStore.UpgradeCopy(null);
        try
        {
            V19TestStore.AssertQueries(store, Queries("upgrade-from-v18"));
            Assert.Empty(store.Connection.Query("PRAGMA foreign_key_check"));
        }
        finally
        {
            store.Dispose();
            SqliteConnection.ClearAllPools();
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void LedgerRowsCascadeWithGenerationAndChunk()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
        long notebook = store.CreateNotebook("cascade").Id!.Value;
        EmbeddingPlanContractTests.Seed(store, notebook, JsonSerializer.SerializeToElement(new object[]
        {
            new { id = 1, type = "text", chunks = new[] { "a", "b" } }, new { id = 2, type = "text", chunks = new[] { "c" } },
        }));
        var generation = store.CreateGeneration(notebook, new GenerationIdentity("local", "1", "m", null, 2, "l2", "1", "1", "2"), 0);
        foreach (long chunk in store.Connection.Query<long>("SELECT id FROM source_chunks ORDER BY id").ToArray())
            store.Connection.Execute("INSERT INTO generation_text_hashes VALUES ($generation,$chunk,$hash,0)",
                new { generation = generation.Id, chunk, hash = EmbeddingPlan.TextHash(chunk.ToString(System.Globalization.CultureInfo.InvariantCulture)) });
        store.Connection.Execute("DELETE FROM sources WHERE id=2");
        Assert.Equal(2, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM generation_text_hashes"));
        store.Connection.Execute("DELETE FROM index_generations WHERE id=$id", new { id = generation.Id });
        Assert.Equal(0, store.Connection.ExecuteScalar<int>("SELECT count(*) FROM generation_text_hashes"));
    }
}
