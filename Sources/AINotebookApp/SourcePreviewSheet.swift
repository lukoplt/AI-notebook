import SwiftUI
import AppKit
import AINotebookCore

/// Epic B7 — source detail: metadata plus the extracted text, chunk by chunk.
struct SourcePreviewSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore

    let source: Source
    @Binding var isPresented: Bool

    @State private var chunks: [SourceChunk] = []
    @State private var assignedTags: [Tag] = []
    @State private var allTags: [Tag] = []

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t.string(.sourcePreviewTitle)).tokenFont(.headline)
                Spacer()
                Button(t.string(.cancel)) { isPresented = false }
            }
            metadata
            TagChipsEditor(
                assigned: assignedTags,
                all: allTags,
                onAdd: { tagId in setTags(assignedTags.map(\.id) + [tagId]) },
                onRemove: { tagId in setTags(assignedTags.map(\.id).filter { $0 != tagId }) },
                onCreate: { name in
                    if let tag = try? store.createTag(name: name) {
                        setTags(assignedTags.map(\.id) + [tag.id])
                    }
                }
            )
            .environmentObject(settings)
            Divider()
            Text(t.string(.sourcePreviewChunksHeader) + " (\(chunks.count))")
                .tokenFont(.headline)
            if chunks.isEmpty {
                Text(t.string(.sourcePreviewNoChunks)).tokenForeground(.text2)
            } else {
                List(chunks) { chunk in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("#\(chunk.ord + 1)").tokenFont(.caption).tokenForeground(.text3)
                            if let page = chunk.pageHint {
                                Text(String(format: t.string(.citationPage), "\(page)")).tokenFont(.caption).tokenForeground(.text3)
                            }
                        }
                        Text(chunk.text).tokenFont(.body).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task {
            chunks = (try? store.chunks(sourceId: source.id ?? -1)) ?? []
            reloadTags()
        }
    }

    private func reloadTags() {
        allTags = (try? store.tags()) ?? []
        assignedTags = (try? store.tagsForSource(sourceId: source.id ?? -1)) ?? []
    }

    private func setTags(_ ids: [Int64]) {
        try? store.setSourceTags(sourceId: source.id ?? -1, tagIds: Array(Set(ids)))
        reloadTags()
    }

    private func statusText(_ status: SourceStatus) -> String {
        switch status {
        case .pending: t.string(.sourceStatusPending)
        case .chunking: t.string(.sourceStatusChunking)
        case .ready: t.string(.sourceStatusReady)
        case .error: t.string(.sourceStatusError)
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.title).tokenFont(.title)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text(t.string(.sourceMetaType)).tokenForeground(.text2); Text(source.type.rawValue) }
                GridRow { Text(t.string(.sourceMetaStatus)).tokenForeground(.text2); Text(statusText(source.status)) }
                if source.status == .error, let detail = IngestionErrorText.key(for: source.error).map(t.string) {
                    GridRow { Color.clear.frame(width: 0, height: 0); Text(detail).tokenForeground(.danger) }
                }
                if let uri = source.uri {
                    GridRow { Text(t.string(.sourceMetaUri)).tokenForeground(.text2); Text(uri).lineLimit(1) }
                }
                GridRow {
                    Text(t.string(.sourceMetaIngested)).tokenForeground(.text2)
                    Text(source.ingestedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .tokenFont(.caption)
            if let path = source.rawPath, !path.isEmpty {
                Button(t.string(.sourcePreviewOpenOriginal)) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .tokenFont(.caption)
            } else if let uri = source.uri, let url = URL(string: uri) {
                Button(t.string(.sourcePreviewOpenOriginal)) { NSWorkspace.shared.open(url) }
                    .tokenFont(.caption)
            }
        }
    }
}
