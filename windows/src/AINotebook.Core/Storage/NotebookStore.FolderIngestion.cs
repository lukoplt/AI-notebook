using System.Globalization;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Fenced folder scan observations, completion and rule transactions (WP6 Task 9).
/// Every method validates the scan job's lease plus the folder's scan generation inside one
/// immediate transaction. File IO and hashing never happen here; the scanner performs them
/// outside the gate and hands the results in. Post-commit notifications fire after the gate
/// is released and never for a rejected fence or a rollback.
/// </summary>
public sealed partial class NotebookStore
{
    public event Action<long>? FolderIngestionChanged;

    /// <summary>
    /// Raised (notebook ID, after the gate is released) whenever a notebook's indexing status may have changed: after
    /// every <see cref="FolderIngestionChanged"/>, and additionally after job lifecycle changes (claim, fenced failure,
    /// lease recovery, retry requeue, cancellation, completion) and runtime start/scan outcomes, and for committed
    /// background embedding batches (coalesced: at most one per <see cref="IndexingProgressInterval"/> per notebook,
    /// plus one trailing raise). Observe this one for live indexing progress; it may fire on any thread.
    /// </summary>
    public event Action<long>? IndexingStatusChanged;

    private readonly object _progressGate = new();
    private readonly Dictionary<long, long> _progressLastRaised = [];
    private readonly HashSet<long> _progressTrailing = [];

    /// <summary>Minimum time between two batch-progress raises of one notebook.</summary>
    public TimeSpan IndexingProgressInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>
    /// Committed background batches are indexing progress, not catalog changes: a status-only raise at most once per
    /// interval per notebook (leading edge plus one trailing raise, so the last batch is never lost). Observers reload
    /// on their UI thread; per-batch raises would make them reload several times per second during a fast build.
    /// </summary>
    internal void NotifyIndexingProgress(long notebookId)
    {
        long now = Environment.TickCount64;
        long window = (long)IndexingProgressInterval.TotalMilliseconds;
        long delay;
        lock (_progressGate)
        {
            if (!_progressLastRaised.TryGetValue(notebookId, out long last) || now - last >= window)
            {
                _progressLastRaised[notebookId] = now;
                delay = -1;
            }
            else if (!_progressTrailing.Add(notebookId)) return;
            else delay = window - (now - last);
        }
        if (delay < 0)
        {
            NotifyIndexingStatusChanged(notebookId);
            return;
        }
        _ = Task.Delay(TimeSpan.FromMilliseconds(delay)).ContinueWith(_ =>
        {
            lock (_progressGate)
            {
                _progressTrailing.Remove(notebookId);
                _progressLastRaised[notebookId] = Environment.TickCount64;
            }
            NotifyIndexingStatusChanged(notebookId);
        }, TaskScheduler.Default);
    }

    internal void NotifyFolderIngestionChanged(long notebookId)
    {
        Raise(FolderIngestionChanged, notebookId);
        NotifyIndexingStatusChanged(notebookId);
    }

    /// <summary>Status-only signal: job lifecycle changes that are not catalog mutations.</summary>
    internal void NotifyIndexingStatusChanged(long notebookId) => Raise(IndexingStatusChanged, notebookId);

    internal void NotifyIndexingStatusChanged(IEnumerable<long> notebookIds)
    {
        foreach (long notebookId in notebookIds.Order()) NotifyIndexingStatusChanged(notebookId);
    }

    private static void Raise(Action<long>? handlers, long notebookId)
    {
        if (handlers is null) return;
        foreach (Action<long> handler in handlers.GetInvocationList())
        {
            try { handler(notebookId); }
            catch (Exception e) { System.Diagnostics.Trace.TraceError("Folder observer failed: {0}", e.GetType().Name); }
        }
    }

    public FolderSource? Folder(long id)
    {
        lock (_gate)
        {
            var row = _conn.QuerySingleOrDefault("SELECT * FROM folder_sources WHERE id=$id", new { id });
            return row is null ? null : ReadFolder(row);
        }
    }

