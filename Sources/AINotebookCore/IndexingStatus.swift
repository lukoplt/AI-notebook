import Foundation

/// Why background embedding cannot run for a notebook (contract `indexing-status-v1` §4).
/// The embedding-session factory returns this instead of a bare nil.
public enum EmbeddingAvailability: String, Sendable, Equatable, CaseIterable {
    case ready
    case noProvider
    case providerDisabled
    case noModel
    case consentRequired
    case providerHasNoEmbeddings
    case credentialUnavailable
}

/// A captured embedding session, or the reason there is none.
public struct EmbeddingSessionResolution: Sendable {
    public let session: FolderEmbeddingSession?
    public let availability: EmbeddingAvailability

    public static func ready(_ session: FolderEmbeddingSession) -> EmbeddingSessionResolution {
        EmbeddingSessionResolution(session: session, availability: .ready)
    }

    public static func unavailable(_ reason: EmbeddingAvailability) -> EmbeddingSessionResolution {
        precondition(reason != .ready, "an unavailable resolution needs a reason")
        return EmbeddingSessionResolution(session: nil, availability: reason)
    }

    private init(session: FolderEmbeddingSession?, availability: EmbeddingAvailability) {
        self.session = session
        self.availability = availability
    }
}


/// One folder of the notebook as the status derivation sees it.
public struct IndexingFolderInput: Sendable, Equatable {
    public let folderId: Int64
    /// `idle|scanning|partial|error|unavailable`.
    public let scanState: String
    public let lastScanError: String?
    /// Files observed so far in the running scan (scanning folders only).
    public let filesSeen: Int?

    public init(folderId: Int64, scanState: String, lastScanError: String?, filesSeen: Int?) {
        self.folderId = folderId
        self.scanState = scanState
        self.lastScanError = lastScanError
        self.filesSeen = filesSeen
    }
}

/// The notebook's newest embed job.
public struct IndexingEmbedJobInput: Sendable, Equatable {
    public let state: String
    public let attempts: Int
    public let nextRetryAt: Int64?
    public let errorCode: String?
    /// Notebook-target dimension bootstrap (no generation yet).
    public let bootstrap: Bool

    public init(state: String, attempts: Int, nextRetryAt: Int64?, errorCode: String?, bootstrap: Bool) {
        self.state = state
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.errorCode = errorCode
        self.bootstrap = bootstrap
    }

    /// Waiting for an automatic retry deadline (contract §2.4).
    func waiting(now: Int64) -> Bool {
        if state == "failed" { return attempts < 5 && nextRetryAt != nil }
        guard state == "queued", let nextRetryAt else { return false }
        return nextRetryAt > now
    }
}

/// Snapshot read by the store in one batch plus the runtime facts (contract §1).
public struct IndexingInputs: Sendable, Equatable {
    public var now: Int64
    public var runtimeError: String?
    public var embeddingAvailability: EmbeddingAvailability
    public var folders: [IndexingFolderInput]
    public var scanJobsPending: Int
    public var extractQueued: Int
    public var extractRunning: Int
    public var sourcesTotal: Int
    public var sourcesReady: Int
    public var sourcesError: Int
    public var needsEmbedding: Bool
    public var embedJob: IndexingEmbedJobInput?
    public var embedChunksDone: Int
    public var embedChunksTotal: Int
    /// Extraction admission's memory-pressure level (runtime fact, addendum §6).
    public var memoryPressure: MemoryPressureLevel

    public init(now: Int64, runtimeError: String? = nil, embeddingAvailability: EmbeddingAvailability = .ready,
                folders: [IndexingFolderInput] = [], scanJobsPending: Int = 0, extractQueued: Int = 0, extractRunning: Int = 0,
                sourcesTotal: Int = 0, sourcesReady: Int = 0, sourcesError: Int = 0, needsEmbedding: Bool = false,
                embedJob: IndexingEmbedJobInput? = nil, embedChunksDone: Int = 0, embedChunksTotal: Int = 0,
                memoryPressure: MemoryPressureLevel = .normal) {
        self.now = now
        self.runtimeError = runtimeError
        self.embeddingAvailability = embeddingAvailability
        self.folders = folders
        self.scanJobsPending = scanJobsPending
        self.extractQueued = extractQueued
        self.extractRunning = extractRunning
        self.sourcesTotal = sourcesTotal
        self.sourcesReady = sourcesReady
        self.sourcesError = sourcesError
        self.needsEmbedding = needsEmbedding
        self.embedJob = embedJob
        self.embedChunksDone = embedChunksDone
        self.embedChunksTotal = embedChunksTotal
        self.memoryPressure = memoryPressure
    }
}

