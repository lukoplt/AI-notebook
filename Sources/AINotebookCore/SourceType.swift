import Foundation

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case pdf
    case text
    case markdown
    case web
    case docx
    case pptx
    case xlsx

    /// Best-effort detection from a filename. Returns nil for unknown extensions.
    public static func detect(filename: String) -> SourceType? {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":            return .pdf
        case "txt":            return .text
        case "md", "markdown": return .markdown
        case "docx":           return .docx
        case "pptx":           return .pptx
        case "xlsx":           return .xlsx
        default:               return nil
        }
    }
}
