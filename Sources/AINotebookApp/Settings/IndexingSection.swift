import AINotebookCore
import SwiftUI

/// Indexing: embedding provider/model (privacy gate, re-embed confirmation),
/// conversion notice, re-index with the dual-space note and durable progress
/// (Retry / Discard) per notebook.
struct IndexingSection: View {
    @Bindable var model: SettingsModel
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(24)) {
            if settings.embeddingSelectionConversionNoticePending {
                HStack(alignment: .top, spacing: DesignTokens.spacing(8)) {
                    Label(t.string(.providerEmbeddingSelectionConverted), systemImage: DesignTokens.icon(.info))
                        .tokenFont(.caption)
                        .tokenForeground(.text2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(t.string(.doneButton)) { settings.dismissEmbeddingSelectionConversionNotice() }
                        .buttonStyle(.secondary)
                }
                .padding(DesignTokens.spacing(12))
                .card(radius: .md, fill: .surface2)
            }
            SettingsGroup(t.string(.embeddingSectionTitle)) {
                Picker(t.string(.embeddingProviderPickerLabel), selection: Binding(
                    get: { settings.selectedEmbeddingProviderId },
                    set: { model.requestEmbeddingChange(providerId: $0, model: settings.selectedEmbeddingModel) })) {
                    ForEach(model.providers.filter { $0.type.supportsEmbeddings }) { Text($0.name).tag($0.id) }
                }
                .alert(t.string(.privacyGateTitle), isPresented: $model.showingEmbeddingPrivacyGate) {
                    Button(t.string(.privacyGateAccept)) { model.acceptEmbeddingPrivacy() }
                    Button(t.string(.cancel), role: .cancel) { model.cancelEmbeddingChange() }
                } message: { Text(t.string(.privacyGateMessage)) }
                Picker(t.string(.embeddingModelPickerLabel), selection: Binding(
                    get: { settings.selectedEmbeddingModel },
                    set: { model.requestEmbeddingChange(providerId: settings.selectedEmbeddingProviderId, model: $0) })) {
                    ModelOptions(models: model.embeddingDiscovery.models, selected: settings.selectedEmbeddingModel)
                }
                DiscoveryControls(state: model.embeddingDiscovery, text: t) { model.startModelRefresh(embedding: true) }
                HStack(spacing: DesignTokens.spacing(8)) {
                    TextField(t.string(.providerManualModelId), text: $model.embeddingModelDraft)
                        .textFieldStyle(.roundedBorder)
                    Button(t.string(.providerApplyModel)) {
                        model.requestEmbeddingChange(providerId: settings.selectedEmbeddingProviderId,
                                                     model: model.trimmed(model.embeddingModelDraft))
                    }
                    .buttonStyle(.secondary)
                    .disabled(model.trimmed(model.embeddingModelDraft).isEmpty)
                }
                LabeledContent(t.string(.currentModelLabel)) {
                    Text(settings.selectedEmbeddingModel).font(DesignTokens.font(.mono)).tokenForeground(.text2)
                }
            }
            SettingsGroup(t.string(.reindexButton), footnote: t.string(.reindexDualSpaceNote)) {
                Button(t.string(.reindexButton)) { model.requestReindex() }
                    .buttonStyle(.secondary)
                reindexProgressRows
            }
        }
        .confirmationDialog(t.string(.reembedConfirm), isPresented: $model.showingReembedConfirm,
                            titleVisibility: .visible) {
            Button(t.string(.reembedConfirmYes), role: .destructive) { model.confirmReembed() }
            Button(t.string(.cancelButton), role: .cancel) { model.cancelEmbeddingChange() }
        }
    }

    /// Preparing before dimensions are known, done/total with exclusions while
    /// building, chat pause, and failure with Retry; Discard cancels building only.
    private var reindexProgressRows: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(8)) {
            ForEach(store.notebooks.filter { $0.id.flatMap { model.reindexProgress[$0] }.map(SettingsModel.showsRow) ?? false }) { notebook in
                if let id = notebook.id, let value = model.reindexProgress[id] {
                    HStack(spacing: DesignTokens.spacing(8)) {
                        Text(notebook.name).lineLimit(1)
                        Spacer()
                        if value.failed {
                            Text(t.string(.reindexFailed)).tokenForeground(.warning)
                            Button(t.string(.reindexRetry)) { Task { await model.retryReindex(notebookId: id) } }
                                .buttonStyle(.secondary)
                        } else if value.preparing {
                            ProgressView().controlSize(.small)
                            Text(t.string(.reindexDiscovering))
                        } else {
                            Text(value.pausedForChat ? t.string(.reindexPausedForChat) : t.string(.reindexProgress))
                            Text("\(value.done) / \(value.total)").monospacedDigit()
                            Text("\(t.string(.folderSkipped)): \(value.excluded)").monospacedDigit()
                        }
                        if !value.failed {
                            Button(t.string(.reindexDiscard), role: .destructive) {
                                Task { await model.discardReindex(notebookId: id) }
                            }
                            .buttonStyle(.secondary)
                        }
                    }
                    .tokenFont(.caption)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refreshReindexProgress()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
