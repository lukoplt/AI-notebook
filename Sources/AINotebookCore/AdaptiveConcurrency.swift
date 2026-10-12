import Foundation
import IOKit.ps

/// How many extractions run at once (contract `ingestion-memory-pressure-v1`
/// addendum A, fixture `ingestion-adaptive-concurrency-v1`): more cores only
/// while the computer is idle, on power and cool; step down at once otherwise.
public enum AdaptiveConcurrency {
    public static let maxWorkersCap = 6
    public static let initialWorkers = 2
    static let batteryWorkers = 2
    static let busyWorkers = 2
    static let constrainedWorkers = 1
    static let maxHashWidth = 4
    static let minBudgetBytes: Int64 = 512 * 1_048_576
    static let maxBudgetBytes: Int64 = 1_024 * 1_048_576
    static let budgetPercent: Int64 = 6
    /// A higher target must hold this long before the limit rises.
    public static let raiseAfterMs: Int64 = 30_000
    /// The system probe is sampled at most this often (memory pressure: every tick).
    public static let sampleIntervalMs: Int64 = 2_000

    public enum Thermal: String, Sendable, Equatable, CaseIterable {
        case nominal, fair, serious, critical

        /// `ProcessInfo.ThermalState` raw value; anything unknown is nominal.
        public static func darwin(rawValue: Int) -> Thermal {
            switch rawValue {
            case 1: return .fair
            case 2: return .serious
            case 3: return .critical
            default: return .nominal
            }
        }
    }

    /// One cheap sample of the machine's state.
    public struct SystemSample: Sendable, Equatable {
        public var cores: Int
        /// Runnable load (1-minute average) in thousandths of a core, our own work included.
        public var loadMilli: Int
        public var thermal: Thermal
        public var lowPower: Bool
        public var onBattery: Bool

        public init(cores: Int, loadMilli: Int, thermal: Thermal = .nominal, lowPower: Bool = false, onBattery: Bool = false) {
            self.cores = cores
            self.loadMilli = loadMilli
            self.thermal = thermal
            self.lowPower = lowPower
            self.onBattery = onBattery
        }
    }

    /// Extraction worker cap for the process: half the logical cores, 1…6.
    public static func maxWorkers(cores: Int) -> Int { min(max(cores / 2, 1), maxWorkersCap) }

    /// Admission memory budget: 6 % of physical memory, 512 MiB…1 GiB.
    public static func memoryBudget(physicalBytes: Int64) -> Int64 {
        let (scaled, overflow) = max(physicalBytes, 0).multipliedReportingOverflow(by: budgetPercent)
        return min(max(overflow ? .max : scaled / 100, minBudgetBytes), maxBudgetBytes)
    }

    /// Concurrent file hashes of a folder scan for the current extraction limit.
    public static func hashWidth(extractionLimit: Int) -> Int { min(max(extractionLimit, 1), maxHashWidth) }

    /// Target worker count; 0 only for critical memory pressure.
    public static func target(_ sample: SystemSample, ownWorkers: Int, memory: MemoryPressureLevel) -> Int {
        if memory == .critical { return 0 }
        var t = maxWorkers(cores: sample.cores)
        if memory == .warning || sample.thermal == .serious || sample.thermal == .critical || sample.lowPower {
            t = min(t, constrainedWorkers)
        }
        if sample.onBattery { t = min(t, batteryWorkers) }
        // Our own running extractions are part of the system load; only the rest counts.
        let (own, ownOverflow) = Int64(max(ownWorkers, 0)).multipliedReportingOverflow(by: 1_000)
        let external = max(0, Int64(sample.loadMilli) - (ownOverflow ? .max : own))
        let capacity = 1_000 * Int64(max(sample.cores, 1))
        if external >= capacity {
            t = min(t, constrainedWorkers)
        } else if 2 * external >= capacity {
            t = min(t, busyWorkers)
        }
        return max(t, 1)
    }

    /// Hysteresis: lower at once; raise only after a higher target held `raiseAfterMs`.
    public struct Governor: Sendable, Equatable {
        public let cap: Int
        public private(set) var limit: Int
        private var since: Int64?

        public init(cap: Int) {
            self.cap = max(cap, 1)
            limit = min(self.cap, AdaptiveConcurrency.initialWorkers)
        }

        @discardableResult
        public mutating func observe(target: Int, atMs: Int64) -> Int {
            let value = min(max(target, 1), cap)
            if value <= limit {
                limit = value
                since = nil
                return limit
            }
            if since == nil || atMs < since! { since = atMs }
            if atMs - since! >= AdaptiveConcurrency.raiseAfterMs {
                limit = value
                since = nil
            }
            return limit
        }
    }

    /// Live macOS sample; every part fails open (load 0, nominal, on AC, no Low Power Mode).
    public static func sampleDarwin() -> SystemSample {
        var load = [Double](repeating: 0, count: 3)
        let loadMilli = getloadavg(&load, 1) == 1 && load[0].isFinite ? Int(min(max(load[0], 0), 1e6) * 1_000) : 0
        let info = ProcessInfo.processInfo
        let thermal: Thermal
        switch info.thermalState {
        case .nominal: thermal = .darwin(rawValue: 0)
        case .fair: thermal = .darwin(rawValue: 1)
        case .serious: thermal = .darwin(rawValue: 2)
        case .critical: thermal = .darwin(rawValue: 3)
        @unknown default: thermal = .nominal
        }
        return SystemSample(cores: info.activeProcessorCount, loadMilli: loadMilli, thermal: thermal,
                            lowPower: info.isLowPowerModeEnabled, onBattery: onBatteryDarwin())
    }

    static func onBatteryDarwin() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
