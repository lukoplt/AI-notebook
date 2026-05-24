import SwiftUI
import AINotebookCore

struct NoteHistorySheet: View {

    let noteId: Int64

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Binding var isPresented: Bool

    @State private var versions: [NoteVersion] = []
    @State private var selection: Int64?
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.historySheetTitle)).font(.title2).bold()
            HSplitView {
                list.frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
                preview.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 360)
            HStack {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 460)
        .task(id: noteId) { await reload() }
    }

    @ViewBuilder
    private var list: some View {
        if versions.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.historyEmpty)).foregroundStyle(.secondary)
                Spacer()
            }
        } else {
            List(selection: $selection) {
                ForEach(versions.reversed()) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(reasonLabel(v.reason)).font(.headline)
                        Text(v.savedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(v.id ?? -1)
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let id = selection, let v = versions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 8) {
                Text(v.title).font(.title3).bold()
                ScrollView {
                    Text(v.bodyMd)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                HStack {
                    Spacer()
                    Button(t.string(.historyRestoreButton)) {
                        Task { await restore(versionId: id) }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        } else {
            VStack {
                Spacer()
                Text(t.string(.historyEmpty)).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func reasonLabel(_ r: NoteVersionReason) -> String {
        switch r {
        case .autosave: return t.string(.historyReasonAutosave)
        case .manual:   return t.string(.editorStatusSaved)
        case .restore:  return t.string(.historyReasonRestore)
        }
    }

    @MainActor
    private func reload() async {
        do {
            versions = try store.noteVersions(noteId: noteId)
            if selection == nil { selection = versions.last?.id }
        } catch { errorMessage = String(describing: error) }
    }

    private func restore(versionId: Int64) async {
        do {
            try store.restoreNoteVersion(versionId: versionId)
            isPresented = false
        } catch { errorMessage = String(describing: error) }
    }
}
