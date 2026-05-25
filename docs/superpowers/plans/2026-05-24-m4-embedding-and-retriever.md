# M4: Embedding + Hybrid Retriever Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Embed every source chunk via Ollama, persist 768-dim float vectors in SQLite, and expose a hybrid retriever (vector cosine top-K + FTS5 BM25 top-K → Reciprocal Rank Fusion) for downstream RAG (M5). Includes a background embedding worker that processes new chunks automatically.

**Architecture:** A new `chunk_embeddings` table stores embeddings as raw BLOB (no sqlite-vec extension — linear cosine in Swift is <50 ms for v1's expected scale of <10 k chunks per notebook). An `Embedder` actor batches chunks through `OllamaClient.embed`, writing rows as it goes. A `Retriever` runs vector top-K and FTS5 top-K in parallel, then merges via RRF (k = 60, the standard). An `EmbeddingWorker` (long-running Task on the app) drains a "needs-embedding" queue whenever new chunks land. The selected embedding model is captured in `app_settings` so a dimension change can trigger a re-embed.

**Tech Stack:** Swift 6, GRDB (existing), `OllamaClient.embed` (M2), Accelerate (vDSP) for fast cosine, FTS5 (M3).

---

## File Structure

**Create:**
- `Sources/AINotebookCore/MigrationV3.swift` — adds `chunk_embeddings` table + `embedding_model` settings key
- `Sources/AINotebookCore/EmbeddingVector.swift` — value type wrapping `[Float]` + BLOB (de)serialization
- `Sources/AINotebookCore/NotebookStore+Embeddings.swift` — CRUD: store + load embeddings, list unembedded chunks
- `Sources/AINotebookCore/Cosine.swift` — `cosineSimilarity(_:_:)` via Accelerate vDSP
- `Sources/AINotebookCore/Embedder.swift` — batches chunks through Ollama, writes rows, reports progress
- `Sources/AINotebookCore/RetrievalHit.swift` — value type: `{chunkId, sourceId, score, snippet}`
- `Sources/AINotebookCore/Retriever.swift` — hybrid search (vec top-K + FTS5 top-K → RRF)
- `Sources/AINotebookCore/EmbeddingWorker.swift` — background Task that drains the unembedded queue
- `Sources/AINotebookApp/EmbedderHolder.swift` — `ObservableObject` wrapping `Embedder` for SwiftUI
- `Sources/AINotebookApp/IndexingStatusBadge.swift` — small SwiftUI view: "Indexing 12/47…" badge
- `Tests/AINotebookCoreTests/MigrationV3Tests.swift`
- `Tests/AINotebookCoreTests/EmbeddingVectorTests.swift`
- `Tests/AINotebookCoreTests/NotebookStoreEmbeddingsTests.swift`
- `Tests/AINotebookCoreTests/CosineTests.swift`
- `Tests/AINotebookCoreTests/EmbedderTests.swift`
- `Tests/AINotebookCoreTests/RetrieverTests.swift`

**Modify:**
- `Sources/AINotebookCore/NotebookStore.swift` — register `MigrationV3`
- `Sources/AINotebookCore/AppSettings.swift` — add `embeddingModel` persisted property
- `Sources/AINotebookCore/Localization.swift` — add 6 indexing-status keys (EN + CS)
- `Sources/AINotebookCore/IngestionService.swift` — after `replaceChunks`, notify the embedder
- `Sources/AINotebookApp/AINotebookApp.swift` — construct + inject `EmbedderHolder`, start `EmbeddingWorker`
- `Sources/AINotebookApp/SourceListView.swift` — show `IndexingStatusBadge`

---

## Task 1: Branch off main

**Files:** branch

- [ ] **Step 1: Branch**

```bash
git checkout main
git checkout -b m4-embedding
```

- [ ] **Step 2: Verify clean state**

```bash
swift test --parallel 2>&1 | tail -5
```

Expected: 95/95 pass (M3 baseline).

---

## Task 2: `MigrationV3` — `chunk_embeddings` table

**Files:** Create `Sources/AINotebookCore/MigrationV3.swift`, modify `Sources/AINotebookCore/NotebookStore.swift`, test `Tests/AINotebookCoreTests/MigrationV3Tests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/MigrationV3Tests.swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV3Tests: XCTestCase {
    func testV3CreatesChunkEmbeddingsTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let names: [String] = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
            XCTAssertTrue(names.contains("chunk_embeddings"), "got: \(names)")
        }
    }

    func testInsertEmbeddingThenReadItBack() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "alpha", tokenCount: 1, pageHint: nil)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        let bytes = Data(repeating: 0xAB, count: 768 * 4)
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (?,?,?,?)",
                arguments: [chunk.id!, 768, "nomic-embed-text", bytes]
            )
        }
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testCascadeDeleteWhenChunkDeleted() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "alpha", tokenCount: 1, pageHint: nil)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.runOnDatabase { db in
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (?,?,?,?)",
                arguments: [chunk.id!, 4, "m", Data([0, 0, 0, 0])]
            )
        }
        try store.deleteSource(id: s.id!)  // cascades to chunks → cascades to embeddings
        let count: Int = try store.runOnDatabase { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings") ?? -1
        }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter MigrationV3Tests 2>&1 | tail -10
```

- [ ] **Step 3: Implement migration**

```swift
// Sources/AINotebookCore/MigrationV3.swift
import GRDB

public func registerMigrationV3(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v3_chunk_embeddings") { db in
        try db.create(table: "chunk_embeddings") { t in
            t.column("chunk_id", .integer)
                .primaryKey()
                .references("source_chunks", onDelete: .cascade)
            t.column("dim",       .integer).notNull()
            t.column("model",     .text).notNull()
            t.column("embedding", .blob).notNull()
        }
        try db.create(
            index: "idx_chunk_embeddings_model",
            on: "chunk_embeddings",
            columns: ["model"]
        )
    }
}
```

- [ ] **Step 4: Register in `NotebookStore.init`**

In `Sources/AINotebookCore/NotebookStore.swift`, append after the existing `registerMigrationV2` line:

```swift
        registerMigrationV3(on: &migrator)
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter MigrationV3Tests 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/MigrationV3.swift Sources/AINotebookCore/NotebookStore.swift Tests/AINotebookCoreTests/MigrationV3Tests.swift
git commit -m "feat(core): MigrationV3 — chunk_embeddings table"
```

---

## Task 3: `EmbeddingVector` value type + BLOB (de)serialization

**Files:** Create `Sources/AINotebookCore/EmbeddingVector.swift`, test `Tests/AINotebookCoreTests/EmbeddingVectorTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/EmbeddingVectorTests.swift
import XCTest
@testable import AINotebookCore

final class EmbeddingVectorTests: XCTestCase {

    func testRoundTripsThroughData() {
        let original = EmbeddingVector(values: [0.1, -0.2, 3.14, -42.0])
        let data = original.asData()
        XCTAssertEqual(data.count, 4 * 4)  // 4 floats × 4 bytes each
        let decoded = try? EmbeddingVector(data: data)
        XCTAssertEqual(decoded?.values, original.values)
        XCTAssertEqual(decoded?.dim, 4)
    }

    func testRejectsMisalignedData() {
        let bytes = Data([0x00, 0x01, 0x02])  // 3 bytes — not a multiple of 4
        XCTAssertThrowsError(try EmbeddingVector(data: bytes))
    }

    func testDimReportsCount() {
        let v = EmbeddingVector(values: Array(repeating: Float(0.5), count: 768))
        XCTAssertEqual(v.dim, 768)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter EmbeddingVectorTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/EmbeddingVector.swift
import Foundation

public struct EmbeddingVector: Equatable, Hashable, Sendable {
    public let values: [Float]

    public var dim: Int { values.count }

    public init(values: [Float]) {
        self.values = values
    }

    public enum DecodeError: Error, Equatable {
        case misalignedByteCount(Int)
    }

    public init(data: Data) throws {
        guard data.count % MemoryLayout<Float>.size == 0 else {
            throw DecodeError.misalignedByteCount(data.count)
        }
        let count = data.count / MemoryLayout<Float>.size
        var arr = [Float](repeating: 0, count: count)
        _ = arr.withUnsafeMutableBytes { dst in
            data.copyBytes(to: dst)
        }
        self.values = arr
    }

    public func asData() -> Data {
        values.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter EmbeddingVectorTests 2>&1 | tail -10
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/EmbeddingVector.swift Tests/AINotebookCoreTests/EmbeddingVectorTests.swift
git commit -m "feat(core): EmbeddingVector with Data round-trip"
```

---

## Task 4: `NotebookStore+Embeddings` — embedding CRUD

**Files:** Create `Sources/AINotebookCore/NotebookStore+Embeddings.swift`, test `Tests/AINotebookCoreTests/NotebookStoreEmbeddingsTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/NotebookStoreEmbeddingsTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreEmbeddingsTests: XCTestCase {

    func testStoreAndLoadEmbedding() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "alpha", tokenCount: 1),
                ChunkDraft(text: "beta",  tokenCount: 1)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        let v1 = EmbeddingVector(values: [1, 0, 0, 0])
        let v2 = EmbeddingVector(values: [0, 1, 0, 0])
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: v1)
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: v2)

        let loaded = try store.embeddings(notebookId: nb.id!, model: "m")
        XCTAssertEqual(loaded.count, 2)
        let pairs = Dictionary(uniqueKeysWithValues: loaded.map { ($0.chunkId, $0.vector.values) })
        XCTAssertEqual(pairs[chunks[0].id!], v1.values)
        XCTAssertEqual(pairs[chunks[1].id!], v2.values)
    }

    func testUnembeddedChunksReturnsOnlyMissingForModel() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: (0..<3).map { ChunkDraft(text: "c\($0)", tokenCount: 1) }
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(
            chunkId: chunks[0].id!,
            model: "m",
            vector: EmbeddingVector(values: [0])
        )
        let pending = try store.unembeddedChunks(model: "m", limit: 100)
        let ids = Set(pending.map(\.id))
        XCTAssertEqual(ids, Set([chunks[1].id!, chunks[2].id!]))
    }

    func testReplaceEmbeddingOverwrites() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "a", tokenCount: 1)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.storeEmbedding(
            chunkId: chunk.id!,
            model: "m",
            vector: EmbeddingVector(values: [1, 0])
        )
        try store.storeEmbedding(
            chunkId: chunk.id!,
            model: "m",
            vector: EmbeddingVector(values: [0, 1])
        )
        let loaded = try store.embeddings(notebookId: nb.id!, model: "m")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].vector.values, [0, 1])
    }

    func testDeleteAllEmbeddingsForModelClearsOnlyThatModel() throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [ChunkDraft(text: "a", tokenCount: 1)]
        )
        let chunk = try store.chunks(sourceId: s.id!).first!
        try store.storeEmbedding(
            chunkId: chunk.id!, model: "m1", vector: EmbeddingVector(values: [1])
        )
        try store.deleteAllEmbeddings(model: "m1")
        XCTAssertEqual(try store.embeddings(notebookId: nb.id!, model: "m1").count, 0)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter NotebookStoreEmbeddingsTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/NotebookStore+Embeddings.swift
import Foundation
import GRDB

public struct StoredEmbedding: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let vector: EmbeddingVector
}

extension NotebookStore {

    public func storeEmbedding(
        chunkId: Int64,
        model: String,
        vector: EmbeddingVector
    ) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding)
                VALUES (?,?,?,?)
                ON CONFLICT(chunk_id) DO UPDATE SET
                  dim = excluded.dim,
                  model = excluded.model,
                  embedding = excluded.embedding
                """,
                arguments: [chunkId, vector.dim, model, vector.asData()]
            )
        }
    }

    /// All embeddings in a notebook for the given model.
    public func embeddings(notebookId: Int64, model: String) throws -> [StoredEmbedding] {
        try runOnDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT ce.chunk_id, sc.source_id, ce.embedding
                FROM chunk_embeddings ce
                JOIN source_chunks sc ON sc.id = ce.chunk_id
                JOIN sources s ON s.id = sc.source_id
                WHERE s.notebook_id = ? AND ce.model = ?
                """,
                arguments: [notebookId, model]
            )
            return try rows.map { row in
                let bytes: Data = row["embedding"]
                return StoredEmbedding(
                    chunkId: row["chunk_id"],
                    sourceId: row["source_id"],
                    vector: try EmbeddingVector(data: bytes)
                )
            }
        }
    }

    /// Chunks that do not yet have a row in `chunk_embeddings` for the given model.
    public func unembeddedChunks(model: String, limit: Int) throws -> [SourceChunk] {
        try runOnDatabase { db in
            try SourceChunk.fetchAll(
                db,
                sql: """
                SELECT sc.* FROM source_chunks sc
                LEFT JOIN chunk_embeddings ce
                  ON ce.chunk_id = sc.id AND ce.model = ?
                WHERE ce.chunk_id IS NULL
                ORDER BY sc.id ASC
                LIMIT ?
                """,
                arguments: [model, limit]
            )
        }
    }

    public func unembeddedCount(model: String) throws -> Int {
        try runOnDatabase { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT count(*) FROM source_chunks sc
                LEFT JOIN chunk_embeddings ce
                  ON ce.chunk_id = sc.id AND ce.model = ?
                WHERE ce.chunk_id IS NULL
                """,
                arguments: [model]
            ) ?? 0
        }
    }

    public func deleteAllEmbeddings(model: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "DELETE FROM chunk_embeddings WHERE model = ?",
                arguments: [model]
            )
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter NotebookStoreEmbeddingsTests 2>&1 | tail -10
```

Expected: 4/4 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/NotebookStore+Embeddings.swift Tests/AINotebookCoreTests/NotebookStoreEmbeddingsTests.swift
git commit -m "feat(core): embedding CRUD (store/load/unembedded/delete)"
```

---

## Task 5: `Cosine` via Accelerate vDSP

**Files:** Create `Sources/AINotebookCore/Cosine.swift`, test `Tests/AINotebookCoreTests/CosineTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/CosineTests.swift
import XCTest
@testable import AINotebookCore

final class CosineTests: XCTestCase {

    func testIdenticalVectorsScoreOne() {
        let a: [Float] = [0.1, 0.2, 0.3, 0.4]
        XCTAssertEqual(Cosine.similarity(a, a), 1.0, accuracy: 1e-5)
    }

    func testOrthogonalVectorsScoreZero() {
        let a: [Float] = [1, 0, 0, 0]
        let b: [Float] = [0, 1, 0, 0]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }

    func testOppositeVectorsScoreMinusOne() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        XCTAssertEqual(Cosine.similarity(a, b), -1.0, accuracy: 1e-5)
    }

    func testZeroMagnitudeReturnsZero() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }

    func testMismatchedDimensionsReturnsZero() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        XCTAssertEqual(Cosine.similarity(a, b), 0.0, accuracy: 1e-5)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter CosineTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/Cosine.swift
