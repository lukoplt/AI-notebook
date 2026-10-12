import Foundation
import CryptoKit

// MARK: - WP8 ports

/// One retrieval identity from the pinned candidate pool, in fused order.
public struct PackHit: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let revisionId: Int64
    public let rrfMicro: Int64

    public init(chunkId: Int64, sourceId: Int64, revisionId: Int64, rrfMicro: Int64) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.revisionId = revisionId
        self.rrfMicro = rrfMicro
    }
}

/// Everything a turn depends on, captured before preparation. Its SHA-256
/// (`PackIntentKey`) lets the UI detect any change since a preview was built.
public struct PackIntent: Codable, Equatable, Sendable {
    public var notebookId: Int64
    public var sessionId: Int64
    public var question: String
    public var mode: String
    public var scope: RetrievalScope
    public var providerId: String
    public var model: String
    public var providerConfigurationRevision: Int64
    public var runtimeContext: Int
    public var maxOutputTokens: Int
    public var evidenceBudgetCap: Int?
    public var fetchK: Int
    public var topK: Int
    public var notebookInstructions: String
    public var instructionsOverride: String?
    public var currentNoteContent: String?
    public var useWebSearch: Bool
    public var historyFingerprint: String
    public var scopeFingerprint: String
    public var regenerateUserId: Int64?
    public var replacesAssistantId: Int64?
    /// WP8 addition: an edit-and-resend replaces `regenerateUserId`'s text with
    /// `question` in the commit transaction; a plain regenerate never does.
    public var editUserText: Bool

    public init(notebookId: Int64, sessionId: Int64, question: String, mode: String, scope: RetrievalScope,
                providerId: String, model: String, providerConfigurationRevision: Int64,
                runtimeContext: Int, maxOutputTokens: Int, evidenceBudgetCap: Int?, fetchK: Int, topK: Int,
                notebookInstructions: String, instructionsOverride: String?, currentNoteContent: String?,
                useWebSearch: Bool, historyFingerprint: String, scopeFingerprint: String,
                regenerateUserId: Int64?, replacesAssistantId: Int64?, editUserText: Bool = false) {
        self.notebookId = notebookId
        self.sessionId = sessionId
        self.question = question
        self.mode = mode
        self.scope = scope
        self.providerId = providerId
        self.model = model
        self.providerConfigurationRevision = providerConfigurationRevision
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.evidenceBudgetCap = evidenceBudgetCap
        self.fetchK = fetchK
        self.topK = topK
        self.notebookInstructions = notebookInstructions
        self.instructionsOverride = instructionsOverride
        self.currentNoteContent = currentNoteContent
        self.useWebSearch = useWebSearch
        self.historyFingerprint = historyFingerprint
        self.scopeFingerprint = scopeFingerprint
        self.regenerateUserId = regenerateUserId
        self.replacesAssistantId = replacesAssistantId
        self.editUserText = editUserText
    }

    /// Existing precedence: a nonblank persona override replaces the notebook's instructions.
    public var effectiveInstructions: String {
        if let override = instructionsOverride,
           override.unicodeScalars.contains(where: { !ContextPackRendering.whitespace.contains($0) }) {
            return override
        }
        return notebookInstructions
    }
}

public enum PackIntentKey {
    /// SHA-256 of the canonical (sorted-key) intent JSON; the preimage is not retained.
    public static func make(_ intent: PackIntent) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings/integers/booleans cannot fail.
        let bytes = (try? encoder.encode(intent)) ?? Data()
        return Data(SHA256.hash(data: bytes))
    }
}

/// A pinned read: owns scope/revision/generation leases plus the materialized
/// scope, coverage and history input. `finish` releases every lease.
public protocol PackReadSession: Sendable {
    var input: ContextPackInput { get async }
    func search(question: String, fetchK: Int) async throws -> [PackHit]
    func hydrate(_ hits: [PackHit]) async throws -> [PackPassage]
    func overview() async throws -> [PackPassage]
    func neighbours(for passages: [PackPassage]) async throws -> [PackPassage]
    func finish() async
}

