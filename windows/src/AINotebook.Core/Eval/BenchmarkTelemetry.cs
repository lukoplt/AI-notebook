using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Eval;

public sealed record ProcessMemorySample(long AtUs, long RunnerBytes, long ServerTreeBytes);

public sealed record ProcessMemoryPeaks(long RunnerBytes, long ServerBytes, long CombinedBytes);

/// <summary>One enumerated process: its PID and parent PID (PIDs are run-local, never persisted).</summary>
public sealed record ProcessRow(int Pid, int ParentPid);

public sealed record ProcessTreeSample(long RunnerBytes, long ServerTreeBytes, IReadOnlyList<int> ServerPids);

/// <summary>Process-tree RSS sampling and peak aggregation (benchmark-v1 §8 memory/process).</summary>
public static class BenchmarkTelemetry
{
    /// <summary>Max runner, max server and the maximum simultaneous sum; rejects empty, negative and decreasing-time samples.</summary>
    public static ProcessMemoryPeaks Peaks(IReadOnlyList<ProcessMemorySample> samples)
    {
        ArgumentNullException.ThrowIfNull(samples);
        if (samples.Count == 0) throw new BenchmarkException("invalidSamples");
        long runner = 0, server = 0, combined = 0;
        long? last = null;
        foreach (var s in samples)
        {
            if (s.RunnerBytes < 0 || s.ServerTreeBytes < 0 || s.AtUs < 0 || s.AtUs < last) throw new BenchmarkException("invalidSamples");
            last = s.AtUs;
            long both;
            try { both = checked(s.RunnerBytes + s.ServerTreeBytes); }
            catch (OverflowException) { throw new BenchmarkException("invalidSamples"); }
            runner = Math.Max(runner, s.RunnerBytes);
            server = Math.Max(server, s.ServerTreeBytes);
            combined = Math.Max(combined, both);
        }
        return new(runner, server, combined);
    }

    /// <summary>
    /// Parses <c>ps -axo pid=,ppid=,rss=</c> (KiB) rows, then sums the root and its descendants once,
    /// excluding the runner and its children. Cycles are tolerated.
    /// </summary>
    public static ProcessTreeSample ParseProcessTable(string psOutput, int rootPid, int runnerPid)
    {
        ArgumentNullException.ThrowIfNull(psOutput);
        var rows = new List<ProcessRow>();
        var bytes = new Dictionary<int, long>();
        foreach (var line in psOutput.Split('\n'))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length != 3 || !parts.All(p => p.All(char.IsAsciiDigit))
                || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out int pid)
                || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out int ppid)
                || !long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out long kib)
                || kib > long.MaxValue / 1024 || bytes.ContainsKey(pid))
                throw new BenchmarkException("invalidSamples");
            rows.Add(new(pid, ppid));
            bytes[pid] = kib * 1024;
        }
        return Tree(rows, pid => bytes.TryGetValue(pid, out var b) ? b : null, rootPid, runnerPid, requireAll: true);
    }

    /// <summary>
    /// Builds one sample from an injected enumeration and RSS reader. A PID whose RSS reads null has
    /// exited and is skipped; a missing root or runner is <c>processUnavailable</c>.
    /// </summary>
    public static ProcessMemorySample Sample(IReadOnlyList<ProcessRow> rows, Func<int, long?> residentBytes,
        int rootPid, int runnerPid, long atUs)
    {
        var tree = Tree(rows, residentBytes, rootPid, runnerPid, requireAll: false);
        return new(atUs, tree.RunnerBytes, tree.ServerTreeBytes);
    }

    private static ProcessTreeSample Tree(IReadOnlyList<ProcessRow> rows, Func<int, long?> residentBytes, int rootPid,
        int runnerPid, bool requireAll)
    {
        var pids = new HashSet<int>();
        var children = new Dictionary<int, List<int>>();
        foreach (var row in rows)
        {
            if (!pids.Add(row.Pid)) throw new BenchmarkException("invalidSamples");
            if (!children.TryGetValue(row.ParentPid, out var list)) children[row.ParentPid] = list = [];
            list.Add(row.Pid);
        }
        if (!pids.Contains(rootPid) || !pids.Contains(runnerPid)) throw new BenchmarkException("processUnavailable");
        long runner = residentBytes(runnerPid) ?? throw new BenchmarkException("processUnavailable");
        if (residentBytes(rootPid) is null) throw new BenchmarkException("processUnavailable");
        var seen = new SortedSet<int>();
        var stack = new Stack<int>([rootPid]);
        long server = 0;
        while (stack.Count > 0)
        {
            int pid = stack.Pop();
            if (pid == runnerPid || !seen.Add(pid)) continue;
            long? rss = residentBytes(pid);
            if (rss is null)
            {
                if (requireAll) throw new BenchmarkException("processUnavailable");
                seen.Remove(pid); // exited between enumeration and the read
                continue;
            }
            if (rss < 0) throw new BenchmarkException("invalidSamples");
            try { server = checked(server + rss.Value); }
            catch (OverflowException) { throw new BenchmarkException("invalidSamples"); }
            if (children.TryGetValue(pid, out var kids))
                foreach (var kid in kids.OrderDescending()) stack.Push(kid);
        }
        return new(runner, server, seen.ToArray());
    }

    /// <summary>
    /// One live sample: Windows enumerates with Toolhelp parent IDs and <c>WorkingSet64</c>;
    /// other platforms use <c>/bin/ps</c> with an argument array. Never called by CI tests.
    /// </summary>
    public static ProcessMemorySample SampleProcesses(int serverRootPid)
    {
        int runner = Environment.ProcessId;
        long atUs = BenchmarkMeasurements.TicksToMicroseconds(Stopwatch.GetTimestamp(), Stopwatch.Frequency);
        if (OperatingSystem.IsWindows())
            return Sample(WindowsProcessTable.Enumerate(), WorkingSet, serverRootPid, runner, atUs);
        var info = new ProcessStartInfo("/bin/ps") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "-axo", "pid=,ppid=,rss=" }) info.ArgumentList.Add(a);
        using var process = Process.Start(info) ?? throw new BenchmarkException("processUnavailable");
        string output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        if (process.ExitCode != 0) throw new BenchmarkException("processUnavailable");
        var tree = ParseProcessTable(output, serverRootPid, runner);
        return new(atUs, tree.RunnerBytes, tree.ServerTreeBytes);
    }

    private static long? WorkingSet(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return process.WorkingSet64;
        }
        catch (ArgumentException) { return null; } // confirmed exited
        catch (InvalidOperationException) { return null; }
        catch (System.ComponentModel.Win32Exception) { throw new BenchmarkException("processUnavailable"); }
    }

    /// <summary>Periodic sampler: one start sample, one per interval, one end sample.</summary>
    public static ProcessMemorySampler StartSampler(Func<ProcessMemorySample> sample, TimeSpan interval) => new(sample, interval);
}

