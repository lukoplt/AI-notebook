import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        // Crash fast on storage init failure — at this point the app cannot
        // function. A future task can replace this with a friendly first-run
        // error screen.
        let store: NotebookStore
        do {
            let path = try StorePath.production()
            store = try NotebookStore(path: path)
        } catch {
            fatalError("Failed to open AINotebook database: \(error)")
        }
        _store = StateObject(wrappedValue: store)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
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
