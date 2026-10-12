import XCTest
import GRDB
@testable import AINotebookCore

/// WP9: v18 upgrade → multilingual folder ingestion → scoped context pack →
/// persisted v2 citations → restart, through the real Core graph.
@MainActor
final class ReleaseUpgradeChatTests: XCTestCase {

    func testFixtureScenarioNamesAreExactlySupported() throws {
        let fixture = try ReleaseFixture.load()
        XCTAssertEqual(fixture.contract, "release-integration")
        XCTAssertEqual(fixture.version, 1)
        XCTAssertEqual(fixture.cases.map(\.name), ReleaseFixture.supportedCases)
    }

    func testFolderSessionUsesRetrievalEndpointIdentity() throws {
        for row in try ReleaseFixture.load().endpointCases {
            let type = try XCTUnwrap(ProviderType(rawValue: row.type))
            let config = ProviderConfig(id: "wp9", type: type, name: "WP9", baseURL: row.root, privacyAcknowledged: true)
            let session = try FolderEmbeddingSession(config: config, model: "wp9-2d", apiKey: nil, modelDigest: nil,
                                                     queryFormatVersion: "1", docFormatVersion: "1")
            XCTAssertEqual(session.selection.endpointRevision, row.expected, row.root)
            XCTAssertEqual(try session.identity(dims: 2).endpointRevision,
                           EmbeddingEndpointRevision.make(type: type, normalizedRoot: try ProviderAPIRoot.normalize(row.root)))
        }
    }

    func testUpgradeFolderChatAndCitationReload() async throws {
        let h = try await ReleaseHarness.open()
        do {
            let row = h.fixture.caseNamed("upgrade-chat")
            XCTAssertEqual(try h.integer("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"), 1)
            let legacy = try h.store.messages(sessionId: 31)
            XCTAssertEqual(legacy.first?.content, "saved answer")
            XCTAssertEqual(legacy.first?.citations.first?.chunkId, 1101)
            XCTAssertTrue(legacy.first?.citations.first?.spans.isEmpty ?? false)

            let handle = try await h.prepare()
            XCTAssertTrue(try h.store.messages(sessionId: h.sessionId).isEmpty, "prepare must write nothing")
            try await h.assertPack(handle.request, caseName: row.name)

            let reply = try await h.send(handle)
            let captured = await h.transport.requests
            XCTAssertEqual(captured, [try PreparedContextRequestJSON.encode(handle.request)])
            XCTAssertEqual(reply.citations.map(\.marker), row.expected.savedMarkers)
            for citation in reply.citations {
                XCTAssertEqual(citation, handle.request.citationMap.first { $0.marker == citation.marker })
            }
            let assistantId = try XCTUnwrap(reply.id)
            let raw = try h.rawCitations(assistantId: assistantId)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
            XCTAssertEqual(json["v"] as? Int, row.expected.citationVersion)
            let saved = reply.citations

            await h.close()
            try await h.reopen()
            XCTAssertEqual(try h.store.messages(sessionId: h.sessionId).last?.citations, saved)
            XCTAssertEqual(try h.store.folders(notebookId: h.notebookId).count, 1)
            let preview = await h.previews.sent(sessionId: h.sessionId, assistantId: assistantId)
            XCTAssertNil(preview, "in-memory preview must not survive a restart")
            await h.close()
            try h.removeTemporaryFiles()
        } catch {
            await h.close()
            try? h.removeTemporaryFiles()
            throw error
        }
    }

    func testExplicitEmptyScopeDoesNotEmbedOrCite() async throws {
        let h = try await ReleaseHarness.open()
        do {
            let row = h.fixture.caseNamed("empty-selection")
            let before = await h.queryEmbedding.calls
            let handle = try await h.prepare(scope: .selection(sourceIds: [], folderIds: []))
            XCTAssertEqual(handle.request.citationMap.count, row.expected.citations)
            let after = await h.queryEmbedding.calls
            XCTAssertEqual(after - before, row.expected.queryEmbeddingCalls)
            XCTAssertFalse(handle.request.messages.flatMap(\.sections).contains { $0.kind == "map" })
            let reply = try await h.send(handle)
            XCTAssertTrue(reply.citations.isEmpty)
            await h.close()
            try h.removeTemporaryFiles()
        } catch {
            await h.close()
            try? h.removeTemporaryFiles()
            throw error
        }
    }

    func testZeroEvidenceBudgetPersistsNoCitations() async throws {
        let h = try await ReleaseHarness.open()
        do {
            let row = h.fixture.caseNamed("zero-evidence")
            let handle = try await h.prepare(cap: try XCTUnwrap(row.cap))
            XCTAssertEqual(handle.request.citationMap.count, row.expected.citations)
            XCTAssertEqual(handle.request.messages.flatMap(\.sections).filter { $0.kind == "evidence" }.count,
                           row.expected.evidenceSections)
            let reply = try await h.send(handle)
            XCTAssertTrue(reply.citations.isEmpty)
            XCTAssertTrue(try XCTUnwrap(h.store.messages(sessionId: h.sessionId).last).citations.isEmpty)
            await h.close()
            try h.removeTemporaryFiles()
        } catch {
            await h.close()
            try? h.removeTemporaryFiles()
            throw error
        }
    }
}
