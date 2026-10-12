using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class ProviderRootUpgradeTests
{
    private static JsonElement[] Cases => SharedFixtures.Json("contracts/provider-store-v1.json")
        .GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("name").GetString()!.StartsWith("legacy-", StringComparison.Ordinal)).ToArray();

    [Fact]
    public async Task V18RootsConvertOnceAndPreserveAllOtherProviderFields()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"provider-upgrade-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "store.sqlite");
        var created = new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc);
        try
        {
            SeedV18(path, conn =>
            {
                foreach (var c in Cases)
                    Insert(conn, c.GetProperty("name").GetString()!, c.GetProperty("type").GetString()!, c.GetProperty("before").GetString()!, created);
                Insert(conn, "invalid", "openai", "http://user:secret@host/v1", created);
            });
            for (var reopen = 0; reopen < 3; reopen++)
            {
                using var store = new NotebookStore(new StorePath(path));
                foreach (var c in Cases)
                {
                    var id = c.GetProperty("name").GetString()!;
                    var p = Assert.IsType<ProviderConfig>(store.Provider(id));
                    Assert.Equal(id, p.Id);
                    Assert.Equal(id, p.Name);
                    Assert.Equal(ProviderTypeExtensions.FromStorageString(c.GetProperty("type").GetString()!), p.Type);
                    Assert.Equal(c.GetProperty("after").GetString(), p.BaseUrl);
                    Assert.False(p.Enabled);
                    Assert.False(p.PrivacyAcknowledged);
                    Assert.Equal(created, p.CreatedAt);
                }
                Assert.Equal("http://user:secret@host/v1", store.Provider("invalid")!.BaseUrl);
                var stub = new StubHttpMessageHandler();
                using var http = new HttpClient(stub);
                var adapter = new OpenAIChatAdapter(http, store.Provider("invalid")!.BaseUrl, "k");
                var error = await Assert.ThrowsAsync<ProviderConfigurationException>(async () =>
                {
                    await foreach (var _ in adapter.StreamAsync("m", [])) { }
                });
                Assert.Equal("invalidBaseURL", error.Code);
                Assert.Empty(stub.AllRequests);
                var fresh = SharedFixtures.Json("contracts/provider-store-v1.json").GetProperty("cases").EnumerateArray()
                    .Single(c => c.GetProperty("name").GetString() == "new-versionless");
                if (reopen == 0)
                    store.SaveProvider(new("new", ProviderType.OpenAICompatible, "New", fresh.GetProperty("before").GetString()!, true, true, created));
                Assert.Equal(fresh.GetProperty("after").GetString(), store.Provider("new")!.BaseUrl);
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    [Theory]
    [InlineData("anthropic")]
    [InlineData("openwebui")]
    public void ChatOnlySelectionHasDurableConversionAndOneTimeNotice(string type)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"provider-selection-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "store.sqlite");
        try
        {
            SeedV18(path, conn => Insert(conn, "chat-only", type, "https://unit.example", DateTime.UtcNow));
            using (var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: "chat-only:vendor/m:tag"))
            {
                var conversion = Assert.IsType<EmbeddingSelectionConversion>(store.PendingEmbeddingSelectionConversion());
                Assert.Equal(ProviderConfig.OllamaId, conversion.ProviderId);
                Assert.Equal("nomic-embed-text", conversion.Model);
                Assert.True(store.HasEmbeddingSelectionConversionNotice());
            }
            using (var store = new NotebookStore(new StorePath(path)))
            {
                Assert.NotNull(store.PendingEmbeddingSelectionConversion());
                store.CompleteEmbeddingSelectionConversion();
                Assert.Null(store.PendingEmbeddingSelectionConversion());
                Assert.True(store.HasEmbeddingSelectionConversionNotice());
                store.DismissEmbeddingSelectionConversionNotice();
            }
            using (var store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: "chat-only:new"))
            {
                Assert.Null(store.PendingEmbeddingSelectionConversion());
                Assert.False(store.HasEmbeddingSelectionConversionNotice());
            }
        }
        finally { Directory.Delete(directory, true); }
    }

    [Fact]
    public void EmbeddingCapableSelectionIsUnchanged()
    {
        using var store = new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: ProviderConfig.OllamaId + ":custom:tag");
        Assert.Null(store.PendingEmbeddingSelectionConversion());
        Assert.False(store.HasEmbeddingSelectionConversionNotice());
    }

    [Fact]
    public void MigrationVersionSeamRejectsUnknownVersions()
    {
        lock (TestGate)
        {
            using var conn = new SqliteConnection("Data Source=:memory:");
            conn.Open();
            Assert.Throws<ArgumentOutOfRangeException>(() => Migrator.Migrate(conn, 0));
            Assert.Throws<ArgumentOutOfRangeException>(() => Migrator.Migrate(conn, 22));
        }
    }

    private static readonly object TestGate = new();
    private static void SeedV18(string path, Action<SqliteConnection> seed)
    {
        lock (TestGate)
        {
            using var conn = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
            conn.Open();
            Migrator.Migrate(conn, 18);
            using var check = conn.CreateCommand();
            check.CommandText = "SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'";
            Assert.Equal(0L, check.ExecuteScalar());
            seed(conn);
        }
    }
    private static void Insert(SqliteConnection conn, string id, string type, string root, DateTime created)
    {
        using var cmd = conn.CreateCommand();
        cmd.CommandText = "INSERT INTO providers(id,type,name,base_url,enabled,privacy_acknowledged,created_at) VALUES($id,$type,$id,$root,0,0,$created)";
        cmd.Parameters.AddWithValue("$id", id);
        cmd.Parameters.AddWithValue("$type", type);
        cmd.Parameters.AddWithValue("$root", root);
        cmd.Parameters.AddWithValue("$created", SqliteDate.ToDb(created));
        cmd.ExecuteNonQuery();
    }
}
