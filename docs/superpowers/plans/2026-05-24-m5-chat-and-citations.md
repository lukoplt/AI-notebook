# M5: Chat Engine + Inline Citations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-notebook chat experience: user asks a question, the engine retrieves top-K chunks via the M4 Retriever, builds a system prompt that asks the LLM to cite chunks as `[1]`, `[2]`, etc., streams the reply token-by-token, parses citation markers, and lets the user click a citation to see the source snippet. Chat sessions and messages persist to SQLite so the conversation survives restarts.

**Architecture:** A new `ChatEngine` actor owns the per-turn flow: retrieve → render system+history+user → `OllamaClient.chat` stream → collect tokens → finalize message + citations. `MigrationV4` adds `chat_sessions` and `messages` tables (already in the design spec). `NotebookStore+Chat` exposes CRUD. SwiftUI shows the conversation in `ChatView` (replaces the `.chat` tab placeholder) with a sticky input field at the bottom, streaming text in the latest assistant bubble, and tappable `[N]` chips that open a `CitationPopover` showing the chunk text + source title.

**Tech Stack:** Swift 6, GRDB (existing), `OllamaClient.chat` streaming (M2), `Retriever` (M4), SwiftUI.

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV4.swift` — adds `chat_sessions`, `messages` tables + indexes
- `Sources/AINotebookCore/ChatSession.swift` — GRDB record
- `Sources/AINotebookCore/ChatMessage.swift` — GRDB record + role enum + Citation value type
- `Sources/AINotebookCore/NotebookStore+Chat.swift` — CRUD: session list, message list, append, delete
- `Sources/AINotebookCore/SystemPrompt.swift` — pure function: context+history → composed system prompt
- `Sources/AINotebookCore/CitationParser.swift` — extract `[N]` markers from streamed text → `[Citation]`
- `Sources/AINotebookCore/ChatEngine.swift` — actor orchestrating retrieve → stream → finalize
- `Sources/AINotebookApp/ChatEngineHolder.swift` — `ObservableObject` wrapper for SwiftUI
- `Sources/AINotebookApp/ChatView.swift` — message list + input field
- `Sources/AINotebookApp/MessageBubble.swift` — single user/assistant message with citation chips
- `Sources/AINotebookApp/CitationPopover.swift` — popover showing chunk text + source title
- `Tests/AINotebookCoreTests/MigrationV4Tests.swift`
- `Tests/AINotebookCoreTests/NotebookStoreChatTests.swift`
- `Tests/AINotebookCoreTests/SystemPromptTests.swift`
- `Tests/AINotebookCoreTests/CitationParserTests.swift`
- `Tests/AINotebookCoreTests/ChatEngineTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register `MigrationV4`
- `Sources/AINotebookCore/Localization.swift` — add 8 chat-UI keys (EN + CS)
- `Sources/AINotebookApp/AINotebookApp.swift` — construct + inject `ChatEngineHolder`
- `Sources/AINotebookApp/NotebookDetailView.swift` — swap `.chat` placeholder for `ChatView`

---

## Task 1: Branch off main

- [ ] **Step 1: Branch + baseline**

```bash
git checkout main
git checkout -b m5-chat
swift test --parallel 2>&1 | tail -5
```

Expected: 116/116 pass.

---

## Task 2: `MigrationV4` — chat_sessions + messages

**Files:** Create `Sources/AINotebookCore/MigrationV4.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV4Tests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV4Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV4Tests: XCTestCase {
    func testV4CreatesSessionAndMessageTables() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("chat_sessions"))
            XCTAssertTrue(names.contains("messages"))
        }
    }

    func testCascadeFromNotebookToSessionsToMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chat_sessions(notebook_id,title,created_at) VALUES (?,?,?)",
                arguments: [nb.id!, "S", Date()]
            )
            let sessionId = db.lastInsertedRowID
            try db.execute(
                sql: "INSERT INTO messages(session_id,role,content,created_at) VALUES (?,?,?,?)",
                arguments: [sessionId, "user", "hi", Date()]
            )
        }
        try store.deleteNotebook(id: nb.id!)
        try store.runOnDatabase { db in
            let sessions: Int = try Int.fetchOne(db, sql: "SELECT count(*) FROM chat_sessions") ?? -1
            let messages: Int = try Int.fetchOne(db, sql: "SELECT count(*) FROM messages")     ?? -1
            XCTAssertEqual(sessions, 0)
            XCTAssertEqual(messages, 0)
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV4Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV4.swift
import GRDB

public func registerMigrationV4(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v4_chat_sessions_and_messages") { db in
        try db.create(table: "chat_sessions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("notebook_id", .integer)
                .notNull()
                .references("notebooks", onDelete: .cascade)
            t.column("title",      .text).notNull()
            t.column("created_at", .datetime).notNull()
        }
        try db.create(
            index: "idx_chat_sessions_notebook",
            on: "chat_sessions",
            columns: ["notebook_id", "created_at"]
        )

        try db.create(table: "messages") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("session_id", .integer)
                .notNull()
                .references("chat_sessions", onDelete: .cascade)
            t.column("role",           .text).notNull()   // 'system' | 'user' | 'assistant'
            t.column("content",        .text).notNull()
            t.column("citations_json", .text)             // JSON array of {chunkId, sourceId, score}
            t.column("created_at",     .datetime).notNull()
        }
        try db.create(
            index: "idx_messages_session",
            on: "messages",
            columns: ["session_id", "created_at"]
        )
    }
}
```