/// Why indexing cannot proceed (`blocked` phase).
public enum IndexingBlockedReason: Sendable, Equatable {
    /// No provider, no model, or a provider without embeddings → Settings › Providers.
    case noEmbeddingModel
    case providerDisabled
    case consentRequired
    /// The provider's API key could not be loaded (Keychain / credential store).
    case credentialUnavailable
    /// Terminal embed failure; "Retry now" → `retryIndexingNow`.
    case indexFailed(code: String)
    /// The ingestion runtime failed to start; "Retry now" → `retryIndexingNow`.
    case runtimeFailed(code: String)

    /// Contract name (`blockedReason`).
    public var name: String {
        switch self {
        case .noEmbeddingModel: return "noEmbeddingModel"
        case .providerDisabled: return "providerDisabled"
        case .consentRequired: return "consentRequired"
        case .credentialUnavailable: return "credentialUnavailable"
        case .indexFailed: return "indexFailed"
        case .runtimeFailed: return "runtimeFailed"
        }
    }

    /// The failure code of `indexFailed` / `runtimeFailed`.
    public var errorCode: String? {
        switch self {
        case .indexFailed(let code), .runtimeFailed(let code): return code
        default: return nil
        }
    }
}

/// The embed job's pending automatic retry.
public struct IndexingRetry: Sendable, Equatable {
    public let code: String
    public let retryAt: Int64
    public let attempt: Int
    /// `max(0, retryAt − now)` at derivation time.
    public let retryInSeconds: Int64

    public init(code: String, retryAt: Int64, attempt: Int, retryInSeconds: Int64) {
        self.code = code
        self.retryAt = retryAt
        self.attempt = attempt
        self.retryInSeconds = retryInSeconds
    }
}

public enum IndexingPhase: Sendable, Equatable {
    /// "Checking folder… N files" (`filesSeen` nil = unknown).
    case scanning(filesSeen: Int?)
    /// "Processing files d / t" (sources).
    case extracting(done: Int, total: Int)
    /// "Indexing d / t chunks"; nil counts = indeterminate; `preparing` = dimension bootstrap.
    case embedding(done: Int?, total: Int?, preparing: Bool)
    case retrying(IndexingRetry)
    case blocked(IndexingBlockedReason)
    case ready
    /// Full-text search only; "Build index" → `retryIndexingNow`.
    case lexicalOnly
    case empty

    /// Contract name (`phase`).
    public var name: String {
        switch self {
        case .scanning: return "scanning"
        case .extracting: return "extracting"
        case .embedding: return "embedding"
        case .retrying: return "retrying"
        case .blocked: return "blocked"
        case .ready: return "ready"
        case .lexicalOnly: return "lexicalOnly"
        case .empty: return "empty"
        }
    }

    public var isActive: Bool {
        switch self {
        case .scanning, .extracting, .embedding, .retrying: return true
        default: return false
        }
    }
}

/// A folder whose last scan did not complete cleanly.
public struct IndexingScanWarning: Sendable, Equatable {
    public let folderId: Int64
    /// `partial|error|unavailable`.
    public let state: String
    public let error: String?

    public init(folderId: Int64, state: String, error: String?) {
        self.folderId = folderId
        self.state = state
        self.error = error
    }
}

/// Per-notebook indexing status (contract `indexing-status-v1`).
public struct IndexingStatus: Sendable, Equatable {
    public let phase: IndexingPhase
    /// Sources with status `error`.
    public let sourceErrors: Int
    public let scanWarnings: [IndexingScanWarning]
    /// `extracting` only: system memory pressure slows (`warning`) or pauses
    /// (`critical`) extraction; nil otherwise (addendum §6).
    public let memoryPressure: MemoryPressureLevel?
    /// A folder scan is running or queued while this phase is shown (`scanning`,
    /// or the `extracting`/`embedding` work it no longer hides; addendum §7).
    public let scanInProgress: Bool
    /// Files seen by the running scan(s) when `scanInProgress`; nil = unknown.
    public let scanFilesSeen: Int?

