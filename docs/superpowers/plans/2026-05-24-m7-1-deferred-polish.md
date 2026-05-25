# M7.1: Deferred Polish — Close All v1 Gaps

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the nine in-scope items deferred from M5/M6/M7 so v0.2.0 reaches full design-spec parity. Also fix the build-app.sh test-bundle leak.

**Scope (10 items):**
1. Save-as-note from chat messages.
2. Notebook-scope transformations (run a template over every source in the notebook).
3. Custom transformation editor UI (create/edit/delete user templates).
4. Multi-session chat per notebook (sessions sidebar + new-session button).
5. Model management UI in Settings (swap chat/embedding model, list pulled, pull more, delete).
6. PDF page-jump from citation (fill `page_hint` on extraction, "Jump to page" action in popover).
7. Re-embed UI when the user changes the embedding model.
8. Chat reconnect with backoff (2 attempts, exponential).
9. Streaming for transformations (live token rendering instead of collect-then-render).
10. `build-app.sh` test-bundle filter.

**Architecture:** No new modules. Mostly UI sheets/views + small Core additions (`OllamaClient.deleteModel`, `PDFExtractor` page hints, `TransformationEngine.stream(...)`, retry wrapper in `ChatEngine`).

**Tech Stack:** Swift 6, SwiftUI, GRDB (existing), PDFKit (existing), Ollama API.

---

## Task 1: Branch + baseline

```bash
git checkout main
git checkout -b m7-1-deferred-polish
swift test --parallel 2>&1 | tail -5
```

Expected: 147/147 pass.

---

## Task 2: `build-app.sh` — filter test bundles

`*Tests.bundle` artefacts get copied into the release `.app/Contents/Resources/`. Fix.

**Files:** Modify `tools/macos/build-app.sh`

- [ ] **Step 1: Edit the bundle-copy loop**

Find this block:

```bash
for b in "$BIN_DIR"/*.bundle; do
    cp -R "$b" "$RESOURCES/"
done
```

Replace with:

```bash
for b in "$BIN_DIR"/*.bundle; do
    base="$(basename "$b")"
    case "$base" in
        *Tests.bundle|*Test.bundle) continue ;;
    esac
    cp -R "$b" "$RESOURCES/"
done
```

- [ ] **Step 2: Re-run + verify**

```bash
./tools/macos/build-app.sh 2>&1 | tail -10
ls "dist/AI Notebook.app/Contents/Resources/"
```

Expected: no `*Tests.bundle` in Resources.

- [ ] **Step 3: Commit**

```bash
git add tools/macos/build-app.sh
git commit -m "build(macos): exclude *Tests.bundle from release app bundle"
```

---

## Task 3: `Ollama.deleteModel` + Core hook for re-embed