- [ ] **Step 4: Register V4 in `NotebookStore.init`**

Append after `registerMigrationV3(on: &migrator)`:

```swift
        registerMigrationV4(on: &migrator)
```

- [ ] **Step 5: Verify pass + commit**

```bash
swift test --filter MigrationV4Tests 2>&1 | tail -10
git add Sources/AINotebookCore/MigrationV4.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV4Tests.swift
git commit -m "feat(core): MigrationV4 — chat_sessions + messages"
```

Expected: 2/2 pass.

---

## Task 3: `ChatSession` + `ChatMessage` GRDB records

**Files:** Create `Sources/AINotebookCore/ChatSession.swift`, `Sources/AINotebookCore/ChatMessage.swift`. No standalone test — covered by Task 4.

- [ ] **Step 1: Implement `ChatSession.swift`**

```swift
// Sources/AINotebookCore/ChatSession.swift
import Foundation
import GRDB

public struct ChatSession: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var notebookId: Int64
    public var title: String
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        notebookId: Int64,
        title: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.notebookId = notebookId
        self.title = title
        self.createdAt = createdAt
    }
}

extension ChatSession: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "chat_sessions"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case notebookId = "notebook_id"
        case title
        case createdAt  = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 2: Implement `ChatMessage.swift`**

```swift
// Sources/AINotebookCore/ChatMessage.swift
import Foundation
import GRDB

public enum ChatRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
}

public struct Citation: Equatable, Hashable, Codable, Sendable {
    public let marker: Int           // the [N] number shown to the user, 1-indexed
    public let chunkId: Int64
    public let sourceId: Int64
    public let snippet: String

    public init(marker: Int, chunkId: Int64, sourceId: Int64, snippet: String) {
        self.marker = marker
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.snippet = snippet
    }
}

public struct ChatMessage: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: Int64?
    public var sessionId: Int64
    public var role: ChatRole
    public var content: String
    public var citations: [Citation]    // mapped to citations_json on disk
    public var createdAt: Date

    public init(
        id: Int64? = nil,
        sessionId: Int64,
        role: ChatRole,
        content: String,
        citations: [Citation] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.citations = citations
        self.createdAt = createdAt
    }
}