    public init(phase: IndexingPhase, sourceErrors: Int, scanWarnings: [IndexingScanWarning],
                memoryPressure: MemoryPressureLevel? = nil, scanInProgress: Bool = false, scanFilesSeen: Int? = nil) {
        self.phase = phase
        self.sourceErrors = sourceErrors
        self.scanWarnings = scanWarnings
        self.memoryPressure = memoryPressure
        self.scanInProgress = scanInProgress
        self.scanFilesSeen = scanInProgress ? scanFilesSeen : nil
    }

    /// scanning | extracting | embedding | retrying.
    public var isActive: Bool { phase.isActive }

    static let warningStates: Set<String> = ["partial", "error", "unavailable"]

    /// The pure derivation (contract §2): first match wins.
    public static func derive(_ input: IndexingInputs) -> IndexingStatus {
        let (phase, scan) = phase(input)
        var pressure: MemoryPressureLevel?
        if case .extracting = phase, input.memoryPressure != .normal { pressure = input.memoryPressure }
        return IndexingStatus(phase: phase, sourceErrors: input.sourcesError,
                              scanWarnings: input.folders.filter { warningStates.contains($0.scanState) }.map {
                                  IndexingScanWarning(folderId: $0.folderId, state: $0.scanState, error: $0.lastScanError)
                              }, memoryPressure: pressure, scanInProgress: scan.active, scanFilesSeen: scan.seen)
    }

    private static func phase(_ input: IndexingInputs) -> (IndexingPhase, (active: Bool, seen: Int?)) {
        if let error = input.runtimeError { return (.blocked(.runtimeFailed(code: error)), (false, nil)) }
        let scanning = input.folders.filter { $0.scanState == "scanning" }
        if !scanning.isEmpty || input.scanJobsPending > 0 {
            let counts = scanning.compactMap(\.filesSeen)
            let seen = counts.isEmpty ? nil : counts.reduce(0, +)
            // Addendum §7: extraction/embedding progress is never hidden behind a running scan.
            return (work(input) ?? .scanning(filesSeen: seen), (true, seen))
        }
        return (work(input) ?? settled(input), (false, nil))
    }

    /// Steps 3–4 without retrying: extraction or a due embed job.
    private static func work(_ input: IndexingInputs) -> IndexingPhase? {
        if input.extractQueued + input.extractRunning > 0 {
            let total = input.sourcesTotal
            return .extracting(done: min(total, input.sourcesReady + input.sourcesError), total: total)
        }
        guard let job = input.embedJob, !job.waiting(now: input.now), job.state == "running" || job.state == "queued" else {
            return nil
        }
        if job.bootstrap { return .embedding(done: nil, total: nil, preparing: true) }
        let total = input.embedChunksTotal
        guard total > 0 else { return .embedding(done: nil, total: nil, preparing: false) }
        return .embedding(done: min(total, input.embedChunksDone), total: total, preparing: false)
    }

    /// Steps 4 (retrying) to 9.
    private static func settled(_ input: IndexingInputs) -> IndexingPhase {
        let job = input.embedJob
        if let job, job.waiting(now: input.now), let retryAt = job.nextRetryAt {
            return .retrying(IndexingRetry(code: job.errorCode ?? "unknown", retryAt: retryAt, attempt: job.attempts,
                                           retryInSeconds: max(0, retryAt - input.now)))
        }
        if input.sourcesTotal == 0 { return .empty }
        switch input.embeddingAvailability {
        case .ready: break
        case .noProvider, .noModel, .providerHasNoEmbeddings: return .blocked(.noEmbeddingModel)
        case .providerDisabled: return .blocked(.providerDisabled)
        case .consentRequired: return .blocked(.consentRequired)
        case .credentialUnavailable: return .blocked(.credentialUnavailable)
        }
        if let job, job.state == "failed", !job.waiting(now: input.now), input.needsEmbedding {
            return .blocked(.indexFailed(code: job.errorCode ?? "unknown"))
        }
        return input.needsEmbedding ? .lexicalOnly : .ready
    }
}

/// The last finished scan of a folder (runtime memory, not durable), for
/// "No changes · N files up to date".
public struct FolderScanOutcome: Sendable, Equatable {
    public let folderId: Int64
    /// Extract jobs queued for the folder's sources while the scan ran.
    public let changedFiles: Int
    /// Eligible files seen in the folder's current scan generation.
    public let filesSeen: Int
    /// Lease-clock seconds.
    public let finishedAt: Int64

    public init(folderId: Int64, changedFiles: Int, filesSeen: Int, finishedAt: Int64) {
        self.folderId = folderId
        self.changedFiles = changedFiles
        self.filesSeen = filesSeen
        self.finishedAt = finishedAt
    }
}
