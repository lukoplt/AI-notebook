import Foundation

extension OllamaClient: ChatStreaming {
    public func stream(
        model: String,
        messages: [ChatTurn]
    ) -> AsyncThrowingStream<String, Error> {
        // Map ChatRole → OllamaChatMessage.Role
        let wire = messages.map { turn in
            OllamaChatMessage(
                role: Self.roleMap(turn.role),
                content: turn.content
            )
        }
        // OllamaClient.chat yields OllamaChatChunk; we re-yield each non-empty
        // message.content delta as a String. `done` flag terminates the inner
        // stream in OllamaClient already — the outer stream finishes naturally.
        let chunkStream = chat(model: model, messages: wire)
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
