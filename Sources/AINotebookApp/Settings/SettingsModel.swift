import AINotebookCore
import Foundation
import Observation

/// State and behaviour of the Settings window (formerly `SettingsView`):
/// provider list + status probes, chat/embedding model discovery, limits,
/// privacy gates and durable re-index progress. Section views only bind to it.
@MainActor
@Observable
final class SettingsModel {
    struct DiscoveryState {
        var models: [ProviderModelInfo] = []
        var result: ProviderProbeResult?
        var error: String?
        var isLoading = false
        var revision = 0
        var task: Task<Void, Never>?
    }

    struct Dependencies {
        let settings: AppSettings
        let store: NotebookStore
        let routerHolder: ProviderRouterHolder
        let folderWatch: FolderWatchController
    }

    private(set) var providers: [ProviderConfig] = []
    private(set) var providerStatus: [String: ProviderProbeResult] = [:]
    private(set) var chatDiscovery = DiscoveryState()
    private(set) var embeddingDiscovery = DiscoveryState()
    var chatModelDraft = ""
    var embeddingModelDraft = ""
    private(set) var limits: ProviderModelLimits?
    var runtimeContextDraft = "" { didSet { if oldValue != runtimeContextDraft { limitsDraftRevision += 1 } } }
    var maxOutputTokensDraft = "" { didSet { if oldValue != maxOutputTokensDraft { limitsDraftRevision += 1 } } }
    private(set) var limitsError: String?
    private(set) var isLoadingLimits = false
    private(set) var isResettingLimits = false
    var settingsError: String?
    /// Durable re-index progress per notebook (persisted generation/job state).
    private(set) var reindexProgress: [Int64: GenerationProgress] = [:]

    var showingModelMgmt = false
    var editingProvider: ProviderConfig?
    var showingAddProvider = false
    var showingChatPrivacyGate = false
    var showingEmbeddingPrivacyGate = false
    var showingReembedConfirm = false
    @ObservationIgnored private var pendingChatProviderId: String?
    @ObservationIgnored private var pendingEmbeddingChange: (providerId: String, model: String)?

    @ObservationIgnored private var statusRevision = 0
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var limitsRevision = 0
    @ObservationIgnored private var limitsDraftRevision = 0
    @ObservationIgnored private var limitsTask: Task<Void, Never>?
    @ObservationIgnored private var deps: Dependencies?

    private var text: AppText { deps?.settings.text ?? AppText(language: .english) }

    // MARK: Lifecycle

    func start(_ dependencies: Dependencies) {
        deps = dependencies
        chatModelDraft = dependencies.settings.selectedChatModel
        embeddingModelDraft = dependencies.settings.selectedEmbeddingModel
        refreshProviders()
        refreshSelections()
    }

    func stop() { invalidateAllRequests() }

    func chatProviderChanged() {
        invalidateDiscovery(embedding: false, clearModels: true)
        startModelRefresh(embedding: false)
        startLimitsLoad(clearDrafts: true)
    }

    func chatModelChanged(_ model: String) {
        chatModelDraft = model
        invalidateDiscovery(embedding: false)
        startLimitsLoad(clearDrafts: true)
    }

    func embeddingProviderChanged() {
        invalidateDiscovery(embedding: true, clearModels: true)
        startModelRefresh(embedding: true)
    }

    func embeddingModelChanged(_ model: String) {
        embeddingModelDraft = model
        invalidateDiscovery(embedding: true)
        startModelRefresh(embedding: true)
    }

    func modelManagementClosed() {
        startModelRefresh(embedding: false)
        startModelRefresh(embedding: true)
    }

    func providersEdited() {
        refreshProviders()
        refreshSelections()
    }

    // MARK: Selection + privacy gates

    func selectChatProvider(_ id: String) {
        guard let settings = deps?.settings, id != settings.selectedChatProviderId else { return }
        if let provider = providers.first(where: { $0.id == id }),
           provider.type.isCloud, !provider.privacyAcknowledged {
            pendingChatProviderId = id
            showingChatPrivacyGate = true
        } else { settings.selectedChatProviderId = id }
    }

