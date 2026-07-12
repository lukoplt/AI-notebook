import SwiftUI
import AINotebookCore

struct SourceListView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ingestion: IngestionServiceHolder
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var routerHolder: ProviderRouterHolder

    @State private var sources: [Source] = []
    @State private var showingAdd = false
    @State private var errorMessage: String?
    @State private var summaries: [Int64: String] = [:]
    @State private var summarizing: Set<Int64> = []
    @State private var isDropTarget = false

    private var t: AppText { settings.text }

    /// Built from the same chat model + Ollama client the app uses elsewhere.
    private func makeSummarizer() -> SourceSummarizer {
        SourceSummarizer(store: store, chat: routerHolder.router, chatModel: settings.selectedChatModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.text.string(.sourcesSectionTitle))
                    .font(.title2).bold()
                Spacer()
                IndexingStatusBadge()
                Button(settings.text.string(.addSourceButton)) {
                    showingAdd = true
                }
            }

            if sources.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text(settings.text.string(.noSourcesEmptyState))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(settings.text.string(.addSourceButton)) {
                        showingAdd = true
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(sources) { source in
                        sourceRow(source)
                            .padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(8)
            }
        }
        // B5 — drag & drop files onto Sources.
        .dropDestination(for: URL.self) { urls, _ in
            ingestDropped(urls)
            return true
        } isTargeted: { isDropTarget = $0 }
        .task(id: notebook.id) { await reload() }
        .sheet(isPresented: $showingAdd, onDismiss: { Task { await reload() } }) {
            AddSourceSheet(
                notebookId: notebook.id!,
                language: settings.language,
                ingestion: ingestion.service,
                isPresented: $showingAdd
            )
        }
    }

    @ViewBuilder
    private func sourceRow(_ source: Source) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading) {
                    Text(source.title).font(.headline)
                    Text(statusText(source.status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                summaryAffordance(source)
                Button(role: .destructive) {
                    delete(source)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            if let id = source.id, let summary = summaries[id], !summary.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.string(.sourceSummaryLabel))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func summaryAffordance(_ source: Source) -> some View {
        if let id = source.id {
            if summarizing.contains(id) {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text(t.string(.sourceSummarizingStatus))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if summaries[id] == nil {
                Button(t.string(.sourceSummarizeButton)) {
                    Task { await summarize(source) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(source.status != .ready)
            }
        }
    }

    private func statusText(_ status: SourceStatus) -> String {
        switch status {
        case .pending:  return settings.text.string(.sourceStatusPending)
        case .chunking: return settings.text.string(.sourceStatusChunking)
        case .ready:    return settings.text.string(.sourceStatusReady)
        case .error:    return settings.text.string(.sourceStatusError)
        }
    }

    private func reload() async {
        do {
            sources = try store.sources(notebookId: notebook.id!)
            var loaded: [Int64: String] = [:]
            for source in sources {
                guard let id = source.id else { continue }
                if let summary = try store.sourceSummary(id: id), !summary.isEmpty {
                    loaded[id] = summary
                }
            }
            summaries = loaded
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor
    private func summarize(_ source: Source) async {
        guard let id = source.id, !summarizing.contains(id) else { return }
        summarizing.insert(id)
        defer { summarizing.remove(id) }
        do {
            let summarizer = makeSummarizer()
            let summary = try await summarizer.summarize(sourceId: id)
            if !summary.isEmpty { summaries[id] = summary }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// B5 — ingest a batch of dropped file URLs, then refresh. Non-file URLs
    /// (e.g. web links) are routed to the URL ingester.
    private func ingestDropped(_ urls: [URL]) {
        guard let notebookId = notebook.id else { return }
        Task {
            for url in urls {
                do {
                    if url.isFileURL {
                        _ = try await ingestion.service.ingestFile(url, into: notebookId)
                    } else {
                        _ = try await ingestion.service.ingestURL(url, into: notebookId)
                    }
                } catch {
                    errorMessage = String(describing: error)
                }
            }
            await reload()
        }
    }

    private func delete(_ source: Source) {
        do {
            try store.deleteSource(id: source.id!)
            Task { await reload() }
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
