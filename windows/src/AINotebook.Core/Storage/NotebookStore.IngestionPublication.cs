using System.Globalization;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Fenced folder publication (WP6 Task 13): revision, chunks, immutable page map, source metadata and
/// the generation work it implies commit in one immediate transaction or not at all.
/// </summary>
public sealed partial class NotebookStore
{
    /// <summary>Test seam: invoked at named stages inside the publication transaction (fault injection).</summary>
    internal Action<string>? PublicationFault { get; set; }

    /// <summary>
    /// Publishes a completed folder extraction for the claimed job. Returns null without any metadata or
    /// chunk change when the fence, expected revision, observation stamp, rules or eligibility no longer
    /// match; a superseded current owner is cancelled. No embedding selection still publishes lexically.
    /// </summary>
    public SourceRevision? PublishFolderExtraction(ExtractionRequest request, RevisionDraft draft,
        IReadOnlyList<RevisionChunkDraft> chunks, PublicationMetadata metadata, EmbeddingSelection? embeddingSelection,
        JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(chunks);
        ArgumentNullException.ThrowIfNull(metadata);
        ArgumentNullException.ThrowIfNull(fence);
        SourceRevision? revision;
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
            if (job is null || job.Draft.Kind != "extract" || job.Draft.Target != SourceTarget(request.SourceId)) return null;
            var source = _conn.QuerySingleOrDefault("""
                SELECT notebook_id,folder_id,rel_path,availability,eligible,current_revision,mtime,size_bytes
                FROM sources WHERE id=$id
                """, new { id = request.SourceId }, tx);
            var folder = source?.folder_id is null ? null : LoadFolder(tx, (long)source!.folder_id);
            bool matches = source is not null && folder is not null && folder.Id == request.FolderId &&
                (string?)source.rel_path == request.RelPath && (string)source.availability == "present" &&
                (long)source.eligible == 1 && (long?)source.current_revision == job.Draft.TargetRevision &&
                (long?)source.mtime == request.Stamp.MtimeNs && (long?)source.size_bytes == request.Stamp.SizeBytes &&
                FolderRulesOf(folder).Equals(request.Rules);
            if (!matches)
            {
                // The current owner was superseded (new observation, rules, eligibility or removal).
                RevisionJobSQL.CancelJob(_conn, tx, fence, now);
                tx.Commit();
                return null;
            }
            notebookId = (long)source!.notebook_id;
            revision = RevisionJobSQL.CommitExtraction(_conn, tx, request.SourceId, draft, chunks, fence, now);
            if (revision is null)
            {
                tx.Commit(); // CommitExtraction may have cancelled a stale owner; nothing was published.
                return null;
            }
            InsertRevisionPages(tx, revision, metadata.Pages);
            PublicationFault?.Invoke("after-pages");
            _conn.Execute("""
                UPDATE sources SET content_hash=$hash,mtime=$mtime,size_bytes=$size,encoding=$encoding,lang=$lang,
                    lang_coverage=$coverage,descriptor=$descriptor,last_synced_at=$synced WHERE id=$id
                """, new
            {
                id = request.SourceId, hash = draft.ContentHash, mtime = request.Stamp.MtimeNs, size = request.Stamp.SizeBytes,
                encoding = metadata.Encoding, lang = metadata.Lang, coverage = metadata.CoverageJSON, descriptor = metadata.DescriptorJSON,
                synced = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime)
            }, tx);
            if (embeddingSelection is not null)
                IngestionGenerationSQL.QueueEmbedding(_conn, tx, notebookId, embeddingSelection, copyExisting: true, now);
            PublicationFault?.Invoke("after-embed-enqueue");
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return revision;
    }

    /// <summary>
    /// Loose-file sibling of <see cref="PublishFolderExtraction"/>: same fenced revision, chunks, page map, metadata and
    /// embedding enqueue in one transaction, without folder stat/rule checks. Lease and current-pointer checks remain.
    /// </summary>
    public SourceRevision? PublishLooseExtraction(long sourceId, RevisionDraft draft, IReadOnlyList<RevisionChunkDraft> chunks,
        PublicationMetadata metadata, EmbeddingSelection? embeddingSelection, JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ArgumentNullException.ThrowIfNull(chunks);
        ArgumentNullException.ThrowIfNull(metadata);
        ArgumentNullException.ThrowIfNull(fence);
        SourceRevision? revision;
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
            if (job is null || job.Draft.Kind != "extract" || job.Draft.Target != SourceTarget(sourceId)) return null;
            long? owner = _conn.QuerySingleOrDefault<long?>("SELECT notebook_id FROM sources WHERE id=$sourceId", new { sourceId }, tx);
            if (owner is not long notebook) return null;
            notebookId = notebook;
            revision = RevisionJobSQL.CommitExtraction(_conn, tx, sourceId, draft, chunks, fence, now);
            if (revision is null)
            {
                tx.Commit();
                return null;
            }
            InsertRevisionPages(tx, revision, metadata.Pages);
            _conn.Execute("""
                UPDATE sources SET content_hash=$hash,encoding=$encoding,lang=$lang,lang_coverage=$coverage,descriptor=$descriptor,
                    last_synced_at=$synced WHERE id=$sourceId
                """, new
            {
                sourceId, hash = draft.ContentHash, encoding = metadata.Encoding, lang = metadata.Lang, coverage = metadata.CoverageJSON,
                descriptor = metadata.DescriptorJSON, synced = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime)
            }, tx);
            if (embeddingSelection is not null)
                IngestionGenerationSQL.QueueEmbedding(_conn, tx, notebookId, embeddingSelection, copyExisting: true, now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return revision;
    }

    /// <summary>
    /// Chat bridge for a typed scope: null for the whole notebook; otherwise the present, eligible sources of this
    /// notebook that are selected explicitly or currently belong to a selected folder (possibly empty).
    /// </summary>
    public IReadOnlySet<long>? ChatSourceIds(long notebookId, AINotebook.Core.Rag.RetrievalScope scope)
    {
        ArgumentNullException.ThrowIfNull(scope);
        if (scope is AINotebook.Core.Rag.RetrievalScope.All) return null;
        var selection = (AINotebook.Core.Rag.RetrievalScope.Selection)scope;
        if (selection.IsEmptySelection) return new HashSet<long>();
        var args = new DynamicParameters(new { notebookId });
        string Bind(IEnumerable<long> ids, string prefix)
        {
            var names = ids.Select((id, i) => { args.Add(prefix + i, id); return "$" + prefix + i; }).ToArray();
            return names.Length == 0 ? "NULL" : string.Join(",", names);
        }
        string sources = Bind(selection.SourceIds, "s");
        string folders = Bind(selection.FolderIds, "f");
        lock (_gate)
            return _conn.Query<long>($"""
                SELECT id FROM sources WHERE notebook_id=$notebookId AND availability='present' AND eligible=1
                  AND (id IN ({sources}) OR folder_id IN ({folders}))
                """, args).ToHashSet();
    }

    /// <summary>Cancels the folder's scan jobs and its sources' extraction work (removal, before row deletion).</summary>
    public int CancelFolderJobs(long folderId)
    {
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            int cancelled = _conn.Execute("""
                UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE ((kind='scan' AND target=$target) OR (kind='extract' AND target IN
                    (SELECT 'source:'||id FROM sources WHERE folder_id=$folderId)))
                  AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))
                """, new { folderId, target = FolderTarget(folderId) }, tx);
            tx.Commit();
            return cancelled;
        }
    }

    /// <summary>True while the folder has queued, running, paused or retryable scan/extract work.</summary>
    public bool FolderHasPendingWork(long folderId)
    {
        lock (_gate)
            return _conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM ingest_jobs
                  WHERE ((kind='scan' AND target=$target) OR (kind='extract' AND target IN
                      (SELECT 'source:'||id FROM sources WHERE folder_id=$folderId)))
                    AND (state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL)))
                """, new { folderId, target = FolderTarget(folderId) });
    }

    /// <summary>
    /// Whether the selected embedding space lacks coverage of the notebook's eligible published revisions: no matching
    /// active generation, or a published revision not done in it, and no outstanding embed work already queued.
    /// </summary>
    public bool NeedsEmbeddingWork(long notebookId, EmbeddingSelection selection)
    {
        ArgumentNullException.ThrowIfNull(selection);
        lock (_gate)
        {
            if (_conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM ingest_jobs j WHERE j.kind='embed' AND j.state IN ('queued','running','paused')
                  AND (j.target='notebook:'||$notebookId OR j.target IN
                      (SELECT 'generation:'||g.id FROM index_generations g WHERE g.notebook_id=$notebookId AND g.state='building')))
                """, new { notebookId }))
                return false;
            bool anyPublished = _conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM sources WHERE notebook_id=$notebookId AND availability='present' AND eligible=1
                  AND published_revision_id IS NOT NULL)
                """, new { notebookId });
            if (!anyPublished) return false;
            long? active = _conn.QuerySingleOrDefault<long?>(
                "SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'", new { notebookId });
            var generation = active is long id ? GenerationSQL.Read(_conn, null, id) : null;
            if (generation is null || !IngestionGenerationSQL.SameSpace(selection, new EmbeddingSelection(generation.Identity.ProviderId,
                    generation.Identity.EndpointRevision, generation.Identity.Model, generation.Identity.ModelDigest, generation.Identity.Dims,
                    generation.Identity.Normalization, generation.Identity.QueryFormatVersion, generation.Identity.DocFormatVersion,
                    generation.Identity.ChunkerVersion)))
                return true;
            return _conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM sources s WHERE s.notebook_id=$notebookId AND s.availability='present' AND s.eligible=1
                  AND s.published_revision_id IS NOT NULL AND NOT EXISTS(SELECT 1 FROM index_generation_manifest m
                    WHERE m.generation_id=$generationId AND m.source_id=s.id AND m.revision_id=s.published_revision_id AND m.state='done'))
                """, new { notebookId, generationId = generation.Id });
        }
    }

    /// <summary>
    /// Changed-during-extraction: cancels only this owner, marks the source pending and queues one fresh
    /// expected-current extraction, atomically. An expired or replaced owner changes nothing.
    /// </summary>
    public bool RequestFreshExtraction(long sourceId, JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(fence);
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
            if (job is null || job.Draft.Kind != "extract" || job.Draft.Target != SourceTarget(sourceId)) return false;
            var source = _conn.QuerySingleOrDefault("SELECT notebook_id,current_revision FROM sources WHERE id=$sourceId",
                new { sourceId }, tx);
            if (source is null || !RevisionJobSQL.CancelJob(_conn, tx, fence, now)) return false;
            notebookId = (long)source.notebook_id;
            _conn.Execute("""
                UPDATE sources SET status='pending',error=NULL WHERE id=$sourceId AND current_revision IS $revision
                """, new { sourceId, revision = job.Draft.TargetRevision }, tx);
            long id = RevisionJobSQL.EnqueueJob(_conn, tx,
                new IngestJobDraft("extract", SourceTarget(sourceId), (long?)source.current_revision), now);
            _conn.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$id", new { id }, tx);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return true;
    }

    private void InsertRevisionPages(SqliteTransaction tx, SourceRevision revision, IReadOnlyList<PageBoundary> pages)
    {
        int scalars = revision.Draft.CanonicalText.EnumerateRunes().Count();
        int previous = 0;
        foreach (var page in pages)
        {
            // Strict exact intervals: ascending unique pages within the canonical scalar range.
            if (page.Page <= previous || page.Start < 0 || page.End < page.Start || page.End > scalars)
                throw new StorageV19Exception("invalidSpan");
            previous = page.Page;
            _conn.Execute("""
                INSERT INTO revision_pages(revision_id,page,char_start,char_end) VALUES($revisionId,$page,$start,$end)
                """, new { revisionId = revision.Id, page = page.Page, start = page.Start, end = page.End }, tx);
        }
    }
}

