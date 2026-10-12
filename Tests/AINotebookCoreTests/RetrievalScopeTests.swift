import XCTest
@testable import AINotebookCore

final class RetrievalScopeTests: XCTestCase {
    private func decode(_ any: Any) throws -> RetrievalScope {
        try JSONDecoder().decode(RetrievalScope.self, from: JSONSerialization.data(withJSONObject: any))
    }
    private func canonicalObject(_ scope: RetrievalScope) throws -> NSDictionary {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try XCTUnwrap(JSONSerialization.jsonObject(with: enc.encode(scope)) as? NSDictionary)
    }

    func testSharedCases() throws {
        let file = try SharedFixtures.json("contracts/scope-v1.json")
        for c in try XCTUnwrap(file["cases"] as? [[String: Any]]) {
            let name = c["name"] as! String
            if c["error"] as? Bool == true {
                XCTAssertThrowsError(try decode(c["json"]!), name)
                continue
            }
            let scope = try decode(c["json"]!)
            XCTAssertEqual(scope.isEmptySelection, c["isEmptySelection"] as? Bool, name)
            let expected = (c["canonical"] ?? c["json"]) as! NSDictionary
            XCTAssertEqual(try canonicalObject(scope), expected, name)
        }
        for c in try XCTUnwrap(file["unionCases"] as? [[String: Any]]) {
            let inputs = try (c["inputs"] as! [Any]).map(decode)
            XCTAssertEqual(RetrievalScope.union(inputs), try decode(c["expected"]!), c["name"] as? String ?? "")
        }
    }
}
