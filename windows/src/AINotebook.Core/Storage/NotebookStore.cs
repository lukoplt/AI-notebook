using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Owns the SQLite connection and exposes CRUD. In-memory uses one kept-open
/// connection for the store lifetime; production opens the file DB. Runs
/// PRAGMA foreign_keys=ON, the Migrator, and seeds builtin transformations.
/// </summary>
public sealed partial class NotebookStore : IDisposable
{
    private readonly SqliteConnection _conn;
    private readonly AppLanguage _language;

    /// <summary>
    /// Serializes every use of <see cref="_conn"/>. Microsoft.Data.Sqlite's
    /// SqliteConnection is NOT thread-safe, and this store deliberately keeps
    /// exactly one connection for its whole lifetime (see the constructor) —
    /// yet it is used concurrently: EmbeddingWorker drains on a thread-pool
    /// thread, FolderWatchService ingests on another, the ViewModels wrap most
    /// calls in Task.Run, and Retriever queries from async continuations.
    /// Without this gate those overlap on one connection and fault at random.
    ///
    /// macOS has no equivalent because GRDB's DatabaseQueue already serializes
    /// all access; the C# port lost that guarantee and this restores it.
    ///
    /// Monitor is re-entrant, so a store method calling another store method
    /// on the same thread is fine. The lock is held for the whole of each
    /// public method — not per statement — so compound read-then-write methods
    /// stay atomic against each other.
    /// </summary>
    private readonly object _gate = new();

    /// <summary>
    /// The same gate, for the two in-assembly collaborators that reach for
    /// <see cref="Connection"/> directly instead of going through a store
    /// method (Retriever's FTS/snippet queries and AttachmentStore's row
    /// writes). They must hold it for the duration of their command.
    /// </summary>
    internal object Gate => _gate;

    /// <summary>Fires after createNote/updateNote with the affected note id.</summary>
    public Func<long, Task>? OnNoteSaved { get; set; }

    /// <summary>Fires after a note is deleted, with the note's UUID.</summary>
    public Func<string, Task>? OnNoteDeleted { get; set; }

    public NotebookStore(StorePath path, AppLanguage language = AppLanguage.English)
    {
        _language = language;
        // In-memory uses a connection-private DB (no shared cache) so each store
        // instance is isolated; the kept-open _conn keeps it alive for the store
        // lifetime. A unique name avoids the process-wide name collisions that a
        // shared-cache in-memory DB would cause across concurrent test stores.
        // Pooling=False on the file DB: this store keeps ONE long-lived connection
        // for its whole lifetime, so connection pooling buys nothing — and on
        // Windows a pooled handle keeps the .sqlite file locked after Dispose(),
        // which breaks reopening the same file (IOException "used by another
        // process"). Disabling pooling makes Dispose() release the file handle
        // immediately. (macOS file locking is lenient enough to mask this.)
        var connStr = path.IsInMemory
            ? $"Data Source=InMemoryAINotebook-{Guid.NewGuid():N};Mode=Memory;Cache=Private"
            : $"Data Source={path.FilePath};Pooling=False";
        _conn = new SqliteConnection(connStr);
        _conn.Open();
        Execute("PRAGMA foreign_keys=ON");
        Migrator.Migrate(_conn);
        BuiltinTransformations.SeedIfNeeded(_conn, _language);
    }

    /// <summary>Test/internal affordance: access the open connection.</summary>
    internal SqliteConnection Connection => _conn;

    private int Execute(string sql, object? param = null) => _conn.Execute(sql, param);

    /// <summary>
    /// B3: write a consistent snapshot of the database to destPath.
    ///
    /// Uses SQLite's online-backup API — the same mechanism macOS reaches
    /// through GRDB's `dbQueue.backup(to:)` — so the copy is taken under a read
    /// transaction and is always internally consistent.
    ///
    /// The previous implementation ran `PRAGMA wal_checkpoint(FULL)` and then
    /// File.Copy'd the database file, which was wrong twice over: journal_mode
    /// is never set to WAL anywhere in this app, so the checkpoint was a no-op,
    /// and a raw file copy of a live database can capture a torn write. It also
    /// could not back up the in-memory store at all (DataSource is not a path).
    ///
    /// `VACUUM INTO` would have been the smaller change, but it silently does
    /// nothing when the source database is in-memory — no exception, no file —
    /// which would have left the tests as the only thing standing between us
    /// and a backup button that reports success and writes nothing.
    ///
    /// The destination is opened through SqliteConnectionStringBuilder rather
    /// than string interpolation: this path comes from a save-file picker, so a
    /// filename containing ';' or '=' would otherwise corrupt the connection
    /// string. Pooling=False for the same reason as the main connection — it
    /// releases the file handle as soon as the connection is disposed.
    /// </summary>
    public void BackupTo(string destPath)
    {
        lock (_gate)
        {
            // The backup API appends into an existing destination rather than
            // replacing it, so clear whatever the picker pointed at first.
            if (File.Exists(destPath)) File.Delete(destPath);
            var connStr = new SqliteConnectionStringBuilder
            {
                DataSource = destPath,
                Pooling = false
            }.ToString();
            using var dest = new SqliteConnection(connStr);
            dest.Open();
            _conn.BackupDatabase(dest);
        }
    }

