import Foundation

public actor TransformationEngine {
    public enum RunError: Error, Equatable {
        case sourceNotFound(Int64)
        case transformationNotFound(Int64)
        case noChunks(Int64)
    }

    private let store: NotebookStore
    private let chat: ChatStreaming
    public let chatModel: String

    public init(store: NotebookStore, chat: ChatStreaming, chatModel: String) {
        self.store = store
        self.chat = chat
        self.chatModel = chatModel
    }

    @discardableResult
    public func run(transformationId: Int64, sourceId: Int64) async throws -> Note {
        let storeRef = store

        let prep: (Transformation, Source, [SourceChunk]) =
            try await MainActor.run {
                guard let t = try storeRef.transformations().first(where: { $0.id == transformationId }) else {
                    throw RunError.transformationNotFound(transformationId)
                }
                guard let s = try storeRef.source(id: sourceId) else {
                    throw RunError.sourceNotFound(sourceId)
                }
                let cs = try storeRef.chunks(sourceId: sourceId)
                return (t, s, cs)
            }
        let (transformation, source, chunks) = prep
        guard !chunks.isEmpty else { throw RunError.noChunks(sourceId) }

        let sourceText = chunks.map(\.text).joined(separator: "\n\n")
        let rendered = transformation.promptTemplate
            .replacingOccurrences(of: "{{source_text}}", with: sourceText)

        let turns: [ChatTurn] = [
            ChatTurn(role: .user, content: rendered)
        ]
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
        }

        let noteTitle = "\(transformation.name) — \(source.title)"
        let note = try await MainActor.run {
            let created = try storeRef.createNote(
                notebookId: source.notebookId,
                title: noteTitle,
                bodyMd: assembled,
                origin: .transformation,
                originRef: transformation.id
            )
            _ = try storeRef.recordTransformationRun(
                transformationId: transformation.id!,
                sourceId: source.id!,
                resultNoteId: created.id
            )
            return created
        }
        return note
    }
}