    func acceptChatPrivacy() {
        guard let deps, let id = pendingChatProviderId else { return }
        do {
            try deps.store.acknowledgePrivacy(providerId: id)
            refreshProviders()
            deps.settings.selectedChatProviderId = id
        } catch { settingsError = providerErrorText(error, text: text) }
        pendingChatProviderId = nil
    }

    func cancelChatPrivacy() { pendingChatProviderId = nil }

    func requestEmbeddingChange(providerId: String, model: String) {
        guard let settings = deps?.settings, !model.isEmpty,
              providerId != settings.selectedEmbeddingProviderId || model != settings.selectedEmbeddingModel else { return }
        pendingEmbeddingChange = (providerId, model)
        if let provider = providers.first(where: { $0.id == providerId }),
           provider.type.isCloud, !provider.privacyAcknowledged {
            showingEmbeddingPrivacyGate = true
        } else { showingReembedConfirm = true }
    }

    func acceptEmbeddingPrivacy() {
        guard let deps, let pending = pendingEmbeddingChange else { return }
        do {
            try deps.store.acknowledgePrivacy(providerId: pending.providerId)
            refreshProviders()
            showingReembedConfirm = true
        } catch {
            settingsError = providerErrorText(error, text: text)
            pendingEmbeddingChange = nil
        }
    }

    func cancelEmbeddingChange() { pendingEmbeddingChange = nil }

    /// "Re-index" without a model change.
    func requestReindex() {
        pendingEmbeddingChange = nil
        showingReembedConfirm = true
    }

    /// Commits a pending embedding change (only after confirmation) and rebuilds.
    func confirmReembed() {
        guard let settings = deps?.settings else { return }
        if let pending = pendingEmbeddingChange {
            settings.selectedEmbeddingProviderId = pending.providerId
            settings.selectedEmbeddingModel = pending.model
            embeddingModelDraft = pending.model
        }
        pendingEmbeddingChange = nil
        Task { await reembedAll() }
    }

    // MARK: Re-index

    /// Builds a replacement index for every notebook beside its active one with
    /// the captured selected embedder (dimension bootstrap when unknown). The
    /// old index answers until an atomic switch; nothing is deleted up front.
    private func reembedAll() async {
        guard let deps, let runtime = deps.folderWatch.runtime else { return }
        do {
            for notebook in deps.store.notebooks {
                guard let id = notebook.id else { continue }
                _ = try await runtime.requestReindex(notebookId: id)
            }
        } catch { settingsError = providerErrorText(error, text: text) }
        await refreshReindexProgress()
    }

    func refreshReindexProgress() async {
        guard let deps, let runtime = deps.folderWatch.runtime else { return }
        var values: [Int64: GenerationProgress] = [:]
        for notebook in deps.store.notebooks {
            guard let id = notebook.id, let value = try? await runtime.generationProgress(notebookId: id) else { continue }
            values[id] = value
        }
        reindexProgress = values
    }

    func retryReindex(notebookId: Int64) async {
        do { _ = try await deps?.folderWatch.runtime?.requestReindex(notebookId: notebookId) }
        catch { settingsError = providerErrorText(error, text: text) }
        await refreshReindexProgress()
    }

    func discardReindex(notebookId: Int64) async {
        do { try await deps?.folderWatch.runtime?.discardBuild(notebookId: notebookId) }
        catch { settingsError = providerErrorText(error, text: text) }
        await refreshReindexProgress()
    }

    static func showsRow(_ value: GenerationProgress) -> Bool {
        value.failed || value.preparing || (value.generationId != nil && value.done + value.excluded < value.total)
    }

    // MARK: Discovery

    func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func selection(embedding: Bool) -> (providerId: String, model: String) {
        guard let settings = deps?.settings else { return ("", "") }
        return embedding ? (settings.selectedEmbeddingProviderId, settings.selectedEmbeddingModel)
                         : (settings.selectedChatProviderId, settings.selectedChatModel)
    }

