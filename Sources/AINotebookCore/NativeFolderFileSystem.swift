import Foundation
import CryptoKit
import Darwin

/// Validations shared by the native descriptor path and the contract traces.
enum FolderAccessValidation {
    static func nanoseconds(seconds: Int64, nanoseconds: Int64) throws -> Int64 {
        let (whole, multiplyOverflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let (result, addOverflow) = whole.addingReportingOverflow(nanoseconds)
        guard !multiplyOverflow, !addOverflow else { throw POSIXError(.EOVERFLOW) }
        return result
    }
    static func validateRoot(persisted: FolderIdentity, opened: FolderIdentity) throws {
        guard persisted == opened else { throw IngestionError(code: "rootIdentityChanged") }
    }

    static func validateContainment(root: FolderIdentity, resolvedComponents: [String]) throws {
        guard resolvedComponents.count >= root.components.count,
              zip(root.components, resolvedComponents).allSatisfy({ $0.utf8.elementsEqual($1.utf8) }) else {
            throw IngestionError(code: "outsideRoot")
        }
    }

    static func validateOpen(enumerated: FileStamp, opened: FileStamp, openedIsLink: Bool,
                             parentBefore: String, parentAfter: String) throws {
        guard !openedIsLink else { throw IngestionError(code: "interiorLink") }
        guard parentBefore.utf8.elementsEqual(parentAfter.utf8) else { throw IngestionError(code: "outsideRoot") }
        guard enumerated == opened else { throw IngestionError(code: "changedDuringExtraction") }
    }

    static func canonicalPaths(_ paths: [String]) -> [String] {
        var seen = Set<Data>()
        return paths.filter { seen.insert(Data($0.utf8)).inserted }
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }
}

/// Descendants are opened relative to retained directory descriptors. Only the
/// selected root may resolve a link. No extractor reopens the live user path.
public struct NativeFolderFileSystem: FolderFileSystem {
    private let beforeOpen: @Sendable (String) throws -> Void
    private let didRead: @Sendable (Int) throws -> Void
    private let isDataless: @Sendable (Darwin.stat) -> Bool

    public init() { self.init(beforeOpen: { _ in }, didRead: { _ in }) }
    init(beforeOpen: @escaping @Sendable (String) throws -> Void,
         didRead: @escaping @Sendable (Int) throws -> Void,
         isDataless: @escaping @Sendable (Darwin.stat) -> Bool = { DatalessFile.isDataless(flags: $0.st_flags) }) {
        self.beforeOpen = beforeOpen
        self.didRead = didRead
        self.isDataless = isDataless
    }

    private final class Descriptor {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
        deinit { Darwin.close(fd) }
    }
    private struct Link {
        let parent: Descriptor
        let name: String
        let device: dev_t
        let inode: ino_t
    }
    private struct OpenRoot {
        let handle: Descriptor
        let identity: FolderIdentity
        let info: Darwin.stat
        let selectedPath: String
    }
    private struct Location {
        let root: OpenRoot
        let parent: Descriptor
        let chain: [Link]
        let leaf: String?
    }

    public func resolve(rootPath: String) throws -> FolderIdentity {
        try selectedRoot(rootPath).identity
    }

    public func caseSensitive(root: FolderSource) throws -> Bool {
        let opened = try openRoot(root)
        let values = try URL(fileURLWithPath: path(opened.handle.fd))
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard let sensitive = values.volumeSupportsCaseSensitiveNames else {
            throw IngestionError(code: "rootUnavailable")
        }
        return sensitive
    }

