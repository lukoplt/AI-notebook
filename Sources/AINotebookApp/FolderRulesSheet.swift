import SwiftUI
import AINotebookCore

/// Edits one folder's include extensions, ignore patterns, limits and text
/// encoding fallback. Save stays disabled until the rules parse, every glob
/// compiles with the folder volume's case policy and every limit is positive
/// within the process ceilings. Cancel changes no stored row.
struct FolderRulesSheet: View {
    let folder: FolderSource
    let text: AppText
    let validate: (FolderRules) async -> Bool
    let onSave: (FolderRules) async throws -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var includes: String
    @State private var ignores: String
    @State private var fileBytes: String
    @State private var officeBytes: String
    @State private var textScalars: String
    @State private var pdfPages: String
    @State private var chunks: String
    @State private var cells: String
    @State private var encoding: String
    @State private var valid = false
    @State private var saving = false
    @State private var failed = false

    init(folder: FolderSource, text: AppText, validate: @escaping (FolderRules) async -> Bool,
         onSave: @escaping (FolderRules) async throws -> Void) {
        self.folder = folder
        self.text = text
        self.validate = validate
        self.onSave = onSave
        let limits = (try? IngestionLimits(json: folder.draft.limitsJSON)) ?? .defaults
        _includes = State(initialValue: folder.draft.includeExts.joined(separator: ", "))
        _ignores = State(initialValue: folder.draft.ignoreGlobs.joined(separator: "\n"))
        _fileBytes = State(initialValue: String(limits.fileBytes))
        _officeBytes = State(initialValue: String(limits.officeBytes))
        _textScalars = State(initialValue: String(limits.textScalars))
        _pdfPages = State(initialValue: String(limits.pdfPages))
        _chunks = State(initialValue: String(limits.chunks))
        _cells = State(initialValue: String(limits.cells))
        _encoding = State(initialValue: folder.draft.encodingFallback)
    }

    /// The candidate rules, or nil when any field fails to parse.
    private var parsed: FolderRules? {
        let exts = includes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let globs = ignores.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !exts.isEmpty, let file = Int64(fileBytes), let office = Int64(officeBytes), let scalars = Int(textScalars),
              let pages = Int(pdfPages), let chunkCount = Int(chunks), let cellCount = Int(cells) else { return nil }
        let limits = IngestionLimits(fileBytes: file, officeBytes: office, textScalars: scalars, pdfPages: pages,
                                     chunks: chunkCount, cells: cellCount)
        guard (try? limits.validate()) != nil else { return nil }
        return FolderRules(includeExts: exts, ignoreGlobs: globs, limits: limits, encodingFallback: encoding)
    }

    private var revalidationKey: String {
        [includes, ignores, fileBytes, officeBytes, textScalars, pdfPages, chunks, cells, encoding].joined(separator: "\u{1}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.string(.folderRulesTitle)).tokenFont(.title)
            Text(folder.draft.displayName).tokenFont(.caption).tokenForeground(.text2)
            Form {
                TextField(text.string(.folderIncludeExtensions), text: $includes)
                VStack(alignment: .leading) {
                    Text(text.string(.folderIgnoreGlobs))
                    TextEditor(text: $ignores)
                        .font(DesignTokens.font(.mono))
                        .frame(minHeight: 90)
                        .accessibilityLabel(text.string(.folderIgnoreGlobs))
                }
                TextField(text.string(.folderMaxFileBytes), text: $fileBytes)
                TextField(text.string(.folderMaxOfficeBytes), text: $officeBytes)
                TextField(text.string(.folderMaxTextScalars), text: $textScalars)
                TextField(text.string(.folderMaxPdfPages), text: $pdfPages)
                TextField(text.string(.folderMaxChunks), text: $chunks)
                TextField(text.string(.folderMaxCells), text: $cells)
                Picker(text.string(.folderEncodingFallback), selection: $encoding) {
                    Text(text.string(.folderEncodingCp1250)).tag("cp1250")
                    Text(text.string(.folderEncodingNone)).tag("none")
                }
            }
            if !valid || failed {
                Text(text.string(.folderRulesInvalid)).tokenFont(.caption).tokenForeground(.danger)
            }
            HStack {
                Spacer()
                Button(text.string(.cancel)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text.string(.save)) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || saving)
            }
        }
        .padding(20)
        .frame(minWidth: 460)
        .task(id: revalidationKey) {
            failed = false
            guard let rules = parsed else { valid = false; return }
            valid = await validate(rules)
        }
    }

    private func save() {
        guard let rules = parsed else { return }
        saving = true
        Task {
            do {
                try await onSave(rules)
                saving = false
                dismiss()
            } catch {
                // Errors keep the sheet open.
                saving = false
                failed = true
            }
        }
    }
}
