# macOS Provider Registry + OpenWebUI (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the full Epic A provider registry (Ollama + Anthropic + OpenAI + OpenAI-compatible + OpenWebUI) to the macOS app so a user can chat through cloud or network models — Windows parity per spec §5.

**Architecture:** Core already has the two seams every engine depends on (`ChatStreaming`, `EmbeddingProducing`). This plan adds: a `providers` table (migration v11, same schema/number as Windows), a `SecretStoring` protocol with Keychain + in-memory implementations, per-type adapters built on ONE shared OpenAI-shape SSE runner (Phase 1 review lesson: no duplicated parsers), and a `ProviderRouter` that implements both protocols and resolves the live *(provider, model)* selection on every call — no adapter cache, adapters are cheap value types. Engines keep their signatures; `Embedder`/`Retriever` gain a `modelKey` closure so the `chunk_embeddings` key `"{providerId}:{model}"` (FR-A11) is always current — this also fixes the pre-existing staleness bug where a model change only took effect after relaunch.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, GRDB 7, XCTest, URLSession (SSE via `bytes(for:).lines`), Security.framework (Keychain).

**Spec:** `docs/superpowers/specs/2026-07-08-openwebui-network-provider-design.md` §5–§8. Roadmap Epic A (`docs/roadmap.md`) FR-A1…FR-A12.

## Global Constraints

- Everything builds and tests **locally on this macOS box**: `swift build`, `swift test` (CI runs `swift test --parallel`). TDD with real RED/GREEN runs — fabricated command output in a report is a defect (one was caught in Phase 1).
- Migration id is exactly `"v11_providers"`, registered after `registerMigrationV10` in `NotebookStore.init` (`Sources/AINotebookCore/NotebookStore.swift`). `providers` schema matches Windows: id TEXT PK, type TEXT, name TEXT, base_url TEXT, enabled INTEGER default 1, privacy_acknowledged INTEGER default 0, created_at DATETIME.
- Storage strings exactly: `ollama | anthropic | openai | openai_compatible | openwebui`; unknown strings fall back to `openai_compatible` (Windows parity). Built-in Ollama provider id is `00000000-0000-0000-0000-000000000000`.
- Keychain: `kSecClassGenericPassword`, service `"AINotebook"`, account = provider id. API keys never in SQLite or UserDefaults; never logged; never echoed back into UI fields.
- CI gate: `.github/workflows/core-ci.yml` job `privacy-grep` forbids the string `URLSession` in `Sources/AINotebookCore/` outside `OllamaClient.swift` and `WebExtractor.swift`. All new networking lives in `Sources/AINotebookCore/Providers/` and the gate's allowlist gains `-e '/Providers/'` (Task 8). Files under `Providers/` that don't network (models, SSE parsing, selection) still must not import URLSession-adjacent APIs needlessly.
- Localization: every new UI string = one `case` in `AppText.Key` + one row in BOTH exhaustive switches `english(_:)` and `czech(_:)` in `Sources/AINotebookCore/Localization.swift` (missing either fails to compile).
- Endpoints: OpenAI/compatible `POST {base}/v1/chat/completions`, `POST {base}/v1/embeddings`, `GET {base}/v1/models`, Bearer optional. Anthropic `POST {base}/v1/messages` (headers `x-api-key`, `anthropic-version: 2023-06-01`, `max_tokens` 8192, top-level `system`), `GET {base}/v1/models`, fallback models `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`, `claude-fable-5`. OpenWebUI `POST {base}/api/chat/completions`, `GET {base}/api/models` (`data[].id` + `data[].name`), Bearer optional, chat-only, no root `/v1/*`.
- Error mapping (FR-A10): 401 → `ProviderError.auth`, 429 → `ProviderError.rateLimit(retryAfterSeconds:)` honoring `Retry-After`, other non-2xx → `ProviderError.http`, Anthropic `stop_reason: "refusal"` → `ProviderError.refusal`. `auth`/`refusal` are never retried by `ChatEngine`.
- Test connection must report network errors (Phase 1 lesson) — list-model calls in adapters THROW on failure; only `ProviderRouter.listModels` (picker path) converts failures to `[]` / Anthropic fallback list.
- No new SPM dependencies (Security is a system framework — no `Package.swift` change).
- Onboarding stays Ollama-first and untouched (FR-A12). `OnboardingViewModel` and `ModelManagementSheet` keep their concrete `OllamaClient`.
- Windows code (`windows/`) untouched.
- Commits: conventional prefixes, trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Branch `feat/provider-registry-macos` from `main`.

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/lukasoplt/Documents/AI_Notebook
git checkout main && git pull
git checkout -b feat/provider-registry-macos main
```

---

### Task 1: Provider model types (`ProviderType`, `ProviderConfig`, `ProviderModelInfo`, `ProviderError`)

**Files:**
- Create: `Sources/AINotebookCore/Providers/ProviderType.swift`
- Create: `Sources/AINotebookCore/Providers/ProviderConfig.swift`
- Create: `Sources/AINotebookCore/Providers/ProviderError.swift`
- Test: `Tests/AINotebookCoreTests/ProviderTypeTests.swift`

**Interfaces:**
- Consumes: nothing (pure value types).
- Produces (later tasks rely on these exact members): `ProviderType` enum (`.ollama/.anthropic/.openai/.openaiCompatible/.openwebui`, `rawValue` = storage string, `static fromStorage(_ raw: String) -> ProviderType`, `var defaultBaseURL: String`, `var supportsEmbeddings: Bool`, `var isCloud: Bool`); `ProviderConfig` struct (`id/type/name/baseURL/enabled/privacyAcknowledged/createdAt`, `static ollamaId`, `var isBuiltInOllama`, `static func builtInOllama() -> ProviderConfig`); `ProviderModelInfo` (`id`, `displayName`, `var label`); `ProviderError` enum (`.auth(String)`, `.rateLimit(retryAfterSeconds: Double?)`, `.http(code: Int, body: String)`, `.refusal`, `.decoding(String)`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/ProviderTypeTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class ProviderTypeTests: XCTestCase {

    func testStorageStringsRoundTrip() {
        XCTAssertEqual(ProviderType.ollama.rawValue, "ollama")
        XCTAssertEqual(ProviderType.anthropic.rawValue, "anthropic")
        XCTAssertEqual(ProviderType.openai.rawValue, "openai")
        XCTAssertEqual(ProviderType.openaiCompatible.rawValue, "openai_compatible")
        XCTAssertEqual(ProviderType.openwebui.rawValue, "openwebui")
        for t in ProviderType.allCases {
            XCTAssertEqual(ProviderType.fromStorage(t.rawValue), t)
        }
    }

    func testUnknownStorageStringFallsBackToOpenAICompatible() {
        XCTAssertEqual(ProviderType.fromStorage("something_new"), .openaiCompatible)
    }

    func testDefaultBaseURLs() {
        XCTAssertEqual(ProviderType.ollama.defaultBaseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(ProviderType.anthropic.defaultBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(ProviderType.openai.defaultBaseURL, "https://api.openai.com")
        XCTAssertEqual(ProviderType.openaiCompatible.defaultBaseURL, "")
        XCTAssertEqual(ProviderType.openwebui.defaultBaseURL, "")
    }

    func testEmbeddingSupport() {
        XCTAssertTrue(ProviderType.ollama.supportsEmbeddings)
        XCTAssertTrue(ProviderType.openai.supportsEmbeddings)
        XCTAssertTrue(ProviderType.openaiCompatible.supportsEmbeddings)
        XCTAssertFalse(ProviderType.anthropic.supportsEmbeddings)
        XCTAssertFalse(ProviderType.openwebui.supportsEmbeddings)
    }

    func testCloudFlagCoversEverythingButOllama() {
        XCTAssertFalse(ProviderType.ollama.isCloud)
        for t in ProviderType.allCases where t != .ollama {
            XCTAssertTrue(t.isCloud, "\(t) must be privacy-gated")
        }
    }

    func testBuiltInOllamaConfig() {
        let cfg = ProviderConfig.builtInOllama()
        XCTAssertEqual(cfg.id, ProviderConfig.ollamaId)
        XCTAssertEqual(ProviderConfig.ollamaId, "00000000-0000-0000-0000-000000000000")
        XCTAssertTrue(cfg.isBuiltInOllama)
        XCTAssertEqual(cfg.type, .ollama)
        XCTAssertTrue(cfg.privacyAcknowledged)
    }

    func testModelInfoLabelFallsBackToId() {
        XCTAssertEqual(ProviderModelInfo(id: "gpt-4o").label, "gpt-4o")
        XCTAssertEqual(ProviderModelInfo(id: "x", displayName: "Nice Name").label, "Nice Name")
        XCTAssertEqual(ProviderModelInfo(id: "x", displayName: "").label, "x")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProviderTypeTests`
Expected: FAIL — compile error `cannot find 'ProviderType' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/Providers/ProviderType.swift`:

```swift
import Foundation

/// Provider registry types. Storage strings match the Windows port exactly
/// (`windows/src/AINotebook.Core/Providers/ProviderType.cs`).
public enum ProviderType: String, CaseIterable, Sendable {
    case ollama
    case anthropic
    case openai
    case openaiCompatible = "openai_compatible"
    case openwebui

    /// Unknown storage strings fall back to `.openaiCompatible` (Windows parity).
    public static func fromStorage(_ raw: String) -> ProviderType {
        ProviderType(rawValue: raw) ?? .openaiCompatible
    }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: "http://127.0.0.1:11434"
        case .anthropic: "https://api.anthropic.com"
        case .openai: "https://api.openai.com"
        case .openaiCompatible, .openwebui: ""
        }
    }

    /// Anthropic has no embeddings API; OpenWebUI is chat-only by design.
    public var supportsEmbeddings: Bool {
        switch self {
        case .anthropic, .openwebui: false
        case .ollama, .openai, .openaiCompatible: true
        }
    }

    /// True when requests leave this machine — the privacy gate applies.
    public var isCloud: Bool { self != .ollama }
}
```

Create `Sources/AINotebookCore/Providers/ProviderConfig.swift`:

```swift
import Foundation

public struct ProviderConfig: Equatable, Sendable, Identifiable {
    /// Well-known id of the built-in Ollama provider — never deleted.
    /// Same GUID as the Windows port.
    public static let ollamaId = "00000000-0000-0000-0000-000000000000"

    public let id: String
    public var type: ProviderType
    public var name: String
    public var baseURL: String
    public var enabled: Bool
    public var privacyAcknowledged: Bool
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        type: ProviderType,
        name: String,
        baseURL: String,
        enabled: Bool = true,
        privacyAcknowledged: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.baseURL = baseURL
        self.enabled = enabled
        self.privacyAcknowledged = privacyAcknowledged
        self.createdAt = createdAt
    }

    public var isBuiltInOllama: Bool { id == Self.ollamaId }

    /// In-memory fallback used when the DB row is unexpectedly missing.
    public static func builtInOllama() -> ProviderConfig {
        ProviderConfig(
            id: ollamaId,
            type: .ollama,
            name: "Ollama (local)",
            baseURL: ProviderType.ollama.defaultBaseURL,
            enabled: true,
            privacyAcknowledged: true
        )
    }
}

public struct ProviderModelInfo: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }

    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        return id
    }
}
```

Create `Sources/AINotebookCore/Providers/ProviderError.swift`:

```swift
import Foundation

/// Wire-level provider failures, mapped per FR-A10.
/// `auth` and `refusal` are terminal — `ChatEngine` must not retry them.
public enum ProviderError: Error, Equatable, Sendable {
    case auth(String)
    case rateLimit(retryAfterSeconds: Double?)
    case http(code: Int, body: String)
    case refusal
    case decoding(String)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProviderTypeTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Providers/ProviderType.swift \
        Sources/AINotebookCore/Providers/ProviderConfig.swift \
        Sources/AINotebookCore/Providers/ProviderError.swift \
        Tests/AINotebookCoreTests/ProviderTypeTests.swift
git commit -m "feat(mac): provider registry model types (ollama/anthropic/openai/compatible/openwebui)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Migration v11 + `NotebookStore+Providers` CRUD

**Files:**
- Create: `Sources/AINotebookCore/MigrationV11.swift`
- Create: `Sources/AINotebookCore/NotebookStore+Providers.swift`
- Modify: `Sources/AINotebookCore/NotebookStore.swift` (register v11 after the `registerMigrationV10(on: &migrator)` line)
- Modify: `Sources/AINotebookCore/StoreError.swift` (one new case — read the file first and mirror its existing case style)
- Test: `Tests/AINotebookCoreTests/MigrationV11Tests.swift`
- Test: `Tests/AINotebookCoreTests/NotebookStoreProvidersTests.swift`

**Interfaces:**
- Consumes: `ProviderType`, `ProviderConfig` (Task 1); GRDB `DatabaseMigrator` pattern (`registerMigrationV11(on:)` free function, id `"v11_providers"`); `NotebookStore.runOnDatabase(_:)`.
- Produces: `extension NotebookStore` methods — `providers() throws -> [ProviderConfig]`, `provider(id: String) throws -> ProviderConfig?`, `saveProvider(_ config: ProviderConfig) throws` (upsert; does NOT overwrite `privacy_acknowledged` on update), `deleteProvider(id: String) throws` (throws `StoreError.builtInProviderUndeletable` for the Ollama row), `acknowledgePrivacy(providerId: String) throws`. Migration rewrites existing `chunk_embeddings.model` values to `"{ollamaId}:{model}"`.

- [ ] **Step 1: Write the failing migration tests**

Create `Tests/AINotebookCoreTests/MigrationV11Tests.swift`:

```swift
import XCTest
import GRDB
@testable import AINotebookCore

@MainActor
final class MigrationV11Tests: XCTestCase {

    func testV11CreatesProvidersTable() throws {
        let store = try NotebookStore(path: .inMemory)
        try store.runOnDatabase { db in
            let cols: [Row] = try Row.fetchAll(db, sql: "PRAGMA table_info('providers')")
            let names = cols.compactMap { $0["name"] as String? }
            XCTAssertEqual(
                Set(names),
                ["id", "type", "name", "base_url", "enabled", "privacy_acknowledged", "created_at"],
                "got: \(names)"
            )
        }
    }

