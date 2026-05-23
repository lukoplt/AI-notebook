import Foundation

public enum OllamaError: Error, Equatable, Sendable {
    case notReachable
    case timeout
    case httpStatus(code: Int, body: String)
    case decoding(message: String)
    case modelNotFound(name: String)
    case unexpectedEndOfStream
    case cancelled
}

extension OllamaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReachable:
            "Ollama daemon is not reachable on localhost:11434."
        case .timeout:
            "Ollama request timed out."
        case .httpStatus(let code, _):
            "Ollama returned HTTP \(code)."
        case .decoding(let message):
            "Failed to decode Ollama response: \(message)."
        case .modelNotFound(let name):
            "Ollama model \"\(name)\" is not pulled."
        case .unexpectedEndOfStream:
            "Ollama stream ended before completion."
        case .cancelled:
            "Ollama request was cancelled."
        }
    }
}
