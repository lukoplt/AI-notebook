import SwiftUI
import WebKit
import AINotebookCore

/// Live handle on the editor's web view (PDF export of the rendered note).
@MainActor
final class EditorBridge {
    weak var webView: WKWebView?

    /// The whole rendered note as PDF (roadmap M-2).
    func makePDF() async throws -> Data {
        guard let webView else { throw CocoaError(.fileWriteUnknown) }
        return try await webView.pdf(configuration: WKPDFConfiguration())
    }
}

/// TipTap editor (bundled `editor.html`) in a WKWebView; the Markdown bridge,
/// attachment scheme and navigation policy are unchanged from the notes editor.
struct EditorWebView: NSViewRepresentable {
    let initialMarkdown: String
    let noteId: Int64
    let noteUuid: String
    let attachments: AttachmentStore?
    var bridge: EditorBridge?
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
        bridge?.webView = webView
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

        /// Fire-and-forget script evaluation (no result is needed).
        @MainActor static func evaluate(_ js: String, in webView: WKWebView?) {
            webView?.evaluateJavaScript(js, completionHandler: nil)
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
                    Self.evaluate(js, in: webView)
                case .change(let md):
                    onChange(md)
                case .save(let md):
                    onChange(md)
                case .attachmentRequest(let requestId, let filename, let mime, let base64):
                    guard let attachments = attachments,
                          let bytes = Data(base64Encoded: base64) else {
                        Self.evaluate(
                            "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied(\(Self.jsString(requestId)))",
                            in: webView
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
                            Self.evaluate(js, in: webViewLocal)
                        } catch {
                            let js = "window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied(\(Self.jsString(requestId)))"
                            Self.evaluate(js, in: webViewLocal)
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
