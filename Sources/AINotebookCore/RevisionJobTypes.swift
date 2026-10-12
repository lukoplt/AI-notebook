import Foundation

public struct RevisionDraft: Equatable, Sendable {
    public let contentHash: String
    public let canonicalText: String
    public let textFormatVersion: Int
    public let chunkerVersion: Int

    public init(contentHash: String, canonicalText: String, textFormatVersion: Int, chunkerVersion: Int) {
        self.contentHash = contentHash
        self.canonicalText = canonicalText
        self.textFormatVersion = textFormatVersion
        self.chunkerVersion = chunkerVersion
    }
}

public struct SourceRevision: Equatable, Sendable {
    public let id: Int64
    public let sourceId: Int64
    public let revision: Int
    public let draft: RevisionDraft
    public let createdAt: Int64

    public init(id: Int64, sourceId: Int64, revision: Int, draft: RevisionDraft, createdAt: Int64) {
        self.id = id
        self.sourceId = sourceId
        self.revision = revision
        self.draft = draft
        self.createdAt = createdAt
    }
}

public struct RevisionChunkDraft: Equatable, Sendable {
    public let text: String
    public let tokenCount: Int
    public let pageHint: Int?
    public let charStart: Int?
    public let charEnd: Int?
    public let lang: String?
    public let langInherited: Bool

    public init(text: String, tokenCount: Int, pageHint: Int?, charStart: Int?, charEnd: Int?, lang: String?, langInherited: Bool) {
        self.text = text
        self.tokenCount = tokenCount
        self.pageHint = pageHint
        self.charStart = charStart
        self.charEnd = charEnd
        self.lang = lang
        self.langInherited = langInherited
    }
}

public struct JobFence: Equatable, Sendable {
    public let jobId: Int64
    public let leaseToken: String

    public init(jobId: Int64, leaseToken: String) {
        self.jobId = jobId
        self.leaseToken = leaseToken
    }
}

public struct IngestJobDraft: Equatable, Sendable {
    public let kind: String
    public let target: String
    public let targetRevision: Int64?
    /// Nonsecret runtime options captured for this job. Frozen after the first claim.
    public let optionsJSON: String

    public init(kind: String, target: String, targetRevision: Int64?, optionsJSON: String = "{}") {
        self.kind = kind
        self.target = target
        self.targetRevision = targetRevision
        self.optionsJSON = optionsJSON
    }
}

public struct IngestJob: Equatable, Sendable {
    public let id: Int64
    public let draft: IngestJobDraft
    public let attempts: Int
    public let nextRetryAt: Int64?
    public let state: String
    public let leaseUntil: Int64?
    public let leaseToken: String?
    public let error: String?

    public init(id: Int64, draft: IngestJobDraft, attempts: Int, nextRetryAt: Int64?, state: String, leaseUntil: Int64?, leaseToken: String?, error: String?) {
        self.id = id
        self.draft = draft
        self.attempts = attempts
        self.nextRetryAt = nextRetryAt
        self.state = state
        self.leaseUntil = leaseUntil
        self.leaseToken = leaseToken
        self.error = error
    }
}

public protocol IngestLeaseClock: Sendable {
    func now() -> Int64
    func wait(until: Int64) async throws
}

public struct SystemIngestLeaseClock: IngestLeaseClock {
    public init() {}
    public func now() -> Int64 { Int64(Date().timeIntervalSince1970) }
    public func wait(until: Int64) async throws {
        try Task.checkCancellation()
        let delay = max(0, Double(until) - Double(now()))
        try await Task.sleep(for: .seconds(delay))
    }
}