import Accelerate
import Foundation

public enum Cosine {

    /// Cosine similarity in [-1, 1]. Returns 0 when either input is zero-magnitude
    /// or the dimensions don't match.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var magA: Float = 0
        var magB: Float = 0
        vDSP_svesq(a, 1, &magA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &magB, vDSP_Length(b.count))
        let denom = sqrtf(magA) * sqrtf(magB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter CosineTests 2>&1 | tail -10
```

Expected: 5/5 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Cosine.swift Tests/AINotebookCoreTests/CosineTests.swift
git commit -m "feat(core): Cosine.similarity via Accelerate vDSP"
```

---

## Task 6: `Embedder` — batched chunk embedding

**Files:** Create `Sources/AINotebookCore/Embedder.swift`, test `Tests/AINotebookCoreTests/EmbedderTests.swift`

We test against a `MockEmbeddingClient` rather than the live `OllamaClient`. The protocol abstracts the network call.

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/EmbedderTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class EmbedderTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        var calls: [[String]] = []
        var dim: Int = 4
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            calls.append(inputs)
            return inputs.map { _ in (0..<self.dim).map { _ in Float.random(in: -1...1) } }
        }
    }

    func testEmbedAllInsertsRowsForEveryChunk() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: (0..<5).map { ChunkDraft(text: "c\($0)", tokenCount: 1) }
        )
        let client = MockEmbeddingClient()
        let embedder = Embedder(store: store, client: client, model: "m", batchSize: 2)
        let count = try await embedder.embedAllPending()
        XCTAssertEqual(count, 5)
        XCTAssertEqual(try store.unembeddedCount(model: "m"), 0)
        XCTAssertEqual(client.calls.count, 3, "should batch 2+2+1")
        XCTAssertEqual(client.calls.map(\.count), [2, 2, 1])
    }

    func testEmbedAllSkipsAlreadyEmbedded() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "a", tokenCount: 1),
                ChunkDraft(text: "b", tokenCount: 1)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(
            chunkId: chunks[0].id!, model: "m",
            vector: EmbeddingVector(values: [1, 0, 0, 0])
        )

        let client = MockEmbeddingClient()
        let embedder = Embedder(store: store, client: client, model: "m", batchSize: 10)
        let count = try await embedder.embedAllPending()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(client.calls.count, 1)
        XCTAssertEqual(client.calls[0], ["b"])
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter EmbedderTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement**

