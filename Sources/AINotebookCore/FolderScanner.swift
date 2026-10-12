import Foundation

/// Pure rule classification shared by scans and rule changes. It never touches
/// the filesystem: a rule change recomputes eligibility from stored row values.
public struct FolderClassifier: Sendable {
    public let rules: FolderRules
    private let globs: [FolderGlob]

    public init(rules: FolderRules, caseSensitive: Bool, tables: UnicodeTables) throws {
        let validated = try rules.validated(caseSensitive: caseSensitive, tables: tables)
        self.rules = validated
        globs = try validated.ignoreGlobs.map { try FolderGlob($0, caseSensitive: caseSensitive, tables: tables) }
    }

    /// Skip reason with the frozen precedence ignored → unsupported_ext → over_limit,
    /// or nil for an eligible regular file.
    public func skipReason(relPath: String, sizeBytes: Int64?) -> String? {
        if globs.contains(where: { $0.matches(relPath) }) { return "ignored" }
        guard let ext = Self.extensionName(relPath), rules.includeExts.contains(ext) else { return "unsupported_ext" }
        if let sizeBytes, sizeBytes > rules.limits.fileBytes { return "over_limit" }
        return nil
    }

    /// ASCII-lowercased extension of the final component; a leading dot alone is no extension.
    static func extensionName(_ relPath: String) -> String? {
        let name = relPath.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? relPath
        let scalars = Array(name.unicodeScalars)
        guard let dot = scalars.lastIndex(of: "."), dot > 0, dot < scalars.count - 1 else { return nil }
        let ext = scalars[(dot + 1)...].map { scalar -> Character in
            (65...90).contains(scalar.value) ? Character(Unicode.Scalar(scalar.value + 32)!) : Character(scalar)
        }
        return String(ext)
    }
}

/// The durable state needed for the metadata fast path of one known file.
struct FolderKnownSource: Sendable, Equatable {
    let id: Int64
    let status: String
    let mtimeNs: Int64?
    let sizeBytes: Int64?
    let contentHash: String?
    let currentRevision: Int64?
    let publishedRevisionId: Int64?
    /// Extraction was given up for the stored content (`ingestion-retry-cap-v1`).
    let gaveUp: Bool
}

public final class FolderScanner: Sendable {
    private let store: NotebookStore
    let fileSystem: any FolderFileSystem
    let tables: UnicodeTables
    private let clock: any IngestLeaseClock
    /// How many files a scan hashes concurrently, read once per scan
    /// (contract `ingestion-memory-pressure-v1` addendum A §A.5).
    private let hashWidth: @Sendable () async -> Int

    public init(store: NotebookStore, fileSystem: any FolderFileSystem, tables: UnicodeTables,
                clock: any IngestLeaseClock = SystemIngestLeaseClock(),
                hashWidth: @escaping @Sendable () async -> Int = { 1 }) {
        self.store = store
        self.fileSystem = fileSystem
        self.tables = tables
        self.clock = clock
        self.hashWidth = hashWidth
    }

    /// Reads are skipped only for a committed, current, published source — or a
    /// source whose extraction was given up (`ingestion-retry-cap-v1`) — whose
    /// stored mtime and size are unchanged. A same-size/same-mtime replacement is
    /// therefore discovered only by Verify all or a forced-hash (native event)
    /// scan: mtime+size cannot detect every replacement.
    static func canSkipRead(_ known: FolderKnownSource?, stamp: FileStamp, verifyAll: Bool) -> Bool {
        guard !verifyAll, let known, known.mtimeNs == stamp.mtimeNs, known.sizeBytes == stamp.sizeBytes else { return false }
        if known.gaveUp { return true }
        return !(known.contentHash ?? "").isEmpty && known.publishedRevisionId != nil
            && known.currentRevision == known.publishedRevisionId && known.status == SourceStatus.ready.rawValue
    }

