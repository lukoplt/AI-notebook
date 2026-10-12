import SwiftUI
import AINotebookCore

/// Add/edit one provider. Presented from SettingsView.
/// Privacy gate (FR-A8): saving a NEW cloud/network provider first shows a
/// consent alert; consent is recorded via acknowledgePrivacy regardless of
/// whether a key was entered (keyless OpenWebUI instances still send data).
struct AddProviderSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @Environment(\.dismiss) private var dismiss

    /// nil = add mode; non-nil = edit mode.
    let existing: ProviderConfig?
    var onSaved: () -> Void

    @State private var type: ProviderType = .openwebui
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var hadStoredKey = false
    @State private var selectedPresetId = "custom"
    @State private var probeResult: ProviderProbeResult?
    @State private var formError: String?
    @State private var isTesting = false
    @State private var probeRevision = 0
    @State private var probeTask: Task<Void, Never>?
    @State private var showingPrivacyGate = false
    @State private var showingDeleteConfirm = false

    private var text: AppText { settings.text }
    private var isEdit: Bool { existing != nil }
    private var isBuiltInOllama: Bool { existing?.isBuiltInOllama == true }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresKey || hadStoredKey || hasDraftKey)
    }

    private var requiresKey: Bool { type == .openai || type == .anthropic }
    private var hasDraftKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var selectableTypes: [ProviderType] {
        // Changing a selected embedder to a chat-only type would require a
        // different embedding selection. Let Settings confirm that change first.
        ProviderType.allCases.filter {
            existing?.id != settings.selectedEmbeddingProviderId || $0.supportsEmbeddings
        }
    }

    private var providerTypeBinding: Binding<ProviderType> {
        Binding(get: { type }, set: { newType in
            // Apply defaults only for an intentional type edit. Populating an
            // existing row must preserve its exact stored root, even when that
            // root happens to match another provider's default.
            let usesDefaultRoot = baseURL.isEmpty || baseURL == type.defaultBaseURL
            type = newType
            if usesDefaultRoot { baseURL = newType.defaultBaseURL }
            selectedPresetId = "custom"
            invalidateProbe()
        })
    }

    private var presetHelpKey: AppText.Key {
        switch ProviderPresets.all.first(where: { $0.id == selectedPresetId })?.helpKey {
        case "providerPresetLocalHelp": .providerPresetLocalHelp
        case "providerPresetRemoteHelp": .providerPresetRemoteHelp
        default: .providerPresetCustomHelp
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.string(isEdit ? .editProviderTitle : .addProviderTitle))
                .tokenFont(.title)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker(text.string(.providerTypeLabel), selection: providerTypeBinding) {
                        ForEach(selectableTypes, id: \.self) { t in
                            Text(displayName(for: t)).tag(t)
                        }
                    }
                    .disabled(isBuiltInOllama)

                    if type == .openaiCompatible {
                        Picker(text.string(.providerPresetLabel), selection: $selectedPresetId) {
                            ForEach(ProviderPresets.all, id: \.id) { preset in
                                Text(preset.id == "custom" ? text.string(.providerPresetCustom) : preset.name)
                                    .tag(preset.id)
                            }
                        }
                        .onChange(of: selectedPresetId) { _, id in
                            applyPreset(id)
                        }
                        Text(text.string(presetHelpKey))
                            .tokenFont(.caption).tokenForeground(.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    TextField(text.string(.providerNameLabel), text: $name)
                    TextField(text.string(.providerUrlLabel), text: $baseURL)

                    if type != .ollama {
                        SecureField(
                            hadStoredKey ? text.string(.providerKeySavedLabel) : text.string(.providerApiKeyLabel),
                            text: $apiKey
                        )
                    }

                    HStack {
                        Button(text.string(.providerTestButton), action: startTest)
                            .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if isTesting { ProgressView().controlSize(.small) }
                    }
                    if let probeResult {
                        Label(providerProbeText(probeResult, text: text), systemImage: probeSymbol(probeResult))
                            .foregroundStyle(probeColor(probeResult))
                            .tokenFont(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    if let formError {
                        Text(formError).tokenForeground(.danger).tokenFont(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack {
                if isEdit && !isBuiltInOllama {
                    Button(text.string(.providerDeleteButton), role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
                Spacer()
                Button(text.string(.cancel)) { dismiss() }
                Button(text.string(.save)) { saveTapped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520, height: 460)
        .onAppear(perform: populate)
        .onChange(of: baseURL) { _, _ in invalidateProbe() }
        .onChange(of: apiKey) { _, _ in invalidateProbe() }
        .onDisappear { invalidateProbe() }
        .alert(text.string(.privacyGateTitle), isPresented: $showingPrivacyGate) {
            Button(text.string(.privacyGateAccept)) { persist(acknowledge: true) }
            Button(text.string(.cancel), role: .cancel) {}
        } message: {
            Text(text.string(.privacyGateMessage))
        }
        .confirmationDialog(
            text.string(.providerDeleteConfirm),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(text.string(.delete), role: .destructive) { deleteProvider() }
        }
    }

    private func displayName(for t: ProviderType) -> String {
        switch t {
        case .ollama: "Ollama (local)"
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI (ChatGPT)"
        case .openaiCompatible: "OpenAI-compatible"
        case .openwebui: "OpenWebUI (network)"
        }
    }

    private func populate() {
        guard let existing else {
            baseURL = type.defaultBaseURL
            return
        }
        type = existing.type
        name = existing.name
        baseURL = existing.baseURL
        let storedKey = (try? routerHolder.secrets.load(providerId: existing.id)) ?? nil
        hadStoredKey = storedKey.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
        // The stored key is never loaded back into the field (FR-A7).
    }

    private func applyPreset(_ id: String) {
        invalidateProbe()
        guard let preset = ProviderPresets.all.first(where: { $0.id == id }), id != "custom" else { return }
        baseURL = preset.baseURL
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = preset.name }
    }

    private func invalidateProbe() {
        probeRevision += 1
        probeTask?.cancel()
        probeTask = nil
        isTesting = false
        probeResult = nil
        formError = nil
    }

    private func startTest() {
        invalidateProbe()
        let revision = probeRevision
        let requestedType = type, requestedRoot = baseURL, requestedKeyDraft = apiKey
        let key: String?
        do {
            if hasDraftKey { key = apiKey }
            else if let existing { key = try routerHolder.secrets.load(providerId: existing.id) }
            else { key = nil }
        } catch {
            formError = providerErrorText(error, text: text)
            return
        }
        isTesting = true
        probeTask = Task { @MainActor in
            defer {
                if probeRevision == revision {
                    isTesting = false
                    probeTask = nil
                }
            }
            do {
                let result = try await routerHolder.router.probe(
                    type: requestedType, baseURL: requestedRoot, apiKey: key)
                guard !Task.isCancelled, probeRevision == revision,
                      type == requestedType, baseURL == requestedRoot, apiKey == requestedKeyDraft else { return }
                probeResult = result
            } catch {
                guard !Task.isCancelled, probeRevision == revision,
                      type == requestedType, baseURL == requestedRoot, apiKey == requestedKeyDraft else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                formError = providerErrorText(error, text: text)
            }
        }
    }

    private func probeColor(_ result: ProviderProbeResult) -> Color {
        switch result.status {
        case .verified: DesignTokens.color(.success)
        case .listingUnsupported: DesignTokens.color(.warning)
        case .failed: DesignTokens.color(.danger)
        }
    }

    private func probeSymbol(_ result: ProviderProbeResult) -> String {
        switch result.status {
        case .verified: "checkmark.circle"
        case .listingUnsupported: "info.circle"
        case .failed: "exclamationmark.circle"
        }
    }

    private func saveTapped() {
        guard !requiresKey || hadStoredKey || hasDraftKey else {
            formError = text.string(.errorInvalidApiKey)
            return
        }
        do {
            _ = try ProviderAPIRoot.normalize(baseURL)
        } catch {
            formError = providerErrorText(error, text: text)
            return
        }
        guard canSave else { return }
        // Consent gate (FR-A8): fires for a NEW cloud/network provider and
        // ALSO when an existing provider's type changes to a cloud/network
        // type — the stored consent belonged to the previous type and must
        // not silently carry over (plan-verification finding).
        let typeChanged = existing.map { $0.type != type } ?? true
        if type.isCloud && typeChanged {
            showingPrivacyGate = true
        } else {
            persist(acknowledge: false)
        }
    }

    private func persist(acknowledge: Bool) {
        do {
            if existing?.id == settings.selectedEmbeddingProviderId && !type.supportsEmbeddings {
                throw ProviderConfigurationError.unsupportedEndpoint
            }
            let cfg = ProviderConfig(
                id: existing?.id ?? UUID().uuidString,
                type: type,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                baseURL: try ProviderAPIRoot.normalize(baseURL),
                enabled: existing?.enabled ?? true,
                privacyAcknowledged: false,   // saveProvider preserves existing consent
                createdAt: existing?.createdAt ?? Date()
            )
            try store.saveProvider(cfg)
            if acknowledge {
                try store.acknowledgePrivacy(providerId: cfg.id)
            }
            if type != .ollama && hasDraftKey {
                try routerHolder.secrets.save(providerId: cfg.id, secret: apiKey)
            }
            onSaved()
            dismiss()
        } catch {
            formError = providerErrorText(error, text: text)
        }
    }

    private func deleteProvider() {
        guard let existing, !existing.isBuiltInOllama else { return }
        do {
            try store.deleteProvider(id: existing.id)
            try routerHolder.secrets.delete(providerId: existing.id)
            // Selections pointing at the deleted provider fall back to Ollama.
            if settings.selectedChatProviderId == existing.id {
                settings.selectedChatProviderId = ProviderConfig.ollamaId
            }
            if settings.selectedEmbeddingProviderId == existing.id {
                settings.selectedEmbeddingProviderId = ProviderConfig.ollamaId
                settings.selectedEmbeddingModel = "nomic-embed-text"
            }
            onSaved()
            dismiss()
        } catch {
            formError = providerErrorText(error, text: text)
        }
    }
}
