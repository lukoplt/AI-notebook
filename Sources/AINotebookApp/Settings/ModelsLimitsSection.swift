import AINotebookCore
import SwiftUI

/// Models & limits: chat provider (privacy gate), chat model with discovery
/// and manual ID, Ollama model management, context limits.
struct ModelsLimitsSection: View {
    @Bindable var model: SettingsModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ollama: OllamaClientHolder

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(24)) {
            SettingsGroup(t.string(.chatModel)) {
                Picker(t.string(.chatProviderPickerLabel), selection: Binding(
                    get: { settings.selectedChatProviderId }, set: { model.selectChatProvider($0) })) {
                    ForEach(model.providers) { Text($0.name).tag($0.id) }
                }
                .alert(t.string(.privacyGateTitle), isPresented: $model.showingChatPrivacyGate) {
                    Button(t.string(.privacyGateAccept)) { model.acceptChatPrivacy() }
                    Button(t.string(.cancel), role: .cancel) { model.cancelChatPrivacy() }
                } message: { Text(t.string(.privacyGateMessage)) }
                Picker(t.string(.chatModelPickerLabel), selection: $settings.selectedChatModel) {
                    ModelOptions(models: model.chatDiscovery.models, selected: settings.selectedChatModel)
                }
                DiscoveryControls(state: model.chatDiscovery, text: t) { model.startModelRefresh(embedding: false) }
                HStack(spacing: DesignTokens.spacing(8)) {
                    TextField(t.string(.providerManualModelId), text: $model.chatModelDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(t.string(.providerApplyModel)) {
                        settings.selectedChatModel = model.trimmed(model.chatModelDraft)
                    }
                    .buttonStyle(.secondary)
                    .disabled(model.trimmed(model.chatModelDraft).isEmpty)
                }
                Button(t.string(.manageModelsButton)) { model.showingModelMgmt = true }
                    .buttonStyle(.secondary)
            }
            SettingsGroup(t.string(.settingsLimits)) {
                LabeledContent(t.string(.providerContextWindow),
                               value: model.limits?.contextWindow.map { String($0) } ?? t.string(.providerContextUnknown))
                if model.limits?.isAssumed == true {
                    Text(t.string(.providerLimitsAssumption)).tokenFont(.caption).tokenForeground(.text3)
                } else if model.limits?.source == "user" {
                    Text(t.string(.providerLimitsUserOverride)).tokenFont(.caption).tokenForeground(.text3)
                }
                LabeledContent(t.string(.providerRuntimeContext)) {
                    TextField("", text: $model.runtimeContextDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .accessibilityLabel(t.string(.providerRuntimeContext))
                }
                LabeledContent(t.string(.providerMaxOutputTokens)) {
                    TextField("", text: $model.maxOutputTokensDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .accessibilityLabel(t.string(.providerMaxOutputTokens))
                }
                HStack(spacing: DesignTokens.spacing(8)) {
                    Button(t.string(.providerLimitsSave)) { model.saveLimits() }
                        .buttonStyle(.secondary)
                        .disabled(model.limits == nil)
                    Button(t.string(.providerLimitsReset)) { model.startLimitsLoad(reset: true) }
                        .buttonStyle(.secondary)
                        .disabled(model.isResettingLimits)
                    if model.isLoadingLimits { ProgressView().controlSize(.small) }
                }
                if let error = model.limitsError { SettingsErrorText(error) }
            }
        }
        .sheet(isPresented: $model.showingModelMgmt, onDismiss: { model.modelManagementClosed() }) {
            ModelManagementSheet(isPresented: $model.showingModelMgmt)
                .environmentObject(settings).environmentObject(ollama)
        }
    }
}

/// Discovered models plus the current selection when it is not in the list.
struct ModelOptions: View {
    let models: [ProviderModelInfo]
    let selected: String

    var body: some View {
        ForEach(models) { Text($0.label).tag($0.id) }
        if !models.contains(where: { $0.id == selected }) { Text(selected).tag(selected) }
    }
}

/// "Refresh models" with progress and the probe result / error.
struct DiscoveryControls: View {
    let state: SettingsModel.DiscoveryState
    let text: AppText
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            HStack(spacing: DesignTokens.spacing(8)) {
                Button(text.string(.providerRefreshModels), action: refresh)
                    .buttonStyle(.secondary)
                    .disabled(state.isLoading)
                if state.isLoading { ProgressView().controlSize(.small) }
            }
            if let result = state.result {
                Text(providerProbeText(result, text: text))
                    .tokenFont(.caption)
                    .tokenForeground(result.status == .verified ? .success : .warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = state.error { SettingsErrorText(error) }
        }
    }
}
