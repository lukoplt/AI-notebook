using Dapper;

namespace AINotebook.Core.Storage;

public sealed partial class NotebookStore
{
    public int? EvidenceBudgetCap(long notebookId)
    {
        lock (_gate)
        {
            RequireNotebookV19(notebookId);
            return _conn.ExecuteScalar<int?>("SELECT evidence_budget_cap FROM notebooks WHERE id=$id", new { id = notebookId });
        }
    }

    public void SetEvidenceBudgetCap(long notebookId, int? value)
    {
        if (value < 0) throw new StorageV19Exception("invalidValue");
        lock (_gate)
        {
            if (_conn.Execute("UPDATE notebooks SET evidence_budget_cap=$value WHERE id=$id", new { id = notebookId, value }) != 1)
                throw new StorageV19Exception("notFound");
        }
    }

    public ProviderModelLimits? ModelLimits(string providerId, string model)
    {
        lock (_gate)
        {
            var row = _conn.QuerySingleOrDefault("""
                SELECT provider_id,model,context_window,runtime_context,max_output_tokens,source
                FROM provider_model_limits WHERE provider_id=$providerId AND model=$model
                """, new { providerId, model });
            return row is null ? null : new ProviderModelLimits((string)row.provider_id, (string)row.model,
                row.context_window is null ? null : (int)row.context_window, (int)row.runtime_context,
                (int)row.max_output_tokens, (string)row.source);
        }
    }

    public void SetModelLimits(ProviderModelLimits limits)
    {
        if (string.IsNullOrWhiteSpace(limits.Model) || limits.ContextWindow <= 0 || limits.RuntimeContext <= 0
            || limits.MaxOutputTokens <= 0 || limits.MaxOutputTokens >= limits.RuntimeContext
            || limits.RuntimeContext > limits.ContextWindow || limits.Source is not ("auto" or "user"))
            throw new StorageV19Exception("invalidValue");
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction();
            if (!_conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM providers WHERE id=$id)", new { id = limits.ProviderId }, tx))
                throw new StorageV19Exception("notFound");
            _conn.Execute("""
                INSERT INTO provider_model_limits(provider_id,model,context_window,runtime_context,max_output_tokens,source)
                VALUES($ProviderId,$Model,$ContextWindow,$RuntimeContext,$MaxOutputTokens,$Source)
                ON CONFLICT(provider_id,model) DO UPDATE SET context_window=excluded.context_window,
                    runtime_context=excluded.runtime_context,max_output_tokens=excluded.max_output_tokens,source=excluded.source
                WHERE provider_model_limits.source <> 'user' OR excluded.source = 'user'
                """, limits, tx);
            tx.Commit();
        }
    }
}
