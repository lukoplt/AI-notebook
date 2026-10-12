using System.Runtime.InteropServices;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// System memory pressure as extraction admission sees it (contract <c>ingestion-memory-pressure-v1</c>):
/// <see cref="Warning"/> admits one concurrent extraction, <see cref="Critical"/> pauses new extractions,
/// <see cref="Normal"/> restores the configured limit.
/// </summary>
public enum MemoryPressureLevel
{
    Normal,
    Warning,
    Critical
}

/// <summary>Probe mappings and contract names for <see cref="MemoryPressureLevel"/>.</summary>
public static class MemoryPressureLevels
{
    public const int WarningLoadPercent = 85;
    public const int CriticalLoadPercent = 95;

    /// <summary><c>MEMORYSTATUSEX.dwMemoryLoad</c> percent: ≥ 95 critical, ≥ 85 warning, else normal.</summary>
    public static MemoryPressureLevel FromMemoryLoad(int percent) =>
        percent >= CriticalLoadPercent ? MemoryPressureLevel.Critical
        : percent >= WarningLoadPercent ? MemoryPressureLevel.Warning
        : MemoryPressureLevel.Normal;

    /// <summary>macOS <c>kern.memorystatus_vm_pressure_level</c> (parity with the Swift probe): 2 warning, 4 critical.</summary>
    public static MemoryPressureLevel FromDarwin(int rawLevel) => rawLevel switch
    {
        2 => MemoryPressureLevel.Warning,
        4 => MemoryPressureLevel.Critical,
        _ => MemoryPressureLevel.Normal
    };

    /// <summary>
    /// Samples the live system memory load (<c>GlobalMemoryStatusEx</c>) on Windows. Not <c>GC.GetGCMemoryInfo()</c>:
    /// that describes the last GC, which an idle process may not run for a long time. Fails open (normal).
    /// </summary>
    public static MemoryPressureLevel SampleWindows()
    {
        if (!OperatingSystem.IsWindows()) return MemoryPressureLevel.Normal;
        try
        {
            var status = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
            return GlobalMemoryStatusEx(ref status) ? FromMemoryLoad((int)status.MemoryLoad) : MemoryPressureLevel.Normal;
        }
        catch (Exception) { return MemoryPressureLevel.Normal; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", EntryPoint = "GlobalMemoryStatusEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);

    /// <summary>Concurrent extractions admitted at <paramref name="level"/>.</summary>
    public static int Concurrency(MemoryPressureLevel level, int maxExtractions) => level switch
    {
        MemoryPressureLevel.Warning => Math.Min(1, maxExtractions),
        MemoryPressureLevel.Critical => 0,
        _ => maxExtractions
    };

    /// <summary>Contract (camelCase) name.</summary>
    public static string ContractName(MemoryPressureLevel level) => level switch
    {
        MemoryPressureLevel.Warning => "warning",
        MemoryPressureLevel.Critical => "critical",
        _ => "normal"
    };
}

/// <summary>
/// Process-wide admission for background ingestion. Extractions hold a permit (at most
/// <c>maxExtractions</c>) plus a conservative memory reservation; waiters are served strictly FIFO.
/// A reservation larger than the budget runs alone, reserving the whole budget, and never deadlocks.
/// Chat turns hold tokens; only new background embedding batches wait for zero chat tokens.
/// Question embeddings and extraction never consult the chat gate.
/// Waiter continuations always run asynchronously, outside the private lock.
/// Memory pressure lowers the concurrency limit (warning → 1, critical → 0) and the adaptive limit (addendum A) bounds
/// it further; neither revokes granted permits.
/// </summary>
public sealed class IngestionAdmission
{
    private readonly object _lock = new();
    private readonly int _maxExtractions;
    private readonly long _budget;
    private readonly List<(Guid Token, long Bytes)> _reservations = [];
    private readonly LinkedList<Waiter> _waiters = new();
    private readonly List<Guid> _chat = [];
    private readonly LinkedList<TaskCompletionSource> _background = new();
    private MemoryPressureLevel _pressure = MemoryPressureLevel.Normal;
    private int _limit;