/// <summary>Generation work implied by publication. Transaction kernels: the caller holds the gate and transaction.</summary>
internal static class IngestionGenerationSQL
{
    private static readonly JsonSerializerOptions OptionsJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    private const string OutstandingEmbed = "(state IN ('queued','running','paused') OR (state='failed' AND next_retry_at IS NOT NULL))";

    /// <summary>
    /// Incremental ingestion reuses an identical building generation (reconciled, no further copy); an explicit
    /// reindex (<paramref name="copyExisting"/> false) retires prior building work for the same notebook/identity
    /// and creates a fresh one. Unchanged vectors are copied only into a newly created successor and only from an
    /// active generation with an identical identity.
    /// </summary>
    internal static IndexGeneration EnsureBuilding(SqliteConnection c, SqliteTransaction tx, long notebookId,
        GenerationIdentity identity, bool copyExisting, long now)
    {
        var building = c.Query<long>("""
            SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='building' ORDER BY id
            """, new { notebookId }, tx).Select(id => GenerationSQL.Read(c, tx, id)!).Where(g => g.Identity == identity).ToArray();
        if (copyExisting && building.Length > 0)
        {
            var reused = building[^1];
            GenerationSQL.Reconcile(c, tx, reused.Id);
            MarkCompleteManifest(c, tx, reused.Id);
            return reused;
        }
        foreach (var stale in building)
        {
            CancelEmbedJobs(c, tx, "generation:" + stale.Id.ToString(CultureInfo.InvariantCulture), null);
            c.Execute("UPDATE index_generations SET state='retired' WHERE id=$id AND state='building'", new { id = stale.Id }, tx);
        }
        var generation = GenerationSQL.Create(c, tx, notebookId, identity, now);
        if (copyExisting)
        {
            long? active = c.QuerySingleOrDefault<long?>(
                "SELECT id FROM index_generations WHERE notebook_id=$notebookId AND state='active'", new { notebookId }, tx);
            if (active is long from && GenerationSQL.Read(c, tx, from)!.Identity == identity)
                GenerationSQL.CopyUnchangedVectors(c, tx, from, generation.Id, null);
        }
        return generation;
    }

