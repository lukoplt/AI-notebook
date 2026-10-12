import Foundation

// MARK: - Embedding request telemetry (benchmark-v1 §3)

public struct EmbeddingTelemetrySnapshot: Equatable, Sendable {
    public let serviceTokens: Int64?
    public let successfulTokens: Int64
    public let requestCount: Int
    public let rejectedRequests: Int
    public let splitParts: Int
    public let uncountedRequests: Int
    /// `measured`, `partial` or `not_available`.
    public let serviceTokenStatus: String

    public init(serviceTokens: Int64?, successfulTokens: Int64, requestCount: Int, rejectedRequests: Int,
                splitParts: Int, uncountedRequests: Int, serviceTokenStatus: String) {
        self.serviceTokens = serviceTokens
        self.successfulTokens = successfulTokens
        self.requestCount = requestCount
        self.rejectedRequests = rejectedRequests
        self.splitParts = splitParts
        self.uncountedRequests = uncountedRequests
        self.serviceTokenStatus = serviceTokenStatus
    }

    /// Pure reduction over one purpose's events. Fallback counts never become service tokens.
    public static func reduce(_ events: [EmbeddingTelemetryEvent], purpose: EmbeddingPurpose) throws -> EmbeddingTelemetrySnapshot {
        var requests = 0, rejected = 0, parts = 0, counted = 0
        var useful: Int64 = 0, service: Int64 = 0
        for e in events where e.purpose == purpose {
            switch e.kind {
            case "request": requests += 1
            case "lengthRejected": rejected += 1
            case "response":
                if let t = e.tokens {
                    guard t >= 0 else { throw BenchmarkError(code: "invalidSamples") }
                    counted += 1
                    let (sum, overflow) = service.addingReportingOverflow(Int64(t))
                    guard !overflow else { throw BenchmarkError(code: "invalidSamples") }
                    service = sum
                }
            case "partAccepted":
                parts += 1
                guard let t = e.tokens, t >= 0 else { throw BenchmarkError(code: "invalidSamples") }
                let (sum, overflow) = useful.addingReportingOverflow(Int64(t))
                guard !overflow else { throw BenchmarkError(code: "invalidSamples") }
                useful = sum
            default: throw BenchmarkError(code: "invalidSamples")
            }
        }
        let uncounted = requests - counted
        guard uncounted >= 0 else { throw BenchmarkError(code: "invalidSamples") }
        let status = uncounted == 0 ? "measured" : (counted > 0 ? "partial" : "not_available")
        return EmbeddingTelemetrySnapshot(serviceTokens: uncounted == 0 ? service : nil, successfulTokens: useful,
                                          requestCount: requests, rejectedRequests: rejected, splitParts: parts,
                                          uncountedRequests: uncounted, serviceTokenStatus: status)
    }
}

/// Per-candidate collector; never global. Its synchronous isolated `record`
/// satisfies the nonthrowing async observer requirement.
public actor BenchmarkEmbeddingTelemetry: EmbeddingTelemetryObserving {
    private var events: [EmbeddingTelemetryEvent] = []

    public init() {}

    public func record(_ event: EmbeddingTelemetryEvent) { events.append(event) }

    public func snapshot(purpose: EmbeddingPurpose) throws -> EmbeddingTelemetrySnapshot {
        try EmbeddingTelemetrySnapshot.reduce(events, purpose: purpose)
    }
}

// MARK: - Process memory (benchmark-v1 §8 memory/process)

public struct ProcessMemorySample: Equatable, Sendable {
    public let atUs: Int64
    public let runnerBytes: Int64
    public let serverTreeBytes: Int64

    public init(atUs: Int64, runnerBytes: Int64, serverTreeBytes: Int64) {
        self.atUs = atUs
        self.runnerBytes = runnerBytes
        self.serverTreeBytes = serverTreeBytes
    }
}

public struct ProcessMemoryPeaks: Equatable, Sendable {
    public let runnerBytes: Int64
    public let serverBytes: Int64
    public let combinedBytes: Int64

    public init(runnerBytes: Int64, serverBytes: Int64, combinedBytes: Int64) {
        self.runnerBytes = runnerBytes
        self.serverBytes = serverBytes
        self.combinedBytes = combinedBytes
    }
}

public struct ProcessTreeSample: Equatable, Sendable {
    public let runnerBytes: Int64
    public let serverTreeBytes: Int64
    public let serverPids: [Int32]

    public init(runnerBytes: Int64, serverTreeBytes: Int64, serverPids: [Int32]) {
        self.runnerBytes = runnerBytes
        self.serverTreeBytes = serverTreeBytes
        self.serverPids = serverPids
    }
}

public enum BenchmarkTelemetry {
    public static let memoryMethod = "ps-rss"
    public static let sampleIntervalMs = 100

