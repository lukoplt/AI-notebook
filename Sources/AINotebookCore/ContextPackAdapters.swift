import Foundation
import CryptoKit

// MARK: - Provider transport (WP2)

/// Freezes the merged WP2 provider session (endpoint, model, limits, adapter)
/// per turn. A plain `ChatStreaming` without session preparation (legacy
/// direct clients and test doubles) receives the flattened logical turns with
/// the frozen model and the request's options.
public struct CompatibilityPackTransportFactory: PackTransportFactory {
    /// Provider ID recorded for clients without provider sessions.
    public static let directProviderId = "direct"

    private let chat: any ChatStreaming
    private let model: String
    private let store: NotebookStore?

    public init(chat: any ChatStreaming, model: String, store: NotebookStore? = nil) {
        self.chat = chat
        self.model = model
        self.store = store
    }

    public func describe(requestedModel: String?) async throws -> PackTransportDescription {
        try await capture(requestedModel).description
    }

    public func freeze(_ intent: PackIntent) async throws -> any PreparedPackTransport {
        let requested = intent.providerId == Self.directProviderId ? intent.model : intent.providerId + ":" + intent.model
        let captured = try await capture(requested)
        let frozen = captured.description
        // The intent was captured from an older selection or limits: the caller must recapture.
        guard frozen.model.providerId == intent.providerId, frozen.model.model == intent.model,
              frozen.model.runtimeContext == intent.runtimeContext,
              frozen.model.maxOutputTokens == intent.maxOutputTokens,
              frozen.configurationRevision == intent.providerConfigurationRevision else {
            throw ChatEngineError.stalePreparedRequest
        }
        return captured.transport
    }

    private struct Captured {
        let description: PackTransportDescription
        let transport: ProviderPackTransport
    }

    private func capture(_ requested: String?) async throws -> Captured {
        try Task.checkCancellation()
        if let preparer = chat as? any ChatSessionPreparing {
            let session = try await preparer.prepareChat(model: requested)
            let store = store
            let config = try store?.provider(id: session.providerId)
            let limits = session.limits
            let model = PackModel(providerId: session.providerId, model: session.model,
                                  runtimeContext: limits.runtimeContext, maxOutputTokens: limits.maxOutputTokens,
                                  contextWindowKnown: !limits.isAssumed,
                                  providerType: config?.type.rawValue ?? ProviderType.ollama.rawValue)
            return Captured(description: PackTransportDescription(model: model,
                                                                  configurationRevision: config.map(Self.revision) ?? 0),
                            transport: ProviderPackTransport(model: model, storageModel: session.storageKey,
                                                             session: session, chat: chat))
        }
        let name = requested ?? model
        let defaults = ChatRequestOptions.defaults
        let packModel = PackModel(providerId: Self.directProviderId, model: name,
                                  runtimeContext: defaults.runtimeContext, maxOutputTokens: defaults.maxOutputTokens,
                                  contextWindowKnown: false, providerType: ProviderType.ollama.rawValue)
        return Captured(description: PackTransportDescription(model: packModel, configurationRevision: 0),
                        transport: ProviderPackTransport(model: packModel, storageModel: name, session: nil, chat: chat))
    }

    /// A JSON-safe digest of the non-secret endpoint configuration.
    private static func revision(_ config: ProviderConfig) -> Int64 {
        let text = [config.id, config.type.rawValue, config.baseURL, config.enabled ? "1" : "0",
                    config.privacyAcknowledged ? "1" : "0"].joined(separator: "\u{0}")
        let digest = Array(SHA256.hash(data: Data(text.utf8)))
        return digest.prefix(6).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }
}

struct ProviderPackTransport: PreparedPackTransport {
    let model: PackModel
    let storageModel: String
    let session: ProviderChatSession?
    let chat: any ChatStreaming

    func stream(_ request: PreparedContextRequest) -> AsyncThrowingStream<String, Error> {
        let turns = ContextPackRendering.logicalTurns(request)
        if let session {
            // The frozen session's limits equal request.model (checked at freeze).
            return session.stream(messages: turns)
        }
        return chat.stream(model: model.model, messages: turns,
                           options: ChatRequestOptions(runtimeContext: request.model.runtimeContext,
                                                       maxOutputTokens: request.model.maxOutputTokens))
    }
}

// MARK: - Pinned data (WP5 retrieval + WP6 coverage/map)

