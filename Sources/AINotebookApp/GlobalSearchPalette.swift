import SwiftUI
import AINotebookCore

/// Epic B4 — the Cmd+K "search everything" palette. Full-text search across all
/// notebooks' notes and source titles; selecting a hit navigates to it.
struct GlobalSearchPalette: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @Binding var isPresented: Bool
    /// Called with (notebookId, noteId?) — noteId nil means a source hit.
    let onSelectNote: (Int64, Int64) -> Void
    let onSelectSource: (Int64, Int64) -> Void

    @State private var query = ""
    @State private var result = GlobalSearchResult(notes: [], sources: [])

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(settings.text.string(.globalSearchPlaceholder), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(16)
                .onChange(of: query) { _, q in
                    result = (try? store.globalSearch(query: q)) ?? GlobalSearchResult(notes: [], sources: [])
                }
            Divider()
            results
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private var results: some View {
        if result.notes.isEmpty && result.sources.isEmpty {
            VStack {
                Spacer()
                Text(query.isEmpty ? settings.text.string(.globalSearchTitle) : settings.text.string(.globalSearchEmpty))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List {
                if !result.notes.isEmpty {
                    Section(settings.text.string(.globalSearchNotesSection)) {
                        ForEach(result.notes) { hit in
                            Button {
                                onSelectNote(hit.notebookId, hit.noteId)
                                isPresented = false
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.title).fontWeight(.medium)
                                    Text(strippedSnippet(hit.snippet))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !result.sources.isEmpty {
                    Section(settings.text.string(.globalSearchSourcesSection)) {
                        ForEach(result.sources) { hit in
                            Button {
                                onSelectSource(hit.notebookId, hit.sourceId)
                                isPresented = false
                            } label: {
                                Text(hit.title)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    /// The FTS snippet wraps matches in `<b>…</b>`; strip the tags for display.
    private func strippedSnippet(_ s: String) -> String {
        s.replacingOccurrences(of: "<b>", with: "").replacingOccurrences(of: "</b>", with: "")
    }
}
