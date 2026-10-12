import XCTest
import GRDB
import Foundation
@testable import AINotebookCore

private struct IntegrationNoEmbeddingClient: EmbeddingProducing {
    enum Unexpected: Error { case providerCalled }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { throw Unexpected.providerCalled }
}

private final class IntegrationModelKey: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String
    init(_ value: String) { storage = value }
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

private actor IntegrationEmbeddingClient: EmbeddingProducing {
    private let vectors: [String: [Float]]
    private let fallback: [Float]
    private let suspendFirst: Bool
    private var calls: [(String, [String])] = []
    private var pending: CheckedContinuation<[[Float]], Error>?
    private var started: [CheckedContinuation<Void, Never>] = []
    init(vectors: [String: [Float]] = [:], fallback: [Float] = [1, 0], suspendFirst: Bool = false) {
        self.vectors = vectors; self.fallback = fallback; self.suspendFirst = suspendFirst
    }
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls.append((model, inputs))
        if suspendFirst && calls.count == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                for waiter in started { waiter.resume() }
                started.removeAll()
            }
        }
        return inputs.map { _ in vectors[model] ?? fallback }
    }
    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { started.append($0) }
    }
    func resume(throwing error: Error? = nil) {
        guard let continuation = pending, let call = calls.first else { return }
        pending = nil
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: call.1.map { _ in vectors[call.0] ?? fallback }) }
    }
    func models() -> [String] { calls.map(\.0) }
    func inputs() -> [[String]] { calls.map(\.1) }
}

private struct IntegrationFixedExtractor: TextExtractor {
    let extracted: ExtractedText
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText { extracted }
}

private actor IntegrationSuspendedExtractor: TextExtractor {
    private var count = 0
    private var pending: [Int: CheckedContinuation<ExtractedText, Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func extract(from url: URL, kind: SourceType) async throws -> ExtractedText {
        count += 1
        let call = count
        return try await withCheckedThrowingContinuation { continuation in
            pending[call] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func waitForCalls(_ value: Int) async {
        if count >= value { return }
        await withCheckedContinuation { waiters.append((value, $0)) }
    }
    func resolve(_ call: Int, text: String) {
        pending.removeValue(forKey: call)?.resume(returning: ExtractedText(title: "fixture", text: text))
    }
}

private actor IntegrationCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

private final class IntegrationLeaseClock: IngestLeaseClock, @unchecked Sendable {
    private let lock = NSLock()
    private var time: Int64
    private var sleepers: [UUID: (Int64, CheckedContinuation<Void, Error>)] = [:]
    private var observed: Set<Int64> = []
    private var observers: [(Int64, CheckedContinuation<Void, Never>)] = []
    init(now: Int64) { time = now }
    func now() -> Int64 { lock.lock(); defer { lock.unlock() }; return time }
    func wait(until deadline: Int64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                observed.insert(deadline)
                let ready = observers.filter { $0.0 == deadline }
                observers.removeAll { $0.0 == deadline }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= time {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers[id] = (deadline, continuation)
                    lock.unlock()
                }
                for observer in ready { observer.1.resume() }
            }
        } onCancel: {
            self.lock.lock()
            let sleeper = self.sleepers.removeValue(forKey: id)
            self.lock.unlock()
            sleeper?.1.resume(throwing: CancellationError())
        }
    }
    func set(_ value: Int64, wake: Bool = false) {
        lock.lock()
        time = value
        let ready = wake ? sleepers.filter { $0.value.0 <= value } : [:]
        for id in ready.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for sleeper in ready.values { sleeper.1.resume() }
    }
    func waitForDeadline(_ deadline: Int64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if observed.contains(deadline) { lock.unlock(); continuation.resume() }
            else { observers.append((deadline, continuation)); lock.unlock() }
        }
    }
}

@MainActor
final class StorageIntegrationTests: XCTestCase {
    func testReplacementAndLexicalOnlyFromSharedFixture() async throws {
        let root = try SharedFixtures.json("contracts/storage-integration-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let c = try XCTUnwrap(cases.first { $0["name"] as? String == "replacement" })
        let old = try XCTUnwrap(c["old"] as? String)
        let new = try XCTUnwrap(c["new"] as? String)
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "upgrade")
        let s = try store.createSource(notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: s.id!, chunks: [ChunkDraft(text: old, tokenCount: 1)])
        let oldID = try XCTUnwrap(store.chunks(sourceId: s.id!).first?.id)
        try store.replaceChunks(sourceId: s.id!, chunks: [ChunkDraft(text: new, tokenCount: 1)])
        let retained = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks WHERE id=?", arguments: [oldID])
        }
        XCTAssertEqual(retained, 1)
        let retriever = Retriever(store: store, client: IntegrationNoEmbeddingClient(), model: "unconfigured")
        let absent = try await retriever.search(notebookId: nb.id!, query: old)
        let found = try await retriever.search(notebookId: nb.id!, query: new)
        XCTAssertTrue(absent.isEmpty)
        XCTAssertEqual(found.map(\.sourceId), [s.id!])
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(retained, expected["retainedOldChunkCount"] as? Int)
        XCTAssertEqual(absent.count, expected["oldHits"] as? Int)
        XCTAssertEqual(found.count, expected["newHits"] as? Int)
        XCTAssertEqual(try store.chunks(sourceId: s.id!).map(\.text), expected["visibleTexts"] as? [String])
        try assertEvents(c, ["replaceChunks", "captureOldChunk", "replaceChunks", "search", "search"])