extension ChatMessage: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "messages"
    public static let databaseColumnEncodingStrategy = DatabaseColumnEncodingStrategy.convertToSnakeCase
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public enum Columns: String {
        case id
        case sessionId     = "session_id"
        case role
        case content
        case citationsJson = "citations_json"
        case createdAt     = "created_at"

        var column: Column { Column(self.rawValue) }
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // Custom encode/decode for the JSON column.
    public init(row: Row) throws {
        let cits: [Citation]
        if let raw: String = row[Columns.citationsJson.rawValue],
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Citation].self, from: data) {
            cits = decoded
        } else {
            cits = []
        }
        let roleRaw: String = row[Columns.role.rawValue]
        try self.init(
            id: row[Columns.id.rawValue],
            sessionId: row[Columns.sessionId.rawValue],
            role: ChatRole(rawValue: roleRaw) ?? .user,
            content: row[Columns.content.rawValue],
            citations: cits,
            createdAt: row[Columns.createdAt.rawValue]
        )
    }

    public func encode(to container: inout PersistenceContainer) throws {
        container[Columns.sessionId.rawValue] = sessionId
        container[Columns.role.rawValue]      = role.rawValue
        container[Columns.content.rawValue]   = content
        container[Columns.citationsJson.rawValue] =
            citations.isEmpty
                ? nil
                : String(data: try JSONEncoder().encode(citations), encoding: .utf8)
        container[Columns.createdAt.rawValue] = createdAt
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookCore/ChatSession.swift Sources/AINotebookCore/ChatMessage.swift
git commit -m "feat(core): ChatSession + ChatMessage GRDB records"
```

---

## Task 4: `NotebookStore+Chat` — session + message CRUD

**Files:** Create `Sources/AINotebookCore/NotebookStore+Chat.swift`, test `Tests/AINotebookCoreTests/NotebookStoreChatTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NotebookStoreChatTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreChatTests: XCTestCase {

    func testCreateAndListSessions() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s1 = try store.createChatSession(notebookId: nb.id!, title: "First")
        _ = try store.createChatSession(notebookId: nb.id!, title: "Second")
        let list = try store.chatSessions(notebookId: nb.id!)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.title)), ["First", "Second"])
        XCTAssertEqual(s1.title, "First")
    }

    func testAppendAndFetchMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        try store.appendMessage(ChatMessage(
            sessionId: session.id!, role: .user, content: "hello"
        ))
        try store.appendMessage(ChatMessage(
            sessionId: session.id!, role: .assistant, content: "hi [1]",
            citations: [Citation(marker: 1, chunkId: 42, sourceId: 7, snippet: "snip")]
        ))
        let msgs = try store.messages(sessionId: session.id!)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].content, "hello")
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[1].citations.count, 1)
        XCTAssertEqual(msgs[1].citations[0].chunkId, 42)
    }

    func testDeleteSessionCascadesMessages() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")
        try store.appendMessage(ChatMessage(sessionId: session.id!, role: .user, content: "x"))
        try store.deleteChatSession(id: session.id!)
        XCTAssertEqual(try store.messages(sessionId: session.id!).count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NotebookStoreChatTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement extension**

```swift
// Sources/AINotebookCore/NotebookStore+Chat.swift
import Foundation
import GRDB

extension NotebookStore {

    @discardableResult
    public func createChatSession(notebookId: Int64, title: String) throws -> ChatSession {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "New chat" : trimmed
        var session = ChatSession(notebookId: notebookId, title: resolved)
        try runOnDatabase { db in
            try session.insert(db)
        }
        return session
    }

    public func chatSessions(notebookId: Int64) throws -> [ChatSession] {
        try runOnDatabase { db in
            try ChatSession
                .filter(ChatSession.Columns.notebookId.column == notebookId)
                .order(ChatSession.Columns.createdAt.column.desc)
                .fetchAll(db)
        }
    }

    public func deleteChatSession(id: Int64) throws {
        try runOnDatabase { db in
            _ = try ChatSession.deleteOne(db, key: id)
        }
    }

    public func appendMessage(_ message: ChatMessage) throws {
        var copy = message
        try runOnDatabase { db in
            try copy.insert(db)
        }
    }

    public func messages(sessionId: Int64) throws -> [ChatMessage] {
        try runOnDatabase { db in
            try ChatMessage
                .filter(ChatMessage.Columns.sessionId.column == sessionId)
                .order(ChatMessage.Columns.createdAt.column.asc)
                .fetchAll(db)
        }
    }

    /// Persist an assistant message and return the row ID. Used by the chat
    /// engine to finalize a streamed message.
    @discardableResult
    public func appendAssistantMessage(
        sessionId: Int64,
        content: String,
        citations: [Citation]
    ) throws -> Int64 {
        var message = ChatMessage(
            sessionId: sessionId,
            role: .assistant,
            content: content,
            citations: citations
        )
        try runOnDatabase { db in
            try message.insert(db)
        }
        return message.id ?? 0
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter NotebookStoreChatTests 2>&1 | tail -10
git add Sources/AINotebookCore/NotebookStore+Chat.swift Tests/AINotebookCoreTests/NotebookStoreChatTests.swift
git commit -m "feat(core): chat CRUD on NotebookStore (sessions/messages/append)"
```

Expected: 3/3 pass.

---

## Task 5: `SystemPrompt` — compose system+context+history

**Files:** Create `Sources/AINotebookCore/SystemPrompt.swift`, test `Tests/AINotebookCoreTests/SystemPromptTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/SystemPromptTests.swift
import XCTest
@testable import AINotebookCore

final class SystemPromptTests: XCTestCase {

    func testRendersHitsAsNumberedBlocks() {
        let hits = [
            RetrievalHit(chunkId: 10, sourceId: 1, score: 0.9, snippet: "alpha facts"),
            RetrievalHit(chunkId: 11, sourceId: 2, score: 0.7, snippet: "beta facts")
        ]
        let prompt = SystemPrompt.compose(hits: hits)
        XCTAssertTrue(prompt.contains("[1] alpha facts"))
        XCTAssertTrue(prompt.contains("[2] beta facts"))
    }

    func testIncludesCitationInstruction() {
        let prompt = SystemPrompt.compose(hits: [])
        XCTAssertTrue(prompt.lowercased().contains("cite"))
        XCTAssertTrue(prompt.contains("[N]"))
    }

    func testNoHitsStillProducesValidPrompt() {
        let prompt = SystemPrompt.compose(hits: [])
        XCTAssertFalse(prompt.isEmpty)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter SystemPromptTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/SystemPrompt.swift
import Foundation

public enum SystemPrompt {

    /// Composes the system prompt that goes ahead of the chat history.
    /// Numbered context blocks come from retrieval; the marker `[N]` in
    /// the context aligns with the citation markers the model is asked
    /// to emit.
    public static func compose(hits: [RetrievalHit]) -> String {
        let header = """
        You are a helpful assistant answering questions about the user's notebook.
        Use ONLY the provided CONTEXT to answer. If the answer isn't in the
        context, say so plainly. When you use a fact from a context block,
        cite it inline as [N] where N is the block number. Multiple citations
        may appear in a single sentence: [1][3].
        """

        if hits.isEmpty {
            return header + "\n\nCONTEXT:\n(none)"
        }

        let blocks = hits.enumerated().map { (i, hit) in
            "[\(i + 1)] \(hit.snippet)"
        }.joined(separator: "\n")

        return header + "\n\nCONTEXT:\n" + blocks
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter SystemPromptTests 2>&1 | tail -10
git add Sources/AINotebookCore/SystemPrompt.swift Tests/AINotebookCoreTests/SystemPromptTests.swift
git commit -m "feat(core): SystemPrompt — render hits + citation instruction"
```

Expected: 3/3 pass.

---

## Task 6: `CitationParser` — find `[N]` markers in streamed text

**Files:** Create `Sources/AINotebookCore/CitationParser.swift`, test `Tests/AINotebookCoreTests/CitationParserTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/CitationParserTests.swift
import XCTest
@testable import AINotebookCore

final class CitationParserTests: XCTestCase {

    func testFindsSingleCitation() {
        let markers = CitationParser.markers(in: "The sky is blue [1].")
        XCTAssertEqual(markers, [1])
    }

    func testFindsMultipleCitationsInOrder() {
        let markers = CitationParser.markers(in: "First [2]. Second [5]. Third [2].")
        XCTAssertEqual(markers, [2, 5, 2])
    }

    func testIgnoresMalformedMarkers() {
        let markers = CitationParser.markers(in: "[abc] [1.2] [-3] [1]")
        XCTAssertEqual(markers, [1])
    }

    func testHandlesAdjacentMarkers() {
        let markers = CitationParser.markers(in: "Both true [1][3].")
        XCTAssertEqual(markers, [1, 3])
    }

    func testEmptyOrNoMatchReturnsEmpty() {
        XCTAssertEqual(CitationParser.markers(in: ""), [])
        XCTAssertEqual(CitationParser.markers(in: "no markers here"), [])
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter CitationParserTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/CitationParser.swift
import Foundation

public enum CitationParser {

    private static let pattern = #"\[(\d+)\]"#

    /// Returns the citation numbers found in `text`, in order, with duplicates.
    public static func markers(in text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        var results: [Int] = []
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            let numRange = m.range(at: 1)
            let raw = ns.substring(with: numRange)
            if let n = Int(raw), n > 0 {
                results.append(n)
            }
        }
        return results
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter CitationParserTests 2>&1 | tail -10
git add Sources/AINotebookCore/CitationParser.swift Tests/AINotebookCoreTests/CitationParserTests.swift
git commit -m "feat(core): CitationParser — extract [N] markers from text"
```

Expected: 5/5 pass.

---

## Task 7: `ChatEngine` actor — retrieve → stream → finalize

**Files:** Create `Sources/AINotebookCore/ChatEngine.swift`, test `Tests/AINotebookCoreTests/ChatEngineTests.swift`

The engine needs a minimal abstraction over the streaming chat client so we can unit-test without hitting the network. Add a `ChatStreaming` protocol the real `OllamaClient` conforms to via a separate file in Task 8.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/ChatEngineTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class ChatEngineTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        let q: [Float]
        init(q: [Float] = [1, 0]) { self.q = q }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in q }
        }
    }

    final class MockChatClient: ChatStreaming, @unchecked Sendable {
        var capturedMessages: [[ChatTurn]] = []
        let tokens: [String]
        init(tokens: [String]) { self.tokens = tokens }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            capturedMessages.append(messages)
            let toks = tokens
            return AsyncThrowingStream { continuation in
                Task {
                    for t in toks {
                        continuation.yield(t)
                    }
                    continuation.finish()
                }
            }
        }
    }

    func testEndToEndStreamsTokensThenPersistsMessages() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        // One chunk + matching embedding so the retriever surfaces it.
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "src", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "the sky is blue", tokenCount: 4)]
        )
        let chunkId = try store.chunks(sourceId: s.id!).first!.id!
        try store.storeEmbedding(
            chunkId: chunkId, model: "emb",
            vector: EmbeddingVector(values: [1, 0])
        )
        let session = try store.createChatSession(notebookId: nb.id!, title: "T")

        let chat = MockChatClient(tokens: ["The sky ", "is blue ", "[1]."])
        let retriever = Retriever(store: store, client: MockEmbeddingClient(), model: "emb")

        let engine = ChatEngine(
            store: store,
            retriever: retriever,
            chat: chat,
            chatModel: "llama-test"
        )

        var streamed: [String] = []
        let final = try await engine.send(
            sessionId: session.id!,
            notebookId: nb.id!,
            userText: "what colour is the sky?"
        ) { token in
            streamed.append(token)
        }

        XCTAssertEqual(streamed.joined(), "The sky is blue [1].")
        XCTAssertEqual(final.content, "The sky is blue [1].")
        XCTAssertEqual(final.citations.first?.chunkId, chunkId)

        let persisted = try store.messages(sessionId: session.id!)
        XCTAssertEqual(persisted.count, 2)
        XCTAssertEqual(persisted[0].role, .user)
        XCTAssertEqual(persisted[0].content, "what colour is the sky?")
        XCTAssertEqual(persisted[1].role, .assistant)
        XCTAssertEqual(persisted[1].citations.first?.chunkId, chunkId)

        XCTAssertEqual(chat.capturedMessages.count, 1)
        let sent = chat.capturedMessages[0]
        XCTAssertEqual(sent.first?.role, .system)
        XCTAssertEqual(sent.last?.role, .user)
        XCTAssertEqual(sent.last?.content, "what colour is the sky?")
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter ChatEngineTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/ChatEngine.swift
import Foundation

