import Foundation
import WebKit
import AINotebookCore

final class AttachmentURLSchemeHandler: NSObject, WKURLSchemeHandler {

    let attachments: AttachmentStore

    init(attachments: AttachmentStore) {
        self.attachments = attachments
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "attachment",
              let host = url.host, !host.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let filename = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !filename.isEmpty else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        do {
            let bytes = try MainActor.assumeIsolated {
                try attachments.read(noteUuid: host, filename: filename)
            }
            let mime = Self.guessMime(forExtension: (filename as NSString).pathExtension)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": mime,
                    "Content-Length": "\(bytes.count)"
                ]
            )!
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(bytes)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static func guessMime(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "pdf":  return "application/pdf"
        case "txt":  return "text/plain"
        case "md":   return "text/markdown"
        default:     return "application/octet-stream"
        }
    }
}