/// Maps the merged WP5 scoped candidate pool and evidence hydrator plus the
/// WP6 coverage snapshot onto the pinned-read port. Answer mode embeds only
/// the current question; Overview pins the scope without embedding.
public struct CompatibilityPackDataSource: PackDataSource {
    private let store: NotebookStore
    private let retriever: Retriever
    private let webSearch: (any WebSearch)?

    public init(store: NotebookStore, retriever: Retriever, webSearch: (any WebSearch)? = nil) {
        self.store = store
        self.retriever = retriever
        self.webSearch = webSearch
    }

    private struct Materialized: Sendable {
        let history: [PackHistoryTurn]
        let notebookName: String
        let coverage: CoverageSnapshot
        let folders: [Int64: ContextFolderDetail]
        let instructions: String
    }

    public func pin(_ intent: PackIntent, model: PackModel) async throws -> any PackReadSession {
        try Task.checkCancellation()
        let store = store
        // Validation, history, coverage and folders come from ONE read snapshot,
        // read off the main actor (chat-during-scan-v1 §2).
        let read = try store.contextReadSnapshot(notebookId: intent.notebookId, sessionId: intent.sessionId,
                                                 scope: intent.scope, includeMaterialized: true)
        // Reject stale captures; never rebuild from a different state.
        guard read.historyFingerprint == intent.historyFingerprint, read.scopeFingerprint == intent.scopeFingerprint,
              read.notebookInstructions == intent.notebookInstructions
        else { throw ChatEngineError.stalePreparedRequest }
        let materialized = Materialized(
            history: ContextHistory.turns(read.messages, excludingUserId: intent.regenerateUserId,
                                          excludingAssistantId: intent.replacesAssistantId),
            notebookName: read.notebookName, coverage: read.coverage, folders: read.folders,
            instructions: intent.effectiveInstructions)

        var external: [PackExternal] = []
        if let note = intent.currentNoteContent,
           note.unicodeScalars.contains(where: { !ContextPackRendering.whitespace.contains($0) }) {
            external.append(PackExternal(id: "note", kind: "note", text: note, language: "und"))
        }
        if intent.useWebSearch, let webSearch {
            // Explicit opt-in only, once per prepare, through the existing provider service.
            let results = (try? await webSearch.search(query: intent.question, maxResults: 5)) ?? []
            try Task.checkCancellation()
            for (index, result) in results.enumerated() {
                external.append(PackExternal(id: "web:\(index + 1)", kind: "web",
                    text: "[W\(index + 1)] \(result.title)\n\(result.snippet)\n\(result.url)", language: "und"))
            }
        }

        var pool: PinnedRetrievalCandidates?
        if !intent.scope.isEmptySelection {
            pool = try await retriever.search(notebookId: intent.notebookId, query: intent.question, scope: intent.scope,
                                              fetchK: intent.fetchK, includeVectors: intent.mode != "overview")
        }
        do {
            let snapshot = pool?.snapshot
            let sources = snapshot?.sources ?? []
            let details = try store.contextSourceDetails(ids: sources.map(\.sourceId))
            let reader = store.makeRetrievalReader()
            let input = Self.input(intent: intent, model: model, materialized: materialized, external: external,
                                   snapshot: snapshot, details: details, pathMatches: pool?.pathMatches ?? [],
                                   pathInventory: pool?.pathInventory ?? false)
            return CompatibilityPackReadSession(store: store, reader: reader, pool: pool, input: input, details: details)
        } catch {
            await pool?.close()
            throw error
        }
    }

    private static func input(intent: PackIntent, model: PackModel, materialized: Materialized,
                              external: [PackExternal], snapshot: ResolvedRetrievalScope?,
                              details: [Int64: ContextSourceDetail], pathMatches: [PathMatch] = [],
                              pathInventory: Bool = false) -> ContextPackInput {
        let pathRanks = Dictionary(pathMatches.enumerated().map { ($1.sourceId, (rank: $0 + 1, date: $1.date, project: $1.project)) },
                                   uniquingKeysWith: { first, _ in first })
        let sources = snapshot?.sources ?? []
        let published = sources.filter { $0.publishedRevisionId != nil }
        let questionTokens = Set(intent.question.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.unicodeScalars.count >= 3 })
        let folderMap = published.map { source -> PackFile in
            let label = ContextPackLabels.identity(source: source, detail: details[source.sourceId])
            let haystack = (label.relPath + "\n" + (details[source.sourceId]?.title ?? "")).lowercased()
            return PackFile(sourceId: source.sourceId, folderId: source.folderId, relPath: label.relPath,
                            displayName: label.displayName,
                            descriptor: ContextPackLabels.descriptor(details[source.sourceId]),
                            metadataMatch: questionTokens.contains { haystack.contains($0) },
                            publishedRevisionId: source.publishedRevisionId,
                            pathRank: pathRanks[source.sourceId]?.rank,
                            matchDate: pathRanks[source.sourceId].flatMap { $0.date == 0 ? nil : $0.date },
                            matchProject: pathRanks[source.sourceId]?.project)
        }

