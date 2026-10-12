import Foundation

public protocol ChatSessionPreparing: Sendable {
    func prepareChat(model: String?) async throws -> ProviderChatSession
}

/// Immutable per-turn adapter and options. Credentials never enter public metadata.
public struct ProviderChatSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let providerId: String
    public let model: String
    public var storageKey: String { providerId + ":" + model }
    public let limits: ProviderModelLimits
    private let adapter: any ChatStreaming

    init(providerId: String, model: String, limits: ProviderModelLimits, adapter: any ChatStreaming) {
        self.providerId = providerId
        self.model = model
        self.limits = limits
        self.adapter = adapter
    }

    public func stream(messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        adapter.stream(model: model, messages: messages, options: limits.options)
    }

    func withOptions(_ options: ChatRequestOptions) throws -> ProviderChatSession {
        let value = ProviderModelLimits(providerId: providerId, model: model,
            contextWindow: limits.contextWindow, runtimeContext: options.runtimeContext,
            maxOutputTokens: options.maxOutputTokens, source: limits.source)
        try value.validate()
        return ProviderChatSession(providerId: providerId, model: model, limits: value, adapter: adapter)
    }

    public var description: String { "ProviderChatSession(providerId: \(providerId), model: \(model))" }
    public var debugDescription: String { description }
}
