import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore
    @StateObject private var ollama: OllamaClientHolder
    @StateObject private var ingestion: IngestionServiceHolder
    @StateObject private var onboarding: OnboardingViewModel

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

        _ingestion = StateObject(wrappedValue: IngestionServiceHolder(
            service: IngestionService(store: store)
        ))

        let client = OllamaClient()
        _ollama = StateObject(wrappedValue: OllamaClientHolder(client: client))
        _onboarding = StateObject(wrappedValue: OnboardingViewModel(
            client: client,
            settings: settings
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(ollama)
                .environmentObject(ingestion)
                .environmentObject(onboarding)
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
