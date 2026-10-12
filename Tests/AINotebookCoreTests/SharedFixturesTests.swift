import XCTest

final class SharedFixturesTests: XCTestCase {
    func testConstantsFixtureLoads() throws {
        let obj = try SharedFixtures.json("contracts/constants-v1.json")
        XCTAssertEqual(obj["contract"] as? String, "constants")
        XCTAssertEqual(obj["version"] as? Int, 1)
    }

    /// Every contract fixture must carry the envelope; case names must be unique.
    func testEveryContractFixtureHasEnvelope() throws {
        let files = try SharedFixtures.contractFiles()
        XCTAssertFalse(files.isEmpty)
        for url in files {
            let obj = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                url.lastPathComponent)
            XCTAssertNotNil(obj["contract"] as? String, url.lastPathComponent)
            XCTAssertNotNil(obj["version"] as? Int, url.lastPathComponent)
            // Value tables without cases: constants-v1, ui-tokens-v1.
            if url.lastPathComponent.hasPrefix("constants-") || url.lastPathComponent.hasPrefix("ui-tokens-") {
                continue
            }
            let cases = try XCTUnwrap(obj["cases"] as? [[String: Any]], url.lastPathComponent)
            let names = cases.compactMap { $0["name"] as? String }
            XCTAssertEqual(names.count, cases.count, "every case needs a name: \(url.lastPathComponent)")
            XCTAssertEqual(Set(names).count, names.count, "duplicate case name: \(url.lastPathComponent)")
        }
    }
}
