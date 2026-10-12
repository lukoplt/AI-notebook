using System.Buffers.Binary;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed record VectorCacheStatistics(long ResidentBytes, long ReservedBytes, int LoadCount, int EntryCount);

/// <summary>
/// Process-wide leased LRU of normalized generation matrices. One private gate
/// covers the dictionaries and the byte ledger only; fills, SQL, awaits and dot
/// products always run outside it. Every matrix and every in-flight reservation is
/// charged against one budget, including invalidated matrices still held by leases.
/// </summary>
public sealed class VectorMatrixCache
{
    /// <summary>The process-wide cache scales its budget with physical memory (retrieval-resident-v1 §4).</summary>
    public static VectorMatrixCache Shared { get; } = new(ResidentBudget(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes));

    /// <summary>clamp(physical / 16, globalBudgetBytes, 1 GiB): 512 MiB on 8 GB, 1 GiB on 16 GB or more.</summary>
    public static long ResidentBudget(long physicalMemory)
        => Math.Min(Math.Max(Math.Max(physicalMemory, 0) / 16, RagContractV1.Cache.GlobalBudgetBytes), 1L << 30);

    private sealed class ResidentEntry(ResidentVectorMatrix matrix)
    {
        internal ResidentVectorMatrix Matrix { get; set; } = matrix;
        internal long Bytes { get; set; }
        internal long Tick { get; set; }
    }
    private readonly Dictionary<ResidentMatrixKey, ResidentEntry> _residents = new();
    private readonly Dictionary<ResidentMatrixKey, object> _residentLocks = new();
    private readonly HashSet<ResidentMatrixKey> _residentBusy = new();

    private readonly object _gate = new();
    private readonly MatrixBudget _budget;
    private readonly Dictionary<RetrievalCacheKey, MatrixEntry> _ready = new();
    private readonly Dictionary<RetrievalCacheKey, MatrixFill> _loading = new();
    private long _tick;
    private int _loadCount;
    private int _activeFills;
    private TaskCompletionSource? _idle;

    public VectorMatrixCache(long budgetBytes = RagContractV1.Cache.GlobalBudgetBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(budgetBytes);
        _budget = new MatrixBudget(budgetBytes);
    }

    /// <summary>
    /// Returns a lease on the cached matrix, or null when the caller must stream its
    /// pinned generation (not admissible, invalidated during fill, or epoch changed).
    /// </summary>
    public async Task<VectorMatrixLease?> AcquireAsync(RetrievalCacheKey key, int rowCount, int dims,
        Func<ulong> epoch, Func<VectorMatrixBuilder, CancellationToken, Task> fill, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(key);
        ArgumentNullException.ThrowIfNull(epoch);
        ArgumentNullException.ThrowIfNull(fill);
        ct.ThrowIfCancellationRequested();
        ulong captured = epoch();
        MatrixFill? started = null;
        MatrixFill joined;
        FillWaiter waiter;
        lock (_gate)
        {
            if (_ready.TryGetValue(key, out var entry))
            {
                entry.LeaseCount++;
                entry.Tick = ++_tick;
                return new VectorMatrixLease(this, entry);
            }
            if (_loading.TryGetValue(key, out var loading))
            {
                joined = loading;
            }
            else
            {
                if (MatrixBudget.Charge(rowCount, dims) is not long charge || !TryReserve(charge)) return null;
                // The builder is allocated only after the reservation has succeeded.
                joined = started = new MatrixFill(key, charge, new VectorMatrixBuilder(rowCount, dims));
                _loading.Add(key, started);
                _loadCount++;
                _activeFills++;
            }
            waiter = new FillWaiter();
            joined.Waiters.Add(waiter);
        }
        // Start the fill inline, outside the gate: its synchronous prefix (for example,
        // borrowing its own retrieval operation) runs before this call can return.
        if (started is not null) _ = RunFillAsync(started, captured, epoch, fill);
        try
        {
            return await waiter.Completion.Task.WaitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            CancelWaiter(joined, waiter);
            throw;
        }
    }

