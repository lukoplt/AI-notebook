import SwiftUI
import AINotebookCore

@MainActor
final class EmbedderHolder: ObservableObject {
    let embedder: Embedder
    let worker: EmbeddingWorker
    init(embedder: Embedder, worker: EmbeddingWorker) {
        self.embedder = embedder
        self.worker = worker
    }
}