    private func isCurrent(_ config: ProviderConfig, model: String, embedding: Bool) -> Bool {
        let selected = selection(embedding: embedding)
        return selected.providerId == config.id && selected.model == model
            && (try? deps?.store.provider(id: config.id)) == config
    }

    func discovery(embedding: Bool) -> DiscoveryState {
        embedding ? embeddingDiscovery : chatDiscovery
    }

    private func setDiscovery(_ state: DiscoveryState, embedding: Bool) {
        if embedding { embeddingDiscovery = state } else { chatDiscovery = state }
    }

    private func invalidateDiscovery(embedding: Bool, clearModels: Bool = false) {
        var state = discovery(embedding: embedding)
        state.task?.cancel()
        state.task = nil
        state.revision += 1
        state.isLoading = false
        state.result = nil
        state.error = nil
        if clearModels { state.models = [] }
        setDiscovery(state, embedding: embedding)
    }

    func startModelRefresh(embedding: Bool) {
        guard let deps else { return }
        invalidateDiscovery(embedding: embedding)
        let selected = selection(embedding: embedding)
        var state = discovery(embedding: embedding)
        let revision = state.revision
        let config: ProviderConfig
        do {
            guard let stored = try deps.store.provider(id: selected.providerId) else {
                throw ProviderConfigurationError.missingProvider
            }
            config = stored
        } catch {
            state.error = providerErrorText(error, text: text)
            setDiscovery(state, embedding: embedding)
            return
        }
        state.isLoading = true
        let router = deps.routerHolder.router
        state.task = Task { @MainActor [weak self] in
            defer {
                if let self, self.discovery(embedding: embedding).revision == revision {
                    var current = self.discovery(embedding: embedding)
                    current.isLoading = false
                    current.task = nil
                    self.setDiscovery(current, embedding: embedding)
                }
            }
            do {
                let models = try await router.discoverModels(providerId: config.id)
                guard let self, !Task.isCancelled, self.discovery(embedding: embedding).revision == revision,
                      self.isCurrent(config, model: selected.model, embedding: embedding) else { return }
                var current = self.discovery(embedding: embedding)
                current.models = models
                current.result = .init(status: .verified, models: models)
                current.isLoading = false
                current.task = nil
                self.setDiscovery(current, embedding: embedding)
                // provider-listing-limits-v1: discovery may have recorded the window of an assumed model.
                if !embedding, self.limits?.isAssumed ?? true,
                   models.contains(where: { $0.id == selected.model && $0.contextWindow != nil }) {
                    self.startLimitsLoad()
                }
            } catch {
                guard let self, !Task.isCancelled, self.discovery(embedding: embedding).revision == revision,
                      self.isCurrent(config, model: selected.model, embedding: embedding) else { return }
                var current = self.discovery(embedding: embedding)
                current.isLoading = false
                current.task = nil
                if error is ProviderListingUnsupported {
                    current.result = .init(status: .listingUnsupported, models: [])
                } else { current.error = providerErrorText(error, text: self.text) }
                self.setDiscovery(current, embedding: embedding)
            }
        }
        setDiscovery(state, embedding: embedding)
    }

    // MARK: Limits

    private func invalidateLimits() {
        limitsRevision += 1
        limitsTask?.cancel()
        limitsTask = nil
        isLoadingLimits = false
        isResettingLimits = false
    }