```swift
// Sources/AINotebookCore/Embedder.swift
import Foundation

/// Minimal protocol the embedder needs from the underlying client.
/// `OllamaClient` will conform to this in Task 7 via a tiny extension.
public protocol EmbeddingProducing: Sendable {
    func embed(model: String, inputs: [String]) async throws -> [[Float]]
}

public actor Embedder {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    public let model: String
    public let batchSize: Int

    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        batchSize: Int = 16
    ) {
        self.store = store
        self.client = client
        self.model = model
        self.batchSize = batchSize
    }

    /// Embeds every chunk that doesn't already have a row for `model`.
    /// Returns total rows written.
    @discardableResult
    public func embedAllPending() async throws -> Int {
        var written = 0
        while true {
            let batch = try await MainActor.run {
                try store.unembeddedChunks(model: model, limit: batchSize)
            }
            if batch.isEmpty { break }
            let inputs = batch.map(\.text)
            let vectors = try await client.embed(model: model, inputs: inputs)
            guard vectors.count == batch.count else {
                throw EmbedderError.responseSizeMismatch(expected: batch.count, got: vectors.count)
            }
            for (chunk, values) in zip(batch, vectors) {
                try await MainActor.run {
                    try store.storeEmbedding(
                        chunkId: chunk.id!,
                        model: model,
                        vector: EmbeddingVector(values: values)
                    )
                }
                written += 1
            }
        }
        return written
    }
}

public enum EmbedderError: Error, Equatable {
    case responseSizeMismatch(expected: Int, got: Int)
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter EmbedderTests 2>&1 | tail -10
```

