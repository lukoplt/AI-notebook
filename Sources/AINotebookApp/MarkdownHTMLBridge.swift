import Foundation
import WebKit

enum EditorMessage: Equatable {
    case ready
    case change(markdown: String)
    case save(markdown: String)
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
        default:
            throw EditorMessageDecodeError.unknownKind(kind)
        }
    }
}
