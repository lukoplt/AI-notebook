import Foundation
import ZIPFoundation

/// Exports notes and notebooks to portable formats (Epic B, FR-B1/B2).
/// Never includes API keys or internal file paths (only the source `uri`,
/// which the user themselves supplied). Ported from the Windows
/// `ExportService`.
public enum ExportService {

    /// A single note rendered as Markdown: an H1 title followed by the body.
    public static func exportNoteMarkdown(_ note: Note) -> String {
        "# \(note.title)\n\n\(note.bodyMd)\n"
    }

    /// Writes a notebook's notes (as `notes/*.md`) plus a `sources.json`
    /// manifest into a ZIP archive at `url`. Overwrites any existing file.
    @MainActor
    public static func exportNotebookZip(notebookId: Int64, store: NotebookStore, to url: URL) throws {
        let notes = try store.notes(notebookId: notebookId)
        let sources = try store.sources(notebookId: notebookId)

        // Stage into a temp directory, then zip the folder. Simple, and keeps
        // filename sanitation and manifest generation testable.
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("nbexport-\(UUID().uuidString)", isDirectory: true)
        let notesDir = staging.appendingPathComponent("notes", isDirectory: true)
        try fm.createDirectory(at: notesDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var usedNames = Set<String>()
        for note in notes {
            var name = sanitizeFilename(note.title)
            // De-dup identical titles so notes never overwrite each other.
            var candidate = name
            var n = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(name)-\(n)"
                n += 1
            }
            name = candidate
            usedNames.insert(name.lowercased())
            let data = Data(exportNoteMarkdown(note).utf8)
            try data.write(to: notesDir.appendingPathComponent("\(name).md"))
        }

        let manifest = sources.map { s in
            SourceManifestEntry(
                id: s.id ?? 0,
                title: s.title,
                type: s.type.rawValue,
                status: s.status.rawValue,
                uri: s.uri,
                ingestedAt: ISO8601DateFormatter().string(from: s.ingestedAt)
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: staging.appendingPathComponent("sources.json"))

        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        try fm.zipItem(at: staging, to: url, shouldKeepParent: false)
    }

    struct SourceManifestEntry: Codable, Equatable {
        var id: Int64
        var title: String
        var type: String
        var status: String
        var uri: String?
        var ingestedAt: String
    }

    /// Replaces filesystem-invalid characters with `_`, trims, and caps length.
    static func sanitizeFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let cleaned = String(raw.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) })
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
        if trimmed.isEmpty { return "note" }
        return String(trimmed.prefix(80))
    }
}
