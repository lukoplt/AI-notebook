import AINotebookCore
import SwiftUI

/// Providers: list with live status, chat/embedding badges, edit, add.
struct ProvidersSection: View {
    @Bindable var model: SettingsModel
    @EnvironmentObject private var settings: AppSettings

    private var t: AppText { settings.text }

    var body: some View {
        SettingsGroup {
            ForEach(model.providers) { provider in
                HStack(spacing: DesignTokens.spacing(8)) {
                    Circle()
                        .fill(DesignTokens.color(statusColor(for: provider)))
                        .frame(width: DesignTokens.spacing(8), height: DesignTokens.spacing(8))
                        .help(model.providerStatus[provider.id].map { providerProbeText($0, text: t) } ?? "")
                        .accessibilityLabel(model.providerStatus[provider.id].map { providerProbeText($0, text: t) } ?? "")
                    Text(provider.name).tokenForeground(.text1)
                    Text(provider.type.rawValue).tokenFont(.caption).tokenForeground(.text3)
                    if provider.id == settings.selectedChatProviderId { badge(.providerBadgeChat) }
                    if provider.id == settings.selectedEmbeddingProviderId { badge(.providerBadgeEmbedding) }
                    Spacer()
                    IconButton(icon: .edit, label: t.string(.editProviderTitle)) { model.editingProvider = provider }
                }
                if provider.id != model.providers.last?.id { Hairline() }
            }
            Button(t.string(.addProviderButton)) { model.showingAddProvider = true }
                .buttonStyle(.secondary)
        }
        .sheet(isPresented: $model.showingAddProvider) {
            AddProviderSheet(existing: nil, onSaved: { model.providersEdited() })
        }
        .sheet(item: $model.editingProvider) { provider in
            AddProviderSheet(existing: provider, onSaved: { model.providersEdited() })
        }
    }

    private func badge(_ key: AppText.Key) -> some View {
        ChipLabel(title: t.string(key))
    }

    private func statusColor(for provider: ProviderConfig) -> DesignTokens.ColorToken {
        guard provider.enabled else { return .text3 }
        switch model.providerStatus[provider.id]?.status {
        case .verified: return .success
        case .listingUnsupported: return .warning
        case .failed: return .danger
        case nil: return .text3
        }
    }
}
