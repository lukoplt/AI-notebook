import Foundation

public struct GenerationIdentity: Equatable, Sendable {
    public let providerId: String
    public let endpointRevision: String
    public let model: String
    public let modelDigest: String?
    public let dims: Int
    public let normalization: String
    public let queryFormatVersion: String
    public let docFormatVersion: String
    public let chunkerVersion: String

    public init(providerId: String, endpointRevision: String, model: String, modelDigest: String?, dims: Int, normalization: String, queryFormatVersion: String, docFormatVersion: String, chunkerVersion: String) {
        self.providerId = providerId
        self.endpointRevision = endpointRevision
        self.model = model
        self.modelDigest = modelDigest
        self.dims = dims
        self.normalization = normalization
        self.queryFormatVersion = queryFormatVersion
        self.docFormatVersion = docFormatVersion
        self.chunkerVersion = chunkerVersion
    }

    public var modelKey: String { providerId == "legacy" ? model : providerId + ":" + model }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
        return bytes(lhs.providerId) == bytes(rhs.providerId) &&
            bytes(lhs.endpointRevision) == bytes(rhs.endpointRevision) &&
            bytes(lhs.model) == bytes(rhs.model) &&
            bytes(lhs.modelDigest) == bytes(rhs.modelDigest) &&
            lhs.dims == rhs.dims &&
            bytes(lhs.normalization) == bytes(rhs.normalization) &&
            bytes(lhs.queryFormatVersion) == bytes(rhs.queryFormatVersion) &&
            bytes(lhs.docFormatVersion) == bytes(rhs.docFormatVersion) &&
            bytes(lhs.chunkerVersion) == bytes(rhs.chunkerVersion)
    }
}

public struct IndexGeneration: Equatable, Sendable {
    public let id: Int64
    public let notebookId: Int64
    public let identity: GenerationIdentity
    public let state: String
    public let createdAt: Int64
    public let activatedAt: Int64?

    public init(id: Int64, notebookId: Int64, identity: GenerationIdentity, state: String, createdAt: Int64, activatedAt: Int64?) {
        self.id = id
        self.notebookId = notebookId
        self.identity = identity
        self.state = state
        self.createdAt = createdAt
        self.activatedAt = activatedAt
    }
}

public struct ManifestEntry: Equatable, Sendable {
    public let sourceId: Int64
    public let revisionId: Int64
    public let state: String
    public let reason: String?

    public init(sourceId: Int64, revisionId: Int64, state: String, reason: String?) {
        self.sourceId = sourceId
        self.revisionId = revisionId
        self.state = state
        self.reason = reason
    }
}

public struct QueryPin: Equatable, Sendable {
    public let token: String
    public let notebookId: Int64
    public let generationId: Int64?
    public let modelKey: String?
    public let dims: Int?
    public let lexicalRevisions: [Int64: Int64]
    public let vectorRevisions: [Int64: Int64]

    public init(token: String, notebookId: Int64, generationId: Int64?, modelKey: String?, dims: Int?, lexicalRevisions: [Int64: Int64], vectorRevisions: [Int64: Int64]) {
        self.token = token
        self.notebookId = notebookId
        self.generationId = generationId
        self.modelKey = modelKey
        self.dims = dims
        self.lexicalRevisions = lexicalRevisions
        self.vectorRevisions = vectorRevisions
    }
}

public struct GarbageCollectionResult: Equatable, Sendable {
    public let generations: Int
    public let revisions: Int
    public let chunks: Int
    public let vectors: Int

    public init(generations: Int, revisions: Int, chunks: Int, vectors: Int) {
        self.generations = generations
        self.revisions = revisions
        self.chunks = chunks
        self.vectors = vectors
    }
}