**Files:** Modify `Sources/AINotebookCore/OllamaClient.swift`, test `Tests/AINotebookCoreTests/OllamaClientDeleteTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/OllamaClientDeleteTests.swift
import XCTest
@testable import AINotebookCore

final class OllamaClientDeleteTests: XCTestCase {

    func testDeleteSendsCorrectRequest() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/delete")
            XCTAssertEqual(request.httpMethod, "DELETE")
            let body = try XCTUnwrap(request.httpBodyStreamData())
            let decoded = try XCTUnwrap(try? JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(decoded["name"], "llama3.2:3b")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let session = URLSession(configuration: config)
        let client = OllamaClient(session: session)
        try await client.deleteModel(name: "llama3.2:3b")
    }

    func testDeleteThrowsOnHttp404() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        StubURLProtocol.reset()
        StubURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data("not found".utf8)
            )
        }
        let session = URLSession(configuration: config)
        let client = OllamaClient(session: session)
        do {
            try await client.deleteModel(name: "ghost")
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

private extension URLRequest {
    func httpBodyStreamData() throws -> Data? {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufSize = 4096
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buf, maxLength: bufSize)
            if read <= 0 { break }
            data.append(buf, count: read)
        }
        return data
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaClientDeleteTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `deleteModel`**

Append to `Sources/AINotebookCore/OllamaClient.swift` (inside the class):

```swift
    /// Deletes a pulled model from the Ollama daemon.
    public func deleteModel(name: String) async throws {
        let url = baseURL.appendingPathComponent("api/delete")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(["name": name])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.httpStatus(code: 0, body: "")
        }
        if !(200..<300).contains(http.statusCode) {
            throw OllamaError.httpStatus(
                code: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter OllamaClientDeleteTests 2>&1 | tail -10
git add Sources/AINotebookCore/OllamaClient.swift Tests/AINotebookCoreTests/OllamaClientDeleteTests.swift
git commit -m "feat(core): OllamaClient.deleteModel"
```

Expected: 2/2 pass.

---

## Task 4: `PDFExtractor` — fill page hints per chunk

The chunker doesn't know about PDF pages. Easiest path: `PDFExtractor` returns `ExtractedText.pageHints = [page-number per character offset]` and the chunker passes the relevant hint to each `ChunkDraft`. Simpler v1: store one hint **per page** as a separate source-chunk-like entity, OR run the chunker page-by-page and assign hints per produced chunk.

Going with the page-by-page approach: extract one chunk per page (or one per ~512-token slice within a page), tagged with the page number.

**Files:** Modify `Sources/AINotebookCore/PDFExtractor.swift`, modify `Sources/AINotebookCore/IngestionService.swift`, modify `Sources/AINotebookCore/Chunker.swift`, test `Tests/AINotebookCoreTests/PDFPageHintsTests.swift`

- [ ] **Step 1: Add `Chunker.chunkPaged`**

Append to `Sources/AINotebookCore/Chunker.swift`:

```swift
    /// Like `chunk(_:)` but takes a list of `(text, pageHint)` pairs (e.g.
    /// from PDF pages). Each page is chunked independently; resulting
    /// `ChunkDraft`s carry the page hint they came from.
    public static func chunkPaged(
        _ pages: [(text: String, pageHint: Int)],
        windowChars: Int = 2048,
        overlapChars: Int = 256
    ) -> [ChunkDraft] {
        var out: [ChunkDraft] = []
        for page in pages {
            let drafts = chunk(page.text, windowChars: windowChars, overlapChars: overlapChars)
            for d in drafts {
                out.append(ChunkDraft(text: d.text, tokenCount: d.tokenCount, pageHint: page.pageHint))
            }
        }
        return out
    }
```

- [ ] **Step 2: Change `PDFExtractor` to emit `ExtractedText` with one page per `\u{0C}`-separated block AND set `pageHints` array**

Modify `Sources/AINotebookCore/PDFExtractor.swift` so it returns text where each page is separated by the form-feed character `\u{0C}`, and `pageHints` is `[1, 2, 3, ...]` matching the page count. (`ExtractedText.pageHints: [Int]?` already exists from M3.)

Then update `IngestionService` to, when handling `.pdf`, switch to the paged chunker:

```swift
case .pdf:
    let extracted = try await pdf.extract(from: url, kind: kind)
    let pages: [(String, Int)]
    if let hints = extracted.pageHints {
        let split = extracted.text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
        pages = zip(split, hints).map { (String($0.0), $0.1) }
    } else {
        pages = [(extracted.text, 0)]
    }
    let chunks = Chunker.chunkPaged(pages)
    return (extracted, chunks)
```

Reshape the existing `runPipeline` to allow callers to provide pre-chunked drafts. Concretely:

1. Change the inner `extract: () async throws -> ExtractedText` closure type to `() async throws -> (ExtractedText, [ChunkDraft])` — second tuple element is pre-chunked drafts (or `Chunker.chunk(extracted.text)` for non-PDF paths).
2. In `runPipeline`, drop the internal `Chunker.chunk(...)` call and use the closure's returned drafts directly.

Update each caller (`ingestFile`, `ingestRawText`, `ingestURL`) to return `(extracted, chunks)`:

```swift
// ingestFile body
return try await runPipeline(for: source) { [self] in
    switch kind {
    case .pdf:
        let extracted = try await pdf.extract(from: url, kind: kind)
        let pages: [(String, Int)]
        if let hints = extracted.pageHints {
            let split = extracted.text.split(separator: "\u{0C}", omittingEmptySubsequences: false)
            pages = zip(split, hints).map { (String($0.0), $0.1) }
        } else {
            pages = [(extracted.text, 0)]
        }
        return (extracted, Chunker.chunkPaged(pages))
    case .text, .markdown:
        let e = try await plain.extract(from: url, kind: kind)
        return (e, Chunker.chunk(e.text))
    case .docx, .pptx, .xlsx:
        let e = try await office.extract(from: url, kind: kind)
        return (e, Chunker.chunk(e.text))
    case .web:
        let e = try await web.extract(from: url, kind: kind)
        return (e, Chunker.chunk(e.text))
    }
}
```

Apply the same shape to `ingestRawText` and `ingestURL` (they're non-PDF, so just wrap with `Chunker.chunk`).

- [ ] **Step 3: Write the test**

```swift
// Tests/AINotebookCoreTests/PDFPageHintsTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class PDFPageHintsTests: XCTestCase {

    func testIngestedPDFChunksCarryPageHints() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sample", withExtension: "pdf", subdirectory: "Fixtures")
        )
        let service = IngestionService(store: store)
        let source = try await service.ingestFile(url, into: nb.id!)
        let chunks = try store.chunks(sourceId: source.id!)
        XCTAssertFalse(chunks.isEmpty)
        // At least one chunk has a non-nil page hint.
        XCTAssertTrue(chunks.contains { $0.pageHint != nil && $0.pageHint! > 0 },
                     "expected at least one chunk with a page hint, got: \(chunks.map { $0.pageHint as Any })")
    }
}
```

- [ ] **Step 4: Build + test + commit**

```bash
swift test --filter PDFPageHintsTests 2>&1 | tail -10
swift test --parallel 2>&1 | tail -5
git add Sources/AINotebookCore/PDFExtractor.swift Sources/AINotebookCore/IngestionService.swift Sources/AINotebookCore/Chunker.swift Tests/AINotebookCoreTests/PDFPageHintsTests.swift
git commit -m "feat(core): PDF chunks carry page_hint via Chunker.chunkPaged"
```

If existing PDFExtractor/PlainTextExtractor/IngestionService tests break due to the signature change of the runPipeline closure, update the call sites (this is a Core-internal API). Confirm full suite still green before committing.

---

## Task 5: Chat reconnect with backoff (2 attempts)

**Files:** Modify `Sources/AINotebookCore/ChatEngine.swift`, test `Tests/AINotebookCoreTests/ChatEngineRetryTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/ChatEngineRetryTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineRetryTests: XCTestCase {

    final class FlakyChat: ChatStreaming, @unchecked Sendable {
        var failuresRemaining: Int
        let tokens: [String]
        var attempts = 0
        init(failuresRemaining: Int, tokens: [String]) {
            self.failuresRemaining = failuresRemaining
            self.tokens = tokens
        }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            attempts += 1
            let shouldFail = failuresRemaining > 0
            if shouldFail { failuresRemaining -= 1 }
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    if shouldFail {
                        c.finish(throwing: URLError(.timedOut))
                        return
                    }
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

    final class StaticEmbedder: EmbeddingProducing, @unchecked Sendable {
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in [1, 0] }
        }
    }

    func testRetriesOnceOnTimeoutThenSucceeds() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = FlakyChat(failuresRemaining: 1, tokens: ["ok"])
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat,
                                chatModel: "m", retryAttempts: 1, retryBackoffMillis: 1)

        let msg = try await engine.send(
            sessionId: session.id!, notebookId: nb.id!, userText: "hi"
        ) { _ in }
        XCTAssertEqual(msg.content, "ok")
        XCTAssertEqual(chat.attempts, 2, "should retry once after the first failure")
    }

    func testGivesUpAfterMaxAttempts() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = FlakyChat(failuresRemaining: 99, tokens: ["ok"])
        let retriever = Retriever(store: store, client: StaticEmbedder(), model: "m")
        let engine = ChatEngine(store: store, retriever: retriever, chat: chat,
                                chatModel: "m", retryAttempts: 2, retryBackoffMillis: 1)

        do {
            _ = try await engine.send(
                sessionId: session.id!, notebookId: nb.id!, userText: "hi"
            ) { _ in }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(chat.attempts, 3, "1 original + 2 retries")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter ChatEngineRetryTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

Extend `ChatEngine`:

1. Add `public let retryAttempts: Int` and `public let retryBackoffMillis: Int` properties.
2. Add to `init` with defaults `retryAttempts: 2, retryBackoffMillis: 250`.
3. Wrap the stream-collecting loop:

```swift
var assembled = ""
var attempt = 0
while true {
    do {
        var partial = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            partial += token
            onToken(token)
        }
        assembled = partial
        break
    } catch {
        if attempt >= retryAttempts { throw error }
        attempt += 1
        let delayNs = UInt64(retryBackoffMillis * Int(pow(2.0, Double(attempt - 1)))) * 1_000_000
        try? await Task.sleep(nanoseconds: delayNs)
    }
}
```

(Backoff: 250 ms, 500 ms, 1 s for attempts 1/2/3 with defaults.)

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter ChatEngineRetryTests 2>&1 | tail -10
git add Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ChatEngineRetryTests.swift
git commit -m "feat(core): ChatEngine retries failed streams with exponential backoff"
```

Expected: 2/2 pass.

---

## Task 6: Streaming for transformations

**Files:** Modify `Sources/AINotebookCore/TransformationEngine.swift`, modify `Sources/AINotebookApp/TransformationsView.swift`, test `Tests/AINotebookCoreTests/TransformationEngineStreamTests.swift`

- [ ] **Step 1: Add `run(... onToken:)` overload to `TransformationEngine`**

```swift
@discardableResult
public func run(
    transformationId: Int64,
    sourceId: Int64,
    onToken: @escaping @Sendable (String) -> Void
) async throws -> Note {
    let storeRef = store
    let prep: (Transformation, Source, [SourceChunk]) =
        try await MainActor.run {
            guard let t = try storeRef.transformations().first(where: { $0.id == transformationId }) else {
                throw RunError.transformationNotFound(transformationId)
            }
            guard let s = try storeRef.source(id: sourceId) else {
                throw RunError.sourceNotFound(sourceId)
            }
            let cs = try storeRef.chunks(sourceId: sourceId)
            return (t, s, cs)
        }
    let (transformation, source, chunks) = prep
    guard !chunks.isEmpty else { throw RunError.noChunks(sourceId) }

    let sourceText = chunks.map(\.text).joined(separator: "\n\n")
    let rendered = transformation.promptTemplate
        .replacingOccurrences(of: "{{source_text}}", with: sourceText)

    let turns: [ChatTurn] = [ChatTurn(role: .user, content: rendered)]
    var assembled = ""
    for try await token in chat.stream(model: chatModel, messages: turns) {
        assembled += token
        onToken(token)
    }

    let noteTitle = "\(transformation.name) — \(source.title)"
    let note = try await MainActor.run {
        let created = try storeRef.createNote(
            notebookId: source.notebookId,
            title: noteTitle,
            bodyMd: assembled,
            origin: .transformation,
            originRef: transformation.id
        )
        _ = try storeRef.recordTransformationRun(
            transformationId: transformation.id!,
            sourceId: source.id!,
            resultNoteId: created.id
        )
        return created
    }
    return note
}
```

Keep the existing `run(transformationId:sourceId:)` as a thin shim that forwards with `onToken: { _ in }`.

- [ ] **Step 2: Add the streaming test**

```swift
// Tests/AINotebookCoreTests/TransformationEngineStreamTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationEngineStreamTests: XCTestCase {

    final class StaggeredChat: ChatStreaming, @unchecked Sendable {
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            let toks = tokens
            return AsyncThrowingStream { c in
                Task {
                    for t in toks { c.yield(t) }
                    c.finish()
                }
            }
        }
    }

    func testStreamsTokensWhileRunning() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "body", tokenCount: 1)]
        )
        let t = try store.createTransformation(
            name: "X", promptTemplate: "{{source_text}}", scope: .source, isBuiltin: false
        )

        let chat = StaggeredChat(tokens: ["alpha ", "beta ", "gamma"])
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")

        let collector = TokenCollector()
        let note = try await engine.run(
            transformationId: t.id!, sourceId: s.id!
        ) { token in
            collector.append(token)
        }
        let received = collector.snapshot
        XCTAssertEqual(received, ["alpha ", "beta ", "gamma"])
        XCTAssertEqual(note.bodyMd, "alpha beta gamma")
    }

    final class TokenCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ s: String) {
            lock.lock(); defer { lock.unlock() }
            items.append(s)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }
}
```

- [ ] **Step 3: Wire `TransformationsView` to display streaming**

In `Sources/AINotebookApp/TransformationsView.swift`, change `run()` to:

```swift
private func run() async {
    guard let tid = selectedTransformationId, let sid = selectedSourceId else { return }
    running = true
    errorMessage = nil
    resultBody = ""
    resultNoteId = nil
    defer { running = false }
    do {
        let note = try await transformationHolder.engine.run(
            transformationId: tid, sourceId: sid
        ) { token in
            Task { @MainActor in resultBody += token }
        }
        resultNoteId = note.id
    } catch {
        errorMessage = String(describing: error)
    }
}
```

- [ ] **Step 4: Verify + commit**

```bash
swift test --filter TransformationEngineStreamTests 2>&1 | tail -10
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/TransformationEngine.swift Sources/AINotebookApp/TransformationsView.swift Tests/AINotebookCoreTests/TransformationEngineStreamTests.swift
git commit -m "feat: streaming for TransformationEngine + live UI render"
```

---

## Task 7: Notebook-scope transformation runs

**Files:** Modify `Sources/AINotebookCore/TransformationEngine.swift`, modify `Sources/AINotebookApp/TransformationsView.swift`, test `Tests/AINotebookCoreTests/TransformationNotebookScopeTests.swift`

- [ ] **Step 1: Add `runNotebookScope(transformationId:notebookId:onToken:)`**

```swift
@discardableResult
public func runNotebookScope(
    transformationId: Int64,
    notebookId: Int64,
    onToken: @escaping @Sendable (String) -> Void = { _ in }
) async throws -> Note {
    let storeRef = store
    let prep: (Transformation, [Source], [SourceChunk]) =
        try await MainActor.run {
            guard let t = try storeRef.transformations().first(where: { $0.id == transformationId }) else {
                throw RunError.transformationNotFound(transformationId)
            }
            let sources = try storeRef.sources(notebookId: notebookId)
            var allChunks: [SourceChunk] = []
            for s in sources {
                allChunks.append(contentsOf: try storeRef.chunks(sourceId: s.id!))
            }
            return (t, sources, allChunks)
        }
    let (transformation, sources, chunks) = prep
    guard !chunks.isEmpty else { throw RunError.noChunks(notebookId) }

    let sourceText = chunks.map(\.text).joined(separator: "\n\n")
    let rendered = transformation.promptTemplate
        .replacingOccurrences(of: "{{source_text}}", with: sourceText)

    let turns: [ChatTurn] = [ChatTurn(role: .user, content: rendered)]
    var assembled = ""
    for try await token in chat.stream(model: chatModel, messages: turns) {
        assembled += token
        onToken(token)
    }
    let noteTitle = "\(transformation.name) — \(sources.count) sources"
    let note = try await MainActor.run {
        let created = try storeRef.createNote(
            notebookId: notebookId,
            title: noteTitle,
            bodyMd: assembled,
            origin: .transformation,
            originRef: transformation.id
        )
        _ = try storeRef.recordTransformationRun(
            transformationId: transformation.id!,
            sourceId: nil,
            resultNoteId: created.id
        )
        return created
    }
    return note
}
```

- [ ] **Step 2: Test**

```swift
// Tests/AINotebookCoreTests/TransformationNotebookScopeTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class TransformationNotebookScopeTests: XCTestCase {

    final class MockChat: ChatStreaming, @unchecked Sendable {
        var captured: [[ChatTurn]] = []
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            captured.append(messages)
            return AsyncThrowingStream { c in
                Task { c.yield("Summary of all"); c.finish() }
            }
        }
    }

    func testRunNotebookScopeConcatenatesAllSources() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createSource(notebookId: nb.id!, type: .text, title: "A", uri: nil, rawPath: nil)
        let s2 = try store.createSource(notebookId: nb.id!, type: .text, title: "B", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: s1.id!, chunks: [ChunkDraft(text: "A1", tokenCount: 1)])
        try store.replaceChunks(sourceId: s2.id!, chunks: [ChunkDraft(text: "B1", tokenCount: 1)])
        let t = try store.createTransformation(
            name: "Cross", promptTemplate: "ALL:\n{{source_text}}", scope: .notebook, isBuiltin: false
        )

        let chat = MockChat()
        let engine = TransformationEngine(store: store, chat: chat, chatModel: "m")
        let note = try await engine.runNotebookScope(
            transformationId: t.id!, notebookId: nb.id!
        )
        XCTAssertEqual(note.bodyMd, "Summary of all")
        XCTAssertEqual(note.notebookId, nb.id!)
        let userTurn = chat.captured.first?.last
        XCTAssertTrue(userTurn?.content.contains("A1") == true)
        XCTAssertTrue(userTurn?.content.contains("B1") == true)
    }
}
```

- [ ] **Step 3: Wire UI**

In `TransformationsView`, add a small toggle/picker: "Scope: source / notebook". When notebook scope is chosen, the source picker hides and the run button calls `runNotebookScope` instead. Use the `transformation.scope` field as the default — if the picked transformation has `scope == .notebook`, default the toggle to notebook.

(Implementer: keep the UI change minimal — one extra `Picker` with `.segmented` style above the source picker. When `.notebook` selected, source picker is disabled.)

- [ ] **Step 4: Verify + commit**

```bash
swift test --filter TransformationNotebookScopeTests 2>&1 | tail -10
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/TransformationEngine.swift Sources/AINotebookApp/TransformationsView.swift Tests/AINotebookCoreTests/TransformationNotebookScopeTests.swift
git commit -m "feat: notebook-scope transformations (concat all sources)"
```

---

## Task 8: Custom transformation editor UI

**Files:** Create `Sources/AINotebookApp/TransformationEditorSheet.swift`, modify `Sources/AINotebookApp/TransformationsView.swift`, add localization keys.

- [ ] **Step 1: Add 6 localization keys**

| key | EN | CS |
|---|---|---|
| `transformationEditButton` | "Edit templates" | "Upravit šablony" |
| `transformationEditorTitle` | "Custom transformations" | "Vlastní transformace" |
| `transformationEditorNew` | "New" | "Nový" |
| `transformationEditorDelete` | "Delete" | "Smazat" |
| `transformationEditorNamePlaceholder` | "Template name" | "Název šablony" |
| `transformationEditorTemplatePlaceholder` | "Prompt template (use {{source_text}})" | "Šablona promptu (použijte {{source_text}})" |

Append matching test:
```swift
    func testTransformationEditorNewIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.transformationEditorNew), "New")
        XCTAssertEqual(AppText(language: .czech)  .string(.transformationEditorNew), "Nový")
    }