    /// <summary>Test-only array loader. It feeds its rows as one page into the production builder.</summary>
    internal Task<VectorMatrixLease?> AcquireAsync(RetrievalCacheKey key, int rowCount, int dims,
        Func<ulong> epoch, Func<CancellationToken, Task<IReadOnlyList<VectorRow>>> load, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(load);
        return AcquireAsync(key, rowCount, dims, epoch, async (builder, token) =>
            builder.Append(await load(token).ConfigureAwait(false)), ct);
    }

    public void Invalidate(string databaseId)
    {
        lock (_gate)
        {
            foreach (var (key, entry) in _ready.Where(p => StringComparer.Ordinal.Equals(p.Key.DatabaseId, databaseId)).ToArray())
            {
                _ready.Remove(key);
                entry.Retired = true;
                if (entry.LeaseCount == 0) Free(entry);
            }
            foreach (var (key, loading) in _loading.Where(p => StringComparer.Ordinal.Equals(p.Key.DatabaseId, databaseId)).ToArray())
            {
                // The slot keeps its reservation until the fill finishes, but may never publish.
                loading.Invalidated = true;
                _loading.Remove(key);
            }
            foreach (var key in _residents.Keys.Where(k => StringComparer.Ordinal.Equals(k.DatabaseId, databaseId)
                && !_residentBusy.Contains(k)).ToArray())
                DropResident(key);
        }
    }

    // ----------------------------------------------------- resident generation matrices

    /// <summary>
    /// Loads the pinned pairs this generation's resident matrix lacks (one load per key at a
    /// time; concurrent callers wait), then scores. Null when the matrix cannot be kept within
    /// the budget: the caller streams. SQL runs outside the cache gate.
    /// </summary>
    internal ResidentScan? ResidentTopK(ResidentMatrixKey key, IReadOnlyDictionary<long, long> pins,
        IReadOnlyDictionary<long, long> allowed, float[] query, int k,
        Func<IReadOnlyDictionary<long, long>, int> count,
        Func<IReadOnlyDictionary<long, long>, ResidentBlock, bool> fill, CancellationToken ct)
    {
        object keyLock;
        lock (_gate)
        {
            if (!_residentLocks.TryGetValue(key, out keyLock!)) _residentLocks[key] = keyLock = new object();
        }
        lock (keyLock)
        {
            ct.ThrowIfCancellationRequested();
            ResidentEntry? entry;
            lock (_gate) _residents.TryGetValue(key, out entry);
            var missing = (entry?.Matrix ?? new ResidentVectorMatrix(key.Dims)).Missing(pins);
            if (missing.Count > 0)
            {
                lock (_gate) _residentBusy.Add(key);
                try
                {
                    int rows = count(missing);
                    long? charge = ResidentBlock.Charge(rows, key.Dims);
                    bool reserved;
                    lock (_gate) reserved = charge is long c && (c == 0 || ReserveEvicting(c, key));
                    if (!reserved)
                    {
                        lock (_gate) DropResident(key);
                        return null;
                    }
                    var block = new ResidentBlock(rows, key.Dims);
                    bool complete;
                    try { complete = fill(missing, block); }
                    catch
                    {
                        lock (_gate) if (charge > 0) _budget.Abandon(charge!.Value);
                        throw;
                    }
                    lock (_gate)
                    {
                        if (charge > 0) _budget.Abandon(charge!.Value);
                        // More rows than counted: never keep a partial pair; this query streams.
                        if (!complete) return null;
                        long actual = ResidentBlock.Charge(block.Count, key.Dims)!.Value;
                        if (actual > 0 && !_budget.Reserve(actual)) { DropResident(key); return null; }
                        if (actual > 0) _budget.Commit(actual);
                        if (!_residents.TryGetValue(key, out entry))
                            _residents[key] = entry = new ResidentEntry(new ResidentVectorMatrix(key.Dims));
                        entry.Matrix.Commit(block, missing);
                        entry.Bytes += actual;
                        if (entry.Matrix.GarbageRows > Math.Max(4096, entry.Matrix.Rows / 2))
                        {
                            var compacted = entry.Matrix.Compacted();
                            _budget.DropResident(entry.Bytes);
                            entry.Matrix = compacted;
                            entry.Bytes = compacted.Bytes;
                            _budget.ForceResident(entry.Bytes);
                        }
                        _loadCount++;
                    }
                }
                finally
                {
                    lock (_gate) _residentBusy.Remove(key);
                }
            }
            lock (_gate)
            {
                if (!_residents.TryGetValue(key, out entry)) return pins.Count == 0 ? new ResidentScan([], 0, 0) : null;
                entry.Tick = ++_tick;
            }
            var matrix = entry.Matrix;
            return new ResidentScan(matrix.TopK(query, allowed, k), matrix.InvalidVectorCount, matrix.PeakPageBytes);
        }
    }