        let noVector = try fixture("no-vector-provider-call")
        try assertEvents(noVector, ["publish", "search"])
        let fresh = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookID = try XCTUnwrap(fresh.createNotebook(name: "lexical").id)
        let service = IngestionService(store: fresh)
        let source = try await service.ingestRawText(title: "lexical", text: XCTUnwrap(noVector["text"] as? String), into: notebookID)
        XCTAssertNotNil(source.publishedRevisionId)
        XCTAssertEqual(source.currentRevision, source.publishedRevisionId)
        let client = IntegrationEmbeddingClient()
        let search = Retriever(store: fresh, client: client, model: try XCTUnwrap(noVector["modelKey"] as? String))
        let hits = try await search.search(notebookId: notebookID, query: XCTUnwrap(noVector["query"] as? String))
        let noVectorExpected = try XCTUnwrap(noVector["expected"] as? [String: Any])
        XCTAssertEqual(hits.count, noVectorExpected["hits"] as? Int)
        let calls = await client.models()
        XCTAssertEqual(calls.count, noVectorExpected["providerCalls"] as? Int)
    }

    func testScalarAndPDFSpans() async throws {
        for name in ["scalar-empty", "scalar-whitespace", "scalar-combining", "scalar-supplementary", "scalar-repeated", "scalar-overlap", "scalar-long-word", "scalar-pdf-crossing", "scalar-text"] {
            let c = try fixture(name)
            let text = try XCTUnwrap(c["text"] as? String)
            let pages = try XCTUnwrap(c["pageStarts"] as? [[Int]]).map { (offset: $0[0], page: $0[1]) }
            let chunks = ScalarChunker.chunk(text, pageStarts: pages, window: try XCTUnwrap(c["window"] as? Int), overlap: try XCTUnwrap(c["overlap"] as? Int))
            try assertChunks(chunks, expected: XCTUnwrap(c["expected"] as? [String: Any]))
        }
        let c = try fixture("scalar-text")
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookID = try XCTUnwrap(store.createNotebook(name: "spans").id)
        let source = try await IngestionService(store: store).ingestRawText(title: "unicode", text: XCTUnwrap(c["text"] as? String), into: notebookID)
        try assertPublishedSource(store, source: source, expected: XCTUnwrap(c["expected"] as? [String: Any]), chunker: 2)

        let pdf = try fixture("pdf-pages")
        let pdfExpected = try XCTUnwrap(pdf["expected"] as? [String: Any])
        let extracted = ExtractedText(title: "pdf", text: try XCTUnwrap(pdf["extractedText"] as? String), pageHints: try XCTUnwrap(pdf["pageHints"] as? [Int]))
        let assembled = ExtractedRevisionAssembly.make(extracted: extracted, kind: .pdf)
        XCTAssertEqual(assembled.pageStarts.map { [$0.offset, $0.page] }, pdfExpected["pageStarts"] as? [[Int]])
        for hints in [extracted.pageHints, nil] {
            let fake = IntegrationFixedExtractor(extracted: ExtractedText(title: extracted.title, text: extracted.text, pageHints: hints))
            let result = try await IngestionService(store: store, pdf: fake).ingestFile(URL(fileURLWithPath: "/fixture/pages.pdf"), into: notebookID)
            try assertPublishedSource(store, source: result, expected: pdfExpected, chunker: 2)
        }
        for ext in ["docx", "pptx", "xlsx"] {
            let extractor = IntegrationFixedExtractor(extracted: ExtractedText(title: "office", text: try XCTUnwrap(c["text"] as? String)))
            let result = try await IngestionService(store: store, office: extractor).ingestFile(URL(fileURLWithPath: "/fixture/office.\(ext)"), into: notebookID)
            let revision = try XCTUnwrap(store.revision(id: XCTUnwrap(result.publishedRevisionId)))
            XCTAssertEqual(revision.draft.chunkerVersion, 1)
            XCTAssertEqual(revision.draft.textFormatVersion, 1)
            XCTAssertEqual(result.currentRevision, result.publishedRevisionId)
            let chunks = try store.chunks(sourceId: XCTUnwrap(result.id))
            XCTAssertFalse(chunks.isEmpty)
            XCTAssertTrue(chunks.allSatisfy { $0.charStart == nil && $0.charEnd == nil && $0.revisionId == revision.id })
        }
        try await assertRenewingExtraction()
    }

    func testEmptyNotePublishesEmptyRevision() async throws {
        let c = try fixture("empty-note")
        try assertEvents(c, ["indexNote", "indexNote"])
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookID = try XCTUnwrap(store.createNotebook(name: "note").id)
        let noteID = try XCTUnwrap(store.createNote(notebookId: notebookID, title: "note", bodyMd: XCTUnwrap(c["initialBody"] as? String)).id)
        let indexer = NoteIndexer(store: store)
        try await indexer.index(noteId: noteID)
        let sourceID = try XCTUnwrap(store.note(id: noteID)?.autoSourceId)
        let old = try store.chunks(sourceId: sourceID)
        XCTAssertFalse(old.isEmpty)
        let client = IntegrationEmbeddingClient()
        let embedder = Embedder(store: store, client: client, model: "empty-note")
        _ = try await embedder.embedAllPending()
        let originalGeneration = try XCTUnwrap(store.activeGeneration(notebookId: notebookID))
        let originalCalls = await client.models()
        try store.updateNote(id: noteID, title: "note", bodyMd: XCTUnwrap(c["body"] as? String))
        try await indexer.index(noteId: noteID)
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let source = try store.source(id: sourceID)
        XCTAssertEqual(source != nil, expected["shadowSourceExists"] as? Bool)
        XCTAssertEqual(source?.publishedRevisionId != nil, expected["published"] as? Bool)
        XCTAssertEqual(try store.chunks(sourceId: sourceID).count, expected["visibleChunks"] as? Int)
        let revision = try XCTUnwrap(store.revision(id: XCTUnwrap(source?.publishedRevisionId)))
        XCTAssertEqual(revision.draft.canonicalText, c["body"] as? String)
        XCTAssertEqual(revision.draft.chunkerVersion, 2)
        try store.runOnDatabase { db in
            for chunk in old { XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT id FROM source_chunks WHERE id=?", arguments: [chunk.id]), chunk.id) }
        }
        let written = try await embedder.embedAllPending()
        XCTAssertEqual(written, expected["visibleChunks"] as? Int)
        let callsAfterClearing = await client.models()
        XCTAssertEqual(callsAfterClearing, originalCalls, "An empty revision needs no provider batch")
        let currentGeneration = try XCTUnwrap(store.activeGeneration(notebookId: notebookID))
        XCTAssertNotEqual(currentGeneration.id, originalGeneration.id)
        XCTAssertEqual(try store.manifest(generationId: currentGeneration.id).first?.revisionId, revision.id)
        XCTAssertEqual(try store.manifest(generationId: currentGeneration.id).first?.state, "done")
        let hits = try await Retriever(store: store, client: client, model: "empty-note")
            .search(notebookId: notebookID, query: XCTUnwrap(c["initialBody"] as? String))
        XCTAssertEqual(hits.count, expected["visibleChunks"] as? Int)
    }

    func testEmbeddingDrainAndModelSwitch() async throws {
        let c = try fixture("model-switch")
        try assertEvents(c, ["publish", "selectModel", "drain", "selectModel", "drain"])
        let keys = try XCTUnwrap(c["keys"] as? [String])
        let vectors = try XCTUnwrap(c["vectors"] as? [[NSNumber]]).map { $0.map(\.floatValue) }
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let notebookID = try XCTUnwrap(store.createNotebook(name: "models").id)
        let source = try await IngestionService(store: store).ingestRawText(title: "models", text: XCTUnwrap(c["text"] as? String), into: notebookID)
        let key = IntegrationModelKey(keys[0])
        let client = IntegrationEmbeddingClient(vectors: Dictionary(uniqueKeysWithValues: zip(keys, vectors)))
        let embedder = Embedder(store: store, client: client, modelKey: { key.value })
        let firstCount = try await embedder.embedAllPending()
        XCTAssertEqual(firstCount, try store.chunks(sourceId: XCTUnwrap(source.id)).count)
        let first = try XCTUnwrap(store.activeGeneration(notebookId: notebookID))
        XCTAssertEqual(first.identity.modelKey, keys[0])
        key.value = keys[1]
        _ = try await embedder.embedAllPending()
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let calls = await client.models()
        XCTAssertEqual(calls, expected["expectedCalls"] as? [String])
        XCTAssertEqual(try store.activeGeneration(notebookId: notebookID)?.identity.modelKey, expected["activeModelKey"] as? String)
        XCTAssertEqual(try store.generation(id: first.id)?.state, "retired")
        XCTAssertEqual(try store.unembeddedCount(model: keys[1]), 0)
        XCTAssertEqual(try store.embeddings(notebookId: notebookID, model: keys[1]).first?.vector.asData(), EmbeddingVector(values: vectors[1]).asData())
        try store.runOnDatabase { db in XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM index_generations WHERE state='active'"), expected["activeCount"] as? Int) }

        // A settings change during an awaited batch does not activate the captured old key.
        let switchedStore = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let switchedNotebook = try XCTUnwrap(switchedStore.createNotebook(name: "mid-drain").id)
        _ = try await IngestionService(store: switchedStore).ingestRawText(title: "current", text: XCTUnwrap(c["text"] as? String), into: switchedNotebook)
        let live = IntegrationModelKey(keys[0])
        let suspended = IntegrationEmbeddingClient(vectors: Dictionary(uniqueKeysWithValues: zip(keys, vectors)), suspendFirst: true)
        let worker = Embedder(store: switchedStore, client: suspended, modelKey: { live.value })
        let drain = Task { try await worker.embedAllPending() }
        await suspended.waitUntilSuspended()
        live.value = keys[1]
        await suspended.resume()
        _ = try await drain.value
        XCTAssertNil(try switchedStore.activeGeneration(notebookId: switchedNotebook))
        let capturedCalls = await suspended.models()
        XCTAssertTrue(capturedCalls.allSatisfy { $0 == keys[0] })
        live.value = keys[0]
        _ = try await worker.embedAllPending()
        XCTAssertEqual(try switchedStore.activeGeneration(notebookId: switchedNotebook)?.identity.modelKey, keys[0])
        let completionCalls = await suspended.models()
        XCTAssertEqual(completionCalls, capturedCalls, "Completed work activates without another provider batch")
        live.value = keys[1]
        _ = try await worker.embedAllPending()
        XCTAssertEqual(try switchedStore.activeGeneration(notebookId: switchedNotebook)?.identity.modelKey, keys[1])

        // Published R1 remains the embedding work corpus while an unchunked R2 is current.
        let refresh = try fixture("replacement")
        let pendingStore = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        let pendingNotebook = try XCTUnwrap(pendingStore.createNotebook(name: "pending refresh").id)
        let published = try await IngestionService(store: pendingStore).ingestRawText(title: "retained publication",
            text: XCTUnwrap(refresh["old"] as? String), into: pendingNotebook)
        let publishedID = try XCTUnwrap(published.publishedRevisionId)
        let publishedChunk = try XCTUnwrap(pendingStore.chunks(sourceId: XCTUnwrap(published.id)).first)
        let pending = try pendingStore.insertRevision(sourceId: XCTUnwrap(published.id),
            draft: RevisionDraft(contentHash: "pending-refresh", canonicalText: XCTUnwrap(refresh["new"] as? String),
                                 textFormatVersion: 1, chunkerVersion: 2), now: 0)
        let pendingClient = IntegrationEmbeddingClient(fallback: vectors[0])
        let pendingWorker = Embedder(store: pendingStore, client: pendingClient, model: keys[0])
        let publishedWrites = try await pendingWorker.embedAllPending()
        XCTAssertEqual(publishedWrites, 1)
        XCTAssertNil(try pendingStore.activeGeneration(notebookId: pendingNotebook))
        let workID = try pendingStore.runOnDatabase { db in
            try XCTUnwrap(Int64.fetchOne(db, sql: "SELECT id FROM index_generations WHERE notebook_id=? AND state='building' ORDER BY id DESC LIMIT 1", arguments: [pendingNotebook]))
        }
        XCTAssertEqual(try pendingStore.manifest(generationId: workID).first?.revisionId, publishedID)
        XCTAssertEqual(try pendingStore.embeddings(notebookId: pendingNotebook, model: keys[0]).map(\.chunkId), [try XCTUnwrap(publishedChunk.id)])
        XCTAssertEqual(try pendingStore.unembeddedCount(model: keys[0]), 0)
        let callsBeforeRetry = await pendingClient.models()
        let repeatedWrites = try await pendingWorker.embedAllPending()
        XCTAssertEqual(repeatedWrites, 0)
        let callsAfterRetry = await pendingClient.models()
        XCTAssertEqual(callsAfterRetry, callsBeforeRetry)
        XCTAssertEqual(try pendingStore.manifest(generationId: workID).first?.revisionId, publishedID)
        XCTAssertEqual(try pendingStore.source(id: XCTUnwrap(published.id))?.currentRevision, pending.id)
        XCTAssertNil(try pendingStore.activeGeneration(notebookId: pendingNotebook))
        try pendingStore.storeEmbedding(chunkId: XCTUnwrap(publishedChunk.id), model: keys[0], vector: EmbeddingVector(values: vectors[1]))
        XCTAssertEqual(try pendingStore.embeddings(notebookId: pendingNotebook, model: keys[0]).first?.vector.asData(), EmbeddingVector(values: vectors[1]).asData())
        XCTAssertEqual(try pendingStore.manifest(generationId: workID).first?.revisionId, publishedID)
        XCTAssertNil(try pendingStore.activeGeneration(notebookId: pendingNotebook))
    }

    func testReingestDuringEmbeddingDropsStaleBatch() async throws {
        let c = try fixture("reingest-during-embedding")
        try assertEvents(c, ["beginEmbedBatch", "publish", "resumeEmbedBatch", "reconcile"])
        let store = try seeded(c)
        let vector = try XCTUnwrap(c["vector"] as? [NSNumber]).map(\.floatValue)
        let client = IntegrationEmbeddingClient(fallback: vector, suspendFirst: true)
        let embedder = Embedder(store: store, client: client, model: "m")
        let drain = Task { try await embedder.embedAllPending() }
        await client.waitUntilSuspended()
        let text = try XCTUnwrap(c["replacementText"] as? String)
        let service = IngestionService(store: store, plain: IntegrationFixedExtractor(extracted: ExtractedText(title: "new", text: text)))
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET raw_path='/fixture/reingest.txt' WHERE id=1") }
        let returned = try await service.reIngest(sourceId: 1)
        await client.resume()
        let written = try await drain.value
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        XCTAssertEqual(written, expected["staleWrites"] as? Int)
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(expected, "activeId"))
        XCTAssertEqual(try store.manifest(generationId: 2).first?.revisionId, try number(expected, "pendingRevisionId"))
        XCTAssertEqual(try store.manifest(generationId: 2).first?.state, "pending")
        try assertPointers(returned, expected: XCTUnwrap(expected["returnedSource"] as? [String: Any]))
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings WHERE generation_id=2"), expected["staleWrites"] as? Int)
        }
        _ = try await embedder.embedAllPending()
        XCTAssertEqual(try store.unembeddedCount(model: "m"), 0)
        try await assertSupersededExtraction()
    }

    func testReindexKeepsActiveWhileWorkIsEmpty() async throws {
        let c = try fixture("reindex-keeps-active")
        try assertEvents(c, ["deleteAllEmbeddings", "inspectWork", "drain"])
        let store = try seeded(c)
        let key = try XCTUnwrap(c["modelKey"] as? String)
        let pin = try store.pinQuery(notebookId: 1, modelKey: key)
        defer { store.releaseQuery(pin) }
        let before = try store.pinnedEmbeddings(pin)
        try store.deleteAllEmbeddings(model: key)
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let request = try XCTUnwrap(expected["afterRequest"] as? [String: Any])
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(request, "activeId"))
        XCTAssertEqual(try store.embeddings(notebookId: 1, model: key).count, request["workVectorCount"] as? Int)
        XCTAssertEqual(try store.pinnedEmbeddings(pin), before)
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings WHERE generation_id=?", arguments: [try number(request, "buildingId")]), request["buildingVectorCount"] as? Int)
        }
        let client = IntegrationEmbeddingClient(fallback: try XCTUnwrap(c["vector"] as? [NSNumber]).map(\.floatValue))
        _ = try await Embedder(store: store, client: client, model: key).embedAllPending()
        let fill = try XCTUnwrap(expected["afterFill"] as? [String: Any])
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(fill, "activeId"))
        XCTAssertEqual(try store.generation(id: number(request, "activeId"))?.state, fill["previousState"] as? String)
        XCTAssertEqual(try store.generation(id: number(fill, "activeId"))?.state, fill["newState"] as? String)
        XCTAssertEqual(try store.pinnedEmbeddings(pin), before)
    }

    func testPinnedQuerySurvivesActivationAndGC() async throws {
        let c = try fixture("reingest-during-embedding")
        let mixed = try seeded(c)
        let vectorChunk = try XCTUnwrap(mixed.chunks(sourceId: 1).first)
        let newText = try XCTUnwrap(c["replacementText"] as? String)
        try mixed.replaceChunks(sourceId: 1, chunks: [ChunkDraft(text: newText, tokenCount: 1)])
        let lexicalChunk = try XCTUnwrap(mixed.chunks(sourceId: 1).first)
        let mixedHits = try await Retriever(store: mixed, client: IntegrationEmbeddingClient(), model: "m").search(notebookId: 1, query: newText)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: mixedHits.map { ($0.chunkId, $0.snippet) }),
                       [try XCTUnwrap(vectorChunk.id): vectorChunk.text, try XCTUnwrap(lexicalChunk.id): lexicalChunk.text])
        XCTAssertNotEqual(vectorChunk.revisionId, lexicalChunk.revisionId)

        let store = try seeded(c)
        let old = try XCTUnwrap(store.chunks(sourceId: 1).first)
        let client = IntegrationEmbeddingClient(fallback: try XCTUnwrap(c["vector"] as? [NSNumber]).map(\.floatValue), suspendFirst: true)
        let retriever = Retriever(store: store, client: client, model: "m")
        let query = Task { try await retriever.search(notebookId: 1, query: old.text) }
        await client.waitUntilSuspended()
        try store.replaceChunks(sourceId: 1, chunks: [ChunkDraft(text: XCTUnwrap(c["replacementText"] as? String), tokenCount: 1)])
        _ = try await Embedder(store: store, client: IntegrationEmbeddingClient(), model: "m").embedAllPending()
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNotNil(try store.generation(id: 1))
        XCTAssertNotNil(try store.revision(id: XCTUnwrap(old.revisionId)))
        await client.resume()
        let hits = try await query.value
        XCTAssertEqual(hits.map(\.chunkId), [try XCTUnwrap(old.id)])
        XCTAssertEqual(hits.first?.snippet, old.text)
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNil(try store.generation(id: 1))
        XCTAssertNil(try store.revision(id: XCTUnwrap(old.revisionId)))

        // A failed query releases its pin as well.
        let active = try XCTUnwrap(store.activeGeneration(notebookId: 1))
        let failing = IntegrationEmbeddingClient(suspendFirst: true)
        let failingRetriever = Retriever(store: store, client: failing, model: "m")
        let failingQuery = Task { try await failingRetriever.search(notebookId: 1, query: "failure") }
        await failing.waitUntilSuspended()
        try store.retireGeneration(id: active.id)
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNotNil(try store.generation(id: active.id))
        await failing.resume(throwing: IntegrationNoEmbeddingClient.Unexpected.providerCalled)
        do { _ = try await failingQuery.value; XCTFail("Expected provider failure") }
        catch { XCTAssertTrue(error is IntegrationNoEmbeddingClient.Unexpected) }
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNil(try store.generation(id: active.id))

        // A cancelled provider await also releases the pinned generation before propagating cancellation.
        _ = try await Embedder(store: store, client: IntegrationEmbeddingClient(), model: "m").embedAllPending()
        let cancelledActive = try XCTUnwrap(store.activeGeneration(notebookId: 1))
        let cancelling = IntegrationEmbeddingClient(suspendFirst: true)
        let cancelledRetriever = Retriever(store: store, client: cancelling, model: "m")
        let cancelledQuery = Task { try await cancelledRetriever.search(notebookId: 1, query: "cancelled") }
        await cancelling.waitUntilSuspended()
        try store.retireGeneration(id: cancelledActive.id)
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNotNil(try store.generation(id: cancelledActive.id))
        cancelledQuery.cancel()
        await cancelling.resume(throwing: CancellationError())
        do { _ = try await cancelledQuery.value; XCTFail("Expected query cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try store.garbageCollect(notebookId: 1)
        XCTAssertNil(try store.generation(id: cancelledActive.id))
    }

    func testProductionUpgradeAndCitationReopen() async throws {
        let migration = try SharedFixtures.json("contracts/storage-v19.json")
        let cases = try XCTUnwrap(migration["cases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("db.sqlite")
            try FileManager.default.copyItem(at: SharedFixtures.url("storage/v18.sqlite"), to: url)
            let key = c["configuredModelKey"] as? String
            var store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: key)
            defer { try? store.dbQueue.close() }
            try V19TestStore.assertQueries(store, queries: XCTUnwrap(c["queries"] as? [[String: Any]]))
            try store.dbQueue.close()
            store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: key)
            try V19TestStore.assertQueries(store, queries: XCTUnwrap(c["queries"] as? [[String: Any]]))
            if c["name"] as? String == "configured-a" {
                let citationCase = try fixture("citation-after-gc")
                try assertEvents(citationCase, ["persistCitation", "deleteSource", "garbageCollect", "reopen", "readCitation"])
                let raw = try XCTUnwrap(citationCase["citation"] as? [String: Any])
                let fixtureCitation = try JSONDecoder().decode(Citation.self, from: JSONSerialization.data(withJSONObject: raw))
                let notebook = try XCTUnwrap(store.createNotebook(name: "production import").id)
                let source = try await IngestionService(store: store).ingestRawText(title: "evidence", text: XCTUnwrap(fixtureCitation.text), into: notebook)
                XCTAssertEqual(source.currentRevision, source.publishedRevisionId)
                XCTAssertNotNil(source.currentRevision)
                let model = try XCTUnwrap(key)
                _ = try await Embedder(store: store, client: IntegrationEmbeddingClient(), model: model).embedAllPending()
                let hits = try await Retriever(store: store, client: IntegrationEmbeddingClient(), model: model).search(notebookId: notebook, query: XCTUnwrap(fixtureCitation.text))
                let hit = try XCTUnwrap(hits.first)
                XCTAssertEqual(hit.sourceId, source.id)
                var citation = Citation(marker: fixtureCitation.marker, chunkId: hit.chunkId, sourceId: hit.sourceId, snippet: fixtureCitation.snippet)
                citation.revisionId = source.publishedRevisionId
                citation.spans = fixtureCitation.spans
                citation.chunkIds = [hit.chunkId]
                citation.text = fixtureCitation.text
                let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "citation").id)
                let message = try store.appendAssistantMessage(sessionId: session, content: "answer", citations: [citation])
                let legacyJSON = try store.runOnDatabase { db in try String.fetchOne(db, sql: "SELECT citations_json FROM messages WHERE id=41") }
                try store.deleteSource(id: XCTUnwrap(source.id))
                _ = try store.garbageCollect(notebookId: notebook)
                try store.dbQueue.close()
                store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: key)
                let expected = try XCTUnwrap(citationCase["expected"] as? [String: Any])
                XCTAssertEqual(try store.source(id: XCTUnwrap(source.id)) != nil, expected["sourceExists"] as? Bool)
                let persisted = try XCTUnwrap(store.messages(sessionId: session).first { $0.id == message })
                XCTAssertEqual(persisted.citations, [citation])
                XCTAssertEqual(persisted.citations.first?.text, expected["text"] as? String)
                try store.runOnDatabase { db in
                    XCTAssertEqual(try String.fetchOne(db, sql: "SELECT citations_json FROM messages WHERE id=41"), legacyJSON)
                    XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
                }
            }
        }
        let restart = try fixture("restart")
        try assertEvents(restart, ["capturePointers", "close", "reopen", "capturePointers"])
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("db.sqlite")
        var store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: nil)
        defer { try? store.dbQueue.close() }
        try seed(store, with: restart)
        let expected = try XCTUnwrap(restart["expected"] as? [String: Any])
        try assertPointers(XCTUnwrap(store.source(id: 1)), expected: XCTUnwrap(expected["before"] as? [String: Any]))
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(XCTUnwrap(expected["before"] as? [String: Any]), "activeId"))
        try store.dbQueue.close()
        store = try NotebookStore(path: StorePath(fileURL: url), configuredEmbeddingModelKey: nil)
        try assertPointers(XCTUnwrap(store.source(id: 1)), expected: XCTUnwrap(expected["after"] as? [String: Any]))
        XCTAssertEqual(try store.activeGeneration(notebookId: 1)?.id, try number(XCTUnwrap(expected["after"] as? [String: Any]), "activeId"))
    }

    private func assertRenewingExtraction() async throws {
        let c = try fixture("renew-running-extraction")
        try assertEvents(c, ["begin", "renew", "commit"])
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let sourceID = try number(c, "sourceId")
        let initial = try number(events[0], "at"), renewed = try number(events[1], "at"), completed = try number(events[2], "at")
        let text = try XCTUnwrap((events[2]["draft"] as? [String: Any])?["canonicalText"] as? String)
        let store = try seeded(c)
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET raw_path='/fixture/renew.txt' WHERE id=?", arguments: [sourceID]) }
        let clock = IntegrationLeaseClock(now: initial)
        let extractor = IntegrationSuspendedExtractor()
        let callbacks = IntegrationCounter()
        let service = IngestionService(store: store, plain: extractor, onChunksWritten: { await callbacks.increment() }, leaseClock: clock)
        let task = Task { try await service.reIngest(sourceId: sourceID) }
        await extractor.waitForCalls(1)
        await clock.waitForDeadline(renewed)
        clock.set(renewed, wake: true)
        await clock.waitForDeadline(renewed + (renewed - initial))
        try store.runOnDatabase { db in
            XCTAssertEqual(try Int64.fetchOne(db, sql: "SELECT lease_until FROM ingest_jobs WHERE state='running'"), try number(expected, "leaseUntilBeforeCommit"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT attempts FROM ingest_jobs WHERE state='running'"), expected["attempts"] as? Int)
        }
        clock.set(completed)
        await extractor.resolve(1, text: text)
        let returned = try await task.value
        try assertPointers(returned, expected: XCTUnwrap(expected["returnedSource"] as? [String: Any]))
        let count = await callbacks.value()
        XCTAssertEqual(count, 1)
        try store.runOnDatabase { db in XCTAssertEqual(try String.fetchOne(db, sql: "SELECT state FROM ingest_jobs ORDER BY id DESC LIMIT 1"), expected["jobState"] as? String) }

        let unrenewed = try seeded(c)
        try unrenewed.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET raw_path='/fixture/expired.txt' WHERE id=?", arguments: [sourceID]) }
        let expiry = try XCTUnwrap(c["withoutRenewal"] as? [String: Any])
        let expiredClock = IntegrationLeaseClock(now: initial)
        let blocked = IntegrationSuspendedExtractor()
        let ignoredCallbacks = IntegrationCounter()
        let expiring = IngestionService(store: unrenewed, plain: blocked, onChunksWritten: { await ignoredCallbacks.increment() }, leaseClock: expiredClock)
        let expiredTask = Task { try await expiring.reIngest(sourceId: sourceID) }
        await blocked.waitForCalls(1)
        await expiredClock.waitForDeadline(renewed)
        expiredClock.set(try number(expiry, "commitAt"))
        await blocked.resolve(1, text: text)
        let expiredSource = try await expiredTask.value
        XCTAssertEqual(expiredSource.publishedRevisionId, try number(expiry, "publishedRevisionId"))
        let ignored = await ignoredCallbacks.value()
        XCTAssertEqual(ignored, 0)
        try unrenewed.runOnDatabase { db in XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE id<>101"), expiry["newRevisionCount"] as? Int) }
    }

    private func assertSupersededExtraction() async throws {
        let c = try fixture("superseded-extraction")
        try assertEvents(c, ["begin", "begin", "commit", "commit"])
        let events = try XCTUnwrap(c["events"] as? [[String: Any]])
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let sourceID = try number(c, "sourceId")
        let store = try seeded(c)
        try store.runOnDatabase { db in try db.execute(sql: "UPDATE sources SET raw_path='/fixture/superseded.txt' WHERE id=?", arguments: [sourceID]) }
        let clock = IntegrationLeaseClock(now: try number(events[0], "at"))
        let extractor = IntegrationSuspendedExtractor()
        let callbacks = IntegrationCounter()
        let service = IngestionService(store: store, plain: extractor, onChunksWritten: { await callbacks.increment() }, leaseClock: clock)
        let a = Task { try await service.reIngest(sourceId: sourceID) }
        await extractor.waitForCalls(1)
        clock.set(try number(events[1], "at"))
        let b = Task { try await service.reIngest(sourceId: sourceID) }
        await extractor.waitForCalls(2)
        clock.set(try number(events[2], "at"))
        await extractor.resolve(2, text: try XCTUnwrap((events[2]["draft"] as? [String: Any])?["canonicalText"] as? String))
        let resultB = try await b.value
        clock.set(try number(events[3], "at"))
        await extractor.resolve(1, text: try XCTUnwrap((events[3]["draft"] as? [String: Any])?["canonicalText"] as? String))
        let resultA = try await a.value
        try assertPointers(resultB, expected: XCTUnwrap(expected["returnedSource"] as? [String: Any]))
        try assertPointers(resultA, expected: XCTUnwrap(expected["returnedSource"] as? [String: Any]))
        let count = await callbacks.value()
        XCTAssertEqual(count, 1)
        let states = try XCTUnwrap(expected["jobStates"] as? [String: String])
        try store.runOnDatabase { db in
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT state FROM ingest_jobs ORDER BY id"), [try XCTUnwrap(states["A"]), try XCTUnwrap(states["B"])])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT count(*) FROM source_revisions WHERE id<>101"), expected["newRevisionCount"] as? Int)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT canonical_text FROM source_revisions WHERE id=(SELECT published_revision_id FROM sources WHERE id=?)", arguments: [sourceID]), expected["publishedText"] as? String)
        }
    }

    private func fixture(_ name: String) throws -> [String: Any] {
        let root = try SharedFixtures.json("contracts/storage-integration-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        let names: Set<String> = ["replacement", "no-vector-provider-call", "empty-note", "scalar-text", "pdf-pages", "model-switch",
            "reingest-during-embedding", "reindex-keeps-active", "citation-after-gc", "restart", "scalar-empty", "scalar-whitespace",
            "scalar-combining", "scalar-supplementary", "scalar-repeated", "scalar-overlap", "scalar-long-word", "scalar-pdf-crossing",
            "superseded-extraction", "renew-running-extraction"]
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), names)
        XCTAssertEqual(Set(cases.compactMap { $0["operation"] as? String }), ["integration", "scalar"])
        return try XCTUnwrap(cases.first { $0["name"] as? String == name }, name)
    }

    private func assertEvents(_ c: [String: Any], _ expected: [String]) throws {
        XCTAssertEqual(try XCTUnwrap(c["events"] as? [[String: Any]]).compactMap { $0["op"] as? String }, expected)
    }

    private func seeded(_ c: [String: Any]) throws -> NotebookStore {
        let store = try NotebookStore(path: .inMemory, configuredEmbeddingModelKey: nil)
        try seed(store, with: c)
        return store
    }

    private func seed(_ store: NotebookStore, with c: [String: Any]) throws {
        try store.runOnDatabase { db in
            for sql in try XCTUnwrap(c["setupSql"] as? [String]) { try db.execute(sql: sql) }
        }
    }

    private func number(_ value: [String: Any], _ key: String) throws -> Int64 { try XCTUnwrap(value[key] as? NSNumber, key).int64Value }

    private func assertPointers(_ source: Source, expected: [String: Any]) throws {
        XCTAssertEqual(source.currentRevision, try number(expected, "currentRevision"))
        XCTAssertEqual(source.publishedRevisionId, try number(expected, "publishedRevisionId"))
    }

    private func assertChunks(_ actual: [RevisionChunkDraft], expected: [String: Any]) throws {
        let chunks = try XCTUnwrap(expected["chunks"] as? [[String: Any]])
        XCTAssertEqual(actual.count, chunks.count)
        for (chunk, value) in zip(actual, chunks) {
            XCTAssertEqual(Array(chunk.text.utf8), Array(try XCTUnwrap(value["text"] as? String).utf8))
            XCTAssertEqual(chunk.charStart, value["start"] as? Int)
            XCTAssertEqual(chunk.charEnd, value["end"] as? Int)
            XCTAssertEqual(chunk.pageHint, value["pageHint"] as? Int)
            XCTAssertEqual(chunk.tokenCount, value["tokenCount"] as? Int)
            XCTAssertNil(chunk.lang)
            XCTAssertFalse(chunk.langInherited)
        }
    }

    private func assertPublishedSource(_ store: NotebookStore, source: Source, expected: [String: Any], chunker: Int) throws {
        XCTAssertEqual(source.currentRevision, source.publishedRevisionId)
        let revision = try XCTUnwrap(store.revision(id: XCTUnwrap(source.publishedRevisionId)))
        XCTAssertEqual(revision.draft.chunkerVersion, chunker)
        XCTAssertEqual(revision.draft.canonicalText, expected["canonicalText"] as? String)
        XCTAssertEqual(revision.draft.canonicalText.unicodeScalars.count, expected["scalarCount"] as? Int)
        let chunks = try store.chunks(sourceId: XCTUnwrap(source.id))
        XCTAssertTrue(chunks.allSatisfy { $0.revisionId == revision.id })
        try assertChunks(chunks.map {
            RevisionChunkDraft(text: $0.text, tokenCount: $0.tokenCount, pageHint: $0.pageHint, charStart: $0.charStart,
                               charEnd: $0.charEnd, lang: $0.lang, langInherited: $0.langInherited)
        }, expected: expected)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
