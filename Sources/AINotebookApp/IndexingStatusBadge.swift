import SwiftUI
import AINotebookCore

struct IndexingStatusBadge: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var embedderHolder: EmbedderHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder

    @State private var pending: Int = 0
    @State private var poller: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if pending == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(settings.text.string(.indexingComplete))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(
                    String(
                        format: settings.text.string(.indexingInProgress),
                        "\(pending)"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { startPoller() }
        .onDisappear { poller?.cancel() }
    }

    private func startPoller() {
        poller?.cancel()
        poller = Task { @MainActor in
            while !Task.isCancelled {
                pending = (try? store.unembeddedCount(model: routerHolder.selection.embeddingKey())) ?? 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s
            }
        }
    }
}
