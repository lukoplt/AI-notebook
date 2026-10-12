import Foundation

public actor NoteIndexer {

    public enum IndexError: Error, Equatable {
        case noteNotFound(Int64)
    }

    private let store: NotebookStore
    private let onChunksWritten: (@Sendable () async -> Void)?
    private let leaseClock: any IngestLeaseClock

    public init(
        store: NotebookStore,
        onChunksWritten: (@Sendable () async -> Void)? = nil,
        leaseClock: any IngestLeaseClock = SystemIngestLeaseClock()
    ) {
        self.store = store
        self.onChunksWritten = onChunksWritten
        self.leaseClock = leaseClock
    }

    public func index(noteId: Int64) async throws {
        let storeRef = store

        let clock = leaseClock
        let prep: (Note, Int64, JobFence) = try await MainActor.run {
            try Task.checkCancellation()
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
            let fence = try storeRef.beginExtraction(sourceId: sourceId, now: clock.now(), leaseToken: UUID().uuidString)
            return (note, sourceId, fence)
        }
        let (note, sourceId, fence) = prep
        let renewal = ExtractionLeaseRenewal.start(store: storeRef, fence: fence, clock: clock)

        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let assembled = ExtractedRevisionAssembly.make(
                    extracted: ExtractedText(title: note.title, text: note.bodyMd), kind: .note)
                renewal.cancel()
                await renewal.value
                let committed = try await MainActor.run {
                    try Task.checkCancellation()
                    return try storeRef.commitExtraction(sourceId: sourceId, draft: assembled.draft,
                        chunks: assembled.chunks, fence: fence, now: clock.now()) != nil
                }
                if committed { await onChunksWritten?() }
            } catch {
                renewal.cancel()
                await renewal.value
                let cancelled = error is CancellationError || Task.isCancelled
                _ = try? await MainActor.run {
                    if cancelled {
                        return try storeRef.cancelJob(fence: fence, now: clock.now())
                    }
                    return try storeRef.failJob(fence: fence, error: String(describing: error), now: clock.now())
                }
                throw error
            }
        } onCancel: {
            renewal.cancel()
        }
    }
}
