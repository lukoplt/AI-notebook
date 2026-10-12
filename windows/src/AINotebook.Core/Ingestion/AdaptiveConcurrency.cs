using System.Runtime.InteropServices;

namespace AINotebook.Core.Ingestion;

/// <summary>Thermal state as the adaptive concurrency policy sees it.</summary>
public enum ThermalState
{
    Nominal,
    Fair,
    Serious,
    Critical
}

/// <summary>One cheap sample of the machine's state.</summary>
/// <param name="Cores">Logical processors.</param>
/// <param name="LoadMilli">System runnable load in thousandths of a core, our own work included.</param>
public readonly record struct SystemSample(int Cores, int LoadMilli, ThermalState Thermal = ThermalState.Nominal,
    bool LowPower = false, bool OnBattery = false);

/// <summary>
/// How many extractions run at once (contract <c>ingestion-memory-pressure-v1</c> addendum A, fixture
/// <c>ingestion-adaptive-concurrency-v1</c>): more cores only while the computer is idle, on power and cool; step
/// down at once otherwise.
/// </summary>
public static class AdaptiveConcurrency
{
    public const int MaxWorkersCap = 6;
    public const int InitialWorkers = 2;
    internal const int BatteryWorkers = 2;
    internal const int BusyWorkers = 2;
    internal const int ConstrainedWorkers = 1;
    internal const int MaxHashWidth = 4;
    internal const long MinBudgetBytes = 512L * 1_048_576;
    internal const long MaxBudgetBytes = 1024L * 1_048_576;
    internal const long BudgetPercent = 6;

    /// <summary>A higher target must hold this long before the limit rises.</summary>
    public const long RaiseAfterMs = 30_000;

    /// <summary>The system probe is sampled at most this often (memory pressure: every tick).</summary>
    public const long SampleIntervalMs = 2_000;

    /// <summary>Extraction worker cap for the process: half the logical cores, 1…6.</summary>
    public static int MaxWorkers(int cores) => Math.Min(Math.Max(cores / 2, 1), MaxWorkersCap);

    /// <summary>Admission memory budget: 6 % of physical memory, 512 MiB…1 GiB.</summary>
    public static long MemoryBudget(long physicalBytes)
    {
        long physical = Math.Max(physicalBytes, 0);
        long scaled = physical > long.MaxValue / BudgetPercent ? long.MaxValue : physical * BudgetPercent / 100;
        return Math.Min(Math.Max(scaled, MinBudgetBytes), MaxBudgetBytes);
    }

    /// <summary>Concurrent file hashes of a folder scan for the current extraction limit.</summary>
    public static int HashWidth(int extractionLimit) => Math.Min(Math.Max(extractionLimit, 1), MaxHashWidth);

    /// <summary>Target worker count; 0 only for critical memory pressure.</summary>
    public static int Target(SystemSample sample, int ownWorkers, MemoryPressureLevel memory)
    {
        if (memory == MemoryPressureLevel.Critical) return 0;
        int t = MaxWorkers(sample.Cores);
        if (memory == MemoryPressureLevel.Warning || sample.Thermal is ThermalState.Serious or ThermalState.Critical || sample.LowPower)
            t = Math.Min(t, ConstrainedWorkers);
        if (sample.OnBattery) t = Math.Min(t, BatteryWorkers);
        // Our own running extractions are part of the system load; only the rest counts.
        long external = Math.Max(0, (long)sample.LoadMilli - 1000L * Math.Max(ownWorkers, 0));
        long capacity = 1000L * Math.Max(sample.Cores, 1);
        if (external >= capacity) t = Math.Min(t, ConstrainedWorkers);
        else if (2 * external >= capacity) t = Math.Min(t, BusyWorkers);
        return Math.Max(t, 1);
    }

    /// <summary><c>ProcessInfo.ThermalState</c> raw value (parity with the Swift probe); anything unknown is nominal.</summary>
    public static ThermalState FromDarwinThermal(int rawValue) => rawValue switch
    {
        1 => ThermalState.Fair,
        2 => ThermalState.Serious,
        3 => ThermalState.Critical,
        _ => ThermalState.Nominal
    };

    /// <summary><c>SYSTEM_POWER_STATUS</c>: ACLineStatus 0 = on battery (1 and 255 "unknown" are not); SystemStatusFlag
    /// bit 0 = battery saver.</summary>
    public static (bool OnBattery, bool LowPower) FromWindowsPower(int acLineStatus, int systemStatusFlag) =>
        (acLineStatus == 0, (systemStatusFlag & 1) == 1);

