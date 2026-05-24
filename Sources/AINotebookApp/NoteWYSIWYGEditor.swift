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
        onSave: @escaping @Sendable (String) -> Void
    ) {
        self._title = title
        self._bodyMd = bodyMd
        self.language = language
        self.noteId = noteId
        self.noteUuid = noteUuid
        self.attachments = attachments
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
                Button("Save") { autoSave.manualSave() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
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
                            "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('\(requestId)')",
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
                            let url = "attachment://\(noteUuidLocal)/\(att.filename)"
                            let js = "window.aino && window.aino.attachmentSaved && window.aino.attachmentSaved('\(requestId)', '\(url)', '\(mime)')"
                            webViewLocal?.evaluateJavaScript(js, completionHandler: nil)
                        } catch {
                            let js = "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('\(requestId)')"
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
