import Foundation

public struct OllamaChatMessage: Codable, Equatable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OllamaChatRequest: Codable, Sendable {
    public let model: String
    public let messages: [OllamaChatMessage]
    public let stream: Bool
    public let options: Options?

    public struct Options: Codable, Sendable {
        public let temperature: Double?
        public let numCtx: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
        }

        public init(temperature: Double? = nil, numCtx: Int? = nil) {
            self.temperature = temperature
            self.numCtx = numCtx
        }
    }

    public init(
        model: String,
        messages: [OllamaChatMessage],
        stream: Bool = true,
        options: Options? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.options = options
    }
}

public struct OllamaChatChunk: Codable, Sendable {
    public let model: String
    public let createdAt: String
    public let message: OllamaChatMessage
    public let done: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
    }
}