public protocol PackDataSource: Sendable {
    func pin(_ intent: PackIntent, model: PackModel) async throws -> any PackReadSession
}

/// A frozen provider endpoint/model/options. No credentials are observable.
public protocol PreparedPackTransport: Sendable {
    var model: PackModel { get }
    /// WP8 addition: the model key persisted on the assistant row (e.g.
    /// `providerId:model` for router sessions). Defaults to the raw model.
    var storageModel: String { get }
    func stream(_ request: PreparedContextRequest) -> AsyncThrowingStream<String, Error>
}

public extension PreparedPackTransport {
    var storageModel: String { model.model }
}

/// The current selection's identity and limits, resolved without freezing.
public struct PackTransportDescription: Equatable, Sendable {
    public let model: PackModel
    public let configurationRevision: Int64

    public init(model: PackModel, configurationRevision: Int64) {
        self.model = model
        self.configurationRevision = configurationRevision
    }
}

public protocol PackTransportFactory: Sendable {
    func freeze(_ intent: PackIntent) async throws -> any PreparedPackTransport
    /// WP8 addition: lets an intent be captured (and its key derived) from the
    /// live selection before anything is frozen. `requestedModel` uses the
    /// router's existing raw/provider-qualified override semantics.
    func describe(requestedModel: String?) async throws -> PackTransportDescription
}

public struct ResolvedCitationOriginal: Equatable, Sendable {
    public let decision: CitationOriginalDecision
    /// Present only for `available` / `changed`.
    public let url: URL?
    /// Note citations keep note navigation instead of a file URL.
    public let noteId: Int64?

    public init(decision: CitationOriginalDecision, url: URL? = nil, noteId: Int64? = nil) {
        self.decision = decision
        self.url = decision == .available || decision == .changed ? url : nil
        self.noteId = noteId
    }
}

public protocol CitationOriginalResolving: Sendable {
    func resolve(notebookId: Int64, citation: Citation) async throws -> ResolvedCitationOriginal
}

// MARK: - Prepared handle

/// Opaque, one-shot. Not serializable; the transport inside it owns the frozen provider session.
public final class PreparedPackHandle: Sendable {
    private actor Consumption {
        var consumed = false
        func take() -> Bool {
            guard !consumed else { return false }
            consumed = true
            return true
        }
    }

    public let intent: PackIntent
    public let key: Data
    public let request: PreparedContextRequest
    public let transport: any PreparedPackTransport
    private let consumption = Consumption()

    init(intent: PackIntent, key: Data, request: PreparedContextRequest, transport: any PreparedPackTransport) {
        self.intent = intent
        self.key = key
        self.request = request
        self.transport = transport
    }

    public var isConsumed: Bool { get async { await consumption.consumed } }

    /// Atomically marks the handle consumed; false when it already was.
    func consume() async -> Bool { await consumption.take() }

    /// The memory-only preview wrapper for this handle.
    public var snapshot: ContextPreviewSnapshot {
        ContextPreviewSnapshot(request: request, providerType: transport.model.providerType)
    }
}

// MARK: - Coordinator

/// Pins provider and retrieval state, collects evidence, and builds the exact
/// request a later send streams. Preparation never writes chat rows.
public struct ContextPackCoordinator: Sendable {
    public let data: any PackDataSource
    public let transports: any PackTransportFactory
    private let build: @Sendable (ContextPackInput) throws -> PreparedContextRequest

    public init(data: any PackDataSource, transports: any PackTransportFactory) {
        self.init(data: data, transports: transports, build: { try ContextPackBuilder.build($0) })
    }

    /// Test seam: substitutes the pure build (e.g. v1 goldens pin estimator v1 and tuning v1).
    init(data: any PackDataSource, transports: any PackTransportFactory,
         build: @escaping @Sendable (ContextPackInput) throws -> PreparedContextRequest) {
        self.data = data
        self.transports = transports
        self.build = build
    }