        let pinnedFiles = Set(sources.filter { $0.publishedRevisionId != nil || $0.vectorRevisionId != nil }.map(\.sourceId)).count
        let coverage = PackCorpusCoverage.normalized(materialized.coverage, pinnedFiles: pinnedFiles)

        let scope = ContextPackLabels.scope(intent.scope, notebookName: materialized.notebookName,
                                            folders: materialized.folders, sources: sources, details: details)
        var revisions: [String: Int64] = [:]
        for source in published { revisions[String(source.sourceId)] = source.publishedRevisionId! }
        return ContextPackInput(question: intent.question, mode: intent.mode,
                                userInstructions: materialized.instructions, history: materialized.history,
                                external: external, candidates: [], neighbours: [], overviewCandidates: [],
                                folderMap: folderMap, scope: scope, coverage: coverage, model: model,
                                generationId: snapshot?.generation?.id, sourceRevisions: revisions,
                                evidenceBudgetCap: intent.evidenceBudgetCap, fetchK: intent.fetchK, topK: intent.topK,
                                pathInventory: pathInventory && !pathMatches.isEmpty ? true : nil)
    }
}

/// Owns the candidate pool (and with it the WP3 query pin) until `finish`.
actor CompatibilityPackReadSession: PackReadSession {
    private let store: NotebookStore
    private let reader: RetrievalReadStore
    private let pool: PinnedRetrievalCandidates?
    private let details: [Int64: ContextSourceDetail]
    private let materialized: ContextPackInput
    private var stashedNeighbours: [PackPassage] = []
    private var finished = false

    init(store: NotebookStore, reader: RetrievalReadStore, pool: PinnedRetrievalCandidates?,
         input: ContextPackInput, details: [Int64: ContextSourceDetail]) {
        self.store = store
        self.reader = reader
        self.pool = pool
        self.materialized = input
        self.details = details
    }

    var input: ContextPackInput { materialized }

    /// The pool was ranked for the intent's question at pin time; this returns its fused order.
    func search(question: String, fetchK: Int) async throws -> [PackHit] {
        guard let pool, question == materialized.question, fetchK == materialized.fetchK else {
            if pool == nil { return [] }
            throw ContextPackError.invalidInput
        }
        return pool.fused.map { PackHit(chunkId: $0.reference.chunkId, sourceId: $0.reference.sourceId,
                                        revisionId: $0.reference.revisionId, rrfMicro: $0.rrfMicro) }
    }

    /// Hydrates each hit at its own revision; published neighbours (radius 1)
    /// are copied in the same pinned borrow and returned by `neighbours(for:)`.
    func hydrate(_ hits: [PackHit]) async throws -> [PackPassage] {
        guard let pool, let snapshot = pool.snapshot, !hits.isEmpty else { return [] }
        let references = Dictionary(pool.fused.map { ($0.reference.chunkId, $0.reference) }, uniquingKeysWith: { a, _ in a })
        let rrf = Dictionary(hits.map { ($0.chunkId, $0.rrfMicro) }, uniquingKeysWith: { a, _ in a })
        let requested = hits.compactMap { references[$0.chunkId] }
        let passages = try await EvidenceHydrator(reader: reader).hydrate(snapshot, references: requested,
            neighborRadius: RagContractV1.Pack.neighborRadius)
        let store = store
        let languages = try store.contextChunkLanguages(chunkIds: passages.map(\.reference.chunkId))
        let mapped = passages.map { passage in
            pack(passage, rrfMicro: passage.isNeighbour ? 0 : rrf[passage.reference.chunkId] ?? 0, languages: languages,
                 snapshot: snapshot)
        }
        stashedNeighbours = zip(passages, mapped).filter { $0.0.isNeighbour }.map(\.1)
        return zip(passages, mapped).filter { !$0.0.isNeighbour }.map(\.1)
    }

    func neighbours(for passages: [PackPassage]) async throws -> [PackPassage] {
        let sources = Set(passages.map(\.sourceId))
        return stashedNeighbours.filter { sources.contains($0.sourceId) }
    }

    /// First chunk of the published revision of every scoped eligible file.
    func overview() async throws -> [PackPassage] {
        guard let snapshot = pool?.snapshot else { return [] }
        var revisions: [Int64: Int64] = [:]
        for source in snapshot.sources { if let published = source.publishedRevisionId { revisions[source.sourceId] = published } }
        let store = store
        let references = try store.contextFirstChunks(revisions: revisions)
        let passages = try await EvidenceHydrator(reader: reader).hydrate(snapshot, references: references, neighborRadius: 0)
        let languages = try store.contextChunkLanguages(chunkIds: passages.map(\.reference.chunkId))
        return passages.filter { $0.reference.ord == 0 }
            .map { pack($0, rrfMicro: 0, languages: languages, snapshot: snapshot) }
    }

    func finish() async {
        guard !finished else { return }
        finished = true
        await pool?.close()
    }

    private func pack(_ passage: EvidencePassage, rrfMicro: Int64, languages: [Int64: String],
                      snapshot: ResolvedRetrievalScope) -> PackPassage {
        let reference = passage.reference
        let source = snapshot.sources.first { $0.sourceId == reference.sourceId }
        let label = source.map { ContextPackLabels.identity(source: $0, detail: details[reference.sourceId]) }
            ?? (relPath: "source-\(reference.sourceId)", displayName: "source-\(reference.sourceId)")
        let span = passage.spans.first
        let language = ContextPackLabels.language(languages[reference.chunkId] ?? details[reference.sourceId]?.lang)
        return PackPassage(chunkId: reference.chunkId, sourceId: reference.sourceId, revisionId: reference.revisionId,
                           folderId: source?.folderId, relPath: label.relPath, displayName: label.displayName,
                           language: language, text: passage.text, ordinal: reference.ord,
                           start: span?.start, end: span?.end, pageFrom: span?.pageFrom, pageTo: span?.pageTo,
                           rrfMicro: rrfMicro, truncationCandidates: [])
    }
}