    /// `now` is the start timestamp; later fence checks use `clock.now()`.
    public func scan(folderId: Int64, verifyAll: Bool, fence: JobFence,
                     now: Int64, cancelled: @escaping @Sendable () -> Bool) async throws {
        let store = self.store
        let begun = try storeWork { () throws -> (ScanTicket, FolderSource)? in
            guard let ticket = try store.beginFolderScan(folderId: folderId, fence: fence, now: now) else { return nil }
            return (ticket, try store.folderSource(id: folderId))
        }
        guard let (ticket, folder) = begun else { return }
        let fileSystem = self.fileSystem, tables = self.tables, clock = self.clock
        let width = await hashWidth()
        let task = Task.detached(priority: .utility) { () async throws -> ScanCompletion? in
            try await Self.walk(ticket: ticket, folder: folder, verifyAll: verifyAll, store: store,
                                fileSystem: fileSystem, tables: tables, clock: clock, hashWidth: width, cancelled: cancelled)
        }
        let outcome: ScanCompletion?
        do {
            outcome = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch StorageV19Error.staleLease {
            return // Another owner or generation took over; it owns the folder state.
        } catch is CancellationError {
            _ = try storeWork { try store.markFolderScanCancelled(ticket: ticket, now: clock.now()) }
            throw CancellationError()
        }
        guard let completion = outcome else {
            _ = try storeWork { try store.markFolderScanCancelled(ticket: ticket, now: clock.now()) }
            if Task.isCancelled { throw CancellationError() }
            return
        }
        _ = try storeWork { try store.finishFolderScan(ticket: ticket, completion: completion, now: clock.now()) }
    }

    /// Most observations committed per store transaction (contract `ingestion-scan-perf-v1` §1).
    public static let observeBatchSize = 256
    /// A non-empty batch is committed at the latest this long after the previous commit.
    public static let observeBatchInterval: Duration = .seconds(1)

    /// Returns nil when the scan was cancelled; a completion otherwise.
    private static func walk(ticket: ScanTicket, folder: FolderSource, verifyAll: Bool, store: NotebookStore,
                             fileSystem: any FolderFileSystem, tables: UnicodeTables,
                             clock: any IngestLeaseClock, hashWidth: Int,
                             cancelled: @escaping @Sendable () -> Bool) async throws -> ScanCompletion? {
        func isCancelled() -> Bool { cancelled() || Task.isCancelled }
        func failure(_ code: String) -> ScanCompletion {
            ScanCompletion(completed: [], incomplete: [""], rootUnavailable: false, error: code)
        }
        if isCancelled() { return nil }
        let sensitive: Bool
        do { sensitive = try fileSystem.caseSensitive(root: folder) }
        catch let error as IngestionError where ["rootUnavailable", "rootIdentityChanged"].contains(error.code) {
            return ScanCompletion(completed: [], incomplete: [], rootUnavailable: true, error: error.code)
        } catch is CancellationError {
            return nil
        } catch {
            return ScanCompletion(completed: [], incomplete: [], rootUnavailable: true, error: "rootUnavailable")
        }
        let classifier: FolderClassifier
        do { classifier = try FolderClassifier(rules: try folder.rules, caseSensitive: sensitive, tables: tables) }
        catch let error as IngestionError { return failure(error.code) }
        let maxBytes = classifier.rules.limits.fileBytes
        // One snapshot for the fast path instead of a store round trip per file.
        let known = try storeWork { try store.folderKnownSources(folderId: folder.id) }
        let batch = ScanObservationBatch()
        let ahead = ScanHashAhead(width: hashWidth) { path in
            try fileSystem.hash(root: folder, relativePath: path, maxBytes: maxBytes)
        }
        @Sendable func needsRead(_ entry: FolderEntry) -> Bool {
            !entry.isDirectory && !entry.isLink
                && classifier.skipReason(relPath: entry.relPath, sizeBytes: entry.stamp.sizeBytes) == nil
                && !canSkipRead(known[entry.relPath], stamp: entry.stamp, verifyAll: verifyAll)
        }
        @Sendable func commit(_ observations: [FolderScanObservation]) async throws {
            guard !observations.isEmpty else { return }
            _ = try storeWork { try store.observeFolderFiles(ticket: ticket, observations: observations, now: clock.now()) }
        }
        @Sendable func add(_ item: FolderScanObservation) async throws {
            if let due = batch.append(item) { try await commit(due) }
        }
        let completion: ScanCompletion
        do {
            completion = try await FolderWalk(fileSystem: fileSystem).walk(root: folder, cancelled: cancelled) { entry, upcoming in
                if entry.isDirectory && !entry.isLink { return }
                if entry.isLink {
                    try await add(.interiorLink(relPath: entry.relPath, stamp: entry.stamp))
                    return
                }
                if let reason = classifier.skipReason(relPath: entry.relPath, sizeBytes: entry.stamp.sizeBytes) {
                    try await add(.file(FolderObservation(relPath: entry.relPath, stamp: entry.stamp, kind: "skipped",
                                                          skipReason: reason, contentHash: nil)))
                    return
                }
                var stamp = entry.stamp
                var hash: String?
                if !canSkipRead(known[entry.relPath], stamp: stamp, verifyAll: verifyAll) {
                    do {
                        // Streaming hash: no payload is retained, only the digest and opened stamp.
                        // Upcoming files of this directory may be hashed ahead; this file's
                        // outcome (or error) is still handled by its own visit.
                        let read = try await ahead.read(entry, upcoming: upcoming, needsRead: needsRead)
                        stamp = read.stamp
                        hash = read.sha256
                    } catch let error as IngestionError where error.code == "fileLimit" {
                        // The file grew past the limit after enumeration.
                        try await add(.file(FolderObservation(relPath: entry.relPath,
                            stamp: FileStamp(identity: stamp.identity, mtimeNs: stamp.mtimeNs, sizeBytes: max(stamp.sizeBytes, maxBytes + 1)),
                            kind: "skipped", skipReason: "over_limit", contentHash: nil)))
                        return
                    }
                }
                try await add(.file(FolderObservation(relPath: entry.relPath, stamp: stamp, kind: "eligible",
                                                      skipReason: nil, contentHash: hash)))
            }
        } catch StorageV19Error.staleLease {
            throw StorageV19Error.staleLease
        } catch let error as CancellationError {
            // Observations made before the cancellation stay durable (no missing-marking follows).
            try? await commit(batch.drain())
            throw error
        } catch {
            try? await commit(batch.drain())
            if isCancelled() { return nil }
            return failure("unexpectedError")
        }
        // Everything observed must be committed before completion may mark anything missing.
        try await commit(batch.drain())
        if isCancelled() { return nil }
        return completion
    }

    /// Validates and applies new rules from stored row values. Files observed
    /// between classification and commit make the store reject the stale
    /// classification; it is then recomputed from a fresh read.
    public func applyRules(folderId: Int64, rules: FolderRules, now: Int64) async throws {
        let store = self.store, clock = self.clock
        let folder = try storeWork { try store.folderSource(id: folderId) }
        let fileSystem = self.fileSystem
        // Rules stay applicable while the root is offline; case-insensitive
        // matching then ignores a superset, the conservative choice.
        let sensitive = await Task.detached(priority: .utility) { () -> Bool in
            (try? fileSystem.caseSensitive(root: folder)) ?? false
        }.value
        let classifier = try FolderClassifier(rules: rules, caseSensitive: sensitive, tables: tables)
        for _ in 0..<8 {
            let rows = try storeWork { try store.folderRuleRows(folderId: folderId) }
            var eligibility: [String: Bool] = [:]
            var reasons: [String: String] = [:]
            for row in rows {
                let reason = classifier.skipReason(relPath: row.relPath, sizeBytes: row.sizeBytes)
                eligibility[row.relPath] = reason == nil
                if let reason { reasons[row.relPath] = reason }
            }
            do {
                try storeWork {
                    try store.applyFolderRules(folderId: folderId, rules: classifier.rules, eligibility: eligibility,
                                               skipReasons: reasons, now: clock.now())
                }
                return
            } catch StorageV19Error.staleRevision {
                continue
            }
        }
        throw StorageV19Error.staleRevision
    }
}

/// Hashes the files a scan must read `width` at a time, ahead of their visits,
/// within the current directory (contract `ingestion-memory-pressure-v1`
/// addendum A §A.5). A result is consumed by its own file's visit, so a hash
/// error keeps its per-file meaning and walk-order commits are unchanged.
/// Width 1 hashes inline, exactly as before.
final class ScanHashAhead: @unchecked Sendable {
    /// Files hashed per look-ahead round, per unit of width.
    static let roundPerWidth = 8
    private let lock = NSLock()
    private var results: [String: Result<FolderRead, Error>] = [:]
    let width: Int
    private let hash: @Sendable (String) throws -> FolderRead

