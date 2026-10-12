using Limits = AINotebook.Core.Providers.ProviderModelLimits;

namespace AINotebook.Core.Storage;

public sealed record EmbeddingSelectionConversion(string ProviderId, string Model);

public sealed partial class NotebookStore
{
    public EmbeddingSelectionConversion? PendingEmbeddingSelectionConversion()
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "SELECT embedding_provider_id,embedding_model FROM provider_configuration_conversion WHERE id=1 AND selection_pending=1";
            using var reader = cmd.ExecuteReader();
            return reader.Read() ? new(reader.GetString(0), reader.GetString(1)) : null;
        }
    }

    public bool HasEmbeddingSelectionConversionNotice()
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "SELECT count(*) FROM provider_configuration_conversion WHERE id=1 AND notice_pending=1";
            return (long)cmd.ExecuteScalar()! != 0;
        }
    }

    public void CompleteEmbeddingSelectionConversion()
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "UPDATE provider_configuration_conversion SET selection_pending=0 WHERE id=1";
            cmd.ExecuteNonQuery();
        }
    }

    public void DismissEmbeddingSelectionConversionNotice()
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "UPDATE provider_configuration_conversion SET notice_pending=0 WHERE id=1";
            cmd.ExecuteNonQuery();
        }
    }

    public Limits? ProviderModelLimits(string providerId, string model)
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = """
                SELECT provider_id, model, context_window, runtime_context, max_output_tokens, source
                FROM provider_model_limits WHERE provider_id=$p AND model=$m
                """;
            cmd.Parameters.AddWithValue("$p", providerId);
            cmd.Parameters.AddWithValue("$m", model);
            using var reader = cmd.ExecuteReader();
            if (!reader.Read()) return null;
            var limits = new Limits(reader.GetString(0), reader.GetString(1),
                reader.IsDBNull(2) ? null : reader.GetInt32(2), reader.GetInt32(3),
                reader.GetInt32(4), reader.GetString(5));
            limits.Validate();
            return limits;
        }
    }

    public void SaveProviderModelLimits(Limits limits)
    {
        limits.Validate();
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = """
                INSERT INTO provider_model_limits(provider_id, model, context_window, runtime_context, max_output_tokens, source)
                VALUES ($p, $m, $w, $c, $o, $s)
                ON CONFLICT(provider_id, model) DO UPDATE SET
                  context_window=excluded.context_window, runtime_context=excluded.runtime_context,
                  max_output_tokens=excluded.max_output_tokens, source=excluded.source
                WHERE provider_model_limits.source <> 'user' OR excluded.source = 'user'
                """;
            cmd.Parameters.AddWithValue("$p", limits.ProviderId);
            cmd.Parameters.AddWithValue("$m", limits.Model);
            cmd.Parameters.AddWithValue("$w", (object?)limits.ContextWindow ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$c", limits.RuntimeContext);
            cmd.Parameters.AddWithValue("$o", limits.MaxOutputTokens);
            cmd.Parameters.AddWithValue("$s", limits.Source);
            cmd.ExecuteNonQuery();
        }
    }

    public void DeleteProviderModelLimits(string providerId, string model)
    {
        lock (_gate)
        {
            using var cmd = Connection.CreateCommand();
            cmd.CommandText = "DELETE FROM provider_model_limits WHERE provider_id=$p AND model=$m";
            cmd.Parameters.AddWithValue("$p", providerId);
            cmd.Parameters.AddWithValue("$m", model);
            cmd.ExecuteNonQuery();
        }
    }
}
