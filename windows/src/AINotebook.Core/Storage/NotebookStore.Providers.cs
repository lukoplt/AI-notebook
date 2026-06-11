using AINotebook.Core.Providers;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public IReadOnlyList<ProviderConfig> Providers()
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at FROM providers ORDER BY created_at";
        using var r = cmd.ExecuteReader();
        var result = new List<ProviderConfig>();
        while (r.Read())
            result.Add(ReadProvider(r));
        return result;
    }

    public ProviderConfig? Provider(string id)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at FROM providers WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        using var r = cmd.ExecuteReader();
        return r.Read() ? ReadProvider(r) : null;
    }

    public ProviderConfig SaveProvider(ProviderConfig p)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = """
            INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
            VALUES($id, $type, $name, $url, $enabled, $priv, $at)
            ON CONFLICT(id) DO UPDATE SET
              type = excluded.type,
              name = excluded.name,
              base_url = excluded.base_url,
              enabled = excluded.enabled,
              privacy_acknowledged = excluded.privacy_acknowledged
            """;
        cmd.Parameters.AddWithValue("$id", p.Id);
        cmd.Parameters.AddWithValue("$type", p.Type.ToStorageString());
        cmd.Parameters.AddWithValue("$name", p.Name);
        cmd.Parameters.AddWithValue("$url", p.BaseUrl);
        cmd.Parameters.AddWithValue("$enabled", p.Enabled ? 1 : 0);
        cmd.Parameters.AddWithValue("$priv", p.PrivacyAcknowledged ? 1 : 0);
        cmd.Parameters.AddWithValue("$at", SqliteDate.ToDb(p.CreatedAt));
        cmd.ExecuteNonQuery();
        return p;
    }

    public void DeleteProvider(string id)
    {
        if (id == ProviderConfig.OllamaId) return; // built-in cannot be deleted
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "DELETE FROM providers WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", id);
        cmd.ExecuteNonQuery();
    }

    public void AcknowledgePrivacy(string providerId)
    {
        using var cmd = Connection.CreateCommand();
        cmd.CommandText = "UPDATE providers SET privacy_acknowledged = 1 WHERE id = $id";
        cmd.Parameters.AddWithValue("$id", providerId);
        cmd.ExecuteNonQuery();
    }

    private static ProviderConfig ReadProvider(SqliteDataReader r) => new(
        Id: r.GetString(0),
        Type: ProviderTypeExtensions.FromStorageString(r.GetString(1)),
        Name: r.GetString(2),
        BaseUrl: r.GetString(3),
        Enabled: r.GetInt64(4) != 0,
        PrivacyAcknowledged: r.GetInt64(5) != 0,
        CreatedAt: SqliteDate.FromDb(r.GetString(6)));
}