extension PackCorpusCoverage {
    /// The builder's coverage invariants (`searchable + pending + error == filesInScope`,
    /// `refreshPending + refreshError <= filesInScope`, every pinned file counted) hold
    /// for ANY store snapshot (chat-during-scan-v1 §2). Coverage is read in its own
    /// snapshot, before the retrieval pin; a folder check, extraction or rule change
    /// in between can only make it disagree with the pin, never fail the turn: a
    /// shortfall against the pinned files counts as searchable, negative counts read
    /// as zero, and refresh counts are clamped to the files in scope.
    static func normalized(_ c: CoverageSnapshot, pinnedFiles: Int) -> PackCorpusCoverage {
        let searchable = max(0, c.searchable), pending = max(0, c.pending), error = max(0, c.error)
        let shortfall = max(0, pinnedFiles - (searchable + pending + error))
        let filesInScope = searchable + pending + error + shortfall
        let refreshPending = min(max(0, c.refreshPending), filesInScope)
        return PackCorpusCoverage(filesInScope: filesInScope, searchable: searchable + shortfall,
                                  pending: pending, error: error, skipped: max(0, c.skipped), missing: max(0, c.missing),
                                  unavailable: max(0, c.unavailable), refreshPending: refreshPending,
                                  refreshError: min(max(0, c.refreshError), filesInScope - refreshPending),
                                  partial: c.isLowerBound)
    }
}

/// Model-facing labels. Folder identity is `(folderId, relPath)`; roots and
/// raw paths never enter a request.
enum ContextPackLabels {
    static let languages: Set<String> = ["en", "cs", "sk", "de", "und", "mixed"]

    static func language(_ value: String?) -> String {
        guard let value, languages.contains(value) else { return "und" }
        return value
    }

