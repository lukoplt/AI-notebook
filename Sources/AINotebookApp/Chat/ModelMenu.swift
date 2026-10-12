import AINotebookCore
import SwiftUI

/// Model chip ("Ollama · llama3.1"): shows the chat model in use (a persona's
/// model wins), offers "Regenerate with …" per provider for the last answer
/// and links to Settings › Models. Choosing a provider for future turns stays
/// in Settings, where the privacy gate lives.
struct ModelChip: View {
    let model: ChatViewModel
    /// Narrow composer: the model name without the provider.
    var compact = false
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings

    private var t: AppText { settings.text }

    private var title: String {
        if let pinned = model.activePersona?.model, !pinned.isEmpty { return pinned }
        if compact { return settings.selectedChatModel }
        let provider = model.chatProviders.first(where: { $0.id == settings.selectedChatProviderId })?.name
            ?? settings.selectedChatProviderId
        return "\(provider) · \(settings.selectedChatModel)"
    }

    var body: some View {
        ChipMenu(title: title, icon: .model, accessibilityLabel: "\(t.string(.composerModel)): \(title)") {
            if model.canRegenerate {
                Button(t.string(.chatRegenerate)) { Task { await model.regenerate() } }
                if !model.chatProviders.isEmpty {
                    Section(t.string(.composerRegenerateWith)) {
                        ForEach(model.chatProviders) { provider in
                            Button(provider.name) { Task { await model.regenerate(via: provider) } }
                        }
                    }
                }
                Divider()
            }
            Button(t.string(.composerModelSettings)) { openSettings() }
        }
    }
}
