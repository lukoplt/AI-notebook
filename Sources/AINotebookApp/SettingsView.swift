import SwiftUI
import AINotebookCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var embedderHolder: EmbedderHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @Environment(\.dismiss) private var dismiss

    @State private var showingReembedConfirm = false
    @State private var showingModelMgmt = false
    @State private var settingsError: String?

    @State private var providers: [ProviderConfig] = []
    @State private var chatModels: [ProviderModelInfo] = []
    @State private var embeddingModels: [ProviderModelInfo] = []
    @State private var editingProvider: ProviderConfig?
    @State private var showingAddProvider = false
    @State private var pendingEmbeddingChange: (providerId: String, model: String)?
    @State private var providerStatus: [String: Bool] = [:]   // id → reachable

    // Captured just before an embedding provider/model change is applied so a
    // cancelled re-embed confirmation can put the selection back exactly as
    // it was. Only the FIRST pending edit in a chain sets these (nil-guarded
    // assignment below) so a cancel always reverts to the pre-edit state,
    // even if the user tweaked provider and model before resolving the
    // dialog.
    @State private var revertEmbeddingProviderId: String?
    @State private var revertEmbeddingModel: String?

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
                Text(settings.text.string(.providersSectionTitle)).font(.headline)
                ForEach(providers) { provider in
                    HStack {
                        Circle()
                            .fill(statusColor(for: provider))
                            .frame(width: 8, height: 8)
                        Text(provider.name)
                        Text(provider.type.rawValue).font(.caption).foregroundStyle(.secondary)
                        if provider.id == settings.selectedChatProviderId {
                            Text(settings.text.string(.providerBadgeChat))
                                .font(.caption2).padding(.horizontal, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                        if provider.id == settings.selectedEmbeddingProviderId {
                            Text(settings.text.string(.providerBadgeEmbedding))
                                .font(.caption2).padding(.horizontal, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                        }
                        Spacer()
                        Button {
                            editingProvider = provider
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button(settings.text.string(.addProviderButton)) { showingAddProvider = true }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker(settings.text.string(.chatProviderPickerLabel), selection: $settings.selectedChatProviderId) {
                    ForEach(providers) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: settings.selectedChatProviderId) { _, _ in
                    Task { await refreshChatModels() }
                }
                if !chatModels.isEmpty {
                    Picker(settings.text.string(.chatModelPickerLabel), selection: $settings.selectedChatModel) {
                        ForEach(chatModels) { m in
                            Text(m.label).tag(m.id)
                        }
                        if !chatModels.contains(where: { $0.id == settings.selectedChatModel }) {
                            Text(settings.selectedChatModel).tag(settings.selectedChatModel)
                        }
                    }
                } else {
                    Text(settings.text.string(.modelsUnavailableCaption))
                        .font(.caption).foregroundStyle(.secondary)
                }
                TextField(
                    settings.text.string(.customModelFieldLabel),
                    text: $settings.selectedChatModel
                )
                .font(.caption)

                Button(settings.text.string(.manageModelsButton)) { showingModelMgmt = true }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(settings.text.string(.embeddingSectionTitle)).font(.headline)

                Picker(settings.text.string(.embeddingProviderPickerLabel), selection: $settings.selectedEmbeddingProviderId) {
                    ForEach(providers.filter { $0.type.supportsEmbeddings }) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: settings.selectedEmbeddingProviderId) { old, new in
                    guard old != new else { return }
                    if revertEmbeddingProviderId == nil { revertEmbeddingProviderId = old }
                    if revertEmbeddingModel == nil { revertEmbeddingModel = settings.selectedEmbeddingModel }
                    pendingEmbeddingChange = (new, settings.selectedEmbeddingModel)
                    showingReembedConfirm = true
                    Task { await refreshEmbeddingModels() }
                }
                if !embeddingModels.isEmpty {
                    Picker(settings.text.string(.embeddingModelPickerLabel), selection: $settings.selectedEmbeddingModel) {
                        ForEach(embeddingModels) { m in
                            Text(m.label).tag(m.id)
                        }
                        if !embeddingModels.contains(where: { $0.id == settings.selectedEmbeddingModel }) {
                            Text(settings.selectedEmbeddingModel).tag(settings.selectedEmbeddingModel)
                        }
                    }
                } else {
                    Text(settings.text.string(.modelsUnavailableCaption))
                        .font(.caption).foregroundStyle(.secondary)
                }
                // Bound directly, like the chat custom-model field, but ALSO routed
                // through the re-embed confirmation (FR-A3 servers that omit
                // /v1/models rely on this field as their only way to pick a model,
                // so it must not bypass the FR-A11 confirm-and-recompute flow).
                TextField(
                    settings.text.string(.customModelFieldLabel),
                    text: $settings.selectedEmbeddingModel
                )
                .font(.caption)
                .onChange(of: settings.selectedEmbeddingModel) { old, new in
                    guard old != new else { return }
                    if revertEmbeddingProviderId == nil { revertEmbeddingProviderId = settings.selectedEmbeddingProviderId }
                    if revertEmbeddingModel == nil { revertEmbeddingModel = old }
                    pendingEmbeddingChange = (settings.selectedEmbeddingProviderId, new)
                    showingReembedConfirm = true
                }

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
                        // Accept whatever provider/model is currently selected —
                        // nothing to revert.
                        pendingEmbeddingChange = nil
                        revertEmbeddingProviderId = nil
                        revertEmbeddingModel = nil
                        Task { await reembedAll() }
                    }
                    Button(settings.text.string(.cancelButton), role: .cancel) {}
                }
                .onChange(of: showingReembedConfirm) { _, isPresented in
                    // Fires for every dismissal path (Cancel tap, Escape, click
                    // outside) — not just the Cancel button — so a change that
                    // triggered the dialog is never left half-applied.
                    guard !isPresented, pendingEmbeddingChange != nil else { return }
                    if let revertEmbeddingProviderId {
                        settings.selectedEmbeddingProviderId = revertEmbeddingProviderId
                    }
                    if let revertEmbeddingModel {
                        settings.selectedEmbeddingModel = revertEmbeddingModel
                    }
                    pendingEmbeddingChange = nil
                    self.revertEmbeddingProviderId = nil
                    self.revertEmbeddingModel = nil
                    Task { await refreshEmbeddingModels() }
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

            HStack {
                Spacer()
                Text("Made with <3 by Lukáš Oplt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Spacer()

            HStack {
                Spacer()
                Button(settings.text.string(.doneButton)) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 680)
        .task {
            refreshProviders()
            await refreshChatModels()
            await refreshEmbeddingModels()
        }
        .sheet(isPresented: $showingModelMgmt, onDismiss: {
            Task { await refreshChatModels(); await refreshEmbeddingModels() }
        }) {
            ModelManagementSheet(isPresented: $showingModelMgmt)
                .environmentObject(settings)
                .environmentObject(ollama)
        }
        .sheet(isPresented: $showingAddProvider, onDismiss: {
            refreshProviders()
            Task { await refreshChatModels(); await refreshEmbeddingModels() }
        }) {
            AddProviderSheet(existing: nil, onSaved: { refreshProviders() })
        }
        .sheet(item: $editingProvider, onDismiss: {
            refreshProviders()
            Task { await refreshChatModels(); await refreshEmbeddingModels() }
        }) { provider in
            AddProviderSheet(existing: provider, onSaved: { refreshProviders() })
        }
    }

    @MainActor
    private func reembedAll() async {
        do {
            try store.deleteAllEmbeddings(model: routerHolder.selection.embeddingKey())
            await embedderHolder.worker.kick()
        } catch {
            settingsError = String(describing: error)
        }
    }

    private func refreshProviders() {
        providers = (try? store.providers()) ?? []
        Task { await refreshProviderStatus() }
    }

    /// Spec §5.2.8 status dot: ● green reachable / ● red error / gray
    /// disabled-or-unknown. Probes run in the background; the row renders
    /// gray until a result lands.
    private func statusColor(for provider: ProviderConfig) -> Color {
        guard provider.enabled else { return .gray }
        switch providerStatus[provider.id] {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private func refreshProviderStatus() async {
        for provider in providers {
            let key = (try? routerHolder.secrets.load(providerId: provider.id)) ?? nil
            let error = await routerHolder.router.testConnection(
                type: provider.type, baseURL: provider.baseURL, apiKey: key)
            providerStatus[provider.id] = (error == nil)
        }
    }

    private func refreshChatModels() async {
        chatModels = await routerHolder.router.listModels(providerId: settings.selectedChatProviderId)
    }

    private func refreshEmbeddingModels() async {
        embeddingModels = await routerHolder.router.listModels(providerId: settings.selectedEmbeddingProviderId)
    }
}

// #Preview disabled — needs env objects from AINotebookAppEntry
