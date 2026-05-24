import SwiftUI
import AINotebookCore

struct SourceListView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ingestion: IngestionServiceHolder

    @State private var sources: [Source] = []
    @State private var showingAdd = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(settings.text.string(.sourcesSectionTitle))
                    .font(.title2).bold()
                Spacer()
                Button(settings.text.string(.addSourceButton)) {
                    showingAdd = true
                }
            }

            if sources.isEmpty {
                Text(settings.text.string(.noSourcesEmptyState))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            } else {
                List {
                    ForEach(sources) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(source.title).font(.headline)
                                Text(statusText(source.status))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                delete(source)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
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
        } catch {
            errorMessage = String(describing: error)
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
