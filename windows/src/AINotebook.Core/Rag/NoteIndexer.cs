using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Rag;

public sealed class NoteIndexer
{
    private readonly NotebookStore _store;
    private readonly Func<Task>? _onChunksWritten;
    private readonly IIngestLeaseClock _leaseClock;

    public NoteIndexer(NotebookStore store, Func<Task>? onChunksWritten = null, IIngestLeaseClock? leaseClock = null)
    {
        _store = store;
        _onChunksWritten = onChunksWritten;
        _leaseClock = leaseClock ?? new SystemIngestLeaseClock();
    }

    public async Task IndexAsync(long noteId, CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        long sourceId;
        string title, body;
        JobFence fence;
        lock (_store.Gate)
        {
            // Capture the note and claim its shadow together, so another connection cannot
            // create a duplicate shadow or claim newer text before this snapshot is fenced.
            using var tx = _store.Connection.BeginTransaction(deferred: false);
            var note = _store.Connection.QuerySingleOrDefault(
                "SELECT notebook_id,title,body_md,auto_source_id FROM notes WHERE id=$noteId", new { noteId }, tx)
                ?? throw new StoreException.SourceNotFound(noteId);
            title = (string)note.title;
            body = (string)note.body_md;
            long? existing = (long?)note.auto_source_id;
            if (existing is long id && _store.Connection.ExecuteScalar<bool>(
                "SELECT EXISTS(SELECT 1 FROM sources WHERE id=$id)", new { id }, tx))
                sourceId = id;
            else
            {
                sourceId = _store.Connection.ExecuteScalar<long>("""
                    INSERT INTO sources(notebook_id,type,title,status,ingested_at)
                    VALUES($notebookId,'note',$title,'pending',$created); SELECT last_insert_rowid();
                    """, new { notebookId = (long)note.notebook_id, title,
                        created = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(_leaseClock.Now).UtcDateTime) }, tx);
                _store.Connection.Execute("UPDATE notes SET auto_source_id=$sourceId WHERE id=$noteId", new { sourceId, noteId }, tx);
            }
            fence = RevisionJobSQL.BeginExtraction(_store.Connection, tx, sourceId, _leaseClock.Now, Guid.NewGuid().ToString("N"));
            tx.Commit();
        }

        await using var renewal = new ExtractionLeaseRenewal(_store, fence, _leaseClock, ct);
        bool published;
        try
        {
            ct.ThrowIfCancellationRequested();
            var chunks = ScalarChunker.Chunk(body);
            var draft = new RevisionDraft(IngestionService.ContentHash(body), body, 1, 2);
            await renewal.StopAsync().ConfigureAwait(false);
            ct.ThrowIfCancellationRequested();
            lock (_store.Gate)
            {
                using var tx = _store.Connection.BeginTransaction(deferred: false);
                long now = _leaseClock.Now;
                // A captured note may have changed before its indexing hook began. Such a
                // snapshot must not publish or replace the newer shadow title.
                bool unchanged = _store.Connection.ExecuteScalar<bool>("""
                    SELECT EXISTS(SELECT 1 FROM notes WHERE id=$noteId AND auto_source_id=$sourceId
                      AND title=$title AND body_md=$body)
                    """, new { noteId, sourceId, title, body }, tx);
                if (!unchanged)
                {
                    RevisionJobSQL.CancelJob(_store.Connection, tx, fence, now);
                    published = false;
                }
                else
                {
                    var revision = RevisionJobSQL.CommitExtraction(_store.Connection, tx, sourceId, draft, chunks, fence, now);
                    published = revision is not null;
                    if (published)
                        _store.Connection.Execute("UPDATE sources SET title=$title,last_synced_at=$at WHERE id=$sourceId",
                            new { sourceId, title, at = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime) }, tx);
                }
                tx.Commit();
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            _store.CancelJob(fence, _leaseClock.Now);
            throw;
        }
        catch (Exception error)
        {
            _store.FailJob(fence, error.ToString(), _leaseClock.Now);
            throw;
        }

        if (published && _onChunksWritten is not null) await _onChunksWritten().ConfigureAwait(false);
    }
}
