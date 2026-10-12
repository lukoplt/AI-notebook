import Foundation

public enum ContextPackError: String, Error, Sendable {
    case invalidInput
    case contextTooSmall
}

public struct PackModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var model: String
    public var runtimeContext: Int
    public var maxOutputTokens: Int
    public var contextWindowKnown: Bool
    public var providerType: String

    public init(providerId: String, model: String, runtimeContext: Int, maxOutputTokens: Int,
                contextWindowKnown: Bool, providerType: String) {
        self.providerId = providerId
        self.model = model
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowKnown = contextWindowKnown
        self.providerType = providerType
    }
}

public struct PreparedPackModel: Codable, Equatable, Sendable {
    public var providerId: String
    public var model: String
    public var runtimeContext: Int
    public var maxOutputTokens: Int
    public var contextWindowKnown: Bool

    public init(providerId: String, model: String, runtimeContext: Int, maxOutputTokens: Int,
                contextWindowKnown: Bool) {
        self.providerId = providerId
        self.model = model
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.contextWindowKnown = contextWindowKnown
    }
}

/// Session-only provider information is deliberately outside prepared-request JSON.
public struct ContextPreviewSnapshot: Codable, Equatable, Sendable {
    public var request: PreparedContextRequest
    public var providerType: String

    public init(request: PreparedContextRequest, providerType: String) {
        self.request = request
        self.providerType = providerType
    }
}

public struct PackScopeSnapshot: Codable, Equatable, Sendable {
    public var kind: String
    public var name: String
    public var sourceIds: [Int64]
    public var folderIds: [Int64]
    public var languages: [String]
    public var lastFullScan: String?
    public var scanState: String

    public init(kind: String, name: String, sourceIds: [Int64], folderIds: [Int64],
                languages: [String], lastFullScan: String? = nil, scanState: String) {
        self.kind = kind
        self.name = name
        self.sourceIds = sourceIds
        self.folderIds = folderIds
        self.languages = languages
        self.lastFullScan = lastFullScan
        self.scanState = scanState
    }
}

public struct PackCorpusCoverage: Codable, Equatable, Sendable {
    public var filesInScope: Int
    public var searchable: Int
    public var pending: Int
    public var error: Int
    public var skipped: Int
    public var missing: Int
    public var unavailable: Int
    public var refreshPending: Int
    public var refreshError: Int
    public var partial: Bool

    public init(filesInScope: Int, searchable: Int, pending: Int, error: Int, skipped: Int,
                missing: Int, unavailable: Int, refreshPending: Int, refreshError: Int, partial: Bool) {
        self.filesInScope = filesInScope
        self.searchable = searchable
        self.pending = pending
        self.error = error
        self.skipped = skipped
        self.missing = missing
        self.unavailable = unavailable
        self.refreshPending = refreshPending
        self.refreshError = refreshError
        self.partial = partial
    }
}

public struct PackTurnCoverage: Codable, Equatable, Sendable {
    public var passages: Int
    public var filesIncluded: Int
    public var candidatesWithPublishedChunks: Int
    public var overview: Bool

    public init(passages: Int, filesIncluded: Int, candidatesWithPublishedChunks: Int, overview: Bool) {
        self.passages = passages
        self.filesIncluded = filesIncluded
        self.candidatesWithPublishedChunks = candidatesWithPublishedChunks
        self.overview = overview
    }
}

public struct PackHistoryTurn: Codable, Equatable, Sendable {
    public var id: Int64
    public var user: String
    public var assistant: String

    public init(id: Int64, user: String, assistant: String) {
        self.id = id
        self.user = user
        self.assistant = assistant
    }
}

public struct PackExternal: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var text: String
    public var language: String

    public init(id: String, kind: String, text: String, language: String) {
        self.id = id
        self.kind = kind
        self.text = text
        self.language = language
    }
}

/// Hydrated evidence uses absolute scalar ends; legacy text uses text-relative ends.
public struct PackPrefix: Codable, Equatable, Sendable {
    public var end: Int
    public var tokens: Int

    public init(end: Int, tokens: Int) {
        self.end = end
        self.tokens = tokens
    }
}

public struct PackPassage: Codable, Equatable, Sendable {
    public var chunkId: Int64
    public var sourceId: Int64
    public var revisionId: Int64
    public var folderId: Int64?
    public var relPath: String
    public var displayName: String
    public var language: String
    public var text: String
    public var ordinal: Int
    public var start: Int?
    public var end: Int?
    public var pageFrom: Int?
    public var pageTo: Int?
    public var rrfMicro: Int64
    public var truncationCandidates: [PackPrefix]

