import AINotebookCore
import SwiftUI

/// Menu-bar commands of the shell (⌘N new chat, ⇧⌘N new notebook, ⌘K search,
/// ⌘[ back from a document, ⌥⌘0 right panel). They act on the focused window.
struct ShellCommands: Commands {
    @ObservedObject var settings: AppSettings
    @FocusedValue(\.shell) private var shell

    private var t: AppText { settings.text }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(t.string(.shellNewChat)) { shell?.newChat() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(shell == nil)
            Button(t.string(.shellNewNotebook)) { shell?.showNewNotebook = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(shell == nil)
        }
        CommandGroup(after: .textEditing) {
            Button(t.string(.globalSearchTitle)) { shell?.showSearch = true }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(shell == nil)
        }
        CommandGroup(after: .sidebar) {
            Button(t.string(.shellTogglePanel)) { shell?.togglePanel() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(shell == nil)
            Button(t.string(.shellBack)) { shell?.back() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(shell?.selection.isDocument != true)
        }
    }
}
