import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore
    @StateObject private var ollama: OllamaClientHolder
    @StateObject private var routerHolder: ProviderRouterHolder
    @StateObject private var ingestion: IngestionServiceHolder
    @StateObject private var embedderHolder: EmbedderHolder
    @StateObject private var onboarding: OnboardingViewModel
    @StateObject private var chatHolder: ChatEngineHolder
    @StateObject private var transformationHolder: TransformationEngineHolder
    @StateObject private var attachmentsHolder: AttachmentStoreHolder
    @StateObject private var noteJump = NoteJumpCoordinator()
    @StateObject private var tabSwitch = TabSwitchCoordinator()
    @StateObject private var updates: UpdateService

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        let updates = UpdateService(settings: settings)
        _updates = StateObject(wrappedValue: updates)

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

        let secrets = KeychainSecretStore()
        let selection = DefaultsProviderSelection()
        let router = ProviderRouter(store: store, secrets: secrets, selection: selection)
        _routerHolder = StateObject(wrappedValue: ProviderRouterHolder(
            router: router, selection: selection, secrets: secrets
        ))

        let embedder = Embedder(
            store: store,
            client: router,
            modelKey: { selection.embeddingKey() }
        )
        let worker = EmbeddingWorker(embedder: embedder)
        _embedderHolder = StateObject(wrappedValue: EmbedderHolder(embedder: embedder, worker: worker))

        let ingestion = IngestionService(store: store, onChunksWritten: {
            await worker.kick()
        })
        _ingestion = StateObject(wrappedValue: IngestionServiceHolder(service: ingestion))

        let indexer = NoteIndexer(store: store, onChunksWritten: { [worker] in
            await worker.kick()
        })
        store.onNoteSaved = { [indexer] noteId in
            do { try await indexer.index(noteId: noteId) }
            catch { print("NoteIndexer error: \(error)") }
        }
        _onboarding = StateObject(wrappedValue: OnboardingViewModel(
            client: client,
            settings: settings
        ))

        let retriever = Retriever(
            store: store,
            client: router,
            modelKey: { selection.embeddingKey() }
        )
        let engine = ChatEngine(
            store: store,
            retriever: retriever,
            chat: router,
            chatModel: settings.selectedChatModel,
            webSearch: DuckDuckGoWebSearch()
        )
        _chatHolder = StateObject(wrappedValue: ChatEngineHolder(engine: engine))

        let txEngine = TransformationEngine(
            store: store, chat: router, chatModel: settings.selectedChatModel
        )
        _transformationHolder = StateObject(wrappedValue: TransformationEngineHolder(engine: txEngine))

        let attachments = AttachmentStore(
            store: store,
            root: (try? AttachmentStore.defaultRoot()) ?? FileManager.default.temporaryDirectory
        )
        _attachmentsHolder = StateObject(wrappedValue: AttachmentStoreHolder(store: attachments))
        store.onNoteDeleted = { uuid in
            await MainActor.run {
                try? attachments.deleteFolder(noteUuid: uuid)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(ollama)
                .environmentObject(routerHolder)
                .environmentObject(ingestion)
                .environmentObject(embedderHolder)
                .environmentObject(onboarding)
                .environmentObject(chatHolder)
                .environmentObject(transformationHolder)
                .environmentObject(attachmentsHolder)
                .environmentObject(noteJump)
                .environmentObject(tabSwitch)
                .environmentObject(updates)
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

@MainActor
final class ProviderRouterHolder: ObservableObject {
    let router: ProviderRouter
    let selection: DefaultsProviderSelection
    let secrets: any SecretStoring
    init(router: ProviderRouter, selection: DefaultsProviderSelection, secrets: any SecretStoring) {
        self.router = router
        self.selection = selection
        self.secrets = secrets
    }
}

@MainActor
final class AttachmentStoreHolder: ObservableObject {
    let store: AttachmentStore
    init(store: AttachmentStore) { self.store = store }
}
