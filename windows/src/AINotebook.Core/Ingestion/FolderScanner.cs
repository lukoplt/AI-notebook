using System.Collections.Concurrent;
using System.Runtime.ExceptionServices;
using System.Security;
using AINotebook.Core.Language;
using AINotebook.Core.Storage;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Pure folder-rule classification. Skip precedence is ignored, then unsupported_ext, then over_limit.
/// The store recomputes extension/size verdicts from row values inside its rule transaction.
/// </summary>
public sealed class FolderRuleClassifier
{
    private readonly FolderRules _rules;
    private readonly FolderGlob[] _globs;

    public FolderRuleClassifier(FolderRules rules, bool caseSensitive, UnicodeTables tables)
    {
        ArgumentNullException.ThrowIfNull(rules);
        ArgumentNullException.ThrowIfNull(tables);
        // Compile and validate every pattern before any classification or write.
        _rules = rules.Validate(tables, caseSensitive);
        _globs = _rules.IgnoreGlobs.Select(pattern => new FolderGlob(pattern, caseSensitive, tables)).ToArray();
    }

    public FolderRules Rules => _rules;

    public bool PassesIgnoreGlobs(string relPath) => !_globs.Any(glob => glob.Matches(relPath));

    public (string Kind, string? SkipReason) Classify(string relPath, long? sizeBytes) =>
        Classify(PassesIgnoreGlobs(relPath), relPath, sizeBytes, _rules);

    public static (string Kind, string? SkipReason) Classify(bool passesIgnoreGlobs, string relPath, long? sizeBytes, FolderRules rules)
    {
        ArgumentNullException.ThrowIfNull(rules);
        if (!passesIgnoreGlobs) return ("skipped", "ignored");
        if (!NormalizeExtensions(rules.IncludeExts).Contains(Extension(relPath), StringComparer.Ordinal))
            return ("skipped", "unsupported_ext");
        if (sizeBytes is long size && size > rules.Limits.FileBytes) return ("skipped", "over_limit");
        return ("eligible", null);
    }

    /// <summary>ASCII-lowercased extension of the final component, without the dot; empty when absent.</summary>
    public static string Extension(string relPath)
    {
        ArgumentNullException.ThrowIfNull(relPath);
        string name = relPath[(relPath.LastIndexOf('/') + 1)..];
        int dot = name.LastIndexOf('.');
        return dot <= 0 || dot == name.Length - 1 ? "" : AsciiLower(name[(dot + 1)..]);
    }

    internal static IReadOnlyList<string> NormalizeExtensions(IReadOnlyList<string> extensions) =>
        extensions.Select(extension => AsciiLower(extension.StartsWith('.') ? extension[1..] : extension)).ToArray();

    private static string AsciiLower(string value) =>
        string.Concat(value.Select(c => c is >= 'A' and <= 'Z' ? (char)(c + ('a' - 'A')) : c));
}

/// <summary>
/// The durable state the scanner's stat fast path needs for one known file (a snapshot taken at scan start).
/// </summary>
internal sealed record FolderKnownSource(string Status, long? Mtime, long? SizeBytes, string? ContentHash, long? Current,
    long? Published, bool GaveUp = false)
{
    /// <summary>
    /// Equal stamp and either a committed hash, current published revision and ready status, or a source whose
    /// extraction was given up (<c>ingestion-retry-cap-v1</c>) — the store's fast-path predicate.
    /// </summary>
    public bool FastPath(FileStamp stamp) => Mtime == stamp.MtimeNs && SizeBytes == stamp.SizeBytes && (GaveUp ||
        ContentHash is not null && Published is not null && Current == Published && Status == "ready");
}

/// <summary>
/// Runs one fenced folder scan: walk on a worker thread, observations committed in bounded batches (at most
/// <see cref="ObserveBatchSize"/> files or <see cref="ObserveBatchInterval"/> per store transaction, contract
/// ingestion-scan-perf-v1), then an atomic completion. Filesystem IO never happens under the store gate.
/// The scan's <c>now</c> is only its start time; later fence checks read the injected clock.
/// </summary>
public sealed class FolderScanner
{
    private const int RuleRetries = 8;
    private readonly NotebookStore _store;
    private readonly IFolderFileSystem _fileSystem;
    private readonly UnicodeTables _tables;
    private readonly IIngestLeaseClock _clock;
    private readonly Func<int> _hashWidth;

