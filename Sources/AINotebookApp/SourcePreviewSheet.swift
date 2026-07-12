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

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t.string(.sourcePreviewTitle)).font(.headline)
                Spacer()
                Button(t.string(.cancel)) { isPresented = false }
            }
            metadata
            Divider()
            Text(t.string(.sourcePreviewChunksHeader) + " (\(chunks.count))")
                .font(.subheadline).bold()
            if chunks.isEmpty {
                Text(t.string(.sourcePreviewNoChunks)).foregroundStyle(.secondary)
            } else {
                List(chunks) { chunk in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("#\(chunk.ord + 1)").font(.caption2).foregroundStyle(.tertiary)
                            if let page = chunk.pageHint {
                                Text("p.\(page)").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Text(chunk.text).font(.callout).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
        .task { chunks = (try? store.chunks(sourceId: source.id ?? -1)) ?? [] }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(source.title).font(.title3).bold()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text("type").foregroundStyle(.secondary); Text(source.type.rawValue) }
                GridRow { Text("status").foregroundStyle(.secondary); Text(source.status.rawValue) }
                if let uri = source.uri {
                    GridRow { Text("uri").foregroundStyle(.secondary); Text(uri).lineLimit(1) }
                }
                GridRow {
                    Text("ingested").foregroundStyle(.secondary)
                    Text(source.ingestedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            if let path = source.rawPath, !path.isEmpty {
                Button(t.string(.sourcePreviewOpenOriginal)) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path))
                }
                .font(.caption)
            } else if let uri = source.uri, let url = URL(string: uri) {
                Button(t.string(.sourcePreviewOpenOriginal)) { NSWorkspace.shared.open(url) }
                    .font(.caption)
            }
        }
    }
}
