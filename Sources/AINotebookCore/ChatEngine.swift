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
    public let retryAttempts: Int
    public let retryBackoffMillis: Int

    public init(
        store: NotebookStore,
        retriever: Retriever,
        chat: ChatStreaming,
        chatModel: String,
        topK: Int = 8,
        retryAttempts: Int = 2,
        retryBackoffMillis: Int = 250
    ) {
        self.store = store
        self.retriever = retriever
        self.chat = chat
        self.chatModel = chatModel
        self.topK = topK
        self.retryAttempts = retryAttempts
        self.retryBackoffMillis = retryBackoffMillis
    }

    @discardableResult
    public func send(
        sessionId: Int64,
        notebookId: Int64,
        userText: String,
        currentNoteContent: String? = nil,
        sourceIds: Set<Int64> = [],
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
            topK: topK,
            sourceIds: sourceIds
        )

        // 3) Compose messages.
        let systemContent = SystemPrompt.compose(hits: hits, currentNoteContent: currentNoteContent)
        let history = try await MainActor.run {
            try storeRef.messages(sessionId: sessionId)
        }
        var turns: [ChatTurn] = [ChatTurn(role: .system, content: systemContent)]
        for m in history {
            turns.append(ChatTurn(role: m.role, content: m.content))
        }

        // 4) Stream tokens with retry + exponential backoff.
        var assembled = ""
        var attempt = 0
        while true {
            do {
                var partial = ""
                for try await token in chat.stream(model: chatModel, messages: turns) {
                    partial += token
                    onToken(token)
                }
                assembled = partial
                break
            } catch {
                if let providerError = error as? ProviderError {
                    switch providerError {
                    case .auth, .refusal, .consentRequired:
                        // Retrying cannot help — the user must fix the key,
                        // rephrase (FR-A10), or grant consent (FR-A8).
                        throw providerError
                    case .rateLimit(let retryAfterSeconds):
                        if attempt >= retryAttempts { throw providerError }
                        attempt += 1
                        let fallback = Double(retryBackoffMillis) * pow(2.0, Double(attempt - 1)) / 1000.0
                        let seconds = retryAfterSeconds ?? fallback
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        continue
                    case .http, .decoding:
                        break // generic backoff below
                    }
                }
                if attempt >= retryAttempts { throw error }
                attempt += 1
                let delayNs = UInt64(retryBackoffMillis * Int(pow(2.0, Double(attempt - 1)))) * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
            }
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
