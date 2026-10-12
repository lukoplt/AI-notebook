import AINotebookCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Notes segment of the right panel (spec §2.3): search, tag filter, "+ New",
/// bulk delete and tool history; a click opens the note in the main area.
struct NotesPanel: View {
    let notebook: Notebook
    let nav: NavigationState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var notes: [Note] = []
    @State private var query = ""
    @State private var searchHits: [Int64]?
    @State private var allTags: [Tag] = []
    @State private var noteTagIds: [Int64: Set<Int64>] = [:]
    @State private var tagFilter: Int64?
    @State private var bulkMode = false
    @State private var selectedIds: Set<Int64> = []
    @State private var showingHistory = false
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    /// Notes after search (FTS order) and the tag filter.
    private var displayed: [Note] {
        var list = notes
        if let hits = searchHits {
            let byId = Dictionary(uniqueKeysWithValues: notes.compactMap { n in n.id.map { ($0, n) } })
            list = hits.compactMap { byId[$0] }
        }
        if let tagFilter {
            list = list.filter { n in n.id.flatMap { noteTagIds[$0]?.contains(tagFilter) } ?? false }
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
                .padding(.horizontal, DesignTokens.spacing(12))
                .padding(.vertical, DesignTokens.spacing(8))
            if bulkMode { bulkBar }
            Hairline()
            if notes.isEmpty {
                EmptyStateView(title: t.string(.notesEmptyState), actions: [
                    EmptyStateAction(title: t.string(.notesNewButton), icon: .note, isPrimary: true) { createBlank() },
                ], compact: true)
            } else if displayed.isEmpty {
                PanelHint(icon: .search, text: t.string(.globalSearchEmpty))
            } else {
                List {
                    ForEach(displayed) { note in row(note) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            if let errorMessage {
                Label(errorMessage, systemImage: DesignTokens.icon(.warning))
                    .tokenFont(.caption)
                    .tokenForeground(.danger)
                    .padding(DesignTokens.spacing(12))
            }
        }
        .task(id: notebook.id) { reload() }
        .onChange(of: nav.selection) { _, _ in reload() }
        .onChange(of: query) { _, value in search(value) }
        .sheet(isPresented: $showingHistory) {
            TransformationHistorySheet(notebook: notebook, isPresented: $showingHistory)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: DesignTokens.spacing(4)) {
            HStack(spacing: DesignTokens.spacing(4)) {
                Image(systemName: DesignTokens.icon(.search))
                    .font(DesignTokens.font(.caption))
                    .tokenForeground(.text3)
                    .accessibilityHidden(true)
                TextField(t.string(.notesSearchPlaceholder), text: $query)
                    .textFieldStyle(.plain)
                    .tokenFont(.body)
            }
            .padding(.horizontal, DesignTokens.spacing(8))
            .frame(minHeight: DesignTokens.size(.hitMin))
            .card(radius: .sm, fill: .surface1)
            if let tagFilter, let tag = allTags.first(where: { $0.id == tagFilter }) {
                ChipButton(tag.name, icon: .tag, isActive: true) { self.tagFilter = nil }
                    .help(t.string(.tagFilterAll))
            }
            IconButton(icon: .add, label: t.string(.notesNewButton)) { createBlank() }
            IconMenu(icon: .more, label: t.string(.shellMore)) {
                if !notes.isEmpty {
                    Button {
                        bulkMode.toggle()
                        selectedIds.removeAll()
                    } label: {
                        Label(bulkMode ? t.string(.bulkDone) : t.string(.bulkSelect),
                              systemImage: DesignTokens.icon(.bulkSelect))
                    }
                }
                if !allTags.isEmpty {
                    Menu {
                        Button(t.string(.tagFilterAll)) { tagFilter = nil }
                        Divider()
                        ForEach(allTags) { tag in
                            Button { tagFilter = tag.id } label: {
                                if tagFilter == tag.id { Label(tag.name, systemImage: "checkmark") }
                                else { Text(tag.name) }
                            }
                        }
                    } label: {
                        Label(t.string(.tagFilterMenu), systemImage: DesignTokens.icon(.tag))
                    }
                }
                Divider()
                Button { showingHistory = true } label: {
                    Label(t.string(.toolHistory), systemImage: DesignTokens.icon(.history))
                }
            }
        }
    }

    private var bulkBar: some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            Text("\(selectedIds.count)").tokenFont(.caption).monospacedDigit().tokenForeground(.text2)
            Spacer()
            Button(t.string(.bulkDelete), role: .destructive) { bulkDelete() }
                .buttonStyle(.secondary)
                .disabled(selectedIds.isEmpty)
            Button(t.string(.bulkDone)) { bulkMode = false; selectedIds.removeAll() }
                .buttonStyle(QuietButtonStyle(token: .focus))
        }
        .padding(.horizontal, DesignTokens.spacing(12))
        .padding(.bottom, DesignTokens.spacing(8))
    }

    // MARK: Rows

    private func row(_ note: Note) -> some View {
        let isOpen = note.id != nil && nav.selection.noteId == note.id
        return HStack(alignment: .top, spacing: DesignTokens.spacing(8)) {
            if bulkMode, let id = note.id {
                Image(systemName: selectedIds.contains(id) ? "checkmark.circle.fill" : "circle")
                    .tokenForeground(selectedIds.contains(id) ? .text1 : .text3)
                    .frame(height: DesignTokens.lineHeight(.body))
                    .accessibilityHidden(true)
            }
            TokenIcon(icon: .note, color: isOpen ? .text1 : .text2)
                .frame(height: DesignTokens.lineHeight(.body))
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title.isEmpty ? t.string(.noteUntitled) : note.title)
                    .tokenFont(.body)
                    .fontWeight(isOpen ? .medium : .regular)
                    .tokenForeground(.text1)
                    .lineLimit(1)
                Text("\(originLabel(note.origin)) · \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .tokenFont(.caption)
                    .tokenForeground(.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, DesignTokens.spacing(4))
        .padding(.horizontal, DesignTokens.spacing(4))
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius(.sm), style: .continuous)
                .fill(isOpen ? DesignTokens.color(.surface2) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard let id = note.id else { return }
            if bulkMode {
                if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
            } else {
                nav.openNote(notebookId: note.notebookId, noteId: id)
            }
        }
        .contextMenu {
            Button(t.string(.exportNoteMarkdown)) { exportMarkdown(note) }
            Divider()
            Button(t.string(.deleteButton), role: .destructive) { delete(note) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .listRowSeparator(.hidden)
    }

    private func originLabel(_ origin: NoteOrigin) -> String {
        switch origin {
        case .manual:         return t.string(.noteOriginManual)
        case .chat:           return t.string(.noteOriginChat)
        case .transformation: return t.string(.noteOriginTransformation)
        }
    }

    // MARK: Data

    private func reload() {
        guard let notebookId = notebook.id else { return }
        do {
            notes = try store.notes(notebookId: notebookId)
            allTags = try store.tags()
            var ids: [Int64: Set<Int64>] = [:]
            for note in notes {
                guard let id = note.id else { continue }
                ids[id] = Set(try store.tagsForNote(noteId: id).map(\.id))
            }
            noteTagIds = ids
            if let f = tagFilter, !allTags.contains(where: { $0.id == f }) { tagFilter = nil }
            search(query)
        } catch { errorMessage = String(describing: error) }
    }

    private func search(_ value: String) {
        guard let notebookId = notebook.id,
              !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchHits = nil
            return
        }
        searchHits = ((try? store.searchNotes(notebookId: notebookId, query: value)) ?? []).map(\.noteId)
    }

    private func createBlank() {
        guard let notebookId = notebook.id else { return }
        do {
            let note = try store.createNote(notebookId: notebookId, title: t.string(.noteUntitled), bodyMd: "")
            reload()
            if let id = note.id { nav.openNote(notebookId: notebookId, noteId: id) }
        } catch { errorMessage = String(describing: error) }
    }

    /// B6 — delete every selected note.
    private func bulkDelete() {
        do {
            for id in selectedIds { try store.deleteNote(id: id) }
            if let open = nav.selection.noteId, selectedIds.contains(open) { nav.back() }
            selectedIds.removeAll()
            bulkMode = false
            reload()
        } catch { errorMessage = String(describing: error) }
    }

    private func delete(_ note: Note) {
        guard let id = note.id else { return }
        do {
            try store.deleteNote(id: id)
            if nav.selection.noteId == id { nav.back() }
            reload()
        } catch { errorMessage = String(describing: error) }
    }

    /// B1 — export a single note to a Markdown file.
    private func exportMarkdown(_ note: Note) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (note.title.isEmpty ? "note" : note.title) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(ExportService.exportNoteMarkdown(note).utf8).write(to: url)
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
