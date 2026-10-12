import AINotebookCore
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// One open note's editing state. Saves go straight to the store; leaving the
/// document flushes pending edits synchronously so nothing is lost.
@MainActor
@Observable
final class NoteDocumentModel {
    let noteId: Int64
    private(set) var note: Note?
    var title = "" {
        didSet { if oldValue != title, loaded { markDirty() } }
    }
    private(set) var body = ""
    private(set) var dirty = false
    var errorMessage: String?
    /// Bumped after a history restore so the editor reloads its content.
    private(set) var contentRevision = 0

    @ObservationIgnored let autoSave: AutoSaveController
    @ObservationIgnored private var store: NotebookStore?
    @ObservationIgnored private var loaded = false

    init(noteId: Int64) {
        self.noteId = noteId
        let sink = SaveSink()
        autoSave = AutoSaveController(save: { markdown in sink.deliver(markdown) })
        sink.model = self
    }

    func load(store: NotebookStore) {
        self.store = store
        loaded = false
        do {
            note = try store.note(id: noteId)
            title = note?.title ?? ""
            body = note?.bodyMd ?? ""
        } catch { errorMessage = String(describing: error) }
        loaded = true
    }

    /// Editor change (Markdown from TipTap).
    func edited(_ markdown: String) {
        body = markdown
        markDirty()
    }

    private func markDirty() {
        dirty = true
        autoSave.noteDidChange(body)
    }

    func saveNow() { autoSave.manualSave() }

    /// Synchronous save of pending edits (leaving the document, closing).
    func flush() {
        guard dirty else { return }
        write(body: body)
    }

    fileprivate func write(body markdown: String) {
        guard let store else { return }
        do {
            try store.updateNote(id: noteId, title: title, bodyMd: markdown)
            if markdown == body { dirty = false }
            note = try store.note(id: noteId)
        } catch { errorMessage = String(describing: error) }
    }

    /// After a history restore: reload from the store and refresh the editor.
    func reloadAfterRestore() {
        guard let store else { return }
        load(store: store)
        dirty = false
        contentRevision += 1
    }
}

/// Routes autosave callbacks (a `@Sendable` closure) back to the model.
private final class SaveSink: @unchecked Sendable {
    @MainActor weak var model: NoteDocumentModel?

    func deliver(_ markdown: String) {
        Task { @MainActor [weak self] in self?.model?.write(body: markdown) }
    }
}

/// A note opened in the main area (spec §2.4): action bar (back, save state,
/// tags, history, export Markdown/PDF), editable title and the TipTap editor
/// centered at the conversation width.
struct NoteDocumentView: View {
    let noteId: Int64
    let nav: NavigationState

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var attachmentsHolder: AttachmentStoreHolder

    @State private var model: NoteDocumentModel
    @State private var bridge = EditorBridge()
    @State private var loadFailed = false
    @State private var showingHistory = false
    @State private var showingTags = false
    @State private var assignedTags: [Tag] = []
    @State private var allTags: [Tag] = []

    private var t: AppText { settings.text }

    init(noteId: Int64, nav: NavigationState) {
        self.noteId = noteId
        self.nav = nav
        _model = State(initialValue: NoteDocumentModel(noteId: noteId))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            actionBar
                .padding(.horizontal, DesignTokens.spacing(16))
                .frame(height: DesignTokens.size(.topBar))
            Hairline()
            VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
                TextField(t.string(.noteTitlePlaceholder), text: $model.title)
                    .textFieldStyle(.plain)
                    .tokenFont(.title)
                    .tokenForeground(.text1)
                if let error = model.errorMessage {
                    Label(error, systemImage: DesignTokens.icon(.error))
                        .tokenFont(.caption)
                        .tokenForeground(.danger)
                }
                if loadFailed {
                    Label(t.string(.editorFailedToLoad), systemImage: DesignTokens.icon(.error))
                        .tokenFont(.body)
                        .tokenForeground(.danger)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.note != nil {
                    EditorWebView(
                        initialMarkdown: model.body,
                        noteId: noteId,
                        noteUuid: model.note?.noteUuid ?? "",
                        attachments: attachmentsHolder.store,
                        bridge: bridge,
                        onChange: { markdown in model.edited(markdown) },
                        onLoadFailed: { loadFailed = true }
                    )
                    // editor.css pads its content by 16 px; pull it back so the
                    // text lines up with the title above.
                    .padding(.horizontal, -DesignTokens.spacing(16))
                    .padding(.top, -DesignTokens.spacing(8))
                    .id(model.contentRevision)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: DesignTokens.size(.conversationMax))
            .padding(.horizontal, DesignTokens.spacing(24))
            .padding(.top, DesignTokens.spacing(24))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            model.load(store: store)
            reloadTags()
        }
        .onDisappear { model.flush() }
        .sheet(isPresented: $showingHistory, onDismiss: { model.reloadAfterRestore() }) {
            NoteHistorySheet(noteId: noteId, isPresented: $showingHistory)
                .environmentObject(settings)
                .environmentObject(store)
        }
    }

