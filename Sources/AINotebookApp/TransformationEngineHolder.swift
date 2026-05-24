import SwiftUI
import AINotebookCore

@MainActor
final class TransformationEngineHolder: ObservableObject {
    let engine: TransformationEngine
    init(engine: TransformationEngine) { self.engine = engine }
}
