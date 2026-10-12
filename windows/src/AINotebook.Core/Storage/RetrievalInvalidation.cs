using System.Collections.Concurrent;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>Shared process epoch only; revision retention remains owned by WP3.</summary>
internal sealed class RetrievalInvalidation
{
    // Cache entries may outlive every connection. A file's epoch must never restart
    // while an old matrix can still carry its canonical database identity.
    private static readonly ConcurrentDictionary<string, RetrievalInvalidation> FileEntries = new(StringComparer.Ordinal);
    private static readonly ConcurrentDictionary<string, WeakReference<RetrievalInvalidation>> Entries = new(StringComparer.Ordinal);
    private static readonly object EntryGate = new();
    private long _epoch;
    internal ulong Epoch => unchecked((ulong)Volatile.Read(ref _epoch));
    internal void Changed() => Interlocked.Increment(ref _epoch);
    internal static RetrievalInvalidation For(string databaseId)
    {
        if (databaseId.StartsWith("file:", StringComparison.Ordinal))
            return FileEntries.GetOrAdd(databaseId, _ => new());
        lock (EntryGate)
        {
            if (Entries.TryGetValue(databaseId, out var weak) && weak.TryGetTarget(out var existing)) return existing;
            var created = new RetrievalInvalidation();
            Entries[databaseId] = new(created);
            // Do not retain one registry key per short-lived in-memory fixture forever.
            if (Entries.Count > 256)
                foreach (var pair in Entries)
                    if (!pair.Value.TryGetTarget(out _)) Entries.TryRemove(pair.Key, out _);
            return created;
        }
    }
}

public sealed partial class NotebookStore
{
    internal static readonly string[] RetrievalMutationTables =
    ["notebooks", "sources", "source_chunks", "source_revisions", "chunk_embeddings",
     "index_generations", "index_generation_manifest", "folder_sources", "source_set_members", "source_set_folders"];
    private RetrievalInvalidation _retrievalInvalidation = null!;
    private long _retrievalDataVersion, _retrievalTotalChanges;
    internal string RetrievalDatabaseId { get { lock (_gate) return GenerationDatabaseIdentity; } }
    internal Action<string>? RetrievalStatementExecuted { get; set; }
    internal ulong RetrievalObservedEpoch() => _retrievalInvalidation.Epoch;

    private void InstallRetrievalInvalidation()
    {
        // Called while constructing the connection under _gate, after migration.
        _retrievalInvalidation = RetrievalInvalidation.For(GenerationDatabaseIdentity);
        // A new connection cannot compare data_version against the closed interval.
        // Conservatively invalidate any matrix retained from an earlier connection.
        _retrievalInvalidation.Changed();
        _conn.CreateFunction("rag_retrieval_changed", () =>
        {
            _retrievalInvalidation.Changed();
            return 0;
        }, isDeterministic: false);
        foreach (string table in RetrievalMutationTables)
            foreach (string operation in new[] { "insert", "update", "delete" })
                _conn.Execute($"CREATE TEMP TRIGGER rag_{table}_{operation} AFTER {operation.ToUpperInvariant()} ON main.{table} BEGIN SELECT rag_retrieval_changed(); END;");
        _retrievalDataVersion = _conn.ExecuteScalar<long>("PRAGMA data_version");
        _retrievalTotalChanges = _conn.ExecuteScalar<long>("SELECT total_changes()");
    }

    internal ulong RefreshRetrievalEpoch(SqliteTransaction? transaction = null)
    {
        lock (_gate)
        {
            RetrievalStatementExecuted?.Invoke("PRAGMA data_version; SELECT total_changes()");
            long dataVersion = _conn.ExecuteScalar<long>("PRAGMA data_version", transaction: transaction);
            long totalChanges = _conn.ExecuteScalar<long>("SELECT total_changes()", transaction: transaction);
            if (dataVersion != _retrievalDataVersion || totalChanges != _retrievalTotalChanges)
            {
                _retrievalInvalidation.Changed();
                _retrievalDataVersion = dataVersion; _retrievalTotalChanges = totalChanges;
            }
            return _retrievalInvalidation.Epoch;
        }
    }
}