    /// Max runner, max server tree and max simultaneous sum (never the sum of peaks).
    public static func peaks(_ samples: [ProcessMemorySample]) throws -> ProcessMemoryPeaks {
        let bad = BenchmarkError(code: "invalidSamples")
        guard !samples.isEmpty else { throw bad }
        var last: Int64?
        var runner: Int64 = 0, server: Int64 = 0, combined: Int64 = 0
        for s in samples {
            guard s.runnerBytes >= 0, s.serverTreeBytes >= 0, s.atUs >= 0, last.map({ s.atUs >= $0 }) ?? true else {
                throw bad
            }
            last = s.atUs
            let (both, overflow) = s.runnerBytes.addingReportingOverflow(s.serverTreeBytes)
            guard !overflow else { throw bad }
            runner = max(runner, s.runnerBytes); server = max(server, s.serverTreeBytes); combined = max(combined, both)
        }
        return ProcessMemoryPeaks(runnerBytes: runner, serverBytes: server, combinedBytes: combined)
    }

    /// Parses `ps -axo pid=,ppid=,rss=` rows (invariant unsigned decimals, RSS KiB) and sums
    /// the server root plus descendants once; the runner and its children are excluded.
    public static func processTree(psOutput: String, rootPid: Int32, runnerPid: Int32) throws -> ProcessTreeSample {
        let bad = BenchmarkError(code: "invalidSamples")
        var rows: [Int64: (ppid: Int64, bytes: Int64)] = [:]
        for line in psOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            if parts.isEmpty { continue }
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
                  let pid = Int64(parts[0]), let ppid = Int64(parts[1]), let kib = Int64(parts[2]) else { throw bad }
            let (bytes, overflow) = kib.multipliedReportingOverflow(by: 1024)
            guard !overflow, rows[pid] == nil else { throw bad }
            rows[pid] = (ppid, bytes)
        }
        let root = Int64(rootPid), runner = Int64(runnerPid)
        guard rows[root] != nil, let runnerRow = rows[runner] else { throw BenchmarkError(code: "processUnavailable") }
        var children: [Int64: [Int64]] = [:]
        for (pid, row) in rows { children[row.ppid, default: []].append(pid) }
        var seen = Set<Int64>(), stack = [root]
        while let pid = stack.popLast() {
            if seen.contains(pid) || pid == runner { continue }
            seen.insert(pid)
            stack.append(contentsOf: (children[pid] ?? []).sorted())
        }
        var server: Int64 = 0
        for pid in seen {
            let (sum, overflow) = server.addingReportingOverflow(rows[pid]!.bytes)
            guard !overflow else { throw bad }
            server = sum
        }
        return ProcessTreeSample(runnerBytes: runnerRow.bytes, serverTreeBytes: server,
                                 serverPids: seen.sorted().map { Int32(truncatingIfNeeded: $0) })
    }

    /// One live sample via `/bin/ps` (argument array, no shell). Not used in CI tests.
    public static func sampleProcesses(serverRootPid: Int32, atUs: Int64,
                                       runnerPid: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> ProcessMemorySample {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw BenchmarkError(code: "processUnavailable") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else {
            throw BenchmarkError(code: "processUnavailable")
        }
        let tree = try processTree(psOutput: text, rootPid: serverRootPid, runnerPid: runnerPid)
        return ProcessMemorySample(atUs: atUs, runnerBytes: tree.runnerBytes, serverTreeBytes: tree.serverTreeBytes)
    }
}

/// Periodic RSS sampler: one sample at start, every interval, and one at stop. The
/// sampling function is injected; a failed sample makes the run's memory unavailable.
public actor ProcessMemorySampler {
    private let sample: @Sendable () throws -> ProcessMemorySample
    private let intervalNs: UInt64
    private var samples: [ProcessMemorySample] = []
    private var failed = false
    private var loop: Task<Void, Never>?

    public init(intervalMs: Int = BenchmarkTelemetry.sampleIntervalMs,
                sample: @escaping @Sendable () throws -> ProcessMemorySample) {
        self.intervalNs = UInt64(max(1, intervalMs)) * 1_000_000
        self.sample = sample
    }

    public func start() {
        take()
        let interval = intervalNs
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                if Task.isCancelled { break }
                await self?.take()
            }
        }
    }

    /// Stops and awaits the loop, takes the end sample and returns all samples, or nil
    /// when any sample failed (memory is then reported as not measured).
    public func stop() async -> [ProcessMemorySample]? {
        loop?.cancel()
        await loop?.value
        loop = nil
        take()
        return failed ? nil : samples
    }

    private func take() {
        do { samples.append(try sample()) } catch { failed = true }
    }
}
