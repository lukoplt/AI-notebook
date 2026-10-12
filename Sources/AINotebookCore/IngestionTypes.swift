import Foundation

public struct IngestionError: Error, Sendable, Equatable {
    public let code: String
    public init(code: String) { self.code = code }
}

/// Per-folder limits may reduce, but never exceed, the process safety ceilings.
public struct IngestionLimits: Sendable, Equatable, Codable {
    public let fileBytes: Int64
    public let officeBytes: Int64
    public let textScalars: Int
    public let pdfPages: Int
    public let chunks: Int
    public let cells: Int

    public init(fileBytes: Int64, officeBytes: Int64, textScalars: Int, pdfPages: Int, chunks: Int, cells: Int) {
        self.fileBytes = fileBytes
        self.officeBytes = officeBytes
        self.textScalars = textScalars
        self.pdfPages = pdfPages
        self.chunks = chunks
        self.cells = cells
    }

    public static let defaults = IngestionLimits(
        fileBytes: RagContractV1.Scan.maxFileBytes,
        officeBytes: RagContractV1.Scan.maxOfficeDecompressedBytes,
        textScalars: RagContractV1.Scan.maxExtractedChars,
        pdfPages: RagContractV1.Scan.maxPdfPages,
        chunks: RagContractV1.Scan.maxChunksPerFile,
        cells: 1_000_000)

    private enum CodingKeys: String, CodingKey {
        case fileBytes = "maxFileBytes"
        case officeBytes = "maxOfficeDecompressedBytes"
        case textScalars = "maxExtractedChars"
        case pdfPages = "maxPdfPages"
        case chunks = "maxChunksPerFile"
        case cells = "maxCells"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self.defaults
        // Only absent keys receive defaults: null and noninteger values are invalid.
        fileBytes = try c.contains(.fileBytes) ? c.decode(Int64.self, forKey: .fileBytes) : defaults.fileBytes
        officeBytes = try c.contains(.officeBytes) ? c.decode(Int64.self, forKey: .officeBytes) : defaults.officeBytes
        textScalars = try c.contains(.textScalars) ? c.decode(Int.self, forKey: .textScalars) : defaults.textScalars
        pdfPages = try c.contains(.pdfPages) ? c.decode(Int.self, forKey: .pdfPages) : defaults.pdfPages
        chunks = try c.contains(.chunks) ? c.decode(Int.self, forKey: .chunks) : defaults.chunks
        cells = try c.contains(.cells) ? c.decode(Int.self, forKey: .cells) : defaults.cells
    }

    public init(json: String) throws {
        do { self = try JSONDecoder().decode(Self.self, from: Data(json.utf8)) }
        catch { throw IngestionError(code: "unsupportedSyntax") }
    }

    public func validate() throws {
        guard fileBytes > 0, fileBytes <= Self.defaults.fileBytes else { throw IngestionError(code: "fileLimit") }
        guard officeBytes > 0, officeBytes <= Self.defaults.officeBytes else { throw IngestionError(code: "officeLimit") }
        guard textScalars > 0, textScalars <= Self.defaults.textScalars else { throw IngestionError(code: "textLimit") }
        guard pdfPages > 0, pdfPages <= Self.defaults.pdfPages else { throw IngestionError(code: "pageLimit") }
        guard chunks > 0, chunks <= Self.defaults.chunks else { throw IngestionError(code: "chunkLimit") }
        guard cells > 0, cells <= Self.defaults.cells else { throw IngestionError(code: "cellLimit") }
    }
}

public struct FolderRules: Sendable, Equatable, Codable {
    public let includeExts: [String]
    public let ignoreGlobs: [String]
    public let limits: IngestionLimits
    public let encodingFallback: String

    public init(includeExts: [String], ignoreGlobs: [String], limits: IngestionLimits, encodingFallback: String) {
        self.includeExts = includeExts
        self.ignoreGlobs = ignoreGlobs
        self.limits = limits
        self.encodingFallback = encodingFallback
    }

    /// Contract `ingestion-formats-v1` §3; also the set a folder rule may include.
    /// Folders stored with the previous default are upgraded once (`FolderDefaultsUpgrade`).
    public static let defaults = FolderRules(
        includeExts: ["pdf", "txt", "md", "markdown", "docx", "pptx", "xlsx", "docm", "pptm", "xlsm", "eml", "msg"],
        ignoreGlobs: [".*", "node_modules", ".git", "build", "dist", ".venv", "__pycache__", "target", "bin", "obj", "~$*"],
        limits: .defaults, encodingFallback: "cp1250")

    public func validated(caseSensitive: Bool, tables: UnicodeTables) throws -> FolderRules {
        try limits.validate()
        guard ["cp1250", "none"].contains(encodingFallback) else { throw IngestionError(code: "unsupportedEncoding") }
        var normalized: [String] = []
        for supplied in includeExts {
            let name = supplied.hasPrefix(".") ? String(supplied.dropFirst()) : supplied
            let bytes = name.utf8.map { byte in (65...90).contains(byte) ? byte + 32 : byte }
            let lower = String(decoding: bytes, as: UTF8.self)
            guard Self.defaults.includeExts.contains(lower) else { throw IngestionError(code: "unsupportedSyntax") }
            if !normalized.contains(lower) { normalized.append(lower) }
        }
        for pattern in ignoreGlobs { _ = try FolderGlob(pattern, caseSensitive: caseSensitive, tables: tables) }
        return FolderRules(includeExts: normalized, ignoreGlobs: ignoreGlobs, limits: limits, encodingFallback: encodingFallback)
    }
}