```

- [ ] **Step 2: Implement `TransformationEditorSheet.swift`**

```swift
// Sources/AINotebookApp/TransformationEditorSheet.swift
import SwiftUI
import AINotebookCore

struct TransformationEditorSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @Binding var isPresented: Bool
    var onChange: () -> Void

    @State private var customs: [Transformation] = []
    @State private var selection: Int64?
    @State private var draftName: String = ""
    @State private var draftTemplate: String = ""
    @State private var draftScope: TransformationScope = .source
    @State private var errorMessage: String?

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.transformationEditorTitle)).font(.title2).bold()
            HSplitView {
                list.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minHeight: 320)
            HStack {
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .task { await reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(t.string(.transformationEditorNew)) {
                    Task { await createBlank() }
                }
                Spacer()
                if let id = selection {
                    Button(role: .destructive) {
                        Task { await delete(id: id) }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            List(selection: $selection) {
                ForEach(customs) { tx in
                    Text(tx.name).tag(tx.id ?? -1)
                }
            }
            .listStyle(.sidebar)
            .onChange(of: selection) { _, newId in
                if let id = newId, let tx = customs.first(where: { $0.id == id }) {
                    draftName = tx.name
                    draftTemplate = tx.promptTemplate
                    draftScope = tx.scope
                }
            }
        }
    }

    @ViewBuilder
    private var editor: some View {
        if selection != nil {
            VStack(alignment: .leading, spacing: 8) {
                TextField(t.string(.transformationEditorNamePlaceholder), text: $draftName)
                    .textFieldStyle(.roundedBorder)
                Picker("Scope", selection: $draftScope) {
                    Text("Source").tag(TransformationScope.source)
                    Text("Notebook").tag(TransformationScope.notebook)
                }
                .pickerStyle(.segmented)
                TextEditor(text: $draftTemplate)
                    .font(.system(.body, design: .monospaced))
                    .overlay(alignment: .topLeading) {
                        if draftTemplate.isEmpty {
                            Text(t.string(.transformationEditorTemplatePlaceholder))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                HStack {
                    Spacer()
                    Button("Save") {
                        Task { await save() }
                    }
                    .keyboardShortcut("s", modifiers: [.command])
                }
            }
        } else {
            VStack { Spacer(); Text("Pick or create a custom template").foregroundStyle(.secondary); Spacer() }
        }
    }

    @MainActor
    private func reload() async {
        do {
            customs = try store.transformations().filter { !$0.isBuiltin }
            if selection == nil { selection = customs.first?.id }
            if let id = selection, let tx = customs.first(where: { $0.id == id }) {
                draftName = tx.name
                draftTemplate = tx.promptTemplate
                draftScope = tx.scope
            }
        } catch { errorMessage = String(describing: error) }
    }

    private func createBlank() async {
        do {
            let tx = try store.createTransformation(
                name: "Untitled",
                promptTemplate: "{{source_text}}",
                scope: .source,
                isBuiltin: false
            )
            await reload()
            selection = tx.id
            onChange()
        } catch { errorMessage = String(describing: error) }
    }

    private func save() async {
        guard let id = selection else { return }
        do {
            try store.updateTransformation(id: id, name: draftName, promptTemplate: draftTemplate)
            await reload()
            onChange()
        } catch { errorMessage = String(describing: error) }
    }

    private func delete(id: Int64) async {
        do {
            try store.deleteTransformation(id: id)
            selection = nil
            await reload()
            onChange()
        } catch { errorMessage = String(describing: error) }
    }
}
```

Note: `draftScope` change isn't persisted via `updateTransformation` (M6 API doesn't accept scope). Add a new overload to the store extension OR add a `scope: TransformationScope` param to `updateTransformation`. Simplest: add a separate method `updateTransformationScope(id:scope:)` to `Sources/AINotebookCore/NotebookStore+Transformations.swift`, called from `save()` here.

- [ ] **Step 3: Add "Edit templates" button to `TransformationsView`**

Add a small button (gear or `t.string(.transformationEditButton)`) next to the run button. Tapping opens `TransformationEditorSheet` via `.sheet(isPresented:)`. On `onChange`, reload `transformations`.

- [ ] **Step 4: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookCore/NotebookStore+Transformations.swift Sources/AINotebookApp/TransformationEditorSheet.swift Sources/AINotebookApp/TransformationsView.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat: custom transformation editor sheet"
```

---

## Task 9: Multi-session chat per notebook

**Files:** Modify `Sources/AINotebookApp/ChatView.swift`, add localization keys.

- [ ] **Step 1: Add 3 localization keys**

| key | EN | CS |
|---|---|---|
| `chatSessionsLabel` | "Sessions" | "Konverzace" |
| `chatNewSessionButton` | "New session" | "Nová konverzace" |
| `chatDeleteSessionButton` | "Delete session" | "Smazat konverzaci" |

- [ ] **Step 2: Refactor `ChatView` to add a session sidebar**

Replace the body's outer `VStack` with `HSplitView`:
- Left: session list (one row per `ChatSession`, newest on top) + a `New session` button. Selecting changes the bound `session`.
- Right: existing chat surface (messages + input).

Reload sessions on appear + on add/delete. On notebook change, re-pick the most recent session (don't auto-create if any exist).

Pseudo-shape:

```swift
var body: some View {
    HSplitView {
        sessionsSidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 280)
        chatSurface.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(16)
    .task(id: notebook.id) { await ensureSessions() }
    .popover(item: $popoverCitation) { c in CitationPopover(...) }
}

private var sessionsSidebar: some View { /* List of ChatSession, Buttons */ }
private var chatSurface: some View { /* existing VStack with messagesList + inputBar */ }
```

Replace the M5 single-session `ensureSession()` with:

```swift
@MainActor
private func ensureSessions() async {
    do {
        sessions = try store.chatSessions(notebookId: notebook.id!)
        if let s = sessions.first {
            selectedSessionId = s.id
        } else {
            let new = try store.createChatSession(
                notebookId: notebook.id!,
                title: t.string(.chatNewSessionTitle)
            )
            sessions = [new]
            selectedSessionId = new.id
        }
        await reloadMessages()
    } catch {
        errorMessage = String(describing: error)
    }
}

private func newSession() async {
    do {
        let s = try store.createChatSession(notebookId: notebook.id!, title: t.string(.chatNewSessionTitle))
        sessions.insert(s, at: 0)
        selectedSessionId = s.id
        await reloadMessages()
    } catch { errorMessage = String(describing: error) }
}

private func deleteSession(_ id: Int64) async {
    do {
        try store.deleteChatSession(id: id)
        sessions.removeAll { $0.id == id }
        selectedSessionId = sessions.first?.id
        await reloadMessages()
    } catch { errorMessage = String(describing: error) }
}
```

State changes from `session: ChatSession?` to `sessions: [ChatSession]` + `selectedSessionId: Int64?`. `reloadMessages()` uses `selectedSessionId`. `send()` uses `selectedSessionId` instead of `session.id`.

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/ChatView.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(app): multi-session chat (sidebar + new/delete)"
```

---

## Task 10: Save-as-note from chat message

**Files:** Modify `Sources/AINotebookApp/MessageBubble.swift`, modify `Sources/AINotebookApp/ChatView.swift`, add 1 localization key.

- [ ] **Step 1: Add localization key**

| key | EN | CS |
|---|---|---|
| `chatSaveAsNoteButton` | "Save as note" | "Uložit jako poznámku" |

- [ ] **Step 2: Add a "Save as note" button to assistant messages**

In `MessageBubble`, add a small button next to the citation chips (assistant messages only):

```swift
let onSaveAsNote: (() -> Void)?

// inside body, after citationChips:
if message.role == .assistant, let onSaveAsNote {
    Button(t.string(.chatSaveAsNoteButton)) { onSaveAsNote() }
        .buttonStyle(.borderless)
        .font(.caption)
}
```

Make `onSaveAsNote` optional so user messages don't show it.

- [ ] **Step 3: Wire from `ChatView`**

In the `ForEach(messages)`, pass:

```swift
onSaveAsNote: { Task { await saveAsNote(m) } }
```

Add the handler:

```swift
private func saveAsNote(_ msg: ChatMessage) async {
    do {
        _ = try store.createNote(
            notebookId: notebook.id!,
            title: "Chat reply — \(msg.createdAt.formatted(date: .abbreviated, time: .shortened))",
            bodyMd: msg.content,
            origin: .chat,
            originRef: msg.id
        )
    } catch {
        errorMessage = String(describing: error)
    }
}
```

- [ ] **Step 4: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/MessageBubble.swift Sources/AINotebookApp/ChatView.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(app): save assistant chat reply as note"
```

---

## Task 11: PDF page-jump from citation

**Files:** Modify `Sources/AINotebookApp/CitationPopover.swift`, modify `Sources/AINotebookApp/ChatView.swift`.

The chunk has `pageHint`. Citation only carries snippet+chunkId. Resolve chunk → fetch page hint → expose as link in popover.

- [ ] **Step 1: Add a `pageHint` to `Citation` OR resolve at popover open time**

Cleanest minimally invasive approach: resolve at popover open time. In `ChatView.showCitation`, fetch the chunk + source `rawPath`, hand both to the popover.

Modify `CitationPopover`'s init to take optional `pageHint: Int?` and `pdfFileURL: URL?`:

```swift
struct CitationPopover: View {
    let citation: Citation
    let sourceTitle: String
    let pageHint: Int?
    let pdfFileURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                Text(sourceTitle).font(.headline)
                Spacer()
                if let page = pageHint, let url = pdfFileURL {
                    Button("Open page \(page)") {
                        Self.openPDFAtPage(url: url, page: page)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            Divider()
            ScrollView { Text(citation.snippet).font(.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 400)
    }

    private static func openPDFAtPage(url: URL, page: Int) {
        // macOS Preview honours #page=N fragment, but only for file URLs
        // that include it via a quirk — safer: use NSWorkspace with a custom
        // open config that names Preview as the app and passes the page via
        // AppleScript. v1 minimal: open the file in Preview and let user
        // navigate. Page-jump exact is a follow-up.
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Wire in `ChatView.showCitation`**

```swift
@State private var popoverPageHint: Int?
@State private var popoverPDFURL: URL?

private func showCitation(_ c: Citation) {
    Task { @MainActor in
        let source = try? store.source(id: c.sourceId)
        let chunks = (try? store.chunks(sourceId: c.sourceId)) ?? []
        let hint = chunks.first(where: { $0.id == c.chunkId })?.pageHint
        let isPDF = (source?.type == .pdf)
        let url: URL? = (isPDF && (source?.rawPath != nil)) ? URL(fileURLWithPath: source!.rawPath!) : nil
        popoverSourceTitle = source?.title ?? ""
        popoverPageHint = hint
        popoverPDFURL = url
        popoverCitation = c
    }
}
```

And pass into the popover:

```swift
.popover(item: $popoverCitation) { c in
    CitationPopover(
        citation: c,
        sourceTitle: popoverSourceTitle,
        pageHint: popoverPageHint,
        pdfFileURL: popoverPDFURL
    )
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookApp/CitationPopover.swift Sources/AINotebookApp/ChatView.swift
git commit -m "feat(app): citation popover surfaces PDF page hint + open in Preview"
```

---

## Task 12: Re-embed UI when embedding model changes

**Files:** Modify `Sources/AINotebookApp/SettingsView.swift`, add 2 localization keys.

- [ ] **Step 1: Add localization keys**

| key | EN | CS |
|---|---|---|
| `reembedButton` | "Re-embed all sources" | "Přeindexovat všechny zdroje" |
| `reembedConfirm` | "This deletes existing embeddings and re-runs them with the current model. Continue?" | "Smaže stávající vektory a přepočte je aktuálním modelem. Pokračovat?" |

- [ ] **Step 2: Add a section to SettingsView**

```swift
@EnvironmentObject private var embedderHolder: EmbedderHolder

// in body, append:
Section("Embedding") {
    HStack {
        Text("Current model:")
        Spacer()
        Text(settings.selectedEmbeddingModel).foregroundStyle(.secondary)
    }
    Button(settings.text.string(.reembedButton), role: .destructive) {
        Task { await reembedAll() }
    }
}

private func reembedAll() async {
    do {
        try await Task.detached { @MainActor in
            try store.deleteAllEmbeddings(model: settings.selectedEmbeddingModel)
        }.value
        await embedderHolder.worker.kick()
    } catch {
        // surface via existing error state if SettingsView has one;
        // otherwise log via print (acceptable for v1 settings).
        print("re-embed failed: \(error)")
    }
}
```

(If `SettingsView` already injects different env objects, adjust imports. The point: a single button that calls `deleteAllEmbeddings(model:)` then kicks the worker.)

- [ ] **Step 3: Add a confirm dialog**

Wrap the Button in `.confirmationDialog(...)`. Use `reembedConfirm` as the message.

- [ ] **Step 4: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/SettingsView.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(app): Settings — re-embed all sources with current model"
```

---

## Task 13: Model management UI in Settings

**Files:** Modify `Sources/AINotebookApp/SettingsView.swift`, create `Sources/AINotebookApp/ModelManagementSheet.swift`, add localization keys.

- [ ] **Step 1: Add localization keys**

| key | EN | CS |
|---|---|---|
| `manageModelsButton` | "Manage models…" | "Spravovat modely…" |
| `manageModelsTitle` | "Installed Ollama models" | "Nainstalované Ollama modely" |
| `manageModelsPullPlaceholder` | "Pull model name (e.g. mistral:7b)" | "Stáhnout model (např. mistral:7b)" |
| `manageModelsPullButton` | "Pull" | "Stáhnout" |
| `manageModelsRefreshButton` | "Refresh list" | "Obnovit seznam" |
| `chatModelPickerLabel` | "Chat model" | "Chatovací model" |
| `embeddingModelPickerLabel` | "Embedding model" | "Model pro vektorizaci" |

- [ ] **Step 2: Add chat + embedding model pickers to SettingsView**

For each: read from `client.listModels()` once on appear, store in `@State var availableModels`. Bind a `Picker` to `settings.selectedChatModel` / `settings.selectedEmbeddingModel`.

- [ ] **Step 3: Implement `ModelManagementSheet`**

```swift
// Sources/AINotebookApp/ModelManagementSheet.swift
import SwiftUI
import AINotebookCore

struct ModelManagementSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var ollama: OllamaClientHolder
    @Binding var isPresented: Bool

    @State private var models: [OllamaModel] = []
    @State private var pullName: String = ""
    @State private var working: Bool = false
    @State private var errorMessage: String?
    @State private var pullProgress: String = ""

    private var t: AppText { settings.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.string(.manageModelsTitle)).font(.title2).bold()
            List {
                ForEach(models, id: \.name) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.name).font(.headline)
                            Text(byteString(m.size)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await delete(name: m.name) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .disabled(working)
                    }
                }
            }
            .frame(minHeight: 200)
            HStack {
                TextField(t.string(.manageModelsPullPlaceholder), text: $pullName)
                    .textFieldStyle(.roundedBorder)
                Button(t.string(.manageModelsPullButton)) {
                    Task { await pull() }
                }
                .disabled(working || pullName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !pullProgress.isEmpty {
                ProgressView(pullProgress)
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button(t.string(.manageModelsRefreshButton)) { Task { await reload() } }
                Spacer()
                Button(t.string(.cancelButton)) { isPresented = false }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
        .task { await reload() }
    }

    private func byteString(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .binary)
    }

    @MainActor
    private func reload() async {
        do {
            models = try await ollama.client.listModels()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func delete(name: String) async {
        working = true; defer { working = false }
        do {
            try await ollama.client.deleteModel(name: name)
            await reload()
        } catch { errorMessage = String(describing: error) }
    }

    private func pull() async {
        let name = pullName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        working = true; pullProgress = "Starting…"
        defer { working = false; pullProgress = "" }
        do {
            for try await event in ollama.client.pullModel(name: name) {
                pullProgress = event.status
            }
            pullName = ""
            await reload()
        } catch { errorMessage = String(describing: error) }
    }
}
```

(If `OllamaModel` field name for size is `size: Int64?` instead of `Int64`, unwrap with `?? 0`. Adapt to the actual M2 struct shape.)

- [ ] **Step 4: Wire from SettingsView**

```swift
@State private var showingModelMgmt = false
// ...
Button(t.string(.manageModelsButton)) { showingModelMgmt = true }
// ...
.sheet(isPresented: $showingModelMgmt) {
    ModelManagementSheet(isPresented: $showingModelMgmt)
}
```

- [ ] **Step 5: Build + commit**

```bash
swift build 2>&1 | tail -5
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/ModelManagementSheet.swift Sources/AINotebookApp/SettingsView.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(app): model management sheet + chat/embedding pickers in Settings"
```

---

## Task 14: Final verification + tag + merge

- [ ] **Step 1: Clean build + parallel tests**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: build ok; ~155 tests pass (147 baseline + Delete(2) + PDFPageHints(1) + ChatRetry(2) + TransformationStream(1) + NotebookScope(1) + assorted localization smoke tests).

- [ ] **Step 2: Rebuild release artefacts**

```bash
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

- [ ] **Step 3: Bump VERSION + CHANGELOG entry**

```bash
echo "0.2.0" > VERSION
```

Edit `Sources/AINotebookCore/AINotebookVersion.swift` → `"0.2.0"`.

Prepend to `CHANGELOG.md`:

```markdown
## [0.2.0] — 2026-05-25

Deferred polish — closes all in-scope v1 gaps from M5/M6/M7.

### Added
- "Save as note" button on assistant chat messages.
- Notebook-scope transformations (run a template over every source).
- Custom transformation editor (create/edit/delete user templates).
- Multi-session chat per notebook (sidebar with new/delete).
- Model management sheet in Settings (list/pull/delete via Ollama API).
- Chat & embedding model pickers in Settings.
- PDF citation popover surfaces the source page and opens in Preview.
- Re-embed-all action in Settings (delete vectors + drain worker).
- Streaming UI for transformation runs (live token render).

### Changed
- `ChatEngine` retries failed streams (exponential backoff, 2 attempts).
- `build-app.sh` excludes `*Tests.bundle` artefacts from the release .app.
```

Commit:
```bash
git add VERSION CHANGELOG.md Sources/AINotebookCore/AINotebookVersion.swift
git commit -m "chore: bump version to 0.2.0 + CHANGELOG"
```

- [ ] **Step 4: Merge + tag**

```bash
git checkout main
git merge --ff-only m7-1-deferred-polish
git tag -a v0.2.0 -m "v0.2.0 — close all v1 polish gaps"
git log --oneline | head -20
```

---

## Acceptance criteria (M7.1 done when ALL true)

- `swift test --parallel` ≥ 155 tests, 0 failures.
- `OllamaClient.deleteModel` works against the stub.
- Ingested PDFs produce chunks with non-nil `pageHint` values.
- `ChatEngine.send` retries on transient error and succeeds.
- `TransformationEngine.run(...onToken:)` invokes the callback per token.
- `TransformationEngine.runNotebookScope` joins all sources' chunks.
- `TransformationEditorSheet` creates/edits/deletes custom templates.
- `ChatView` shows a session sidebar; new + delete work.
- "Save as note" on an assistant message creates a `notes` row with `origin = .chat` and the message id as `originRef`.
- Citation popover shows a "Open page N" button for PDF sources with a page hint.
- Settings "Re-embed all" empties `chunk_embeddings` for the current model and kicks the worker.
- `ModelManagementSheet` lists, pulls, and deletes models.
- All new EN/CS strings render in both languages.
- `tools/macos/build-app.sh` produces a `.app` whose Resources contain no `*Tests.bundle`.
- Local git tag `v0.2.0` exists; `main` fast-forwarded.

---

## Notes for the implementer

- **Order matters: do Task 4 (PDF page hints) before Task 11 (citation popover wire), so page_hint actually populates when smoke-testing.**
- **`updateTransformation` scope:** Task 8 needs scope mutability. Either extend the existing M6 `updateTransformation(id:name:promptTemplate:)` to also take `scope:`, or add a separate `updateTransformationScope(id:scope:)`. Either is fine — match whichever feels least disruptive.
- **`OllamaModel` shape:** verify the size field name in `Sources/AINotebookCore/OllamaModel.swift` before writing the byte string formatter in Task 13.
- **SettingsView env objects:** if `OllamaClientHolder` or `EmbedderHolder` aren't currently injected into Settings, add the `.environmentObject` lines in `AINotebookAppEntry`'s scene body. Look at how other env objects flow to Settings as the source of truth.
- **Model picker fallback:** if `OllamaClient.listModels()` errors (e.g. daemon down), the model pickers should fall back to free-text input with the current value pre-filled. Don't crash.
- **PDF page-jump fidelity:** opening Preview at the exact page from Swift is fiddly (the documented `#page=N` URL fragment only works with `file://` URLs in *some* PDF viewers). v1 settles for "open in Preview at page 1" and exposes the page number to the user as text. A proper PDFKit-based viewer panel is a follow-up.