public struct ChatTurn: Equatable, Sendable {
    public let role: ChatRole
    public let content: String
    public init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

public protocol ChatStreaming: Sendable {
    func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error>
}

public actor ChatEngine {
    private let store: NotebookStore
    private let retriever: Retriever
    private let chat: ChatStreaming
    public let chatModel: String
    public let topK: Int

    public init(
        store: NotebookStore,
        retriever: Retriever,
        chat: ChatStreaming,
        chatModel: String,
        topK: Int = 8
    ) {
        self.store = store
        self.retriever = retriever
        self.chat = chat
        self.chatModel = chatModel
        self.topK = topK
    }

    /// Runs one turn: persist the user message, retrieve, build prompt,
    /// stream the assistant reply (calling `onToken` for each chunk),
    /// parse citations, persist the assistant message, and return it.
    @discardableResult
    public func send(
        sessionId: Int64,
        notebookId: Int64,
        userText: String,
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ChatMessage {
        // 1) Persist the user message.
        try await MainActor.run {
            try store.appendMessage(ChatMessage(
                sessionId: sessionId,
                role: .user,
                content: userText
            ))
        }

        // 2) Retrieve context.
        let hits = try await retriever.search(
            notebookId: notebookId,
            query: userText,
            topK: topK
        )

        // 3) Compose messages.
        let systemContent = SystemPrompt.compose(hits: hits)
        let history = try await MainActor.run {
            try store.messages(sessionId: sessionId)
        }
        var turns: [ChatTurn] = [ChatTurn(role: .system, content: systemContent)]
        for m in history {
            turns.append(ChatTurn(role: m.role, content: m.content))
        }

        // 4) Stream tokens.
        var assembled = ""
        for try await token in chat.stream(model: chatModel, messages: turns) {
            assembled += token
            onToken(token)
        }

        // 5) Parse citation markers and resolve to chunks.
        let markers = CitationParser.markers(in: assembled)
        let unique = Array(NSOrderedSet(array: markers)) as? [Int] ?? Array(Set(markers))
        var citations: [Citation] = []
        for m in unique {
            guard m >= 1, m <= hits.count else { continue }
            let h = hits[m - 1]
            citations.append(Citation(
                marker: m,
                chunkId: h.chunkId,
                sourceId: h.sourceId,
                snippet: h.snippet
            ))
        }

        // 6) Persist the assistant message.
        let stored = ChatMessage(
            sessionId: sessionId,
            role: .assistant,
            content: assembled,
            citations: citations
        )
        try await MainActor.run {
            try store.appendMessage(stored)
        }
        return stored
    }
}
```

- [ ] **Step 4: Verify pass + commit**

```bash
swift test --filter ChatEngineTests 2>&1 | tail -10
git add Sources/AINotebookCore/ChatEngine.swift Tests/AINotebookCoreTests/ChatEngineTests.swift
git commit -m "feat(core): ChatEngine — retrieve, stream, parse citations, persist"
```

Expected: 1/1 pass.

---

## Task 8: Conform `OllamaClient` to `ChatStreaming`

**Files:** Create `Sources/AINotebookCore/OllamaClient+ChatStreaming.swift`

The M2 `OllamaClient.chat` already returns `AsyncThrowingStream<String, Error>` of token deltas. Wrap its `messages` parameter to match `ChatTurn`. Verify the M2 signature first:

```bash
grep -n "func chat" Sources/AINotebookCore/OllamaClient.swift
```

- [ ] **Step 1: Implement the conformance**

```swift
// Sources/AINotebookCore/OllamaClient+ChatStreaming.swift
import Foundation

extension OllamaClient: ChatStreaming {
    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        // Map ChatTurn → the request type that M2 OllamaClient.chat accepts.
        // The OllamaChatTypes file should contain something like:
        //   public struct OllamaChatMessage { let role: String; let content: String }
        // and `chat(model:messages:)` returns AsyncThrowingStream<String, Error>.
        // If the actual API shape differs, adapt to it; the semantic to keep
        // is "model + [role, content] → token stream".
        let wire = messages.map { turn in
            OllamaChatMessage(role: turn.role.rawValue, content: turn.content)
        }
        return chat(model: model, messages: wire)
    }
}
```

If the wire type name or the `chat(model:messages:)` signature differs, adapt accordingly. The protocol method signature must remain exactly as in `ChatEngine.swift`.

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookCore/OllamaClient+ChatStreaming.swift
git commit -m "feat(core): OllamaClient conforms to ChatStreaming"
```

---

## Task 9: 8 EN/CS chat-UI localization keys

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, append test in `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Add keys**

| key | EN | CS |
|---|---|---|
| `chatNewSessionTitle` | "New chat" | "Nový chat" |
| `chatInputPlaceholder` | "Ask anything about your sources…" | "Zeptej se na cokoli ze svých zdrojů…" |
| `chatSendButton` | "Send" | "Odeslat" |
| `chatEmptyState` | "Start by asking a question." | "Začněte položením otázky." |
| `chatErrorPrefix` | "Chat error: " | "Chyba chatu: " |
| `chatCitationsSectionTitle` | "Citations" | "Citace" |
| `chatNoCitationsForMessage` | "No citations" | "Žádné citace" |
| `chatRegenerateButton` | "Regenerate" | "Znovu vygenerovat" |

Wire through `AppText` matching the existing pattern (enum case + EN dict + CS dict).

- [ ] **Step 2: Add smoke test**

```swift
    func testChatSendButtonIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.chatSendButton), "Send")
        XCTAssertEqual(AppText(language: .czech)  .string(.chatSendButton), "Odeslat")
    }
