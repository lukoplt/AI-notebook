import Foundation

/// Deterministic postorder bookkeeping keeps successful sibling subtrees when
/// cancellation or a permission error prevents a complete root traversal.
public struct FolderWalk: Sendable {
    private let fileSystem: any FolderFileSystem

    public init(fileSystem: any FolderFileSystem) { self.fileSystem = fileSystem }

    private struct Frame {
        let directory: String
        let entries: [FolderEntry]
        let expectedIdentity: String?
        let completedStart: Int
        var next = 0
        var complete = true
    }

    public func walk(root: FolderSource, cancelled: @Sendable () -> Bool,
                     visit: @Sendable (FolderEntry) async throws -> Void) async throws -> ScanCompletion {
        try await walk(root: root, cancelled: cancelled, visitAhead: { entry, _ in try await visit(entry) })
    }

    /// `visitAhead` also receives the entries that follow `entry` in its directory
    /// (walk order), so a visitor can prepare them ahead of their own visit. Each
    /// entry's outcome still belongs to its own visit.
    public func walk(root: FolderSource, cancelled: @Sendable () -> Bool,
                     visitAhead visit: @Sendable (FolderEntry, ArraySlice<FolderEntry>) async throws -> Void) async throws -> ScanCompletion {
        var completed: [String] = []
        var incomplete: [String] = []
        var frames: [Frame] = []
        func isCancelled() -> Bool { Task.isCancelled || cancelled() }
        func partial() -> ScanCompletion {
            var unique: [Data: String] = [:]
            for path in incomplete + frames.map(\.directory) { unique[Data(path.utf8)] = path }
            let paths = unique.values.sorted {
                let left = Self.depth($0), right = Self.depth($1)
                return left == right ? Self.precedes($0, $1) : left > right
            }
            return ScanCompletion(completed: completed.sorted(by: Self.precedes), incomplete: paths,
                                  rootUnavailable: false, error: nil)
        }
        guard !isCancelled() else {
            return ScanCompletion(completed: [], incomplete: [""], rootUnavailable: false, error: nil)
        }
        do {
            frames.append(Frame(directory: "", entries: try entries(root: root, directory: "", expectedIdentity: nil),
                                expectedIdentity: nil, completedStart: 0))
        } catch {
            if let unavailable = Self.unavailable(error) { return unavailable }
            if Self.permission(error) {
                return ScanCompletion(completed: [], incomplete: [], rootUnavailable: true, error: "rootUnavailable")
            }
            if Self.cancellation(error) {
                return ScanCompletion(completed: [], incomplete: [""], rootUnavailable: false, error: nil)
            }
            throw error
        }

        while let last = frames.indices.last {
            if isCancelled() { return partial() }
            if frames[last].next == frames[last].entries.count {
                do {
                    // The final visitor may have raced a directory replacement
                    // or selected-root retarget after its last file operation.
                    // Revalidate before granting missing-marking permission.
                    let current = try fileSystem.stat(root: root, relativePath: frames[last].directory)
                    if let expectedIdentity = frames[last].expectedIdentity,
                       !current.identity.utf8.elementsEqual(expectedIdentity.utf8) {
                        throw IngestionError(code: "changedDuringExtraction")
                    }
                } catch {
                    if let unavailable = Self.unavailable(error) { return unavailable }
                    if Self.cancellation(error) { return partial() }
                    if frames[last].directory.isEmpty, Self.permission(error) {
                        return ScanCompletion(completed: [], incomplete: [], rootUnavailable: true, error: "rootUnavailable")
                    }
                    guard Self.permission(error) || Self.pathChanged(error) else { throw error }
                    // Completed children belonged to the previous directory
                    // identity and cannot authorize missing-marking either.
                    completed.removeSubrange(frames[last].completedStart..<completed.count)
                    frames[last].complete = false
                }
                if isCancelled() { return partial() }
                let frame = frames.removeLast()
                if frame.complete {
                    // All descendants completed. Replace their individual
                    // prefixes with this single, now-complete directory.
                    completed.removeSubrange(frame.completedStart..<completed.count)
                    completed.append(frame.directory)
                } else {
                    incomplete.append(frame.directory)
                    if let parent = frames.indices.last { frames[parent].complete = false }
                }
                continue
            }

            let entry = frames[last].entries[frames[last].next]
            frames[last].next += 1
            do {
                try await visit(entry, frames[last].entries[frames[last].next...])
            } catch {
                if let unavailable = Self.unavailable(error) { return unavailable }
                if Self.cancellation(error) { return partial() }
                guard Self.permission(error) || Self.pathChanged(error) else { throw error }
                frames[last].complete = false
                if entry.isDirectory && !entry.isLink { incomplete.append(entry.relPath) }
                continue
            }
            guard entry.isDirectory, !entry.isLink else { continue }
            if isCancelled() {
                incomplete.append(entry.relPath)
                return partial()
            }
            do {
                let children = try entries(root: root, directory: entry.relPath, expectedIdentity: entry.stamp.identity)
                frames.append(Frame(directory: entry.relPath, entries: children,
                                    expectedIdentity: entry.stamp.identity, completedStart: completed.count))
            } catch {
                if let unavailable = Self.unavailable(error) { return unavailable }
                if Self.cancellation(error) {
                    incomplete.append(entry.relPath)
                    return partial()
                }
                guard Self.permission(error) || Self.pathChanged(error) else { throw error }
                frames[last].complete = false
                incomplete.append(entry.relPath)
            }
        }
        return partial()
    }