    /// <summary><c>GetSystemTimes</c> deltas (kernel time includes idle) → load in thousandths of a core.</summary>
    public static int FromWindowsTimes(long idle, long kernel, long user, int cores)
    {
        long total = kernel + user;
        if (total <= 0) return 0;
        long busy = Math.Min(Math.Max(total - idle, 0), total);
        return (int)((decimal)busy * Math.Max(cores, 1) * 1000 / total);
    }

    /// <summary>Contract (camelCase) name.</summary>
    public static string ContractName(ThermalState state) => state switch
    {
        ThermalState.Fair => "fair",
        ThermalState.Serious => "serious",
        ThermalState.Critical => "critical",
        _ => "nominal"
    };
}

/// <summary>Hysteresis: lower at once; raise only after a higher target held <see cref="AdaptiveConcurrency.RaiseAfterMs"/>.</summary>
public sealed class ConcurrencyGovernor
{
    private long? _since;

    public ConcurrencyGovernor(int cap)
    {
        Cap = Math.Max(cap, 1);
        Limit = Math.Min(Cap, AdaptiveConcurrency.InitialWorkers);
    }

    public int Cap { get; }
    public int Limit { get; private set; }

    public int Observe(int target, long atMs)
    {
        int value = Math.Min(Math.Max(target, 1), Cap);
        if (value <= Limit)
        {
            Limit = value;
            _since = null;
            return Limit;
        }
        if (_since is null || atMs < _since) _since = atMs;
        if (atMs - _since >= AdaptiveConcurrency.RaiseAfterMs)
        {
            Limit = value;
            _since = null;
        }
        return Limit;
    }
}

/// <summary>
/// Live Windows probe: system load from <c>GetSystemTimes</c> deltas between calls, power from
/// <c>GetSystemPowerStatus</c>. Windows exposes no thermal state to unpackaged desktop apps (nominal). Every part fails
/// open (load 0, on AC, no battery saver); off Windows the sample is idle.
/// </summary>
public sealed class WindowsSystemProbe
{
    private readonly object _lock = new();
    private (long Idle, long Kernel, long User)? _previous;

    public SystemSample Sample()
    {
        int cores = Environment.ProcessorCount;
        if (!OperatingSystem.IsWindows()) return new SystemSample(cores, 0);
        int load = 0;
        bool onBattery = false, lowPower = false;
        try
        {
            if (GetSystemTimes(out long idle, out long kernel, out long user))
                lock (_lock)
                {
                    if (_previous is { } p) load = AdaptiveConcurrency.FromWindowsTimes(idle - p.Idle, kernel - p.Kernel, user - p.User, cores);
                    _previous = (idle, kernel, user);
                }
        }
        catch (Exception) { load = 0; }
        try
        {
            if (GetSystemPowerStatus(out var status))
                (onBattery, lowPower) = AdaptiveConcurrency.FromWindowsPower(status.ACLineStatus, status.SystemStatusFlag);
        }
        catch (Exception) { onBattery = false; lowPower = false; }
        return new SystemSample(cores, load, ThermalState.Nominal, lowPower, onBattery);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out long idleTime, out long kernelTime, out long userTime);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
}

/// <summary>
/// Runs CPU-bound background sections at <see cref="ThreadPriority.BelowNormal"/> so the UI and foreground apps
/// win (addendum A §A.5), restoring the pool thread's priority afterwards. Changing priority can fail (non-Windows,
/// restricted environments); the work then runs at the current priority.
/// </summary>
internal static class BackgroundPriority
{
    public static T Run<T>(Func<T> work)
    {
        var thread = Thread.CurrentThread;
        ThreadPriority previous;
        try
        {
            previous = thread.Priority;
            if (previous > ThreadPriority.BelowNormal) thread.Priority = ThreadPriority.BelowNormal;
        }
        catch (Exception error) when (error is ThreadStateException or PlatformNotSupportedException or InvalidOperationException)
        {
            return work();
        }
        try { return work(); }
        finally
        {
            try { thread.Priority = previous; }
            catch (Exception error) when (error is ThreadStateException or PlatformNotSupportedException or InvalidOperationException) { }
        }
    }
}
