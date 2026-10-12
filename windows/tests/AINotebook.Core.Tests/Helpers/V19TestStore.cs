using System.Text.Json;
using AINotebook.Core.Storage;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Helpers;

internal static class V19TestStore
{
    private static readonly object ConstructionGate = new();

    // Kept as a seam for the production registration task's historical harness.
    internal static void MigrateV18(SqliteConnection connection) => Migrator.MigrateThrough(connection, "v18_personas");

    internal static NotebookStore Create()
    {
        return new NotebookStore(StorePath.InMemory, configuredEmbeddingModelKey: null);
    }

    internal static (NotebookStore Store, string Directory, V19MigrationReport Report) UpgradeCopy(string? configuredKey)
    {
        string directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"ainotebook-v19-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        string path = System.IO.Path.Combine(directory, "db.sqlite");
        File.Copy(SharedFixtures.Path("storage/v18.sqlite"), path);
        NotebookStore? store = null;
        try
        {
            V19MigrationReport report;
            lock (ConstructionGate)
            {
                using var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ToString());
                connection.Open();
                connection.Execute("PRAGMA foreign_keys=ON");
                MigrateV18(connection);
                using var transaction = connection.BeginTransaction();
                report = MigrationV19.Apply(connection, transaction, configuredKey);
                connection.Execute("INSERT INTO grdb_migrations(identifier) VALUES('v19_folder_rag')", transaction: transaction);
                transaction.Commit();
            }
            store = new NotebookStore(new StorePath(path), configuredEmbeddingModelKey: configuredKey);
            return (store, directory, report);
        }
        catch
        {
            store?.Dispose();
            Directory.Delete(directory, recursive: true);
            throw;
        }
    }

    internal static NotebookStore Reopen(string directory, string? configuredKey = null)
    {
        return new NotebookStore(new StorePath(System.IO.Path.Combine(directory, "db.sqlite")), configuredEmbeddingModelKey: configuredKey);
    }

    internal static V19MigrationReport Upgrade(NotebookStore store, string? configuredKey)
    {
        lock (store.Gate)
        {
            if (store.Connection.ExecuteScalar<int>(
                "SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'") != 0)
                return new V19MigrationReport(new Dictionary<long, int>());
            using var transaction = store.Connection.BeginTransaction();
            var report = MigrationV19.Apply(store.Connection, transaction, configuredKey);
            store.Connection.Execute("INSERT INTO grdb_migrations(identifier) VALUES('v19_folder_rag')", transaction: transaction);
            transaction.Commit();
            return report;
        }
    }

    internal static void AssertQueries(NotebookStore store, JsonElement queries)
    {
        lock (store.Gate)
        {
            Assert.NotEmpty(queries.EnumerateArray());
            foreach (var query in queries.EnumerateArray())
            {
                using var command = store.Connection.CreateCommand();
                command.CommandText = query.GetProperty("sql").GetString()!;
                using var reader = command.ExecuteReader();
                var rows = new List<object?[]>();
                while (reader.Read())
                {
                    var values = new object?[reader.FieldCount];
                    for (int i = 0; i < reader.FieldCount; i++)
                        values[i] = reader.IsDBNull(i) ? null : reader.GetValue(i);
                    rows.Add(values);
                }
                var actual = JsonSerializer.SerializeToElement(rows);
                var expected = query.GetProperty("rows");
                if (query.GetProperty("name").GetString() == "columns-ingest_jobs"
                    && !expected.EnumerateArray().Any(row => row[0].GetString() == "options_json"))
                {
                    // The additive handoff fixture keeps the original shared snapshot usable by
                    // the parallel Swift worktree while retaining every original schema assertion.
                    // Compare the full actual rowset against the old rows plus the exact new column.
                    var handoff = SharedFixtures.Json("contracts/storage-revision-pages-v1.json")
                        .GetProperty("cases").EnumerateArray().Single(c => c.GetProperty("name").GetString() == "durable-job-options-schema");
                    var optionColumn = handoff.GetProperty("queries").EnumerateArray()
                        .Single(q => q.GetProperty("name").GetString() == "columns-job-handoff")
                        .GetProperty("rows").EnumerateArray().Single(row => row[0].GetString() == "options_json");
                    expected = JsonSerializer.SerializeToElement(expected.EnumerateArray().Append(optionColumn).ToArray());
                }
                Assert.True(JsonElement.DeepEquals(expected, actual),
                    $"{query.GetProperty("name").GetString()}: expected {expected.GetRawText()}, actual {actual.GetRawText()}");
            }
        }
    }

    internal static void Seed(NotebookStore store, JsonElement statements)
    {
        lock (store.Gate)
        {
            using var transaction = store.Connection.BeginTransaction();
            foreach (var statement in statements.EnumerateArray())
                store.Connection.Execute(statement.GetString()!, transaction: transaction);
            transaction.Commit();
        }
    }
}