public sealed class ProcessMemorySampler : IAsyncDisposable
{
    private readonly Func<ProcessMemorySample> _sample;
    private readonly List<ProcessMemorySample> _samples = [];
    private readonly CancellationTokenSource _stop = new();
    private readonly Task _loop;
    private IReadOnlyList<ProcessMemorySample>? _result;
    private Exception? _failure;

    internal ProcessMemorySampler(Func<ProcessMemorySample> sample, TimeSpan interval)
    {
        _sample = sample ?? throw new ArgumentNullException(nameof(sample));
        Take();
        _loop = Task.Run(async () =>
        {
            using var timer = new PeriodicTimer(interval);
            try
            {
                while (await timer.WaitForNextTickAsync(_stop.Token).ConfigureAwait(false)) Take();
            }
            catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        });
    }

    private void Take()
    {
        try
        {
            var s = _sample();
            lock (_samples) _samples.Add(s);
        }
        catch (Exception error) { _failure ??= error; }
    }

    /// <summary>Stops, awaits the loop, takes the end sample and returns every sample (idempotent).</summary>
    public async Task<IReadOnlyList<ProcessMemorySample>> StopAsync()
    {
        if (_result is not null) return _result;
        _stop.Cancel();
        await _loop.ConfigureAwait(false);
        Take();
        if (_failure is BenchmarkException failure) throw failure;
        if (_failure is not null) throw new BenchmarkException("processUnavailable");
        lock (_samples) _result = _samples.ToArray();
        return _result;
    }

    public async ValueTask DisposeAsync()
    {
        if (_result is null)
        {
            _stop.Cancel();
            try { await _loop.ConfigureAwait(false); } catch (OperationCanceledException) { }
        }
        _stop.Dispose();
    }
}

/// <summary>Per-candidate embedding telemetry collector; snapshots copy events under a short lock.</summary>
public sealed class BenchmarkEmbeddingTelemetry : IEmbeddingTelemetryObserver
{
    private readonly object _gate = new();
    private readonly List<EmbeddingTelemetryEvent> _events = [];

    public ValueTask RecordAsync(EmbeddingTelemetryEvent observation)
    {
        if (observation is not null) lock (_gate) _events.Add(observation);
        return ValueTask.CompletedTask;
    }

    public EmbeddingTelemetrySnapshot Snapshot(EmbeddingPurpose purpose)
    {
        EmbeddingTelemetryEvent[] copy;
        lock (_gate) copy = _events.ToArray();
        try { return EmbeddingTelemetrySnapshot.FromEvents(copy, purpose); }
        catch (Exception error) when (error is OverflowException or EmbeddingProfileException)
        {
            throw new BenchmarkException("invalidSamples");
        }
    }
}

/// <summary>Toolhelp32 enumeration of (pid, parent pid); Windows only, behind <see cref="OperatingSystem.IsWindows"/>.</summary>
internal static class WindowsProcessTable
{
    private const uint Th32csSnapProcess = 0x00000002;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry32W entry);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry32W entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    internal static IReadOnlyList<ProcessRow> Enumerate()
    {
        if (!OperatingSystem.IsWindows()) throw new BenchmarkException("processUnavailable");
        IntPtr snapshot = CreateToolhelp32Snapshot(Th32csSnapProcess, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) throw new BenchmarkException("processUnavailable");
        try
        {
            var rows = new List<ProcessRow>();
            var entry = new ProcessEntry32W { dwSize = (uint)Marshal.SizeOf<ProcessEntry32W>() };
            for (bool ok = Process32FirstW(snapshot, ref entry); ok; ok = Process32NextW(snapshot, ref entry))
                rows.Add(new((int)entry.th32ProcessID, (int)entry.th32ParentProcessID));
            return rows;
        }
        finally { CloseHandle(snapshot); }
    }
}
