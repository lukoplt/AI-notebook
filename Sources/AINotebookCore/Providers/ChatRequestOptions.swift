/// Per-request limits shared by every chat transport.
public struct ChatRequestOptions: Equatable, Sendable {
    public let runtimeContext: Int
    public let maxOutputTokens: Int

    public init(runtimeContext: Int, maxOutputTokens: Int) {
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
    }

    public static let defaults = ChatRequestOptions(
        runtimeContext: RagContractV1.Providers.defaultRuntimeContext,
        maxOutputTokens: RagContractV1.Providers.defaultMaxOutputTokens
    )

    public func validate() throws {
        guard runtimeContext > 0, maxOutputTokens > 0, maxOutputTokens < runtimeContext else {
            throw ProviderConfigurationError.invalidLimits
        }
    }
}

public enum ProviderRequestError: Error, Sendable {
    case contextTooLong
}

/// Existing clients and test doubles can retain their no-options requirement.
/// Concrete provider adapters override this overload to serialize the limits.
public extension ChatStreaming {
    func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        -> AsyncThrowingStream<String, Error> {
        stream(model: model, messages: messages)
    }
}
