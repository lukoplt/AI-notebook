import AINotebookCore
import SwiftUI

/// Main area: the chat thread, a note document, or an empty state.
struct MainAreaView: View {
    let nav: NavigationState
    let chat: ChatViewModel

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var folderWatch: FolderWatchController

    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        Group {
            if store.notebooks.isEmpty {
                EmptyStateView(title: t.string(.shellEmptyAppTitle), actions: [
                    EmptyStateAction(title: t.string(.addFolderButton), icon: .addFolder, isPrimary: true) {
                        Task { await openFolderAsNotebook() }
                    },
                    EmptyStateAction(title: t.string(.shellNewNotebook), icon: .add) {
                        nav.showNewNotebook = true
                    },
                ])
            } else {
                switch nav.selection {
                case .chat(let nb, _), .newChat(.some(let nb)):
                    if let notebook = store.notebooks.first(where: { $0.id == nb }) {
                        ChatThreadView(model: chat, nav: nav, notebook: notebook)
                    }
                case .newChat(.none):
                    EmptyStateView(title: t.string(.noNotebookSelected))
                case .note(_, let noteId):
                    NoteDocumentView(noteId: noteId, nav: nav).id(noteId)
                }
            }
        }
        // An explicit minimum keeps wide content from squeezing the sidebar and panel.
        .frame(minWidth: DesignTokens.size(.panelMin), maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.color(.bg))
        .shellTopBar(nav: nav, chat: chat)
        .alert(errorMessage ?? "", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button(t.string(.doneButton)) { errorMessage = nil }
        }
    }

    private func openFolderAsNotebook() async {
        do {
            guard let id = try await NotebookActions.openFolderAsNotebook(
                store: store, runtime: folderWatch.runtime) else { return }
            nav.reloadSessions(store: store)
            nav.newChat(in: id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