    /// A display label with no path, drive or control syntax.
    static func label(_ text: String, fallback: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let forbidden = scalar == "/" || scalar == "\\" || scalar == ":" || scalar.value < 32 || (127...159).contains(scalar.value)
            scalars.append(forbidden ? "_" : scalar)
        }
        let value = String(scalars).trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "." || value == ".." ? fallback : value
    }

    static func validRelative(_ path: String) -> Bool {
        let parts = path.unicodeScalars.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.unicodeScalars.contains(where: {
            $0 == "\\" || $0 == ":" || $0.value < 32 || (127...159).contains($0.value)
        }) && parts.allSatisfy { !$0.isEmpty && String($0) != "." && String($0) != ".." }
    }

    static func identity(source: ScopedSource, detail: ContextSourceDetail?) -> (relPath: String, displayName: String) {
        let fallback = "source-\(source.sourceId)"
        if source.folderId != nil, let rel = source.relPath, validRelative(rel) {
            let base = rel.split(separator: "/").last.map(String.init) ?? rel
            return (rel, label(base, fallback: fallback))
        }
        let name = label(detail?.title ?? source.displayName, fallback: fallback)
        return (name, name)
    }

    /// Map descriptors use the published descriptor's title, type and size, on
    /// one line; sources without one fall back to their type. The value is raw:
    /// the renderer is the only place that escapes it (context-pack-v1).
    static func descriptor(_ detail: ContextSourceDetail?) -> String {
        guard let detail else { return "" }
        guard let json = detail.descriptor, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return detail.type.rawValue }
        var parts: [String] = []
        if let title = object["title"] as? String, !title.isEmpty { parts.append(title) }
        if let type = object["type"] as? String, !type.isEmpty { parts.append(type) }
        if let pages = object["pageCount"] as? Int, pages > 0 { parts.append("\(pages) p.") }
        if let sheets = object["sheetCount"] as? Int, sheets > 0 { parts.append("\(sheets) sheets") }
        return parts.joined(separator: " · ")
    }

    static func scope(_ scope: RetrievalScope, notebookName: String, folders: [Int64: ContextFolderDetail],
                      sources: [ScopedSource], details: [Int64: ContextSourceDetail]) -> PackScopeSnapshot {
        let kind: String, sourceIds: [Int64], folderIds: [Int64], name: String
        switch scope {
        case .all:
            kind = "all"; sourceIds = []; folderIds = []; name = notebookName
        case let .selection(s, f):
            kind = "selection"; sourceIds = s.sorted(); folderIds = f.sorted()
            if s.isEmpty, f.count == 1, let folder = folders[f.first!] { name = folder.displayName }
            else { name = "\(notebookName) (selection)" }
        }
        let involved: [ContextFolderDetail]
        switch scope {
        case .all: involved = Array(folders.values)
        case let .selection(_, f):
            let ids = Set(f).union(sources.compactMap(\.folderId))
            involved = ids.compactMap { folders[$0] }
        }
        let state: String
        let states = Set(involved.map(\.scanState))
        if let first = ["scanning", "partial", "error", "unavailable"].first(where: states.contains) { state = first }
        else { state = "idle" }
        var lastFullScan: String?
        if !involved.isEmpty, involved.allSatisfy({ $0.lastFullScanAt != nil }) {
            let oldest = involved.map { $0.lastFullScanAt! }.min()!
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            formatter.timeZone = TimeZone(identifier: "UTC")
            lastFullScan = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(oldest)))
        }
        let languages = Set(sources.filter { $0.publishedRevisionId != nil }
            .compactMap { details[$0.sourceId]?.lang }.filter(Self.languages.contains))
        return PackScopeSnapshot(kind: kind, name: name, sourceIds: sourceIds, folderIds: folderIds,
                                 languages: languages.sorted(), lastFullScan: lastFullScan, scanState: state)
    }
}

// MARK: - Native original resolver (WP6 containment)

/// Revalidates the live source, folder root and physical containment on
/// every click, then asks `CitationOriginalPolicy`. Never opens a file.
public struct NativeCitationOriginalResolver: CitationOriginalResolving {
    private let store: NotebookStore
    private let fileSystem: NativeFolderFileSystem

    public init(store: NotebookStore, fileSystem: NativeFolderFileSystem = NativeFolderFileSystem()) {
        self.store = store
        self.fileSystem = fileSystem
    }