    public init(chunkId: Int64, sourceId: Int64, revisionId: Int64, folderId: Int64? = nil,
                relPath: String, displayName: String, language: String, text: String, ordinal: Int,
                start: Int? = nil, end: Int? = nil, pageFrom: Int? = nil, pageTo: Int? = nil,
                rrfMicro: Int64, truncationCandidates: [PackPrefix]) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.revisionId = revisionId
        self.folderId = folderId
        self.relPath = relPath
        self.displayName = displayName
        self.language = language
        self.text = text
        self.ordinal = ordinal
        self.start = start
        self.end = end
        self.pageFrom = pageFrom
        self.pageTo = pageTo
        self.rrfMicro = rrfMicro
        self.truncationCandidates = truncationCandidates
    }
}

public struct PackFile: Codable, Equatable, Sendable {
    public var sourceId: Int64
    public var folderId: Int64?
    public var relPath: String
    public var displayName: String
    public var descriptor: String
    public var metadataMatch: Bool
    public var publishedRevisionId: Int64?
    /// 1-based rank among the question's path matches (retrieval-paths-v1), nil when unmatched.
    public var pathRank: Int?
    /// YYYYMMDD of a path match, when known.
    public var matchDate: Int?
    /// retrieval-paths v2 (§6): the match's project directory, grouping inventory answers.
    public var matchProject: String?

    public init(sourceId: Int64, folderId: Int64? = nil, relPath: String, displayName: String,
                descriptor: String, metadataMatch: Bool, publishedRevisionId: Int64? = nil,
                pathRank: Int? = nil, matchDate: Int? = nil, matchProject: String? = nil) {
        self.sourceId = sourceId
        self.folderId = folderId
        self.relPath = relPath
        self.displayName = displayName
        self.descriptor = descriptor
        self.metadataMatch = metadataMatch
        self.publishedRevisionId = publishedRevisionId
        self.pathRank = pathRank
        self.matchDate = matchDate
        self.matchProject = matchProject
    }
}

public struct ContextPackInput: Codable, Equatable, Sendable {
    public var question: String
    public var mode: String
    public var userInstructions: String
    public var history: [PackHistoryTurn]
    public var external: [PackExternal]
    public var candidates: [PackPassage]
    public var neighbours: [PackPassage]
    public var overviewCandidates: [PackPassage]
    public var folderMap: [PackFile]
    public var scope: PackScopeSnapshot
    public var coverage: PackCorpusCoverage
    public var model: PackModel
    public var generationId: Int64?
    /// Published revisions pinned before retrieval, used to authorize neighbours.
    public var sourceRevisions: [String: Int64]
    public var evidenceBudgetCap: Int?
    public var fetchK: Int
    public var topK: Int
    /// retrieval-paths v2 (§6): the question is an inventory question; omitted from JSON unless true.
    public var pathInventory: Bool?

    public init(question: String, mode: String, userInstructions: String,
                history: [PackHistoryTurn], external: [PackExternal], candidates: [PackPassage],
                neighbours: [PackPassage], overviewCandidates: [PackPassage], folderMap: [PackFile],
                scope: PackScopeSnapshot, coverage: PackCorpusCoverage, model: PackModel,
                generationId: Int64? = nil, sourceRevisions: [String: Int64],
                evidenceBudgetCap: Int? = nil, fetchK: Int, topK: Int, pathInventory: Bool? = nil) {
        self.question = question
        self.mode = mode
        self.userInstructions = userInstructions
        self.history = history
        self.external = external
        self.candidates = candidates
        self.neighbours = neighbours
        self.overviewCandidates = overviewCandidates
        self.folderMap = folderMap
        self.scope = scope
        self.coverage = coverage
        self.model = model
        self.generationId = generationId
        self.sourceRevisions = sourceRevisions
        self.evidenceBudgetCap = evidenceBudgetCap
        self.fetchK = fetchK
        self.topK = topK
        self.pathInventory = pathInventory
    }

    private enum CodingKeys: String, CodingKey {
        case question, mode, userInstructions, history, external, candidates, neighbours
        case overviewCandidates, folderMap, scope, coverage, model, generationId, sourceRevisions
        case evidenceBudgetCap, fetchK, topK, pathInventory
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(question, forKey: .question)
        try c.encode(mode, forKey: .mode)
        try c.encode(userInstructions, forKey: .userInstructions)
        try c.encode(history, forKey: .history)
        try c.encode(external, forKey: .external)
        try c.encode(candidates, forKey: .candidates)
        try c.encode(neighbours, forKey: .neighbours)
        try c.encode(overviewCandidates, forKey: .overviewCandidates)
        try c.encode(folderMap, forKey: .folderMap)
        try c.encode(scope, forKey: .scope)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(model, forKey: .model)
        try c.encode(generationId, forKey: .generationId)
        try c.encode(sourceRevisions, forKey: .sourceRevisions)
        try c.encodeIfPresent(evidenceBudgetCap, forKey: .evidenceBudgetCap)
        try c.encode(fetchK, forKey: .fetchK)
        try c.encode(topK, forKey: .topK)
        if pathInventory == true { try c.encode(true, forKey: .pathInventory) }
    }
}