Expected: 2/2 pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Embedder.swift Tests/AINotebookCoreTests/EmbedderTests.swift
git commit -m "feat(core): Embedder actor — batched embed of pending chunks"
```

---

## Task 7: Conform `OllamaClient` to `EmbeddingProducing`

**Files:** Modify `Sources/AINotebookCore/OllamaClient.swift` (or create a small extension file)

- [ ] **Step 1: Add the conformance**

Create `Sources/AINotebookCore/OllamaClient+EmbeddingProducing.swift`:

```swift
// Sources/AINotebookCore/OllamaClient+EmbeddingProducing.swift
import Foundation

extension OllamaClient: EmbeddingProducing {
    /// Wraps the M2 batched-embed call into the protocol's shape.
    /// `OllamaClient.embed(model:input:)` already accepts an array.
    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let response = try await embed(model: model, input: inputs)
        return response.embeddings
    }
}
```

If the actual `OllamaClient.embed` signature differs (e.g. returns `OllamaEmbedResponse` with a differently-named property), adapt the body. The semantic to preserve: take `(model, [String])`, return `[[Float]]` indexed identically to inputs.

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookCore/OllamaClient+EmbeddingProducing.swift
git commit -m "feat(core): OllamaClient conforms to EmbeddingProducing"
```

---

## Task 8: `RetrievalHit` + `Retriever` (hybrid RRF)

**Files:** Create `Sources/AINotebookCore/RetrievalHit.swift`, `Sources/AINotebookCore/Retriever.swift`, test `Tests/AINotebookCoreTests/RetrieverTests.swift`

- [ ] **Step 1: Write failing test**

