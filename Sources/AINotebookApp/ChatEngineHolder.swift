import SwiftUI
import AINotebookCore

@MainActor
final class ChatEngineHolder: ObservableObject {
    let engine: ChatEngine
    init(engine: ChatEngine) { self.engine = engine }
}
