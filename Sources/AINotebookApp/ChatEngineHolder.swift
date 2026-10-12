import SwiftUI
import AINotebookCore

/// Shares one chat engine, its window-local context previews and the native
/// original-file resolver between ChatView and the notes chat panel.
@MainActor
final class ChatEngineHolder: ObservableObject {
    let engine: ChatEngine
    let previews: ContextPreviewSession
    let originals: any CitationOriginalResolving

    init(engine: ChatEngine, originals: any CitationOriginalResolving) {
        self.engine = engine
        self.previews = engine.previews
        self.originals = originals
    }
}