```swift
// Tests/AINotebookCoreTests/RetrieverTests.swift
import XCTest
@testable import AINotebookCore

@MainActor
final class RetrieverTests: XCTestCase {

    final class MockEmbeddingClient: EmbeddingProducing, @unchecked Sendable {
        let queryVector: [Float]
        init(queryVector: [Float]) { self.queryVector = queryVector }
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            inputs.map { _ in queryVector }
        }
    }

    func testReturnsTopKByCosineSimilarity() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "alpha apple",   tokenCount: 2),
                ChunkDraft(text: "beta banana",   tokenCount: 2),
                ChunkDraft(text: "gamma grape",   tokenCount: 2)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        // 1st chunk vector aligned with query → highest cosine
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: EmbeddingVector(values: [0, 1]))
        try store.storeEmbedding(chunkId: chunks[2].id!, model: "m", vector: EmbeddingVector(values: [-1, 0]))

        let client = MockEmbeddingClient(queryVector: [1, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "doesn't matter — mock", topK: 2
        )
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].chunkId, chunks[0].id!, "highest-cosine chunk first")
    }

    func testFTSAloneSurfacesTextMatchWhenNoEmbedding() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                ChunkDraft(text: "the quick brown fox", tokenCount: 4),
                ChunkDraft(text: "lazy dog sleeps",     tokenCount: 3)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        // No embeddings stored — vector branch finds nothing, FTS branch finds "fox".
        let client = MockEmbeddingClient(queryVector: [0, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 5
        )
        let chunkIds = Set(hits.map(\.chunkId))
        XCTAssertTrue(chunkIds.contains(chunks[0].id!))
    }

    func testRRFRanksFusedAboveSingleSourceMatch() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let s = try store.createSource(
            notebookId: nb.id!, type: .text, title: "x", uri: nil, rawPath: nil
        )
        try store.replaceChunks(
            sourceId: s.id!,
            chunks: [
                // Chunk A: matches both vector AND text
                ChunkDraft(text: "fox runs fast",      tokenCount: 3),
                // Chunk B: matches text only
                ChunkDraft(text: "fox sleeps softly",  tokenCount: 3),
                // Chunk C: matches vector only
                ChunkDraft(text: "unrelated greeting", tokenCount: 2)
            ]
        )
        let chunks = try store.chunks(sourceId: s.id!)
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        try store.storeEmbedding(chunkId: chunks[2].id!, model: "m", vector: EmbeddingVector(values: [0.9, 0.1]))

        let client = MockEmbeddingClient(queryVector: [1, 0])
        let retriever = Retriever(store: store, client: client, model: "m")
        let hits = try await retriever.search(
            notebookId: nb.id!, query: "fox", topK: 3
        )
        XCTAssertEqual(hits.first?.chunkId, chunks[0].id!, "fused hit ranks above single-source hits")
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter RetrieverTests 2>&1 | tail -10
```

- [ ] **Step 3: Implement `RetrievalHit.swift`**

```swift
// Sources/AINotebookCore/RetrievalHit.swift
import Foundation

public struct RetrievalHit: Equatable, Sendable {
    public let chunkId: Int64
    public let sourceId: Int64
    public let score: Float
    public let snippet: String

    public init(chunkId: Int64, sourceId: Int64, score: Float, snippet: String) {
        self.chunkId = chunkId
        self.sourceId = sourceId
        self.score = score
        self.snippet = snippet
    }
}
```

- [ ] **Step 4: Implement `Retriever.swift`**