public struct FileStamp: Sendable, Equatable, Codable {
    public let identity: String
    public let mtimeNs: Int64
    public let sizeBytes: Int64
    public init(identity: String, mtimeNs: Int64, sizeBytes: Int64) {
        self.identity = identity
        self.mtimeNs = mtimeNs
        self.sizeBytes = sizeBytes
    }
}

public struct CanonicalDocument: Sendable, Equatable {
    public let text: String
    public let title: String?
    public let kind: String
    public let pages: [PageBoundary]
    public let sheetNames: [String]
    public let encoding: String?
    public init(text: String, title: String?, kind: String, pages: [PageBoundary], sheetNames: [String], encoding: String?) {
        self.text = text
        self.title = title
        self.kind = kind
        self.pages = pages
        self.sheetNames = sheetNames
        self.encoding = encoding
    }
}

public struct DecodedText: Sendable, Equatable {
    public let text: String
    public let encoding: String
    public init(text: String, encoding: String) {
        self.text = text
        self.encoding = encoding
    }
}

public struct FolderObservation: Sendable, Equatable {
    public let relPath: String
    public let stamp: FileStamp
    public let kind: String
    public let skipReason: String?
    public let contentHash: String?
    public init(relPath: String, stamp: FileStamp, kind: String, skipReason: String?, contentHash: String?) {
        self.relPath = relPath
        self.stamp = stamp
        self.kind = kind
        self.skipReason = skipReason
        self.contentHash = contentHash
    }
}

/// One entry of a batched scan commit (contract `ingestion-scan-perf-v1` §1).
/// `knownOnly` marks an interior link: it is recorded (as `skipped`/`ignored`)
/// only when the path already has a source, exactly like `observeInteriorLink`.
public struct FolderScanObservation: Sendable, Equatable {
    public let observation: FolderObservation
    public let knownOnly: Bool

    public static func file(_ observation: FolderObservation) -> FolderScanObservation {
        FolderScanObservation(observation: observation, knownOnly: false)
    }

    public static func interiorLink(relPath: String, stamp: FileStamp) -> FolderScanObservation {
        FolderScanObservation(observation: FolderObservation(relPath: relPath, stamp: stamp, kind: "skipped",
                                                             skipReason: "ignored", contentHash: nil), knownOnly: true)
    }
}

/// Outcome of one batched scan commit: `unchanged` rows only had their
/// `seen_generation` bumped; `changed` rows went through the per-file path.
/// Interior links without a source count as neither.
public struct FolderObserveBatchResult: Sendable, Equatable {
    public let changed: Int
    public let unchanged: Int
    public init(changed: Int, unchanged: Int) {
        self.changed = changed
        self.unchanged = unchanged
    }
}

public struct ScanTicket: Sendable, Equatable {
    public let folderId: Int64
    public let generation: Int64
    public let fence: JobFence
    public init(folderId: Int64, generation: Int64, fence: JobFence) {
        self.folderId = folderId
        self.generation = generation
        self.fence = fence
    }
}

public struct ScanCompletion: Sendable, Equatable {
    public let completed: [String]
    public let incomplete: [String]
    public let rootUnavailable: Bool
    public let error: String?
    public init(completed: [String], incomplete: [String], rootUnavailable: Bool, error: String?) {
        self.completed = completed
        self.incomplete = incomplete
        self.rootUnavailable = rootUnavailable
        self.error = error
    }
}

public struct ExtractionRequest: Sendable, Equatable {
    public let sourceId: Int64
    public let folderId: Int64
    public let relPath: String
    public let stamp: FileStamp
    public let hash: String
    public let rules: FolderRules
    public init(sourceId: Int64, folderId: Int64, relPath: String, stamp: FileStamp, hash: String, rules: FolderRules) {
        self.sourceId = sourceId
        self.folderId = folderId
        self.relPath = relPath
        self.stamp = stamp
        self.hash = hash
        self.rules = rules
    }
}

/// Nonsecret settings persisted with a job. Credentials belong to provider sessions.
public struct EmbeddingSelection: Sendable, Equatable, Codable {
    public let providerId: String
    public let endpointRevision: String
    public let model: String
    public let modelDigest: String?
    public let dims: Int?
    public let normalization: String
    public let queryFormatVersion: String
    public let docFormatVersion: String
    public let chunkerVersion: String
    public init(providerId: String, endpointRevision: String, model: String, modelDigest: String?, dims: Int?,
                normalization: String, queryFormatVersion: String, docFormatVersion: String, chunkerVersion: String) {
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

    public static func == (lhs: Self, rhs: Self) -> Bool {
        func bytes(_ value: String?) -> Data? { value.map { Data($0.utf8) } }
        return bytes(lhs.providerId) == bytes(rhs.providerId)
            && bytes(lhs.endpointRevision) == bytes(rhs.endpointRevision)
            && bytes(lhs.model) == bytes(rhs.model)
            && bytes(lhs.modelDigest) == bytes(rhs.modelDigest)
            && lhs.dims == rhs.dims
            && bytes(lhs.normalization) == bytes(rhs.normalization)
            && bytes(lhs.queryFormatVersion) == bytes(rhs.queryFormatVersion)
            && bytes(lhs.docFormatVersion) == bytes(rhs.docFormatVersion)
            && bytes(lhs.chunkerVersion) == bytes(rhs.chunkerVersion)
    }
}

public struct PublicationMetadata: Sendable, Equatable {
    public let encoding: String?
    public let lang: String?
    public let coverageJSON: String?
    public let descriptorJSON: String
    public let pages: [PageBoundary]
    public init(encoding: String?, lang: String?, coverageJSON: String?, descriptorJSON: String, pages: [PageBoundary]) {
        self.encoding = encoding
        self.lang = lang
        self.coverageJSON = coverageJSON
        self.descriptorJSON = descriptorJSON
        self.pages = pages
    }
}
