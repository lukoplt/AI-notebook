import SwiftUI
import AINotebookCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPlaceholder
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
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading) {
            Text(settings.text.string(.notebooks))
                .font(.headline)
                .padding()
            Spacer()
        }
        .frame(minWidth: 220)
    }

    private var detailPlaceholder: some View {
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

#Preview {
    ContentView()
        .environmentObject(AppSettings(
            defaults: UserDefaults(suiteName: "preview")!,
            preferredLanguages: ["en-US"]
        ))
}