    // Swift's Date() stores sub-millisecond precision so created_at/updated_at
    // never collide; the SqliteDate TEXT format truncates to milliseconds, so
    // back-to-back writes could tie and make `ORDER BY updated_at DESC`
    // ambiguous. Hand out a strictly-increasing UTC timestamp (stepping by the
    // 1ms storage granularity) to preserve newest-first ordering.
    private DateTime _lastNow = DateTime.MinValue;
    private DateTime Now()
    {
        // Truncate to whole milliseconds (the SqliteDate storage resolution) so
        // the in-memory value matches the DB round-trip, then keep it strictly
        // increasing so newest-first ordering is deterministic.
        var now = DateTime.UtcNow;
        now = new DateTime(now.Ticks - (now.Ticks % TimeSpan.TicksPerMillisecond), DateTimeKind.Utc);
        if (now <= _lastNow) now = _lastNow.AddMilliseconds(1);
        _lastNow = now;
        return now;
    }

    public void Dispose()
    {
        lock (_gate) _conn.Dispose();
    }

    // ---- Notebooks ----

    public Notebook CreateNotebook(string name, string description = "")
    {
        lock (_gate)
        {
            var trimmed = name.Trim();
            if (trimmed.Length == 0) throw new StoreException.InvalidNotebookName(name);
            var now = Now();
            var id = _conn.ExecuteScalar<long>(
                """
                INSERT INTO notebooks(name, description, created_at, updated_at)
                VALUES($name, $desc, $created, $updated);
                SELECT last_insert_rowid();
                """,
                new { name = trimmed, desc = description, created = SqliteDate.ToDb(now), updated = SqliteDate.ToDb(now) });
            return new Notebook(id, trimmed, description, now, now);
        }
    }

    public IReadOnlyList<Notebook> Notebooks()
    {
        lock (_gate)
        {
            return _conn.Query(
                "SELECT id, name, description, created_at, updated_at, instructions FROM notebooks ORDER BY updated_at DESC")
                .Select(r => new Notebook(
                    (long)r.id, (string)r.name, (string)r.description,
                    SqliteDate.FromDb((string)r.created_at), SqliteDate.FromDb((string)r.updated_at),
                    r.instructions is null ? "" : (string)r.instructions))
                .ToList();
        }
    }

    public Notebook RenameNotebook(long id, string newName)
    {
        lock (_gate)
        {
            var trimmed = newName.Trim();
            if (trimmed.Length == 0) throw new StoreException.InvalidNotebookName(newName);
            var now = Now();
            var rows = _conn.Execute(
                "UPDATE notebooks SET name=$name, updated_at=$updated WHERE id=$id",
                new { name = trimmed, updated = SqliteDate.ToDb(now), id });
            if (rows == 0) throw new StoreException.NotebookNotFound(id);
            var row = _conn.QuerySingle(
                "SELECT id, name, description, created_at, updated_at, instructions FROM notebooks WHERE id=$id", new { id });
            return new Notebook((long)row.id, (string)row.name, (string)row.description,
                SqliteDate.FromDb((string)row.created_at), SqliteDate.FromDb((string)row.updated_at),
                row.instructions is null ? "" : (string)row.instructions);
        }
    }

    public void UpdateNotebookInstructions(long id, string instructions)
    {
        lock (_gate)
        {
            var now = Now();
            var rows = _conn.Execute(
                "UPDATE notebooks SET instructions=$ins, updated_at=$updated WHERE id=$id",
                new { ins = instructions, updated = SqliteDate.ToDb(now), id });
            if (rows == 0) throw new StoreException.NotebookNotFound(id);
        }
    }

    public void DeleteNotebook(long id)
    {
        lock (_gate)
        {
            var rows = _conn.Execute("DELETE FROM notebooks WHERE id=$id", new { id });
            if (rows == 0) throw new StoreException.NotebookNotFound(id);
        }
    }
}