public struct PackSection: Codable, Equatable, Sendable {
    public var kind: String
    public var text: String
    public var tokens: Int

    public init(kind: String, text: String, tokens: Int) {
        self.kind = kind
        self.text = text
        self.tokens = tokens
    }
}

public struct PackMessage: Codable, Equatable, Sendable {
    public var role: String
    public var sections: [PackSection]

    public init(role: String, sections: [PackSection]) {
        self.role = role
        self.sections = sections
    }
}

public struct PackItem: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String

    public init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

public struct PackOmission: Codable, Equatable, Sendable {
    public var kind: String
    public var id: String
    public var reason: String

    public init(kind: String, id: String, reason: String) {
        self.kind = kind
        self.id = id
        self.reason = reason
    }
}

public struct PackOptions: Codable, Equatable, Sendable {
    public var numCtx: Int?
    public var maxTokens: Int?

    public init(numCtx: Int? = nil, maxTokens: Int? = nil) {
        self.numCtx = numCtx
        self.maxTokens = maxTokens
    }
}

public struct PackCoverage: Codable, Equatable, Sendable {
    public var corpus: PackCorpusCoverage
    public var turn: PackTurnCoverage

    public init(corpus: PackCorpusCoverage, turn: PackTurnCoverage) {
        self.corpus = corpus
        self.turn = turn
    }
}

/// Multiple revisions of a source can be retained by one prepared request.
public struct PackSourceRevision: Codable, Equatable, Hashable, Sendable {
    public var sourceId: Int64
    public var revisionId: Int64

    public init(sourceId: Int64, revisionId: Int64) {
        self.sourceId = sourceId
        self.revisionId = revisionId
    }
}

public struct PreparedContextRequest: Codable, Equatable, Sendable {
    public var estimatorVersion: Int
    public var model: PreparedPackModel
    public var messages: [PackMessage]
    public var options: PackOptions
    public var citationMap: [Citation]
    public var included: [PackItem]
    public var omitted: [PackOmission]
    public var coverage: PackCoverage
    public var generationId: Int64?
    public var sourceRevisions: [PackSourceRevision]

    public init(estimatorVersion: Int, model: PreparedPackModel, messages: [PackMessage],
                options: PackOptions, citationMap: [Citation], included: [PackItem],
                omitted: [PackOmission], coverage: PackCoverage, generationId: Int64? = nil,
                sourceRevisions: [PackSourceRevision]) {
        self.estimatorVersion = estimatorVersion
        self.model = model
        self.messages = messages
        self.options = options
        self.citationMap = citationMap
        self.included = included
        self.omitted = omitted
        self.coverage = coverage
        self.generationId = generationId
        self.sourceRevisions = sourceRevisions
    }

    private enum CodingKeys: String, CodingKey {
        case estimatorVersion, model, messages, options, citationMap, included, omitted
        case coverage, generationId, sourceRevisions
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(estimatorVersion, forKey: .estimatorVersion)
        try c.encode(model, forKey: .model)
        try c.encode(messages, forKey: .messages)
        try c.encode(options, forKey: .options)
        try c.encode(citationMap, forKey: .citationMap)
        try c.encode(included, forKey: .included)
        try c.encode(omitted, forKey: .omitted)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(generationId, forKey: .generationId)
        try c.encode(sourceRevisions, forKey: .sourceRevisions)
    }
}

/// Budget-kernel ends are relative to the beginning of the passage (§8).
public struct PackBudgetPrefix: Codable, Equatable, Sendable {
    public var endScalar: Int
    public var tokens: Int

    public init(endScalar: Int, tokens: Int) {
        self.endScalar = endScalar
        self.tokens = tokens
    }
}

public struct PackBudgetPassage: Codable, Equatable, Sendable {
    public var id: Int64
    public var tokens: Int
    public var truncationCandidates: [PackBudgetPrefix]

    public init(id: Int64, tokens: Int, truncationCandidates: [PackBudgetPrefix] = []) {
        self.id = id
        self.tokens = tokens
        self.truncationCandidates = truncationCandidates
    }

