import Foundation

public actor NoteIndexer {

    public enum IndexError: Error, Equatable {
        case noteNotFound(Int64)
    }

    private let store: NotebookStore
    private let onChunksWritten: (@Sendable () async -> Void)?

    public init(
        store: NotebookStore,
        onChunksWritten: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.onChunksWritten = onChunksWritten
    }

    public func index(noteId: Int64) async throws {
        let storeRef = store

        let prep: (Note, Int64) = try await MainActor.run {
            guard let note = try storeRef.note(id: noteId) else {
                throw IndexError.noteNotFound(noteId)
            }
            let sourceId: Int64
            if let existing = note.autoSourceId,
               try storeRef.source(id: existing) != nil {
                var s = try storeRef.source(id: existing)!
                if s.title != note.title {
                    s.title = note.title
                    try storeRef.runOnDatabase { db in try s.update(db) }
                }
                sourceId = existing
            } else {
                let created = try storeRef.createSource(
                    notebookId: note.notebookId,
                    type: .note,
                    title: note.title,
                    uri: nil,
                    rawPath: nil
                )
                sourceId = created.id!
                try storeRef.linkNoteToShadowSource(noteId: noteId, sourceId: sourceId)
            }
            return (note, sourceId)
        }
        let (note, sourceId) = prep

        let drafts: [ChunkDraft] = note.bodyMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : Chunker.chunk(note.bodyMd)

        try await MainActor.run {
            try storeRef.replaceChunks(sourceId: sourceId, chunks: drafts)
            try storeRef.updateSourceStatus(id: sourceId, status: .ready, error: nil)
        }

        await onChunksWritten?()
    }
}