    /// <param name="hashWidth">How many files a scan hashes concurrently, read once per scan (contract
    /// <c>ingestion-memory-pressure-v1</c> addendum A §A.5); default 1.</param>
    public FolderScanner(NotebookStore store, IFolderFileSystem fileSystem, UnicodeTables tables, IIngestLeaseClock? clock = null,
        Func<int>? hashWidth = null)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));
        _tables = tables ?? throw new ArgumentNullException(nameof(tables));
        _clock = clock ?? new SystemIngestLeaseClock();
        _hashWidth = hashWidth ?? (() => 1);
    }

    public Task ScanAsync(long folderId, bool verifyAll, JobFence fence, long now, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(fence);
        return Task.Run(() => ScanCoreAsync(folderId, verifyAll, fence, now, ct), CancellationToken.None);
    }

    public Task ApplyRulesAsync(long folderId, FolderRules rules, long now, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(rules);
        return Task.Run(() =>
        {
            ct.ThrowIfCancellationRequested();
            var folder = _store.Folder(folderId) ?? throw new StorageV19Exception("notFound");
            bool caseSensitive;
            try { caseSensitive = _fileSystem.CaseSensitive(folder); }
            catch (Exception error) when (IsAccessFailure(error))
            {
                // Rules can change while the root is offline; folding is the conservative ignore policy.
                caseSensitive = false;
            }
            var classifier = new FolderRuleClassifier(rules, caseSensitive, _tables);
            for (int attempt = 0; ; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                var eligibility = new Dictionary<string, bool>(StringComparer.Ordinal);
                var reasons = new Dictionary<string, string>(StringComparer.Ordinal);
                foreach (var (path, size) in _store.FolderRuleRows(folderId))
                {
                    var (kind, reason) = classifier.Classify(path, size);
                    eligibility[path] = kind == "eligible";
                    if (reason is not null) reasons[path] = reason;
                }
                try
                {
                    _store.ApplyFolderRules(folderId, classifier.Rules, eligibility, now, reasons);
                    return;
                }
                catch (StorageV19Exception error) when (error.Code == "staleRevision" && attempt < RuleRetries)
                {
                    // A path was observed after the verdicts were computed; recompute against the newer rows.
                }
            }
        }, CancellationToken.None);
    }

    /// <summary>Most observations committed per store transaction (contract ingestion-scan-perf-v1 §1).</summary>
    public const int ObserveBatchSize = 256;

    /// <summary>A non-empty batch is committed at the latest this long after the previous commit.</summary>
    public static readonly TimeSpan ObserveBatchInterval = TimeSpan.FromSeconds(1);

    private async Task ScanCoreAsync(long folderId, bool verifyAll, JobFence fence, long now, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        var folder = _store.Folder(folderId);
        if (folder is null) return;
        var ticket = _store.BeginFolderScan(folderId, fence, now);
        if (ticket is null) return;
        ScanCompletion completion;
        var batch = new ObservationBatch(this, ticket);
        try
        {
            var rules = NotebookStore.FolderRulesOf(folder);
            bool caseSensitive;
            try { caseSensitive = _fileSystem.CaseSensitive(folder); }
            catch (Exception error) when (IsAccessFailure(error))
            {
                _store.FinishFolderScan(ticket, new ScanCompletion([], [""], true, "rootUnavailable"), _clock.Now);
                return;
            }
            var classifier = new FolderRuleClassifier(rules, caseSensitive, _tables);
            // One snapshot for the fast path instead of a store round trip per file.
            var known = _store.FolderKnownSources(folder.Id);
            long maxBytes = classifier.Rules.Limits.FileBytes;
            var ahead = new ScanHashAhead(_hashWidth(), (path, token) => _fileSystem.Hash(folder, path, maxBytes, token));
            bool NeedsRead(FolderEntry entry) => !entry.IsDirectory && !entry.IsLink &&
                classifier.Classify(entry.RelPath, entry.Stamp.SizeBytes).Kind != "skipped" &&
                !(!verifyAll && known.TryGetValue(entry.RelPath, out var source) && source.FastPath(entry.Stamp));
            completion = await new FolderWalk(_fileSystem).WalkAsync(folder, () => ct.IsCancellationRequested,
                (entry, upcoming) => Visit(folder, batch, known, classifier, verifyAll, entry, upcoming, ahead, NeedsRead, ct),
                ct).ConfigureAwait(false);
            // Everything observed must be committed before completion may mark anything missing.
            batch.Flush();
        }
        catch (StorageV19Exception error) when (error.Code == "staleLease")
        {
            return; // The job lost its lease or a newer generation started; the new owner decides.
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            // Observations made before the cancellation stay durable (no missing-marking follows).
            batch.TryFlush();
            _store.MarkFolderScanCancelled(ticket, _clock.Now);
            throw;
        }
        catch (Exception error)
        {
            System.Diagnostics.Trace.TraceError("Folder scan failed: {0}", error.GetType().Name);
            batch.TryFlush();
            // Unexpected failures never mark anything missing.
            _store.FinishFolderScan(ticket, new ScanCompletion([], [""], false, "unexpectedError"), _clock.Now);
            return;
        }
        if (ct.IsCancellationRequested)
        {
            // A cancelled job cannot finish; only the current generation is marked partial.
            _store.MarkFolderScanCancelled(ticket, _clock.Now);
            ct.ThrowIfCancellationRequested();
        }
        _store.FinishFolderScan(ticket, completion, _clock.Now);
    }

    private async Task Visit(FolderSource folder, ObservationBatch batch, IReadOnlyDictionary<string, FolderKnownSource> known,
        FolderRuleClassifier classifier, bool verifyAll, FolderEntry entry, IEnumerable<FolderEntry> upcoming,
        ScanHashAhead ahead, Func<FolderEntry, bool> needsRead, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (entry.IsDirectory && !entry.IsLink) return;
        if (entry.IsLink)
        {
            // Links are never followed or created as sources; a known source replaced by one becomes ineligible.
            batch.Add(FolderScanObservation.InteriorLink(entry.RelPath, entry.Stamp));
            return;
        }
        var (kind, reason) = classifier.Classify(entry.RelPath, entry.Stamp.SizeBytes);
        if (kind == "skipped")
        {
            // Classification never opens ignored, unsupported or oversize file bodies.
            batch.Add(FolderScanObservation.File(new FolderObservation(entry.RelPath, entry.Stamp, kind, reason, null)));
            return;
        }
        if (!verifyAll && known.TryGetValue(entry.RelPath, out var source) && source.FastPath(entry.Stamp))
        {
            batch.Add(FolderScanObservation.File(new FolderObservation(entry.RelPath, entry.Stamp, "eligible", null, null)));
            return;
        }
        FolderRead read;
        try
        {
            // Upcoming files of this directory may be hashed ahead; this file's outcome (or error) is still handled
            // here, by its own visit.
            read = await ahead.ReadAsync(entry, upcoming, needsRead, ct).ConfigureAwait(false);
        }
        catch (FolderIngestionException error) when (error.Code == "fileLimit")
        {
            // The file grew past the limit after enumeration.
            long limit = classifier.Rules.Limits.FileBytes;
            batch.Add(FolderScanObservation.File(new FolderObservation(entry.RelPath,
                entry.Stamp with { SizeBytes = Math.Max(entry.Stamp.SizeBytes, limit + 1) }, "skipped", "over_limit", null)));
            return;
        }
        // Every other read failure propagates to the walk, as on macOS (contract ingestion-scan-perf-v1 §5): a file
        // that is unreadable (denied, locked), vanished, became a link or changed during the read is not observed and
        // only its directory becomes incomplete. Never an unhashed eligible observation: the store rejects one for a
        // new file (losing the batch) and would re-extract a known one.
        batch.Add(FolderScanObservation.File(new FolderObservation(entry.RelPath, read.Stamp, "eligible", null, read.Sha256)));
    }

    /// <summary>
    /// Pending observations of one walk (visits are sequential). Due at <see cref="ObserveBatchSize"/> entries or
    /// <see cref="ObserveBatchInterval"/> after the previous commit.
    /// </summary>
    private sealed class ObservationBatch(FolderScanner scanner, ScanTicket ticket)
    {
        private readonly List<FolderScanObservation> _items = [];
        private long _last = System.Diagnostics.Stopwatch.GetTimestamp();

        public void Add(FolderScanObservation item)
        {
            _items.Add(item);
            if (_items.Count >= ObserveBatchSize ||
                System.Diagnostics.Stopwatch.GetElapsedTime(_last) >= ObserveBatchInterval)
                Flush();
        }

        public void Flush()
        {
            _last = System.Diagnostics.Stopwatch.GetTimestamp();
            if (_items.Count == 0) return;
            var pending = _items.ToArray();
            _items.Clear();
            scanner._store.ObserveFolderFiles(ticket, pending, scanner._clock.Now);
        }

        /// <summary>Best effort on a failing or cancelled scan; the original outcome wins.</summary>
        public void TryFlush()
        {
            try { Flush(); }
            catch (Exception error) when (error is StorageV19Exception or SqliteException or InvalidOperationException)
            {
                System.Diagnostics.Trace.TraceWarning("Pending scan observations dropped: {0}", error.GetType().Name);
            }
        }
    }

    /// <summary>
    /// Hashes the files a scan must read <c>width</c> at a time, ahead of their visits, within the current directory
    /// (contract <c>ingestion-memory-pressure-v1</c> addendum A §A.5). A result (or captured exception) is consumed by
    /// its own file's visit, so a hash error keeps its per-file meaning and walk-order commits are unchanged. Width 1
    /// hashes inline, exactly as before. Hashing runs at below-normal thread priority.
    /// </summary>
    internal sealed class ScanHashAhead(int width, Func<string, CancellationToken, FolderRead> hash)
    {
        /// <summary>Files hashed per look-ahead round, per unit of width.</summary>
        internal const int RoundPerWidth = 8;
        private readonly ConcurrentDictionary<string, Outcome> _results = new(StringComparer.Ordinal);

        public int Width { get; } = Math.Max(width, 1);

        public async Task<FolderRead> ReadAsync(FolderEntry entry, IEnumerable<FolderEntry> upcoming,
            Func<FolderEntry, bool> needsRead, CancellationToken ct)
        {
            if (_results.TryRemove(entry.RelPath, out var cached)) return cached.Get();
            if (Width == 1) return BackgroundPriority.Run(() => hash(entry.RelPath, ct));
            string[] paths = [entry.RelPath, .. upcoming.Where(needsRead).Take(Width * RoundPerWidth - 1).Select(e => e.RelPath)];
            var outcomes = new Outcome[paths.Length];
            await Parallel.ForEachAsync(Enumerable.Range(0, paths.Length), new ParallelOptions { MaxDegreeOfParallelism = Width },
                (index, _) =>
                {
                    outcomes[index] = Capture(paths[index], ct);
                    return ValueTask.CompletedTask;
                }).ConfigureAwait(false);
            for (int index = 1; index < paths.Length; index++) _results[paths[index]] = outcomes[index];
            return outcomes[0].Get();
        }

        private Outcome Capture(string path, CancellationToken ct)
        {
            try
            {
                ct.ThrowIfCancellationRequested();
                return new Outcome(BackgroundPriority.Run(() => hash(path, ct)), null);
            }
            catch (Exception error) { return new Outcome(null, ExceptionDispatchInfo.Capture(error)); }
        }

        private readonly record struct Outcome(FolderRead? Read, ExceptionDispatchInfo? Error)
        {
            public FolderRead Get()
            {
                Error?.Throw();
                return Read!;
            }
        }
    }

    private static bool IsAccessFailure(Exception error) => error is IOException or UnauthorizedAccessException or
        SecurityException or FolderIngestionException
        {
            Code: "rootUnavailable" or "rootIdentityChanged" or "changedDuringExtraction" or "interiorLink" or "outsideRoot"
        };
}
