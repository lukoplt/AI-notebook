import Foundation
import GRDB

extension NotebookStore {
    public func evidenceBudgetCap(notebookId: Int64) throws -> Int? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT evidence_budget_cap FROM notebooks WHERE id=?",
                                            arguments: [notebookId]) else {
                throw StorageV19Error.notFound
            }
            return row["evidence_budget_cap"]
        }
    }

    @MainActor public func setEvidenceBudgetCap(notebookId: Int64, value: Int?) throws {
        guard value.map({ $0 >= 0 }) ?? true else { throw StorageV19Error.invalidValue }
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notebooks WHERE id=?)",
                                    arguments: [notebookId]) == true else {
                throw StorageV19Error.notFound
            }
            try db.execute(sql: "UPDATE notebooks SET evidence_budget_cap=? WHERE id=?",
                           arguments: [value, notebookId])
        }
        try refresh()
    }

    public func modelLimits(providerId: String, model: String) throws -> ProviderModelLimits? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT provider_id,model,context_window,runtime_context,max_output_tokens,source
                FROM provider_model_limits WHERE provider_id=? AND model=?
                """, arguments: [providerId, model]) else { return nil }
            return ProviderModelLimits(providerId: row["provider_id"], model: row["model"],
                                       contextWindow: row["context_window"], runtimeContext: row["runtime_context"],
                                       maxOutputTokens: row["max_output_tokens"], source: row["source"])
        }
    }

    public func setModelLimits(_ limits: ProviderModelLimits) throws {
        guard !limits.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              limits.runtimeContext > 0, limits.maxOutputTokens > 0,
              limits.maxOutputTokens < limits.runtimeContext,
              limits.contextWindow.map({ $0 > 0 && limits.runtimeContext <= $0 }) ?? true,
              ["auto", "user"].contains(limits.source) else {
            throw StorageV19Error.invalidValue
        }
        try dbQueue.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM providers WHERE id=?)",
                                    arguments: [limits.providerId]) == true else {
                throw StorageV19Error.notFound
            }
            try db.execute(sql: """
                INSERT INTO provider_model_limits(provider_id,model,context_window,runtime_context,max_output_tokens,source)
                VALUES(?,?,?,?,?,?)
                ON CONFLICT(provider_id,model) DO UPDATE SET context_window=excluded.context_window,
                    runtime_context=excluded.runtime_context,max_output_tokens=excluded.max_output_tokens,
                    source=excluded.source
                """, arguments: [limits.providerId, limits.model, limits.contextWindow,
                                   limits.runtimeContext, limits.maxOutputTokens, limits.source])
        }
    }
}
