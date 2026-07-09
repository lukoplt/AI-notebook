import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case notebookNotFound(id: Int64)
    case invalidNotebookName(String)
    case sourceNotFound(Int64)
    case invalidSourceTitle(String)
    case builtInProviderUndeletable
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id):
            "Notebook \(id) not found."
        case .invalidNotebookName(let name):
            "Invalid notebook name: \"\(name)\"."
        case .sourceNotFound(let id):
            "Source #\(id) not found."
        case .invalidSourceTitle(let title):
            "Invalid source title: \"\(title)\"."
        case .builtInProviderUndeletable:
            "The built-in Ollama provider cannot be deleted."
        }
    }
}