    private enum CodingKeys: String, CodingKey {
        case id, tokens, truncationCandidates
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        tokens = try c.decode(Int.self, forKey: .tokens)
        truncationCandidates = try c.decodeIfPresent([PackBudgetPrefix].self, forKey: .truncationCandidates) ?? []
    }
}

public struct PackBudgetInput: Codable, Equatable, Sendable {
    public var runtimeContext: Int
    public var maxOutputTokens: Int
    public var mandatoryTokens: Int
    public var evidenceBudgetCap: Int?
    public var topK: Int
    public var passages: [PackBudgetPassage]
    public var mapTokensDesired: Int
    public var noteWebTokensDesired: Int
    public var historyTurnTokensNewestFirst: [Int]
    /// retrieval-paths v2 (§6, inventory questions only): the rendered map's own ceiling and the
    /// evidence target's upper bound. Absent, the budget is exactly folder-rag-v1 §8.
    public var mapCeilingTokens: Int?
    public var evidenceCeilingTokens: Int?

    public init(runtimeContext: Int, maxOutputTokens: Int, mandatoryTokens: Int,
                evidenceBudgetCap: Int? = nil, topK: Int, passages: [PackBudgetPassage],
                mapTokensDesired: Int, noteWebTokensDesired: Int, historyTurnTokensNewestFirst: [Int],
                mapCeilingTokens: Int? = nil, evidenceCeilingTokens: Int? = nil) {
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.mandatoryTokens = mandatoryTokens
        self.evidenceBudgetCap = evidenceBudgetCap
        self.topK = topK
        self.passages = passages
        self.mapTokensDesired = mapTokensDesired
        self.noteWebTokensDesired = noteWebTokensDesired
        self.historyTurnTokensNewestFirst = historyTurnTokensNewestFirst
        self.mapCeilingTokens = mapCeilingTokens
        self.evidenceCeilingTokens = evidenceCeilingTokens
    }
}

public struct PackBudgetResult: Codable, Equatable, Sendable {
    public var remainder: Int
    public var evidenceTarget: Int
    public var includedPassageIds: [Int64]
    public var truncatedPassageId: Int64?
    public var truncatedPassageEndScalar: Int?
    public var truncatedPassageTokens: Int?
    public var evidenceTokens: Int
    public var mapTokens: Int
    public var noteWebTokens: Int
    public var historyTurnsIncluded: Int
    public var historyTokens: Int
    public var unusedTokens: Int

    public init(remainder: Int, evidenceTarget: Int, includedPassageIds: [Int64],
                truncatedPassageId: Int64?, truncatedPassageEndScalar: Int?, truncatedPassageTokens: Int?,
                evidenceTokens: Int, mapTokens: Int, noteWebTokens: Int,
                historyTurnsIncluded: Int, historyTokens: Int, unusedTokens: Int) {
        self.remainder = remainder
        self.evidenceTarget = evidenceTarget
        self.includedPassageIds = includedPassageIds
        self.truncatedPassageId = truncatedPassageId
        self.truncatedPassageEndScalar = truncatedPassageEndScalar
        self.truncatedPassageTokens = truncatedPassageTokens
        self.evidenceTokens = evidenceTokens
        self.mapTokens = mapTokens
        self.noteWebTokens = noteWebTokens
        self.historyTurnsIncluded = historyTurnsIncluded
        self.historyTokens = historyTokens
        self.unusedTokens = unusedTokens
    }

    private enum CodingKeys: String, CodingKey {
        case remainder, evidenceTarget, includedPassageIds, truncatedPassageId
        case truncatedPassageEndScalar, truncatedPassageTokens, evidenceTokens, mapTokens
        case noteWebTokens, historyTurnsIncluded, historyTokens, unusedTokens
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(remainder, forKey: .remainder)
        try c.encode(evidenceTarget, forKey: .evidenceTarget)
        try c.encode(includedPassageIds, forKey: .includedPassageIds)
        try c.encode(truncatedPassageId, forKey: .truncatedPassageId)
        try c.encode(truncatedPassageEndScalar, forKey: .truncatedPassageEndScalar)
        try c.encode(truncatedPassageTokens, forKey: .truncatedPassageTokens)
        try c.encode(evidenceTokens, forKey: .evidenceTokens)
        try c.encode(mapTokens, forKey: .mapTokens)
        try c.encode(noteWebTokens, forKey: .noteWebTokens)
        try c.encode(historyTurnsIncluded, forKey: .historyTurnsIncluded)
        try c.encode(historyTokens, forKey: .historyTokens)
        try c.encode(unusedTokens, forKey: .unusedTokens)
    }
}