```swift
// Sources/AINotebookCore/Retriever.swift
import Foundation
import GRDB

public actor Retriever {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    public let model: String
    public let rrfK: Int

    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        rrfK: Int = 60
    ) {
        self.store = store
        self.client = client
        self.model = model
        self.rrfK = rrfK
    }

    /// Hybrid retrieval: cosine top-K on vectors + FTS5 BM25 top-K → RRF.
    public func search(
        notebookId: Int64,
        query: String,
        topK: Int = 8
    ) async throws -> [RetrievalHit] {
        // 1) Vector ranking — embed query, score against stored vectors.
        let queryVectors = try await client.embed(model: model, inputs: [query])
        let queryVector = queryVectors.first ?? []
        let allEmbeddings = try await MainActor.run {
            try store.embeddings(notebookId: notebookId, model: model)
        }
        let vectorRanked: [(chunkId: Int64, sourceId: Int64, score: Float)] =
            allEmbeddings
                .map { e in
                    (e.chunkId, e.sourceId, Cosine.similarity(queryVector, e.vector.values))
                }
                .sorted { $0.score > $1.score }
                .prefix(topK)
                .map { $0 }

        // 2) FTS ranking — BM25 top-K on chunks_fts within the notebook.
        let ftsRanked = try await MainActor.run {
            try Self.ftsTopK(store: store, notebookId: notebookId, query: query, k: topK)
        }

        // 3) Reciprocal Rank Fusion.
        var rrfScores: [Int64: Float] = [:]
        var meta: [Int64: (sourceId: Int64, snippet: String)] = [:]
        for (rank, hit) in vectorRanked.enumerated() {
            rrfScores[hit.chunkId, default: 0] += 1.0 / Float(rrfK + rank + 1)
            meta[hit.chunkId] = (hit.sourceId, "")
        }
        for (rank, hit) in ftsRanked.enumerated() {
            rrfScores[hit.chunkId, default: 0] += 1.0 / Float(rrfK + rank + 1)
            meta[hit.chunkId] = (hit.sourceId, hit.snippet)
        }

        // 4) Hydrate snippets for chunks that only came from the vector branch.
        let missingSnippets = meta.compactMap { (id, m) in m.snippet.isEmpty ? id : nil }
        if !missingSnippets.isEmpty {
            let snippets = try await MainActor.run {
                try Self.snippets(store: store, chunkIds: missingSnippets)
            }
            for (id, snippet) in snippets {
                meta[id] = (meta[id]?.sourceId ?? 0, snippet)
            }
        }

        return rrfScores
            .sorted { $0.value > $1.value }
            .prefix(topK)
            .compactMap { (id, score) in
                guard let m = meta[id] else { return nil }
                return RetrievalHit(chunkId: id, sourceId: m.sourceId, score: score, snippet: m.snippet)
            }
    }

    // MARK: - Internal SQL helpers

    private static func ftsTopK(
        store: NotebookStore,
        notebookId: Int64,
        query: String,
        k: Int
    ) throws -> [(chunkId: Int64, sourceId: Int64, snippet: String)] {
        try store.runOnDatabase { db in
            // FTS5 MATCH; bm25() returns ascending where lower=better, so we ORDER ASC.
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sc.id AS chunk_id, sc.source_id AS source_id, sc.text AS text
                FROM chunks_fts f
                JOIN source_chunks sc ON sc.id = f.chunk_id
                JOIN sources s ON s.id = sc.source_id
                WHERE f.text MATCH ? AND s.notebook_id = ?
                ORDER BY bm25(chunks_fts)
                LIMIT ?
                """,
                arguments: [Self.escapeFTS(query), notebookId, k]
            )
            return rows.map { r in
                let text: String = r["text"]
                return (
                    chunkId: r["chunk_id"],
                    sourceId: r["source_id"],
                    snippet: String(text.prefix(240))
                )
            }
        }
    }

    private static func snippets(
        store: NotebookStore,
        chunkIds: [Int64]
    ) throws -> [Int64: String] {
        guard !chunkIds.isEmpty else { return [:] }
        return try store.runOnDatabase { db in
            let placeholders = chunkIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, text FROM source_chunks WHERE id IN (\(placeholders))",
                arguments: StatementArguments(chunkIds.map { $0 as DatabaseValueConvertible })
            )
            var out: [Int64: String] = [:]
            for r in rows {
                let text: String = r["text"]
                out[r["id"]] = String(text.prefix(240))
            }
            return out
        }
    }

    /// Defensive escaping of double quotes for the FTS5 `MATCH` operator.
    /// We wrap the whole query in double quotes so it's treated as a phrase
    /// search and special characters can't break the parser.
    private static func escapeFTS(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter RetrieverTests 2>&1 | tail -10
```

Expected: 3/3 pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/Retriever.swift Sources/AINotebookCore/RetrievalHit.swift Tests/AINotebookCoreTests/RetrieverTests.swift
git commit -m "feat(core): Retriever — hybrid RRF over cosine + FTS5"
```

---

## Task 9: `EmbeddingWorker` background drain

**Files:** Create `Sources/AINotebookCore/EmbeddingWorker.swift`. Tested via integration through `Embedder` in Task 6; this task just wires the worker around it.

- [ ] **Step 1: Implement**

```swift
// Sources/AINotebookCore/EmbeddingWorker.swift
import Foundation

