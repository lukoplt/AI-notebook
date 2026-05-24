import SwiftUI
import AINotebookCore
import UniformTypeIdentifiers

struct AddSourceSheet: View {

    enum Tab: Hashable { case file, url, text }

    let notebookId: Int64
    let language: AppLanguage
    let ingestion: IngestionService
    @Binding var isPresented: Bool

    @State private var tab: Tab = .file
    @State private var urlString = ""
    @State private var rawTitle = ""
    @State private var rawText  = ""
    @State private var fileURL: URL?
    @State private var working = false
    @State private var errorMessage: String?

    private var t: AppText { AppText(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.addSourceSheetTitle))
                .font(.title2).bold()

            Picker("", selection: $tab) {
                Text(t.string(.addSourceFromFile)).tag(Tab.file)
                Text(t.string(.addSourceFromURL)).tag(Tab.url)
                Text(t.string(.addSourceFromText)).tag(Tab.text)
            }
            .pickerStyle(.segmented)

            Group {
                switch tab {
                case .file: fileSection
                case .url:  urlSection
                case .text: textSection
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(t.string(.cancelButton)) {
                    isPresented = false
                }
                .disabled(working)

                Button(t.string(.addSourceConfirm)) {
                    Task { await submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || !canSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 480, minHeight: 320)
    }

    private var canSubmit: Bool {
        switch tab {
        case .file: return fileURL != nil
        case .url:  return URL(string: urlString)?.scheme?.hasPrefix("http") == true
        case .text: return !rawTitle.trimmingCharacters(in: .whitespaces).isEmpty
                       && !rawText .trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Choose file…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [
                    .pdf,
                    .plainText,
                    UTType("net.daringfireball.markdown") ?? .plainText,
                    UTType("org.openxmlformats.wordprocessingml.document") ?? .data,
                    UTType("org.openxmlformats.presentationml.presentation") ?? .data,
                    UTType("org.openxmlformats.spreadsheetml.sheet") ?? .data
                ]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { fileURL = panel.url }
            }
            if let fileURL {
                Text(fileURL.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var urlSection: some View {
        TextField(
            t.string(.addSourceURLPlaceholder),
            text: $urlString
        )
        .textFieldStyle(.roundedBorder)
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                t.string(.addSourceTitlePlaceholder),
                text: $rawTitle
            )
            .textFieldStyle(.roundedBorder)

            TextEditor(text: $rawText)
                .frame(minHeight: 120)
                .border(.secondary.opacity(0.3))
        }
    }

    @MainActor
    private func submit() async {
        working = true
        errorMessage = nil
        defer { working = false }
        do {
            switch tab {
            case .file:
                guard let url = fileURL else { return }
                _ = try await ingestion.ingestFile(url, into: notebookId)
            case .url:
                guard let url = URL(string: urlString) else { return }
                _ = try await ingestion.ingestURL(url, into: notebookId)
            case .text:
                _ = try await ingestion.ingestRawText(
                    title: rawTitle,
                    text: rawText,
                    into: notebookId
                )
            }
            isPresented = false
        } catch {
            errorMessage = String(describing: error)
        }
    }
}