    public IngestionAdmission(int maxExtractions = 2, long memoryBytes = 536870912)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxExtractions, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(memoryBytes, 1L);
        _maxExtractions = maxExtractions;
        _budget = memoryBytes;
        _limit = maxExtractions;
    }

    /// <summary>
    /// The production admission for this machine (<c>ingestion-memory-pressure-v1</c> addendum A §A.2): half the logical
    /// cores (1…6) and 6 % of physical memory (512 MiB…1 GiB).
    /// </summary>
    public static IngestionAdmission Standard() =>
        new(AdaptiveConcurrency.MaxWorkers(Environment.ProcessorCount),
            AdaptiveConcurrency.MemoryBudget(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes));

    /// <summary>Extraction permits the admission can ever grant at once (the extraction dispatch loop count).</summary>
    public int MaxExtractions => _maxExtractions;

    /// <summary>The memory budget shared by granted extractions.</summary>
    public long MemoryBytes => _budget;

    /// <summary>
    /// Deterministic reservation: text <c>min(file, limit)*4 + scalars*8 + chunks*256</c>; Office and PDF
    /// add the expanded-Office allowance. Bounds admitted concurrent work, not allocations inside parsers.
    /// </summary>
    public static long ExtractionReservation(long fileBytes, string extension, IngestionLimits limits)
    {
        ArgumentNullException.ThrowIfNull(limits);
        ArgumentOutOfRangeException.ThrowIfNegative(fileBytes);
        checked
        {
            long bytes = Math.Min(fileBytes, limits.FileBytes) * 4 + (long)limits.TextScalars * 8 + (long)limits.Chunks * 256;
            if (extension is "docx" or "pptx" or "xlsx" or "pdf") bytes += limits.OfficeBytes;
            return bytes;
        }
    }

    public Task<Guid> AcquireExtractionAsync(long bytes, CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(bytes);
        ct.ThrowIfCancellationRequested();
        long reserve = Math.Min(bytes, _budget);
        Waiter waiter;
        lock (_lock)
        {
            if (_waiters.Count == 0 && CanGrant(reserve))
            {
                var token = Guid.NewGuid();
                _reservations.Add((token, reserve));
                return Task.FromResult(token);
            }
            waiter = new Waiter(bytes, reserve);
            waiter.Node = _waiters.AddLast(waiter);
        }
        if (ct.CanBeCanceled)
            waiter.Registration = ct.Register(() =>
            {
                bool removed;
                lock (_lock)
                {
                    removed = waiter.Node?.List is not null;
                    if (removed) _waiters.Remove(waiter.Node!);
                }
                if (removed)
                {
                    waiter.Completion.TrySetCanceled(ct);
                    // A cancelled head can unblock smaller waiters behind it.
                    Complete(Drain());
                }
            });
        return waiter.Completion.Task;
    }

    /// <summary>Idempotent: releasing an unknown or already released token does nothing.</summary>
    public void ReleaseExtraction(Guid token)
    {
        List<Action> grants;
        lock (_lock)
        {
            int index = _reservations.FindIndex(r => r.Token == token);
            if (index < 0) return;
            _reservations.RemoveAt(index);
            grants = DrainLocked();
        }
        Complete(grants);
    }

    /// <summary>The frozen folder-rag-v1 boolean form: <c>true</c> = critical, <c>false</c> = normal.</summary>
    public void SetMemoryPressure(bool blocked) =>
        SetMemoryPressure(blocked ? MemoryPressureLevel.Critical : MemoryPressureLevel.Normal);

    /// <summary>Applies the current level; lower pressure drains waiters in FIFO order.</summary>
    public void SetMemoryPressure(MemoryPressureLevel level)
    {
        List<Action> grants;
        lock (_lock)
        {
            _pressure = level;
            grants = DrainLocked();
        }
        Complete(grants);
    }

    /// <summary>The level last applied (indexing status runtime fact).</summary>
    public MemoryPressureLevel PressureLevel { get { lock (_lock) return _pressure; } }

