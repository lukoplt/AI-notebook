#if DEBUG
import AINotebookCore
import SwiftUI

/// Debug-only screenshot states: `-AINotebookQANotebook <name>` selects a
/// notebook and `-AINotebookQAScreen <screen>` opens one state
/// (newchat, note, citations, context, sources, runtool, settings).
/// `-AINotebookQAIndexing <phase>` replaces the live indexing status
/// (`IndexingStatusModel.qaPhases`); `-AINotebookRenderIndexingStrips <dir>`
/// renders the Sources status strip of every phase to PNGs and exits.
struct QAScreen: ViewModifier {
    let nav: NavigationState
    let chat: ChatViewModel

    @EnvironmentObject private var store: NotebookStore
    @Environment(\.openSettings) private var openSettings

    static var screen: String? { UserDefaults.standard.string(forKey: "AINotebookQAScreen") }

    func body(content: Content) -> some View {
        content.task {
            let defaults = UserDefaults.standard
            if let name = defaults.string(forKey: "AINotebookQANotebook"),
               let id = store.notebooks.first(where: { $0.name == name })?.id {
                nav.openNotebook(id)
            }
            guard let screen = Self.screen else { return }
            try? await Task.sleep(for: .milliseconds(800))
            switch screen {
            case "newchat":
                nav.newChat()
            case "note":
                if let id = nav.currentNotebookId, let note = (try? store.notes(notebookId: id))?.last, let nid = note.id {
                    nav.openNote(notebookId: id, noteId: nid)
                }
            case "citations":
                if let answer = chat.lastAssistantMessage, let first = answer.citations.first {
                    chat.focusCitation(in: answer, marker: first.marker)
                }
                nav.showPanel(.citations)
            case "context":
                chat.input = "Jaká je výpovědní lhůta servisní smlouvy?"
                chat.startPreparingDraft()
                nav.showPanel(.context)
            case "sources":
                nav.showPanel(.sources)
            case "notes":
                nav.showPanel(.notes)
            case "runtool":
                nav.runToolRequest = RunToolRequest(transformationId: nil)
            case "settings":
                openSettings()
            default:
                break
            }
        }
    }
}
#endif
