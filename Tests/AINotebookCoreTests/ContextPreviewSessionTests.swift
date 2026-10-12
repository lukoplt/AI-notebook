import XCTest
import CryptoKit
@testable import AINotebookCore

@MainActor
final class ContextPreviewSessionTests: XCTestCase {
    func testInvalidLimitPreconditions() throws {
        let variable = "WP8_PREVIEW_LIMIT_CASE"
        if let limitCase = ProcessInfo.processInfo.environment[variable] {
            switch limitCase {
            case "turns": _ = ContextPreviewSession(maxTurns: 0, maxBytes: 1)
            case "bytes": _ = ContextPreviewSession(maxTurns: 1, maxBytes: -1)
            default: XCTFail("Unknown precondition case")
            }
            return
        }
        for limitCase in ["turns", "bytes"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest", "AINotebookCoreTests.ContextPreviewSessionTests/testInvalidLimitPreconditions",
                               Bundle(for: Self.self).bundlePath]
            child.environment = [variable: limitCase]
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationReason, .uncaughtSignal, limitCase)
        }
    }

    func testDraftPressureSameKeyGenerationsAndSessionClear() async {
        let cache = ContextPreviewSession(maxTurns: 2, maxBytes: 4)
        let key = Data(repeating: 1, count: 32)
        let first = await cache.beginDraft(sessionId: 1, key: key)
        let second = await cache.beginDraft(sessionId: 1, key: key)
        let stale = await cache.completeDraft(generation: first, key: key, bytes: Data([9]))
        let ready = await cache.completeDraft(generation: second, key: key, bytes: Data([1, 2, 3, 4]))
        let retained = await cache.retain(Data([8]), sessionId: 2, assistantId: 1)
        await cache.clear(sessionId: 2)
        let state = await cache.state
        let draft = await cache.draft(key: key)
        let wrongPromotion = await cache.promoteDraft(sessionId: 2, assistantId: 2)
        XCTAssertFalse(stale); XCTAssertTrue(ready); XCTAssertFalse(retained); XCTAssertFalse(wrongPromotion)
        XCTAssertEqual(state.generation, second); XCTAssertEqual(state.retainedBytes, 4)
        XCTAssertEqual(draft, Data([1, 2, 3, 4]))
    }

    func testOversizedReplacementPreservesFIFOAndDraft() async {
        let cache = ContextPreviewSession(maxTurns: 2, maxBytes: 4)
        _ = await cache.retain(Data([1]), sessionId: 1, assistantId: 1)
        _ = await cache.retain(Data([2]), sessionId: 1, assistantId: 2)
        let rejected = await cache.retain(Data(repeating: 0, count: 5), sessionId: 1, assistantId: 1)
        _ = await cache.retain(Data([3]), sessionId: 1, assistantId: 3)
        let gone = await cache.sent(sessionId: 1, assistantId: 1)
        let preserved = await cache.sent(sessionId: 1, assistantId: 2)
        XCTAssertFalse(rejected); XCTAssertNil(gone); XCTAssertEqual(preserved, Data([2]))
        let key = Data(repeating: 2, count: 32)
        let generation = await cache.beginDraft(sessionId: 1, key: key)
        _ = await cache.completeDraft(generation: generation, key: key, bytes: Data([4]))
        let oversize = await cache.completeDraft(generation: generation, key: key, bytes: Data(repeating: 9, count: 5))
        let draft = await cache.draft(key: key)
        XCTAssertFalse(oversize); XCTAssertEqual(draft, Data([4]))
    }

    func testEmptyDraftAtZeroByteLimitCanBePromoted() async {
        let cache = ContextPreviewSession(maxTurns: 1, maxBytes: 0)
        let key = Data(repeating: 0, count: 32)
        let generation = await cache.beginDraft(sessionId: 1, key: key)
        let completed = await cache.completeDraft(generation: generation, key: key, bytes: Data())
        let promoted = await cache.promoteDraft(sessionId: 1, assistantId: 1)
        let sent = await cache.sent(sessionId: 1, assistantId: 1)
        let draft = await cache.draft(key: key)
        let state = await cache.state
        XCTAssertTrue(completed); XCTAssertTrue(promoted); XCTAssertEqual(sent, Data()); XCTAssertNil(draft)
        XCTAssertEqual(state.generation, generation + 1); XCTAssertEqual(state.retainedBytes, 0)
    }

    func testSharedPreviewOperations() async throws {
        let rows = try ContextPackFixtures.cases("preview")
        XCTAssertEqual(rows.count, 13)
        for row in rows {
            let input = row["input"] as! [String: Any]
            let operations = input["operations"] as! [[String: Any]]
            let expected = (row["expected"] as! [String: Any])["states"] as! [[String: Any]]
            let cache = ContextPreviewSession(maxTurns: input["maxTurns"] as? Int ?? 5,
                                              maxBytes: input["maxBytes"] as? Int ?? 33_554_432)
            var activeKey: Data?
            var activeSession: Int64?
            var knownKeys = Set<Data>()
            var knownEntries = Set<EntryID>()
            for (index, operation) in operations.enumerated() {
                let message = "\(row["name"] as! String) operation \(index)"
                let kind = operation["kind"] as! String
                let session = (operation["sessionId"] as? NSNumber)?.int64Value
                let assistant = (operation["assistantId"] as? NSNumber)?.int64Value
                let key = try operationKey(operation)
                if let key { knownKeys.insert(key) }
                var result: Any = NSNull()
                switch kind {
                case "retain":
                    knownEntries.insert(EntryID(session: session!, assistant: assistant!))
                    result = await cache.retain(payload(operation), sessionId: session!, assistantId: assistant!)
                case "sent":
                    result = await cache.sent(sessionId: session!, assistantId: assistant!) != nil
                case "beginDraft":
                    activeKey = key; activeSession = session
                    result = await cache.beginDraft(sessionId: session!, key: key!)
                case "completeDraft":
                    result = await cache.completeDraft(generation: (operation["generation"] as! NSNumber).uint64Value,
                                                       key: key!, bytes: payload(operation))
                case "draft":
                    result = await cache.draft(key: key!) != nil
                case "changeIntent":
                    let unchanged = activeKey == key
                    result = unchanged
                    if !unchanged { await cache.invalidateDraft(); activeKey = nil; activeSession = nil }
                case "invalidateDraft":
                    await cache.invalidateDraft(); activeKey = nil; activeSession = nil
                case "clear":
                    await cache.clear(sessionId: session!)
                    if activeSession == session { activeKey = nil; activeSession = nil }
                case "promoteDraft":
                    result = await cache.promoteDraft(sessionId: session!, assistantId: assistant!)
                    if result as? Bool == true {
                        knownEntries.insert(EntryID(session: session!, assistant: assistant!))
                        activeKey = nil; activeSession = nil
                    }
                default: XCTFail("Unknown fixture operation: \(kind)")
                }
                let state = await cache.state
                let actual: [String: Any] = [
                    "retained": state.entries.map { ["sessionId": $0.sessionId, "assistantId": $0.assistantId, "bytes": $0.byteCount] as [String: Any] },
                    "retainedIds": state.entries.map(\.assistantId), "retainedBytes": state.retainedBytes,
                    "draftBytes": state.draftBytes, "draftReady": state.draftReady,
                    "draftSessionId": state.draftSessionId.map { $0 as Any } ?? NSNull(),
                    "generation": state.generation, "result": result
                ]
                XCTAssertEqual(actual as NSDictionary, expected[index] as NSDictionary, message)
                for entry in knownEntries {
                    let bytes = await cache.sent(sessionId: entry.session, assistantId: entry.assistant)
                    let wanted = state.entries.first { $0.sessionId == entry.session && $0.assistantId == entry.assistant }
                    XCTAssertEqual(bytes?.count, wanted?.byteCount, message)
                }
                for knownKey in knownKeys {
                    let bytes = await cache.draft(key: knownKey)
                    XCTAssertEqual(bytes != nil, state.draftReady && knownKey == activeKey, message)
                    if let bytes { XCTAssertEqual(bytes.count, state.draftBytes, message) }
                }
            }
        }
    }

    func testByteBudgetIsGlobalAcrossSessions() async {
        let cache = ContextPreviewSession()
        let bytes = Data(repeating: 120, count: 12 * 1024 * 1024)
        _ = await cache.retain(bytes, sessionId: 1, assistantId: 1)
        _ = await cache.retain(bytes, sessionId: 2, assistantId: 2)
        _ = await cache.retain(bytes, sessionId: 1, assistantId: 3)
        let evicted = await cache.sent(sessionId: 1, assistantId: 1)
        let retained = await cache.retainedBytes
        XCTAssertNil(evicted)
        XCTAssertEqual(retained, 24 * 1024 * 1024)
    }

    func testZeroByteLimitAndValueIsolation() async {
        let cache = ContextPreviewSession(maxTurns: 1, maxBytes: 0)
        let accepted = await cache.retain(Data(), sessionId: 1, assistantId: 1)
        let rejected = await cache.retain(Data([1]), sessionId: 1, assistantId: 1)
        let value = await cache.sent(sessionId: 1, assistantId: 1)
        XCTAssertTrue(accepted); XCTAssertFalse(rejected); XCTAssertEqual(value, Data())
        let isolated = ContextPreviewSession(maxTurns: 1, maxBytes: 10)
        var data = Data([1, 2])
        _ = await isolated.retain(data, sessionId: 1, assistantId: 1)
        data[0] = 3
        var returned = await isolated.sent(sessionId: 1, assistantId: 1)!
        returned[0] = 4
        let original = await isolated.sent(sessionId: 1, assistantId: 1)
        XCTAssertEqual(original, Data([1, 2]))
    }

    private struct EntryID: Hashable { let session: Int64; let assistant: Int64 }

    private func payload(_ operation: [String: Any]) -> Data {
        let value = operation["payload"] as! [String: Any]
        return Data(String(repeating: value["text"] as! String, count: value["repeat"] as? Int ?? 1).utf8)
    }

    // Task 8 owns the production typed intent/key. These fixtures exercise Task 6's
    // opaque digest interface using the same canonical SHA-256 input convention.
    private func operationKey(_ operation: [String: Any]) throws -> Data? {
        if var intent = operation["intent"] as? [String: Any] {
            intent.removeValue(forKey: "displayLanguage")
            if var scope = intent["scope"] as? [String: Any] {
                for field in ["sourceIds", "folderIds"] {
                    if let ids = scope[field] as? [Int64] { scope[field] = Set(ids).sorted() }
                }
                intent["scope"] = scope
            }
            return Data(SHA256.hash(data: try PreparedContextRequestJSON.canonicalData(intent)))
        }
        guard let hex = operation["key"] as? String else { return nil }
        let characters = Array(hex)
        return Data(stride(from: 0, to: characters.count, by: 2).map { UInt8(String(characters[$0...($0 + 1)]), radix: 16)! })
    }
    func testEvictionAndOversizeRejection() async {
        let cache = ContextPreviewSession(maxTurns: 2, maxBytes: 6)
        _ = await cache.retain(Data("á".utf8), sessionId: 1, assistantId: 1)
        _ = await cache.retain(Data("bb".utf8), sessionId: 1, assistantId: 2)
        _ = await cache.sent(sessionId: 1, assistantId: 1)
        _ = await cache.retain(Data("cc".utf8), sessionId: 1, assistantId: 3)
        let gone = await cache.sent(sessionId: 1, assistantId: 1)
        let kept = await cache.sent(sessionId: 1, assistantId: 2)
        XCTAssertNil(gone); XCTAssertEqual(kept, Data("bb".utf8))
        let accepted = await cache.retain(Data(repeating: 120, count: 7), sessionId: 1, assistantId: 4)
        let bytes = await cache.retainedBytes
        XCTAssertFalse(accepted); XCTAssertEqual(bytes, 4)
    }
    func testStaleCompletionCannotReplaceNewDraft() async {
        let cache = ContextPreviewSession()
        let a = Data(repeating: 1,count: 32), b = Data(repeating: 2,count: 32)
        let first = await cache.beginDraft(sessionId: 1,key: a)
        let second = await cache.beginDraft(sessionId: 1,key: b)
        let stale = await cache.completeDraft(generation: first, key: a, bytes: Data("old".utf8))
        let current = await cache.completeDraft(generation: second, key: b, bytes: Data("new".utf8))
        let value = await cache.draft(key: b)
        XCTAssertFalse(stale); XCTAssertTrue(current); XCTAssertEqual(value, Data("new".utf8))
    }
}
