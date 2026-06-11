using AINotebook.Core.Models;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// E1: Monitors a local folder and re-ingests files that are created or modified.
/// Call Enable() to start watching; Disable() or Dispose() to stop.
/// </summary>
public sealed class FolderWatchService : IDisposable
{
    private readonly NotebookStore _store;
    private readonly IngestionService _ingestion;
    private FileSystemWatcher? _watcher;
    private long _notebookId;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public bool IsActive => _watcher is { EnableRaisingEvents: true };
    public string? WatchedFolder { get; private set; }

    public FolderWatchService(NotebookStore store, IngestionService ingestion)
    {
        _store = store;
        _ingestion = ingestion;
    }

    public void Enable(long notebookId, string folder)
    {
        Disable();
        _notebookId = notebookId;
        WatchedFolder = folder;

        _watcher = new FileSystemWatcher(folder)
        {
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
            IncludeSubdirectories = false,
            EnableRaisingEvents = true
        };
        _watcher.Created += OnFileEvent;
        _watcher.Changed += OnFileEvent;
    }

    public void Disable()
    {
        if (_watcher is null) return;
        _watcher.EnableRaisingEvents = false;
        _watcher.Created -= OnFileEvent;
        _watcher.Changed -= OnFileEvent;
        _watcher.Dispose();
        _watcher = null;
        WatchedFolder = null;
    }

    private void OnFileEvent(object _, FileSystemEventArgs e)
    {
        var ext = Path.GetExtension(e.FullPath).TrimStart('.').ToLowerInvariant();
        var type = SourceTypeExtensions.Detect(e.Name ?? "");
        if (type is null) return;

        _ = Task.Run(async () =>
        {
            // Debounce: wait briefly so the file write completes.
            await Task.Delay(500);
            await _gate.WaitAsync();
            try
            {
                var existing = _store.SourcesIncludingShadow(_notebookId)
                    .FirstOrDefault(s => s.RawPath == e.FullPath);

                if (existing is not null)
                {
                    // Already ingested — check content hash to skip unchanged files.
                    var hash = await ComputeHashAsync(e.FullPath);
                    if (hash == existing.ContentHash) return;
                    await _ingestion.ReIngestAsync(existing.Id!.Value, CancellationToken.None);
                    _store.UpdateSourceSyncInfo(existing.Id.Value, DateTime.UtcNow, hash);
                }
                else
                {
                    var title = Path.GetFileNameWithoutExtension(e.Name ?? e.FullPath);
                    var source = _store.CreateSource(_notebookId, type.Value, title, null, e.FullPath);
                    await _ingestion.ReIngestAsync(source.Id!.Value, CancellationToken.None);
                    var hash = await ComputeHashAsync(e.FullPath);
                    _store.UpdateSourceSyncInfo(source.Id.Value, DateTime.UtcNow, hash);
                }
            }
            catch
            {
                // Swallow — file may be locked; next change event will retry.
            }
            finally
            {
                _gate.Release();
            }
        });
    }

    private static async Task<string> ComputeHashAsync(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var hash = await System.Security.Cryptography.MD5.HashDataAsync(fs);
        return Convert.ToHexString(hash);
    }

    public void Dispose() => Disable();
}
