/// The chat scope the user picked. Whole notebook resolves to `.all`; selected
/// mode is always an explicit selection — an empty selection never becomes
/// "all". Saved sets stay IDs and contribute their *current* members per turn;
/// folders stay folder IDs so membership is evaluated live per turn.
public struct FolderScopeSelection: Sendable, Equatable {
    public var wholeNotebook: Bool
    public var sourceIds: Set<Int64>
    public var folderIds: Set<Int64>
    public var setIds: Set<Int64>

    public init(wholeNotebook: Bool = true, sourceIds: Set<Int64> = [],
                folderIds: Set<Int64> = [], setIds: Set<Int64> = []) {
        self.wholeNotebook = wholeNotebook
        self.sourceIds = sourceIds
        self.folderIds = folderIds
        self.setIds = setIds
    }

    public func resolved(setScopes: [Int64: RetrievalScope]) -> RetrievalScope {
        if wholeNotebook { return .all }
        var scopes: [RetrievalScope] = [.selection(sourceIds: sourceIds, folderIds: folderIds)]
        for id in setIds.sorted() {
            // Persisted source sets always represent an explicit selection.
            if let scope = setScopes[id], case .selection = scope { scopes.append(scope) }
        }
        return RetrievalScope.union(scopes)
    }
}
