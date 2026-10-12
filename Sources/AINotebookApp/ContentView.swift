import AppKit
import SwiftUI
import AINotebookCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var onboarding: OnboardingViewModel
    @EnvironmentObject private var updates: UpdateService
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ingestion: IngestionServiceHolder
    @EnvironmentObject private var folderWatch: FolderWatchController
    #if DEBUG
    @State private var demoSeedPending = DemoSeed.requestedDirectory != nil
    #else
    private let demoSeedPending = false
    #endif

    var body: some View {
        Group {
            if demoSeedPending {
                #if DEBUG
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        await DemoSeed.runIfRequested(store: store, ingestion: ingestion.service,
                                                      runtime: folderWatch.runtime)
                        demoSeedPending = false
                    }
                #endif
            } else if settings.hasCompletedOnboarding {
                AppShellView()
                    .task { await updates.autoCheckIfDue() }
            } else {
                OnboardingView(viewModel: onboarding)
                    .environmentObject(settings)
            }
        }
        .onAppear(perform: Self.applyAppearanceOverride)
    }

    /// QA aid: `-AINotebookAppearance dark|light` forces the appearance
    /// (light/dark screenshots without touching the system setting).
    private static func applyAppearanceOverride() {
        switch UserDefaults.standard.string(forKey: "AINotebookAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
    }
}
