import Foundation

public enum StoreError: Error, Equatable, Sendable {
    case notebookNotFound(id: Int64)
    case invalidNotebookName(String)
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id):
            "Notebook \(id) not found."
        case .invalidNotebookName(let name):
            "Invalid notebook name: \"\(name)\"."
        }
    }
}