/// Long-running task that runs `Embedder.embedAllPending` whenever it's
/// kicked. `kick()` is idempotent: while a drain is in flight, additional
/// kicks set a "drain again when this finishes" flag.
public actor EmbeddingWorker {
    private let embedder: Embedder
    private var inFlight: Task<Void, Never>?
    private var pendingKick = false

    public private(set) var lastError: Error?
    public private(set) var totalEmbedded: Int = 0

    public init(embedder: Embedder) {
        self.embedder = embedder
    }

    public func kick() {
        if inFlight == nil {
            inFlight = Task { [weak self] in
                await self?.drain()
            }
        } else {
            pendingKick = true
        }
    }

    private func drain() async {
        repeat {
            pendingKick = false
            do {
                let n = try await embedder.embedAllPending()
                totalEmbedded += n
                lastError = nil
            } catch {
                lastError = error
            }
        } while pendingKick
        inFlight = nil
    }

    /// Test-only: wait until the current drain finishes (returns immediately
    /// if no drain is in flight).
    public func waitUntilIdle() async {
        if let task = inFlight {
            _ = await task.value
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookCore/EmbeddingWorker.swift
git commit -m "feat(core): EmbeddingWorker actor — debounced background drain"
```

---

## Task 10: `IngestionService` kicks the embedder after `replaceChunks`

**Files:** Modify `Sources/AINotebookCore/IngestionService.swift`

- [ ] **Step 1: Add an optional embedder hook**

In `Sources/AINotebookCore/IngestionService.swift`:

1. Add an optional property:
   ```swift
   private let onChunksWritten: (@Sendable () async -> Void)?
   ```
2. Extend `init` with a defaulted parameter:
   ```swift
   public init(
       store: NotebookStore,
       plain:  TextExtractor = PlainTextExtractor(),
       pdf:    TextExtractor = PDFExtractor(),
       web:    TextExtractor = WebExtractor(),
       office: TextExtractor = OfficeExtractor(),
       onChunksWritten: (@Sendable () async -> Void)? = nil
   ) {
       self.store = store
       self.plain = plain
       self.pdf = pdf
       self.web = web
       self.office = office
       self.onChunksWritten = onChunksWritten
   }
   ```
3. In `runPipeline`, after `try store.replaceChunks(...)` succeeds, call the hook:
   ```swift
   await onChunksWritten?()
   ```

This keeps Core decoupled from the App-level `EmbeddingWorker`; the app wires them together in Task 12.

- [ ] **Step 2: Verify existing tests still pass**

```bash
swift test --parallel 2>&1 | tail -5
```

Expected: previous count + new M4 tests, all pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookCore/IngestionService.swift
git commit -m "feat(core): IngestionService.onChunksWritten hook for embedder kick"
```

---

## Task 11: `AppSettings.embeddingModel` + 6 indexing-status localization keys

**Files:** Modify `Sources/AINotebookCore/AppSettings.swift`, modify `Sources/AINotebookCore/Localization.swift`, modify `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Read existing AppSettings + Localization shape**

```bash
sed -n '1,60p' Sources/AINotebookCore/AppSettings.swift
sed -n '1,80p' Sources/AINotebookCore/Localization.swift
```

- [ ] **Step 2: Add `embeddingModel` to AppSettings**

Add a `@Published` UserDefaults-persisted property mirroring how `language` or `chatModel` is persisted (whichever exists already). Default value: `"nomic-embed-text"`.

- [ ] **Step 3: Add 6 new localization keys**

| key | EN | CS |
|---|---|---|
| `indexingInProgress` | "Indexing %@…" | "Indexuji %@…" |
| `indexingProgressFormat` | "%d / %d chunks" | "%d / %d částí" |
| `indexingComplete` | "Indexed" | "Indexováno" |
| `indexingError` | "Indexing error" | "Chyba při indexaci" |
| `indexingPaused` | "Indexing paused" | "Indexace pozastavena" |
| `indexingIdle` | "Idle" | "Nečinné" |

Wire them through `AppText` exactly like the M3 source-UI keys (Task 14 of M3).

- [ ] **Step 4: Add a localization smoke test**

```swift
    func testIndexingCompleteIsBilingual() {
        XCTAssertEqual(AppText(language: .english).string(.indexingComplete), "Indexed")
        XCTAssertEqual(AppText(language: .czech)  .string(.indexingComplete), "Indexováno")
    }
```

- [ ] **Step 5: Build + test**

```bash
swift test --parallel 2>&1 | tail -5
```

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/AppSettings.swift Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): AppSettings.embeddingModel + 6 EN/CS indexing-status keys"
```

---

## Task 12: `EmbedderHolder` + wire worker into `AINotebookAppEntry`

**Files:** Create `Sources/AINotebookApp/EmbedderHolder.swift`, modify `Sources/AINotebookApp/AINotebookApp.swift`

- [ ] **Step 1: Implement holder**

```swift
// Sources/AINotebookApp/EmbedderHolder.swift
import SwiftUI
import AINotebookCore

@MainActor
final class EmbedderHolder: ObservableObject {
    let embedder: Embedder
    let worker: EmbeddingWorker
    init(embedder: Embedder, worker: EmbeddingWorker) {
        self.embedder = embedder
        self.worker = worker
    }
}
```

- [ ] **Step 2: Build holder + worker in the app entry**

In `Sources/AINotebookApp/AINotebookApp.swift`:

1. Add `@StateObject private var embedderHolder: EmbedderHolder`.
2. In `init()`, after `client` is constructed (the existing `OllamaClient`) and `store` exists:
   ```swift
   let embedder = Embedder(
       store: store,
       client: client,
       model: settings.embeddingModel
   )
   let worker = EmbeddingWorker(embedder: embedder)
   _embedderHolder = StateObject(wrappedValue: EmbedderHolder(embedder: embedder, worker: worker))
   ```
3. Construct `IngestionService` with the kick hook now:
   ```swift
   let ingestion = IngestionService(store: store, onChunksWritten: { [worker] in
       await worker.kick()
   })
   _ingestion = StateObject(wrappedValue: IngestionServiceHolder(service: ingestion))
   ```
4. Inject the holder in the scene body:
   ```swift
   .environmentObject(embedderHolder)
   ```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookApp/EmbedderHolder.swift Sources/AINotebookApp/AINotebookApp.swift
git commit -m "feat(app): wire Embedder + EmbeddingWorker + IngestionService kick"
```

---

## Task 13: `IndexingStatusBadge` in `SourceListView`

**Files:** Create `Sources/AINotebookApp/IndexingStatusBadge.swift`, modify `Sources/AINotebookApp/SourceListView.swift`

- [ ] **Step 1: Implement the badge**

```swift
// Sources/AINotebookApp/IndexingStatusBadge.swift
import SwiftUI
import AINotebookCore

struct IndexingStatusBadge: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var embedderHolder: EmbedderHolder

    @State private var pending: Int = 0
    @State private var poller: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if pending == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(settings.text.string(.indexingComplete))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(
                    String(
                        format: settings.text.string(.indexingInProgress),
                        "\(pending)"
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { startPoller() }
        .onDisappear { poller?.cancel() }
    }

    private func startPoller() {
        poller?.cancel()
        poller = Task { @MainActor in
            while !Task.isCancelled {
                pending = (try? store.unembeddedCount(model: settings.embeddingModel)) ?? 0
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 s
            }
        }
    }
}
```

- [ ] **Step 2: Show badge in `SourceListView`**

In `Sources/AINotebookApp/SourceListView.swift`, add `IndexingStatusBadge()` to the right of the section title's `HStack` (next to the `Add source` button):

```swift
HStack {
    Text(settings.text.string(.sourcesSectionTitle))
        .font(.title2).bold()
    Spacer()
    IndexingStatusBadge()
    Button(settings.text.string(.addSourceButton)) {
        showingAdd = true
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -10
```

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookApp/IndexingStatusBadge.swift Sources/AINotebookApp/SourceListView.swift
git commit -m "feat(app): IndexingStatusBadge in SourceListView"
```

---

## Task 14: Final verification + tag + merge

- [ ] **Step 1: Clean build + parallel test run**

```bash
swift package clean
swift build
swift test --parallel
```

Expected: build ok; **~111 tests** pass (95 M3 baseline + MigrationV3(3) + EmbeddingVector(3) + Embeddings(4) + Cosine(5) + Embedder(2) + Retriever(3) + Localization addition(1) — minor variance OK).

- [ ] **Step 2: Smoke test**

```bash
swift run AINotebookApp
```

Manually verify, assuming Ollama is running with `nomic-embed-text` pulled:
- Create a notebook, add a multi-paragraph text source.
- `IndexingStatusBadge` flips from "Indexing N…" to "Indexed" within seconds.
- Delete the source → badge goes back to "Indexed" (0 pending).

If Ollama or the embedding model isn't available, the badge stays at "Indexing N…" and `EmbeddingWorker.lastError` carries the failure — that's expected behaviour, not a bug.

- [ ] **Step 3: Tag**

```bash
git tag -a m4-embedding-tag -m "M4 embedding + hybrid retriever complete"
```

- [ ] **Step 4: Merge to main**

```bash
git checkout main
git merge --ff-only m4-embedding
git log --oneline | head -16
```

---

## Acceptance criteria (M4 done when ALL true)

- `swift build` succeeds.
- `swift test --parallel` ≈ 111 tests passing, 0 failures.
- `MigrationV3` adds `chunk_embeddings` (chunk_id PK, dim, model, embedding BLOB) with `ON DELETE CASCADE` from `source_chunks`.
- `EmbeddingVector` round-trips losslessly through `Data` (4 bytes / Float).
- `Cosine.similarity` matches expected values within 1e-5 for identical / orthogonal / opposite / mismatched vectors.
- `Embedder.embedAllPending` only embeds chunks missing for the current model and respects `batchSize`.
- `Retriever.search` returns RRF-fused hits, ranking chunks present in BOTH branches above single-branch matches.
- `EmbeddingWorker.kick` debounces concurrent calls and reports `lastError` on failure.
- `IngestionService.onChunksWritten` fires after every successful `replaceChunks` and kicks the worker in the live app.
- `IndexingStatusBadge` shows "Indexing N…" while pending > 0 and "Indexed" at 0.
- All 6 new EN/CS strings render in both languages.

---

## Notes for the implementer

- **Linear cosine performance:** At 10 000 chunks × 768 floats × 4 B = ~30 MB, a single query takes ~10 ms in vDSP. Plenty of headroom for v1. M8 / future work: drop in `sqlite-vec` when notebooks routinely hit 100 k+ chunks.
- **MainActor dance:** `NotebookStore` is `@MainActor`. The `Embedder` and `Retriever` actors hop to the main actor for store reads/writes via `MainActor.run`. Don't hold the main actor across `client.embed` — the inputs/vectors are plain values, so hop in, get the batch, hop out, await network, hop back, write rows.
- **FTS5 `MATCH` parser:** Special characters (quotes, parens, `AND`, `OR`, `NOT`) can break unescaped queries. `escapeFTS` wraps the whole query as a quoted phrase, which is safe but loses operator support. For v1 that's the right trade-off; phrase search is what users expect.
- **Dimension mismatch:** If a user switches embedding model and the new model emits a different dim, stored vectors with the old dim still load fine — `Cosine.similarity` returns 0 for mismatched lengths, so they harmlessly fall to the bottom. M7 polish will add a "re-embed all" affordance to clear and rebuild.
- **`OllamaClient.embed` exact shape:** Verify against the actual M2 implementation before writing the conformance in Task 7. If the response type is `OllamaEmbedResponse` with `embeddings: [[Float]]`, the conformance is the one-liner above. If it's `[Double]` instead of `[Float]`, map elements through `Float($0)` before returning.
