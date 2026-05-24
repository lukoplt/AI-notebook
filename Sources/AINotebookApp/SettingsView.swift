import SwiftUI
import AINotebookCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var embedderHolder: EmbedderHolder
    @Environment(\.dismiss) private var dismiss

    @State private var availableModels: [String] = []
    @State private var showingReembedConfirm = false
    @State private var showingModelMgmt = false
    @State private var settingsError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(settings.text.string(.settings))
                .font(.title2)
                .bold()

            Picker(settings.text.string(.language), selection: $settings.language) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if !availableModels.isEmpty {
                    Picker(settings.text.string(.chatModelPickerLabel),
                           selection: $settings.selectedChatModel) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        if !availableModels.contains(settings.selectedChatModel) {
                            Text(settings.selectedChatModel).tag(settings.selectedChatModel)
                        }
                    }
                    Picker(settings.text.string(.embeddingModelPickerLabel),
                           selection: $settings.selectedEmbeddingModel) {
                        ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        if !availableModels.contains(settings.selectedEmbeddingModel) {
                            Text(settings.selectedEmbeddingModel).tag(settings.selectedEmbeddingModel)
                        }
                    }
                } else {
                    Text("Models unavailable — start Ollama or refresh in Manage models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(settings.text.string(.manageModelsButton)) { showingModelMgmt = true }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(settings.text.string(.embeddingSectionTitle)).font(.headline)
                HStack {
                    Text(settings.text.string(.currentModelLabel))
                    Spacer()
                    Text(settings.selectedEmbeddingModel)
                        .foregroundStyle(.secondary)
                        .monospaced()
                }
                Button(settings.text.string(.reembedButton), role: .destructive) {
                    showingReembedConfirm = true
                }
                .confirmationDialog(
                    settings.text.string(.reembedConfirm),
                    isPresented: $showingReembedConfirm,
                    titleVisibility: .visible
                ) {
                    Button(settings.text.string(.reembedConfirmYes), role: .destructive) {
                        Task { await reembedAll() }
                    }
                    Button(settings.text.string(.cancelButton), role: .cancel) {}
                }
            }

            if let settingsError {
                Text(settingsError).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Text(settings.text.string(.version))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(AINotebookVersion)
                    .monospacedDigit()
            }

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460, height: 540)
        .task { await refreshModels() }
        .sheet(isPresented: $showingModelMgmt, onDismiss: { Task { await refreshModels() } }) {
            ModelManagementSheet(isPresented: $showingModelMgmt)
                .environmentObject(settings)
                .environmentObject(ollama)
        }
    }

    @MainActor
    private func reembedAll() async {
        do {
            try store.deleteAllEmbeddings(model: settings.selectedEmbeddingModel)
            await embedderHolder.worker.kick()
        } catch {
            settingsError = String(describing: error)
        }
    }

    private func refreshModels() async {
        do {
            let models = try await ollama.client.listModels()
            availableModels = models.map(\.name).sorted()
        } catch {
            availableModels = []
        }
    }
}

// #Preview disabled — needs env objects from AINotebookAppEntry
