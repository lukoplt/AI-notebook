using System.Collections.Concurrent;
using System.Globalization;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Ingestion
{
    /// <summary>
    /// Durable job runner over WP3's fenced job state machine. It selects a due candidate (concurrent calls pick
    /// distinct jobs), reserves that job's admission capacity, then claims the exact id atomically; no claimed job
    /// ever waits for a permit.
    /// A child renewal loop extends the lease every 60 seconds and cancels the attempt when renewal fails.
    /// The execute delegate owns kind-specific fenced completion; the queue never completes jobs generically.
    /// </summary>
    public sealed class JobQueue
    {
        private const int CandidateLimit = 32;
        private const long RenewalInterval = 60;
        internal const long PreClaimDeferral = 60;
        private readonly NotebookStore _store;
        private readonly IIngestLeaseClock _clock;
        private readonly IngestionAdmission _admission;
        private readonly Func<string> _token;
        private readonly CancellationTokenSource _stopping = new();
        private readonly ConcurrentDictionary<Task, byte> _running = new();
        private readonly object _gate = new();
        private readonly HashSet<long> _selected = [];
        // Candidates whose reservation or claim threw, skipped until the lease-clock deadline: one poisoned row at the
        // head of the due order must not stall every later job of its kind (ingestion-memory-pressure-v1 §5).
        private readonly Dictionary<long, long> _deferred = new();
        private readonly Dictionary<long, (JobFence Fence, CancellationTokenSource Attempt)> _active = new();

        public JobQueue(NotebookStore store, IIngestLeaseClock clock, IngestionAdmission admission, Func<string>? token = null)
        {
            _store = store ?? throw new ArgumentNullException(nameof(store));
            _clock = clock ?? throw new ArgumentNullException(nameof(clock));
            _admission = admission ?? throw new ArgumentNullException(nameof(admission));
            _token = token ?? (() => Guid.NewGuid().ToString("N"));
        }

        /// <summary>
        /// Runs at most one due job of <paramref name="kind"/>. <paramref name="reservedBytes"/> &gt; 0 holds an
        /// extraction permit for the attempt; zero runs without one (scan/embed work). Returns false when no
        /// due job could be claimed. User cancellation (<paramref name="ct"/>) cancels the job under its fence;
        /// <see cref="StopAsync"/> leaves it for lease recovery so shutdown never discards queued work.
        /// </summary>
        public Task<bool> RunOneAsync(string kind, long reservedBytes,
            Func<IngestJob, JobFence, CancellationToken, Task> execute, CancellationToken ct = default)
        {
            ArgumentOutOfRangeException.ThrowIfNegative(reservedBytes);
            return RunOneAsync(kind, (_, _) => Task.FromResult(reservedBytes), execute, ct);
        }

        /// <summary>
        /// Per-job reservation overload: <paramref name="reservation"/> computes the selected candidate's extraction
        /// reservation (only <c>extract</c> jobs hold an admission permit).
        /// </summary>
        public async Task<bool> RunOneAsync(string kind, Func<IngestJob, CancellationToken, Task<long>> reservation,
            Func<IngestJob, JobFence, CancellationToken, Task> execute, CancellationToken ct = default)
        {
            ArgumentException.ThrowIfNullOrEmpty(kind);
            ArgumentNullException.ThrowIfNull(reservation);
            ArgumentNullException.ThrowIfNull(execute);
            if (_stopping.IsCancellationRequested) return false;
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _running.TryAdd(done.Task, 0);
            try
            {
                return await RunCoreAsync(kind, reservation, execute, ct).ConfigureAwait(false);
            }
            finally
            {
                done.TrySetResult();
                _running.TryRemove(done.Task, out _);
            }
        }

        /// <summary>Cancels every running attempt and awaits it; no renewal task survives.</summary>
        public async Task StopAsync()
        {
            _stopping.Cancel();
            await Task.WhenAll(_running.Keys.ToArray()).ConfigureAwait(false);
        }

        /// <summary>User cancellation: stops local work and cancels the durable job (fenced when running here).</summary>
        public Task<bool> CancelAsync(long jobId)
        {
            (JobFence Fence, CancellationTokenSource Attempt) entry;
            bool local;
            lock (_gate) local = _active.TryGetValue(jobId, out entry);
            if (!local) return Task.FromResult(_store.CancelIngestJob(jobId, null, _clock.Now));
            bool cancelled = _store.CancelIngestJob(jobId, entry.Fence, _clock.Now);
            try { entry.Attempt.Cancel(); } catch (ObjectDisposedException) { }
            return Task.FromResult(cancelled);
        }

        private async Task<bool> RunCoreAsync(string kind, Func<IngestJob, CancellationToken, Task<long>> reservation,
            Func<IngestJob, JobFence, CancellationToken, Task> execute, CancellationToken ct)
        {
            using var attempt = CancellationTokenSource.CreateLinkedTokenSource(ct, _stopping.Token);
            long now = _clock.Now;
            _store.RecoverExpiredJobs(now);
            _store.RequeueRetryableJobs(now);
            IngestJob? candidate;
            lock (_gate)
            {
                foreach (long expired in _deferred.Where(d => d.Value <= now).Select(d => d.Key).ToArray()) _deferred.Remove(expired);
                candidate = _store.DueJobs(kind, now, CandidateLimit)
                    .FirstOrDefault(job => !_selected.Contains(job.Id) && !_deferred.ContainsKey(job.Id));
                if (candidate is not null) _selected.Add(candidate.Id);
            }
            if (candidate is null) return false;
            Guid? permit = null;
            bool claimed = false;
            try
            {
                if (kind == "extract")
                    permit = await _admission.AcquireExtractionAsync(await reservation(candidate, attempt.Token).ConfigureAwait(false),
                        attempt.Token).ConfigureAwait(false);
                attempt.Token.ThrowIfCancellationRequested();
                // A lost race or an orphaned target simply reports no work.
                var job = _store.ClaimJob(_clock.Now, _token(), candidate.Id);
                if (job is null) return false;
                claimed = true;
                var fence = new JobFence(job.Id, job.LeaseToken!);
                lock (_gate) _active[job.Id] = (fence, attempt);
                try { await ExecuteAsync(job, fence, execute, attempt, ct).ConfigureAwait(false); }
                finally { lock (_gate) _active.Remove(job.Id); }
                return true;
            }
            catch (OperationCanceledException) when (attempt.IsCancellationRequested && !ct.IsCancellationRequested)
            {
                return false; // Stopping before a claim.
            }
            catch (Exception error) when (!claimed && error is not OperationCanceledException && Defer(candidate.Id, now))
            {
                throw; // Unreachable: Defer records the deferral and returns false so the exception propagates.
            }
            finally
            {
                lock (_gate) _selected.Remove(candidate.Id);
                if (permit is Guid token) _admission.ReleaseExtraction(token);
            }
        }

        private async Task ExecuteAsync(IngestJob job, JobFence fence, Func<IngestJob, JobFence, CancellationToken, Task> execute,
            CancellationTokenSource attempt, CancellationToken userToken)
        {
            using var renewalStop = new CancellationTokenSource();
            int lost = 0;
            var renewal = Task.Run(async () =>
            {
                long next = _clock.Now + RenewalInterval;
                while (true)
                {
                    await _clock.WaitUntilAsync(next, renewalStop.Token).ConfigureAwait(false);
                    if (!_store.RenewJob(fence, _clock.Now))
                    {
                        Interlocked.Exchange(ref lost, 1);
                        try { attempt.Cancel(); } catch (ObjectDisposedException) { }
                        return;
                    }
                    next = _clock.Now + RenewalInterval;
                }
            }, CancellationToken.None);
            try
            {
                await execute(job, fence, attempt.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (attempt.IsCancellationRequested)
            {
                if (Volatile.Read(ref lost) == 0 && userToken.IsCancellationRequested)
                    _store.CancelIngestJob(job.Id, fence, _clock.Now);
                // Lost lease: the new owner decides. Stopping: lease recovery requeues the attempt.
                if (userToken.IsCancellationRequested) throw;
            }
            catch (Exception error)
            {
                // Only the current fence may fail its attempt; a stale worker's failure has no effect.
                if (Volatile.Read(ref lost) == 0) _store.FailJob(fence, ErrorCode(error), _clock.Now);
            }
            finally
            {
                renewalStop.Cancel();
                try { await renewal.ConfigureAwait(false); }
                catch (OperationCanceledException) { }
            }
        }

        private bool Defer(long jobId, long now)
        {
            lock (_gate) _deferred[jobId] = now > long.MaxValue - PreClaimDeferral ? long.MaxValue : now + PreClaimDeferral;
            return false;
        }

        internal static string ErrorCode(Exception error) => error switch
        {
            FolderIngestionException ingestion => ingestion.Code,
            StorageV19Exception storage => storage.Code,
            _ => "unexpectedError"
        };
    }
}

namespace AINotebook.Core.Storage
{
    public sealed partial class NotebookStore
    {
        /// <summary>
        /// Due queued candidates of one kind, filtered before the limit and ordered by deadline then id.
        /// A null deadline is immediately due. Read-only; claiming happens separately and atomically.
        /// </summary>
        public IReadOnlyList<IngestJob> DueJobs(string kind, long now, int limit)
        {
            ArgumentOutOfRangeException.ThrowIfLessThan(limit, 1);
            lock (_gate)
                return _conn.Query<long>("""
                    SELECT id FROM ingest_jobs
                    WHERE kind=$kind AND state='queued' AND attempts<5 AND (next_retry_at IS NULL OR next_retry_at<=$now)
                    ORDER BY coalesce(next_retry_at,0),id LIMIT $limit
                    """, new { kind, now, limit }).Select(id => RevisionJobSQL.Job(_conn, null, id)!).ToArray();
        }

        /// <summary>
        /// An exhausted job is never reset: a user retry queues a new due row (attempts 0) and marks the source's refresh
        /// pending again. Null when the job is not exhausted.
        /// </summary>
        public long? RetryExhaustedJob(long jobId, long now)
        {
            long id;
            long? notebook;
            lock (_gate)
            {
                using var tx = _conn.BeginTransaction(deferred: false);
                var job = RevisionJobSQL.Job(_conn, tx, jobId);
                if (job is null || job.State != "failed" || !(job.Attempts >= 5 || job.NextRetryAt is null)) return null;
                id = RevisionJobSQL.EnqueueJob(_conn, tx, job.Draft, now);
                _conn.Execute("UPDATE ingest_jobs SET next_retry_at=NULL WHERE id=$id", new { id }, tx);
                if (job.Draft.Kind == "extract" && job.Draft.Target.StartsWith("source:", StringComparison.Ordinal))
                    _conn.Execute("""
                        UPDATE sources SET status='pending',error=NULL WHERE 'source:'||id=$target AND current_revision IS $revision
                        """, new { target = job.Draft.Target, revision = job.Draft.TargetRevision }, tx);
                notebook = RevisionJobSQL.NotebookOf(_conn, tx, job.Draft.Target);
                tx.Commit();
            }
            if (notebook is long changed) NotifyIndexingStatusChanged(changed);
            return id;
        }

        /// <summary>
        /// User cancellation. A running job is cancelled only through its fence; without a fence only queued or
        /// paused jobs are cancelled. A cancelled extraction never leaves its source refresh-pending forever: when no
        /// other unfinished extraction owns the source it becomes a visible <c>cancelled</c> refresh error, which a
        /// later scan or retry replaces.
        /// </summary>
        public bool CancelIngestJob(long jobId, JobFence? fence, long now)
        {
            long? notebook;
            lock (_gate)
            {
                using var tx = _conn.BeginTransaction(deferred: false);
                var job = RevisionJobSQL.Job(_conn, tx, jobId);
                if (job is null) return false;
                if (fence is not null)
                {
                    if (fence.JobId != jobId || !RevisionJobSQL.CancelJob(_conn, tx, fence, now)) return false;
                }
                else
                {
                    if (job.State is not ("queued" or "paused")) return false;
                    RevisionJobSQL.CancelJob(_conn, tx, jobId);
                }
                if (job.Draft.Kind == "extract")
                    _conn.Execute("""
                        UPDATE sources SET status='error',error='cancelled'
                        WHERE 'source:'||id=$target AND current_revision IS $revision AND status IN ('pending','chunking')
                          AND NOT EXISTS(SELECT 1 FROM ingest_jobs WHERE kind='extract' AND target=$target AND id<>$jobId
                            AND (state IN ('queued','running','paused') OR (state='failed' AND attempts<5 AND next_retry_at IS NOT NULL)))
                        """, new { target = job.Draft.Target, revision = job.Draft.TargetRevision, jobId }, tx);
                notebook = RevisionJobSQL.NotebookOf(_conn, tx, job.Draft.Target);
                tx.Commit();
            }
            if (notebook is long changed) NotifyIndexingStatusChanged(changed);
            return true;
        }
    }
}