    // Caller holds _gate. Evicts least-recently-used unleased matrices and idle resident generations.
    private bool ReserveEvicting(long bytes, ResidentMatrixKey keeping)
    {
        while (!_budget.Reserve(bytes))
        {
            var resident = _residents.Where(p => !p.Key.Equals(keeping) && !_residentBusy.Contains(p.Key))
                .OrderBy(p => p.Value.Tick).Select(p => (KeyValuePair<ResidentMatrixKey, ResidentEntry>?)p).FirstOrDefault();
            var entry = _ready.Values.Where(e => e.LeaseCount == 0).OrderBy(e => e.Tick).FirstOrDefault();
            if (resident is { } r && (entry is null || r.Value.Tick <= entry.Tick)) DropResident(r.Key);
            else if (entry is not null)
            {
                _ready.Remove(entry.Key);
                Free(entry);
            }
            else return false;
        }
        return true;
    }

    // Caller holds _gate.
    private void DropResident(ResidentMatrixKey key)
    {
        if (_residents.Remove(key, out var entry)) _budget.DropResident(entry.Bytes);
    }

    /// <summary>A store reopened its database: matrices under the retired identity are unreachable.</summary>
    public void DropResidents(string databaseInstance)
    {
        lock (_gate)
            foreach (var key in _residents.Keys.Where(k => k.DatabaseInstance == databaseInstance && !_residentBusy.Contains(k)).ToArray())
                DropResident(key);
    }

    /// <summary>Memory pressure: drops every resident matrix that no load is extending.</summary>
    public void TrimResidents()
    {
        lock (_gate)
            foreach (var key in _residents.Keys.Where(k => !_residentBusy.Contains(k)).ToArray()) DropResident(key);
    }

    internal int? ResidentRowCount(ResidentMatrixKey key)
    {
        lock (_gate) return _residents.TryGetValue(key, out var entry) ? entry.Matrix.Rows : null;
    }

    public VectorCacheStatistics Statistics()
    {
        lock (_gate) return new(_budget.Resident, _budget.Reserved, _loadCount, _ready.Count + _residents.Count);
    }

    internal IReadOnlyList<RetrievalCacheKey> ResidentKeys()
    {
        lock (_gate)
            return _ready.Keys.OrderBy(k => k.DatabaseId, StringComparer.Ordinal)
                .ThenBy(k => k.NotebookId).ThenBy(k => k.GenerationId).ThenBy(k => k.Epoch).ToArray();
    }

    /// <summary>Completes once no fill is running, i.e. every abandoned reservation has been refunded.</summary>
    internal Task WhenIdleAsync()
    {
        lock (_gate)
        {
            if (_activeFills == 0) return Task.CompletedTask;
            _idle ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            return _idle.Task;
        }
    }