    /// <summary>
    /// Applies the adaptive concurrency limit (addendum A), clamped to <c>1…maxExtractions</c>. Lowering never revokes
    /// granted permits; raising drains waiters in FIFO order.
    /// </summary>
    public void SetConcurrencyLimit(int limit)
    {
        List<Action> grants;
        lock (_lock)
        {
            _limit = Math.Min(Math.Max(limit, 1), _maxExtractions);
            grants = DrainLocked();
        }
        Complete(grants);
    }

    /// <summary>The adaptive limit last applied.</summary>
    public int ConcurrencyLimit { get { lock (_lock) return _limit; } }

    /// <summary>Extractions currently holding a permit.</summary>
    public int RunningExtractions { get { lock (_lock) return _reservations.Count; } }

    public Guid BeginChat()
    {
        var token = Guid.NewGuid();
        lock (_lock) _chat.Add(token);
        return token;
    }

    /// <summary>Idempotent. Background batches resume only when every chat token has ended.</summary>
    public void EndChat(Guid token)
    {
        List<TaskCompletionSource> resumed = [];
        lock (_lock)
        {
            if (!_chat.Remove(token) || _chat.Count != 0) return;
            resumed.AddRange(_background);
            _background.Clear();
        }
        foreach (var completion in resumed) completion.TrySetResult();
    }

    /// <summary>Call immediately before each new background provider batch; an already sent batch may finish.</summary>
    public Task WaitForBackgroundBatchAsync(CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        LinkedListNode<TaskCompletionSource> node;
        lock (_lock)
        {
            if (_chat.Count == 0) return Task.CompletedTask;
            node = _background.AddLast(completion);
        }
        if (ct.CanBeCanceled)
        {
            var registration = ct.Register(() =>
            {
                lock (_lock) if (node.List is not null) _background.Remove(node);
                completion.TrySetCanceled(ct);
            });
            completion.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        }
        return completion.Task;
    }

    // Test/diagnostic snapshots (internal): FIFO and grant order are part of the shared fixtures.
    internal IReadOnlyList<(Guid Token, long Bytes)> Reservations { get { lock (_lock) return _reservations.ToArray(); } }
    internal IReadOnlyList<long> WaitingBytes { get { lock (_lock) return _waiters.Select(w => w.Requested).ToArray(); } }
    internal IReadOnlyList<Guid> ChatTokens { get { lock (_lock) return _chat.ToArray(); } }
    internal int BackgroundWaiters { get { lock (_lock) return _background.Count; } }
    internal bool MemoryPressure { get { lock (_lock) return _pressure != MemoryPressureLevel.Normal; } }
    internal IReadOnlyList<Guid> ReservationTokens { get { lock (_lock) return _reservations.Select(r => r.Token).ToArray(); } }

    private bool CanGrant(long reserve) =>
        _reservations.Count < Math.Min(_limit, MemoryPressureLevels.Concurrency(_pressure, _maxExtractions))
        && _reservations.Sum(r => r.Bytes) + reserve <= _budget;

    private List<Action> Drain()
    {
        lock (_lock) return DrainLocked();
    }

    private List<Action> DrainLocked()
    {
        var grants = new List<Action>();
        // Strict FIFO: a large head waiter is never overtaken, so it cannot starve.
        while (_waiters.First is { } first && CanGrant(first.Value.Reserve))
        {
            var waiter = first.Value;
            _waiters.RemoveFirst();
            waiter.Node = null;
            var token = Guid.NewGuid();
            _reservations.Add((token, waiter.Reserve));
            grants.Add(() =>
            {
                waiter.Registration.Dispose();
                if (!waiter.Completion.TrySetResult(token)) ReleaseExtraction(token);
            });
        }
        return grants;
    }

    private static void Complete(List<Action> grants)
    {
        foreach (var grant in grants) grant();
    }

    private sealed class Waiter(long requested, long reserve)
    {
        public long Requested { get; } = requested;
        public long Reserve { get; } = reserve;
        public TaskCompletionSource<Guid> Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public LinkedListNode<Waiter>? Node { get; set; }
        public CancellationTokenRegistration Registration { get; set; }
    }
}
