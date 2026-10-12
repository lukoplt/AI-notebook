import Foundation

extension OllamaClient: ChatStreaming {
    public func stream(
        model: String,
        messages: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages, options: .defaults)
    }

    public func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        -> AsyncThrowingStream<String, Error> {
        do {
            try options.validate()
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        // Map ChatRole → OllamaChatMessage.Role
        let wire = ProviderWire.canonicalMessages(messages).map { turn in
            OllamaChatMessage(
                role: Self.roleMap(turn.role),
                content: turn.content
            )
        }
        // OllamaClient.chat yields OllamaChatChunk; we re-yield each non-empty
        // message.content delta as a String. `done` flag terminates the inner
        // stream in OllamaClient already — the outer stream finishes naturally.
        let chunkStream = chat(model: model, messages: wire,
                               options: .init(numCtx: options.runtimeContext, numPredict: options.maxOutputTokens))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in chunkStream {
                        let delta = chunk.message.content
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func roleMap(_ role: ChatRole) -> OllamaChatMessage.Role {
        switch role {
        case .system:    return .system
        case .user:      return .user
        case .assistant: return .assistant
        }
    }
}
