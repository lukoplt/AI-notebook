import AINotebookCore
import SwiftUI

/// Collapsible right panel (spec §2.3): segmented tabs over Sources, Notes,
/// Context and Citations (document mode: "Chat about note" replaces Context).
struct RightPanelView: View {
    let nav: NavigationState
    let chat: ChatViewModel

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    private var t: AppText { settings.text }

    private var notebook: Notebook? {
        store.notebooks.first(where: { $0.id == nav.currentNotebookId })
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelSegmentedControl(
                selection: Binding(get: { nav.visibleSegment }, set: { nav.panelSegment = $0 }),
                items: ShellNavigation.segments(documentMode: nav.selection.isDocument).map { ($0, title($0)) }
            )
            .padding(DesignTokens.spacing(12))
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DesignTokens.color(.surface1))
    }

    private func title(_ segment: ShellPanel) -> String {
        switch segment {
        case .sources: t.string(.sources)
        case .notes: t.string(.notes)
        case .context: t.string(.panelContext)
        case .citations: t.string(.chatCitationsSectionTitle)
        case .noteChat: t.string(.panelNoteChat)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let notebook, let notebookId = notebook.id {
            switch nav.visibleSegment {
            case .sources:
                SourcesPanel(notebook: notebook).id(notebookId)
            case .notes:
                NotesPanel(notebook: notebook, nav: nav).id(notebookId)
            case .context:
                ContextPanel(model: chat)
            case .citations:
                CitationsPanel(model: chat, notebookId: notebookId)
            case .noteChat:
                NotesChatPanel(notebook: notebook,
                               currentNote: nav.selection.noteId.flatMap { try? store.note(id: $0) })
            }
        } else {
            Color.clear
        }
    }
}