    /// <summary>Starts a new scan generation for the running scan job identified by <paramref name="fence"/>.</summary>
    public ScanTicket? BeginFolderScan(long folderId, JobFence fence, long now)
    {
        ArgumentNullException.ThrowIfNull(fence);
        ScanTicket ticket;
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, folderId);
            if (folder is null || !OwnsScan(tx, folderId, fence, now)) return null;
            // Another live scan of the same folder owns the generation until its lease is reclaimed.
            if (_conn.ExecuteScalar<bool>("""
                SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=$target
                    AND state='running' AND id<>$id AND lease_until>$now)
                """, new { target = FolderTarget(folderId), id = fence.JobId, now }, tx))
                return null;
            long generation = checked(folder.ScanGeneration + 1);
            _conn.Execute("UPDATE folder_sources SET scan_state='scanning',scan_generation=$generation WHERE id=$folderId",
                new { generation, folderId }, tx);
            tx.Commit();
            ticket = new ScanTicket(folderId, generation, fence);
            notebookId = folder.NotebookId;
        }
        NotifyFolderIngestionChanged(notebookId);
        return ticket;
    }

    /// <summary>
    /// Records one regular file (or a link that replaced a known source). Returns the extraction request
    /// when the file has pending extraction work. A null <see cref="FolderObservation.ContentHash"/> means
    /// the scanner took the stat fast path; it is honoured only while the fast-path predicate still holds.
    /// Throws <c>staleLease</c> when the ticket no longer owns the folder's current scan generation.
    /// </summary>
    public ExtractionRequest? ObserveFolderFile(ScanTicket ticket, FolderObservation observation, long now)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        ValidateObservation(observation);
        ExtractionRequest? request;
        bool changed;
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, ticket.FolderId);
            if (folder is null || !OwnsTicket(tx, folder, ticket, now)) throw new StorageV19Exception("staleLease");
            notebookId = folder.NotebookId;
            changed = ObserveCore(tx, folder, observation, ticket.Generation, now, out request);
            tx.Commit();
        }
        if (changed) NotifyFolderIngestionChanged(notebookId);
        return request;
    }

    /// <summary>Bound paths per bulk statement (well under SQLite's variable limit).</summary>
    private const int ObserveBatchBulkChunk = 400;

    /// <summary>
    /// Commits a batch of scanner observations in one transaction (contract ingestion-scan-perf-v1 §1–2). Every
    /// observation is validated first; an invalid one rejects the batch. A row whose inventory and source already match
    /// the observation only gets seen_generation bumped (bulk UPDATE); every other row takes exactly the
    /// <see cref="ObserveFolderFile"/> path (interior links only when the path has a source). Raises one
    /// <see cref="FolderIngestionChanged"/> when any row changed, otherwise a throttled status-only signal (files seen);
    /// nothing for an empty batch or a rejected ticket.
    /// </summary>
    public FolderObserveBatchResult ObserveFolderFiles(ScanTicket ticket, IReadOnlyList<FolderScanObservation> observations, long now)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        ArgumentNullException.ThrowIfNull(observations);
        foreach (var item in observations)
        {
            ArgumentNullException.ThrowIfNull(item);
            ValidateObservation(item.Observation);
        }
        if (observations.Count == 0) return new FolderObserveBatchResult(0, 0);
        bool anyChange = false;
        int changed = 0;
        var bump = new List<string>();
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, ticket.FolderId);
            if (folder is null || !OwnsTicket(tx, folder, ticket, now)) throw new StorageV19Exception("staleLease");
            notebookId = folder.NotebookId;
            var items = new Dictionary<string, (string Kind, string? Reason, long? Mtime, long? Size)>(StringComparer.Ordinal);
            var sources = new Dictionary<string, (FolderSourceState State, string Availability, bool Eligible)>(StringComparer.Ordinal);
            var paths = observations.Select(item => item.Observation.RelPath).Distinct(StringComparer.Ordinal).ToArray();
            foreach (var chunk in paths.Chunk(ObserveBatchBulkChunk))
            {
                foreach (var row in _conn.Query("""
                    SELECT rel_path,kind,skip_reason,mtime,size_bytes FROM scan_items WHERE folder_id=$folderId AND rel_path IN $paths
                    """, new { folderId = folder.Id, paths = chunk }, tx))
                    items[(string)row.rel_path] = ((string)row.kind, (string?)row.skip_reason, (long?)row.mtime, (long?)row.size_bytes);
                foreach (var row in _conn.Query($"""
                    SELECT rel_path,id,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,availability,eligible,
                        {RetryBudgetSQL.GaveUpPredicate} AS gave_up
                    FROM sources WHERE folder_id=$folderId AND rel_path IN $paths
                    """, new { folderId = folder.Id, paths = chunk }, tx))
                    sources[(string)row.rel_path] = (new FolderSourceState((long)row.id, (string)row.status, (long?)row.mtime,
                        (long?)row.size_bytes, (string?)row.content_hash, (long?)row.current_revision, (long?)row.published_revision_id,
                        (long)row.gave_up != 0),
                        (string)row.availability, (long)row.eligible != 0);
            }
            bool Unchanged(FolderObservation observation)
            {
                var stamp = observation.Stamp;
                if (!items.TryGetValue(observation.RelPath, out var item) || item.Kind != observation.Kind ||
                    !StringComparer.Ordinal.Equals(item.Reason, observation.SkipReason) ||
                    item.Mtime != stamp.MtimeNs || item.Size != stamp.SizeBytes)
                    return false;
                bool known = sources.TryGetValue(observation.RelPath, out var source);
                if (observation.Kind == "skipped") return !known;
                if (!known || source.Availability != "present" || !source.Eligible ||
                    source.State.Mtime != stamp.MtimeNs || source.State.SizeBytes != stamp.SizeBytes)
                    return false;
                var state = source.State;
                // A given-up source with an unchanged stamp is settled (ingestion-retry-cap-v1 §4).
                if (observation.ContentHash is null && state.GaveUp) return true;
                bool current = !string.IsNullOrEmpty(state.ContentHash) && state.Published is not null &&
                    state.Current == state.Published && state.Status == "ready";
                return current && (observation.ContentHash is null ||
                    StringComparer.Ordinal.Equals(observation.ContentHash, state.ContentHash));
            }
            var touched = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in observations)
            {
                var observation = item.Observation;
                // A repeated path sees its own earlier write: never trust the snapshot twice.
                bool first = touched.Add(observation.RelPath);
                if (item.KnownOnly && !(first ? sources.ContainsKey(observation.RelPath)
                        : FolderSourceRow(tx, folder.Id, observation.RelPath) is not null))
                    continue;
                if (first && Unchanged(observation))
                {
                    bump.Add(observation.RelPath);
                    continue;
                }
                anyChange |= ObserveCore(tx, folder, observation, ticket.Generation, now, out _);
                changed++;
            }
            foreach (var chunk in bump.Chunk(ObserveBatchBulkChunk))
                _conn.Execute("UPDATE scan_items SET seen_generation=$generation WHERE folder_id=$folderId AND rel_path IN $paths",
                    new { generation = ticket.Generation, folderId = folder.Id, paths = chunk }, tx);
            tx.Commit();
        }
        if (anyChange) NotifyFolderIngestionChanged(notebookId);
        else if (changed + bump.Count > 0) NotifyIndexingProgress(notebookId);
        return new FolderObserveBatchResult(changed, bump.Count);
    }

    private static void ValidateObservation(FolderObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        ValidateRelativePath(observation.RelPath);
        if (observation.Stamp is null || observation.Stamp.SizeBytes < 0 ||
            observation.Kind is not ("eligible" or "skipped") ||
            observation.Kind == "eligible" && observation.SkipReason is not null ||
            observation.Kind == "skipped" && observation.SkipReason is not ("ignored" or "unsupported_ext" or "over_limit"))
            throw new StorageV19Exception("invalidValue");
    }

    /// <summary>The per-file observation body inside the caller's fenced transaction. True when anything changed.</summary>
    private bool ObserveCore(SqliteTransaction tx, FolderSource folder, FolderObservation observation, long generation, long now,
        out ExtractionRequest? request)
    {
        request = null;
        bool changed = UpsertObservedInventory(tx, folder.Id, observation, generation);
        var source = FolderSourceRow(tx, folder.Id, observation.RelPath);
        var stamp = observation.Stamp;
        if (observation.Kind == "skipped")
        {
            if (source is not null)
            {
                changed |= _conn.Execute("""
                    UPDATE sources SET availability='present',eligible=0,mtime=$mtime,size_bytes=$size
                    WHERE id=$id AND (availability<>'present' OR eligible<>0 OR mtime IS NOT $mtime OR size_bytes IS NOT $size)
                    """, new { id = source.Id, mtime = stamp.MtimeNs, size = stamp.SizeBytes }, tx) > 0;
                changed |= CancelOutstandingExtracts(tx, source.Id) > 0;
            }
        }
        else if (source is null)
        {
            // A new file is always hashed: the scanner never fast-paths an unknown path.
            if (observation.ContentHash is null) throw new StorageV19Exception("invalidValue");
            long sourceId = InsertFolderSource(tx, folder, observation, now);
            RetryBudgetSQL.Observe(_conn, tx, sourceId, observation.ContentHash, sameStamp: false);
            EnqueueDue(tx, new IngestJobDraft("extract", SourceTarget(sourceId), null), now);
            // A new source has no committed hash; the request carries the observed hash in memory only.
            request = new ExtractionRequest(sourceId, folder.Id, observation.RelPath, stamp,
                observation.ContentHash ?? "", FolderRulesOf(folder));
            changed = true;
        }
        else
        {
            bool sameStamp = source.Mtime == stamp.MtimeNs && source.SizeBytes == stamp.SizeBytes;
            string? committed = string.IsNullOrEmpty(source.ContentHash) ? null : source.ContentHash;
            bool publishedCurrent = source.Published is not null && source.Current == source.Published;
            bool fastPath = sameStamp && (committed is not null && publishedCurrent && source.Status == "ready" || source.GaveUp);
            changed |= _conn.Execute("""
                UPDATE sources SET availability='present',eligible=1,mtime=$mtime,size_bytes=$size
                WHERE id=$id AND (availability<>'present' OR eligible<>1 OR mtime IS NOT $mtime OR size_bytes IS NOT $size)
                """, new { id = source.Id, mtime = stamp.MtimeNs, size = stamp.SizeBytes }, tx) > 0;
            string? hash = observation.ContentHash;
            if (hash is not null && committed is not null && publishedCurrent && StringComparer.Ordinal.Equals(hash, committed))
            {
                // The committed bytes are on disk: any pending refresh is superseded.
                if (source.Status != "ready")
                {
                    CancelOutstandingExtracts(tx, source.Id);
                    _conn.Execute("UPDATE sources SET status='ready',error=NULL WHERE id=$id", new { id = source.Id }, tx);
                    RetryBudgetSQL.Clear(_conn, tx, source.Id);
                    changed = true;
                }
            }
            else if (hash is null && fastPath)
            {
                // Stat fast path: metadata and inventory only. A same-size, same-mtime replacement is
                // only discovered by Verify all or a forced-hash native event (inherent tradeoff).
            }
            else
            {
                // Metadata alone never suppresses pending or failed extraction; a spent budget for the same
                // content does (ingestion-retry-cap-v1 §4).
                changed = true;
                RetryBudgetSQL.Observe(_conn, tx, source.Id, hash, sameStamp);
                if (RequireExtraction(tx, source.Id, keepRunning: sameStamp, now))
                    request = new ExtractionRequest(source.Id, folder.Id, observation.RelPath, stamp,
                        hash ?? committed ?? "", FolderRulesOf(folder));
            }
        }
        return changed;
    }

    /// <summary>
    /// Completes the scan job together with the folder's final state. Missing marking and source-less
    /// inventory cleanup happen only inside completed prefixes; a stale ticket changes nothing.
    /// </summary>
    public bool FinishFolderScan(ScanTicket ticket, ScanCompletion completion, long now)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        ArgumentNullException.ThrowIfNull(completion);
        foreach (string prefix in completion.Completed.Concat(completion.Incomplete))
            if (prefix.Length != 0) ValidateRelativePath(prefix);
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, ticket.FolderId);
            if (folder is null || !OwnsTicket(tx, folder, ticket, now)) return false;
            notebookId = folder.NotebookId;
            long folderId = folder.Id;
            if (completion.RootUnavailable)
            {
                // Present sources become unavailable; nothing is called missing while the root is offline.
                _conn.Execute("UPDATE folder_sources SET scan_state='unavailable',last_scan_error=$error WHERE id=$folderId",
                    new { folderId, error = completion.Error ?? "rootUnavailable" }, tx);
                _conn.Execute("UPDATE sources SET availability='unavailable' WHERE folder_id=$folderId AND availability='present'",
                    new { folderId }, tx);
            }
            else if (completion.Error is not null)
            {
                _conn.Execute("UPDATE folder_sources SET scan_state='error',last_scan_error=$error WHERE id=$folderId",
                    new { folderId, error = completion.Error }, tx);
            }
            else
            {
                foreach (string prefix in completion.Completed.Distinct(StringComparer.Ordinal))
                {
                    var unseen = _conn.Query<long>($"""
                        SELECT s.id FROM sources s WHERE s.folder_id=$folderId AND {PrefixPredicate("s.rel_path")}
                          AND NOT EXISTS(SELECT 1 FROM scan_items i WHERE i.folder_id=s.folder_id
                            AND i.rel_path=s.rel_path AND i.seen_generation=$generation)
                        ORDER BY s.id
                        """, new { folderId, prefix, generation = ticket.Generation }, tx).ToArray();
                    foreach (long sourceId in unseen)
                    {
                        _conn.Execute("UPDATE sources SET availability='missing' WHERE id=$sourceId AND availability<>'missing'",
                            new { sourceId }, tx);
                        CancelOutstandingExtracts(tx, sourceId);
                    }
                    // Source inventory stays until the source itself is removed so missing precedence is counted once.
                    _conn.Execute($"""
                        DELETE FROM scan_items WHERE folder_id=$folderId AND {PrefixPredicate("rel_path")}
                          AND seen_generation<>$generation
                          AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.folder_id=scan_items.folder_id
                            AND s.rel_path=scan_items.rel_path)
                        """, new { folderId, prefix, generation = ticket.Generation }, tx);
                }
                bool full = completion.Incomplete.Count == 0 && completion.Completed.Contains("");
                _conn.Execute("""
                    UPDATE folder_sources SET scan_state=$state,last_scan_error=NULL,
                        last_full_scan_at=CASE WHEN $full THEN $now ELSE last_full_scan_at END
                    WHERE id=$folderId
                    """, new { folderId, state = full ? "idle" : "partial", full, now }, tx);
            }
            if (!RevisionJobSQL.FinishPublishedJob(_conn, tx, ticket.Fence, now))
                throw new StorageV19Exception("staleLease");
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return true;
    }

    /// <summary>
    /// Current-generation-only partial marker after a cancelled scan. It never marks anything missing,
    /// and a newer generation (or a finished scan) is left untouched.
    /// </summary>
    public bool MarkFolderScanCancelled(ScanTicket ticket, long now)
    {
        ArgumentNullException.ThrowIfNull(ticket);
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, ticket.FolderId);
            if (folder is null) return false;
            notebookId = folder.NotebookId;
            if (_conn.Execute("""
                UPDATE folder_sources SET scan_state='partial'
                WHERE id=$id AND scan_generation=$generation AND scan_state='scanning'
                """, new { id = folder.Id, generation = ticket.Generation }, tx) != 1)
                return false;
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return true;
    }

    /// <summary>
    /// Commits new folder rules, eligibility flags, skipped reasons and job changes atomically.
    /// <paramref name="eligibility"/> holds the classifier's verdict for every stored path and
    /// <paramref name="skipReasons"/> its reason for ineligible ones (ignored first); a missing reason falls back to
    /// extension/size checks. A path observed after the verdicts were computed makes the map stale
    /// (<c>staleRevision</c>); the caller recomputes and retries.
    /// </summary>
    public void ApplyFolderRules(long folderId, FolderRules rules, IReadOnlyDictionary<string, bool> eligibility, long now,
        IReadOnlyDictionary<string, string>? skipReasons = null)
    {
        ArgumentNullException.ThrowIfNull(rules);
        ArgumentNullException.ThrowIfNull(eligibility);
        if (rules.Limits is null) throw new FolderIngestionException("unsupportedSyntax");
        rules.Limits.Validate();
        if (rules.EncodingFallback is not ("cp1250" or "none")) throw new FolderIngestionException("unsupportedEncoding");
        var normalized = rules with { IncludeExts = FolderRuleClassifier.NormalizeExtensions(rules.IncludeExts) };
        skipReasons ??= new Dictionary<string, string>();
        long notebookId;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            var folder = LoadFolder(tx, folderId) ?? throw new StorageV19Exception("notFound");
            notebookId = folder.NotebookId;
            var rows = RuleRows(tx, folderId);
            // Rows observed after the caller classified must be classified too.
            if (rows.Any(row => !eligibility.ContainsKey(row.RelPath))) throw new StorageV19Exception("staleRevision");

            FolderRules? previous;
            try { previous = FolderRulesOf(folder); }
            catch (FolderIngestionException) { previous = null; }
            bool forceExtraction = previous is null || previous.Limits != normalized.Limits ||
                !StringComparer.Ordinal.Equals(previous.EncodingFallback, normalized.EncodingFallback);
            _conn.Execute("""
                UPDATE folder_sources SET include_exts=$include,ignore_globs=$ignore,limits=$limits,encoding_fallback=$encoding
                WHERE id=$folderId
                """, new
            {
                folderId, include = JsonSerializer.Serialize(normalized.IncludeExts),
                ignore = JsonSerializer.Serialize(normalized.IgnoreGlobs), limits = normalized.Limits.ToJson(),
                encoding = normalized.EncodingFallback
            }, tx);

            foreach (var row in rows)
            {
                bool eligible = eligibility[row.RelPath];
                string? reason = eligible ? null : skipReasons.GetValueOrDefault(row.RelPath) ?? FallbackReason(normalized, row);
                string kind = eligible ? "eligible" : "skipped";
                var item = _conn.QuerySingleOrDefault("SELECT seen_generation,mtime,size_bytes FROM scan_items WHERE folder_id=$folderId AND rel_path=$path",
                    new { folderId, path = row.RelPath }, tx);
                if (row.SourceId is not long sourceId)
                {
                    _conn.Execute("UPDATE scan_items SET kind=$kind,skip_reason=$reason WHERE folder_id=$folderId AND rel_path=$path",
                        new { folderId, path = row.RelPath, kind, reason }, tx);
                    continue;
                }
                var source = _conn.QuerySingle("""
                    SELECT eligible,availability,status,mtime,size_bytes,current_revision,published_revision_id FROM sources WHERE id=$sourceId
                    """, new { sourceId }, tx);
                if (item is not null)
                    UpsertInventory(tx, folderId, row.RelPath, kind, reason, (long?)item.mtime, (long?)item.size_bytes, (long)item.seen_generation);
                else if ((string)source.availability != "missing")
                    UpsertInventory(tx, folderId, row.RelPath, kind, reason, (long?)source.mtime, (long?)source.size_bytes, folder.ScanGeneration);
                bool wasEligible = (long)source.eligible != 0;
                _conn.Execute("UPDATE sources SET eligible=$eligible WHERE id=$sourceId", new { sourceId, eligible }, tx);
                if (!eligible)
                {
                    CancelOutstandingExtracts(tx, sourceId);
                    continue;
                }
                long? current = (long?)source.current_revision;
                long? published = (long?)source.published_revision_id;
                bool needsWork = published is null || current != published || (string)source.status != "ready";
                if (!wasEligible && needsWork || forceExtraction)
                {
                    // New limits or encoding may resolve a failure: the budget starts over.
                    if (forceExtraction) RetryBudgetSQL.Reset(_conn, tx, sourceId);
                    RequireExtraction(tx, sourceId, keepRunning: !forceExtraction, now);
                }
            }
            // A folder rescan discovers unknown files and re-extracts under the new rules.
            if (!_conn.ExecuteScalar<bool>(
                "SELECT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='scan' AND target=$target AND state='queued')",
                new { target = FolderTarget(folderId) }, tx))
                EnqueueDue(tx, new IngestJobDraft("scan", FolderTarget(folderId), null, """{"verifyAll":false}"""), now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
    }

    /// <summary>Stored sources plus source-less inventory: the rows a rule change must classify.</summary>
    internal IReadOnlyList<(string RelPath, long? SizeBytes)> FolderRuleRows(long folderId)
    {
        lock (_gate) return RuleRows(null, folderId).Select(row => (row.RelPath, row.SizeBytes)).ToArray();
    }

    /// <summary>Queues extraction for one folder source now (coalesced with unclaimed work for the same revision).</summary>
    public bool RequestFolderExtraction(long sourceId, long now)
    {
        long notebookId;
        bool queued;
        lock (_gate)
        {
            using var tx = _conn.BeginTransaction(deferred: false);
            long? owner = _conn.QuerySingleOrDefault<long?>(
                "SELECT notebook_id FROM sources WHERE id=$sourceId AND folder_id IS NOT NULL", new { sourceId }, tx);
            if (owner is not long notebook) throw new StorageV19Exception("notFound");
            notebookId = notebook;
            // An explicit re-ingest is a user retry: a spent failure budget starts over.
            RetryBudgetSQL.ResetIfGaveUp(_conn, tx, sourceId);
            queued = RequireExtraction(tx, sourceId, keepRunning: true, now);
            tx.Commit();
        }
        NotifyFolderIngestionChanged(notebookId);
        return queued;
    }

    private sealed record RuleRow(string RelPath, long? SizeBytes, long? SourceId);

    private IReadOnlyList<RuleRow> RuleRows(SqliteTransaction? tx, long folderId)
    {
        var sources = _conn.Query("SELECT id,rel_path,size_bytes FROM sources WHERE folder_id=$folderId AND rel_path IS NOT NULL ORDER BY id",
            new { folderId }, tx).Select(r => new RuleRow((string)r.rel_path, (long?)r.size_bytes, (long?)r.id));
        var items = _conn.Query("""
            SELECT i.rel_path,i.size_bytes FROM scan_items i WHERE i.folder_id=$folderId
              AND NOT EXISTS(SELECT 1 FROM sources s WHERE s.folder_id=i.folder_id AND s.rel_path=i.rel_path)
            ORDER BY CAST(i.rel_path AS BLOB)
            """, new { folderId }, tx).Select(r => new RuleRow((string)r.rel_path, (long?)r.size_bytes, null));
        return sources.Concat(items).ToArray();
    }

    /// <summary>Reason for an ineligible stored row when the classifier supplied none.</summary>
    private static string FallbackReason(FolderRules rules, RuleRow row)
    {
        string extension = FolderRuleClassifier.Extension(row.RelPath);
        if (extension.Length == 0 || !rules.IncludeExts.Contains(extension, StringComparer.Ordinal)) return "unsupported_ext";
        if (row.SizeBytes is long size && size > rules.Limits.FileBytes) return "over_limit";
        return "ignored";
    }

    private void UpsertInventory(SqliteTransaction tx, long folderId, string relPath, string kind, string? reason,
        long? mtime, long? size, long generation) => _conn.Execute("""
        INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
        VALUES($folderId,$relPath,$kind,$reason,$mtime,$size,$generation)
        ON CONFLICT(folder_id,rel_path) DO UPDATE SET kind=excluded.kind,skip_reason=excluded.skip_reason,
            mtime=excluded.mtime,size_bytes=excluded.size_bytes,seen_generation=excluded.seen_generation
        """, new { folderId, relPath, kind, reason, mtime, size, generation }, tx);

    /// <summary>WP6 jobs are immediately due (NULL retry deadline); WP3's EnqueueJob is unchanged.</summary>
    private long EnqueueDue(SqliteTransaction tx, IngestJobDraft draft, long now)
    {
        long id = RevisionJobSQL.EnqueueJob(_conn, tx, draft, now);
        _conn.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$id", new { id }, tx);
        return id;
    }

    /// <summary>
    /// Queues extraction for the source's current pointer unless an unclaimed job for it already exists (or a
    /// running one may stand for unchanged bytes); every other unfinished extraction is superseded. True when a new
    /// job was queued.
    /// </summary>
    private bool RequireExtraction(SqliteTransaction tx, long sourceId, bool keepRunning, long now)
    {
        // A spent failure budget queues nothing until the content changes or the user retries.
        if (RetryBudgetSQL.Exhausted(_conn, tx, sourceId)) return false;
        long? current = _conn.QuerySingleOrDefault<long?>("SELECT current_revision FROM sources WHERE id=$sourceId", new { sourceId }, tx);
        string target = SourceTarget(sourceId);
        var reusable = _conn.Query($"""
            SELECT id,state,target_revision FROM ingest_jobs WHERE kind='extract' AND target=$target AND {OutstandingExtractPredicate}
            ORDER BY id
            """, new { target }, tx).LastOrDefault(row => (long?)row.target_revision == current &&
                ((string)row.state is "queued" or "paused" || keepRunning && (string)row.state == "running"));
        if (reusable is not null)
        {
            CancelOutstandingExtracts(tx, sourceId, (long)reusable.id);
            if ((string)reusable.state != "running")
                _conn.Execute("UPDATE sources SET status='pending',error=NULL WHERE id=$sourceId", new { sourceId }, tx);
            return false;
        }
        CancelOutstandingExtracts(tx, sourceId);
        EnqueueDue(tx, new IngestJobDraft("extract", target, current), now);
        _conn.Execute("UPDATE sources SET status='pending',error=NULL WHERE id=$sourceId", new { sourceId }, tx);
        return true;
    }

    /// <summary>
    /// Request for a restarted extract job. The hash is the last committed hash (possibly empty);
    /// the worker always replaces it with the hash of the file it actually opens.
    /// </summary>
    public ExtractionRequest? ExtractionRequest(long sourceId)
    {
        lock (_gate)
        {
            var row = _conn.QuerySingleOrDefault("""
                SELECT folder_id,rel_path,mtime,size_bytes,content_hash FROM sources
                WHERE id=$sourceId AND folder_id IS NOT NULL AND rel_path IS NOT NULL
                """, new { sourceId });
            if (row is null) return null;
            var folder = LoadFolder(null, (long)row.folder_id);
            if (folder is null) return null;
            return new ExtractionRequest(sourceId, folder.Id, (string)row.rel_path,
                new FileStamp("", (long?)row.mtime ?? 0, (long?)row.size_bytes ?? 0),
                (string?)row.content_hash ?? "", FolderRulesOf(folder));
        }
    }

    /// <summary>
    /// The folder's sources keyed by rel_path: the scanner's fast-path snapshot. A stale entry is harmless — the commit
    /// re-checks every row, and an outdated skip falls back to queuing extraction from the committed hash.
    /// </summary>
    internal IReadOnlyDictionary<string, FolderKnownSource> FolderKnownSources(long folderId)
    {
        lock (_gate)
            return _conn.Query($"""
                SELECT rel_path,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,
                    {RetryBudgetSQL.GaveUpPredicate} AS gave_up
                FROM sources WHERE folder_id=$folderId AND rel_path IS NOT NULL
                """, new { folderId }).ToDictionary(row => (string)row.rel_path, row => new FolderKnownSource((string)row.status,
                    (long?)row.mtime, (long?)row.size_bytes, (string?)row.content_hash, (long?)row.current_revision,
                    (long?)row.published_revision_id, (long)row.gave_up != 0), StringComparer.Ordinal);
    }

    /// <summary>
    /// Stat fast-path predicate: equal stamp and either committed hash, current published revision and ready, or given up
    /// (ingestion-retry-cap-v1 §4).
    /// </summary>
    internal bool FolderFastPath(long folderId, string relPath, FileStamp stamp)
    {
        lock (_gate)
            return _conn.ExecuteScalar<bool>($"""
                SELECT EXISTS(SELECT 1 FROM sources WHERE folder_id=$folderId AND rel_path=$relPath
                    AND mtime=$mtime AND size_bytes=$size AND (content_hash IS NOT NULL
                    AND published_revision_id IS NOT NULL AND current_revision=published_revision_id AND status='ready'
                    OR {RetryBudgetSQL.GaveUpPredicate}))
                """, new { folderId, relPath, mtime = stamp.MtimeNs, size = stamp.SizeBytes });
    }

    internal bool HasFolderSource(long folderId, string relPath)
    {
        lock (_gate)
            return _conn.ExecuteScalar<bool>("SELECT EXISTS(SELECT 1 FROM sources WHERE folder_id=$folderId AND rel_path=$relPath)",
                new { folderId, relPath });
    }

    internal static FolderRules FolderRulesOf(FolderSource folder) => new(folder.Draft.IncludeExts, folder.Draft.IgnoreGlobs,
        IngestionLimits.FromJson(folder.Draft.LimitsJSON), folder.Draft.EncodingFallback);

    private const string OutstandingExtractPredicate =
        "(state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL))";

    // Exact component prefix membership; never LIKE (wildcards, and 'a' must not match 'ab').
    private static string PrefixPredicate(string column) =>
        $"($prefix='' OR {column}=$prefix OR substr({column},1,length($prefix)+1)=$prefix||'/')";

    private static string FolderTarget(long folderId) => "folder:" + folderId.ToString(CultureInfo.InvariantCulture);
    private static string SourceTarget(long sourceId) => "source:" + sourceId.ToString(CultureInfo.InvariantCulture);

    private FolderSource? LoadFolder(SqliteTransaction? tx, long folderId)
    {
        var row = _conn.QuerySingleOrDefault("SELECT * FROM folder_sources WHERE id=$folderId", new { folderId }, tx);
        return row is null ? null : ReadFolder(row);
    }

    private bool OwnsScan(SqliteTransaction tx, long folderId, JobFence fence, long now)
    {
        var job = RevisionJobSQL.ValidateFence(_conn, tx, fence, now);
        return job is not null && job.Draft.Kind == "scan" && job.Draft.Target == FolderTarget(folderId);
    }

    private bool OwnsTicket(SqliteTransaction tx, FolderSource folder, ScanTicket ticket, long now) =>
        folder.ScanState == "scanning" && folder.ScanGeneration == ticket.Generation &&
        OwnsScan(tx, folder.Id, ticket.Fence, now);

    private int CancelOutstandingExtracts(SqliteTransaction tx, long sourceId, long? except = null) => _conn.Execute($"""
        UPDATE ingest_jobs SET state='cancelled',next_retry_at=NULL,lease_until=NULL,lease_token=NULL
        WHERE kind='extract' AND target=$target AND {OutstandingExtractPredicate} AND ($except IS NULL OR id<>$except)
        """, new { target = SourceTarget(sourceId), except }, tx);

    private bool UpsertObservedInventory(SqliteTransaction tx, long folderId, FolderObservation observation, long generation)
    {
        var existing = _conn.QuerySingleOrDefault("SELECT kind,skip_reason FROM scan_items WHERE folder_id=$folderId AND rel_path=$relPath",
            new { folderId, relPath = observation.RelPath }, tx);
        _conn.Execute("""
            INSERT INTO scan_items(folder_id,rel_path,kind,skip_reason,mtime,size_bytes,seen_generation)
            VALUES($folderId,$relPath,$kind,$reason,$mtime,$size,$generation)
            ON CONFLICT(folder_id,rel_path) DO UPDATE SET kind=excluded.kind,skip_reason=excluded.skip_reason,
                mtime=excluded.mtime,size_bytes=excluded.size_bytes,seen_generation=excluded.seen_generation
            """, new
        {
            folderId, relPath = observation.RelPath, kind = observation.Kind, reason = observation.SkipReason,
            mtime = observation.Stamp.MtimeNs, size = observation.Stamp.SizeBytes, generation
        }, tx);
        return existing is null || (string)existing.kind != observation.Kind ||
            !StringComparer.Ordinal.Equals((string?)existing.skip_reason, observation.SkipReason);
    }

    private sealed record FolderSourceState(long Id, string Status, long? Mtime, long? SizeBytes, string? ContentHash,
        long? Current, long? Published, bool GaveUp);

    private FolderSourceState? FolderSourceRow(SqliteTransaction tx, long folderId, string relPath)
    {
        var row = _conn.QuerySingleOrDefault($"""
            SELECT id,status,mtime,size_bytes,content_hash,current_revision,published_revision_id,
                {RetryBudgetSQL.GaveUpPredicate} AS gave_up
            FROM sources WHERE folder_id=$folderId AND rel_path=$relPath
            """, new { folderId, relPath }, tx);
        return row is null ? null : new FolderSourceState((long)row.id, (string)row.status, (long?)row.mtime,
            (long?)row.size_bytes, (string?)row.content_hash, (long?)row.current_revision, (long?)row.published_revision_id,
            (long)row.gave_up != 0);
    }

    private long InsertFolderSource(SqliteTransaction tx, FolderSource folder, FolderObservation observation, long now)
    {
        string name = observation.RelPath[(observation.RelPath.LastIndexOf('/') + 1)..];
        string extension = FolderRuleClassifier.Extension(observation.RelPath);
        string title = extension.Length == 0 ? name : name[..^(extension.Length + 1)];
        if (title.Trim().Length == 0) title = name;
        SourceType type = FolderExtractionWorker.TypeFor(extension);
        string rawPath = Path.Join(folder.Draft.RootPath, observation.RelPath.Replace('/', Path.DirectorySeparatorChar));
        return _conn.ExecuteScalar<long>("""
            INSERT INTO sources(notebook_id,type,title,uri,raw_path,status,error,ingested_at,
                folder_id,rel_path,mtime,size_bytes,availability,eligible)
            VALUES($notebookId,$type,$title,NULL,$rawPath,'pending',NULL,$ingested,
                $folderId,$relPath,$mtime,$size,'present',1);
            SELECT last_insert_rowid();
            """, new
        {
            notebookId = folder.NotebookId, type = type.ToDb(), title = title.Trim(), rawPath,
            ingested = SqliteDate.ToDb(DateTimeOffset.FromUnixTimeSeconds(now).UtcDateTime),
            folderId = folder.Id, relPath = observation.RelPath,
            mtime = observation.Stamp.MtimeNs, size = observation.Stamp.SizeBytes
        }, tx);
    }
}