    public func list(root: FolderSource, directory: String) throws -> [FolderEntry] {
        try Task.checkCancellation()
        let location = try locate(root: root, relativePath: directory)
        let descriptor: Descriptor
        if let leaf = location.leaf {
            descriptor = try openChild(parent: location.parent, name: leaf, directory: true)
        } else { descriptor = location.parent }
        try validate(location, descriptor: descriptor)
        let duplicate = Darwin.dup(descriptor.fd)
        guard duplicate >= 0 else { throw posix() }
        guard let stream = fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw posix()
        }
        defer { closedir(stream) }
        var entries: [FolderEntry] = []
        while true {
            try Task.checkCancellation()
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { throw posix() }
                break
            }
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard name != ".", name != ".." else { continue }
            let info = try childStat(descriptor.fd, name)
            let type = info.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR || type == S_IFLNK else { continue }
            let relative = directory.isEmpty ? name : directory + "/" + name
            entries.append(try FolderEntry(relPath: relative, isDirectory: type == S_IFDIR,
                                       isLink: type == S_IFLNK, stamp: stamp(info)))
        }
        try validate(location, descriptor: descriptor)
        return entries.sorted { $0.relPath.unicodeScalars.lexicographicallyPrecedes($1.relPath.unicodeScalars) }
    }

    public func stat(root: FolderSource, relativePath: String) throws -> FileStamp {
        let location = try locate(root: root, relativePath: relativePath)
        guard let leaf = location.leaf else { return try stamp(location.root.info) }
        let handle = try openChild(parent: location.parent, name: leaf, directory: false)
        try validate(location, descriptor: handle)
        return try stamp(descriptorStat(handle.fd))
    }

    public func hash(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderRead {
        let result = try read(root: root, relativePath: relativePath, maxBytes: maxBytes, destination: nil)
        return FolderRead(bytes: Data(), stamp: result.0, sha256: result.1)
    }

    public func snapshot(root: FolderSource, relativePath: String, maxBytes: Int64) throws -> FolderFileSnapshot {
        try Task.checkCancellation()
        let ext = (relativePath as NSString).pathExtension
        let name = "ainotebook-snapshot-" + UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw posix() }
        let destination = Descriptor(fd)
        do {
            let result = try read(root: root, relativePath: relativePath, maxBytes: maxBytes, destination: destination)
            guard fchmod(destination.fd, mode_t(0o400)) == 0 else { throw posix() }
            return FolderFileSnapshot(url: url, stamp: result.0, hash: result.1)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func read(root: FolderSource, relativePath: String, maxBytes: Int64,
                      destination: Descriptor?) throws -> (FileStamp, String) {
        try Task.checkCancellation()
        guard maxBytes > 0 else { throw IngestionError(code: "fileLimit") }
        let location = try locate(root: root, relativePath: relativePath)
        guard let leaf = location.leaf else { throw IngestionError(code: "outsideRoot") }
        let enumerated = try childStat(location.parent.fd, leaf)
        guard enumerated.st_mode & S_IFMT != S_IFLNK else { throw IngestionError(code: "interiorLink") }
        guard enumerated.st_mode & S_IFMT == S_IFREG else { throw IngestionError(code: "outsideRoot") }
        do {
            return try readContents(location: location, leaf: leaf, enumerated: enumerated,
                                    relativePath: relativePath, maxBytes: maxBytes, destination: destination)
        } catch where !(error is IngestionError) {
            // A failed read of a still-dataless placeholder (iCloud not downloaded).
            let current = try? childStat(location.parent.fd, leaf)
            throw DatalessFile.readFailure(error, stillDataless: current.map(isDataless) ?? false)
        }
    }

    private func readContents(location: Location, leaf: String, enumerated: Darwin.stat, relativePath: String,
                              maxBytes: Int64, destination: Descriptor?) throws -> (FileStamp, String) {
        try beforeOpen(relativePath)
        let handle = try openChild(parent: location.parent, name: leaf, directory: false)
        try validate(location, descriptor: handle)
        let initial = try descriptorStat(handle.fd)
        try FolderAccessValidation.validateOpen(enumerated: stamp(enumerated), opened: stamp(initial),
            openedIsLink: initial.st_mode & S_IFMT == S_IFLNK, parentBefore: "same", parentAfter: "same")
        guard initial.st_mode & S_IFMT == S_IFREG else { throw IngestionError(code: "outsideRoot") }
        guard initial.st_size >= 0, initial.st_size <= maxBytes else { throw IngestionError(code: "fileLimit") }
        var digest = SHA256()
        var total: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw posix()
            }
            if count == 0 { break }
            guard Int64(count) <= maxBytes - total else { throw IngestionError(code: "fileLimit") }
            total += Int64(count)
            try didRead(count)
            digest.update(data: Data(buffer[0..<count]))
            if let destination {
                try buffer.withUnsafeBytes { bytes in
                    var written = 0
                    while written < count {
                        try Task.checkCancellation()
                        let n = Darwin.write(destination.fd, bytes.baseAddress!.advanced(by: written), count - written)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw posix() }
                        written += n
                    }
                }
            }
        }
        try validate(location, descriptor: handle)
        let final = try descriptorStat(handle.fd)
        guard try stamp(initial) == stamp(final), total == initial.st_size else {
            throw IngestionError(code: "changedDuringExtraction")
        }
        // The same descriptor may remain valid after replacement of its leaf.
        let current = try childStat(location.parent.fd, leaf)
        guard current.st_dev == initial.st_dev, try stamp(current) == stamp(initial) else {
            throw IngestionError(code: "changedDuringExtraction")
        }
        return (try stamp(initial), digest.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func selectedRoot(_ rootPath: String) throws -> OpenRoot {
        guard !rootPath.utf8.contains(0) else { throw IngestionError(code: "rootUnavailable") }
        let fd = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw IngestionError(code: "rootUnavailable") }
        let handle = Descriptor(fd)
        let info = try descriptorStat(fd)
        let canonical = try path(fd)
        let resources = try URL(fileURLWithPath: canonical).resourceValues(forKeys: [.volumeUUIDStringKey])
        // A device number is deliberately not persisted: it may change after
        // remounting. Volumes without a stable UUID cannot be registered safely.
        guard let volume = resources.volumeUUIDString, !volume.isEmpty else {
            throw IngestionError(code: "rootUnavailable")
        }
        let identity = FolderIdentity(volumeId: volume, components: components(canonical), rootFileId: String(info.st_ino))
        return OpenRoot(handle: handle, identity: identity, info: info, selectedPath: rootPath)
    }

    private func openRoot(_ root: FolderSource) throws -> OpenRoot {
        let opened = try selectedRoot(root.draft.rootPath)
        try FolderAccessValidation.validateRoot(persisted: root.identity, opened: opened.identity)
        return opened
    }

    private func locate(root: FolderSource, relativePath: String) throws -> Location {
        let names: [String]
        if relativePath.isEmpty { names = [] }
        else {
            names = relativePath.components(separatedBy: "/")
            guard !relativePath.contains("\\"), !relativePath.utf8.contains(0),
                  names.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw IngestionError(code: "outsideRoot")
            }
        }
        let opened = try openRoot(root)
        var parent = opened.handle
        var chain: [Link] = []
        for name in names.dropLast() {
            let child = try openChild(parent: parent, name: name, directory: true)
            let info = try descriptorStat(child.fd)
            guard info.st_dev == opened.info.st_dev else { throw IngestionError(code: "outsideRoot") }
            chain.append(Link(parent: parent, name: name, device: info.st_dev, inode: info.st_ino))
            try FolderAccessValidation.validateContainment(root: opened.identity, resolvedComponents: components(path(child.fd)))
            parent = child
        }
        return Location(root: opened, parent: parent, chain: chain, leaf: names.last)
    }

    private func openChild(parent: Descriptor, name: String, directory: Bool) throws -> Descriptor {
        let before = try childStat(parent.fd, name)
        guard before.st_mode & S_IFMT != S_IFLNK else { throw IngestionError(code: "interiorLink") }
        let fd = openat(parent.fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | (directory ? O_DIRECTORY : 0))
        guard fd >= 0 else {
            if errno == ELOOP { throw IngestionError(code: "interiorLink") }
            throw posix()
        }
        let handle = Descriptor(fd)
        let after = try descriptorStat(fd)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino else {
            throw IngestionError(code: "changedDuringExtraction")
        }
        return handle
    }

    private func validate(_ location: Location, descriptor: Descriptor) throws {
        try FolderAccessValidation.validateRoot(persisted: location.root.identity,
            opened: selectedRoot(location.root.selectedPath).identity)
        // Check every retained parent link, then the opened handle's resolved
        // components. A rename out of the root must fail before the first read.
        for link in location.chain {
            let current: Darwin.stat
            do { current = try childStat(link.parent.fd, link.name) }
            catch { throw IngestionError(code: "outsideRoot") }
            guard current.st_dev == link.device, current.st_ino == link.inode,
                  current.st_mode & S_IFMT == S_IFDIR else { throw IngestionError(code: "outsideRoot") }
        }
        let info = try descriptorStat(descriptor.fd)
        guard info.st_dev == location.root.info.st_dev else { throw IngestionError(code: "outsideRoot") }
        try FolderAccessValidation.validateContainment(root: location.root.identity,
            resolvedComponents: components(path(descriptor.fd)))
        let currentRootPath = try path(location.root.handle.fd)
        guard components(currentRootPath).map({ Data($0.utf8) }) == location.root.identity.components.map({ Data($0.utf8) }) else {
            throw IngestionError(code: "rootIdentityChanged")
        }
    }

    private func childStat(_ parent: Int32, _ name: String) throws -> Darwin.stat {
        var value = Darwin.stat()
        guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw posix() }
        return value
    }
    private func descriptorStat(_ fd: Int32) throws -> Darwin.stat {
        var value = Darwin.stat()
        guard fstat(fd, &value) == 0 else { throw posix() }
        return value
    }
    private func stamp(_ value: Darwin.stat) throws -> FileStamp {
        try FileStamp(identity: String(value.st_ino), mtimeNs: FolderAccessValidation.nanoseconds(
            seconds: Int64(value.st_mtimespec.tv_sec), nanoseconds: Int64(value.st_mtimespec.tv_nsec)),
                  sizeBytes: value.st_size)
    }
    private func path(_ fd: Int32) throws -> String {
        var bytes = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &bytes) == 0 else { throw posix() }
        return String(cString: bytes)
    }
    private func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
    private func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
