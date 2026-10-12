/// Watcher debounce in monotonic milliseconds: a scan is due 500 ms after the
/// last signal, but never later than 5 s after the first signal of a burst.
/// Signals during a running scan schedule exactly one trailing scan.
public struct RescanSchedule: Sendable, Equatable {
    public static let debounce: Int64 = 500
    public static let maximumCoalesce: Int64 = 5_000

    public private(set) var dueAt: Int64?
    public private(set) var firstSignal: Int64?
    public private(set) var lastSignal: Int64?
    public private(set) var trailingFirstSignal: Int64?
    public private(set) var trailingLastSignal: Int64?
    public private(set) var running = false
    public private(set) var startedScanCount = 0

    public init() {}

    public mutating func signal(at milliseconds: Int64) {
        if running {
            trailingFirstSignal = trailingFirstSignal ?? milliseconds
            trailingLastSignal = milliseconds
            return
        }
        firstSignal = firstSignal ?? milliseconds
        lastSignal = milliseconds
        dueAt = Self.deadline(first: firstSignal!, last: milliseconds)
    }

    public func isDue(at milliseconds: Int64) -> Bool {
        guard !running, let dueAt else { return false }
        return milliseconds >= dueAt
    }

    public mutating func started() {
        running = true
        startedScanCount += 1
        firstSignal = nil
        lastSignal = nil
        dueAt = nil
    }

    public mutating func finished(at milliseconds: Int64) {
        running = false
        guard let first = trailingFirstSignal, let last = trailingLastSignal else { return }
        trailingFirstSignal = nil
        trailingLastSignal = nil
        firstSignal = first
        lastSignal = last
        dueAt = Self.deadline(first: first, last: last)
    }

    private static func deadline(first: Int64, last: Int64) -> Int64 {
        let (debounced, o1) = last.addingReportingOverflow(debounce)
        let (ceiling, o2) = first.addingReportingOverflow(maximumCoalesce)
        return min(o1 ? .max : debounced, o2 ? .max : ceiling)
    }
}