    // Caller holds _gate. Never evicts unless eviction can actually admit the charge.
    private bool TryReserve(long charge)
    {
        if (_budget.Reserve(charge)) return true;
        long evictable = _ready.Values.Where(e => e.LeaseCount == 0).Sum(e => e.Bytes);
        if (charge > _budget.Limit || _budget.Resident - evictable > _budget.Limit - charge - _budget.Reserved) return false;
        while (!_budget.Reserve(charge))
        {
            var victim = _ready.Values.Where(e => e.LeaseCount == 0)
                .OrderBy(e => e.Tick)
                .ThenBy(e => e.Key.DatabaseId, StringComparer.Ordinal)
                .ThenBy(e => e.Key.NotebookId).ThenBy(e => e.Key.GenerationId).ThenBy(e => e.Key.Epoch)
                .FirstOrDefault();
            if (victim is null) return false;
            _ready.Remove(victim.Key);
            Free(victim);
        }
        return true;
    }

    // Caller holds _gate.
    private void Free(MatrixEntry entry)
    {
        if (entry.Matrix is null) return;
        _budget.DropResident(entry.Bytes);
        entry.Matrix = null;
    }

    private async Task RunFillAsync(MatrixFill loading, ulong captured, Func<ulong> epoch,
        Func<VectorMatrixBuilder, CancellationToken, Task> fill)
    {
        Exception? failure = null;
        bool current = false;
        try
        {
            await fill(loading.Builder, loading.Cancellation.Token).ConfigureAwait(false);
            loading.Cancellation.Token.ThrowIfCancellationRequested();
            current = epoch() == captured;
        }
        catch (Exception error)
        {
            failure = error;
        }
        var matrix = loading.Builder.Seal();
        Complete(loading, matrix, current, failure);
    }

    private void Complete(MatrixFill loading, VectorMatrix matrix, bool current, Exception? failure)
    {
        List<(FillWaiter Waiter, VectorMatrixLease? Lease)> outcomes;
        TaskCompletionSource? idle = null;
        lock (_gate)
        {
            if (_loading.TryGetValue(loading.Key, out var registered) && ReferenceEquals(registered, loading))
                _loading.Remove(loading.Key);
            loading.Done = true;
            var waiters = loading.Waiters.ToArray();
            loading.Waiters.Clear();
            outcomes = new(waiters.Length);
            if (failure is null && current && !loading.Invalidated && waiters.Length > 0)
            {
                _budget.Commit(loading.Bytes);
                var entry = new MatrixEntry(loading.Key, loading.Bytes, matrix)
                {
                    LeaseCount = waiters.Length,
                    Tick = ++_tick,
                };
                _ready[loading.Key] = entry;
                foreach (var waiter in waiters)
                {
                    var lease = new VectorMatrixLease(this, entry);
                    waiter.Granted = lease;
                    outcomes.Add((waiter, lease));
                }
            }
            else
            {
                _budget.Abandon(loading.Bytes);
                foreach (var waiter in waiters) outcomes.Add((waiter, null));
            }
            if (--_activeFills == 0) { idle = _idle; _idle = null; }
        }
        loading.Cancellation.Dispose();
        foreach (var (waiter, lease) in outcomes)
        {
            if (lease is not null || failure is null) waiter.Completion.TrySetResult(lease);
            else waiter.Completion.TrySetException(failure);
        }
        idle?.TrySetResult();
    }

    private void CancelWaiter(MatrixFill loading, FillWaiter waiter)
    {
        VectorMatrixLease? granted;
        bool cancelFill = false;
        lock (_gate)
        {
            granted = waiter.Granted;
            if (granted is null && loading.Waiters.Remove(waiter) && loading.Waiters.Count == 0 && !loading.Done)
            {
                // The last waiter left: stop single-flight sharing and cancel the fill;
                // the fill's completion refunds its reservation exactly once.
                if (_loading.TryGetValue(loading.Key, out var registered) && ReferenceEquals(registered, loading))
                    _loading.Remove(loading.Key);
                cancelFill = true;
            }
        }
        // A grant that raced the caller's cancellation is released, never leaked.
        granted?.Dispose();
        if (cancelFill)
        {
            try { loading.Cancellation.Cancel(); }
            catch (ObjectDisposedException) { }
        }
    }

    internal void Release(MatrixEntry entry)
    {
        lock (_gate)
        {
            if (entry.LeaseCount <= 0) throw new InvalidOperationException("Unbalanced vector matrix lease");
            entry.LeaseCount--;
            if (entry.Retired && entry.LeaseCount == 0) Free(entry);
        }
    }

