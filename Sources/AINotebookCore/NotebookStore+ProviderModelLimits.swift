import GRDB

extension NotebookStore {
    public func providerModelLimits(providerId: String, model: String) throws -> ProviderModelLimits? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT provider_id, model, context_window, runtime_context, max_output_tokens, source
                FROM provider_model_limits WHERE provider_id = ? AND model = ?
                """, arguments: [providerId, model]) else { return nil }
            let limits = ProviderModelLimits(providerId: row["provider_id"], model: row["model"],
                contextWindow: row["context_window"], runtimeContext: row["runtime_context"],
                maxOutputTokens: row["max_output_tokens"], source: row["source"])
            try limits.validate()
            return limits
        }
    }

    /// Automatic metadata refreshes cannot overwrite a saved user choice.
    /// The conditional upsert also protects a user save made while discovery awaits.
    public func saveProviderModelLimits(_ limits: ProviderModelLimits) throws {
        try limits.validate()
        try runOnDatabase { db in
            try db.execute(sql: """
                INSERT INTO provider_model_limits(provider_id, model, context_window, runtime_context, max_output_tokens, source)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(provider_id, model) DO UPDATE SET
                  context_window = excluded.context_window, runtime_context = excluded.runtime_context,
                  max_output_tokens = excluded.max_output_tokens, source = excluded.source
                WHERE provider_model_limits.source <> 'user' OR excluded.source = 'user'
                """, arguments: [limits.providerId, limits.model, limits.contextWindow,
                                   limits.runtimeContext, limits.maxOutputTokens, limits.source])
        }
    }

    public func deleteProviderModelLimits(providerId: String, model: String) throws {
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM provider_model_limits WHERE provider_id = ? AND model = ?",
                           arguments: [providerId, model])
        }
    }
}
