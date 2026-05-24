import Foundation
import GRDB

@MainActor
public final class AttachmentStore {

    private let store: NotebookStore
    public let root: URL

    public init(store: NotebookStore, root: URL) {
        self.store = store
        self.root = root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public static func defaultRoot(fileManager: FileManager = .default) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )
        let container = appSupport.appendingPathComponent("AINotebook", isDirectory: true)
        let attachments = container.appendingPathComponent("attachments", isDirectory: true)
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        return attachments
    }

    @discardableResult
    public func save(
        noteId: Int64,
        noteUuid: String,
        filename: String,
        mime: String,
        bytes: Data
    ) throws -> NoteAttachment {
        let folder = root.appendingPathComponent(noteUuid, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolved = uniqueFilename(in: folder, requested: filename)
        let url = folder.appendingPathComponent(resolved)
        try bytes.write(to: url)
        var att = NoteAttachment(
            noteId: noteId,
            noteUuid: noteUuid,
            filename: resolved,
            mime: mime,
            byteSize: Int64(bytes.count)
        )
        try store.runOnDatabase { db in
            try att.insert(db)
        }
        return att
    }

    public func read(noteUuid: String, filename: String) throws -> Data {
        let url = root
            .appendingPathComponent(noteUuid, isDirectory: true)
            .appendingPathComponent(filename)
        return try Data(contentsOf: url)
    }

    public func list(noteId: Int64) throws -> [NoteAttachment] {
        try store.runOnDatabase { db in
            try NoteAttachment
                .filter(NoteAttachment.Columns.noteId.column == noteId)
                .order(NoteAttachment.Columns.createdAt.column.asc)
                .fetchAll(db)
        }
    }

    public func deleteFolder(noteUuid: String) throws {
        let folder = root.appendingPathComponent(noteUuid, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    private func uniqueFilename(in folder: URL, requested: String) -> String {
        let stem = (requested as NSString).deletingPathExtension
        let ext = (requested as NSString).pathExtension
        let dotExt = ext.isEmpty ? "" : ".\(ext)"
        var candidate = requested
        var n = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(n))\(dotExt)"
            n += 1
            if n > 9_999 { break }
        }
        return candidate
    }
}