    private sealed class MatrixFill(RetrievalCacheKey key, long bytes, VectorMatrixBuilder builder)
    {
        internal RetrievalCacheKey Key { get; } = key;
        internal long Bytes { get; } = bytes;
        internal VectorMatrixBuilder Builder { get; } = builder;
        internal CancellationTokenSource Cancellation { get; } = new();
        internal List<FillWaiter> Waiters { get; } = new();
        internal bool Invalidated { get; set; }
        internal bool Done { get; set; }
    }

    private sealed class FillWaiter
    {
        internal TaskCompletionSource<VectorMatrixLease?> Completion { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal VectorMatrixLease? Granted { get; set; }
    }
}

internal sealed class MatrixEntry(RetrievalCacheKey key, long bytes, VectorMatrix matrix)
{
    internal RetrievalCacheKey Key { get; } = key;
    internal long Bytes { get; } = bytes;
    internal VectorMatrix? Matrix { get; set; } = matrix;
    internal int LeaseCount { get; set; }
    internal long Tick { get; set; }
    internal bool Retired { get; set; }
}

/// <summary>Immutable normalized matrix: one Float32 slab plus four Int64 metadata columns.</summary>
internal sealed class VectorMatrix(int rowCount, int dims, float[] slab, long[] chunkIds, long[] sourceIds,
    long[] revisionIds, long[] ords, int invalidCount)
{
    internal int RowCount { get; } = rowCount;
    internal int Dims { get; } = dims;
    internal int InvalidCount { get; } = invalidCount;

    internal IReadOnlyList<ScoredChunk> TopK(float[] query, IReadOnlySet<long> permittedSources, int k)
    {
        var heap = MaskedVectorTopK.Create(query, Dims, permittedSources, k);
        if (heap is null) return Array.Empty<ScoredChunk>();
        for (int row = 0; row < RowCount; row++)
        {
            // Mask before constructing a reference or computing a dot product.
            if (!permittedSources.Contains(sourceIds[row])) continue;
            heap.Offer(new ChunkReference(chunkIds[row], sourceIds[row], revisionIds[row], (int)ords[row]),
                slab.AsSpan(row * Dims, Dims));
        }
        return heap.Sorted();
    }
}

/// <summary>
/// Exclusively owned loading buffer sized to the reserved row capacity. Only the
/// fill worker appends; completion seals it permanently.
/// </summary>
public sealed class VectorMatrixBuilder
{
    private readonly object _gate = new();
    private readonly int _capacity;
    private readonly int _dims;
    private readonly float[] _slab;
    private readonly long[] _chunkIds, _sourceIds, _revisionIds, _ords;
    private int _offered, _count, _invalid;
    private bool _sealed;

    internal VectorMatrixBuilder(int rowCapacity, int dims)
    {
        _capacity = rowCapacity;
        _dims = dims;
        _slab = new float[checked(rowCapacity * dims)];
        _chunkIds = new long[rowCapacity];
        _sourceIds = new long[rowCapacity];
        _revisionIds = new long[rowCapacity];
        _ords = new long[rowCapacity];
    }

    public void Append(IReadOnlyList<VectorRow> page)
    {
        ArgumentNullException.ThrowIfNull(page);
        lock (_gate)
        {
            Reserve(page.Count);
            foreach (var row in page)
            {
                if (row.Values.Length != _dims) { _invalid++; continue; }
                var target = _slab.AsSpan(_count * _dims, _dims);
                row.Values.CopyTo(target);
                Commit(row.Reference, target);
            }
        }
    }

    /// <summary>Decodes a raw SQLite page straight into the slab without per-row arrays.</summary>
    internal void AppendRaw(RawVectorPage page)
    {
        ArgumentNullException.ThrowIfNull(page);
        lock (_gate)
        {
            Reserve(page.Rows.Count);
            foreach (var row in page.Rows)
            {
                if (row.Blob is not byte[] bytes || bytes.LongLength != (long)_dims * sizeof(float)) { _invalid++; continue; }
                var target = _slab.AsSpan(_count * _dims, _dims);
                for (int i = 0; i < _dims; i++)
                    target[i] = BitConverter.Int32BitsToSingle(
                        BinaryPrimitives.ReadInt32LittleEndian(bytes.AsSpan(i * sizeof(float), sizeof(float))));
                Commit(row.Reference, target);
            }
        }
    }

