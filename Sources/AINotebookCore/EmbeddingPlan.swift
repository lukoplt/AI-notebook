import CryptoKit
import Foundation

/// Which chunks a background build embeds, in which order (contract `embedding-plan-v1`).
public enum EmbeddingPlan {
    /// Stored source types embedded last and capped (`.xlsx` and `.xlsm` both store `xlsx`).
    public static let spreadsheetTypes: [SourceType] = [.xlsx]
    /// A spreadsheet source embeds only its chunks with `ord` below this; the rest stay full-text only.
    public static let spreadsheetChunkCap = 64
    /// A round examines at most `roundScanFactor × batchSize` candidates.
    public static let roundScanFactor = 16

    public static func priorityClass(_ type: SourceType) -> Int { spreadsheetTypes.contains(type) ? 1 : 0 }

    /// The embed cap of a source type, nil when every chunk is embedded.
    public static func embedCap(_ type: SourceType) -> Int? { spreadsheetTypes.contains(type) ? spreadsheetChunkCap : nil }

    /// Lowercase hex SHA-256 of the exact UTF-8 bytes (no normalization): the dedup key within a generation.
    public static func textHash(_ text: String) -> String {
        var hex = [UInt8]()
        hex.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(text.utf8)) {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    /// `c.ord` below the source's cap; index-friendly on `idx_chunks_revision_ord`.
    static func embeddableSQL(source s: String = "s", chunk c: String = "c") -> String {
        "\(c).ord<(CASE WHEN \(s).type='xlsx' THEN \(spreadsheetChunkCap) ELSE 9223372036854775807 END)"
    }

    /// `(s.type='xlsx')` as 0/1: the priority class of a source row.
    static func classSQL(source s: String = "s") -> String { "(\(s).type='xlsx')" }
}

/// Keyset position of the last consumed candidate: `(priorityClass, sourceId, ord)`.
public struct EmbeddingCursor: Sendable, Equatable, Comparable {
    public let priorityClass: Int
    public let sourceId: Int64
    public let ord: Int

    public static func < (lhs: EmbeddingCursor, rhs: EmbeddingCursor) -> Bool {
        (lhs.priorityClass, lhs.sourceId, lhs.ord) < (rhs.priorityClass, rhs.sourceId, rhs.ord)
    }
}

/// One round of a generation build: unique provider inputs, chunks that join an input,
/// and how many vectors were copied from existing ones without a provider call.
struct EmbeddingRound: Sendable, Equatable {
    let items: [EmbeddingBatchItem]
    /// Same-text chunks that receive the vector of `items[index]` at commit.
    let joined: [(item: EmbeddingBatchItem, index: Int)]
    let copied: Int
    let cursor: EmbeddingCursor?
    /// The walk restarted from the beginning because settling changed the manifest.
    let reset: Bool

    static func == (lhs: EmbeddingRound, rhs: EmbeddingRound) -> Bool {
        lhs.items == rhs.items && lhs.copied == rhs.copied && lhs.cursor == rhs.cursor && lhs.reset == rhs.reset
            && lhs.joined.map(\.item) == rhs.joined.map(\.item) && lhs.joined.map(\.index) == rhs.joined.map(\.index)
    }
}
