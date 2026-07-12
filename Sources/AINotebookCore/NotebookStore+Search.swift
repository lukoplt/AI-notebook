import Foundation
import GRDB

/// A note matched by full-text search, with an FTS snippet (`<b>` around the
/// matched term).
public struct NoteSearchHit: Identifiable, Equatable, Sendable {
    public var noteId: Int64
    public var notebookId: Int64
    public var title: String
    public var snippet: String
    public var id: Int64 { noteId }
}

/// A source matched by full-text search over its title.
public struct SourceSearchHit: Identifiable, Equatable, Sendable {
    public var sourceId: Int64
    public var notebookId: Int64
    public var title: String
    public var id: Int64 { sourceId }
}

/// Cross-notebook search result (Cmd/Ctrl+K palette, FR-B4).
public struct GlobalSearchResult: Equatable, Sendable {
    public var notes: [NoteSearchHit]
    public var sources: [SourceSearchHit]
    public init(notes: [NoteSearchHit], sources: [SourceSearchHit]) {
        self.notes = notes
        self.sources = sources
    }
}

/// Full-text note search (FR-B9) and cross-notebook global search (FR-B4).
/// Ported from the Windows `NotebookStore.Search` partial, including the
/// FTS-query escaping that quotes each token so user punctuation can't produce
/// an FTS5 syntax error.
extension NotebookStore {

    /// Full-text search within a single notebook's notes.
    public func searchNotes(notebookId: Int64, query: String) throws -> [NoteSearchHit] {
        let escaped = Self.escapeFtsQuery(query)
        guard !escaped.isEmpty else { return [] }
        return try runOnDatabase { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT n.id AS id, n.notebook_id AS notebook_id, n.title AS title,
                       snippet(notes_fts, 1, '<b>', '</b>', '…', 20) AS snippet
                FROM notes_fts
                JOIN notes n ON n.id = notes_fts.rowid
                WHERE notes_fts MATCH ? AND n.notebook_id = ?
                ORDER BY rank
                LIMIT 50
                """,
                arguments: [escaped, notebookId]
            ).map {
                NoteSearchHit(noteId: $0["id"], notebookId: $0["notebook_id"], title: $0["title"], snippet: $0["snippet"])
            }
        }
    }

    /// Cross-notebook search across notes and source titles.
    public func globalSearch(query: String) throws -> GlobalSearchResult {
        let escaped = Self.escapeFtsQuery(query)
        guard !escaped.isEmpty else { return GlobalSearchResult(notes: [], sources: []) }
        return try runOnDatabase { db in
            let notes = try Row.fetchAll(
                db,
                sql: """
                SELECT n.id AS id, n.notebook_id AS notebook_id, n.title AS title,
                       snippet(notes_fts, 1, '<b>', '</b>', '…', 20) AS snippet
                FROM notes_fts
                JOIN notes n ON n.id = notes_fts.rowid
                WHERE notes_fts MATCH ?
                ORDER BY rank
                LIMIT 100
                """,
                arguments: [escaped]
            ).map {
                NoteSearchHit(noteId: $0["id"], notebookId: $0["notebook_id"], title: $0["title"], snippet: $0["snippet"])
            }
            let sources = try Row.fetchAll(
                db,
                sql: """
                SELECT s.id AS id, s.notebook_id AS notebook_id, s.title AS title
                FROM sources_fts
                JOIN sources s ON s.id = sources_fts.rowid
                WHERE sources_fts MATCH ?
                ORDER BY rank
                LIMIT 50
                """,
                arguments: [escaped]
            ).map {
                SourceSearchHit(sourceId: $0["id"], notebookId: $0["notebook_id"], title: $0["title"])
            }
            return GlobalSearchResult(notes: notes, sources: sources)
        }
    }

    /// Quotes each whitespace-delimited token so punctuation in user input
    /// doesn't generate an FTS5 syntax error. Empty input → empty string.
    static func escapeFtsQuery(_ raw: String) -> String {
        raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            .joined(separator: " ")
    }
}
