import Foundation

/// Epic D1: generates a 1–2 sentence document-level context for each chunk of
/// a source via the chat model and stores it in `source_chunks.context`, so the
/// embedder can prepend it (Anthropic "contextual retrieval"). Opt-in — ingest
/// only calls this when the settings toggle is on. Ported from the Windows
/// `ContextualEnricher`.
@MainActor
public final class ContextualEnricher {
    private let store: NotebookStore
    private let chat: ChatStreaming
    private let model: () -> String

    public init(store: NotebookStore, chat: ChatStreaming, model: @escaping () -> String) {
        self.store = store
        self.chat = chat
        self.model = model
    }

    /// Generates and stores context for every chunk of a source. Call after
    /// the chunks are persisted, before embedding.
    public func enrichSource(sourceId: Int64) async throws {
        let chunks = try store.chunks(sourceId: sourceId)
        guard !chunks.isEmpty else { return }

        // A preview of the first few chunks stands in for the whole document.
        let docPreview = chunks.prefix(5).map(\.text).joined(separator: "\n")
        let currentModel = model()

        for chunk in chunks {
            guard let chunkId = chunk.id else { continue }
            let context = try await generateContext(model: currentModel, docPreview: docPreview, chunkText: chunk.text)
            try store.setChunkContext(chunkId: chunkId, context: context)
        }
    }

    /// The enrichment prompt (verbatim shape from the Windows enricher).
    static func contextPrompt(docPreview: String, chunkText: String) -> String {
        "Here is a document excerpt:\n<document>\n\(docPreview)\n</document>\n\n"
        + "Here is a specific chunk from this document:\n<chunk>\n\(chunkText)\n</chunk>\n\n"
        + "In 1-2 sentences, describe what this chunk is about in the context of the document. "
        + "Be concise and factual. Reply with only the description."
    }

    private func generateContext(model: String, docPreview: String, chunkText: String) async throws -> String {
        let prompt = Self.contextPrompt(docPreview: docPreview, chunkText: chunkText)
        var result = ""
        for try await token in chat.stream(model: model, messages: [ChatTurn(role: .user, content: prompt)]) {
            result += token
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
