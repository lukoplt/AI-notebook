import Foundation
import AINotebookCore

/// Chat scope presentation state. The selection stays explicit IDs (sources,
/// folders, saved sets); membership is resolved by Core immediately before
/// each send/regenerate. The selection resets to whole notebook only when the
/// notebook changes, never on a reload, and an emptied selection stays empty.
@MainActor
final class FolderScopeModel: ObservableObject {
    @Published var selection = FolderScopeSelection()
    @Published private(set) var sources: [Source] = []
    @Published private(set) var folders: [FolderSource] = []
    @Published private(set) var sets: [SourceSet] = []

    private var store: NotebookStore?
    private var notebookId: Int64?

    func configure(store: NotebookStore) { self.store = store }

    func reload(notebookId: Int64) throws {
        guard let store else { return }
        if self.notebookId != notebookId {
            self.notebookId = notebookId
            selection = FolderScopeSelection()
        }
        // Published sources, including those whose latest refresh failed.
        sources = try store.sources(notebookId: notebookId).filter { $0.id != nil && $0.publishedRevisionId != nil }
        folders = try store.folders(notebookId: notebookId)
        sets = try store.sourceSets(notebookId: notebookId)
    }

    /// The typed scope for this turn, with saved-set membership read now.
    func resolveForTurn() throws -> RetrievalScope {
        guard let store, let notebookId else { return .all }
        return try store.resolveFolderScope(notebookId: notebookId, selection: selection)
    }

    var isEmptySelection: Bool {
        !selection.wholeNotebook && selection.sourceIds.isEmpty && selection.folderIds.isEmpty && selection.setIds.isEmpty
    }

    var selectedCount: Int { selection.sourceIds.count + selection.folderIds.count + selection.setIds.count }

    func setWholeNotebook(_ whole: Bool) { selection.wholeNotebook = whole }

    /// Any checkbox switches to selected mode; selecting every row never
    /// switches back to whole notebook.
    func toggle(source id: Int64, _ on: Bool) { selection.wholeNotebook = false; update(&selection.sourceIds, id, on) }
    func toggle(folder id: Int64, _ on: Bool) { selection.wholeNotebook = false; update(&selection.folderIds, id, on) }
    func toggle(set id: Int64, _ on: Bool) { selection.wholeNotebook = false; update(&selection.setIds, id, on) }

    /// Personas select their saved set by ID.
    func apply(setId: Int64) { selection = FolderScopeSelection(wholeNotebook: false, setIds: [setId]) }

    func saveCurrent(name: String) throws {
        guard let store, let notebookId else { return }
        _ = try store.saveFolderScopeSet(notebookId: notebookId, name: name, selection: selection)
        try reload(notebookId: notebookId)
    }

    func delete(set id: Int64) throws {
        guard let store, let notebookId else { return }
        try store.deleteSourceSet(id: id)
        try reload(notebookId: notebookId)
    }

    private func update(_ set: inout Set<Int64>, _ id: Int64, _ on: Bool) {
        if on { set.insert(id) } else { set.remove(id) }
    }
}
