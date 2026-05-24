import Foundation

public struct ChatTurn: Equatable, Sendable {
    public let role: ChatRole
    public let content: String
    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol ChatStreaming: Sendable {
    func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}

public actor ChatEngine {
    private let store: NotebookStore
    private let retriever: Retriever
    private let chat: ChatStreaming
    public let chatModel: String
    public let topK: Int

    public init(
        store: NotebookStore,
        retriever: Retriever,
        chat: ChatStreaming,
        chatModel: String,
        topK: Int = 8
    ) {
        self.store = store
        self.retriever = retriever
        self.chat = chat
        self.chatModel = chatModel
        self.topK = topK
    }

    @discardableResult
    public func send(
        sessionId: Int64,
        notebookId: Int64,
        userText: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ChatMessage {
        // 1) Persist the user message.
        let storeRef = store
        try await MainActor.run {
            try storeRef.appendMessage(ChatMessage(
                sessionId: sessionId,
                role: .user,
                content: userText
            ))
        }

        // 2) Retrieve context.
        let hits = try await retriever.search(
            notebookId: notebookId,
            query: userText,
            topK: topK
        )

        // 3) Compose messages.
        let systemContent = SystemPrompt.compose(hits: hits)
        let history = try await MainActor.run {
            try storeRef.messages(sessionId: sessionId)
        }
        var turns: [ChatTurn] = [ChatTurn(role: .system, content: systemContent)]
        for m in history {
            turns.append(ChatTurn(role: m.role, content: m.content))
        }

        // 4) Stream tokens.
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
            onToken(token)
        }

        // 5) Parse citation markers and resolve to chunks.
        let markers = CitationParser.markers(in: assembled)
        var seen = Set<Int>()
        var uniqueOrdered: [Int] = []
        for m in markers where !seen.contains(m) {
            seen.insert(m)
            uniqueOrdered.append(m)
        }
        var citations: [Citation] = []
        for m in uniqueOrdered {
            guard m >= 1, m <= hits.count else { continue }
            let h = hits[m - 1]
            citations.append(Citation(
                marker: m,
                chunkId: h.chunkId,
                sourceId: h.sourceId,
                snippet: h.snippet
            ))
        }

        // 6) Persist the assistant message.
        let stored = ChatMessage(
            sessionId: sessionId,
            role: .assistant,
            content: assembled,
            citations: citations
        )
        try await MainActor.run {
            try storeRef.appendMessage(stored)
        }
        return stored
    }
}