    /// <summary>
    /// Queues (or coalesces with outstanding) embedding work for a selection: a generation-target job when dimensions
    /// are verified or adopted from a building/active generation of the same space (<c>ingestion-build-merge-v1</c> §2),
    /// otherwise one notebook-target bootstrap job (coalesced only with identical queued options). A generation job
    /// supersedes the unclaimed incremental bootstraps of its space (§3). Options hold only the nonsecret selection and
    /// copy flag. Returns the job ID.
    /// </summary>
    internal static long QueueEmbedding(SqliteConnection c, SqliteTransaction tx, long notebookId, EmbeddingSelection requested,
        bool copyExisting, long now)
    {
        var selection = EmbedJobPlanning.ResolveBuild(requested, copyExisting, NotebookStore.GenerationSnapshots(c, tx, notebookId))
            is { } adopted ? EmbedJobPlanning.ToSelection(adopted.Identity) : requested;
        string options = JsonSerializer.Serialize(new EmbedOptions(selection, copyExisting), OptionsJson);
        string target;
        long? existing;
        if (selection.Dims is int dims)
        {
            var identity = Identity(selection, dims);
            target = "generation:" + EnsureBuilding(c, tx, notebookId, identity, copyExisting, now).Id
                .ToString(CultureInfo.InvariantCulture);
            // One embed job per generation: no second job while one is queued, paused or running.
            existing = c.QuerySingleOrDefault<long?>("""
                SELECT id FROM ingest_jobs WHERE kind='embed' AND target=$target AND state IN ('queued','paused','running')
                ORDER BY id LIMIT 1
                """, new { target }, tx);
            var bootstraps = c.Query("""
                SELECT id,target,state,attempts,next_retry_at,error,options_json FROM ingest_jobs
                WHERE kind='embed' AND target=$bootstrap AND state IN ('queued','paused','failed') ORDER BY id
                """, new { bootstrap = "notebook:" + notebookId.ToString(CultureInfo.InvariantCulture) }, tx)
                .Select(row => NotebookStore.EmbedJobSnapshotOf(row)).Cast<EmbedJobSnapshot>().ToArray();
            CompleteBootstraps(c, tx, EmbedJobPlanning.Superseded(identity, bootstraps));
        }
        else
        {
            target = "notebook:" + notebookId.ToString(CultureInfo.InvariantCulture);
            existing = c.Query("SELECT id,options_json FROM ingest_jobs WHERE kind='embed' AND target=$target AND state IN ('queued','running')",
                    new { target }, tx)
                .Where(row => ReadOptions((string)row.options_json) is { } saved && saved.Selection == selection && saved.CopyExisting == copyExisting)
                .Select(row => (long?)(long)row.id).FirstOrDefault();
        }
        if (existing is long id) return id;
        long created = RevisionJobSQL.EnqueueJob(c, tx, new IngestJobDraft("embed", target, null, options), now);
        c.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$created", new { created }, tx);
        return created;
    }

