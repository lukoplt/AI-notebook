import Foundation
@testable import AINotebookCore

enum ContextPackFixtures {
    static func cases(_ kind: String) throws -> [[String: Any]] {
        let root = try SharedFixtures.json("contracts/context-pack-v1.json")
        return (root["cases"] as! [[String: Any]]).filter { $0["kind"] as? String == kind }
    }

    static func decode<T: Decodable>(_ object: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    static func input(_ name: String) throws -> ContextPackInput {
        let row = try cases("build").first { $0["name"] as? String == name }!
        return try decode(row["input"]!, as: ContextPackInput.self)
    }
}
