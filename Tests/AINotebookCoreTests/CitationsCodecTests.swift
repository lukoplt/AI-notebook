import XCTest
@testable import AINotebookCore

final class CitationsCodecTests: XCTestCase {
    private struct Case: Decodable {
        let name: String
        let stored: String?
        let expected: [Citation]
    }
    private struct File: Decodable { let cases: [Case] }

    func testSharedFixtureCases() throws {
        let file = try JSONDecoder().decode(File.self, from: SharedFixtures.data("contracts/citations-v2.json"))
        XCTAssertGreaterThanOrEqual(file.cases.count, 27)
        for c in file.cases {
            XCTAssertEqual(CitationsCodec.decode(c.stored), c.expected, c.name)
        }
    }

    func testEncodeEmptyIsNil() {
        XCTAssertNil(CitationsCodec.encode([]))
    }

    func testLegacyOnlyCitationsEncodeAsLegacyArray() throws {
        let raw = try XCTUnwrap(CitationsCodec.encode([
            Citation(marker: 1, chunkId: 10, sourceId: 2, snippet: "a")
        ]))
        XCTAssertTrue(raw.hasPrefix("["), raw)
    }

    func testV2RoundTrip() throws {
        var c = Citation(marker: 2, chunkId: 10, sourceId: 2, snippet: "s")
        c.folderId = 5
        c.relPath = "a/b.md"
        c.spans = [CitationSpan(start: 3, end: 9, pageFrom: nil, pageTo: nil)]
        c.chunkIds = [10]
        c.text = "full passage"
        let raw = try XCTUnwrap(CitationsCodec.encode([c]))
        XCTAssertTrue(raw.hasPrefix("{"), raw)
        XCTAssertEqual(CitationsCodec.decode(raw), [c])
    }

    @MainActor
    func testMessageRowWithCorruptCitationsStillLoads() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: nb.id!, title: "S")
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO messages(session_id, role, content, citations_json, created_at)
                VALUES (?, 'assistant', 'hi', '{broken', ?)
                """, arguments: [session.id!, Date()])
        }
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0].citations, [])
    }

    @MainActor
    func testMixedValidInvalidItemsRoundTripThroughStore() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "N")
        let session = try store.createChatSession(notebookId: nb.id!, title: "S")
        let raw = #"[{"marker":1,"chunkId":10,"sourceId":2,"snippet":"ok"},{"marker":"x"}]"#
        try store.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO messages(session_id, role, content, citations_json, created_at)
                VALUES (?, 'assistant', 'hi', ?, ?)
                """, arguments: [session.id!, raw, Date()])
        }
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs[0].citations, [Citation(marker: 1, chunkId: 10, sourceId: 2, snippet: "ok")])
    }
}
