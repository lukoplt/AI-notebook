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
        var connStr = path.IsInMemory
            ? $"Data Source=InMemoryAINotebook-{Guid.NewGuid():N};Mode=Memory;Cache=Private"
            : $"Data Source={path.FilePath}";
        _conn = new SqliteConnection(connStr);
        _conn.Open();
        Execute("PRAGMA foreign_keys=ON");
        Migrator.Migrate(_conn);
        BuiltinTransformations.SeedIfNeeded(_conn, _language);
    }

    /// <summary>Test/internal affordance: access the open connection.</summary>
    internal SqliteConnection Connection => _conn;

    private int Execute(string sql, object? param = null) => _conn.Execute(sql, param);

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

    public void Dispose() => _conn.Dispose();

    // ---- Notebooks ----

    public Notebook CreateNotebook(string name, string description = "")
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

    public IReadOnlyList<Notebook> Notebooks()
    {
        return _conn.Query(
            "SELECT id, name, description, created_at, updated_at FROM notebooks ORDER BY updated_at DESC")
            .Select(r => new Notebook(
                (long)r.id, (string)r.name, (string)r.description,
                SqliteDate.FromDb((string)r.created_at), SqliteDate.FromDb((string)r.updated_at)))
            .ToList();
    }

    public Notebook RenameNotebook(long id, string newName)
    {
        var trimmed = newName.Trim();
        if (trimmed.Length == 0) throw new StoreException.InvalidNotebookName(newName);
        var now = Now();
        var rows = _conn.Execute(
            "UPDATE notebooks SET name=$name, updated_at=$updated WHERE id=$id",
            new { name = trimmed, updated = SqliteDate.ToDb(now), id });
        if (rows == 0) throw new StoreException.NotebookNotFound(id);
        var row = _conn.QuerySingle(
            "SELECT id, name, description, created_at, updated_at FROM notebooks WHERE id=$id", new { id });
        return new Notebook((long)row.id, (string)row.name, (string)row.description,
            SqliteDate.FromDb((string)row.created_at), SqliteDate.FromDb((string)row.updated_at));
    }

    public void DeleteNotebook(long id)
    {
        var rows = _conn.Execute("DELETE FROM notebooks WHERE id=$id", new { id });
        if (rows == 0) throw new StoreException.NotebookNotFound(id);
    }
}
