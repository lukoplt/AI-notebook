using AINotebook.Core.Models;
using Dapper;

namespace AINotebook.Core.Storage;

public record NoteSearchHit(long NoteId, long NotebookId, string Title, string Snippet);
public record SourceSearchHit(long SourceId, long NotebookId, string Title);
public record GlobalSearchResult(IReadOnlyList<NoteSearchHit> Notes, IReadOnlyList<SourceSearchHit> Sources);

public sealed partial class NotebookStore
{
    /// <summary>Full-text search within a single notebook's notes.</summary>
    public IReadOnlyList<NoteSearchHit> SearchNotes(long notebookId, string query)
    {
        if (string.IsNullOrWhiteSpace(query)) return [];
        return Connection.Query(
            """
            SELECT n.id, n.notebook_id, n.title,
                   snippet(notes_fts, 1, '<b>', '</b>', '…', 20) AS snippet
            FROM notes_fts
            JOIN notes n ON n.id = notes_fts.rowid
            WHERE notes_fts MATCH $q
              AND n.notebook_id = $nb
            ORDER BY rank
            LIMIT 50
            """,
            new { q = EscapeFtsQuery(query), nb = notebookId })
            .Select(r => new NoteSearchHit((long)r.id, (long)r.notebook_id, (string)r.title, (string)r.snippet))
            .ToList();
    }

    /// <summary>Cross-notebook search across notes and source titles.</summary>
    public GlobalSearchResult GlobalSearch(string query)
    {
        if (string.IsNullOrWhiteSpace(query))
            return new GlobalSearchResult([], []);

        var escaped = EscapeFtsQuery(query);

        var notes = Connection.Query(
            """
            SELECT n.id, n.notebook_id, n.title,
                   snippet(notes_fts, 1, '<b>', '</b>', '…', 20) AS snippet
            FROM notes_fts
            JOIN notes n ON n.id = notes_fts.rowid
            WHERE notes_fts MATCH $q
            ORDER BY rank
            LIMIT 100
            """,
            new { q = escaped })
            .Select(r => new NoteSearchHit((long)r.id, (long)r.notebook_id, (string)r.title, (string)r.snippet))
            .ToList();

        var sources = Connection.Query(
            """
            SELECT s.id, s.notebook_id, s.title
            FROM sources_fts
            JOIN sources s ON s.id = sources_fts.rowid
            WHERE sources_fts MATCH $q
            ORDER BY rank
            LIMIT 50
            """,
            new { q = escaped })
            .Select(r => new SourceSearchHit((long)r.id, (long)r.notebook_id, (string)r.title))
            .ToList();

        return new GlobalSearchResult(notes, sources);
    }

    private static string EscapeFtsQuery(string raw)
    {
        // Wrap bare terms in double-quotes so punctuation in user input doesn't
        // generate FTS5 syntax errors. Each whitespace-delimited token is
        // individually quoted; empty tokens are skipped.
        var parts = raw.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(t => "\"" + t.Replace("\"", "\"\"") + "\"");
        return string.Join(" ", parts);
    }
}