    /// <summary>
    /// A pending entry is done once every embeddable chunk of its published revision has a vector (an empty revision
    /// trivially); capped spreadsheet chunks stay full-text only (<c>embedding-plan-v1</c> §3).
    /// </summary>
    internal static void MarkCompleteManifest(SqliteConnection c, SqliteTransaction tx, long generationId)
    {
        long dims = GenerationSQL.Read(c, tx, generationId)!.Identity.Dims;
        c.Execute($"""
            UPDATE index_generation_manifest SET state='done',reason=NULL
            WHERE generation_id=$generationId AND state='pending'
              AND EXISTS(SELECT 1 FROM sources s WHERE s.id=index_generation_manifest.source_id
                AND s.published_revision_id=index_generation_manifest.revision_id AND s.availability='present' AND s.eligible=1)
              AND NOT EXISTS(SELECT 1 FROM sources s JOIN source_chunks c ON c.revision_id=index_generation_manifest.revision_id
                WHERE s.id=index_generation_manifest.source_id AND {EmbeddingPlan.EmbeddableSql}
                AND NOT EXISTS(SELECT 1 FROM chunk_embeddings e WHERE e.chunk_id=c.id AND e.generation_id=$generationId
                  AND length(e.embedding)=$bytes))
            """, new { generationId, bytes = dims * sizeof(float) }, tx);
    }

