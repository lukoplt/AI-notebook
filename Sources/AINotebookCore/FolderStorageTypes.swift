import Foundation

public struct FolderIdentity: Equatable, Sendable, Codable {
    public let volumeId: String
    public let components: [String]
    /// Filesystem object identity; path overlap still depends only on volume and components.
    public let rootFileId: String

    public init(volumeId: String, components: [String], rootFileId: String) {
        self.volumeId = volumeId
        self.components = components
        self.rootFileId = rootFileId
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.volumeId.utf8.elementsEqual(rhs.volumeId.utf8)
            && lhs.rootFileId.utf8.elementsEqual(rhs.rootFileId.utf8)
            && lhs.components.count == rhs.components.count
            && zip(lhs.components, rhs.components).allSatisfy { $0.utf8.elementsEqual($1.utf8) }
    }
}

public struct FolderDraft: Equatable, Sendable, Codable {
    public let rootPath: String
    public let displayName: String
    public let includeExts: [String]
    public let ignoreGlobs: [String]
    public let limitsJSON: String
    public let encodingFallback: String
    public let watchEnabled: Bool

    public init(rootPath: String, displayName: String, includeExts: [String], ignoreGlobs: [String], limitsJSON: String, encodingFallback: String, watchEnabled: Bool) {
        self.rootPath = rootPath
        self.displayName = displayName
        self.includeExts = includeExts
        self.ignoreGlobs = ignoreGlobs
        self.limitsJSON = limitsJSON
        self.encodingFallback = encodingFallback
        self.watchEnabled = watchEnabled
    }
}

public struct FolderSource: Equatable, Sendable {
    public let id: Int64
    public let notebookId: Int64
    public let draft: FolderDraft
    public let identity: FolderIdentity
    public let scanState: String
    public let scanGeneration: Int64
    public let lastFullScanAt: Int64?
    public let lastScanError: String?
    public let createdAt: Int64

    public init(id: Int64, notebookId: Int64, draft: FolderDraft, identity: FolderIdentity, scanState: String, scanGeneration: Int64, lastFullScanAt: Int64?, lastScanError: String?, createdAt: Int64) {
        self.id = id
        self.notebookId = notebookId
        self.draft = draft
        self.identity = identity
        self.scanState = scanState
        self.scanGeneration = scanGeneration
        self.lastFullScanAt = lastFullScanAt
        self.lastScanError = lastScanError
        self.createdAt = createdAt
    }
}

public struct ScanItem: Equatable, Sendable {
    public let folderId: Int64
    public let relPath: String
    public let kind: String
    public let skipReason: String?
    public let mtime: Int64?
    public let sizeBytes: Int64?
    public let seenGeneration: Int64

    public init(folderId: Int64, relPath: String, kind: String, skipReason: String?, mtime: Int64?, sizeBytes: Int64?, seenGeneration: Int64) {
        self.folderId = folderId
        self.relPath = relPath
        self.kind = kind
        self.skipReason = skipReason
        self.mtime = mtime
        self.sizeBytes = sizeBytes
        self.seenGeneration = seenGeneration
    }
}

public struct CoverageSnapshot: Equatable, Sendable {
    public let searchable: Int
    public let pending: Int
    public let error: Int
    public let skipped: Int
    public let missing: Int
    public let unavailable: Int
    public let refreshPending: Int
    public let refreshError: Int
    public let isLowerBound: Bool
    public let notSearchable: Int
    public let current: Int

    public init(searchable: Int, pending: Int, error: Int, skipped: Int, missing: Int, unavailable: Int, refreshPending: Int, refreshError: Int, isLowerBound: Bool, notSearchable: Int = 0, current: Int = 0) {
        self.searchable = searchable
        self.pending = pending
        self.error = error
        self.skipped = skipped
        self.missing = missing
        self.unavailable = unavailable
        self.refreshPending = refreshPending
        self.refreshError = refreshError
        self.isLowerBound = isLowerBound
        self.notSearchable = notSearchable
        self.current = current
    }
}

public struct ProviderModelLimits: Equatable, Sendable {
    public let providerId: String
    public let model: String
    public let contextWindow: Int?
    public let runtimeContext: Int
    public let maxOutputTokens: Int
    public let source: String

    public init(providerId: String, model: String, contextWindow: Int?, runtimeContext: Int, maxOutputTokens: Int, source: String) {
        self.providerId = providerId
        self.model = model
        self.contextWindow = contextWindow
        self.runtimeContext = runtimeContext
        self.maxOutputTokens = maxOutputTokens
        self.source = source
    }
}

public protocol FolderPathIdentity: Sendable {
    func resolve(rootPath: String) throws -> FolderIdentity
}