    private func entries(root: FolderSource, directory: String, expectedIdentity: String?) throws -> [FolderEntry] {
        try Task.checkCancellation()
        if let expectedIdentity {
            let before = try fileSystem.stat(root: root, relativePath: directory)
            guard before.identity.utf8.elementsEqual(expectedIdentity.utf8) else {
                throw IngestionError(code: "changedDuringExtraction")
            }
        }
        let entries = try fileSystem.list(root: root, directory: directory)
        if let expectedIdentity {
            let after = try fileSystem.stat(root: root, relativePath: directory)
            guard after.identity.utf8.elementsEqual(expectedIdentity.utf8) else {
                throw IngestionError(code: "changedDuringExtraction")
            }
        }
        var seen = Set<Data>()
        for entry in entries {
            let components = entry.relPath.split(separator: "/", omittingEmptySubsequences: false)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  components.dropLast().joined(separator: "/").utf8.elementsEqual(directory.utf8),
                  seen.insert(Data(entry.relPath.utf8)).inserted else {
                throw IngestionError(code: "outsideRoot")
            }
        }
        return entries.sorted { Self.precedes($0.relPath, $1.relPath) }
    }

    private static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars)
    }
    private static func depth(_ path: String) -> Int { path.isEmpty ? 0 : path.split(separator: "/").count }

    private static func cancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? IngestionError)?.code == "cancelled"
    }
    private static func permission(_ error: Error) -> Bool {
        if let error = error as? CocoaError { return error.code == .fileReadNoPermission }
        if let error = error as? POSIXError { return error.code == .EACCES || error.code == .EPERM }
        return false
    }
    private static func pathChanged(_ error: Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .ENOENT || error.code == .ENOTDIR
        }
        guard let error = error as? IngestionError else { return false }
        return ["changedDuringExtraction", "interiorLink", "outsideRoot"].contains(error.code)
    }
    private static func unavailable(_ error: Error) -> ScanCompletion? {
        guard let error = error as? IngestionError,
              error.code == "rootUnavailable" || error.code == "rootIdentityChanged" else { return nil }
        // Losing the selected root invalidates even earlier completed subtrees:
        // the scanner must switch availability without marking files missing.
        return ScanCompletion(completed: [], incomplete: [], rootUnavailable: true, error: error.code)
    }
}