    func testV11SeedsBuiltInOllamaRow() throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = try XCTUnwrap(try store.provider(id: ProviderConfig.ollamaId))
        XCTAssertEqual(cfg.type, .ollama)
        XCTAssertEqual(cfg.baseURL, "http://127.0.0.1:11434")
        XCTAssertTrue(cfg.enabled)
        XCTAssertTrue(cfg.privacyAcknowledged)
    }

    /// Build a v10 database by hand, plant a legacy embedding row, then run
    /// v11 and assert the key was requalified to "{ollamaId}:{model}".
    func testV11RequalifiesExistingEmbeddingKeys() throws {
        let q = try DatabaseQueue()
        var m = DatabaseMigrator()
        registerMigrationV1(on: &m)
        registerMigrationV2(on: &m)
        registerMigrationV3(on: &m)
        registerMigrationV4(on: &m)
        registerMigrationV5(on: &m)
        registerMigrationV6(on: &m)
        registerMigrationV7(on: &m)
        registerMigrationV8(on: &m)
        registerMigrationV9(on: &m)
        registerMigrationV10(on: &m)
        try m.migrate(q)

        try q.write { db in
            // FK-safe direct insert: disable FK checks for this connection so
            // we don't have to construct notebook/source/chunk parent rows.
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (1, 2, 'nomic-embed-text', x'00000000')"
            )
        }

        registerMigrationV11(on: &m)
        try m.migrate(q)

        try q.read { db in
            let model = try XCTUnwrap(String.fetchOne(db, sql: "SELECT model FROM chunk_embeddings WHERE chunk_id = 1"))
            XCTAssertEqual(model, "\(ProviderConfig.ollamaId):nomic-embed-text")
        }
    }

    func testV11DoesNotDoubleQualifyAlreadyQualifiedKeys() throws {
        let q = try DatabaseQueue()
        var m = DatabaseMigrator()
        registerMigrationV1(on: &m)
        registerMigrationV2(on: &m)
        registerMigrationV3(on: &m)
        registerMigrationV4(on: &m)
        registerMigrationV5(on: &m)
        registerMigrationV6(on: &m)
        registerMigrationV7(on: &m)
        registerMigrationV8(on: &m)
        registerMigrationV9(on: &m)
        registerMigrationV10(on: &m)
        try m.migrate(q)
        try q.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(
                sql: "INSERT INTO chunk_embeddings(chunk_id, dim, model, embedding) VALUES (1, 2, 'abc:nomic', x'00000000')"
            )
        }
        registerMigrationV11(on: &m)
        try m.migrate(q)
        try q.read { db in
            let model = try XCTUnwrap(String.fetchOne(db, sql: "SELECT model FROM chunk_embeddings WHERE chunk_id = 1"))
            XCTAssertEqual(model, "abc:nomic", "already-qualified keys must not be rewritten")
        }
    }
}
```

Adjustment rule: if `PRAGMA foreign_keys = OFF` inside `q.write` still leaves FK enforcement on (GRDB may manage the pragma), replace the direct insert with minimal parent rows — read `MigrationV2.swift`/`MigrationV3.swift` for the actual `source_chunks` columns and insert a notebook → source → chunk chain first. Document whichever path you used.

- [ ] **Step 2: Write the failing CRUD tests**

Create `Tests/AINotebookCoreTests/NotebookStoreProvidersTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

@MainActor
final class NotebookStoreProvidersTests: XCTestCase {

    private func makeStore() throws -> NotebookStore {
        try NotebookStore(path: .inMemory)
    }