    /// <summary>Completes unclaimed bootstraps as no-ops (<c>ingestion-build-merge-v1</c> §3); a claimed job is never touched.</summary>
    internal static void CompleteBootstraps(SqliteConnection c, SqliteTransaction tx, IReadOnlyList<long> ids)
    {
        foreach (long id in ids)
            c.Execute("""
                UPDATE ingest_jobs SET state='done',error=NULL,next_retry_at=NULL,lease_until=NULL,lease_token=NULL
                WHERE id=$id AND kind='embed' AND target LIKE 'notebook:%' AND state<>'running'
                """, new { id }, tx);
    }

    internal static void CancelEmbedJobs(SqliteConnection c, SqliteTransaction tx, string target, long? onlyJobId) => c.Execute($"""
        UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
        WHERE kind='embed' AND target=$target AND ($onlyJobId IS NULL OR id=$onlyJobId) AND {OutstandingEmbed}
        """, new { target, onlyJobId }, tx);

    internal static GenerationIdentity Identity(EmbeddingSelection selection, int dims) => new(selection.ProviderId,
        selection.EndpointRevision, selection.Model, selection.ModelDigest, dims, selection.Normalization,
        selection.QueryFormatVersion, selection.DocFormatVersion, selection.ChunkerVersion);

    /// <summary>Same vector space: every field equal except an unknown dimension on either side.</summary>
    internal static bool SameSpace(EmbeddingSelection a, EmbeddingSelection b) =>
        a with { Dims = null } == b with { Dims = null } && (a.Dims is null || b.Dims is null || a.Dims == b.Dims);

    internal static EmbedOptions? ReadOptions(string json)
    {
        try { return JsonSerializer.Deserialize<EmbedOptions>(json, OptionsJson) is { Selection: not null } options ? options : null; }
        catch (JsonException) { return null; }
    }

    internal static string SerializeOptions(EmbeddingSelection selection, bool copyExisting) =>
        JsonSerializer.Serialize(new EmbedOptions(selection, copyExisting), OptionsJson);

    internal sealed record EmbedOptions(EmbeddingSelection Selection, bool CopyExisting);
}
