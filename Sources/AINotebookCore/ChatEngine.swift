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
    func stream(model: String, messages: [ChatTurn], options: ChatRequestOptions)
        -> AsyncThrowingStream<String, Error>
}

/// Chat turns are prepared once into an immutable context pack (WP8) and the
/// exact prepared request is streamed. Preparation writes nothing; the user
/// row is appended immediately before the first stream attempt and the
/// assistant row only after a successful stream.
public actor ChatEngine {
    private let store: NotebookStore
    public nonisolated let coordinator: ContextPackCoordinator
    public nonisolated let previews: ContextPreviewSession
    public let chatModel: String
    /// Explicit retrieval overrides; nil takes the value from the runtime tuning.
    public let topK: Int?
    public let fetchK: Int?
    /// WP7 runtime tuning (the shipped benchmark decision by default), resolved once per
    /// captured intent so a preview and its send hash the same fetchK/topK.
    private let tuning: @Sendable () throws -> RagRuntimeTuning
    public let retryAttempts: Int
    public let retryBackoffMillis: Int
    private let admission: IngestionAdmission?
    /// Per-session send guard: fingerprint reads plus the user insert of one
    /// turn never interleave with another send in the same session.
    private var sendingSessions = Set<Int64>()

    /// Compatibility initializer: adapts the merged WP5 retriever and WP2
    /// provider transport through `ContextPackAdapters`.
    public init(
        store: NotebookStore,
        retriever: Retriever,
        chat: ChatStreaming,
        chatModel: String,
        webSearch: WebSearch? = nil,
        topK: Int? = nil,
        retryAttempts: Int = 2,
        retryBackoffMillis: Int = 250,
        admission: IngestionAdmission? = nil
    ) {
        let coordinator = ContextPackCoordinator(
            data: CompatibilityPackDataSource(store: store, retriever: retriever, webSearch: webSearch),
            transports: CompatibilityPackTransportFactory(chat: chat, model: chatModel, store: store))
        self.init(store: store, coordinator: coordinator, previews: ContextPreviewSession(), chatModel: chatModel,
                  retryAttempts: retryAttempts, retryBackoffMillis: retryBackoffMillis, admission: admission,
                  topK: topK)
    }

    public init(
        store: NotebookStore,
        coordinator: ContextPackCoordinator,
        previews: ContextPreviewSession,
        chatModel: String,
        retryAttempts: Int = 2,
        retryBackoffMillis: Int = 250,
        admission: IngestionAdmission? = nil,
        topK: Int? = nil,
        fetchK: Int? = nil,
        tuning: @escaping @Sendable () throws -> RagRuntimeTuning = { try RagRuntimeTuning.bundled() }
    ) {
        self.store = store
        self.coordinator = coordinator
        self.previews = previews
        self.chatModel = chatModel
        self.topK = topK
        self.fetchK = fetchK
        self.tuning = tuning
        self.retryAttempts = retryAttempts
        self.retryBackoffMillis = retryBackoffMillis
        self.admission = admission
    }

    /// Holds a chat admission token for the whole phase so no new background
    /// embedding batch starts meanwhile; released on success, error and
    /// cancellation in an awaited exit (never a detached defer).
    private func admitted<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        guard let admission else { return try await body() }
        let token = await admission.beginChat()
        do {
            let value = try await body()
            await admission.endChat(token)
            return value
        } catch {
            await admission.endChat(token)
            throw error
        }
    }

    /// A capture → prepare → send cycle whose scope evidence changed underneath it
    /// (a running folder check or extraction; `stalePreparedRequest` is thrown
    /// before any row or network call) runs again from the new snapshot, at most
    /// `ChatSessionState.staleRepreparations` more times (chat-during-scan-v1 §3).
    private func reprepareOnStale<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch ChatEngineError.stalePreparedRequest where ChatSessionState.reprepareAfterStale(attempt: attempt) {
                attempt += 1
                try Task.checkCancellation()
            }
        }
    }

    private func beginSending(_ sessionId: Int64) throws {
        guard sendingSessions.insert(sessionId).inserted else { throw ChatEngineError.sendInProgress }
    }

    private func endSending(_ sessionId: Int64) {
        sendingSessions.remove(sessionId)
    }

    // MARK: - Two-phase API (preview UI)

    /// Captures everything a turn depends on from the live selection, store and
    /// arguments. The UI derives `PackIntentKey.make(intent)` from a fresh
    /// capture to detect a stale preview.
    public func captureIntent(
        sessionId: Int64, notebookId: Int64, question: String, scope: RetrievalScope,
        mode: String = "answer", currentNoteContent: String? = nil, useWebSearch: Bool = false,
        model: String? = nil, instructionsOverride: String? = nil,
        regenerateUserId: Int64? = nil, replacesAssistantId: Int64? = nil, editUserText: Bool = false
    ) async throws -> PackIntent {
        guard ["answer", "overview"].contains(mode) else { throw StorageV19Error.invalidValue }
        try Task.checkCancellation()
        let described = try await coordinator.describe(requestedModel: model)
        let retrieval = try Self.retrieval(topK: topK, fetchK: fetchK, tuning: tuning())
        // One read snapshot, off the main actor (chat-during-scan-v1 §2).
        let captured = try store.contextReadSnapshot(notebookId: notebookId, sessionId: sessionId, scope: scope,
                                                     includeMaterialized: false)
        return PackIntent(notebookId: notebookId, sessionId: sessionId, question: question, mode: mode, scope: scope,
                          providerId: described.model.providerId, model: described.model.model,
                          providerConfigurationRevision: described.configurationRevision,
                          runtimeContext: described.model.runtimeContext,
                          maxOutputTokens: described.model.maxOutputTokens,
                          evidenceBudgetCap: captured.evidenceBudgetCap, fetchK: retrieval.fetchK, topK: retrieval.topK,
                          notebookInstructions: captured.notebookInstructions, instructionsOverride: instructionsOverride,
                          currentNoteContent: currentNoteContent, useWebSearch: useWebSearch,
                          historyFingerprint: captured.historyFingerprint, scopeFingerprint: captured.scopeFingerprint,
                          regenerateUserId: regenerateUserId, replacesAssistantId: replacesAssistantId,
                          editUserText: editUserText)
    }

    /// Explicit values win; omitted ones come from the tuning; fetchK never drops below topK.
    static func retrieval(topK: Int?, fetchK: Int?, tuning: RagRuntimeTuning) -> (fetchK: Int, topK: Int) {
        let top = topK ?? tuning.topK
        return (max(fetchK ?? tuning.fetchK, top), top)
    }

    /// Builds the exact request a later `sendPrepared` streams. Writes nothing.
    public func prepare(_ intent: PackIntent) async throws -> PreparedPackHandle {
        try await admitted { try await coordinator.prepare(intent) }
    }

    /// Streams `handle.request` unchanged (including on retries), persists the
    /// answer with its packed citations and retains the sent preview by the
    /// real assistant ID. `expectedKey` is the key of a freshly captured
    /// intent; a mismatch or changed history/scope throws
    /// `stalePreparedRequest` without a row or network call.
    @discardableResult
    public func sendPrepared(
        _ handle: PreparedPackHandle, expectedKey: Data,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void = {}
    ) async throws -> ChatMessage {
        let sessionId = handle.intent.sessionId
        try beginSending(sessionId)
        do {
            let reply = try await admitted {
                try await streamPrepared(handle, expectedKey: expectedKey, onToken: onToken, onRetry: onRetry)
            }
            endSending(sessionId)
            return reply
        } catch {
            endSending(sessionId)
            throw error
        }
    }

    // MARK: - Convenience (capture → prepare → send)

    /// Typed-scope send: folders and sets resolve to live eligible members for
    /// this turn; `.all` searches the whole notebook; an empty selection
    /// retrieves no evidence. `mode` is `answer` or `overview`.
    @discardableResult
    public func send(
        sessionId: Int64, notebookId: Int64, userText: String,
        scope: RetrievalScope, mode: String = "answer", currentNoteContent: String? = nil,
        useWebSearch: Bool = false, model: String? = nil, instructionsOverride: String? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void = {}
    ) async throws -> ChatMessage {
        try beginSending(sessionId)
        do {
            let reply = try await admitted {
                try await reprepareOnStale {
                    let intent = try await captureIntent(
                        sessionId: sessionId, notebookId: notebookId, question: userText, scope: scope, mode: mode,
                        currentNoteContent: currentNoteContent, useWebSearch: useWebSearch, model: model,
                        instructionsOverride: instructionsOverride)
                    let handle = try await coordinator.prepare(intent)
                    return try await streamPrepared(handle, expectedKey: handle.key, onToken: onToken, onRetry: onRetry)
                }
            }
            endSending(sessionId)
            return reply
        } catch {
            endSending(sessionId)
            throw error
        }
    }

    /// Typed-scope regenerate of the last exchange. The existing user row and
    /// the previous answer stay until the replacement commits.
    @discardableResult
    public func regenerate(
        sessionId: Int64, notebookId: Int64, scope: RetrievalScope, mode: String = "answer",
        currentNoteContent: String? = nil, model: String? = nil, instructionsOverride: String? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void = {}
    ) async throws -> ChatMessage {
        try beginSending(sessionId)
        do {
            let reply = try await admitted {
                try await reprepareOnStale {
                    let target = try await regenerateTarget(sessionId: sessionId)
                    let intent = try await captureIntent(
                        sessionId: sessionId, notebookId: notebookId, question: target.user.content, scope: scope,
                        mode: mode, currentNoteContent: currentNoteContent, model: model,
                        instructionsOverride: instructionsOverride, regenerateUserId: target.user.id,
                        replacesAssistantId: target.assistantId)
                    let handle = try await coordinator.prepare(intent)
                    return try await streamPrepared(handle, expectedKey: handle.key, onToken: onToken, onRetry: onRetry)
                }
            }
            endSending(sessionId)
            return reply
        } catch {
            endSending(sessionId)
            throw error
        }
    }

    /// The last user row and, when answered, its trailing assistant row.
    public func regenerateTarget(sessionId: Int64) async throws -> (user: ChatMessage, assistantId: Int64?) {
        let storeRef = store
        let history = try await MainActor.run { try storeRef.messages(sessionId: sessionId) }
            .filter { $0.id != nil }.sorted { $0.id! < $1.id! }
        let assistantId = history.last.flatMap { $0.role == .assistant ? $0.id : nil }
        let candidates = assistantId == nil ? history : Array(history.dropLast())
        guard let user = candidates.last, user.role == .user else { throw ChatEngineError.noUserMessageToRegenerate }
        return (user, assistantId)
    }

    /// Old-signature compatibility wrappers: empty `sourceIds` keeps its old
    /// "whole notebook" meaning. New callers use the typed-scope overloads.
    @discardableResult
    public func send(
        sessionId: Int64,
        notebookId: Int64,
        userText: String,
        currentNoteContent: String? = nil,
        sourceIds: Set<Int64> = [],
        useWebSearch: Bool = false,
        model: String? = nil,
        instructionsOverride: String? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void = {}
    ) async throws -> ChatMessage {
        try await send(sessionId: sessionId, notebookId: notebookId, userText: userText,
                       scope: Self.legacyScope(sourceIds), currentNoteContent: currentNoteContent,
                       useWebSearch: useWebSearch, model: model, instructionsOverride: instructionsOverride,
                       onToken: onToken, onRetry: onRetry)
    }

    @discardableResult
    public func regenerate(
        sessionId: Int64,
        notebookId: Int64,
        currentNoteContent: String? = nil,
        sourceIds: Set<Int64> = [],
        model: String? = nil,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void = {}
    ) async throws -> ChatMessage {
        try await regenerate(sessionId: sessionId, notebookId: notebookId, scope: Self.legacyScope(sourceIds),
                             currentNoteContent: currentNoteContent, model: model, onToken: onToken, onRetry: onRetry)
    }

    private static func legacyScope(_ sourceIds: Set<Int64>) -> RetrievalScope {
        sourceIds.isEmpty ? .all : .selection(sourceIds: sourceIds, folderIds: [])
    }

    // MARK: - Streaming

    private func streamPrepared(
        _ handle: PreparedPackHandle, expectedKey: Data,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void
    ) async throws -> ChatMessage {
        let intent = handle.intent
        guard expectedKey == handle.key else { throw ChatEngineError.stalePreparedRequest }
        guard !(await handle.isConsumed) else { throw ChatEngineError.preparedRequestConsumed }
        let storeRef = store
        let current = try storeRef.contextReadSnapshot(notebookId: intent.notebookId, sessionId: intent.sessionId,
                                                       scope: intent.scope, includeMaterialized: false)
        guard current.historyFingerprint == intent.historyFingerprint, current.scopeFingerprint == intent.scopeFingerprint else {
            throw ChatEngineError.stalePreparedRequest
        }
        // One-shot from here on, whatever the outcome.
        guard await handle.consume() else { throw ChatEngineError.preparedRequestConsumed }
        try Task.checkCancellation()
        if intent.regenerateUserId == nil {
            _ = try await MainActor.run { try storeRef.appendContextUser(sessionId: intent.sessionId, text: intent.question) }
        }

        let assembled = try await streamWithRetry(handle, onToken: onToken, onRetry: onRetry)

        // Resolve markers against the finished pack; unknown markers are dropped.
        let byMarker = Dictionary(handle.request.citationMap.map { ($0.marker, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        let citations = CitationParser.markers(in: assembled).compactMap { marker -> Citation? in
            guard seen.insert(marker).inserted else { return nil }
            return byMarker[marker]
        }
        let model = handle.transport.storageModel
        let stored = try await MainActor.run {
            try storeRef.commitContextAssistant(
                sessionId: intent.sessionId, content: assembled, citations: citations, model: model,
                replacesAssistantId: intent.replacesAssistantId, replacesUserId: intent.regenerateUserId,
                replacementUserText: intent.editUserText ? intent.question : nil)
        }
        if let assistantId = stored.id {
            if await previews.draft(key: handle.key) != nil {
                await previews.promoteDraft(sessionId: intent.sessionId, assistantId: assistantId)
            } else if let bytes = try? ContextPreviewSnapshotJSON.encode(handle.snapshot) {
                await previews.retain(bytes, sessionId: intent.sessionId, assistantId: assistantId)
            }
        }
        return stored
    }

    /// Retries reuse the same frozen transport and request. Auth, refusal,
    /// consent, configuration and context-length errors are terminal;
    /// cancellation is never retried.
    private func streamWithRetry(
        _ handle: PreparedPackHandle,
        onToken: @escaping @Sendable (String) -> Void,
        onRetry: @escaping @Sendable () -> Void
    ) async throws -> String {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                var partial = ""
                for try await token in handle.transport.stream(handle.request) {
                    try Task.checkCancellation()
                    partial += token
                    onToken(token)
                }
                try Task.checkCancellation()
                return partial
            } catch {
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled
                    || (error as? OllamaError) == .cancelled
                    || error is ProviderConfigurationError || error is ProviderRequestError
                    || error is ChatEngineError || error is ContextPackError {
                    throw error
                }
                if let providerError = error as? ProviderError {
                    switch providerError {
                    case .auth, .refusal, .consentRequired:
                        // Retrying cannot help — the user must fix the key,
                        // rephrase (FR-A10), or grant consent (FR-A8).
                        throw providerError
                    case .rateLimit(let retryAfterSeconds):
                        if attempt >= retryAttempts { throw providerError }
                        attempt += 1
                        // Tokens from the failed attempt already reached
                        // onToken, so the caller's buffer holds a partial
                        // answer this retry would append to. Tell it to drop.
                        onRetry()
                        let fallback = Double(retryBackoffMillis) * pow(2.0, Double(attempt - 1)) / 1000.0
                        let seconds = retryAfterSeconds ?? fallback
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        continue
                    case .http, .decoding:
                        break // generic backoff below
                    }
                }
                if attempt >= retryAttempts { throw error }
                attempt += 1
                onRetry()
                let delayNs = UInt64(retryBackoffMillis * Int(pow(2.0, Double(attempt - 1)))) * 1_000_000
                try await Task.sleep(nanoseconds: delayNs)
            }
        }
    }
}

public enum ChatEngineError: Error, Equatable, Sendable {
    case noUserMessageToRegenerate
    /// The prepared request no longer matches the captured intent, history or scope.
    case stalePreparedRequest
    /// A prepared handle is one-shot; it cannot be streamed twice.
    case preparedRequestConsumed
    /// Another turn of this session is already being sent.
    case sendInProgress
}