    // Caller holds _gate.
    private void Reserve(int rows)
    {
        if (_sealed) throw new InvalidOperationException("Vector matrix builder is sealed");
        if (rows > _capacity - _offered)
            throw new InvalidOperationException("Vector matrix fill exceeded its reserved row capacity");
        _offered += rows;
    }

    // Caller holds _gate. Nonfinite rows are rejected; legacy zero rows stay zero.
    private void Commit(ChunkReference reference, Span<float> target)
    {
        if (!MaskedVectorTopK.Normalize(target, allowZero: true)) { _invalid++; return; }
        _chunkIds[_count] = reference.ChunkId;
        _sourceIds[_count] = reference.SourceId;
        _revisionIds[_count] = reference.RevisionId;
        _ords[_count] = reference.Ord;
        _count++;
    }

    internal VectorMatrix Seal()
    {
        lock (_gate)
        {
            _sealed = true;
            return new VectorMatrix(_count, _dims, _slab, _chunkIds, _sourceIds, _revisionIds, _ords, _invalid);
        }
    }
}

public sealed class VectorMatrixLease : IDisposable
{
    private readonly VectorMatrixCache _cache;
    private readonly MatrixEntry _entry;
    private VectorMatrix? _matrix;

    internal VectorMatrixLease(VectorMatrixCache cache, MatrixEntry entry)
    {
        _cache = cache;
        _entry = entry;
        _matrix = entry.Matrix ?? throw new InvalidOperationException("Leased a freed vector matrix");
    }

    /// <summary>Stored rows rejected while filling (wrong width or nonfinite).</summary>
    public int InvalidVectorCount =>
        (Volatile.Read(ref _matrix) ?? throw new ObjectDisposedException(nameof(VectorMatrixLease))).InvalidCount;

    public IReadOnlyList<ScoredChunk> TopK(float[] query, IReadOnlySet<long> permittedSources, int k)
    {
        ArgumentNullException.ThrowIfNull(query);
        ArgumentNullException.ThrowIfNull(permittedSources);
        var matrix = Volatile.Read(ref _matrix) ?? throw new ObjectDisposedException(nameof(VectorMatrixLease));
        return matrix.TopK(query, permittedSources, k);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _matrix, null) is not null) _cache.Release(_entry);
    }
}

/// <summary>Byte ledger for matrices and reservations; mutated only under the cache gate.</summary>
internal sealed class MatrixBudget(long limit)
{
    internal long Limit { get; } = limit;
    internal long Resident { get; private set; }
    internal long Reserved { get; private set; }

    internal static long? Charge(int rows, int dims)
    {
        if (rows <= 0 || dims <= 0) return null;
        try { return checked((long)rows * (checked((long)dims * 4) + 32)); }
        catch (OverflowException) { return null; }
    }

    internal bool Reserve(long bytes)
    {
        if (bytes <= 0 || bytes > Limit || Resident > Limit - bytes || Reserved > Limit - bytes - Resident) return false;
        Reserved += bytes;
        return true;
    }

    internal void Commit(long bytes)
    {
        if (Reserved < bytes) throw new InvalidOperationException();
        Reserved -= bytes;
        Resident += bytes;
    }

    internal void Abandon(long bytes)
    {
        if (Reserved < bytes) throw new InvalidOperationException();
        Reserved -= bytes;
    }

    /// <summary>Re-charges bytes that were resident a moment ago (compaction never grows them).</summary>
    internal void ForceResident(long bytes) => Resident += bytes;

    internal void DropResident(long bytes)
    {
        if (Resident < bytes) throw new InvalidOperationException();
        Resident -= bytes;
    }
}
