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
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var showingPrivacyGate = false
    @State private var showingDeleteConfirm = false

    private var text: AppText { settings.text }
    private var isEdit: Bool { existing != nil }
    private var isBuiltInOllama: Bool { existing?.isBuiltInOllama == true }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.string(isEdit ? .editProviderTitle : .addProviderTitle))
                .font(.title2).bold()

            Picker(text.string(.providerTypeLabel), selection: $type) {
                ForEach(ProviderType.allCases, id: \.self) { t in
                    Text(displayName(for: t)).tag(t)
                }
            }
            .disabled(isBuiltInOllama)
            .onChange(of: type) { _, newType in
                if baseURL.isEmpty || ProviderType.allCases.map(\.defaultBaseURL).contains(baseURL) {
                    baseURL = newType.defaultBaseURL
                }
                testResult = nil
                testSucceeded = false
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
                Button(text.string(.providerTestButton)) {
                    Task { await runTest() }
                }
                .disabled(isTesting || baseURL.isEmpty)
                if isTesting { ProgressView().controlSize(.small) }
                if testSucceeded {
                    Label(text.string(.providerTestSuccess), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let testResult {
                    Text(testResult).foregroundStyle(.red).font(.caption)
                }
            }

            Spacer()

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
        .frame(width: 460, height: 340)
        .onAppear(perform: populate)
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
        hadStoredKey = ((try? routerHolder.secrets.load(providerId: existing.id)) ?? nil) != nil
        // The stored key is never loaded back into the field (FR-A7).
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        testSucceeded = false
        let keyForTest: String? = {
            if !apiKey.isEmpty { return apiKey }
            if let existing { return (try? routerHolder.secrets.load(providerId: existing.id)) ?? nil }
            return nil
        }()
        if let error = await routerHolder.router.testConnection(
            type: type, baseURL: baseURL.trimmingCharacters(in: .whitespaces), apiKey: keyForTest
        ) {
            testResult = providerErrorText(error, text: text)
        } else {
            testSucceeded = true
        }
    }

    private func saveTapped() {
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
        let cfg = ProviderConfig(
            id: existing?.id ?? UUID().uuidString,
            type: type,
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            enabled: true,
            privacyAcknowledged: false,   // saveProvider never clobbers it; see acknowledgePrivacy below
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            try store.saveProvider(cfg)
            if acknowledge {
                try store.acknowledgePrivacy(providerId: cfg.id)
            }
            if type != .ollama && !apiKey.isEmpty {
                try routerHolder.secrets.save(providerId: cfg.id, secret: apiKey)
            }
            // If this edit switched the currently-selected embedding provider
            // to a type that no longer supports embeddings, the selection
            // would silently keep pointing at it (picker no longer offers it,
            // router falls back to Ollama at runtime) — reset it explicitly.
            if settings.selectedEmbeddingProviderId == cfg.id && !cfg.type.supportsEmbeddings {
                settings.selectedEmbeddingProviderId = ProviderConfig.ollamaId
            }
            onSaved()
            dismiss()
        } catch {
            testResult = String(describing: error)
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
            }
            onSaved()
            dismiss()
        } catch {
            testResult = String(describing: error)
        }
    }
}