    public func resolve(notebookId: Int64, citation: Citation) async throws -> ResolvedCitationOriginal {
        let store = store
        guard let record = try store.contextOriginal(notebookId: notebookId, sourceId: citation.sourceId)
        else { return ResolvedCitationOriginal(decision: .unavailable) }
        if record.source.type == .note {
            return ResolvedCitationOriginal(decision: record.noteId == nil ? .unavailable : .available, noteId: record.noteId)
        }
        if citation.folderId != nil || record.source.folderId != nil {
            return evaluateFolder(record, citation: citation)
        }
        return evaluateLoose(record, citation: citation)
    }

    private func evaluateFolder(_ record: ContextOriginalRecord, citation: Citation) -> ResolvedCitationOriginal {
        // Folder citations never fall back to rawPath.
        let relPath = citation.relPath ?? record.source.relPath ?? ""
        var input = CitationOriginalInput(relativePath: relPath, rootComponents: [], resolvedComponents: [],
                                          caseSensitive: true, exists: false, isRegularFile: false,
                                          sourceExists: true, currentRevisionId: record.currentRevisionId,
                                          citedRevisionId: citation.revisionId)
        // Syntax first: a traversal path is unsafe even if the source is gone.
        guard CitationOriginalPolicy.evaluate(input) != .unsafe else { return ResolvedCitationOriginal(decision: .unsafe) }
        guard let folder = record.folder, citation.folderId == nil || citation.folderId == folder.id,
              let live = record.source.relPath, live.utf8.elementsEqual(relPath.utf8) else {
            return ResolvedCitationOriginal(decision: .unavailable)
        }
        let root = folder.identity.components
        let opened: FolderIdentity
        do { opened = try fileSystem.resolve(rootPath: folder.draft.rootPath) } catch {
            return ResolvedCitationOriginal(decision: .unavailable)
        }
        guard opened == folder.identity else { return ResolvedCitationOriginal(decision: .unavailable) }
        do {
            // Descriptor walk: interior/leaf links and escapes fail here.
            _ = try fileSystem.stat(root: folder, relativePath: relPath)
        } catch let error as IngestionError where ["outsideRoot", "interiorLink", "rootIdentityChanged"].contains(error.code) {
            return ResolvedCitationOriginal(decision: error.code == "rootIdentityChanged" ? .unavailable : .unsafe)
        } catch {
            return ResolvedCitationOriginal(decision: .unavailable)
        }
        let selected = folder.draft.rootPath.hasSuffix("/") ? folder.draft.rootPath : folder.draft.rootPath + "/"
        guard let physical = Self.realPath(selected + relPath) else { return ResolvedCitationOriginal(decision: .unavailable) }
        let values = try? URL(fileURLWithPath: physical).resourceValues(forKeys: [.isRegularFileKey])
        input.rootComponents = root
        input.resolvedComponents = Self.components(physical)
        input.caseSensitive = (try? fileSystem.caseSensitive(root: folder)) ?? true
        input.exists = values != nil
        input.isRegularFile = values?.isRegularFile == true
        let decision = CitationOriginalPolicy.evaluate(input)
        return ResolvedCitationOriginal(decision: decision, url: URL(fileURLWithPath: physical))
    }

    /// Loose legacy files use the live source's trusted stored location.
    private func evaluateLoose(_ record: ContextOriginalRecord, citation: Citation) -> ResolvedCitationOriginal {
        guard let raw = record.rawPath, raw.hasPrefix("/"), !raw.utf8.contains(0) else {
            return ResolvedCitationOriginal(decision: .unavailable)
        }
        let stored = URL(fileURLWithPath: raw)
        guard let parent = Self.realPath(stored.deletingLastPathComponent().path),
              let physical = Self.realPath(raw) else { return ResolvedCitationOriginal(decision: .unavailable) }
        let values = try? URL(fileURLWithPath: physical).resourceValues(forKeys: [.isRegularFileKey])
        let input = CitationOriginalInput(relativePath: stored.lastPathComponent,
                                          rootComponents: Self.components(parent),
                                          resolvedComponents: Self.components(physical),
                                          caseSensitive: true, exists: values != nil,
                                          isRegularFile: values?.isRegularFile == true, sourceExists: true,
                                          currentRevisionId: record.currentRevisionId, citedRevisionId: citation.revisionId)
        return ResolvedCitationOriginal(decision: CitationOriginalPolicy.evaluate(input), url: URL(fileURLWithPath: physical))
    }

    /// realpath(3): unlike Foundation's symlink resolution it never strips `/private`.
    private static func realPath(_ path: String) -> String? {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }
}