```

- [ ] **Step 3: Build + test + commit**

```bash
swift test --filter LocalizationTests 2>&1 | tail -10
git add Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): 8 EN/CS chat-UI localization keys"
```

---

## Task 10: `ChatEngineHolder` + wire into app entry

**Files:** Create `Sources/AINotebookApp/ChatEngineHolder.swift`, modify `Sources/AINotebookApp/AINotebookApp.swift`

- [ ] **Step 1: Implement holder**

```swift
// Sources/AINotebookApp/ChatEngineHolder.swift
import SwiftUI
import AINotebookCore

@MainActor
final class ChatEngineHolder: ObservableObject {
    let engine: ChatEngine
    init(engine: ChatEngine) { self.engine = engine }
}
```

- [ ] **Step 2: Construct + inject**

In `Sources/AINotebookApp/AINotebookApp.swift`:

1. Add field:
   ```swift
   @StateObject private var chatHolder: ChatEngineHolder
   ```
2. In `init()`, after `embedder` and `retriever` instances (or right after `embedder`), build the retriever and engine:
   ```swift
   let retriever = Retriever(
       store: store,
       client: client,
       model: settings.selectedEmbeddingModel
   )
   let engine = ChatEngine(
       store: store,
       retriever: retriever,
       chat: client,
       chatModel: settings.selectedChatModel
   )
   _chatHolder = StateObject(wrappedValue: ChatEngineHolder(engine: engine))
   ```
3. Inject:
   ```swift
   .environmentObject(chatHolder)
   ```

- [ ] **Step 3: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/ChatEngineHolder.swift Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): wire ChatEngine into app entry"
```

