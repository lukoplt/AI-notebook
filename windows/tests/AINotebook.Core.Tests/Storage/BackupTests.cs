using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// BackupTo used to run `PRAGMA wal_checkpoint(FULL)` then File.Copy the
/// database file. journal_mode is never set to WAL anywhere in this app, so the
/// checkpoint was a no-op, and copying a live database file can capture a torn
/// write. It also could not back up the in-memory store at all. SQLite's
/// online-backup API snapshots under a read transaction instead.
///
/// These tests use the in-memory store deliberately: `VACUUM INTO`, the obvious
/// alternative, silently produces no file at all for an in-memory source.
/// </summary>
public class BackupTests
{
    [Fact]
    public void BackupProducesAReadableCopyOfTheData()
    {
        var dest = Path.Combine(Path.GetTempPath(), $"aino-backup-{Guid.NewGuid():N}.sqlite");
        try
        {
            using (var store = new NotebookStore(StorePath.InMemory))
            {
                store.CreateNotebook("Kept", "desc");
                store.BackupTo(dest);
            }

            Assert.True(File.Exists(dest));

            using var restored = new NotebookStore(new StorePath(dest));
            Assert.Contains(restored.Notebooks(), n => n.Name == "Kept");
        }
        finally
        {
            if (File.Exists(dest)) File.Delete(dest);
        }
    }

    [Fact]
    public void BackupOverwritesAnExistingDestination()
    {
        var dest = Path.Combine(Path.GetTempPath(), $"aino-backup-{Guid.NewGuid():N}.sqlite");
        try
        {
            // VACUUM INTO refuses a destination that already exists, so the
            // file the picker hands us must be removed first.
            File.WriteAllText(dest, "stale");

            using (var store = new NotebookStore(StorePath.InMemory))
            {
                store.CreateNotebook("Fresh", "");
                store.BackupTo(dest);
            }

            using var restored = new NotebookStore(new StorePath(dest));
            Assert.Contains(restored.Notebooks(), n => n.Name == "Fresh");
        }
        finally
        {
            if (File.Exists(dest)) File.Delete(dest);
        }
    }
}