    func testSaveAndFetchRoundTrips() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(
            type: .openwebui, name: "LAN server", baseURL: "http://192.168.1.50:3000"
        )
        try store.saveProvider(cfg)
        let loaded = try XCTUnwrap(try store.provider(id: cfg.id))
        XCTAssertEqual(loaded.type, .openwebui)
        XCTAssertEqual(loaded.name, "LAN server")
        XCTAssertEqual(loaded.baseURL, "http://192.168.1.50:3000")
        XCTAssertTrue(loaded.enabled)
        XCTAssertFalse(loaded.privacyAcknowledged)
    }

    func testProvidersListsSeedPlusSavedOrderedByCreation() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(type: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com")
        try store.saveProvider(cfg)
        let all = try store.providers()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.id, ProviderConfig.ollamaId)
        XCTAssertEqual(all.last?.id, cfg.id)
    }

    func testUpdatePreservesPrivacyAcknowledgement() throws {
        let store = try makeStore()
        var cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        try store.saveProvider(cfg)
        try store.acknowledgePrivacy(providerId: cfg.id)
        cfg.name = "OpenAI renamed"
        try store.saveProvider(cfg)   // cfg still carries privacyAcknowledged == false
        let loaded = try XCTUnwrap(try store.provider(id: cfg.id))
        XCTAssertEqual(loaded.name, "OpenAI renamed")
        XCTAssertTrue(loaded.privacyAcknowledged, "edit must not reset the consent flag")
    }

    func testDeleteRefusesBuiltInOllama() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.deleteProvider(id: ProviderConfig.ollamaId))
        XCTAssertNotNil(try store.provider(id: ProviderConfig.ollamaId))
    }

    func testDeleteRemovesRow() throws {
        let store = try makeStore()
        let cfg = ProviderConfig(type: .openwebui, name: "X", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        try store.deleteProvider(id: cfg.id)
        XCTAssertNil(try store.provider(id: cfg.id))
    }

    func testUnknownTypeStringLoadsAsOpenAICompatible() throws {
        let store = try makeStore()
        try store.runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES ('future-id', 'grok', 'Future', 'https://x', 1, 0, datetime('now'))
                """
            )
        }
        let loaded = try XCTUnwrap(try store.provider(id: "future-id"))
        XCTAssertEqual(loaded.type, .openaiCompatible)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter 'MigrationV11Tests|NotebookStoreProvidersTests'`
Expected: FAIL — `cannot find 'registerMigrationV11' in scope` etc.

- [ ] **Step 4: Implement**

Create `Sources/AINotebookCore/MigrationV11.swift`:

```swift
import GRDB

/// Schema v11 — provider registry. Creates `providers`, seeds the built-in
/// Ollama row, and requalifies `chunk_embeddings.model` to the fully
/// qualified "{providerId}:{model}" key (FR-A11) so same-named models under
/// different providers can never return each other's vectors.
public func registerMigrationV11(on migrator: inout DatabaseMigrator) {
    migrator.registerMigration("v11_providers") { db in
        try db.create(table: "providers") { t in
            t.column("id", .text).primaryKey()
            t.column("type", .text).notNull()
            t.column("name", .text).notNull()
            t.column("base_url", .text).notNull()
            t.column("enabled", .integer).notNull().defaults(to: 1)
            t.column("privacy_acknowledged", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
        }
        try db.execute(
            sql: """
            INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
            VALUES (?, 'ollama', 'Ollama (local)', 'http://127.0.0.1:11434', 1, 1, datetime('now'))
            """,
            arguments: [ProviderConfig.ollamaId]
        )
        try db.execute(
            sql: """
            UPDATE chunk_embeddings
            SET model = ? || ':' || model
            WHERE model NOT LIKE '%:%'
            """,
            arguments: [ProviderConfig.ollamaId]
        )
    }
}
```

Create `Sources/AINotebookCore/NotebookStore+Providers.swift`:

```swift
import Foundation
import GRDB

extension NotebookStore {

    public func providers() throws -> [ProviderConfig] {
        try runOnDatabase { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at
                FROM providers ORDER BY created_at, id
                """
            )
            return rows.map(Self.providerConfig(from:))
        }
    }

    public func provider(id: String) throws -> ProviderConfig? {
        try runOnDatabase { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT id, type, name, base_url, enabled, privacy_acknowledged, created_at
                FROM providers WHERE id = ?
                """,
                arguments: [id]
            ).map(Self.providerConfig(from:))
        }
    }

    /// Upsert. On update, `privacy_acknowledged` is intentionally NOT
    /// overwritten — consent is granted once via `acknowledgePrivacy` and an
    /// edit must not reset it.
    public func saveProvider(_ config: ProviderConfig) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: """
                INSERT INTO providers(id, type, name, base_url, enabled, privacy_acknowledged, created_at)
                VALUES (?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                  type = excluded.type,
                  name = excluded.name,
                  base_url = excluded.base_url,
                  enabled = excluded.enabled
                """,
                arguments: [
                    config.id, config.type.rawValue, config.name, config.baseURL,
                    config.enabled, config.privacyAcknowledged, config.createdAt
                ]
            )
        }
    }

    public func deleteProvider(id: String) throws {
        guard id != ProviderConfig.ollamaId else {
            throw StoreError.builtInProviderUndeletable
        }
        try runOnDatabase { db in
            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id])
        }
    }

    public func acknowledgePrivacy(providerId: String) throws {
        try runOnDatabase { db in
            try db.execute(
                sql: "UPDATE providers SET privacy_acknowledged = 1 WHERE id = ?",
                arguments: [providerId]
            )
        }
    }

    private static func providerConfig(from row: Row) -> ProviderConfig {
        ProviderConfig(
            id: row["id"],
            type: ProviderType.fromStorage(row["type"]),
            name: row["name"],
            baseURL: row["base_url"],
            enabled: (row["enabled"] as Int64? ?? 0) != 0,
            privacyAcknowledged: (row["privacy_acknowledged"] as Int64? ?? 0) != 0,
            createdAt: row["created_at"]
        )
    }
}
```

In `Sources/AINotebookCore/NotebookStore.swift`, after `registerMigrationV10(on: &migrator)` add:

```swift
        registerMigrationV11(on: &migrator)
```

In `Sources/AINotebookCore/StoreError.swift`, add a case following the file's existing style (read it first), e.g.:

```swift
    case builtInProviderUndeletable
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter 'MigrationV11Tests|NotebookStoreProvidersTests'`
Expected: PASS (10 tests).

- [ ] **Step 6: Run the full suite (migration touches shared schema)**

Run: `swift test`
Expected: all green — existing embedding tests must still pass (they use fixed model strings via the store; the composite-key rewrite only runs on rows existing at migration time, and fresh in-memory stores start empty).

- [ ] **Step 7: Commit**

```bash
git add Sources/AINotebookCore/MigrationV11.swift \
        Sources/AINotebookCore/NotebookStore+Providers.swift \
        Sources/AINotebookCore/NotebookStore.swift \
        Sources/AINotebookCore/StoreError.swift \
        Tests/AINotebookCoreTests/MigrationV11Tests.swift \
        Tests/AINotebookCoreTests/NotebookStoreProvidersTests.swift
git commit -m "feat(mac): providers table (migration v11) + NotebookStore provider CRUD

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `SecretStoring` — Keychain + in-memory secret stores

**Files:**
- Create: `Sources/AINotebookCore/Providers/SecretStore.swift`
- Test: `Tests/AINotebookCoreTests/SecretStoreTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public protocol SecretStoring: Sendable { func save(providerId: String, secret: String) throws; func load(providerId: String) throws -> String?; func delete(providerId: String) throws }`; `InMemorySecretStore` (thread-safe, for tests); `KeychainSecretStore(service: String = "AINotebook")`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/SecretStoreTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class SecretStoreTests: XCTestCase {

    func testInMemoryRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "sk-abc")
        XCTAssertEqual(try store.load(providerId: "p1"), "sk-abc")
    }

    func testInMemoryOverwrite() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "old")
        try store.save(providerId: "p1", secret: "new")
        XCTAssertEqual(try store.load(providerId: "p1"), "new")
    }

    func testInMemoryMissingIsNil() throws {
        XCTAssertNil(try InMemorySecretStore().load(providerId: "nope"))
    }

    func testInMemoryDelete() throws {
        let store = InMemorySecretStore()
        try store.save(providerId: "p1", secret: "x")
        try store.delete(providerId: "p1")
        XCTAssertNil(try store.load(providerId: "p1"))
    }

    func testInMemoryDeleteMissingDoesNotThrow() {
        XCTAssertNoThrow(try InMemorySecretStore().delete(providerId: "nope"))
    }
}
```

Note: `KeychainSecretStore` gets NO unit test — the CI runner's headless login keychain is unreliable and a failure there would be environmental, not logical. It is a thin `SecItem*` wrapper verified by compilation plus the manual acceptance checklist in Task 13 (key survives app restart). State this in your report; do not invent a Keychain test run.

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SecretStoreTests`
Expected: FAIL — `cannot find 'InMemorySecretStore' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/Providers/SecretStore.swift`:

```swift
import Foundation
import Security

/// Where provider API keys live. Keychain in production, in-memory in tests.
/// Keys are NEVER stored in SQLite or UserDefaults (FR-A7).
public protocol SecretStoring: Sendable {
    func save(providerId: String, secret: String) throws
    func load(providerId: String) throws -> String?
    func delete(providerId: String) throws
}

public enum SecretStoreError: Error, Equatable {
    case osStatus(OSStatus)
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(providerId: String, secret: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[providerId] = secret
    }

    public func load(providerId: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[providerId]
    }

    public func delete(providerId: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[providerId] = nil
    }
}

/// macOS Keychain implementation: `kSecClassGenericPassword`,
/// service "AINotebook", account = provider id (FR-A7).
public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "AINotebook") {
        self.service = service
    }

    private func baseQuery(providerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId
        ]
    }

    public func save(providerId: String, secret: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(providerId: providerId)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw SecretStoreError.osStatus(addStatus) }
        } else {
            guard status == errSecSuccess else { throw SecretStoreError.osStatus(status) }
        }
    }

    public func load(providerId: String) throws -> String? {
        var query = baseQuery(providerId: providerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SecretStoreError.osStatus(status)
        }
        return String(data: data, encoding: .utf8)
    }

    public func delete(providerId: String) throws {
        let status = SecItemDelete(baseQuery(providerId: providerId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretStoreError.osStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SecretStoreTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Providers/SecretStore.swift \
        Tests/AINotebookCoreTests/SecretStoreTests.swift
git commit -m "feat(mac): SecretStoring protocol with Keychain and in-memory stores

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Shared SSE parsing (`SSE`, wire structs)

**Files:**
- Create: `Sources/AINotebookCore/Providers/SSE.swift`
- Test: `Tests/AINotebookCoreTests/SSETests.swift`

**Interfaces:**
- Consumes: nothing (pure functions — deliberately no URLSession here).
- Produces: `SSE.dataPayload(of line: String) -> String?`, `SSE.done` (== `"[DONE]"`), `SSE.openAITokens(inPayload:) -> [String]`, `SSE.anthropicEvent(inPayload:) -> AnthropicStreamEvent?`; `enum AnthropicStreamEvent { case textDelta(String), stopReason(String), messageStop, other }`. Tasks 5–7 build every adapter's parsing on these — Phase 1's review flagged the Windows adapters for duplicating the SSE parser; on macOS there is exactly one.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/SSETests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class SSETests: XCTestCase {

    // ── data-line framing ────────────────────────────────────────────────

    func testDataPayloadExtractsPayload() {
        XCTAssertEqual(SSE.dataPayload(of: #"data: {"x":1}"#), #"{"x":1}"#)
    }

    func testNonDataLinesAreNil() {
        XCTAssertNil(SSE.dataPayload(of: "event: ping"))
        XCTAssertNil(SSE.dataPayload(of: ""))
        XCTAssertNil(SSE.dataPayload(of: ": comment"))
    }

    func testDoneSentinel() {
        XCTAssertEqual(SSE.dataPayload(of: "data: [DONE]"), SSE.done)
    }

    // ── OpenAI shape ─────────────────────────────────────────────────────

    func testOpenAITokensFromDelta() {
        let payload = #"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#
        XCTAssertEqual(SSE.openAITokens(inPayload: payload), ["Hello"])
    }

    func testOpenAITokensMultipleChoices() {
        let payload = #"{"choices":[{"delta":{"content":"A"},"index":0},{"delta":{"content":"B"},"index":1}]}"#
        XCTAssertEqual(SSE.openAITokens(inPayload: payload), ["A", "B"])
    }

    func testOpenAITokensSkipsEmptyAndMissingContent() {
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[{"delta":{"content":""},"index":0}]}"#), [])
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[{"delta":{},"index":0}]}"#), [])
        XCTAssertEqual(SSE.openAITokens(inPayload: #"{"choices":[]}"#), [])
    }

    func testOpenAITokensMalformedJSONIsEmpty() {
        XCTAssertEqual(SSE.openAITokens(inPayload: "not-json"), [])
    }

    // ── Anthropic shape ──────────────────────────────────────────────────

    func testAnthropicTextDelta() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#
        XCTAssertEqual(SSE.anthropicEvent(inPayload: payload), .textDelta("Hi"))
    }

    func testAnthropicStopReason() {
        let payload = #"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":1}}"#
        XCTAssertEqual(SSE.anthropicEvent(inPayload: payload), .stopReason("refusal"))
    }

    func testAnthropicMessageStop() {
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"message_stop"}"#), .messageStop)
    }

    func testAnthropicPingAndUnknownAreOther() {
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"ping"}"#), .other)
        XCTAssertEqual(SSE.anthropicEvent(inPayload: #"{"type":"content_block_start","content_block":{}}"#), .other)
    }

    func testAnthropicMalformedIsNil() {
        XCTAssertNil(SSE.anthropicEvent(inPayload: "not-json"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SSETests`
Expected: FAIL — `cannot find 'SSE' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/Providers/SSE.swift`:

```swift
import Foundation

/// Shared Server-Sent-Events parsing for the OpenAI-shape (OpenAI, LM Studio,
/// OpenRouter, vLLM, OpenWebUI) and Anthropic streaming APIs. Pure functions —
/// no networking in this file (the CI grep gate keeps URLSession confined).
public enum SSE {
    public static let done = "[DONE]"

    /// Payload of a `data: `-prefixed SSE line; nil for any other line.
    public static func dataPayload(of line: String) -> String? {
        guard line.hasPrefix("data: ") else { return nil }
        return String(line.dropFirst("data: ".count))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Tokens in one OpenAI-shape chunk (`choices[].delta.content`).
    /// Malformed JSON → empty array; the caller just skips the line.
    public static func openAITokens(inPayload payload: String) -> [String] {
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(OpenAIStreamChunk.self, from: data),
              let choices = chunk.choices
        else { return [] }
        return choices.compactMap { $0.delta?.content }.filter { !$0.isEmpty }
    }

    /// One parsed Anthropic stream event; nil when the payload is not JSON.
    public static func anthropicEvent(inPayload payload: String) -> AnthropicStreamEvent? {
        guard let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode(AnthropicRawEvent.self, from: data)
        else { return nil }
        switch raw.type {
        case "content_block_delta":
            if raw.delta?.type == "text_delta", let text = raw.delta?.text {
                return .textDelta(text)
            }
            return .other
        case "message_delta":
            if let stop = raw.delta?.stopReason { return .stopReason(stop) }
            return .other
        case "message_stop":
            return .messageStop
        default:
            return .other
        }
    }
}

public enum AnthropicStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case stopReason(String)
    case messageStop
    case other
}

struct OpenAIStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
    }
    let choices: [Choice]?
}

struct AnthropicRawEvent: Decodable {
    struct Delta: Decodable {
        let type: String?
        let text: String?
        let stopReason: String?
        enum CodingKeys: String, CodingKey {
            case type, text
            case stopReason = "stop_reason"
        }
    }
    let type: String
    let delta: Delta?
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SSETests`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Providers/SSE.swift \
        Tests/AINotebookCoreTests/SSETests.swift
git commit -m "feat(mac): shared SSE parsing for OpenAI-shape and Anthropic streams

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: OpenAI adapters (chat + embeddings + model listing) and the mock HTTP test harness

**Files:**
- Create: `Sources/AINotebookCore/Providers/ProviderWire.swift`
- Create: `Sources/AINotebookCore/Providers/OpenAIAdapters.swift`
- Create: `Tests/AINotebookCoreTests/MockURLProtocol.swift` (test-target helper, reused by Tasks 6–8)
- Test: `Tests/AINotebookCoreTests/OpenAIAdapterTests.swift`

**Interfaces:**
- Consumes: `ChatStreaming` (`Sources/AINotebookCore/ChatEngine.swift:12` — `func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error>`), `EmbeddingProducing` (`Embedder.swift:5` — `func embed(model: String, inputs: [String]) async throws -> [[Float]]`), `ChatTurn`/`ChatRole`, `ProviderError`, `ProviderModelInfo`, `SSE` (Task 4). Read `Sources/AINotebookCore/ChatMessage.swift` first to mirror the real `ChatRole` case names (expected `.system/.user/.assistant`) — adjust `ProviderWire.wireRole` if they differ and document it.
- Produces (Tasks 6–8 rely on these exact symbols):
  - `ProviderWire.trimBase(_ baseURL: String) -> String` (strips trailing `/`)
  - `ProviderWire.url(base: String, path: String) throws -> URL` (throws `ProviderError.decoding` on invalid/empty base)
  - `ProviderWire.wireRole(_ role: ChatRole) -> String`
  - `ProviderWire.error(forStatus code: Int, retryAfter: String?, body: String) -> ProviderError?` (nil for 2xx)
  - `ProviderWire.openAIStyleChatRequest(base: String, path: String, apiKey: String?, model: String, messages: [ChatTurn]) throws -> URLRequest`
  - `ProviderWire.openAIStyleStream(request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error>` — the ONE OpenAI-shape SSE runner
  - `ProviderWire.listOpenAIStyleModels(base: String, path: String, apiKey: String?, session: URLSession) async throws -> [ProviderModelInfo]` (decodes `data[].id` + optional `data[].name` → displayName; sorted by `label` case-insensitively; THROWS on any failure incl. 401 → `ProviderError.auth`)
  - `struct OpenAIChatAdapter: ChatStreaming` — `init(baseURL: String, apiKey: String?, session: URLSession = .shared)`, `static func listModels(baseURL: String, apiKey: String?, session: URLSession) async throws -> [ProviderModelInfo]`
  - `struct OpenAIEmbeddingAdapter: EmbeddingProducing` — same init shape
  - Test helper: `MockURLProtocol` + `makeMockSession()` + `URLRequest.bodyData`

- [ ] **Step 1: Write the mock HTTP harness (test target)**

Create `Tests/AINotebookCoreTests/MockURLProtocol.swift`:

```swift
import Foundation
import XCTest

/// Intercepts every request on a session made by `makeMockSession()`.
/// Set `MockURLProtocol.handler` per test; it returns (response, bodyData).
/// The body is delivered in one chunk — `URLSession.bytes(for:).lines` still
/// splits it into lines, so SSE streams are testable end-to-end.
final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

func httpResponse(_ url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}

extension URLRequest {
    /// URLProtocol exposes POST bodies as `httpBodyStream`, not `httpBody`.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
```

- [ ] **Step 2: Write the failing adapter tests**

Create `Tests/AINotebookCoreTests/OpenAIAdapterTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OpenAIAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func sseBody(_ payloads: [String]) -> Data {
        Data((payloads.map { "data: \($0)" }.joined(separator: "\n") + "\n").utf8)
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    // ── streaming ────────────────────────────────────────────────────────

    func testStreamsTokensAndStopsAtDone() async throws {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), self.sseBody([
                #"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#,
                #"{"choices":[{"delta":{"content":", world"},"index":0}]}"#,
                "[DONE]",
                #"{"choices":[{"delta":{"content":"IGNORED"},"index":0}]}"#
            ]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "sk-k", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "gpt-4o", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hello", ", world"])
    }

    func testChatRequestShape() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), self.sseBody(["[DONE]"]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com/", apiKey: "sk-abc", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "gpt-4o", messages: [
            ChatTurn(role: .system, content: "Be concise."),
            ChatTurn(role: .user, content: "Hello")
        ]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"gpt-4o""#), body)
        XCTAssertTrue(body.contains(#""role":"system""#), "system turn stays in messages for OpenAI shape")
        XCTAssertTrue(body.contains(#""stream":true"#), body)
    }

    func testNoAuthHeaderWithoutKey() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), self.sseBody(["[DONE]"]))
        }
        let adapter = OpenAIChatAdapter(baseURL: "http://localhost:1234", apiKey: nil, session: makeMockSession())
        _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertNil(try XCTUnwrap(captured).value(forHTTPHeaderField: "Authorization"))
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testStatus429ThrowsRateLimitWithRetryAfter() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 429, headers: ["Retry-After": "7"]), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .rateLimit(retryAfterSeconds: 7))
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testStatus500ThrowsHTTP() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 500), Data())
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .http(let code, _) = e else { return XCTFail("expected .http, got \(e)") }
            XCTAssertEqual(code, 500)
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testMalformedSSELinesAreSkipped() async throws {
        MockURLProtocol.handler = { req in
            let body = "data: not-json\n" +
                       "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"index\":0}]}\n" +
                       "data: [DONE]\n"
            return (httpResponse(req.url!, status: 200), Data(body.utf8))
        }
        let adapter = OpenAIChatAdapter(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["ok"])
    }

    func testEmptyBaseURLThrowsDecodingNotCrash() async {
        let adapter = OpenAIChatAdapter(baseURL: "", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .decoding = e else { return XCTFail("expected .decoding, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    // ── model listing ────────────────────────────────────────────────────

    func testListModelsParsesAndSorts() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"object":"list","data":[{"id":"gpt-4o"},{"id":"babbage-002"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await OpenAIChatAdapter.listModels(baseURL: "https://api.openai.com", apiKey: "k", session: makeMockSession())
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(models.map(\.id), ["babbage-002", "gpt-4o"])
    }

    func testListModels401Throws() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        do {
            _ = try await OpenAIChatAdapter.listModels(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsNetworkErrorPropagates() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await OpenAIChatAdapter.listModels(baseURL: "http://192.168.1.99:9999", apiKey: nil, session: makeMockSession())
            XCTFail("expected throw")
        } catch { /* URLError propagates — Test connection shows it (Phase 1 lesson) */ }
    }

    // ── embeddings ───────────────────────────────────────────────────────

    func testEmbeddingsRequestAndParsing() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"object":"list","data":[{"embedding":[0.1,0.2]},{"embedding":[0.3,0.4]}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let adapter = OpenAIEmbeddingAdapter(baseURL: "https://api.openai.com", apiKey: "sk-k", session: makeMockSession())
        let vectors = try await adapter.embed(model: "text-embedding-3-small", inputs: ["a", "b"])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/embeddings")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-k")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"text-embedding-3-small""#), body)
        XCTAssertTrue(body.contains(#""input":["a","b"]"#), body)
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.2], accuracy: 0.0001)
        XCTAssertEqual(vectors[1], [0.3, 0.4], accuracy: 0.0001)
    }

    func testEmbeddings401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenAIEmbeddingAdapter(baseURL: "https://api.openai.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await adapter.embed(model: "m", inputs: ["a"])
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }
}

/// Float-array comparison helper.
func XCTAssertEqual(_ lhs: [Float], _ rhs: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
    for (l, r) in zip(lhs, rhs) {
        XCTAssertEqual(l, r, accuracy: accuracy, file: file, line: line)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter OpenAIAdapterTests`
Expected: FAIL — `cannot find 'OpenAIChatAdapter' in scope`.

- [ ] **Step 4: Implement the shared wire layer**

Create `Sources/AINotebookCore/Providers/ProviderWire.swift`:

```swift
import Foundation

/// Shared request building, status mapping, and the single OpenAI-shape SSE
/// stream runner used by the OpenAI, OpenAI-compatible, and OpenWebUI
/// adapters. Networking is allowed here: this file lives under Providers/,
/// which the core-ci privacy-grep job allowlists.
enum ProviderWire {

    static func trimBase(_ baseURL: String) -> String {
        var s = baseURL
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    static func url(base: String, path: String) throws -> URL {
        let trimmed = trimBase(base)
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw ProviderError.decoding("Invalid base URL: '\(base)'")
        }
        return url
    }

    static func wireRole(_ role: ChatRole) -> String {
        switch role {
        case .system: "system"
        case .assistant: "assistant"
        case .user: "user"
        }
    }

    /// nil for 2xx; otherwise the FR-A10 mapping.
    static func error(forStatus code: Int, retryAfter: String?, body: String) -> ProviderError? {
        switch code {
        case 200..<300: nil
        case 401: .auth("Invalid API key (401).")
        case 429: .rateLimit(retryAfterSeconds: retryAfter.flatMap(Double.init))
        default: .http(code: code, body: body)
        }
    }

    struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct OpenAIChatBody: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
    }

    static func openAIStyleChatRequest(
        base: String,
        path: String,
        apiKey: String?,
        model: String,
        messages: [ChatTurn]
    ) throws -> URLRequest {
        var req = URLRequest(url: try url(base: base, path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let wire = messages.map { WireMessage(role: wireRole($0.role), content: $0.content) }
        req.httpBody = try JSONEncoder().encode(OpenAIChatBody(model: model, messages: wire, stream: true))
        return req
    }

    /// The one OpenAI-shape SSE runner: send, map status, split lines, parse
    /// deltas, honor [DONE]. Task cancellation propagates via onTermination.
    static func openAIStyleStream(request: URLRequest, session: URLSession) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       let err = error(
                        forStatus: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        body: ""
                       ) {
                        continuation.finish(throwing: err)
                        return
                    }
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line) else { continue }
                        if payload == SSE.done { break }
                        for token in SSE.openAITokens(inPayload: payload) {
                            continuation.yield(token)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let name: String?
        }
        let data: [Item]
    }

    /// GET {base}{path} → {"data":[{"id", "name"?}]}. Throws on ANY failure —
    /// 401 → .auth, other statuses → .http, network errors → URLError.
    /// Sorted case-insensitively by label.
    static func listOpenAIStyleModels(
        base: String,
        path: String,
        apiKey: String?,
        session: URLSession
    ) async throws -> [ProviderModelInfo] {
        var req = URLRequest(url: try url(base: base, path: path))
        req.httpMethod = "GET"
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw ProviderError.decoding("Unexpected /models response shape")
        }
        return decoded.data
            .map { ProviderModelInfo(id: $0.id, displayName: $0.name) }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }
}
```

- [ ] **Step 5: Implement the OpenAI adapters**

Create `Sources/AINotebookCore/Providers/OpenAIAdapters.swift`:

```swift
import Foundation

/// OpenAI-compatible streaming chat adapter (OpenAI, LM Studio, OpenRouter,
/// vLLM). The system turn stays in the messages array as role:"system".
/// Covers both the `openai` and `openai_compatible` provider types.
public struct OpenAIChatAdapter: ChatStreaming {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try ProviderWire.openAIStyleChatRequest(
                base: baseURL, path: "/v1/chat/completions",
                apiKey: apiKey, model: model, messages: messages
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderWire.openAIStyleStream(request: request, session: session)
    }

    public static func listModels(
        baseURL: String, apiKey: String?, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        try await ProviderWire.listOpenAIStyleModels(
            base: baseURL, path: "/v1/models", apiKey: apiKey, session: session
        )
    }
}

/// `POST {base}/v1/embeddings` — OpenAI and compatible servers.
public struct OpenAIEmbeddingAdapter: EmbeddingProducing {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: [String]
    }

    private struct ResponseBody: Decodable {
        struct Item: Decodable { let embedding: [Double] }
        let data: [Item]
    }

    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/embeddings"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiKey, !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(RequestBody(model: model, input: inputs))
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = ProviderWire.error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw ProviderError.decoding("Unexpected /embeddings response shape")
        }
        return decoded.data.map { $0.embedding.map(Float.init) }
    }
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter OpenAIAdapterTests`
Expected: PASS (13 tests).

Note: the local `swift test` run is NOT gated by CI's privacy-grep — but CI would fail right now because `ProviderWire.swift`/`OpenAIAdapters.swift` mention URLSession. The gate allowlist update lands in Task 8; do not push before then (this plan pushes in Task 13 only).

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/AINotebookCore/Providers/ProviderWire.swift \
        Sources/AINotebookCore/Providers/OpenAIAdapters.swift \
        Tests/AINotebookCoreTests/MockURLProtocol.swift \
        Tests/AINotebookCoreTests/OpenAIAdapterTests.swift
git commit -m "feat(mac): OpenAI chat/embedding adapters on shared wire layer

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: `AnthropicChatAdapter`

**Files:**
- Create: `Sources/AINotebookCore/Providers/AnthropicChatAdapter.swift`
- Test: `Tests/AINotebookCoreTests/AnthropicAdapterTests.swift`

**Interfaces:**
- Consumes: `ChatStreaming`, `ChatTurn`/`ChatRole`, `ProviderError`, `ProviderModelInfo`, `SSE.anthropicEvent` (Task 4), `ProviderWire.url/error/trimBase` (Task 5), `MockURLProtocol` harness (Task 5).
- Produces: `struct AnthropicChatAdapter: ChatStreaming` — `init(baseURL: String, apiKey: String, session: URLSession = .shared)`; `static let defaultModels: [ProviderModelInfo]` (fallback when `/v1/models` is unreachable — the router uses it); `static func listModels(baseURL: String, apiKey: String, session: URLSession) async throws -> [ProviderModelInfo]`. Key differences from the OpenAI shape: system prompt is hoisted to the top-level `system` field (NOT a message), headers are `x-api-key` + `anthropic-version: 2023-06-01` (no Bearer), `max_tokens: 8192`, and `stop_reason == "refusal"` surfaces as `ProviderError.refusal`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/AnthropicAdapterTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class AnthropicAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    private func sse(_ payloads: [String]) -> Data {
        Data((payloads.map { "data: \($0)" }.joined(separator: "\n") + "\n").utf8)
    }

    func testStreamsTextDeltas() async throws {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), self.sse([
                #"{"type":"message_start","message":{}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"lo"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
                #"{"type":"message_stop"}"#
            ]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "claude-sonnet-4-6", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hel", "lo"])
    }

    func testSystemTurnHoistedToTopLevelField() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), self.sse([#"{"type":"message_stop"}"#]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "claude-sonnet-4-6", messages: [
            ChatTurn(role: .system, content: "Be concise."),
            ChatTurn(role: .user, content: "Hello"),
            ChatTurn(role: .assistant, content: "Hi!"),
            ChatTurn(role: .user, content: "More")
        ]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""system":"Be concise.""#), body)
        XCTAssertFalse(body.contains(#""role":"system""#), "system must NOT appear in messages: \(body)")
        XCTAssertTrue(body.contains(#""max_tokens":8192"#), body)
        XCTAssertTrue(body.contains(#""stream":true"#), body)
        XCTAssertTrue(body.contains(#""role":"assistant""#), body)
    }

    func testRefusalStopReasonThrows() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), self.sse([
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I"}}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"refusal"}}"#
            ]))
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "k", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .refusal)
        } catch { XCTFail("expected ProviderError.refusal, got \(error)") }
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = AnthropicChatAdapter(baseURL: "https://api.anthropic.com", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsParsesDisplayName() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"data":[{"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6"},{"id":"claude-haiku-4-5","display_name":"Claude Haiku 4.5"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await AnthropicChatAdapter.listModels(baseURL: "https://api.anthropic.com", apiKey: "sk-ant", session: makeMockSession())
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(models.count, 2)
        XCTAssertTrue(models.contains(ProviderModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6")))
    }

    func testDefaultModelsFallbackList() {
        let ids = AnthropicChatAdapter.defaultModels.map(\.id)
        XCTAssertEqual(ids, ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5", "claude-fable-5"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AnthropicAdapterTests`
Expected: FAIL — `cannot find 'AnthropicChatAdapter' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/Providers/AnthropicChatAdapter.swift`:

```swift
import Foundation

/// Anthropic Messages API streaming adapter. Differs from the OpenAI shape:
/// the system prompt is a top-level `system` field (never a message), auth is
/// `x-api-key` + `anthropic-version`, and a `stop_reason` of "refusal" is
/// surfaced as `ProviderError.refusal` instead of an empty answer (FR-A10).
public struct AnthropicChatAdapter: ChatStreaming {
    static let apiVersion = "2023-06-01"
    static let maxTokens = 8192

    /// Offered when GET /v1/models is unreachable (roadmap FR-A3 fallback).
    public static let defaultModels: [ProviderModelInfo] = [
        ProviderModelInfo(id: "claude-opus-4-8", displayName: "Claude Opus 4.8"),
        ProviderModelInfo(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6"),
        ProviderModelInfo(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5"),
        ProviderModelInfo(id: "claude-fable-5", displayName: "Claude Fable 5")
    ]

    let baseURL: String
    let apiKey: String
    let session: URLSession

    public init(baseURL: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    private struct RequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [ProviderWire.WireMessage]
        let stream: Bool
        enum CodingKeys: String, CodingKey {
            case model, system, messages, stream
            case maxTokens = "max_tokens"
        }
    }

    func makeRequest(model: String, messages: [ChatTurn]) throws -> URLRequest {
        let systemTexts = messages.filter { $0.role == .system }.map(\.content)
        let system = systemTexts.isEmpty ? nil : systemTexts.joined(separator: "\n\n")
        let wire = messages
            .filter { $0.role != .system }
            .map { ProviderWire.WireMessage(role: ProviderWire.wireRole($0.role), content: $0.content) }

        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/messages"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONEncoder().encode(RequestBody(
            model: model, maxTokens: Self.maxTokens, system: system, messages: wire, stream: true
        ))
        return req
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(model: model, messages: messages)
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse,
                       let err = ProviderWire.error(
                        forStatus: http.statusCode,
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                        body: ""
                       ) {
                        continuation.finish(throwing: err)
                        return
                    }
                    for try await line in bytes.lines {
                        guard let payload = SSE.dataPayload(of: line),
                              let event = SSE.anthropicEvent(inPayload: payload)
                        else { continue }
                        switch event {
                        case .textDelta(let text):
                            continuation.yield(text)
                        case .stopReason(let reason):
                            if reason == "refusal" {
                                continuation.finish(throwing: ProviderError.refusal)
                                return
                            }
                        case .messageStop:
                            continuation.finish()
                            return
                        case .other:
                            continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct ModelsResponse: Decodable {
        struct Item: Decodable {
            let id: String
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id
                case displayName = "display_name"
            }
        }
        let data: [Item]
    }

    /// Throws on any failure (401 → .auth, network → URLError). The router
    /// substitutes `defaultModels` for the picker path only.
    public static func listModels(
        baseURL: String, apiKey: String, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        var req = URLRequest(url: try ProviderWire.url(base: baseURL, path: "/v1/models"))
        req.httpMethod = "GET"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse,
           let err = ProviderWire.error(
            forStatus: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: String(data: data, encoding: .utf8) ?? ""
           ) {
            throw err
        }
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: data) else {
            throw ProviderError.decoding("Unexpected /v1/models response shape")
        }
        return decoded.data.map { ProviderModelInfo(id: $0.id, displayName: $0.displayName) }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AnthropicAdapterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Providers/AnthropicChatAdapter.swift \
        Tests/AINotebookCoreTests/AnthropicAdapterTests.swift
git commit -m "feat(mac): Anthropic Messages API streaming adapter with refusal handling

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: `OpenWebUIChatAdapter`

**Files:**
- Create: `Sources/AINotebookCore/Providers/OpenWebUIChatAdapter.swift`
- Test: `Tests/AINotebookCoreTests/OpenWebUIAdapterTests.swift`

**Interfaces:**
- Consumes: `ProviderWire.openAIStyleChatRequest/openAIStyleStream/listOpenAIStyleModels` (Task 5) — the adapter is a thin path-parameterization, NOT a copy (Phase 1 lesson).
- Produces: `struct OpenWebUIChatAdapter: ChatStreaming` — `init(baseURL: String, apiKey: String?, session: URLSession = .shared)`; `static func listModels(baseURL: String, apiKey: String?, session: URLSession) async throws -> [ProviderModelInfo]` (uses `data[].name` as display name — OpenWebUI aggregates Ollama models, cloud backends, and functions).

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/OpenWebUIAdapterTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OpenWebUIAdapterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    func testPostsToApiChatCompletionsNotV1() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: [DONE]\n".utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://192.168.1.50:3000/", apiKey: "sk-owui", session: makeMockSession())
        _ = try await collect(adapter.stream(model: "llama3.2", messages: [ChatTurn(role: .user, content: "hi")]))
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "http://192.168.1.50:3000/api/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-owui")
    }

    func testStreamsTokens() async throws {
        MockURLProtocol.handler = { req in
            let body = "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0}]}\n" +
                       "data: {\"choices\":[{\"delta\":{\"content\":\", LAN\"},\"index\":0}]}\n" +
                       "data: [DONE]\n"
            return (httpResponse(req.url!, status: 200), Data(body.utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: nil, session: makeMockSession())
        let tokens = try await collect(adapter.stream(model: "llama3.2", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["Hello", ", LAN"])
    }

    func testKeylessRequestHasNoAuthHeader() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: [DONE]\n".utf8))
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: nil, session: makeMockSession())
        _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertNil(try XCTUnwrap(captured).value(forHTTPHeaderField: "Authorization"))
    }

    func testStatus401ThrowsAuth() async {
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let adapter = OpenWebUIChatAdapter(baseURL: "http://h:3000", apiKey: "bad", session: makeMockSession())
        do {
            _ = try await collect(adapter.stream(model: "m", messages: [ChatTurn(role: .user, content: "hi")]))
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        } catch { XCTFail("expected ProviderError, got \(error)") }
    }

    func testListModelsUsesApiModelsAndNameAsDisplayName() async throws {
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            let json = #"{"data":[{"id":"gpt-4o","name":"GPT-4o (cloud)","object":"model"},{"id":"llama3.2","name":"Llama 3.2","object":"model"}]}"#
            return (httpResponse(req.url!, status: 200), Data(json.utf8))
        }
        let models = try await OpenWebUIChatAdapter.listModels(baseURL: "http://h:3000", apiKey: "k", session: makeMockSession())
        XCTAssertEqual(captured?.url?.absoluteString, "http://h:3000/api/models")
        XCTAssertEqual(models.map(\.label), ["GPT-4o (cloud)", "Llama 3.2"])
        XCTAssertEqual(models.map(\.id), ["gpt-4o", "llama3.2"])
    }

    func testListModelsNetworkErrorPropagates() async {
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await OpenWebUIChatAdapter.listModels(baseURL: "http://192.168.1.99:9999", apiKey: nil, session: makeMockSession())
            XCTFail("expected throw")
        } catch { /* propagates so Test connection reports it */ }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter OpenWebUIAdapterTests`
Expected: FAIL — `cannot find 'OpenWebUIChatAdapter' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/Providers/OpenWebUIChatAdapter.swift`:

```swift
import Foundation

/// OpenWebUI network adapter. OpenWebUI aggregates models (local Ollama,
/// cloud backends, functions) behind an OpenAI-shape API rooted at /api,
/// NOT /v1: POST {base}/api/chat/completions, GET {base}/api/models.
/// Bearer key optional — instances may run with auth disabled. Chat-only:
/// OpenWebUI exposes no OpenAI-compatible embeddings endpoint.
public struct OpenWebUIChatAdapter: ChatStreaming {
    let baseURL: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        let request: URLRequest
        do {
            request = try ProviderWire.openAIStyleChatRequest(
                base: baseURL, path: "/api/chat/completions",
                apiKey: apiKey, model: model, messages: messages
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        return ProviderWire.openAIStyleStream(request: request, session: session)
    }

    public static func listModels(
        baseURL: String, apiKey: String?, session: URLSession = .shared
    ) async throws -> [ProviderModelInfo] {
        try await ProviderWire.listOpenAIStyleModels(
            base: baseURL, path: "/api/models", apiKey: apiKey, session: session
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter OpenWebUIAdapterTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Providers/OpenWebUIChatAdapter.swift \
        Tests/AINotebookCoreTests/OpenWebUIAdapterTests.swift
git commit -m "feat(mac): OpenWebUI chat adapter (thin path parameterization of shared wire)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: `ProviderSelectionReading` + `ProviderRouter` + CI gate allowlist

**Files:**
- Create: `Sources/AINotebookCore/Providers/ProviderSelection.swift`
- Create: `Sources/AINotebookCore/Providers/ProviderRouter.swift`
- Modify: `.github/workflows/core-ci.yml` (privacy-grep allowlist)
- Modify: `Sources/AINotebookCore/OllamaClient.swift:3-5` (stale header comment)
- Test: `Tests/AINotebookCoreTests/ProviderRouterTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–7; `OllamaClient(baseURL:session:)` (`OllamaClient.swift:12`), `OllamaClient.listModels()/embed(model:input:)/chat(model:messages:options:)`; `NotebookStore.provider(id:)` (Task 2; `NotebookStore` is `@MainActor` — hop via `MainActor.run`).
- Produces:
  - `public enum ProviderSettingsKeys` — `chatProviderId = "selectedChatProviderId"`, `embeddingProviderId = "selectedEmbeddingProviderId"`, `chatModel = "selectedChatModel"`, `embeddingModel = "selectedEmbeddingModel"` (string constants shared with `AppSettings`, Task 11).
  - `public protocol ProviderSelectionReading: Sendable` — `func chatSelection() -> (providerId: String, model: String)`, `func embeddingSelection() -> (providerId: String, model: String)`; extension `func embeddingKey() -> String` returning `"{providerId}:{model}"`.
  - `public final class DefaultsProviderSelection: ProviderSelectionReading` (UserDefaults-backed; defaults: Ollama id + `"llama3.2:3b"` / `"nomic-embed-text"`).
  - `public final class ProviderRouter: ChatStreaming, EmbeddingProducing` — `init(store: NotebookStore, secrets: any SecretStoring, selection: any ProviderSelectionReading, session: URLSession = .shared)`; plus `func listModels(providerId: String) async -> [ProviderModelInfo]` (UI-safe: failures → `[]`, Anthropic → `defaultModels`) and `func testConnection(type: ProviderType, baseURL: String, apiKey: String?) async -> Error?` (nil = OK; the caught error otherwise — UI maps `ProviderError` cases to localized strings). The passed `model` parameter on `stream`/`embed` is IGNORED — the live selection wins.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/ProviderRouterTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

@MainActor
final class ProviderRouterTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// Fixed selection for tests.
    final class StaticSelection: ProviderSelectionReading, @unchecked Sendable {
        var chat: (String, String)
        var embed: (String, String)
        init(chat: (String, String), embed: (String, String)) {
            self.chat = chat
            self.embed = embed
        }
        func chatSelection() -> (providerId: String, model: String) { chat }
        func embeddingSelection() -> (providerId: String, model: String) { embed }
    }

    private func makeRouter(
        store: NotebookStore,
        selection: StaticSelection,
        secrets: InMemorySecretStore = InMemorySecretStore()
    ) -> ProviderRouter {
        ProviderRouter(store: store, secrets: secrets, selection: selection, session: makeMockSession())
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var tokens: [String] = []
        for try await t in stream { tokens.append(t) }
        return tokens
    }

    func testChatRoutesToOpenWebUIWithLiveModelAndStoredKey() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: cfg.id, secret: "sk-owui")
        let selection = StaticSelection(chat: (cfg.id, "llama3.2"), embed: (ProviderConfig.ollamaId, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection, secrets: secrets)

        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("data: {\"choices\":[{\"delta\":{\"content\":\"tok\"},\"index\":0}]}\ndata: [DONE]\n".utf8))
        }
        // Engines pass their launch-time model — the router must ignore it.
        let tokens = try await collect(router.stream(model: "stale-model-ignored", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(tokens, ["tok"])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "http://h:3000/api/chat/completions")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-owui")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"llama3.2""#), "live model must win: \(body)")
    }

    func testChatFallsBackToOllamaWhenConfigMissing() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: ("no-such-id", "llama3.2:3b"), embed: (ProviderConfig.ollamaId, "x"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data("{\"model\":\"m\",\"created_at\":\"\",\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"done\":true}\n".utf8))
        }
        _ = try await collect(router.stream(model: "ignored", messages: [ChatTurn(role: .user, content: "hi")]))
        XCTAssertEqual(captured?.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
    }

    func testEmbedRoutesToOpenAIEmbeddings() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openai, name: "OpenAI", baseURL: "https://api.openai.com")
        try store.saveProvider(cfg)
        let secrets = InMemorySecretStore()
        try secrets.save(providerId: cfg.id, secret: "sk-oai")
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (cfg.id, "text-embedding-3-small"))
        let router = makeRouter(store: store, selection: selection, secrets: secrets)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"data":[{"embedding":[1.0,0.0]}]}"#.utf8))
        }
        let vectors = try await router.embed(model: "ignored", inputs: ["a"])
        XCTAssertEqual(vectors, [[1.0, 0.0]])
        let req = try XCTUnwrap(captured)
        XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/embeddings")
        let body = String(decoding: try XCTUnwrap(req.bodyData), as: UTF8.self)
        XCTAssertTrue(body.contains(#""model":"text-embedding-3-small""#), body)
    }

    func testEmbedForChatOnlyTypeFallsBackToOllama() async throws {
        // UI never offers openwebui for embeddings; if selected anyway the
        // router falls back to Ollama (Windows parity).
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (cfg.id, "nomic-embed-text"))
        let router = makeRouter(store: store, selection: selection)
        nonisolated(unsafe) var captured: URLRequest?
        MockURLProtocol.handler = { req in
            captured = req
            return (httpResponse(req.url!, status: 200), Data(#"{"embeddings":[[1.0,0.0]]}"#.utf8))
        }
        _ = try await router.embed(model: "ignored", inputs: ["a"])
        // Falls back to the openwebui config's host? No — to Ollama's default.
        XCTAssertEqual(captured?.url?.absoluteString, "http://127.0.0.1:11434/api/embed")
    }

    func testListModelsOpenWebUI() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Data(#"{"data":[{"id":"llama3.2","name":"Llama 3.2"}]}"#.utf8))
        }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models.map(\.id), ["llama3.2"])
    }

    func testListModelsFailureIsEmptyForUI() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .openwebui, name: "LAN", baseURL: "http://h:3000")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models, [])
    }

    func testListModelsAnthropicFailureGivesFallbackList() async throws {
        let store = try NotebookStore(path: .inMemory)
        let cfg = ProviderConfig(type: .anthropic, name: "Claude", baseURL: "https://api.anthropic.com")
        try store.saveProvider(cfg)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let models = await router.listModels(providerId: cfg.id)
        XCTAssertEqual(models, AnthropicChatAdapter.defaultModels)
    }

    func testTestConnectionSuccessReturnsNil() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 200), Data(#"{"data":[{"id":"m"}]}"#.utf8))
        }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://h:3000", apiKey: "k")
        XCTAssertNil(error)
    }

    func testTestConnectionReports401() async throws {
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { req in
            (httpResponse(req.url!, status: 401), Data())
        }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://h:3000", apiKey: "bad")
        guard case .auth = error as? ProviderError else {
            return XCTFail("expected ProviderError.auth, got \(String(describing: error))")
        }
    }

    func testTestConnectionReportsNetworkFailure() async throws {
        // Phase 1 lesson: a typo'd LAN URL must NOT report success.
        let store = try NotebookStore(path: .inMemory)
        let selection = StaticSelection(chat: (ProviderConfig.ollamaId, "x"), embed: (ProviderConfig.ollamaId, "y"))
        let router = makeRouter(store: store, selection: selection)
        MockURLProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        let error = await router.testConnection(type: .openwebui, baseURL: "http://192.168.1.99:9999", apiKey: nil)
        XCTAssertNotNil(error)
    }

    func testEmbeddingKeyComposition() {
        let selection = StaticSelection(chat: ("c", "m"), embed: ("prov-1", "nomic-embed-text"))
        XCTAssertEqual(selection.embeddingKey(), "prov-1:nomic-embed-text")
    }

    func testDefaultsSelectionReadsSharedKeys() {
        let suiteName = "router.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let selection = DefaultsProviderSelection(defaults: defaults)
        XCTAssertEqual(selection.chatSelection().providerId, ProviderConfig.ollamaId)
        XCTAssertEqual(selection.chatSelection().model, "llama3.2:3b")
        defaults.set("p-9", forKey: ProviderSettingsKeys.chatProviderId)
        defaults.set("gpt-4o", forKey: ProviderSettingsKeys.chatModel)
        XCTAssertEqual(selection.chatSelection().providerId, "p-9")
        XCTAssertEqual(selection.chatSelection().model, "gpt-4o")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProviderRouterTests`
Expected: FAIL — `cannot find 'ProviderRouter' in scope`.

- [ ] **Step 3: Implement selection**

Create `Sources/AINotebookCore/Providers/ProviderSelection.swift`:

```swift
import Foundation

/// UserDefaults keys for the active provider/model selection. Shared between
/// `AppSettings` (writes, @MainActor) and `DefaultsProviderSelection`
/// (reads from any context — UserDefaults is thread-safe).
public enum ProviderSettingsKeys {
    public static let chatProviderId = "selectedChatProviderId"
    public static let embeddingProviderId = "selectedEmbeddingProviderId"
    public static let chatModel = "selectedChatModel"
    public static let embeddingModel = "selectedEmbeddingModel"
}

/// Live (provider, model) selection, readable from any isolation context.
/// The router consults this on EVERY call, which is what makes provider and
/// model switches take effect without rebuilding engines.
public protocol ProviderSelectionReading: Sendable {
    func chatSelection() -> (providerId: String, model: String)
    func embeddingSelection() -> (providerId: String, model: String)
}

public extension ProviderSelectionReading {
    /// Fully qualified `chunk_embeddings.model` key (FR-A11).
    func embeddingKey() -> String {
        let s = embeddingSelection()
        return "\(s.providerId):\(s.model)"
    }
}

public final class DefaultsProviderSelection: ProviderSelectionReading, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func chatSelection() -> (providerId: String, model: String) {
        (defaults.string(forKey: ProviderSettingsKeys.chatProviderId) ?? ProviderConfig.ollamaId,
         defaults.string(forKey: ProviderSettingsKeys.chatModel) ?? "llama3.2:3b")
    }

    public func embeddingSelection() -> (providerId: String, model: String) {
        (defaults.string(forKey: ProviderSettingsKeys.embeddingProviderId) ?? ProviderConfig.ollamaId,
         defaults.string(forKey: ProviderSettingsKeys.embeddingModel) ?? "nomic-embed-text")
    }
}
```

- [ ] **Step 4: Implement the router**

Create `Sources/AINotebookCore/Providers/ProviderRouter.swift`:

```swift
import Foundation

/// Routes `ChatStreaming` / `EmbeddingProducing` calls to the active
/// provider. Reads the live (provider, model) selection on every call — the
/// `model` parameter passed by engines is ignored (they capture it at
/// launch; the router is what makes Settings changes effective immediately).
/// Adapters are cheap value types constructed per call and the API key is
/// read from the secret store each time: no cache, no staleness.
public final class ProviderRouter: @unchecked Sendable {
    private let store: NotebookStore
    private let secrets: any SecretStoring
    private let selection: any ProviderSelectionReading
    private let session: URLSession

    public init(
        store: NotebookStore,
        secrets: any SecretStoring,
        selection: any ProviderSelectionReading,
        session: URLSession = .shared
    ) {
        self.store = store
        self.secrets = secrets
        self.selection = selection
        self.session = session
    }

    // MARK: - Resolution

    private func config(_ providerId: String) async -> ProviderConfig {
        let storeRef = store
        let cfg = try? await MainActor.run { try storeRef.provider(id: providerId) }
        return (cfg ?? nil) ?? .builtInOllama()
    }

    private func apiKey(for cfg: ProviderConfig) -> String? {
        guard cfg.type.isCloud else { return nil }
        return (try? secrets.load(providerId: cfg.id)) ?? nil
    }

    private func ollamaClient(baseURL: String) -> OllamaClient {
        let url = URL(string: ProviderWire.trimBase(baseURL))
            ?? URL(string: ProviderType.ollama.defaultBaseURL)!
        return OllamaClient(baseURL: url, session: session)
    }

    private func chatAdapter(for cfg: ProviderConfig) -> any ChatStreaming {
        switch cfg.type {
        case .ollama:
            ollamaClient(baseURL: cfg.baseURL)
        case .anthropic:
            AnthropicChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg) ?? "", session: session)
        case .openai, .openaiCompatible:
            OpenAIChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
        case .openwebui:
            OpenWebUIChatAdapter(baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
        }
    }
}

// MARK: - ChatStreaming

extension ProviderRouter: ChatStreaming {
    public func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (providerId, activeModel) = self.selection.chatSelection()
                    let cfg = await self.config(providerId)
                    let adapter = self.chatAdapter(for: cfg)
                    for try await token in adapter.stream(model: activeModel, messages: messages) {
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - EmbeddingProducing

extension ProviderRouter: EmbeddingProducing {
    public func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        let (providerId, activeModel) = selection.embeddingSelection()
        let cfg = await config(providerId)
        switch cfg.type {
        case .openai, .openaiCompatible:
            return try await OpenAIEmbeddingAdapter(
                baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session
            ).embed(model: activeModel, inputs: inputs)
        case .ollama:
            let doubles = try await ollamaClient(baseURL: cfg.baseURL)
                .embed(model: activeModel, input: inputs)
            return doubles.map { $0.map(Float.init) }
        case .anthropic, .openwebui:
            // Chat-only types never appear in the embedding picker; if the
            // selection points here anyway, fall back to local Ollama
            // (Windows parity — same treatment as Anthropic on Windows).
            let doubles = try await ollamaClient(baseURL: ProviderType.ollama.defaultBaseURL)
                .embed(model: activeModel, input: inputs)
            return doubles.map { $0.map(Float.init) }
        }
    }
}

// MARK: - Settings-UI surface

extension ProviderRouter {

    /// Models for the pickers. UI-safe: failures collapse to an empty list
    /// (Anthropic gets its static fallback list per FR-A3).
    public func listModels(providerId: String) async -> [ProviderModelInfo] {
        let cfg = await config(providerId)
        do {
            switch cfg.type {
            case .ollama:
                return try await ollamaClient(baseURL: cfg.baseURL).listModels()
                    .map { ProviderModelInfo(id: $0.name) }
                    .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
            case .anthropic:
                return try await AnthropicChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg) ?? "", session: session)
            case .openai, .openaiCompatible:
                return try await OpenAIChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
            case .openwebui:
                return try await OpenWebUIChatAdapter.listModels(
                    baseURL: cfg.baseURL, apiKey: apiKey(for: cfg), session: session)
            }
        } catch {
            return cfg.type == .anthropic ? AnthropicChatAdapter.defaultModels : []
        }
    }

    /// nil = success. Otherwise returns the underlying error — 401, HTTP
    /// failures, and network errors all surface (FR-A9; Phase 1 lesson: a
    /// typo'd LAN URL must not show a green checkmark). The UI maps
    /// `ProviderError` cases to localized strings.
    public func testConnection(type: ProviderType, baseURL: String, apiKey: String?) async -> Error? {
        do {
            switch type {
            case .ollama:
                _ = try await ollamaClient(baseURL: baseURL).listModels()
            case .anthropic:
                _ = try await AnthropicChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey ?? "", session: session)
            case .openai, .openaiCompatible:
                _ = try await OpenAIChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey, session: session)
            case .openwebui:
                _ = try await OpenWebUIChatAdapter.listModels(
                    baseURL: baseURL, apiKey: apiKey, session: session)
            }
            return nil
        } catch {
            return error
        }
    }
}
```

- [ ] **Step 5: Update the CI gate and the stale OllamaClient header**

In `.github/workflows/core-ci.yml`, replace the privacy-grep step's `run` block with:

```yaml
      - name: Forbid URLSession in AINotebookCore except OllamaClient, WebExtractor and Providers/
        # OllamaClient, WebExtractor, and the provider adapters under
        # Providers/ are the only Core files allowed to talk to the network.
        # Every other Core file must stay offline.
        run: |
          OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v -e '/OllamaClient.swift$' -e '/WebExtractor.swift$' -e '/Providers/' || true)
          if [ -n "$OFFENDERS" ]; then
            echo "::error::URLSession found outside OllamaClient.swift, WebExtractor.swift and Providers/:"
            echo "$OFFENDERS"
            exit 1
          fi
          echo "OK: URLSession only present in OllamaClient.swift, WebExtractor.swift and Providers/."
```

In `Sources/AINotebookCore/OllamaClient.swift`, update the header comment (it predates WebExtractor's allowlisting and this change):

```swift
/// Typed wrapper around the Ollama HTTP API. Lives in `AINotebookCore`.
/// Networking in Core is restricted to this file, `WebExtractor.swift`, and
/// the provider adapters under `Providers/` (enforced by CI grep gate).
```

Verify the gate logic locally:

```bash
OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v -e '/OllamaClient.swift$' -e '/WebExtractor.swift$' -e '/Providers/' || true)
[ -z "$OFFENDERS" ] && echo "GATE OK" || echo "GATE FAIL: $OFFENDERS"
```

Expected: `GATE OK`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter ProviderRouterTests`
Expected: PASS (12 tests).

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/AINotebookCore/Providers/ProviderSelection.swift \
        Sources/AINotebookCore/Providers/ProviderRouter.swift \
        Sources/AINotebookCore/OllamaClient.swift \
        .github/workflows/core-ci.yml \
        Tests/AINotebookCoreTests/ProviderRouterTests.swift
git commit -m "feat(mac): ProviderRouter with live selection + CI gate allowlist for Providers/

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: Live model keys in `Embedder`/`Retriever` + FR-A10 retry semantics in `ChatEngine`

**Files:**
- Modify: `Sources/AINotebookCore/Embedder.swift`
- Modify: `Sources/AINotebookCore/Retriever.swift:10-20` (init) and the `search` body's model usages
- Modify: `Sources/AINotebookCore/ChatEngine.swift:80-98` (retry loop)
- Test: `Tests/AINotebookCoreTests/EmbedderModelKeyTests.swift`
- Test: extend `Tests/AINotebookCoreTests/ChatEngineRetryTests.swift`

**Interfaces:**
- Consumes: `ProviderError` (Task 1). Existing stubs: `FlakyChat` in `ChatEngineRetryTests.swift`, `MockEmbeddingClient` in `EmbedderTests.swift`.
- Produces: `Embedder.init(store:client:modelKey: @escaping @Sendable () -> String, batchSize:)` — the old `init(store:client:model:batchSize:)` remains as a convenience delegating `modelKey: { model }` so existing call sites and tests compile unchanged. Same pair for `Retriever` (`modelKey` + convenience `model`). `ChatEngine` retry: `ProviderError.auth`/`.refusal` are rethrown immediately (no retry); `.rateLimit(retryAfterSeconds:)` sleeps the server-provided interval when present; everything else keeps the existing exponential backoff.

- [ ] **Step 1: Write the failing Embedder/Retriever tests**

Create `Tests/AINotebookCoreTests/EmbedderModelKeyTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

@MainActor
final class EmbedderModelKeyTests: XCTestCase {

    final class RecordingClient: EmbeddingProducing, @unchecked Sendable {
        var models: [String] = []
        func embed(model: String, inputs: [String]) async throws -> [[Float]] {
            models.append(model)
            return inputs.map { _ in [1, 0] }
        }
    }

    /// Mutable key box standing in for a live settings read.
    final class KeyBox: @unchecked Sendable {
        var value: String
        init(_ value: String) { self.value = value }
    }

    /// NotebookStore has no notebooks() list API — return the id directly.
    private func makeStoreWithOneChunk() throws -> (store: NotebookStore, notebookId: Int64) {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "NB")
        let source = try store.createSource(
            notebookId: nb.id!, type: .text, title: "T", uri: nil, rawPath: nil)
        try store.replaceChunks(sourceId: source.id!, chunks: [
            SourceChunk(sourceId: source.id!, ord: 0, text: "hello world")
        ])
        return (store, nb.id!)
    }

    func testEmbedderUsesLiveModelKeyPerDrain() async throws {
        let (store, _) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let box = KeyBox("prov-A:model-1")
        let embedder = Embedder(store: store, client: client, modelKey: { box.value })

        _ = try await embedder.embedAllPending()
        XCTAssertEqual(client.models, ["prov-A:model-1"])

        // Switch the selection; the SAME embedder instance must pick it up.
        box.value = "prov-B:model-2"
        _ = try await embedder.embedAllPending()   // chunk has no row for the new key yet
        XCTAssertEqual(client.models, ["prov-A:model-1", "prov-B:model-2"])
    }

    func testConvenienceInitKeepsFixedModel() async throws {
        let (store, _) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let embedder = Embedder(store: store, client: client, model: "fixed-key")
        _ = try await embedder.embedAllPending()
        XCTAssertEqual(client.models, ["fixed-key"])
    }

    func testRetrieverUsesLiveModelKey() async throws {
        let (store, notebookId) = try makeStoreWithOneChunk()
        let client = RecordingClient()
        let embedder = Embedder(store: store, client: client, model: "prov-A:m")
        _ = try await embedder.embedAllPending()

        let box = KeyBox("prov-A:m")
        let retriever = Retriever(store: store, client: client, modelKey: { box.value })
        let hits = try await retriever.search(notebookId: notebookId, query: "hello")
        XCTAssertFalse(hits.isEmpty, "stored vectors under prov-A:m must be found")

        box.value = "prov-B:other"
        let missHits = try await retriever.search(notebookId: notebookId, query: "hello")
        // Vector arm finds nothing under the new key (FTS may still hit);
        // assert the embed call went out with the NEW key.
        XCTAssertEqual(client.models.last, "prov-B:other")
        _ = missHits
    }
}
```

Adjustment rule: `makeStoreWithOneChunk` uses `store.replaceChunks(sourceId:chunks:)` and `SourceChunk(sourceId:ord:text:)` — verify the real chunk-writing API in `NotebookStore+Sources.swift` / `SourceChunk.swift` and `EmbedderTests.swift` (which already builds this fixture) and mirror it exactly.

- [ ] **Step 2: Write the failing ChatEngine retry tests**

Append to `Tests/AINotebookCoreTests/ChatEngineRetryTests.swift` (inside the existing test class; reuse its store/session fixture pattern — read the file first):

```swift
    final class ThrowingChat: ChatStreaming, @unchecked Sendable {
        let error: Error
        var attempts = 0
        init(error: Error) { self.error = error }
        func stream(model: String, messages: [ChatTurn]) -> AsyncThrowingStream<String, Error> {
            attempts += 1
            let err = error
            return AsyncThrowingStream { c in c.finish(throwing: err) }
        }
    }

    func testAuthErrorIsNotRetried() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.auth("Invalid API key (401)."))
        let engine = makeEngine(store: store, chat: chat)
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            guard case .auth = e else { return XCTFail("expected .auth, got \(e)") }
        }
        XCTAssertEqual(chat.attempts, 1, "401 must not be retried")
    }

    func testRefusalIsNotRetried() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.refusal)
        let engine = makeEngine(store: store, chat: chat)
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .refusal)
        }
        XCTAssertEqual(chat.attempts, 1)
    }

    func testRateLimitRetriesWithServerHint() async throws {
        let (store, sessionId, notebookId) = try makeChatFixture()
        let chat = ThrowingChat(error: ProviderError.rateLimit(retryAfterSeconds: 0.01))
        let engine = makeEngine(store: store, chat: chat)   // retryAttempts: 2
        do {
            _ = try await engine.send(sessionId: sessionId, notebookId: notebookId, userText: "hi", onToken: { _ in })
            XCTFail("expected throw")
        } catch let e as ProviderError {
            XCTAssertEqual(e, .rateLimit(retryAfterSeconds: 0.01))
        }
        XCTAssertEqual(chat.attempts, 3, "initial + 2 retries")
    }
```

Adjustment rule: `makeChatFixture()`/`makeEngine(store:chat:)` are placeholders for however `ChatEngineRetryTests.swift` actually builds its store, session, notebook, retriever, and engine — read the existing tests in that file and reuse their exact fixture helpers (inline the setup if the file has no shared helper). Keep `retryAttempts` at the file's existing value or pass `retryAttempts: 2` explicitly, and use a tiny `retryBackoffMillis` (e.g. 1) so the suite stays fast.

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test --filter 'EmbedderModelKeyTests|ChatEngineRetryTests'`
Expected: FAIL — `Embedder` has no `modelKey:` init; new retry tests fail (auth currently retried: attempts == 3).

- [ ] **Step 4: Implement Embedder/Retriever changes**

In `Sources/AINotebookCore/Embedder.swift`, replace the stored `model` property and init:

```swift
public actor Embedder {
    private let store: NotebookStore
    private let client: EmbeddingProducing
    private let modelKey: @Sendable () -> String
    public let batchSize: Int

    /// `modelKey` is read at the start of every drain, so a provider/model
    /// switch in Settings applies to the next embedding run without
    /// rebuilding the embedder (fixes the pre-registry staleness bug).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        modelKey: @escaping @Sendable () -> String,
        batchSize: Int = 16
    ) {
        self.store = store
        self.client = client
        self.modelKey = modelKey
        self.batchSize = batchSize
    }

    /// Convenience for a fixed key (tests, single-provider setups).
    public init(
        store: NotebookStore,
        client: EmbeddingProducing,
        model: String,
        batchSize: Int = 16
    ) {
        self.init(store: store, client: client, modelKey: { model }, batchSize: batchSize)
    }

    @discardableResult
    public func embedAllPending() async throws -> Int {
        let key = modelKey()
        var written = 0
        while true {
            let batch = try await MainActor.run {
                try store.unembeddedChunks(model: key, limit: batchSize)
            }
            if batch.isEmpty { break }
            let inputs = batch.map(\.text)
            let vectors = try await client.embed(model: key, inputs: inputs)
            guard vectors.count == batch.count else {
                throw EmbedderError.responseSizeMismatch(expected: batch.count, got: vectors.count)
            }
            for (chunk, values) in zip(batch, vectors) {
                try await MainActor.run {
                    try store.storeEmbedding(
                        chunkId: chunk.id!,
                        model: key,
                        vector: EmbeddingVector(values: values)
                    )
                }
                written += 1
            }
        }
        return written
    }
}
```

(`store` is `@MainActor`; the existing code already hops via `MainActor.run` — preserve that. Note the composite key goes BOTH into the store rows and into `client.embed(model:)`; the router ignores the latter and resolves the live raw model itself, while non-router clients — tests, direct Ollama setups via the convenience init — receive exactly what they were configured with.)

In `Sources/AINotebookCore/Retriever.swift`, mirror the same change: replace `public let model: String` with `private let modelKey: @Sendable () -> String`, primary init takes `modelKey:`, convenience init takes `model:` and delegates, and in `search(...)` bind `let key = modelKey()` once at the top, replacing every use of the old `model` property (the `client.embed(model: key, ...)` query embedding and the `store.embeddings(notebookId:model: key)` fetch).

- [ ] **Step 5: Implement the ChatEngine retry refinement**

In `Sources/AINotebookCore/ChatEngine.swift`, replace the retry loop's `catch` block (currently lines 92-97):

```swift
            } catch {
                if let providerError = error as? ProviderError {
                    switch providerError {
                    case .auth, .refusal:
                        // Retrying cannot help — the user must fix the key
                        // or rephrase (FR-A10).
                        throw providerError
                    case .rateLimit(let retryAfterSeconds):
                        if attempt >= retryAttempts { throw providerError }
                        attempt += 1
                        let fallback = Double(retryBackoffMillis) * pow(2.0, Double(attempt - 1)) / 1000.0
                        let seconds = retryAfterSeconds ?? fallback
                        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        continue
                    case .http, .decoding:
                        break // generic backoff below
                    }
                }
                if attempt >= retryAttempts { throw error }
                attempt += 1
                let delayNs = UInt64(retryBackoffMillis * Int(pow(2.0, Double(attempt - 1)))) * 1_000_000
                try? await Task.sleep(nanoseconds: delayNs)
            }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `swift test --filter 'EmbedderModelKeyTests|ChatEngineRetryTests|EmbedderTests|RetrieverTests'`
Expected: PASS — new tests green, existing Embedder/Retriever/retry tests green via the convenience inits.

- [ ] **Step 7: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 8: Commit**

```bash
git add Sources/AINotebookCore/Embedder.swift \
        Sources/AINotebookCore/Retriever.swift \
        Sources/AINotebookCore/ChatEngine.swift \
        Tests/AINotebookCoreTests/EmbedderModelKeyTests.swift \
        Tests/AINotebookCoreTests/ChatEngineRetryTests.swift
git commit -m "feat(mac): live embedding model keys + FR-A10 retry semantics (no retry on auth/refusal)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Localization keys (EN + CZ)

**Files:**
- Modify: `Sources/AINotebookCore/Localization.swift` (enum `Key` + `english(_:)` + `czech(_:)` — all three or it won't compile)
- Test: extend `Tests/AINotebookCoreTests/LocalizationTests.swift`

**Interfaces:**
- Consumes: existing `AppText` structure (`enum Key: CaseIterable`, exhaustive per-language switches).
- Produces: 26 new keys used by Tasks 11–12. Structural parity is enforced automatically by the existing `testEveryKeyHasEnglishString`/`testEveryKeyHasCzechString` loops over `allCases`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/AINotebookCoreTests/LocalizationTests.swift` (match the file's existing bilingual-test style):

```swift
    func testProviderSectionKeysAreBilingual() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.providersSectionTitle), "AI providers")
        XCTAssertEqual(cs.string(.providersSectionTitle), "AI provideři")
        XCTAssertEqual(en.string(.addProviderButton), "Add provider…")
        XCTAssertEqual(cs.string(.addProviderButton), "Přidat providera…")
        XCTAssertEqual(en.string(.providerTestButton), "Test connection")
        XCTAssertEqual(cs.string(.providerTestButton), "Otestovat připojení")
        XCTAssertEqual(en.string(.privacyGateTitle), "Send data to this provider?")
        XCTAssertEqual(cs.string(.privacyGateTitle), "Odesílat data tomuto providerovi?")
        XCTAssertEqual(en.string(.errorInvalidApiKey), "Invalid API key")
        XCTAssertEqual(cs.string(.errorInvalidApiKey), "Neplatný API klíč")
        XCTAssertEqual(en.string(.doneButton), "Done")
        XCTAssertEqual(cs.string(.doneButton), "Hotovo")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter LocalizationTests`
Expected: FAIL — compile error, `Key` has no member `providersSectionTitle`.

- [ ] **Step 3: Implement**

In `Sources/AINotebookCore/Localization.swift` add to `enum Key` (after the existing settings block around line 113):

```swift
        case providersSectionTitle
        case addProviderButton
        case addProviderTitle
        case editProviderTitle
        case providerTypeLabel
        case providerNameLabel
        case providerUrlLabel
        case providerApiKeyLabel
        case providerKeySavedLabel
        case providerTestButton
        case providerTestSuccess
        case providerDeleteButton
        case providerDeleteConfirm
        case chatProviderPickerLabel
        case embeddingProviderPickerLabel
        case customModelFieldLabel
        case providerBadgeChat
        case providerBadgeEmbedding
        case privacyGateTitle
        case privacyGateMessage
        case privacyGateAccept
        case errorInvalidApiKey
        case errorRateLimited
        case errorModelRefusal
        case modelsUnavailableCaption
        case doneButton
```

Add to `english(_:)` (implicit-return switch rows, match surrounding style):

```swift
        case .providersSectionTitle:        "AI providers"
        case .addProviderButton:            "Add provider…"
        case .addProviderTitle:             "Add provider"
        case .editProviderTitle:            "Edit provider"
        case .providerTypeLabel:            "Type"
        case .providerNameLabel:            "Name"
        case .providerUrlLabel:             "Base URL"
        case .providerApiKeyLabel:          "API key"
        case .providerKeySavedLabel:        "Key saved ✓ — paste to replace"
        case .providerTestButton:           "Test connection"
        case .providerTestSuccess:          "Connection OK"
        case .providerDeleteButton:         "Delete provider"
        case .providerDeleteConfirm:        "Delete this provider? Its API key will be removed from the Keychain."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Embedding provider"
        case .customModelFieldLabel:        "Custom model ID"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "embeddings"
        case .privacyGateTitle:             "Send data to this provider?"
        case .privacyGateMessage:           "Chat questions and the source/note excerpts selected as context will be sent to this provider's server. Your database and local embeddings stay on this Mac."
        case .privacyGateAccept:            "Enable provider"
        case .errorInvalidApiKey:           "Invalid API key"
        case .errorRateLimited:             "Too many requests (429)"
        case .errorModelRefusal:            "The model declined to answer"
        case .modelsUnavailableCaption:     "Models unavailable — start Ollama or refresh in Manage models."
        case .doneButton:                   "Done"
```

Add to `czech(_:)`:

```swift
        case .providersSectionTitle:        "AI provideři"
        case .addProviderButton:            "Přidat providera…"
        case .addProviderTitle:             "Přidat providera"
        case .editProviderTitle:            "Upravit providera"
        case .providerTypeLabel:            "Typ"
        case .providerNameLabel:            "Název"
        case .providerUrlLabel:             "Base URL"
        case .providerApiKeyLabel:          "API klíč"
        case .providerKeySavedLabel:        "Klíč uložen ✓ — vložením nahradíte"
        case .providerTestButton:           "Otestovat připojení"
        case .providerTestSuccess:          "Připojení OK"
        case .providerDeleteButton:         "Smazat providera"
        case .providerDeleteConfirm:        "Smazat tohoto providera? Jeho API klíč bude odstraněn z Klíčenky."
        case .chatProviderPickerLabel:      "Chat provider"
        case .embeddingProviderPickerLabel: "Provider pro vektorizaci"
        case .customModelFieldLabel:        "Vlastní ID modelu"
        case .providerBadgeChat:            "chat"
        case .providerBadgeEmbedding:       "vektorizace"
        case .privacyGateTitle:             "Odesílat data tomuto providerovi?"
        case .privacyGateMessage:           "Dotazy v chatu a úryvky zdrojů/poznámek vybrané jako kontext budou odesílány na server tohoto providera. Vaše databáze a lokální vektorizace zůstávají na tomto Macu."
        case .privacyGateAccept:            "Povolit providera"
        case .errorInvalidApiKey:           "Neplatný API klíč"
        case .errorRateLimited:             "Příliš mnoho požadavků (429)"
        case .errorModelRefusal:            "Model odmítl odpovědět"
        case .modelsUnavailableCaption:     "Modely nedostupné — spusťte Ollamu nebo obnovte ve Správě modelů."
        case .doneButton:                   "Hotovo"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter LocalizationTests`
Expected: PASS (existing parity loops + the new bilingual test).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/Localization.swift \
        Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(mac): localization keys for provider registry UI (EN + CZ)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 11: `AppSettings` provider keys + composition-root wiring

**Files:**
- Modify: `Sources/AINotebookCore/AppSettings.swift`
- Modify: `Sources/AINotebookApp/AINotebookApp.swift` (init + a new holder + environment injection)
- Modify: `Sources/AINotebookApp/ChatView.swift:34-35` (`makeFollowupSuggester`)
- Modify: `Sources/AINotebookApp/SourceListView.swift:21-22` (`makeSummarizer`)
- Test: extend `Tests/AINotebookCoreTests/AppSettingsTests.swift`

**Interfaces:**
- Consumes: `ProviderSettingsKeys`, `DefaultsProviderSelection`, `ProviderRouter`, `KeychainSecretStore` (Tasks 3, 8); `Embedder`/`Retriever` `modelKey:` inits (Task 9).
- Produces: `AppSettings.selectedChatProviderId` / `selectedEmbeddingProviderId` (`@Published`, UserDefaults-backed via the SHARED `ProviderSettingsKeys` constants, default `ProviderConfig.ollamaId`); `@MainActor final class ProviderRouterHolder: ObservableObject { let router: ProviderRouter; let selection: DefaultsProviderSelection; let secrets: any SecretStoring }` injected as an environment object. All engines now stream through the router. `OllamaClient` stays wired for onboarding + model management only.

- [ ] **Step 1: Write the failing AppSettings tests**

Append to `Tests/AINotebookCoreTests/AppSettingsTests.swift` (reuse its `makeSuite` helper):

```swift
    func testProviderSelectionDefaultsToBuiltInOllama() {
        let defaults = makeSuite("test.providers.\(UUID().uuidString)")
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(settings.selectedChatProviderId, ProviderConfig.ollamaId)
        XCTAssertEqual(settings.selectedEmbeddingProviderId, ProviderConfig.ollamaId)
    }

    func testProviderSelectionPersistsThroughSharedKeys() {
        let name = "test.providers.persist.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        settings.selectedChatProviderId = "prov-1"
        settings.selectedChatModel = "gpt-4o"
        // The router-side reader must observe the same values immediately.
        let selection = DefaultsProviderSelection(defaults: defaults)
        XCTAssertEqual(selection.chatSelection().providerId, "prov-1")
        XCTAssertEqual(selection.chatSelection().model, "gpt-4o")
        // And a fresh AppSettings re-reads them.
        let reloaded = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(reloaded.selectedChatProviderId, "prov-1")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AppSettingsTests`
Expected: FAIL — `AppSettings` has no `selectedChatProviderId`.

- [ ] **Step 3: Implement AppSettings**

In `Sources/AINotebookCore/AppSettings.swift`:
1. Replace the two model-key literals in the private `Keys` enum with the shared constants and add the provider keys:

```swift
    private enum Keys {
        static let language = "language"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let selectedChatModel = ProviderSettingsKeys.chatModel
        static let selectedEmbeddingModel = ProviderSettingsKeys.embeddingModel
        static let selectedChatProviderId = ProviderSettingsKeys.chatProviderId
        static let selectedEmbeddingProviderId = ProviderSettingsKeys.embeddingProviderId
    }
```

2. Add the published properties (below `selectedEmbeddingModel`):

```swift
    @Published public var selectedChatProviderId: String {
        didSet { defaults.set(selectedChatProviderId, forKey: Keys.selectedChatProviderId) }
    }

    @Published public var selectedEmbeddingProviderId: String {
        didSet { defaults.set(selectedEmbeddingProviderId, forKey: Keys.selectedEmbeddingProviderId) }
    }
```

3. Initialize them in `init` (after the model lines):

```swift
        self.selectedChatProviderId =
            defaults.string(forKey: Keys.selectedChatProviderId) ?? ProviderConfig.ollamaId
        self.selectedEmbeddingProviderId =
            defaults.string(forKey: Keys.selectedEmbeddingProviderId) ?? ProviderConfig.ollamaId
```

- [ ] **Step 4: Wire the composition root**

In `Sources/AINotebookApp/AINotebookApp.swift`:

1. After the `OllamaClientHolder` line in `init()`, build the registry stack:

```swift
    let secrets = KeychainSecretStore()
    let selection = DefaultsProviderSelection()
    let router = ProviderRouter(store: store, secrets: secrets, selection: selection)
    _routerHolder = StateObject(wrappedValue: ProviderRouterHolder(
        router: router, selection: selection, secrets: secrets
    ))
```

2. Route the engines through the router and the live embedding key (the passed model strings are launch-time snapshots the router ignores; the `modelKey` closure is what stays live):

```swift
    let embedder = Embedder(
        store: store,
        client: router,
        modelKey: { selection.embeddingKey() }
    )
    // … EmbeddingWorker/IngestionService/NoteIndexer lines unchanged …

    let retriever = Retriever(
        store: store,
        client: router,
        modelKey: { selection.embeddingKey() }
    )
    let engine = ChatEngine(
        store: store,
        retriever: retriever,
        chat: router,
        chatModel: settings.selectedChatModel
    )
    // …
    let txEngine = TransformationEngine(
        store: store, chat: router, chatModel: settings.selectedChatModel
    )
```

3. Declare the holder property alongside the other `@StateObject`s, add the holder class next to `OllamaClientHolder` (bottom of the file), and inject `.environmentObject(routerHolder)` in `body` with the others:

```swift
    @StateObject private var routerHolder: ProviderRouterHolder
```

```swift
@MainActor
final class ProviderRouterHolder: ObservableObject {
    let router: ProviderRouter
    let selection: DefaultsProviderSelection
    let secrets: any SecretStoring
    init(router: ProviderRouter, selection: DefaultsProviderSelection, secrets: any SecretStoring) {
        self.router = router
        self.selection = selection
        self.secrets = secrets
    }
}
```

4. `OnboardingViewModel(client: client, settings: settings)` and the ollama holder stay exactly as they are (FR-A12).

- [ ] **Step 5: Route the two per-view factories through the router**

`Sources/AINotebookApp/ChatView.swift` — add `@EnvironmentObject private var routerHolder: ProviderRouterHolder` and change:

```swift
    private func makeFollowupSuggester() -> FollowupSuggester {
        FollowupSuggester(chat: routerHolder.router, chatModel: settings.selectedChatModel)
    }
```

`Sources/AINotebookApp/SourceListView.swift` — same pattern:

```swift
    private func makeSummarizer() -> SourceSummarizer {
        SourceSummarizer(store: store, chat: routerHolder.router, chatModel: settings.selectedChatModel)
    }
```

- [ ] **Step 6: Build + full suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests green. (Behavior with the default selection is unchanged: router → built-in Ollama row → same endpoints as before.)

- [ ] **Step 7: Commit**

```bash
git add Sources/AINotebookCore/AppSettings.swift \
        Sources/AINotebookApp/AINotebookApp.swift \
        Sources/AINotebookApp/ChatView.swift \
        Sources/AINotebookApp/SourceListView.swift \
        Tests/AINotebookCoreTests/AppSettingsTests.swift
git commit -m "feat(mac): wire engines through ProviderRouter with live selection

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 12: Settings UI — providers section, add/edit sheet, privacy gate, two-level pickers

**Files:**
- Create: `Sources/AINotebookApp/AddProviderSheet.swift`
- Create: `Sources/AINotebookApp/ProviderErrorText.swift`
- Modify: `Sources/AINotebookApp/ChatView.swift` (localized provider errors in the chat error row — exact site located by grep, see Step 2b)
- Modify: `Sources/AINotebookApp/SettingsView.swift` (providers section + two-level pickers + custom-model fields + re-embed confirm on embedding change + the two hardcoded strings)

**Interfaces:**
- Consumes: `ProviderRouterHolder` (Task 11), `NotebookStore` provider CRUD (Task 2), localization keys (Task 10), `router.listModels`/`testConnection`, `ProviderError`.
- Produces: user-facing registry per spec §5.2.8. No new Core symbols.

- [ ] **Step 1: Create the add/edit sheet**

Create `Sources/AINotebookApp/AddProviderSheet.swift`:

```swift
import SwiftUI
import AINotebookCore

/// Add/edit one provider. Presented from SettingsView.
/// Privacy gate (FR-A8): saving a NEW cloud/network provider first shows a
/// consent alert; consent is recorded via acknowledgePrivacy regardless of
/// whether a key was entered (keyless OpenWebUI instances still send data).
struct AddProviderSheet: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var routerHolder: ProviderRouterHolder
    @Environment(\.dismiss) private var dismiss

    /// nil = add mode; non-nil = edit mode.
    let existing: ProviderConfig?
    var onSaved: () -> Void

    @State private var type: ProviderType = .openwebui
    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var hadStoredKey = false
    @State private var testResult: String?
    @State private var testSucceeded = false
    @State private var isTesting = false
    @State private var showingPrivacyGate = false
    @State private var showingDeleteConfirm = false

    private var text: AppText { settings.text }
    private var isEdit: Bool { existing != nil }
    private var isBuiltInOllama: Bool { existing?.isBuiltInOllama == true }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text.string(isEdit ? .editProviderTitle : .addProviderTitle))
                .font(.title2).bold()

            Picker(text.string(.providerTypeLabel), selection: $type) {
                ForEach(ProviderType.allCases, id: \.self) { t in
                    Text(displayName(for: t)).tag(t)
                }
            }
            .disabled(isBuiltInOllama)
            .onChange(of: type) { _, newType in
                if baseURL.isEmpty || ProviderType.allCases.map(\.defaultBaseURL).contains(baseURL) {
                    baseURL = newType.defaultBaseURL
                }
                testResult = nil
                testSucceeded = false
            }

            TextField(text.string(.providerNameLabel), text: $name)
            TextField(text.string(.providerUrlLabel), text: $baseURL)

            if type != .ollama {
                SecureField(
                    hadStoredKey ? text.string(.providerKeySavedLabel) : text.string(.providerApiKeyLabel),
                    text: $apiKey
                )
            }

            HStack {
                Button(text.string(.providerTestButton)) {
                    Task { await runTest() }
                }
                .disabled(isTesting || baseURL.isEmpty)
                if isTesting { ProgressView().controlSize(.small) }
                if testSucceeded {
                    Label(text.string(.providerTestSuccess), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else if let testResult {
                    Text(testResult).foregroundStyle(.red).font(.caption)
                }
            }

            Spacer()

            HStack {
                if isEdit && !isBuiltInOllama {
                    Button(text.string(.providerDeleteButton), role: .destructive) {
                        showingDeleteConfirm = true
                    }
                }
                Spacer()
                Button(text.string(.cancel)) { dismiss() }
                Button(text.string(.save)) { saveTapped() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460, height: 340)
        .onAppear(perform: populate)
        .alert(text.string(.privacyGateTitle), isPresented: $showingPrivacyGate) {
            Button(text.string(.privacyGateAccept)) { persist(acknowledge: true) }
            Button(text.string(.cancel), role: .cancel) {}
        } message: {
            Text(text.string(.privacyGateMessage))
        }
        .confirmationDialog(
            text.string(.providerDeleteConfirm),
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(text.string(.delete), role: .destructive) { deleteProvider() }
        }
    }

    private func displayName(for t: ProviderType) -> String {
        switch t {
        case .ollama: "Ollama (local)"
        case .anthropic: "Anthropic (Claude)"
        case .openai: "OpenAI (ChatGPT)"
        case .openaiCompatible: "OpenAI-compatible"
        case .openwebui: "OpenWebUI (network)"
        }
    }

    private func populate() {
        guard let existing else {
            baseURL = type.defaultBaseURL
            return
        }
        type = existing.type
        name = existing.name
        baseURL = existing.baseURL
        hadStoredKey = ((try? routerHolder.secrets.load(providerId: existing.id)) ?? nil) != nil
        // The stored key is never loaded back into the field (FR-A7).
    }

    private func runTest() async {
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        testSucceeded = false
        let keyForTest: String? = {
            if !apiKey.isEmpty { return apiKey }
            if let existing { return (try? routerHolder.secrets.load(providerId: existing.id)) ?? nil }
            return nil
        }()
        if let error = await routerHolder.router.testConnection(
            type: type, baseURL: baseURL.trimmingCharacters(in: .whitespaces), apiKey: keyForTest
        ) {
            testResult = friendlyMessage(for: error)
        } else {
            testSucceeded = true
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let pe = error as? ProviderError {
            switch pe {
            case .auth: return text.string(.errorInvalidApiKey)
            case .rateLimit: return text.string(.errorRateLimited)
            case .refusal: return text.string(.errorModelRefusal)
            case .http(let code, _): return "HTTP \(code)"
            case .decoding(let message): return message
            }
        }
        return error.localizedDescription
    }

    private func saveTapped() {
        // Consent gate (FR-A8): fires for a NEW cloud/network provider and
        // ALSO when an existing provider's type changes to a cloud/network
        // type — the stored consent belonged to the previous type and must
        // not silently carry over (plan-verification finding).
        let typeChanged = existing.map { $0.type != type } ?? true
        if type.isCloud && typeChanged {
            showingPrivacyGate = true
        } else {
            persist(acknowledge: false)
        }
    }

    private func persist(acknowledge: Bool) {
        let cfg = ProviderConfig(
            id: existing?.id ?? UUID().uuidString,
            type: type,
            name: name.trimmingCharacters(in: .whitespaces),
            baseURL: baseURL.trimmingCharacters(in: .whitespaces),
            enabled: true,
            privacyAcknowledged: false,   // saveProvider never clobbers it; see acknowledgePrivacy below
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            try store.saveProvider(cfg)
            if acknowledge {
                try store.acknowledgePrivacy(providerId: cfg.id)
            }
            if type != .ollama && !apiKey.isEmpty {
                try routerHolder.secrets.save(providerId: cfg.id, secret: apiKey)
            }
            onSaved()
            dismiss()
        } catch {
            testResult = String(describing: error)
        }
    }

    private func deleteProvider() {
        guard let existing, !existing.isBuiltInOllama else { return }
        do {
            try store.deleteProvider(id: existing.id)
            try routerHolder.secrets.delete(providerId: existing.id)
            // Selections pointing at the deleted provider fall back to Ollama.
            if settings.selectedChatProviderId == existing.id {
                settings.selectedChatProviderId = ProviderConfig.ollamaId
            }
            if settings.selectedEmbeddingProviderId == existing.id {
                settings.selectedEmbeddingProviderId = ProviderConfig.ollamaId
            }
            onSaved()
            dismiss()
        } catch {
            testResult = String(describing: error)
        }
    }
}
```

Adjustment rule: `.cancel`, `.save`, `.delete` `AppText.Key` cases are assumed to exist (LocalizationTests asserts `.cancel`/`.delete` today) — verify `.save` exists in `Localization.swift`; if not, add it in the Task 10 style (`"Save"` / `"Uložit"`) and note it.

- [ ] **Step 2: Rework SettingsView**

In `Sources/AINotebookApp/SettingsView.swift`:

1. Add environment + state:

```swift
    @EnvironmentObject private var routerHolder: ProviderRouterHolder

    @State private var providers: [ProviderConfig] = []
    @State private var chatModels: [ProviderModelInfo] = []
    @State private var embeddingModels: [ProviderModelInfo] = []
    @State private var editingProvider: ProviderConfig?
    @State private var showingAddProvider = false
    @State private var pendingEmbeddingChange: (providerId: String, model: String)?
    @State private var providerStatus: [String: Bool] = [:]   // id → reachable
```

2. Providers section (insert between the language picker and the model section):

```swift
            Divider()
            Text(settings.text.string(.providersSectionTitle)).font(.headline)
            ForEach(providers) { provider in
                HStack {
                    Circle()
                        .fill(statusColor(for: provider))
                        .frame(width: 8, height: 8)
                    Text(provider.name)
                    Text(provider.type.rawValue).font(.caption).foregroundStyle(.secondary)
                    if provider.id == settings.selectedChatProviderId {
                        Text(settings.text.string(.providerBadgeChat))
                            .font(.caption2).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                    if provider.id == settings.selectedEmbeddingProviderId {
                        Text(settings.text.string(.providerBadgeEmbedding))
                            .font(.caption2).padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    }
                    Spacer()
                    Button {
                        editingProvider = provider
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.plain)
                }
            }
            Button(settings.text.string(.addProviderButton)) { showingAddProvider = true }
```

3. Replace the two model `Picker`s with two-level pickers + custom-model fields. Chat:

```swift
            Picker(settings.text.string(.chatProviderPickerLabel), selection: $settings.selectedChatProviderId) {
                ForEach(providers) { p in
                    Text(p.name).tag(p.id)
                }
            }
            .onChange(of: settings.selectedChatProviderId) { _, _ in
                Task { await refreshChatModels() }
            }
            if !chatModels.isEmpty {
                Picker(settings.text.string(.chatModelPickerLabel), selection: $settings.selectedChatModel) {
                    ForEach(chatModels) { m in
                        Text(m.label).tag(m.id)
                    }
                    if !chatModels.contains(where: { $0.id == settings.selectedChatModel }) {
                        Text(settings.selectedChatModel).tag(settings.selectedChatModel)
                    }
                }
            }
            TextField(
                settings.text.string(.customModelFieldLabel),
                text: $settings.selectedChatModel
            )
            .font(.caption)
```

Embedding — same two-level shape bound to `$settings.selectedEmbeddingProviderId`/`$settings.selectedEmbeddingModel`, with two differences: the provider `ForEach` filters `providers.filter { $0.type.supportsEmbeddings }` (FR-A5 — anthropic and openwebui never appear), and both the provider picker's `.onChange` and the model picker route through the re-embed confirmation instead of applying silently:

```swift
            .onChange(of: settings.selectedEmbeddingProviderId) { old, new in
                guard old != new else { return }
                pendingEmbeddingChange = (new, settings.selectedEmbeddingModel)
                Task { await refreshEmbeddingModels() }
            }
```

and reuse the EXISTING re-embed `confirmationDialog` flow: when `pendingEmbeddingChange` is set, show the same confirm the re-embed button uses; on confirm call `reembedAll()`, on cancel restore the previous selection. Read the current dialog code (lines 65-77) and extend it rather than duplicating it.

4. Update `reembedAll()` to the composite key (FR-A11):

```swift
    private func reembedAll() async {
        do {
            try store.deleteAllEmbeddings(model: routerHolder.selection.embeddingKey())
            await embedderHolder.worker.kick()
        } catch {
            settingsError = String(describing: error)
        }
    }
```

5. Model refresh via the router (replaces `refreshModels()`'s direct `ollama.client.listModels()`):

```swift
    private func refreshProviders() {
        providers = (try? store.providers()) ?? []
        Task { await refreshProviderStatus() }
    }

    /// Spec §5.2.8 status dot: ● green reachable / ● red error / gray
    /// disabled-or-unknown. Probes run in the background; the row renders
    /// gray until a result lands.
    private func statusColor(for provider: ProviderConfig) -> Color {
        guard provider.enabled else { return .gray }
        switch providerStatus[provider.id] {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private func refreshProviderStatus() async {
        for provider in providers {
            let key = (try? routerHolder.secrets.load(providerId: provider.id)) ?? nil
            let error = await routerHolder.router.testConnection(
                type: provider.type, baseURL: provider.baseURL, apiKey: key)
            providerStatus[provider.id] = (error == nil)
        }
    }

    private func refreshChatModels() async {
        chatModels = await routerHolder.router.listModels(providerId: settings.selectedChatProviderId)
    }

    private func refreshEmbeddingModels() async {
        embeddingModels = await routerHolder.router.listModels(providerId: settings.selectedEmbeddingProviderId)
    }
```

Call `refreshProviders()` + both refreshes from the existing `.task { }` and after sheet dismissals.

6. Wire the sheets:

```swift
        .sheet(isPresented: $showingAddProvider, onDismiss: { refreshProviders() }) {
            AddProviderSheet(existing: nil, onSaved: { refreshProviders() })
        }
        .sheet(item: $editingProvider, onDismiss: { refreshProviders() }) { provider in
            AddProviderSheet(existing: provider, onSaved: { refreshProviders() })
        }
```

7. Replace the two hardcoded strings: line 48's caption → `settings.text.string(.modelsUnavailableCaption)`; line 104's `Button("Done")` → `Button(settings.text.string(.doneButton))`.

- [ ] **Step 2b: Localized provider errors in the chat error row (spec §6)**

Create `Sources/AINotebookApp/ProviderErrorText.swift`:

```swift
import AINotebookCore

/// Maps wire-level provider failures to localized user-facing text.
/// Used by the chat error row and the Add-provider sheet's Test button.
func providerErrorText(_ error: Error, text: AppText) -> String {
    if let pe = error as? ProviderError {
        switch pe {
        case .auth: return text.string(.errorInvalidApiKey)
        case .rateLimit: return text.string(.errorRateLimited)
        case .refusal: return text.string(.errorModelRefusal)
        case .http(let code, _): return "HTTP \(code)"
        case .decoding(let message): return message
        }
    }
    return error.localizedDescription
}
```

Then (a) replace `AddProviderSheet.friendlyMessage(for:)`'s body with `providerErrorText(error, text: text)` (delete the private helper), and (b) find the chat error display: grep `Sources/AINotebookApp/ChatView.swift` (and `NotesChatPanel.swift`) for the `catch` around the `engine.send(...)` call and route the message it renders through `providerErrorText(error, text: settings.text)` instead of the raw error description. Mirror however the existing code formats the error row — only the string source changes. Document the exact call sites you touched.

- [ ] **Step 3: Build + full suite**

Run: `swift build && swift test`
Expected: build succeeds, all tests green (SwiftUI views have no unit tests in this repo — the App target has no test target; correctness is covered by the Core tests plus Step 4).

- [ ] **Step 4: Manual smoke check (local app run)**

```bash
swift run AINotebookApp
```

Verify: Settings opens → "AI providers" lists "Ollama (local)" with a status dot (green when Ollama runs) and a "chat"/"embeddings" badge on the selected provider → Add provider (type OpenWebUI, bogus URL `http://127.0.0.1:9`) → "Test connection" reports an error (NOT success) → save triggers the privacy alert → provider appears in the list and in the chat-provider picker → switching chat provider back to Ollama keeps chat working → embedding provider picker does NOT offer the OpenWebUI entry → edit the OpenWebUI provider and switch its type to "Anthropic (Claude)" → saving triggers the privacy gate AGAIN (consent does not carry across type changes) → Done. Report what you saw honestly; screenshots not required.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookApp/AddProviderSheet.swift \
        Sources/AINotebookApp/ProviderErrorText.swift \
        Sources/AINotebookApp/SettingsView.swift \
        Sources/AINotebookApp/ChatView.swift
git commit -m "feat(mac): provider registry Settings UI with privacy gate and two-level pickers

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 13: Finalize — full verification, docs, push, CI

**Files:**
- Modify: `CHANGELOG.md` (extend the `[Unreleased]` section added by Phase 1)
- Modify: `README.md` (platform/provider table + privacy line)

- [ ] **Step 1: Full local verification**

```bash
swift build 2>&1 | tail -3
swift test --parallel 2>&1 | tail -3
OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v -e '/OllamaClient.swift$' -e '/WebExtractor.swift$' -e '/Providers/' || true); [ -z "$OFFENDERS" ] && echo "GATE OK" || echo "GATE FAIL: $OFFENDERS"
grep -rn "sk-" Sources/ --include='*.swift' | grep -v -i "test\|mock\|fixture" || echo "NO KEY LITERALS"
```

Expected: build clean, all tests pass, `GATE OK`, `NO KEY LITERALS`.

- [ ] **Step 2: CHANGELOG**

In `CHANGELOG.md`, extend the `[Unreleased]` → `### Added` section (below the Windows OpenWebUI entry). If `[Unreleased]` does not exist on this branch yet (Phase 1's PR #2 not merged when the branch was cut), create the section at the top of the file (`## [Unreleased]` + `### Added`):

```markdown
- macOS: full AI provider registry — connect Anthropic (Claude), OpenAI
  (ChatGPT), any OpenAI-compatible server (LM Studio, OpenRouter, vLLM), or
  an OpenWebUI server on your network, alongside local Ollama. Per-role
  provider + model selection for chat and embeddings, connection test,
  privacy consent gate, and API keys stored in the macOS Keychain — never in
  the database. Embedding vectors are now keyed by provider + model on both
  platforms, and provider/model switches apply immediately (no relaunch).
```

- [ ] **Step 3: README**

Update the platform table row and the privacy line that currently say macOS is Ollama-only:
- Table: `| **macOS** 14+ | Swift 6 · SwiftUI | Ollama (local) · Anthropic · OpenAI · any OpenAI-compatible endpoint · OpenWebUI |` and extend the Windows row's provider list with `· OpenWebUI`.
- Prose: replace "On macOS the AI is local-only (Ollama)." with "Both platforms stay local-first with Ollama, and can optionally connect a cloud provider (Anthropic, OpenAI) or a network server (OpenWebUI, LM Studio) when you want a stronger model."

Read the surrounding README text and keep its voice; adjust any other now-false "macOS is local-only" claims you find (grep for "local-only" and "Ollama (local only)").

- [ ] **Step 4: Commit + push + CI**

```bash
git add CHANGELOG.md README.md
git commit -m "docs: changelog + README for macOS provider registry

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin feat/provider-registry-macos
```

core-ci's `push` trigger fires for `main` only — a branch push starts nothing. Open the PR first (its `pull_request` trigger targets main), then watch that run:

```bash
gh pr create --base main --head feat/provider-registry-macos \
  --title "feat(mac): provider registry — Anthropic, OpenAI, OpenAI-compatible, OpenWebUI" \
  --body "macOS Epic A provider registry per docs/superpowers/specs/2026-07-08-openwebui-network-provider-design.md §5. Chat via cloud/network providers, embeddings via Ollama/OpenAI, Keychain-stored keys, privacy gate, live provider/model switching. Draft until the manual acceptance checklist passes." \
  --draft
sleep 10
gh run watch $(gh run list --branch feat/provider-registry-macos --workflow core-ci.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected: core-ci green (build-and-test + privacy-grep with the extended allowlist). windows-ci does not run for this branch (no `windows/` changes) — if it triggers anyway it must stay green (nothing under `windows/` was touched).

- [ ] **Step 5: Manual acceptance checklist (user, real environment)**

1. Launch the app; existing notebooks/chat/embeddings work unchanged (default = Ollama).
2. Add an OpenWebUI provider (real LAN URL + API key) → Test OK → privacy gate → pick one of its models as chat model → chat streams with `[N]` citations, follow-ups, transformations.
3. Quit + relaunch: key survives (Keychain), selection survives.
4. `sqlite3 ~/Library/Application\ Support/AINotebook/db.sqlite .dump | grep -i "sk-"` → no output (no key in DB).
5. Keychain Access.app shows a generic password, service `AINotebook`.
6. Switch embedding model → re-embed confirm → retrieval works after; switch back → works (vectors keyed per provider:model).
7. Optional: Anthropic/OpenAI key, LM Studio (openai_compatible) smoke test.

## Out of scope

Windows changes (Phase 1 shipped separately — PR #2); in-app update check; reading `privacy_acknowledged` for enforcement (flag is recorded correctly on macOS incl. keyless saves, but no code path reads it yet on either platform — parity with Windows; enforcement is a future cross-platform change).