    public func describe(requestedModel: String?) async throws -> PackTransportDescription {
        try await transports.describe(requestedModel: requestedModel)
    }

    public func prepare(_ intent: PackIntent) async throws -> PreparedPackHandle {
        try Task.checkCancellation()
        let transport = try await transports.freeze(intent)
        let read = try await data.pin(intent, model: transport.model)
        do {
            // Retrieval uses only the current question; Overview and an empty
            // selection never embed it.
            var candidates: [PackPassage] = [], neighbours: [PackPassage] = [], overview: [PackPassage] = []
            if intent.scope.isEmptySelection {
                // Never widen an empty selection.
            } else if intent.mode == "overview" {
                overview = try await read.overview()
            } else {
                let hits = try await read.search(question: intent.question, fetchK: intent.fetchK)
                candidates = try await read.hydrate(hits)
                neighbours = try await read.neighbours(for: candidates)
            }
            try Task.checkCancellation()
            // The materialized input is read immediately before the pure build.
            let base = await read.input
            let input = intent.scope.isEmptySelection
                ? base.replacingEvidence(candidates: [], neighbours: [], overviewCandidates: [], folderMap: [])
                : base.replacingEvidence(candidates: candidates, neighbours: neighbours,
                                         overviewCandidates: overview, folderMap: base.folderMap)
            let request = try build(input)
            let handle = PreparedPackHandle(intent: intent, key: PackIntentKey.make(intent),
                                            request: request, transport: transport)
            await read.finish()
            return handle
        } catch {
            await read.finish()
            throw error
        }
    }
}

extension ContextPackInput {
    /// Copies every other field unchanged (including later optional fields such as `pathInventory`).
    func replacingEvidence(candidates: [PackPassage], neighbours: [PackPassage],
                           overviewCandidates: [PackPassage], folderMap: [PackFile]) -> ContextPackInput {
        var copy = self
        copy.candidates = candidates
        copy.neighbours = neighbours
        copy.overviewCandidates = overviewCandidates
        copy.folderMap = folderMap
        return copy
    }
}

// MARK: - History

public enum ContextHistory {
    /// Adjacent complete user→assistant exchanges ordered by persisted ID,
    /// oldest first. Trailing unanswered users and the regenerate/edit target
    /// pair are excluded; the turn ID is the user row's ID.
    public static func turns(_ messages: [ChatMessage], excludingUserId: Int64? = nil,
                             excludingAssistantId: Int64? = nil) -> [PackHistoryTurn] {
        let ordered = messages
            .filter { $0.id != nil && $0.role != .system && $0.id != excludingUserId && $0.id != excludingAssistantId }
            .sorted { $0.id! < $1.id! }
        var turns: [PackHistoryTurn] = []
        var index = 0
        while index + 1 < ordered.count {
            let user = ordered[index], assistant = ordered[index + 1]
            if user.role == .user && assistant.role == .assistant {
                turns.append(PackHistoryTurn(id: user.id!, user: user.content, assistant: assistant.content))
                index += 2
            } else {
                index += 1
            }
        }
        return turns
    }
}

// MARK: - Preview wrapper bytes

/// Memory-only `{providerType, request}` wrapper, canonical like the prepared request.
public enum ContextPreviewSnapshotJSON {
    public static func encode(_ snapshot: ContextPreviewSnapshot) throws -> Data {
        let object: NSDictionary = [
            "providerType": snapshot.providerType,
            "request": try PreparedContextRequestJSON.object(snapshot.request),
        ]
        return try PreparedContextRequestJSON.canonicalData(object)
    }

    public static func decode(_ bytes: Data) throws -> ContextPreviewSnapshot {
        try JSONDecoder().decode(ContextPreviewSnapshot.self, from: bytes)
    }
}