    init(width: Int, hash: @escaping @Sendable (String) throws -> FolderRead) {
        self.width = max(width, 1)
        self.hash = hash
    }

    func read(_ entry: FolderEntry, upcoming: ArraySlice<FolderEntry>,
              needsRead: (FolderEntry) -> Bool) async throws -> FolderRead {
        if let cached = take(entry.relPath) { return try cached.get() }
        guard width > 1 else { return try hash(entry.relPath) }
        let paths = [entry.relPath] + upcoming.lazy.filter(needsRead).prefix(width * Self.roundPerWidth - 1).map(\.relPath)
        let computed = await hashAll(paths)
        store(zip(paths, computed).dropFirst())
        return try computed[0].get()
    }

    private func store<S: Sequence>(_ computed: S) where S.Element == (String, Result<FolderRead, Error>) {
        lock.lock(); defer { lock.unlock() }
        for (path, result) in computed { results[path] = result }
    }

    private func take(_ path: String) -> Result<FolderRead, Error>? {
        lock.lock(); defer { lock.unlock() }
        return results.removeValue(forKey: path)
    }

    /// At most `width` hashes in flight; results in `paths` order.
    private func hashAll(_ paths: [String]) async -> [Result<FolderRead, Error>] {
        let hash = self.hash
        return await withTaskGroup(of: (Int, Result<FolderRead, Error>).self) { group in
            var out = [Result<FolderRead, Error>?](repeating: nil, count: paths.count)
            var next = 0
            while next < min(width, paths.count) {
                let index = next, path = paths[index]
                group.addTask { (index, Task.isCancelled ? .failure(CancellationError()) : Result { try hash(path) }) }
                next += 1
            }
            while let (index, result) = await group.next() {
                out[index] = result
                if next < paths.count {
                    let index = next, path = paths[index]
                    group.addTask { (index, Task.isCancelled ? .failure(CancellationError()) : Result { try hash(path) }) }
                    next += 1
                }
            }
            return out.map { $0 ?? .failure(CancellationError()) }
        }
    }
}

/// Pending observations of one walk (visits are sequential; the lock only
/// satisfies `Sendable`). A batch is due at `observeBatchSize` entries or
/// `observeBatchInterval` after the previous commit.
final class ScanObservationBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [FolderScanObservation] = []
    private var last = ContinuousClock.now

    func append(_ item: FolderScanObservation) -> [FolderScanObservation]? {
        lock.lock(); defer { lock.unlock() }
        items.append(item)
        guard items.count >= FolderScanner.observeBatchSize
                || ContinuousClock.now - last >= FolderScanner.observeBatchInterval else { return nil }
        return takeLocked()
    }

    func drain() -> [FolderScanObservation] {
        lock.lock(); defer { lock.unlock() }
        return takeLocked()
    }

    private func takeLocked() -> [FolderScanObservation] {
        let taken = items
        items = []
        last = ContinuousClock.now
        return taken
    }
}

extension FolderSource {
    /// Persisted rules. An unparsable limits document is an invalid rule set, never defaults.
    public var rules: FolderRules {
        get throws {
            FolderRules(includeExts: draft.includeExts, ignoreGlobs: draft.ignoreGlobs,
                        limits: try IngestionLimits(json: draft.limitsJSON), encodingFallback: draft.encodingFallback)
        }
    }
}
