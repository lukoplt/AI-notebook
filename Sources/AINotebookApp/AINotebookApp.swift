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
    @StateObject private var folderWatch: FolderWatchController

    init() {
        #if DEBUG
        IndexingStripRenderer.runIfRequested()
        #endif
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        let updates = UpdateService(settings: settings)
        _updates = StateObject(wrappedValue: updates)

        let store: NotebookStore
        do {
            let path = try StorePath.production()
            store = try NotebookStore(path: path)
            try settings.convertLegacyProviderSelection(store: store)
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

        // One admission gate and one durable folder runtime per process, sized for this
        // machine (ingestion-memory-pressure-v1 addendum A: half the cores, 6 % of RAM).
        let admission = IngestionAdmission.standard()
        // The factory explains a missing session (no provider/model, disabled, consent,
        // credential) instead of returning nil; the Sources panel shows the reason.
        let resolveSession: @Sendable (Int64) async throws -> EmbeddingSessionResolution = { [store, secrets, selection] _ in
            let chosen = selection.embeddingSelection()
            return try await MainActor.run { () throws -> EmbeddingSessionResolution in
                let config = try store.provider(id: chosen.providerId)
                return FolderEmbeddingSession.resolve(config: config, model: chosen.model, loadKey: {
                    guard let config, config.type.isCloud else { return nil }
                    return try secrets.load(providerId: config.id)
                })
            }
        }
        let session: @Sendable (Int64) async throws -> FolderEmbeddingSession? = { try await resolveSession($0).session }
        let runtime: FolderIngestionRuntime
        do {
            // Memory pressure is sampled on every scheduler tick (ingestion-memory-pressure-v1 §3);
            // load, thermal state and power every 2 s for the adaptive worker limit (addendum A).
            runtime = try FolderIngestionRuntime.standard(store: store, admission: admission, resolveSession: resolveSession,
                                                          memoryPressure: { MemoryPressureLevel.sampleDarwin() },
                                                          systemLoad: { AdaptiveConcurrency.sampleDarwin() })
        } catch {
            fatalError("Failed to build the folder ingestion runtime: \(error)")
        }
        FolderWatchController.installedRuntime = runtime
        let folderWatch = FolderWatchController(runtime: runtime)
        _folderWatch = StateObject(wrappedValue: folderWatch)

        let embedder = Embedder(
            store: store,
            client: router,
            modelKey: { selection.embeddingKey() },
            admission: admission
        )
        // Publications wake durable generation work; the legacy embedder never runs in production.
        let worker = EmbeddingWorker(wake: { try await runtime.wakeGenerationWork() })
        _embedderHolder = StateObject(wrappedValue: EmbedderHolder(embedder: embedder, worker: worker))

        let ingestion = IngestionService(store: store, onChunksWritten: {
            await worker.kick()
        }, folderRuntime: runtime, embeddingSelection: { try await session($0)?.selection })
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
        // WP8: production adapters over the merged WP5 retriever, WP6
        // coverage/folders and WP2 provider sessions; one preview cache.
        let coordinator = ContextPackCoordinator(
            data: CompatibilityPackDataSource(store: store, retriever: retriever, webSearch: DuckDuckGoWebSearch()),
            transports: CompatibilityPackTransportFactory(chat: router, model: settings.selectedChatModel, store: store)
        )
        let engine = ChatEngine(
            store: store,
            coordinator: coordinator,
            previews: ContextPreviewSession(),
            chatModel: settings.selectedChatModel,
            admission: admission
        )
        _chatHolder = StateObject(wrappedValue: ChatEngineHolder(
            engine: engine, originals: NativeCitationOriginalResolver(store: store)))

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
        // Started here, once per process — never per WindowGroup view.
        folderWatch.startProcessRuntime()
    }

    var body: some Scene {
        WindowGroup {
            injectEnvironment(ContentView())
                .frame(minWidth: 1100, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            ShellCommands(settings: settings)
        }

        Settings {
            injectEnvironment(SettingsWindowView())
        }
    }

    /// Every app-wide service as an environment object (windows and Settings).
    private func injectEnvironment<V: View>(_ view: V) -> some View {
        view
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
            .environmentObject(folderWatch)
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
