import XCTest
@testable import AINotebookCore

/// WP8 Task 8: coordinator phases, exact prepared request streaming,
/// persistence of packed citations, retained previews and native original
/// resolution. Port doubles live only in this file.
@MainActor
final class ChatEngineContextPackTests: XCTestCase {

    // MARK: - Port doubles

    /// Synchronous so `onRetry` entries keep their order relative to streams.
    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [NSDictionary] = []
        func add(_ entry: NSDictionary) { lock.withLock { entries.append(entry) } }
        var calls: [NSDictionary] { lock.withLock { entries } }
    }

    actor RecordingReadSession: PackReadSession {
        let log: CallLog
        private var stored: ContextPackInput
        private(set) var built: ContextPackInput?

        init(input: ContextPackInput, log: CallLog) {
            stored = input
            self.log = log
        }

        var input: ContextPackInput {
            get async {
                log.add(["op": "build"])
                built = stored
                return stored
            }
        }

        func setHistory(_ history: [PackHistoryTurn]) { stored.history = history }

        /// `wrapped` is the JSON array `[value]`.
        func mutate(field: String, wrapped: Data) throws {
            let value = (try JSONSerialization.jsonObject(with: wrapped) as! [Any])[0]
            switch field {
            case "question": stored.question = value as! String
            case "candidates":
                stored.candidates = try ContextPackFixtures.decode(value, as: [PackPassage].self)
            default: XCTFail("unknown field \(field)")
            }
        }

        func search(question: String, fetchK: Int) async throws -> [PackHit] {
            log.add(["op": "search", "question": question, "fetchK": fetchK])
            return stored.candidates.map {
                PackHit(chunkId: $0.chunkId, sourceId: $0.sourceId, revisionId: $0.revisionId, rrfMicro: $0.rrfMicro)
            }
        }

        func hydrate(_ hits: [PackHit]) async throws -> [PackPassage] {
            log.add(["op": "hydrate", "hits": hits.map {
                ["chunkId": $0.chunkId, "sourceId": $0.sourceId, "revisionId": $0.revisionId] as NSDictionary
            }])
            return hits.compactMap { hit in stored.candidates.first { $0.chunkId == hit.chunkId } }
        }

        func overview() async throws -> [PackPassage] {
            log.add(["op": "overview"])
            return stored.overviewCandidates
        }

        func neighbours(for passages: [PackPassage]) async throws -> [PackPassage] {
            log.add(["op": "neighbours"])
            return stored.neighbours
        }

        func finish() async { log.add(["op": "finish"]) }
    }

    struct RecordingDataSource: PackDataSource {
        let read: RecordingReadSession
        let store: NotebookStore

        func pin(_ intent: PackIntent, model: PackModel) async throws -> any PackReadSession {
            read.log.add(["op": "pin"])
            let store = store
            let messages = try await MainActor.run { try store.messages(sessionId: intent.sessionId) }
            await read.setHistory(ContextHistory.turns(messages, excludingUserId: intent.regenerateUserId,
                                                       excludingAssistantId: intent.replacesAssistantId))
            return read
        }
    }

    enum Outcome: Sendable { case success, retry, failure, cancel }
    struct Attempt: Sendable {
        let outcome: Outcome
        let tokens: [String]
    }

    actor RecordingTransport: PreparedPackTransport {
        nonisolated let model: PackModel
        let log: CallLog
        private(set) var requests: [String] = []
        private var attempts: [Attempt] = []

        init(model: PackModel, log: CallLog) {
            self.model = model
            self.log = log
        }

        func enqueue(_ values: [Attempt]) { attempts += values }

        nonisolated func stream(_ request: PreparedContextRequest) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                Task { await self.play(request, continuation) }
            }
        }

        private func play(_ request: PreparedContextRequest, _ continuation: AsyncThrowingStream<String, Error>.Continuation) {
            log.add(["op": "stream"])
            requests.append(String(decoding: (try? PreparedContextRequestJSON.encode(request)) ?? Data(), as: UTF8.self))
            let attempt = attempts.isEmpty ? Attempt(outcome: .success, tokens: []) : attempts.removeFirst()
            for token in attempt.tokens { continuation.yield(token) }
            switch attempt.outcome {
            case .success: continuation.finish()
            case .retry: continuation.finish(throwing: URLError(.timedOut))
            case .failure: continuation.finish(throwing: ProviderError.auth("test"))
            case .cancel: continuation.finish(throwing: CancellationError())
            }
        }
    }

    struct RecordingTransportFactory: PackTransportFactory {
        let transport: RecordingTransport

        func freeze(_ intent: PackIntent) async throws -> any PreparedPackTransport {
            transport.log.add(["op": "freeze"])
            return transport
        }

        func describe(requestedModel: String?) async throws -> PackTransportDescription {
            PackTransportDescription(model: transport.model, configurationRevision: 0)
        }
    }

    // MARK: - Focused prepare/send test

    func testPrepareDoesNotWriteAndSendUsesExactPreparedPack() async throws {
        let fixture = try ContextPackFixtures.input("basic-cs")
        let store = try NotebookStore(path: .inMemory)
        let notebook = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: notebook.id!, title: "T")
        let log = CallLog()
        let read = RecordingReadSession(input: fixture, log: log)
        let transport = RecordingTransport(model: fixture.model, log: log)
        await transport.enqueue([Attempt(outcome: .success, tokens: ["[2][1][2][99]"])])
        let coordinator = ContextPackCoordinator(data: RecordingDataSource(read: read, store: store),
                                                 transports: RecordingTransportFactory(transport: transport))
        let previews = ContextPreviewSession()
        let engine = ChatEngine(store: store, coordinator: coordinator, previews: previews, chatModel: "test",
                                retryBackoffMillis: 0)
        let intent = try PackIntent.testValue(input: fixture, notebookId: notebook.id!, sessionId: session.id!,
            historyFingerprint: store.contextHistoryFingerprint(sessionId: session.id!),
            scopeFingerprint: store.contextScopeFingerprint(notebookId: notebook.id!, scope: .all))
        let handle = try await engine.prepare(intent)
        XCTAssertTrue(try store.messages(sessionId: session.id!).isEmpty)
        let callsBefore = log.calls.count

        // A changed intent's key is stale: no row, no provider call.
        var changed = intent
        changed.question += " (changed)"
        do {
            _ = try await engine.sendPrepared(handle, expectedKey: PackIntentKey.make(changed), onToken: { _ in })
            XCTFail("stale key must be rejected")
        } catch { XCTAssertEqual(error as? ChatEngineError, .stalePreparedRequest) }
        XCTAssertTrue(try store.messages(sessionId: session.id!).isEmpty)
        XCTAssertEqual(log.calls.count, callsBefore)

        let reply = try await engine.sendPrepared(handle, expectedKey: PackIntentKey.make(intent), onToken: { _ in })
        let sent = await transport.requests
        XCTAssertEqual(sent, [String(decoding: try PreparedContextRequestJSON.encode(handle.request), as: UTF8.self)])
        XCTAssertEqual(reply.citations.map(\.marker), [2, 1])
        XCTAssertEqual(reply.citations, [handle.request.citationMap[1], handle.request.citationMap[0]])
        let saved = try store.messages(sessionId: session.id!)
        XCTAssertEqual(saved.map(\.role), [.user, .assistant])
        XCTAssertEqual(saved.first?.content, fixture.question)
        XCTAssertEqual(saved.last?.id, reply.id)
        XCTAssertEqual(saved.last?.citations, reply.citations)
        let retained = await previews.sent(sessionId: session.id!, assistantId: try XCTUnwrap(reply.id))
        XCTAssertEqual(retained, try ContextPreviewSnapshotJSON.encode(ContextPreviewSnapshot(
            request: handle.request, providerType: handle.transport.model.providerType)))
        XCTAssertEqual(try ContextPreviewSnapshotJSON.decode(XCTUnwrap(retained)).request, handle.request)

        // A completed handle cannot be replayed.
        let streams = log.calls.count
        do {
            _ = try await engine.sendPrepared(handle, expectedKey: handle.key, onToken: { _ in })
            XCTFail("replay must be rejected")
        } catch { XCTAssertEqual(error as? ChatEngineError, .preparedRequestConsumed) }
        XCTAssertEqual(try store.messages(sessionId: session.id!).count, 2)
        XCTAssertEqual(log.calls.count, streams)
    }

    // MARK: - Shared coordinator scripts

    func testCoordinatorFixtureScripts() async throws {
        let scripts = try ContextPackFixtures.cases("coordinator")
        XCTAssertEqual(scripts.count, 12)
        for script in scripts { try await run(script) }
    }

    private func run(_ script: [String: Any]) async throws {
        let name = script["name"] as! String
        let input = script["input"] as! [String: Any]
        let expected = script["expected"] as! [String: Any]
        let packInput = try ContextPackFixtures.decode(input["packInput"]!, as: ContextPackInput.self)
        let store = try NotebookStore(path: .inMemory)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "NB").id)
        let sessionId = try XCTUnwrap(store.createChatSession(notebookId: notebookId, title: "T").id)
        for row in input["rows"] as? [[String: Any]] ?? [] {
            var message = ChatMessage(sessionId: sessionId, role: ChatRole(rawValue: row["role"] as! String)!,
                                      content: row["content"] as! String, model: row["model"] as? String)
            message.citations = []
            try store.appendMessage(message)
        }
        XCTAssertEqual(try store.messages(sessionId: sessionId).compactMap(\.id),
                       (input["rows"] as? [[String: Any]] ?? []).map { Int64($0["id"] as! Int) }, name)

        let log = CallLog()
        let read = RecordingReadSession(input: packInput, log: log)
        let transport = RecordingTransport(model: packInput.model, log: log)
        let previews = ContextPreviewSession()
        // The shared scripts are WP8 goldens of estimator v1 and tuning v1; production defaults to
        // estimator v2 and the bundled tuning (WP7), so the goldens inject v1 explicitly.
        let engine = ChatEngine(store: store, coordinator: ContextPackCoordinator(
            data: RecordingDataSource(read: read, store: store), transports: RecordingTransportFactory(transport: transport),
            build: { try ContextPackBuilder.build($0, estimator: PlaceholderTokenEstimatorV1(), tuning: .v1) }),
            previews: previews, chatModel: "test", retryAttempts: 2, retryBackoffMillis: 0)

        var handle: PreparedPackHandle?
        var intent: PackIntent?
        var errors: [String] = []
        var markers: [Int] = []
        for event in input["events"] as! [[String: Any]] {
            switch event["kind"] as! String {
            case "prepare":
                var value = PackIntent.testValue(input: packInput, notebookId: notebookId, sessionId: sessionId,
                    historyFingerprint: try store.contextHistoryFingerprint(sessionId: sessionId),
                    scopeFingerprint: try store.contextScopeFingerprint(notebookId: notebookId,
                                                                        scope: PackIntent.scope(packInput.scope)))
                value.regenerateUserId = (event["regenerateUserId"] as? Int).map(Int64.init)
                value.replacesAssistantId = (event["replacesAssistantId"] as? Int).map(Int64.init)
                value.editUserText = event["edit"] as? Bool ?? false
                intent = value
                do { handle = try await engine.prepare(value) } catch { errors.append(Self.code(error)) }
            case "mutateInput":
                let wrapped = try JSONSerialization.data(withJSONObject: [event["value"]!])
                try await read.mutate(field: event["field"] as! String, wrapped: wrapped)
            case "send":
                guard let handle, let intent else { errors.append("noPreparedRequest"); continue }
                var key = PackIntentKey.make(intent)
                if event["staleKey"] as? Bool == true {
                    var changed = intent
                    changed.question += " (changed)"
                    key = PackIntentKey.make(changed)
                }
                let attempts = (event["attempts"] as? [[String: Any]] ?? []).map { attempt -> Attempt in
                    let outcome: Outcome = switch attempt["outcome"] as! String {
                    case "retry": .retry
                    case "failure": .failure
                    case "cancel": .cancel
                    default: .success
                    }
                    return Attempt(outcome: outcome, tokens: attempt["tokens"] as! [String])
                }
                await transport.enqueue(attempts)
                do {
                    let reply = try await engine.sendPrepared(handle, expectedKey: key, onToken: { _ in },
                                                              onRetry: { log.add(["op": "retry"]) })
                    markers += reply.citations.map(\.marker)
                    let assistantId = try XCTUnwrap(reply.id, name)
                    if await previews.sent(sessionId: sessionId, assistantId: assistantId) != nil {
                        log.add(["op": "retainPreview", "assistantId": assistantId])
                    }
                } catch { errors.append(Self.code(error)) }
            default:
                XCTFail("\(name): unknown event")
            }
        }

        XCTAssertEqual(log.calls as NSArray, expected["calls"] as! NSArray, name)
        XCTAssertEqual(errors, expected["errors"] as! [String], name)
        XCTAssertEqual(markers, expected["parsedMarkers"] as? [Int] ?? [], name)
        let streamed = await transport.requests
        XCTAssertEqual(streamed, expected["streamedRequests"] as? [String] ?? [], name)
        if let bytes = expected["preparedBytes"] as? String {
            XCTAssertEqual(String(decoding: try PreparedContextRequestJSON.encode(XCTUnwrap(handle, name).request),
                                  as: UTF8.self), bytes, name)
        } else {
            XCTAssertNil(handle, name)
        }
        let built = await read.built
        let history = (built?.history ?? []).map { ["id": $0.id, "user": $0.user, "assistant": $0.assistant] as NSDictionary }
        XCTAssertEqual(history as NSArray, (expected["preparedHistory"] as? [Any] ?? []) as NSArray, name)
        XCTAssertEqual(try rows(store, sessionId) as NSArray, expected["rows"] as! NSArray, name)
        let retained = expected["retainedPreviews"] as? [[String: Any]] ?? []
        let state = await previews.state
        XCTAssertEqual(state.entries.map(\.assistantId), retained.map { Int64($0["assistantId"] as! Int) }, name)
        for preview in retained {
            let bytes = await previews.sent(sessionId: sessionId, assistantId: Int64(preview["assistantId"] as! Int))
            XCTAssertEqual(bytes.map { String(decoding: $0, as: UTF8.self) }, preview["canonicalBytes"] as? String, name)
        }
    }

    private static func code(_ error: Error) -> String {
        if let engine = error as? ChatEngineError { return String(describing: engine) }
        if let pack = error as? ContextPackError { return pack.rawValue }
        if error is CancellationError { return "cancelled" }
        return "streamFailed"
    }

    private func rows(_ store: NotebookStore, _ sessionId: Int64) throws -> [NSDictionary] {
        try store.messages(sessionId: sessionId).sorted { $0.id! < $1.id! }.map { message in
            let row = NSMutableDictionary(dictionary: ["id": message.id!, "role": message.role.rawValue,
                                                       "content": message.content])
            if message.role == .assistant {
                if let model = message.model { row["model"] = model }
                row["citations"] = try Self.citationObjects(message.citations)
            }
            return row
        }
    }

    private static func citationObjects(_ citations: [Citation]) throws -> [Any] {
        guard let encoded = CitationsCodec.encode(citations) else { return [] }
        let object = try JSONSerialization.jsonObject(with: Data(encoded.utf8))
        return (object as? [String: Any])?["items"] as? [Any] ?? object as! [Any]
    }

    // MARK: - Runtime tuning (WP7 Task 15 composed with the WP8 coordinator)

    func testCapturedIntentTakesOmittedFetchKAndTopKFromRuntimeTuning() async throws {
        let fixture = try ContextPackFixtures.input("basic-cs")
        let store = try NotebookStore(path: .inMemory)
        let notebook = try XCTUnwrap(store.createNotebook(name: "NB").id)
        let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "T").id)
        let log = CallLog()
        let coordinator = ContextPackCoordinator(
            data: RecordingDataSource(read: RecordingReadSession(input: fixture, log: log), store: store),
            transports: RecordingTransportFactory(transport: RecordingTransport(model: fixture.model, log: log)))
        let tuned = try RagRuntimeTuning(fetchK: 48, topK: 24, evidenceShareBp: 7000)
        func capture(topK: Int? = nil, fetchK: Int? = nil,
                     tuning: @escaping @Sendable () throws -> RagRuntimeTuning = { try RagRuntimeTuning.bundled() })
            async throws -> PackIntent {
            let engine = ChatEngine(store: store, coordinator: coordinator, previews: ContextPreviewSession(),
                                    chatModel: "test", topK: topK, fetchK: fetchK, tuning: tuning)
            return try await engine.captureIntent(sessionId: session, notebookId: notebook, question: "q", scope: .all)
        }

        // The shipped decision is pending, so production defaults stay v1 (32/16).
        var intent = try await capture()
        XCTAssertEqual([intent.fetchK, intent.topK], [32, 16])
        intent = try await capture(tuning: { tuned })
        XCTAssertEqual([intent.fetchK, intent.topK], [48, 24])
        // Explicit arguments win; fetchK never drops below topK.
        intent = try await capture(topK: 4, tuning: { tuned })
        XCTAssertEqual([intent.fetchK, intent.topK], [48, 4])
        intent = try await capture(topK: 12, fetchK: 8, tuning: { tuned })
        XCTAssertEqual([intent.fetchK, intent.topK], [12, 12])
        intent = try await capture(fetchK: 9, tuning: { tuned })
        XCTAssertEqual([intent.fetchK, intent.topK], [24, 24])
        // An invalid decision fails the capture instead of silently using other values.
        do {
            _ = try await capture(tuning: { throw RagTuningError.invalidTuning })
            XCTFail("expected invalidTuning")
        } catch let error as RagTuningError {
            XCTAssertEqual(error, .invalidTuning)
        }
    }

    // MARK: - History and fingerprints

    func testHistoryKeepsOnlyCompletePairsAndFingerprintsTrackEdits() throws {
        let store = try NotebookStore(path: .inMemory)
        let notebook = try XCTUnwrap(store.createNotebook(name: "NB").id)
        let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "T").id)
        let empty = try store.contextHistoryFingerprint(sessionId: session)
        XCTAssertEqual(empty.count, 64, "an empty history still has a real digest")
        for (role, text) in [(ChatRole.user, "a"), (.assistant, "A"), (.user, "orphan"), (.user, "b"), (.assistant, "B"), (.user, "c")] {
            try store.appendMessage(ChatMessage(sessionId: session, role: role, content: text))
        }
        let messages = try store.messages(sessionId: session)
        XCTAssertEqual(ContextHistory.turns(messages).map(\.user), ["a", "b"])
        XCTAssertEqual(ContextHistory.turns(messages, excludingUserId: messages[3].id, excludingAssistantId: messages[4].id)
            .map(\.user), ["a"])
        let before = try store.contextHistoryFingerprint(sessionId: session)
        XCTAssertNotEqual(before, empty)
        try store.updateMessageContent(id: messages[1].id!, content: "A edited")
        XCTAssertNotEqual(try store.contextHistoryFingerprint(sessionId: session), before)

        let source = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: "s", uri: nil, rawPath: nil).id)
        let scope = RetrievalScope.selection(sourceIds: [source], folderIds: [])
        let scoped = try store.contextScopeFingerprint(notebookId: notebook, scope: scope)
        XCTAssertNotEqual(scoped, try store.contextScopeFingerprint(notebookId: notebook, scope: .all))
        XCTAssertNotEqual(try store.contextScopeFingerprint(notebookId: notebook, scope: .selection(sourceIds: [], folderIds: [])), "")
        try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET eligible=0 WHERE id=?", arguments: [source]) }
        XCTAssertNotEqual(try store.contextScopeFingerprint(notebookId: notebook, scope: scope), scoped)
    }

    func testCommitRejectsForeignIdsAndKeepsOldPairUntilSuccess() throws {
        let store = try NotebookStore(path: .inMemory)
        let notebook = try XCTUnwrap(store.createNotebook(name: "NB").id)
        let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "T").id)
        let other = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "O").id)
        let user = try store.appendContextUser(sessionId: session, text: "Q")
        let answer = try store.commitContextAssistant(sessionId: session, content: "A", citations: [], model: "m",
                                                      replacesAssistantId: nil, replacesUserId: nil, replacementUserText: nil)
        XCTAssertNotNil(user.id)
        XCTAssertThrowsError(try store.commitContextAssistant(sessionId: other, content: "X", citations: [], model: "m",
            replacesAssistantId: answer.id, replacesUserId: user.id, replacementUserText: "edited"))
        XCTAssertEqual(try store.messages(sessionId: session).map(\.content), ["Q", "A"])
        let replaced = try store.commitContextAssistant(sessionId: session, content: "A2", citations: [], model: "m",
            replacesAssistantId: answer.id, replacesUserId: user.id, replacementUserText: "Q2")
        XCTAssertEqual(try store.messages(sessionId: session).map(\.content), ["Q2", "A2"])
        XCTAssertEqual(try store.messages(sessionId: session).last?.id, replaced.id)
    }

    // MARK: - Production adapters

    private struct StubIdentity: FolderPathIdentity {
        func resolve(rootPath: String) throws -> FolderIdentity {
            FolderIdentity(volumeId: "test", components: ["docs"], rootFileId: "root-1")
        }
    }
    private final class CapturingChat: ChatStreaming, @unchecked Sendable {
        private let lock = NSLock()
        private var turns: [[ChatTurn]] = []
        let reply: String
        init(reply: String) { self.reply = reply }
        var captured: [[ChatTurn]] { lock.withLock { turns } }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            lock.withLock { turns.append(messages) }
            let reply = reply
            return AsyncThrowingStream { $0.yield(reply); $0.finish() }
        }
    }
    private struct UnitEmbedder: EmbeddingProducing {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] { inputs.map { _ in [1, 0] } }
    }

    func testProductionAdaptersPackFolderEvidenceOverviewAndEmptySelection() async throws {
        let store = try NotebookStore(path: .inMemory)
        let notebook = try XCTUnwrap(store.createNotebook(name: "Research").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: "/docs", displayName: "Docs",
            includeExts: ["txt"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: false),
            identity: StubIdentity(), now: 0)
        var published: [String: Int64] = [:]
        for (rel, text) in [("a/report.txt", "Alpha report. The secret spice is saffron."), ("b/notes.txt", "Beta notes about pepper.")] {
            let id = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: rel, uri: nil, rawPath: nil).id)
            try store.attachSource(sourceId: id, folderId: folder.id, relPath: rel)
            published[rel] = try store.commitForegroundRevision(sourceId: id, draft: RevisionDraft(contentHash: rel,
                canonicalText: text, textFormatVersion: 1, chunkerVersion: 2), chunks: ScalarChunker.chunk(text),
                now: 0, leaseToken: "seed-" + rel).id
        }
        let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "T").id)
        let chat = CapturingChat(reply: "See [1].")
        let engine = ChatEngine(store: store, retriever: Retriever(store: store, client: UnitEmbedder(), model: "m"),
                                chat: chat, chatModel: "m", retryBackoffMillis: 0)

        let answer = try await engine.send(sessionId: session, notebookId: notebook, userText: "saffron",
                                           scope: .selection(sourceIds: [], folderIds: [folder.id]), onToken: { _ in })
        let cited = try XCTUnwrap(answer.citations.first)
        XCTAssertEqual(cited.relPath, "a/report.txt")
        XCTAssertEqual(cited.folderId, folder.id)
        XCTAssertEqual(cited.revisionId, published["a/report.txt"])
        XCTAssertEqual(cited.text, "Alpha report. The secret spice is saffron.")
        XCTAssertEqual(cited.spans, [CitationSpan(start: 0, end: 42, pageFrom: nil, pageTo: nil)])
        let final = try XCTUnwrap(chat.captured.last?.last?.content)
        XCTAssertTrue(final.hasPrefix("[SCOPE]\nScope: Docs\nScan: idle; last complete: unknown\n"))
        XCTAssertTrue(final.contains("Folder \(folder.id) /a: 1 published files"))
        XCTAssertTrue(final.contains("[1] a/report.txt · und\nAlpha report. The secret spice is saffron."))
        XCTAssertFalse(final.contains("/docs"), "folder roots never enter a request")

        let overview = try await engine.send(sessionId: session, notebookId: notebook, userText: "What is here?",
                                             scope: .all, mode: "overview", onToken: { _ in })
        let overviewBytes = await engine.previews.sent(sessionId: session, assistantId: try XCTUnwrap(overview.id))
        let snapshot = try ContextPreviewSnapshotJSON.decode(XCTUnwrap(overviewBytes))
        XCTAssertEqual(snapshot.providerType, "ollama")
        XCTAssertTrue(snapshot.request.coverage.turn.overview)
        XCTAssertEqual(snapshot.request.coverage.turn.candidatesWithPublishedChunks, 2)
        XCTAssertEqual(snapshot.request.coverage.corpus.filesInScope, 2)
        XCTAssertEqual(snapshot.request.citationMap.compactMap(\.relPath).sorted(), ["a/report.txt", "b/notes.txt"])
        XCTAssertEqual(snapshot.request.messages.count, 4, "system, the previous complete exchange, final user")
        XCTAssertTrue(try XCTUnwrap(chat.captured.last?.last?.content)
            .contains("This is an overview from excerpts from 2/2 files, not an exhaustive summary. Candidates with published chunks: 2."))

        let empty = try await engine.send(sessionId: session, notebookId: notebook, userText: "saffron?",
                                          scope: .selection(sourceIds: [], folderIds: []), onToken: { _ in })
        XCTAssertEqual(empty.citations, [])
        XCTAssertFalse(try XCTUnwrap(chat.captured.last?.last?.content).contains("secret spice"), "an empty selection is never widened")
        XCTAssertTrue(try XCTUnwrap(chat.captured.last?.last?.content).contains("Turn: 0 passages from 0 files"))
    }

    // MARK: - Native original resolution

    func testOriginalResolverRevalidatesContainmentOnEveryClick() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wp8-original-" + UUID().uuidString)
        let root = base.appendingPathComponent("root"), sibling = base.appendingPathComponent("root-other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("inside".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("gone soon".utf8).write(to: root.appendingPathComponent("b.txt"))
        try Data("outside".utf8).write(to: sibling.appendingPathComponent("a.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path,
                                                   withDestinationPath: "../root-other/a.txt")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("dir").path,
                                                   withDestinationPath: "../root-other")
        let loose = base.appendingPathComponent("loose.pdf")
        try Data("pdf".utf8).write(to: loose)

        let store = try NotebookStore(path: .inMemory)
        let notebook = try XCTUnwrap(store.createNotebook(name: "NB").id)
        let folder = try store.createFolder(notebookId: notebook, draft: FolderDraft(rootPath: root.path, displayName: "Root",
            includeExts: ["txt"], ignoreGlobs: [], limitsJSON: "{}", encodingFallback: "cp1250", watchEnabled: false),
            identity: NativeFolderFileSystem(), now: 0)
        func attach(_ rel: String) throws -> (source: Int64, old: Int64, current: Int64) {
            let id = try XCTUnwrap(store.createSource(notebookId: notebook, type: .text, title: rel, uri: nil, rawPath: nil).id)
            try store.attachSource(sourceId: id, folderId: folder.id, relPath: rel)
            let old = try store.insertRevision(sourceId: id, draft: RevisionDraft(contentHash: "1", canonicalText: "old",
                textFormatVersion: 1, chunkerVersion: 2), now: 1).id
            let current = try store.insertRevision(sourceId: id, draft: RevisionDraft(contentHash: "2", canonicalText: "new",
                textFormatVersion: 1, chunkerVersion: 2), now: 2).id
            try store.runOnDatabase { try $0.execute(sql: "UPDATE sources SET current_revision=? WHERE id=?", arguments: [current, id]) }
            return (id, old, current)
        }
        func citation(_ source: Int64, rel: String, revision: Int64?, text: String = "saved snapshot") -> Citation {
            var c = Citation(marker: 1, chunkId: 1, sourceId: source, snippet: text)
            c.folderId = folder.id
            c.relPath = rel
            c.revisionId = revision
            c.text = text
            return c
        }
        let resolver = NativeCitationOriginalResolver(store: store)
        let inside = try attach("a.txt")
        let resolvedPointer = try XCTUnwrap(realpath(root.appendingPathComponent("a.txt").path, nil))
        let expectedURL = URL(fileURLWithPath: String(cString: resolvedPointer))
        free(resolvedPointer)

        let changed = try await resolver.resolve(notebookId: notebook, citation: citation(inside.source, rel: "a.txt", revision: inside.old))
        XCTAssertEqual(changed.decision, .changed)
        XCTAssertEqual(changed.url, expectedURL)
        let current = try await resolver.resolve(notebookId: notebook, citation: citation(inside.source, rel: "a.txt", revision: inside.current))
        XCTAssertEqual(current.decision, .available)

        let traversal = try await resolver.resolve(notebookId: notebook,
            citation: citation(inside.source, rel: "../root-other/a.txt", revision: inside.current))
        XCTAssertEqual(traversal.decision, .unsafe)
        XCTAssertNil(traversal.url)

        let link = try attach("link.txt")
        let escaped = try await resolver.resolve(notebookId: notebook, citation: citation(link.source, rel: "link.txt", revision: link.current))
        XCTAssertEqual(escaped.decision, .unsafe)
        XCTAssertNil(escaped.url)

        let prefixSibling = try attach("dir/a.txt")
        let viaDirectory = try await resolver.resolve(notebookId: notebook,
            citation: citation(prefixSibling.source, rel: "dir/a.txt", revision: prefixSibling.current))
        XCTAssertEqual(viaDirectory.decision, .unsafe)
        XCTAssertNil(viaDirectory.url)

        let removed = try attach("b.txt")
        try FileManager.default.removeItem(at: root.appendingPathComponent("b.txt"))
        let missing = try await resolver.resolve(notebookId: notebook, citation: citation(removed.source, rel: "b.txt", revision: removed.current))
        XCTAssertEqual(missing.decision, .unavailable)
        XCTAssertNil(missing.url)

        // A deleted source is unavailable; the persisted snapshot still renders.
        let session = try XCTUnwrap(store.createChatSession(notebookId: notebook, title: "T").id)
        let saved = citation(inside.source, rel: "a.txt", revision: inside.old, text: "full saved excerpt")
        _ = try store.commitContextAssistant(sessionId: session, content: "[1]", citations: [saved], model: "m",
                                             replacesAssistantId: nil, replacesUserId: nil, replacementUserText: nil)
        try store.deleteSource(id: inside.source)
        let deleted = try await resolver.resolve(notebookId: notebook, citation: saved)
        XCTAssertEqual(deleted.decision, .unavailable)
        XCTAssertEqual(try store.messages(sessionId: session).last?.citations.first?.text, "full saved excerpt")

        // Loose legacy files keep their trusted stored location.
        let legacy = try XCTUnwrap(store.createSource(notebookId: notebook, type: .pdf, title: "loose.pdf", uri: nil,
                                                      rawPath: loose.path).id)
        let opened = try await resolver.resolve(notebookId: notebook,
            citation: Citation(marker: 1, chunkId: 1, sourceId: legacy, snippet: "x"))
        XCTAssertEqual(opened.decision, .available)
        XCTAssertEqual(opened.url?.lastPathComponent, "loose.pdf")
    }
}

extension PackIntent {
    static func scope(_ snapshot: PackScopeSnapshot) -> RetrievalScope {
        snapshot.kind == "all" ? .all
            : .selection(sourceIds: Set(snapshot.sourceIds), folderIds: Set(snapshot.folderIds))
    }

    /// Test-only helper, not a production default.
    static func testValue(input: ContextPackInput, notebookId: Int64, sessionId: Int64,
                          historyFingerprint: String, scopeFingerprint: String) -> PackIntent {
        PackIntent(notebookId: notebookId, sessionId: sessionId, question: input.question, mode: input.mode,
                   scope: scope(input.scope), providerId: input.model.providerId, model: input.model.model,
                   providerConfigurationRevision: 0, runtimeContext: input.model.runtimeContext,
                   maxOutputTokens: input.model.maxOutputTokens, evidenceBudgetCap: input.evidenceBudgetCap,
                   fetchK: input.fetchK, topK: input.topK, notebookInstructions: "",
                   instructionsOverride: input.userInstructions, currentNoteContent: nil, useWebSearch: false,
                   historyFingerprint: historyFingerprint, scopeFingerprint: scopeFingerprint,
                   regenerateUserId: nil, replacesAssistantId: nil)
    }
}
