using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// v17 repairs providers.created_at rows written by the (buggy) v11 data
/// step, which seeded the built-in Ollama provider via
/// DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") — no milliseconds — while
/// SqliteDate.FromDb requires the strict "yyyy-MM-dd HH:mm:ss.fff" shape.
/// Every DB migrated before the v11 fix carries one such row.
///
/// Test-infra note: mirrors MigrationV16Tests. Migrate() is idempotent per
/// recorded identifier, so by the time a fully-migrated in-memory DB exists,
/// v17 has ALREADY run (and found nothing to fix, since v11's seed is fixed
/// going forward). To exercise the repair step against a genuine pre-v17
/// state we: (1) run the full migration to get real schema + bookkeeping,
/// (2) overwrite created_at directly via raw SQL to simulate the legacy
/// malformed value, then (3) re-invoke the v17 data step directly via the
/// internal <see cref="Migrator.FixProviderTimestamps"/> helper (the exact
/// SQL RunCustom executes for "v17_fix_provider_timestamps") — re-running
/// Migrate() itself would be a no-op since v17 is already recorded.
/// </summary>
public class MigrationV17Tests
{
    private const string OllamaId = "00000000-0000-0000-0000-000000000000";

    private static SqliteConnection OpenMigrated()
    {
        var conn = new SqliteConnection("Data Source=:memory:");
        conn.Open();
        using (var pragma = conn.CreateCommand())
        {
            pragma.CommandText = "PRAGMA foreign_keys=ON";
            pragma.ExecuteNonQuery();
        }
        Migrator.Migrate(conn);
        return conn;
    }

    private static void Exec(SqliteConnection c, string sql)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = sql;
        cmd.ExecuteNonQuery();
    }

    private static string CreatedAtFor(SqliteConnection c, string id)
    {
        using var cmd = c.CreateCommand();
        cmd.CommandText = "SELECT created_at FROM providers WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        return (string)cmd.ExecuteScalar()!;
    }

    [Fact]
    public void Second_precision_timestamp_gets_millisecond_suffix_appended()
    {
        using var c = OpenMigrated();
        // Simulate the legacy v11 bug: overwrite the (now-correctly-seeded)
        // Ollama row's created_at with a second-precision value.
        Exec(c, $"UPDATE providers SET created_at = '2026-07-10 11:36:04' WHERE id = '{OllamaId}'");

        Migrator.FixProviderTimestamps(c);

        Assert.Equal("2026-07-10 11:36:04.000", CreatedAtFor(c, OllamaId));
    }

    [Fact]
    public void Millisecond_precision_timestamp_is_left_untouched()
    {
        using var c = OpenMigrated();
        const string otherId = "11111111-1111-1111-1111-111111111111";
        Exec(c, $"""
            INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
            VALUES('{otherId}', 'openai', 'OpenAI', 'https://api.openai.com', 1, 1, '2026-01-01 00:00:00.000')
            """);

        Migrator.FixProviderTimestamps(c);

        Assert.Equal("2026-01-01 00:00:00.000", CreatedAtFor(c, otherId));
    }
}