---

## Task 11: `MessageBubble` view

**Files:** Create `Sources/AINotebookApp/MessageBubble.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/MessageBubble.swift
import SwiftUI
import AINotebookCore

struct MessageBubble: View {

    let message: ChatMessage
    let language: AppLanguage
    let onCitationTapped: (Citation) -> Void

    private var t: AppText { AppText(language: language) }

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !message.citations.isEmpty {
                    citationChips
                }
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
        .padding(.vertical, 4)
    }

    private var citationChips: some View {
        HStack(spacing: 6) {
            ForEach(message.citations, id: \.marker) { c in
                Button {
                    onCitationTapped(c)
                } label: {
                    Text("[\(c.marker)]")
                        .font(.caption.monospaced())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.20))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/MessageBubble.swift
git commit -m "feat(app): MessageBubble with citation chips"
```

---

## Task 12: `CitationPopover` view

**Files:** Create `Sources/AINotebookApp/CitationPopover.swift`

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookApp/CitationPopover.swift
import SwiftUI
import AINotebookCore

struct CitationPopover: View {

    let citation: Citation
    let sourceTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "quote.opening")
                Text(sourceTitle)
                    .font(.headline)
            }
            Divider()
            ScrollView {
                Text(citation.snippet)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 360)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build 2>&1 | tail -10
