import Foundation

/// Produces and persists a short plain-text summary for a single source.
/// Lazy-friendly: the caller decides when to summarize. Reuses the same
/// `ChatStreaming` abstraction as the chat and transformation engines.
public actor SourceSummarizer {
    public enum SummarizeError: Error, Equatable {
        case sourceNotFound(Int64)
    }

    private let store: NotebookStore
    private let chat: ChatStreaming
    public let chatModel: String

    public init(store: NotebookStore, chat: ChatStreaming, chatModel: String) {
        self.store = store
        self.chat = chat
        self.chatModel = chatModel
    }

    /// Summarize the source's chunks into 2-3 plain-text sentences, persist the
    /// result, and return it. Returns an empty string without calling the model
    /// when the source has no chunks.
    @discardableResult
    public func summarize(sourceId: Int64) async throws -> String {
        let storeRef = store
        let chunks: [SourceChunk] = try await MainActor.run {
            try storeRef.chunks(sourceId: sourceId)
        }
        guard !chunks.isEmpty else { return "" }

        let sourceText = chunks.map(\.text).joined(separator: "\n\n")
        let prompt = """
        Summarize the following source in 2-3 plain-text sentences. Stay grounded \
        in the text and do not add anything not present in it. Output the summary \
        only — no preamble, no Markdown.

        SOURCE TEXT:
        \(sourceText)
        """
        let turns: [ChatTurn] = [ChatTurn(role: .user, content: prompt)]
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
        }
        let summary = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        try await MainActor.run {
            try storeRef.setSourceSummary(id: sourceId, text: summary)
        }
        return summary
    }
}
