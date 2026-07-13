import SwiftUI
import AINotebookCore

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var embedderHolder: EmbedderHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @EnvironmentObject private var updates: UpdateService
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

    // MARK: - FR-A8 re-gate on picker selection
    //
    // Selecting a cloud/network provider that was never acknowledged (e.g. it
    // was added, declined, and left `enabled` in the registry) must re-show
    // the privacy gate — the router enforces this defense-in-depth on every
    // call, but a picker that silently "worked" via Ollama fallback (or threw
    // a raw `consentRequired` chat error) would be a confusing dead end.
    //
    // Both pickers reuse the same `privacyGateTitle/Message/Accept` keys and
    // alert pattern as `AddProviderSheet`. Each has its own `showing…`/
    // `pending…Consent` pair so the two gates never interfere.
    @State private var showingChatPrivacyGate = false
    @State private var pendingChatProviderConsent: (old: String, new: String)?
    // Set immediately before programmatically reverting
    // `selectedChatProviderId` on decline, so the reentrant `onChange` fire
    // that revert triggers is swallowed instead of being mistaken for a new
    // user selection (which would just no-op here, but is guarded for the
    // same reason as the embedding flag below).
    @State private var suppressChatProviderOnChange = false

    @State private var showingEmbeddingPrivacyGate = false
    @State private var pendingEmbeddingProviderConsent: (old: String, new: String)?
    // Same purpose as `suppressChatProviderOnChange`, but load-bearing here:
    // without it, reverting `selectedEmbeddingProviderId` on consent-decline
    // would re-enter the embedding `onChange` and — since the reverted-to
    // provider is already acknowledged — fall through to
    // `beginEmbeddingProviderChange`, incorrectly popping the re-embed
    // confirmation dialog right after the user declined consent.
    @State private var suppressEmbeddingProviderOnChange = false

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
                .onChange(of: settings.selectedChatProviderId) { old, new in
                    if suppressChatProviderOnChange {
                        suppressChatProviderOnChange = false
                        return
                    }
                    guard old != new else { return }
                    if let provider = providers.first(where: { $0.id == new }),
                       provider.type.isCloud, !provider.privacyAcknowledged {
                        pendingChatProviderConsent = (old, new)
                        showingChatPrivacyGate = true
                        return
                    }
                    Task { await refreshChatModels() }
                }
                .alert(settings.text.string(.privacyGateTitle), isPresented: $showingChatPrivacyGate) {
                    Button(settings.text.string(.privacyGateAccept)) {
                        guard let pending = pendingChatProviderConsent else { return }
                        do {
                            try store.acknowledgePrivacy(providerId: pending.new)
                            refreshProviders()
                            pendingChatProviderConsent = nil
                            Task { await refreshChatModels() }
                        } catch {
                            // Consent was NOT recorded — do not proceed with the
                            // selection. Revert exactly like a decline, and
                            // surface the failure instead of silently keeping
                            // an un-acknowledged provider selected.
                            settingsError = String(describing: error)
                            suppressChatProviderOnChange = true
                            settings.selectedChatProviderId = pending.old
                            pendingChatProviderConsent = nil
                        }
                    }
                    Button(settings.text.string(.cancel), role: .cancel) {
                        guard let pending = pendingChatProviderConsent else { return }
                        suppressChatProviderOnChange = true
                        settings.selectedChatProviderId = pending.old
                        pendingChatProviderConsent = nil
                    }
                } message: {
                    Text(settings.text.string(.privacyGateMessage))
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
                    if suppressEmbeddingProviderOnChange {
                        suppressEmbeddingProviderOnChange = false
                        return
                    }
                    guard old != new else { return }
                    // Consent gate runs FIRST: only once the user accepts does
                    // the existing re-embed confirmation flow continue (see
                    // beginEmbeddingProviderChange below). Decline reverts and
                    // skips the re-embed dialog entirely.
                    if let provider = providers.first(where: { $0.id == new }),
                       provider.type.isCloud, !provider.privacyAcknowledged {
                        pendingEmbeddingProviderConsent = (old, new)
                        showingEmbeddingPrivacyGate = true
                        return
                    }
                    beginEmbeddingProviderChange(old: old, new: new)
                }
                .alert(settings.text.string(.privacyGateTitle), isPresented: $showingEmbeddingPrivacyGate) {
                    Button(settings.text.string(.privacyGateAccept)) {
                        guard let pending = pendingEmbeddingProviderConsent else { return }
                        do {
                            try store.acknowledgePrivacy(providerId: pending.new)
                            refreshProviders()
                            pendingEmbeddingProviderConsent = nil
                            beginEmbeddingProviderChange(old: pending.old, new: pending.new)
                        } catch {
                            // Consent was NOT recorded — do not proceed with the
                            // selection (skip the re-embed flow entirely). Revert
                            // exactly like a decline, and surface the failure.
                            settingsError = String(describing: error)
                            suppressEmbeddingProviderOnChange = true
                            settings.selectedEmbeddingProviderId = pending.old
                            pendingEmbeddingProviderConsent = nil
                        }
                    }
                    Button(settings.text.string(.cancel), role: .cancel) {
                        guard let pending = pendingEmbeddingProviderConsent else { return }
                        suppressEmbeddingProviderOnChange = true
                        settings.selectedEmbeddingProviderId = pending.old
                        pendingEmbeddingProviderConsent = nil
                    }
                } message: {
                    Text(settings.text.string(.privacyGateMessage))
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
                    Button(settings.text.string(.cancelButton), role: .cancel) {
                        // Explicit revert so the common cancel path doesn't
                        // depend on onChange-vs-button transaction ordering.
                        // No-op if there's nothing pending (e.g. the dialog
                        // was opened via the plain "Re-embed all" button).
                        guard pendingEmbeddingChange != nil else { return }
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
                .onChange(of: showingReembedConfirm) { _, isPresented in
                    // Catch-all for dismissal paths that skip the Cancel
                    // button's action (Escape, click outside). Idempotent:
                    // if Cancel (or Yes) already cleared pendingEmbeddingChange,
                    // this is a no-op, so it never double-applies the revert.
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

            Toggle(settings.text.string(.webSearchToggle), isOn: $settings.webSearchEnabled)
            Toggle(settings.text.string(.updateAutoCheckToggle), isOn: $settings.autoCheckUpdates)
            HStack {
                Button(settings.text.string(.updateCheckNowButton)) {
                    Task { await updates.checkNow() }
                }
                .disabled(updates.status == .checking)
                Text(updateStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    /// The pre-consent-gate body of the embedding-provider `onChange`:
    /// arms the re-embed confirmation dialog with a revert snapshot. Shared
    /// by the direct (already-acknowledged) path and the post-consent-accept
    /// path so both funnel through the identical existing re-embed flow.
    private func beginEmbeddingProviderChange(old: String, new: String) {
        if revertEmbeddingProviderId == nil { revertEmbeddingProviderId = old }
        if revertEmbeddingModel == nil { revertEmbeddingModel = settings.selectedEmbeddingModel }
        pendingEmbeddingChange = (new, settings.selectedEmbeddingModel)
        showingReembedConfirm = true
        Task { await refreshEmbeddingModels() }
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

    private var updateStatusText: String {
        switch updates.status {
        case .idle: ""
        case .checking: settings.text.string(.updateStatusChecking)
        case .upToDate: settings.text.string(.updateStatusUpToDate)
        case .available(let info):
            String(format: settings.text.string(.updateStatusAvailable), info.latestVersion)
        case .failed: settings.text.string(.updateStatusFailed)
        }
    }
}

// #Preview disabled — needs env objects from AINotebookAppEntry
