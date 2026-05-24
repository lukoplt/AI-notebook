import SwiftUI
import AINotebookCore

struct ModelManagementSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ollama: OllamaClientHolder
    @Binding var isPresented: Bool

    @State private var models: [OllamaModel] = []
    @State private var pullName: String = ""
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var pullProgress: String = ""

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.manageModelsTitle)).font(.title2).bold()
            List {
                ForEach(models, id: \.name) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name).font(.headline)
                            Text(byteString(m.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await delete(name: m.name) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(working)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                TextField(t.string(.manageModelsPullPlaceholder), text: $pullName)
                    .textFieldStyle(.roundedBorder)
                Button(t.string(.manageModelsPullButton)) {
                    Task { await pull() }
                }
                .disabled(working || pullName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !pullProgress.isEmpty { ProgressView(pullProgress) }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(t.string(.manageModelsRefreshButton)) { Task { await reload() } }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .task { await reload() }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }

    @MainActor
    private func reload() async {
        do {
            models = try await ollama.client.listModels()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(name: String) async {
        working = true; defer { working = false }
        do {
            try await ollama.client.deleteModel(name: name)
            await reload()
        } catch { errorMessage = String(describing: error) }
    }

    private func pull() async {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        working = true; pullProgress = "Starting…"
        defer { working = false; pullProgress = "" }
        do {
            for try await event in ollama.client.pullModel(name: name) {
                pullProgress = event.status
            }
            pullName = ""
            await reload()
        } catch { errorMessage = String(describing: error) }
    }
}
