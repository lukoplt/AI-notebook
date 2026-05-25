import SwiftUI
import AINotebookCore

struct TransformationHistorySheet: View {

    let notebook: Notebook
    @Binding var isPresented: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var noteJump: NoteJumpCoordinator
    @EnvironmentObject private var tabSwitch: TabSwitchCoordinator

    @State private var rows: [Row] = []
    @State private var errorMessage: String?

    struct Row: Identifiable, Hashable {
        let id: Int64
        let templateName: String
        let sourceTitle: String
        let noteId: Int64?
        let noteTitle: String
        let ranAt: Date
    }

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.aiToolsHistoryTitle)).font(.title2).bold()
            if rows.isEmpty {
                VStack {
                    Spacer()
                    Text(t.string(.aiToolsHistoryEmpty)).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                List {
                    ForEach(rows) { r in
                        Button {
                            jump(to: r)
                        } label: {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.templateName).font(.headline)
                                    Text(r.sourceTitle).font(.callout).foregroundStyle(.secondary)
                                    Text(r.ranAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if r.noteId == nil {
                                    Text("(deleted)").font(.caption).foregroundStyle(.red)
                                } else {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(r.noteId == nil)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 360)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
        .task(id: notebook.id) { await reload() }
    }

    @MainActor
    private func reload() async {
        do {
            let runs = try store.transformationRuns()
            let transformations = try store.transformations()
            let txByID: [Int64: Transformation] = Dictionary(
                uniqueKeysWithValues: transformations.compactMap { tx in
                    tx.id.map { ($0, tx) }
                }
            )
            let notes = try store.notes(notebookId: notebook.id!)
            let notesByID: [Int64: Note] = Dictionary(
                uniqueKeysWithValues: notes.compactMap { n in
                    n.id.map { ($0, n) }
                }
            )
            let sources = try store.sourcesIncludingShadow(notebookId: notebook.id!)
            let sourcesByID: [Int64: Source] = Dictionary(
                uniqueKeysWithValues: sources.compactMap { s in
                    s.id.map { ($0, s) }
                }
            )

            rows = runs.compactMap { run -> Row? in
                guard let runId = run.id else { return nil }
                let note: Note? = run.resultNoteId.flatMap { notesByID[$0] }
                let source: Source? = run.sourceId.flatMap { sourcesByID[$0] }
                let belongsToNotebook = (note?.notebookId == notebook.id) ||
                    (source?.notebookId == notebook.id)
                guard belongsToNotebook else { return nil }
                let txName = txByID[run.transformationId]?.name ?? "(unknown)"
                let srcTitle = source?.title
                    ?? (run.sourceId == nil ? "(notebook scope)" : "(deleted)")
                return Row(
                    id: runId,
                    templateName: txName,
                    sourceTitle: srcTitle,
                    noteId: note?.id,
                    noteTitle: note?.title ?? "(deleted)",
                    ranAt: run.ranAt
                )
            }
            .sorted { $0.ranAt > $1.ranAt }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func jump(to row: Row) {
        guard let nid = row.noteId else { return }
        isPresented = false
        tabSwitch.request(.notes)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            noteJump.request(noteId: nid)
        }
    }
}
