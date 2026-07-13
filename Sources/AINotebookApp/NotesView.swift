import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AINotebookCore

private struct NoteIdBox: Identifiable, Hashable {
    let id: Int64
}

struct NotesView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var attachmentsHolder: AttachmentStoreHolder

    @State private var notes: [Note] = []
    @State private var selection: Int64?
    @State private var draftTitle: String = ""
    @State private var draftBody:  String = ""
    @State private var errorMessage: String?
    @State private var historyNoteId: Int64?
    @StateObject private var editorCoord = NoteEditorCoordinator()
    @State private var pendingSelection: Int64?
    @State private var showUnsavedAlert = false
    @State private var bulkMode = false
    @State private var selectedNoteIds: Set<Int64> = []

    private var t: AppText { settings.text }

    private var currentNote: Note? {
        guard let id = selection else { return nil }
        return notes.first(where: { $0.id == id })
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 320, maxHeight: .infinity)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            NotesChatPanel(notebook: notebook, currentNote: currentNote)
                .frame(minWidth: 280, idealWidth: 340, maxWidth: 440, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: notebook.id) { await reload() }
        .onReceive(noteJump.$target.compactMap { $0 }) { id in
            if notes.contains(where: { $0.id == id }) {
                attemptSelect(id)
                noteJump.clear()
            }
        }
        .alert(t.string(.unsavedChangesTitle), isPresented: $showUnsavedAlert) {
            Button(t.string(.unsavedSaveButton)) {
                editorCoord.flushPendingSave?()
                commitPendingSelection()
            }
            Button(t.string(.unsavedDiscardButton), role: .destructive) {
                editorCoord.hasUnsavedChanges = false
                commitPendingSelection()
            }
            Button(t.string(.cancelButton), role: .cancel) {
                pendingSelection = nil
            }
        } message: {
            Text(t.string(.unsavedChangesMessage))
        }
        .sheet(
            item: Binding<NoteIdBox?>(
                get: { historyNoteId.map { NoteIdBox(id: $0) } },
                set: { historyNoteId = $0?.id }
            ),
            onDismiss: { Task { await reload() } }
        ) { box in
            NoteHistorySheet(
                noteId: box.id,
                isPresented: Binding(
                    get: { historyNoteId != nil },
                    set: { if !$0 { historyNoteId = nil } }
                )
            )
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.string(.notesSectionTitle)).font(.title3).bold()
                Spacer()
                if !notes.isEmpty {
                    Button(bulkMode ? t.string(.bulkDone) : t.string(.bulkSelect)) {
                        bulkMode.toggle()
                        selectedNoteIds.removeAll()
                    }
                }
                Button(t.string(.notesNewButton)) {
                    Task { await createBlank() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if bulkMode && !selectedNoteIds.isEmpty {
                HStack {
                    Text("\(selectedNoteIds.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t.string(.bulkDelete), role: .destructive) { bulkDeleteNotes() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 12)
            }
            if notes.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "note.text")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(t.string(.notesEmptyState))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                    Button(t.string(.notesNewButton)) {
                        Task { await createBlank() }
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding<Int64?>(
                    get: { selection },
                    set: { newValue in attemptSelect(newValue) }
                )) {
                    ForEach(notes) { note in
                        HStack(spacing: 8) {
                            if bulkMode, let id = note.id {
                                Image(systemName: selectedNoteIds.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedNoteIds.contains(id) ? Color.accentColor : .secondary)
                                    .onTapGesture { toggleBulk(id) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.title.isEmpty ? t.string(.noteUntitled) : note.title)
                                    .font(.headline)
                                Text(originLabel(note.origin))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(note.id ?? -1)
                        .contextMenu {
                            Button(t.string(.exportNoteMarkdown)) { exportNoteMarkdown(note) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, notes.contains(where: { $0.id == id }) {
            NoteWYSIWYGEditor(
                title: $draftTitle,
                bodyMd: $draftBody,
                language: settings.language,
                noteId: id,
                noteUuid: notes.first(where: { $0.id == id })?.noteUuid ?? "",
                attachments: attachmentsHolder.store,
                coordinator: editorCoord,
                onShowHistory: { historyNoteId = id },
                onSave: { _ in
                    Task { @MainActor in await save(id: id) }
                }
            )
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(id)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "doc.text")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(t.string(.notesEmptyState))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func originLabel(_ o: NoteOrigin) -> String {
        switch o {
        case .manual:         return t.string(.noteOriginManual)
        case .chat:           return t.string(.noteOriginChat)
        case .transformation: return t.string(.noteOriginTransformation)
        }
    }

    @MainActor
    private func toggleBulk(_ id: Int64) {
        if selectedNoteIds.contains(id) { selectedNoteIds.remove(id) } else { selectedNoteIds.insert(id) }
    }

    /// B6 — delete every selected note.
    private func bulkDeleteNotes() {
        do {
            for id in selectedNoteIds { try store.deleteNote(id: id) }
            if let sel = selection, selectedNoteIds.contains(sel) { selection = nil }
            selectedNoteIds.removeAll()
            bulkMode = false
            Task { await reload() }
        } catch { errorMessage = String(describing: error) }
    }

    /// B1 — export a single note to a Markdown file.
    private func exportNoteMarkdown(_ note: Note) {
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

    private func reload() async {
        do {
            notes = try store.notes(notebookId: notebook.id!)
            if selection == nil { selection = notes.first?.id }
            if let id = selection, let n = notes.first(where: { $0.id == id }) {
                draftTitle = n.title
                draftBody  = n.bodyMd
            }
        } catch { errorMessage = String(describing: error) }
    }

    private func createBlank() async {
        do {
            let n = try store.createNote(
                notebookId: notebook.id!,
                title: t.string(.noteUntitled),
                bodyMd: ""
            )
            await reload()
            attemptSelect(n.id)
        } catch { errorMessage = String(describing: error) }
    }

    private func save(id: Int64) async {
        do {
            try store.updateNote(id: id, title: draftTitle, bodyMd: draftBody)
            await reload()
        } catch { errorMessage = String(describing: error) }
    }

    /// Intercept selection changes: if the active editor has unsaved
    /// changes and the target differs, present the unsaved-changes alert
    /// before switching.
    private func attemptSelect(_ newValue: Int64?) {
        if editorCoord.hasUnsavedChanges, newValue != selection {
            pendingSelection = newValue
            showUnsavedAlert = true
            return
        }
        applySelection(newValue)
    }

    private func commitPendingSelection() {
        let target = pendingSelection
        pendingSelection = nil
        applySelection(target)
    }

    private func applySelection(_ newValue: Int64?) {
        selection = newValue
        if let id = newValue, let n = notes.first(where: { $0.id == id }) {
            draftTitle = n.title
            draftBody  = n.bodyMd
        } else if newValue == nil {
            draftTitle = ""
            draftBody = ""
        }
    }
}
