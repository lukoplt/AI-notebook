import AINotebookCore
import SwiftUI

/// Empty chat (spec §2.2): "What are we working on?", the notebook picker
/// (new chat only), the composer and quiet quick actions.
struct NewChatEmptyState: View {
    let model: ChatViewModel
    let nav: NavigationState
    let notebook: Notebook
    let showsNotebookPicker: Bool

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var folderWatch: FolderWatchController
    @State private var error: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: DesignTokens.spacing(16)) {
            Spacer(minLength: DesignTokens.spacing(32))
            Text(t.string(.chatEmptyTitle))
                .tokenFont(.title)
                .tokenForeground(.text1)
            if showsNotebookPicker {
                ChipMenu(title: notebook.name, icon: .notebook,
                         accessibilityLabel: "\(t.string(.chooseNotebook)): \(notebook.name)") {
                    ForEach(store.notebooks) { candidate in
                        Button { nav.newChat(in: candidate.id) } label: {
                            if candidate.id == notebook.id { Label(candidate.name, systemImage: "checkmark") }
                            else { Text(candidate.name) }
                        }
                    }
                    Divider()
                    Button(t.string(.shellNewNotebook)) { nav.showNewNotebook = true }
                    Button(t.string(.openFolderAsNotebook)) { Task { await openFolder() } }
                }
            }
            if let notebookId = notebook.id {
                ChatComposer(model: model, nav: nav, notebookId: notebookId,
                             autoFocus: true, showsQuickActions: true)
                    .padding(.top, DesignTokens.spacing(8))
            }
            if let message = model.errorMessage {
                ChatErrorRow(message: message, retryTitle: t.string(.chatRetry),
                             onRetry: model.retry == nil ? nil : { Task { await model.performRetry() } })
            }
            Spacer(minLength: DesignTokens.spacing(32))
            Spacer(minLength: DesignTokens.spacing(32))
        }
        .frame(maxWidth: DesignTokens.size(.conversationMax))
        .padding(.horizontal, DesignTokens.spacing(24))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t.string(.doneButton)) { error = nil }
        }
    }

    private func openFolder() async {
        do {
            guard let id = try await NotebookActions.openFolderAsNotebook(
                store: store, runtime: folderWatch.runtime) else { return }
            nav.reloadSessions(store: store)
            nav.newChat(in: id)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