git add Sources/AINotebookApp/CitationPopover.swift
git commit -m "feat(app): CitationPopover (snippet preview)"
```

---

## Task 13: `ChatView` — assembled chat surface

**Files:** Create `Sources/AINotebookApp/ChatView.swift`, modify `Sources/AINotebookApp/NotebookDetailView.swift`

- [ ] **Step 1: Implement `ChatView.swift`**

```swift
// Sources/AINotebookApp/ChatView.swift
import SwiftUI
import AINotebookCore

struct ChatView: View {
    let notebook: Notebook

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var chatHolder: ChatEngineHolder

    @State private var session: ChatSession?
    @State private var messages: [ChatMessage] = []
    @State private var input: String = ""
    @State private var streamingDraft: String = ""
    @State private var sending = false
    @State private var errorMessage: String?
    @State private var popoverCitation: Citation?
    @State private var popoverSourceTitle: String = ""

    private var t: AppText { settings.text }

    var body: some View {
        VStack(spacing: 0) {
            messagesList
            Divider()
            inputBar
        }
        .padding(16)
        .task(id: notebook.id) { await ensureSession() }
        .popover(item: $popoverCitation) { c in
            CitationPopover(citation: c, sourceTitle: popoverSourceTitle)
        }
    }

    @ViewBuilder
    private var messagesList: some View {
        if messages.isEmpty && streamingDraft.isEmpty {
            VStack {
                Spacer()
                Text(t.string(.chatEmptyState))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(messages) { m in
                        MessageBubble(
                            message: m,
                            language: settings.language,
                            onCitationTapped: { c in showCitation(c) }
                        )
                    }
                    if !streamingDraft.isEmpty {
                        MessageBubble(
                            message: ChatMessage(
                                sessionId: session?.id ?? 0,
                                role: .assistant,
                                content: streamingDraft
                            ),
                            language: settings.language,
                            onCitationTapped: { _ in }
                        )
                    }
                    if let errorMessage {
                        Text(t.string(.chatErrorPrefix) + errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(t.string(.chatInputPlaceholder), text: $input, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(sending)

            Button(t.string(.chatSendButton)) {
                Task { await send() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(sending || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 8)
    }

    @MainActor
    private func ensureSession() async {
        do {
            let existing = try store.chatSessions(notebookId: notebook.id!)
            if let s = existing.first {
                session = s
            } else {
                session = try store.createChatSession(
                    notebookId: notebook.id!,
                    title: t.string(.chatNewSessionTitle)
                )
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    @MainActor
    private func reloadMessages() async {
        guard let s = session else { return }
        do {
            messages = try store.messages(sessionId: s.id!)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func send() async {
        guard let s = session else { return }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        sending = true
        errorMessage = nil
        streamingDraft = ""
        defer { sending = false; streamingDraft = "" }
        do {
            _ = try await chatHolder.engine.send(
                sessionId: s.id!,
                notebookId: notebook.id!,
                userText: text
            ) { token in
                Task { @MainActor in streamingDraft += token }
            }
            await reloadMessages()
        } catch {
            errorMessage = String(describing: error)
            await reloadMessages()
        }
    }

    private func showCitation(_ c: Citation) {
        Task { @MainActor in
            let source = (try? store.source(id: c.sourceId))?.title ?? ""
            popoverSourceTitle = source
            popoverCitation = c
        }
    }
}

// SwiftUI `.popover(item:)` requires Identifiable.
extension Citation: Identifiable {
    public var id: Int { marker * 1_000_000 + Int(chunkId % 999_999) }
}
```

- [ ] **Step 2: Swap `.chat` placeholder in `NotebookDetailView`**

In `Sources/AINotebookApp/NotebookDetailView.swift`, in the `Group { switch selectedTab }` that's already there from M3, change the `.chat` arm:

```swift
case .chat:
    ChatView(notebook: notebook)
```

Leave `.notes` and `.transformations` on the existing `placeholder`.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookApp/ChatView.swift Sources/AINotebookApp/NotebookDetailView.swift
git commit -m "feat(app): ChatView wired into notebook chat tab"
```

---

## Task 14: Final verification + tag + merge

- [ ] **Step 1: Clean build + parallel test run**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: build ok; **~134 tests** pass (116 M4 baseline + MigrationV4(2) + NotebookStoreChat(3) + SystemPrompt(3) + CitationParser(5) + ChatEngine(1) + Localization(1) ≈ 131-134).

- [ ] **Step 2: Smoke test the app**

```bash
swift run AINotebookApp
```

Requires Ollama running with the configured chat + embedding models pulled. Manual checks:
- Open a notebook with at least one ingested + embedded source.
- Switch to the **Chat** tab.
- Type "what is this source about?" → send.
- See tokens streaming into the latest assistant bubble.
- Citation chips `[1]`, `[2]` appear at the bottom of the assistant message.
- Click a citation chip → popover shows the chunk text + source title.
- Quit and relaunch → conversation history reappears.

- [ ] **Step 3: Tag**

```bash
git tag -a m5-chat-tag -m "M5 chat engine + inline citations complete"
```

- [ ] **Step 4: Merge to main**

```bash
git checkout main
git merge --ff-only m5-chat
git log --oneline | head -16
```

---

## Acceptance criteria (M5 done when ALL true)

- `swift build` succeeds.
- `swift test --parallel` passes; ~130+ tests, 0 failures.
- `MigrationV4` adds `chat_sessions` + `messages` with `ON DELETE CASCADE` from `notebooks → chat_sessions → messages`.
- `ChatMessage` round-trips citations through `citations_json`.
- `SystemPrompt.compose` always includes the citation instruction and `[N]` blocks.
- `CitationParser.markers` extracts `[N]` integers in order, ignoring malformed forms.
- `ChatEngine.send` persists user msg, streams tokens via `onToken`, parses citations against retrieval hits, persists assistant msg.
- App: typing a question in the Chat tab streams an answer with clickable citations that open the popover.
- 8 new EN/CS strings render in both languages.
- Local git tag `m5-chat-tag` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **OllamaClient.chat signature** lives in `OllamaClient.swift` + `OllamaChatTypes.swift`. Verify the wire message type name and parameter labels before writing Task 8. If `chat(model:messages:)` requires a different request envelope, adapt — but keep the `ChatStreaming.stream(model:messages:)` protocol method exactly as defined in Task 7.
- **Streaming UI race:** Tokens arrive on whatever task the stream uses. We hop to MainActor inside `onToken` via `Task { @MainActor in streamingDraft += token }`. This is correct but does mean the draft can lag the actual stream by one runloop. Fine for v1.
- **Citation dedupe:** Multiple `[1]` markers in the response produce a single Citation row (we de-dupe by marker number). If the model emits `[1][1]` we still show one chip.
- **Out-of-range markers:** If the model invents `[99]` when only 3 hits exist, we drop it silently. Future polish: surface a "model cited non-existent block" warning.
- **Session model:** v1 keeps one chat session per notebook ("auto-create on first visit"). M6+ can add multi-session UI (sidebar listing sessions per notebook).
- **System prompt language:** Stays English in v1 because Ollama models follow English instructions most reliably. Localization sweep in M7 may add a Czech alternative.
