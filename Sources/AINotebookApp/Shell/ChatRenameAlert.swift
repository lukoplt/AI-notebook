import AINotebookCore
import SwiftUI

/// The chat a rename alert is open for (sidebar context menu or top bar "…").
struct ChatRenameTarget: Identifiable, Equatable {
    let id: Int64
    let notebookId: Int64
    let title: String
}

/// "Rename chat" alert with the current title prefilled. Blank or unchanged
/// titles keep the stored one (Core `ChatSessionState.renamedTitle`).
private struct ChatRenameAlert: ViewModifier {
    @Binding var target: ChatRenameTarget?
    let nav: NavigationState
    let onRenamed: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @State private var text = ""
    /// Presented only after `text` holds the current title, so the alert
    /// field opens prefilled.
    @State private var presented = false

    func body(content: Content) -> some View {
        let t = settings.text
        content
            .onChange(of: target) { _, newTarget in
                if let newTarget { text = newTarget.title }
                presented = newTarget != nil
            }
            .alert(t.string(.renameChatTitle), isPresented: $presented) {
                TextField(t.string(.renameChatTitle), text: $text)
                Button(t.string(.save)) {
                    if let target, nav.renameChat(target.id, notebookId: target.notebookId, to: text, store: store) {
                        onRenamed()
                    }
                    target = nil
                }
                .keyboardShortcut(.defaultAction)
                Button(t.string(.cancel), role: .cancel) { target = nil }
            }
            .onChange(of: presented) { _, isPresented in
                if !isPresented { target = nil }
            }
    }
}

extension View {
    func chatRenameAlert(_ target: Binding<ChatRenameTarget?>, nav: NavigationState,
                         onRenamed: @escaping () -> Void = {}) -> some View {
        modifier(ChatRenameAlert(target: target, nav: nav, onRenamed: onRenamed))
    }
}