    func startLimitsLoad(reset: Bool = false, clearDrafts: Bool = false) {
        guard let deps else { return }
        invalidateLimits()
        limitsError = nil
        if clearDrafts {
            limits = nil
            runtimeContextDraft = ""
            maxOutputTokensDraft = ""
            limitsDraftRevision += 1
        }
        let selected = selection(embedding: false)
        let config: ProviderConfig
        do {
            guard let stored = try deps.store.provider(id: selected.providerId) else {
                throw ProviderConfigurationError.missingProvider
            }
            config = stored
            if reset { try deps.store.deleteProviderModelLimits(providerId: config.id, model: selected.model) }
        } catch {
            limitsError = providerErrorText(error, text: text)
            return
        }
        let revision = limitsRevision, draftRevision = limitsDraftRevision
        isLoadingLimits = true
        isResettingLimits = reset
        let router = deps.routerHolder.router
        limitsTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.limitsRevision == revision {
                    self.isLoadingLimits = false
                    self.isResettingLimits = false
                    self.limitsTask = nil
                }
            }
            do {
                let value = try await router.resolveLimits(providerId: config.id, model: selected.model, refresh: reset)
                guard let self, !Task.isCancelled, self.limitsRevision == revision,
                      self.isCurrent(config, model: selected.model, embedding: false) else { return }
                self.limits = value
                if self.limitsDraftRevision == draftRevision {
                    self.runtimeContextDraft = String(value.runtimeContext)
                    self.maxOutputTokensDraft = String(value.maxOutputTokens)
                    self.limitsDraftRevision = draftRevision
                }
            } catch {
                guard let self, !Task.isCancelled, self.limitsRevision == revision,
                      self.isCurrent(config, model: selected.model, embedding: false) else { return }
                self.limitsError = providerErrorText(error, text: self.text)
            }
        }
    }

    func saveLimits() {
        guard let deps, let limits, limits.providerId == deps.settings.selectedChatProviderId,
              limits.model == deps.settings.selectedChatModel else { return }
        do {
            guard let runtime = positiveInteger(runtimeContextDraft),
                  let output = positiveInteger(maxOutputTokensDraft) else {
                throw ProviderConfigurationError.invalidLimits
            }
            let value = ProviderModelLimits(providerId: limits.providerId, model: limits.model,
                contextWindow: limits.contextWindow, runtimeContext: runtime, maxOutputTokens: output, source: "user")
            try value.validate()
            try deps.store.saveProviderModelLimits(value)
            invalidateLimits()
            self.limits = value
            limitsError = nil
        } catch { limitsError = providerErrorText(error, text: text) }
    }

    private func positiveInteger(_ value: String) -> Int? {
        let raw = trimmed(value)
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let parsed = Int(raw), parsed > 0, parsed <= Int32.max else { return nil }
        return parsed
    }

    // MARK: Providers

    private func refreshProviders() {
        guard let deps else { return }
        do {
            providers = try deps.store.providers()
            startProviderStatus()
        } catch { settingsError = providerErrorText(error, text: text) }
    }

    private func startProviderStatus() {
        guard let deps else { return }
        statusRevision += 1
        statusTask?.cancel()
        providerStatus = [:]
        let revision = statusRevision, captured = providers
        let router = deps.routerHolder.router, secrets = deps.routerHolder.secrets, store = deps.store
        statusTask = Task { @MainActor [weak self] in
            for provider in captured where provider.enabled {
                guard let self, !Task.isCancelled, self.statusRevision == revision else { return }
                do {
                    let key = try secrets.load(providerId: provider.id)
                    let result = try await router.probe(type: provider.type, baseURL: provider.baseURL, apiKey: key)
                    guard !Task.isCancelled, self.statusRevision == revision else { return }
                    guard (try? store.provider(id: provider.id)) == provider else { continue }
                    self.providerStatus[provider.id] = result
                } catch {
                    guard !Task.isCancelled, self.statusRevision == revision else { return }
                    guard (try? store.provider(id: provider.id)) == provider else { continue }
                    self.providerStatus[provider.id] = .init(status: .failed, models: [])
                }
            }
        }
    }

    private func refreshSelections() {
        startModelRefresh(embedding: false)
        startModelRefresh(embedding: true)
        startLimitsLoad(clearDrafts: true)
    }

    private func invalidateAllRequests() {
        statusRevision += 1
        statusTask?.cancel()
        statusTask = nil
        invalidateDiscovery(embedding: false)
        invalidateDiscovery(embedding: true)
        invalidateLimits()
    }
}
