import SwiftUI
import WebKit
import AINotebookCore

struct NoteWYSIWYGEditor: View {

    @Binding var title: String
    @Binding var bodyMd: String
    let language: AppLanguage
    let noteId: Int64
    let noteUuid: String
    let attachments: AttachmentStore?
    let coordinator: NoteEditorCoordinator?
    let onShowHistory: (() -> Void)?
    let onSave: @Sendable (String) -> Void

    @StateObject private var autoSave: AutoSaveController
    @State private var loadFailed = false

    private var t: AppText { AppText(language: language) }

    init(
        title: Binding<String>,
        bodyMd: Binding<String>,
        language: AppLanguage,
        noteId: Int64,
        noteUuid: String,
        attachments: AttachmentStore?,
        coordinator: NoteEditorCoordinator? = nil,
        onShowHistory: (() -> Void)? = nil,
        onSave: @escaping @Sendable (String) -> Void
    ) {
        self._title = title
        self._bodyMd = bodyMd
        self.language = language
        self.noteId = noteId
        self.noteUuid = noteUuid
        self.attachments = attachments
        self.coordinator = coordinator
        self.onShowHistory = onShowHistory
        self.onSave = onSave
        self._autoSave = StateObject(wrappedValue: AutoSaveController(save: onSave))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(t.string(.noteTitlePlaceholder), text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            if loadFailed {
                VStack {
                    Spacer()
                    Text(t.string(.editorFailedToLoad)).foregroundStyle(.red)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EditorWebView(
                    initialMarkdown: bodyMd,
                    noteId: noteId,
                    noteUuid: noteUuid,
                    attachments: attachments,
                    onChange: { md in
                        bodyMd = md
                        autoSave.noteDidChange(md)
                    },
                    onLoadFailed: { loadFailed = true }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                statusLabel
                Spacer()
                if let onShowHistory {
                    Button(AppText(language: language).string(.historyButton)) { onShowHistory() }
                        .keyboardShortcut("h", modifiers: [.command, .shift])
                }
                Button("Save") { autoSave.manualSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            coordinator?.flushPendingSave = { [weak autoSave] in autoSave?.manualSave() }
            coordinator?.hasUnsavedChanges = (autoSave.status == .unsaved || autoSave.status == .saving)
        }
        .onDisappear {
            coordinator?.flushPendingSave = nil
        }
        .onChange(of: autoSave.status) { _, newValue in
            coordinator?.hasUnsavedChanges = (newValue == .unsaved || newValue == .saving)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch autoSave.status {
        case .saved:
            Label(t.string(.editorStatusSaved), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .saving:
            Label(t.string(.editorStatusSaving), systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .unsaved:
            Label(t.string(.editorStatusUnsaved), systemImage: "pencil.circle")
                .font(.caption).foregroundStyle(.orange)
        case .error(let msg):
            Label("\(AppText(language: language).string(.editorStatusError)) — \(msg)",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
        }
    }
}

private struct EditorWebView: NSViewRepresentable {
    let initialMarkdown: String
    let noteId: Int64
    let noteUuid: String
    let attachments: AttachmentStore?
    let onChange: (String) -> Void
    let onLoadFailed: () -> Void

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(onChange: onChange, onLoadFailed: onLoadFailed)
        c.attachments = attachments
        c.noteId = noteId
        c.noteUuid = noteUuid
        return c
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        if let attachments = attachments {
            config.setURLSchemeHandler(
                AttachmentURLSchemeHandler(attachments: attachments),
                forURLScheme: "attachment"
            )
        }
        let userController = WKUserContentController()
        userController.add(context.coordinator, name: "aino")
        config.userContentController = userController
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")

        guard let folder = Bundle.module.url(forResource: "editor", withExtension: nil),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("editor.html").path) else {
            DispatchQueue.main.async { onLoadFailed() }
            return webView
        }
        let html = folder.appendingPathComponent("editor.html")
        webView.loadFileURL(html, allowingReadAccessTo: folder)
        context.coordinator.webView = webView
        context.coordinator.initialMarkdown = initialMarkdown
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onChange = onChange
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onChange: (String) -> Void
        var onLoadFailed: () -> Void
        var initialMarkdown: String = ""
        var attachments: AttachmentStore?
        var noteId: Int64 = 0
        var noteUuid: String = ""

        init(onChange: @escaping (String) -> Void,
             onLoadFailed: @escaping () -> Void) {
            self.onChange = onChange
            self.onLoadFailed = onLoadFailed
        }

        /// Encodes a Swift string as a JS string literal (double-quoted) with all
        /// breaking characters escaped, so untrusted values (e.g. attachment file
        /// names) can be safely embedded in an evaluateJavaScript call. Uses JSON
        /// encoding, which is a valid subset of JS string literals.
        static func jsString(_ s: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [s]),
                  let json = String(data: data, encoding: .utf8) else {
                return "\"\""
            }
            // json is `["<escaped>"]`; strip the surrounding array brackets.
            return String(json.dropFirst().dropLast())
        }

        func userContentController(_ uc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            do {
                let m = try MarkdownHTMLBridge.decode(message.body)
                switch m {
                case .ready:
                    let escaped = initialMarkdown
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "`",  with: "\\`")
                        .replacingOccurrences(of: "$",  with: "\\$")
                    let js = "window.aino && window.aino.setContent(`\(escaped)`)"
                    webView?.evaluateJavaScript(js, completionHandler: nil)
                case .change(let md):
                    onChange(md)
                case .save(let md):
                    onChange(md)
                case .attachmentRequest(let requestId, let filename, let mime, let base64):
                    guard let attachments = attachments,
                          let bytes = Data(base64Encoded: base64) else {
                        webView?.evaluateJavaScript(
                            "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied(\(Self.jsString(requestId)))",
                            completionHandler: nil
                        )
                        return
                    }
                    let noteIdLocal = noteId
                    let noteUuidLocal = noteUuid
                    let webViewLocal = webView
                    Task { @MainActor in
                        do {
                            let att = try attachments.save(
                                noteId: noteIdLocal,
                                noteUuid: noteUuidLocal,
                                filename: filename,
                                mime: mime,
                                bytes: bytes
                            )
                            // att.filename is user-controlled (the uploaded file name).
                            // JSON-encode every argument so an apostrophe or script
                            // payload in the name cannot break out of the JS call and
                            // execute in the editor WebView. Mirrors the Windows
                            // EditorWebView JsonSerializer.Serialize handling.
                            let url = "attachment://\(noteUuidLocal)/\(att.filename)"
                            let js = "window.aino && window.aino.attachmentSaved && window.aino.attachmentSaved("
                                + "\(Self.jsString(requestId)), \(Self.jsString(url)), \(Self.jsString(mime)))"
                            webViewLocal?.evaluateJavaScript(js, completionHandler: nil)
                        } catch {
                            let js = "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied(\(Self.jsString(requestId)))"
                            webViewLocal?.evaluateJavaScript(js, completionHandler: nil)
                        }
                    }
                }
            } catch {
                // Unknown payloads ignored in v1.
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            onLoadFailed()
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onLoadFailed()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.scheme == "file" {
                decisionHandler(.allow)
            } else if navigationAction.navigationType == .other {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}
