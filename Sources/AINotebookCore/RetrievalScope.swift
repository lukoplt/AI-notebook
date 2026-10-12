/// Chat retrieval scope (contract v1, `docs/contracts/folder-rag-v1.md` §1).
/// `.selection` is the union of explicit sources and the *current* members of
/// the listed folders; an empty selection means zero results, never "all".
public enum RetrievalScope: Equatable, Hashable, Sendable, Codable {
    case all
    case selection(sourceIds: Set<Int64>, folderIds: Set<Int64>)

    public var isEmptySelection: Bool {
        if case let .selection(s, f) = self { return s.isEmpty && f.isEmpty }
        return false
    }

    public static func union(_ scopes: [RetrievalScope]) -> RetrievalScope {
        var sources = Set<Int64>(), folders = Set<Int64>()
        for scope in scopes {
            switch scope {
            case .all: return .all
            case let .selection(s, f): sources.formUnion(s); folders.formUnion(f)
            }
        }
        return .selection(sourceIds: sources, folderIds: folders)
    }

    private enum CodingKeys: String, CodingKey { case kind, sourceIds, folderIds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "all": self = .all
        case "selection":
            self = .selection(
                sourceIds: Set(try c.decode([Int64].self, forKey: .sourceIds)),
                folderIds: Set(try c.decode([Int64].self, forKey: .folderIds)))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown scope kind \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .all:
            try c.encode("all", forKey: .kind)
        case let .selection(s, f):
            try c.encode("selection", forKey: .kind)
            try c.encode(s.sorted(), forKey: .sourceIds)
            try c.encode(f.sorted(), forKey: .folderIds)
        }
    }
}
