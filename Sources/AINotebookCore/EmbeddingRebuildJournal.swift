import Foundation

public struct EmbeddingRebuildTarget: Codable, Equatable, Sendable {
    public let notebookId: Int64
    public let generationId: Int64

    public init(notebookId: Int64, generationId: Int64) {
        self.notebookId = notebookId
        self.generationId = generationId
    }
}

/// Local recovery record written before an explicit rebuild's atomic activation. It holds
/// selections and IDs only: no roots, secrets or source text.
public struct EmbeddingRebuildRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let previous: EmbeddingModelChoice
    public let requested: EmbeddingModelChoice
    public let targets: [EmbeddingRebuildTarget]

    public init(version: Int = 1, previous: EmbeddingModelChoice, requested: EmbeddingModelChoice,
                targets: [EmbeddingRebuildTarget]) {
        self.version = version
        self.previous = previous
        self.requested = requested
        self.targets = targets
    }

    func validate() throws {
        let bad = EmbeddingRecommendationError(code: "invalidJournal")
        guard version == 1, !previous.providerId.isEmpty, !previous.model.isEmpty, !requested.providerId.isEmpty,
              !requested.model.isEmpty, requested.profileId != nil,
              targets.allSatisfy({ $0.notebookId > 0 && $0.generationId > 0 }),
              Set(targets.map(\.notebookId)).count == targets.count,
              Set(targets.map(\.generationId)).count == targets.count else { throw bad }
    }

    private enum CodingKeys: String, CodingKey { case version, previous, requested, targets }
}

/// `embedding-rebuild-v1.json` beside `db.sqlite`; atomic writes.
public struct EmbeddingRebuildJournal: Sendable {
    public static let fileName = "embedding-rebuild-v1.json"
    public let url: URL

    public init(url: URL) { self.url = url }

    public func read() throws -> EmbeddingRebuildRecord? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let record: EmbeddingRebuildRecord
        do { record = try JSONDecoder().decode(EmbeddingRebuildRecord.self, from: data) }
        catch { throw EmbeddingRecommendationError(code: "invalidJournal") }
        try record.validate()
        return record
    }

    public func write(_ record: EmbeddingRebuildRecord) throws {
        try record.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: url, options: .atomic)
    }

    public func clear() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { return }
    }
}
