import SwiftUI
import AINotebookCore

struct NotesView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    @State private var notes: [Note] = []
    @State private var selection: Int64?
    @State private var draftTitle: String = ""
    @State private var draftBody:  String = ""
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: notebook.id) { await reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(t.string(.notesSectionTitle))
                    .font(.title3).bold()
                Spacer()
                Button(t.string(.notesNewButton)) {
                    Task { await createBlank() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if notes.isEmpty {
                Text(t.string(.notesEmptyState))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 24)
            } else {
                List(selection: $selection) {
                    ForEach(notes) { note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.title.isEmpty ? t.string(.noteUntitled) : note.title)
                                .font(.headline)
                            Text(originLabel(note.origin))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(note.id ?? -1)
                    }
                }
                .listStyle(.sidebar)
                .onChange(of: selection) { _, newId in
                    if let id = newId, let n = notes.first(where: { $0.id == id }) {
                        draftTitle = n.title
                        draftBody  = n.bodyMd
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red).padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selection, notes.contains(where: { $0.id == id }) {
            NoteEditor(
                title: $draftTitle,
                bodyMd: $draftBody,
                language: settings.language,
                onSave: { Task { await save(id: id) } }
            )
            .padding(16)
        } else {
            VStack {
                Spacer()
                Text(t.string(.notesEmptyState))
                    .foregroundStyle(.secondary)
                Spacer()
            }
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
    private func reload() async {
        do {
            notes = try store.notes(notebookId: notebook.id!)
            if selection == nil { selection = notes.first?.id }
            if let id = selection, let n = notes.first(where: { $0.id == id }) {
                draftTitle = n.title
                draftBody  = n.bodyMd
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func createBlank() async {
        do {
            let n = try store.createNote(
                notebookId: notebook.id!,
                title: t.string(.noteUntitled),
                bodyMd: ""
            )
            await reload()
            selection = n.id
            draftTitle = n.title
            draftBody = ""
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func save(id: Int64) async {
        do {
            try store.updateNote(id: id, title: draftTitle, bodyMd: draftBody)
            await reload()
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
