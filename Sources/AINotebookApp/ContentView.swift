import SwiftUI
import AINotebookCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var embedderHolder: EmbedderHolder
    @EnvironmentObject private var onboarding: OnboardingViewModel
    @EnvironmentObject private var updates: UpdateService

    @State private var selectedNotebookId: Int64?
    @State private var showSettings = false

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainUI
            } else {
                OnboardingView(viewModel: onboarding)
                    .environmentObject(settings)
            }
        }
    }

    private var mainUI: some View {
        VStack(spacing: 0) {
            if let info = updates.availableInfo, !updates.bannerDismissed {
                UpdateBanner(info: info)
            }
            NavigationSplitView {
                SidebarView(selection: $selectedNotebookId)
                    .environmentObject(settings)
                    .environmentObject(store)
            } detail: {
                detail
            }
            .navigationTitle(settings.text.string(.appName))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showSettings = true
                    } label: {
                        Label(settings.text.string(.settings), systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(store)
                    .environmentObject(ollama)
                    .environmentObject(embedderHolder)
            }
        }
        .task {
            if settings.hasCompletedOnboarding {
                await updates.autoCheckIfDue()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedNotebookId,
           let notebook = store.notebooks.first(where: { $0.id == id }) {
            NotebookDetailView(notebook: notebook)
                .environmentObject(settings)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(settings.text.string(.noNotebookSelected))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