    // MARK: Action bar

    private var actionBar: some View {
        HStack(spacing: DesignTokens.spacing(8)) {
            IconButton(icon: .back, label: t.string(.shellBack)) { nav.back() }
            SaveStatusLabel(autoSave: model.autoSave, text: t)
            Spacer(minLength: DesignTokens.spacing(8))
            Button { model.saveNow() } label: { Text(t.string(.save)) }
                .buttonStyle(QuietButtonStyle())
                .keyboardShortcut("s", modifiers: .command)
            IconButton(icon: .tag, label: t.string(.tagsLabel), isActive: !assignedTags.isEmpty) {
                showingTags = true
            }
            .popover(isPresented: $showingTags, arrowEdge: .bottom) {
                TagChipsEditor(
                    assigned: assignedTags,
                    all: allTags,
                    onAdd: { setTags(assignedTags.map(\.id) + [$0]) },
                    onRemove: { id in setTags(assignedTags.map(\.id).filter { $0 != id }) },
                    onCreate: { name in
                        if let tag = try? store.createTag(name: name) { setTags(assignedTags.map(\.id) + [tag.id]) }
                    }
                )
                .padding(DesignTokens.spacing(16))
                .frame(width: DesignTokens.size(.panelMin))
            }
            IconButton(icon: .history, label: t.string(.historyButton)) {
                model.flush()
                showingHistory = true
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            IconMenu(icon: .export, label: t.string(.documentExport)) {
                Button(t.string(.exportNoteMarkdown)) { exportMarkdown() }
                Button(t.string(.documentExportPDF)) { Task { await exportPDF() } }
            }
        }
    }

    // MARK: Tags

    private func reloadTags() {
        allTags = (try? store.tags()) ?? []
        assignedTags = (try? store.tagsForNote(noteId: noteId)) ?? []
    }

    private func setTags(_ ids: [Int64]) {
        try? store.setNoteTags(noteId: noteId, tagIds: Array(Set(ids)))
        reloadTags()
    }

    // MARK: Export

    private var fileBaseName: String {
        let trimmed = model.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "note" : trimmed
    }

    /// B1 — the note as a Markdown file.
    private func exportMarkdown() {
        model.flush()
        guard let note = model.note,
              let url = NotebookActions.savePanelURL(suggestedName: fileBaseName + ".md",
                                                     type: UTType(filenameExtension: "md") ?? .plainText)
        else { return }
        do {
            try Data(ExportService.exportNoteMarkdown(note).utf8).write(to: url)
        } catch { model.errorMessage = String(describing: error) }
    }

    /// M-2 — the rendered note as PDF (WKWebView.createPDF).
    private func exportPDF() async {
        guard let url = NotebookActions.savePanelURL(suggestedName: fileBaseName + ".pdf", type: .pdf) else { return }
        do {
            let data = try await bridge.makePDF()
            try data.write(to: url)
        } catch { model.errorMessage = String(describing: error) }
    }
}

/// Saved / Saving / Unsaved / Error label of the autosave controller.
private struct SaveStatusLabel: View {
    @ObservedObject var autoSave: AutoSaveController
    let text: AppText

    var body: some View {
        Group {
            switch autoSave.status {
            case .saved:
                Label(text.string(.editorStatusSaved), systemImage: DesignTokens.icon(.success))
                    .tokenForeground(.text3)
            case .saving:
                Label(text.string(.editorStatusSaving), systemImage: DesignTokens.icon(.scan))
                    .tokenForeground(.text3)
            case .unsaved:
                Label(text.string(.editorStatusUnsaved), systemImage: DesignTokens.icon(.edit))
                    .tokenForeground(.text2)
            case .error(let message):
                Label("\(text.string(.editorStatusError)) — \(message)", systemImage: DesignTokens.icon(.error))
                    .tokenForeground(.danger)
            }
        }
        .tokenFont(.caption)
        .lineLimit(1)
    }
}
