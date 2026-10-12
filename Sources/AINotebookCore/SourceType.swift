import Foundation

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case pdf
    case text
    case markdown
    case web
    case docx
    case pptx
    case xlsx
    case note
    /// An e-mail message: `.eml` (RFC 5322/MIME) or Outlook `.msg`.
    case email

    /// Readable extensions without a well-known system type identifier, for open
    /// panels (macro-enabled OOXML and e-mail).
    public static let extraFileExtensions = ["docm", "pptm", "xlsm", "eml", "msg"]

    /// Best-effort detection from a filename. Returns nil for unknown extensions.
    /// Macro-enabled OOXML packages read as their macro-free kind (their main part
    /// differs only in content type; `vbaProject.bin` is never read). Contract:
    /// `ingestion-formats-v1.json` (detect cases), same table as Windows.
    public static func detect(filename: String) -> SourceType? {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":            return .pdf
        case "txt":            return .text
        case "md", "markdown": return .markdown
        case "docx", "docm":   return .docx
        case "pptx", "pptm":   return .pptx
        case "xlsx", "xlsm":   return .xlsx
        case "eml", "msg":     return .email
        default:               return nil
        }
    }
}
