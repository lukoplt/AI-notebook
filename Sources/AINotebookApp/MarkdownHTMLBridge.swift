import Foundation
import WebKit

enum EditorMessage: Equatable {
    case ready
    case change(markdown: String)
    case save(markdown: String)
    case attachmentRequest(requestId: String, filename: String, mime: String, base64: String)
}

enum EditorMessageDecodeError: Error, Equatable {
    case invalidPayload
    case unknownKind(String)
    case missingMarkdown
}

enum MarkdownHTMLBridge {
    static func decode(_ body: Any) throws -> EditorMessage {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String else {
            throw EditorMessageDecodeError.invalidPayload
        }
        switch kind {
        case "ready":
            return .ready
        case "change":
            guard let md = dict["markdown"] as? String else {
                throw EditorMessageDecodeError.missingMarkdown
            }
            return .change(markdown: md)
        case "save":
            guard let md = dict["markdown"] as? String else {
                throw EditorMessageDecodeError.missingMarkdown
            }
            return .save(markdown: md)
        case "attachment":
            guard let requestId = dict["requestId"] as? String,
                  let filename = dict["filename"] as? String,
                  let mime = dict["mime"] as? String,
                  let base64 = dict["base64"] as? String else {
                throw EditorMessageDecodeError.invalidPayload
            }
            return .attachmentRequest(requestId: requestId, filename: filename, mime: mime, base64: base64)
        default:
            throw EditorMessageDecodeError.unknownKind(kind)
        }
    }
}
