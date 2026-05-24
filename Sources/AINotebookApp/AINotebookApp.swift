import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore
    @StateObject private var ollama: OllamaClientHolder
    @StateObject private var ingestion: IngestionServiceHolder
    @StateObject private var embedderHolder: EmbedderHolder
    @StateObject private var onboarding: OnboardingViewModel
    @StateObject private var chatHolder: ChatEngineHolder
    @StateObject private var transformationHolder: TransformationEngineHolder
    @StateObject private var noteJump = NoteJumpCoordinator()

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        let store: NotebookStore
        do {
            let path = try StorePath.production()
            store = try NotebookStore(path: path)
        } catch {
            fatalError("Failed to open AINotebook database: \(error)")
        }
        _store = StateObject(wrappedValue: store)

        let client = OllamaClient()
        _ollama = StateObject(wrappedValue: OllamaClientHolder(client: client))

        let embedder = Embedder(
            store: store,
            client: client,
            model: settings.selectedEmbeddingModel
        )
        let worker = EmbeddingWorker(embedder: embedder)
        _embedderHolder = StateObject(wrappedValue: EmbedderHolder(embedder: embedder, worker: worker))

        let ingestion = IngestionService(store: store, onChunksWritten: {
            await worker.kick()
        })
        _ingestion = StateObject(wrappedValue: IngestionServiceHolder(service: ingestion))
        _onboarding = StateObject(wrappedValue: OnboardingViewModel(
            client: client,
            settings: settings
        ))

        let retriever = Retriever(
            store: store,
            client: client,
            model: settings.selectedEmbeddingModel
        )
        let engine = ChatEngine(
            store: store,
            retriever: retriever,
            chat: client,
            chatModel: settings.selectedChatModel
        )
        _chatHolder = StateObject(wrappedValue: ChatEngineHolder(engine: engine))

        let txEngine = TransformationEngine(
            store: store, chat: client, chatModel: settings.selectedChatModel
        )
        _transformationHolder = StateObject(wrappedValue: TransformationEngineHolder(engine: txEngine))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(ollama)
                .environmentObject(ingestion)
                .environmentObject(embedderHolder)
                .environmentObject(onboarding)
                .environmentObject(chatHolder)
                .environmentObject(transformationHolder)
                .environmentObject(noteJump)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                EmptyView()
            }
        }
    }
}

/// `OllamaClient` itself is a final class, so it can't be `@StateObject`'d
/// directly without `ObservableObject` conformance — wrap it in a holder.
@MainActor
final class OllamaClientHolder: ObservableObject {
    let client: OllamaClient
    init(client: OllamaClient) { self.client = client }
}
