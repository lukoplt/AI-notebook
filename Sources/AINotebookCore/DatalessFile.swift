import Darwin
import Foundation

/// Cloud placeholders (iCloud Drive with "Optimize Mac Storage", other File
/// Provider folders) are "dataless": metadata is local, content is not. Reading
/// one asks the system to download it; when that fails (offline, provider
/// error) the read error is reported as `notDownloaded` instead of a generic
/// read or archive error. Nothing here starts a download on its own.
enum DatalessFile {
    /// `SF_DATALESS` from <sys/stat.h>.
    static let flag: UInt32 = 0x4000_0000

    static func isDataless(flags: UInt32) -> Bool { flags & flag != 0 }

    /// lstat only: never opens the file, never triggers materialization.
    static func isDataless(path: String) -> Bool {
        var info = Darwin.stat()
        return lstat(path, &info) == 0 && isDataless(flags: info.st_flags)
    }

    /// iCloud also reports placeholders through URL resource values.
    static func isNotDownloaded(_ url: URL) -> Bool {
        if isDataless(path: url.path) { return true }
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus == .notDownloaded
    }

    /// A failed read of a still-dataless file becomes `notDownloaded`;
    /// cancellation and every other failure pass through unchanged.
    static func readFailure(_ error: Error, stillDataless: Bool) -> Error {
        guard stillDataless, !(error is CancellationError) else { return error }
        return IngestionError(code: "notDownloaded")
    }
}
