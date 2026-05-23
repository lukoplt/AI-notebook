# AI Notebook M2 — Ollama Client + Onboarding Wizard

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Detect a running Ollama daemon on `localhost:11434`, guide non-technical users through installing it and pulling the default chat + embedding models on first launch, then expose a typed Swift client for chat, embedding, and model management to later milestones.

**Architecture:** Add `OllamaClient` as a single Swift file in `AINotebookCore` that wraps `URLSession` calls to `http://127.0.0.1:11434`. Stream endpoints (`/api/pull`, `/api/chat`) emit one JSON line per chunk over `AsyncThrowingStream<Event, Error>`. Tests use a custom `URLProtocol` stub registered on a private `URLSessionConfiguration` so no real network is touched. The onboarding wizard is a four-step SwiftUI `OnboardingView` driven by an `OnboardingViewModel` that observes the client. A new `hasCompletedOnboarding` flag in `AppSettings` gates whether the wizard or the main `ContentView` is shown at launch.

**Tech Stack:** Swift 6.0, SwiftUI, URLSession (URLProtocol mocking for tests), JSON streaming over NDJSON, Ollama REST API.

**Branch:** `m2-ollama` (off `main`).

---

## File Structure

| Path | Purpose |
|---|---|
| `.github/workflows/core-ci.yml` | Modified: exclude `OllamaClient.swift` from the `URLSession` privacy grep. |
| `Sources/AINotebookCore/OllamaError.swift` | Typed errors: not reachable, http status, decoding, timeout, model not found. |
| `Sources/AINotebookCore/OllamaModel.swift` | `struct OllamaModel` + `OllamaModelList` matching `/api/tags`. |
| `Sources/AINotebookCore/OllamaPullEvent.swift` | `enum OllamaPullEvent` for one streamed chunk of `/api/pull`. |
| `Sources/AINotebookCore/OllamaChatTypes.swift` | `OllamaChatMessage`, `OllamaChatRequest`, `OllamaChatChunk`. |
| `Sources/AINotebookCore/OllamaEmbedTypes.swift` | `OllamaEmbedRequest`, `OllamaEmbedResponse`. |
| `Sources/AINotebookCore/OllamaClient.swift` | The only file allowed to import URLSession-network APIs. Detects daemon, lists models, pulls models (stream), embeds, chats (stream). |
| `Sources/AINotebookCore/AppSettings.swift` | Modified: add `hasCompletedOnboarding`, `selectedChatModel`, `selectedEmbeddingModel`. |
| `Sources/AINotebookCore/Localization.swift` | Modified: add ~25 new keys for onboarding UI. |
| `Sources/AINotebookApp/Onboarding/OnboardingStep.swift` | Enum: `welcome`, `detectOllama`, `pickModels`, `pullModels`, `done`. |
| `Sources/AINotebookApp/Onboarding/OnboardingViewModel.swift` | `@MainActor` `ObservableObject` orchestrating state transitions + progress. |
| `Sources/AINotebookApp/Onboarding/OnboardingView.swift` | Container view that dispatches to the per-step subview. |
| `Sources/AINotebookApp/Onboarding/WelcomeStepView.swift` | Single welcome screen. |
| `Sources/AINotebookApp/Onboarding/DetectOllamaStepView.swift` | Detection + install link + poll. |
| `Sources/AINotebookApp/Onboarding/PickModelsStepView.swift` | Two pickers + defaults + advanced override. |
| `Sources/AINotebookApp/Onboarding/PullModelsStepView.swift` | Dual progress bars while pulling. |
| `Sources/AINotebookApp/Onboarding/DoneStepView.swift` | Confirmation + Continue button. |
| `Sources/AINotebookApp/AINotebookApp.swift` | Modified: inject `OllamaClient`. |
| `Sources/AINotebookApp/ContentView.swift` | Modified: show `OnboardingView` until `hasCompletedOnboarding` flips. |
| `Tests/AINotebookCoreTests/OllamaClientTests.swift` | URLProtocol-stubbed integration tests for detect, list, pull stream, embed, chat stream. |
| `Tests/AINotebookCoreTests/StubURLProtocol.swift` | Helper: a `URLProtocol` subclass that returns canned responses + chunked streams. |

---

## Task 1: Branch + CI gate exclusion

**Files:**
- Create branch `m2-ollama`
- Modify: `.github/workflows/core-ci.yml`

- [ ] **Step 1: Branch off main**

```bash
cd /Users/lukasoplt/Documents/AI_Notebook
git checkout main
git pull --ff-only || true
git checkout -b m2-ollama
```

- [ ] **Step 2: Update the privacy grep step**

Open `/Users/lukasoplt/Documents/AI_Notebook/.github/workflows/core-ci.yml` and replace the privacy-grep step's `run:` block with this exact block:

```yaml
      - name: Forbid URLSession in AINotebookCore except OllamaClient
        # OllamaClient is the only file allowed to talk to the network.
        # Every other Core file must stay offline.
        run: |
          OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v '/OllamaClient.swift$' || true)
          if [ -n "$OFFENDERS" ]; then
            echo "::error::URLSession found outside OllamaClient.swift:"
            echo "$OFFENDERS"
            exit 1
          fi
          echo "OK: URLSession only present in OllamaClient.swift."
```

- [ ] **Step 3: Sanity-check the new grep locally**

Run:
```bash
OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v '/OllamaClient.swift$' || true)
echo "OFFENDERS=$OFFENDERS"
```
Expected: `OFFENDERS=` (empty — no Core file uses URLSession yet, OllamaClient doesn't exist yet so the exclusion is vacuously OK).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/core-ci.yml
git commit -m "ci: exclude OllamaClient.swift from URLSession privacy gate"
```

---

## Task 2: `OllamaError` enum

**Files:**
- Create: `Sources/AINotebookCore/OllamaError.swift`

- [ ] **Step 1: Write the file**

Create `Sources/AINotebookCore/OllamaError.swift`:

```swift
import Foundation

public enum OllamaError: Error, Equatable, Sendable {
    case notReachable                       // socket refused / DNS / general I/O
    case timeout
    case httpStatus(code: Int, body: String)
    case decoding(message: String)
    case modelNotFound(name: String)
    case unexpectedEndOfStream
    case cancelled
}

extension OllamaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notReachable:
            "Ollama daemon is not reachable on localhost:11434."
        case .timeout:
            "Ollama request timed out."
        case .httpStatus(let code, _):
            "Ollama returned HTTP \(code)."
        case .decoding(let message):
            "Failed to decode Ollama response: \(message)."
        case .modelNotFound(let name):
            "Ollama model \"\(name)\" is not pulled."
        case .unexpectedEndOfStream:
            "Ollama stream ended before completion."
        case .cancelled:
            "Ollama request was cancelled."
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
swift build --target AINotebookCore
```
Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/AINotebookCore/OllamaError.swift
git commit -m "feat(core): add OllamaError"
```

---

## Task 3: `OllamaModel` + `OllamaModelList` data types

**Files:**
- Create: `Sources/AINotebookCore/OllamaModel.swift`
- Create: `Tests/AINotebookCoreTests/OllamaModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/AINotebookCoreTests/OllamaModelTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaModelTests: XCTestCase {
    func testDecodesTagListPayload() throws {
        let json = """
        {
          "models": [
            {
              "name": "llama3.2:3b",
              "modified_at": "2024-09-25T12:00:00Z",
              "size": 2019377664,
              "digest": "abc123",
              "details": {
                "format": "gguf",
                "family": "llama",
                "parameter_size": "3B",
                "quantization_level": "Q4_K_M"
              }
            }
          ]
        }
        """.data(using: .utf8)!

        let list = try JSONDecoder().decode(OllamaModelList.self, from: json)
        XCTAssertEqual(list.models.count, 1)
        let model = list.models[0]
        XCTAssertEqual(model.name, "llama3.2:3b")
        XCTAssertEqual(model.size, 2_019_377_664)
        XCTAssertEqual(model.digest, "abc123")
        XCTAssertEqual(model.details.parameterSize, "3B")
    }

    func testEmptyListDecodes() throws {
        let json = """
        { "models": [] }
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode(OllamaModelList.self, from: json)
        XCTAssertTrue(list.models.isEmpty)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaModelTests
```
Expected: FAIL — `OllamaModelList` undefined.

- [ ] **Step 3: Implementation**

Create `Sources/AINotebookCore/OllamaModel.swift`:

```swift
import Foundation

public struct OllamaModel: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let modifiedAt: String
    public let size: Int64
    public let digest: String
    public let details: Details

    public struct Details: Codable, Equatable, Hashable, Sendable {
        public let format: String?
        public let family: String?
        public let parameterSize: String?
        public let quantizationLevel: String?

        enum CodingKeys: String, CodingKey {
            case format
            case family
            case parameterSize = "parameter_size"
            case quantizationLevel = "quantization_level"
        }
    }

    enum CodingKeys: String, CodingKey {
        case name
        case modifiedAt = "modified_at"
        case size
        case digest
        case details
    }
}

public struct OllamaModelList: Codable, Equatable, Sendable {
    public let models: [OllamaModel]
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaModelTests
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaModel.swift Tests/AINotebookCoreTests/OllamaModelTests.swift
git commit -m "feat(core): add OllamaModel + OllamaModelList decoding"
```

---

## Task 4: `OllamaPullEvent`

**Files:**
- Create: `Sources/AINotebookCore/OllamaPullEvent.swift`
- Create: `Tests/AINotebookCoreTests/OllamaPullEventTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaPullEventTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaPullEventTests: XCTestCase {
    func testDecodeStartStatus() throws {
        let json = #"{"status":"pulling manifest"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertEqual(event.status, "pulling manifest")
        XCTAssertNil(event.total)
        XCTAssertNil(event.completed)
        XCTAssertNil(event.digest)
    }

    func testDecodeProgressEvent() throws {
        let json = """
        {"status":"downloading","digest":"sha256:abc","total":2019377664,"completed":1000000}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertEqual(event.status, "downloading")
        XCTAssertEqual(event.digest, "sha256:abc")
        XCTAssertEqual(event.total, 2_019_377_664)
        XCTAssertEqual(event.completed, 1_000_000)
        XCTAssertEqual(event.fractionComplete, 1_000_000.0 / 2_019_377_664.0, accuracy: 1e-9)
    }

    func testFractionCompleteIsNilWhenMissing() throws {
        let json = #"{"status":"verifying"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(OllamaPullEvent.self, from: json)
        XCTAssertNil(event.fractionComplete)
    }

    func testIsTerminalSuccess() {
        let success = OllamaPullEvent(status: "success", digest: nil, total: nil, completed: nil)
        XCTAssertTrue(success.isTerminalSuccess)

        let mid = OllamaPullEvent(status: "downloading", digest: nil, total: 100, completed: 50)
        XCTAssertFalse(mid.isTerminalSuccess)
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaPullEventTests
```
Expected: FAIL.

- [ ] **Step 3: Implementation**

Create `Sources/AINotebookCore/OllamaPullEvent.swift`:

```swift
import Foundation

public struct OllamaPullEvent: Codable, Equatable, Sendable {
    public let status: String
    public let digest: String?
    public let total: Int64?
    public let completed: Int64?

    public init(status: String, digest: String? = nil, total: Int64? = nil, completed: Int64? = nil) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
    }

    /// 0.0…1.0 download progress for the current digest, or nil if the
    /// event doesn't carry both `total` and `completed`.
    public var fractionComplete: Double? {
        guard let total, let completed, total > 0 else { return nil }
        return Double(completed) / Double(total)
    }

    /// Ollama emits `{"status":"success"}` as the terminal frame of a
    /// successful pull.
    public var isTerminalSuccess: Bool {
        status == "success"
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaPullEventTests
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaPullEvent.swift Tests/AINotebookCoreTests/OllamaPullEventTests.swift
git commit -m "feat(core): add OllamaPullEvent streaming type"
```

---

## Task 5: `OllamaChatTypes` + `OllamaEmbedTypes`

**Files:**
- Create: `Sources/AINotebookCore/OllamaChatTypes.swift`
- Create: `Sources/AINotebookCore/OllamaEmbedTypes.swift`
- Create: `Tests/AINotebookCoreTests/OllamaWireTypesTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaWireTypesTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaWireTypesTests: XCTestCase {
    func testChatRequestEncodes() throws {
        let req = OllamaChatRequest(
            model: "llama3.2:3b",
            messages: [
                OllamaChatMessage(role: .system, content: "You are helpful."),
                OllamaChatMessage(role: .user, content: "Hi.")
            ],
            stream: true,
            options: nil
        )
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "llama3.2:3b")
        XCTAssertEqual(json["stream"] as? Bool, true)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
    }

    func testChatChunkDecode() throws {
        let json = """
        {"model":"llama3.2:3b","created_at":"2024-09-25T12:00:00Z","message":{"role":"assistant","content":"Hi"},"done":false}
        """.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(OllamaChatChunk.self, from: json)
        XCTAssertEqual(chunk.message.content, "Hi")
        XCTAssertEqual(chunk.message.role, .assistant)
        XCTAssertFalse(chunk.done)
    }

    func testEmbedRequestEncodesArrayInput() throws {
        let req = OllamaEmbedRequest(model: "nomic-embed-text", input: ["a", "b"])
        let data = try JSONEncoder().encode(req)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["model"] as? String, "nomic-embed-text")
        XCTAssertEqual(json["input"] as? [String], ["a", "b"])
    }

    func testEmbedResponseDecodes() throws {
        let json = """
        {"embeddings":[[0.1,0.2,0.3],[0.4,0.5,0.6]]}
        """.data(using: .utf8)!
        let res = try JSONDecoder().decode(OllamaEmbedResponse.self, from: json)
        XCTAssertEqual(res.embeddings.count, 2)
        XCTAssertEqual(res.embeddings[0], [0.1, 0.2, 0.3])
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaWireTypesTests
```
Expected: FAIL.

- [ ] **Step 3: Implementation — `OllamaChatTypes.swift`**

Create `Sources/AINotebookCore/OllamaChatTypes.swift`:

```swift
import Foundation

public struct OllamaChatMessage: Codable, Equatable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

public struct OllamaChatRequest: Codable, Sendable {
    public let model: String
    public let messages: [OllamaChatMessage]
    public let stream: Bool
    public let options: Options?

    public struct Options: Codable, Sendable {
        public let temperature: Double?
        public let numCtx: Int?

        enum CodingKeys: String, CodingKey {
            case temperature
            case numCtx = "num_ctx"
        }

        public init(temperature: Double? = nil, numCtx: Int? = nil) {
            self.temperature = temperature
            self.numCtx = numCtx
        }
    }

    public init(
        model: String,
        messages: [OllamaChatMessage],
        stream: Bool = true,
        options: Options? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.options = options
    }
}

public struct OllamaChatChunk: Codable, Sendable {
    public let model: String
    public let createdAt: String
    public let message: OllamaChatMessage
    public let done: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message
        case done
    }
}
```

- [ ] **Step 4: Implementation — `OllamaEmbedTypes.swift`**

Create `Sources/AINotebookCore/OllamaEmbedTypes.swift`:

```swift
import Foundation

public struct OllamaEmbedRequest: Codable, Sendable {
    public let model: String
    public let input: [String]

    public init(model: String, input: [String]) {
        self.model = model
        self.input = input
    }
}

public struct OllamaEmbedResponse: Codable, Sendable {
    public let embeddings: [[Double]]
}
```

- [ ] **Step 5: Verify pass**

```bash
swift test --filter OllamaWireTypesTests
```
Expected: PASS, 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/OllamaChatTypes.swift Sources/AINotebookCore/OllamaEmbedTypes.swift Tests/AINotebookCoreTests/OllamaWireTypesTests.swift
git commit -m "feat(core): add Ollama chat + embed wire types"
```

---

## Task 6: `StubURLProtocol` test helper

**Files:**
- Create: `Tests/AINotebookCoreTests/StubURLProtocol.swift`

This is a test-only utility that lets us intercept `URLSession` requests with canned responses. Used by Task 7.

- [ ] **Step 1: Create the file**

Create `Tests/AINotebookCoreTests/StubURLProtocol.swift`:

```swift
import Foundation

/// Thread-safe queue of stubbed responses. Each `URLProtocol` start dequeues
/// one stub and serves it. Tests call `StubURLProtocol.enqueue(...)` before
/// invoking the client.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        let statusCode: Int
        let headers: [String: String]
        let bodyChunks: [Data]   // each chunk delivered as a separate `client?.urlProtocol(_:didLoad:)` call

        static func json(_ data: Data, status: Int = 200) -> Stub {
            Stub(
                statusCode: status,
                headers: ["Content-Type": "application/json"],
                bodyChunks: [data]
            )
        }

        static func ndjson(_ lines: [Data], status: Int = 200) -> Stub {
            Stub(
                statusCode: status,
                headers: ["Content-Type": "application/x-ndjson"],
                bodyChunks: lines.map { line in
                    var d = line
                    d.append(0x0A) // newline
                    return d
                }
            )
        }

        static func connectionRefused() -> Stub {
            Stub(statusCode: -1, headers: [:], bodyChunks: [])
        }
    }

    private static let lock = NSLock()
    private static var stubs: [Stub] = []

    static func enqueue(_ stub: Stub) {
        lock.lock(); defer { lock.unlock() }
        stubs.append(stub)
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        stubs.removeAll()
    }

    private static func dequeue() -> Stub? {
        lock.lock(); defer { lock.unlock() }
        return stubs.isEmpty ? nil : stubs.removeFirst()
    }

    /// Returns a `URLSessionConfiguration` whose only protocol is this stub.
    /// Pass this to `URLSession(configuration:)` in tests.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let stub = StubURLProtocol.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }

        if stub.statusCode == -1 {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.bodyChunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Build tests**

```bash
swift build --target AINotebookCoreTests
```
Expected: success. (Or `swift test --filter SomethingThatDoesNotExist` to invoke compile without running tests — either is fine.)

- [ ] **Step 3: Commit**

```bash
git add Tests/AINotebookCoreTests/StubURLProtocol.swift
git commit -m "test(core): add StubURLProtocol helper"
```

---

## Task 7: `OllamaClient` — detect + listModels

**Files:**
- Create: `Sources/AINotebookCore/OllamaClient.swift`
- Create: `Tests/AINotebookCoreTests/OllamaClientDetectAndListTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaClientDetectAndListTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaClientDetectAndListTests: XCTestCase {
    override func setUp() {
        StubURLProtocol.reset()
    }

    private func makeClient() -> OllamaClient {
        OllamaClient(session: StubURLProtocol.session())
    }

    func testDetectTrueOn200() async throws {
        StubURLProtocol.enqueue(.json(#"{"models":[]}"#.data(using: .utf8)!))
        let client = makeClient()
        let isUp = await client.detect()
        XCTAssertTrue(isUp)
    }

    func testDetectFalseOnConnectionRefused() async {
        StubURLProtocol.enqueue(.connectionRefused())
        let client = makeClient()
        let isUp = await client.detect()
        XCTAssertFalse(isUp)
    }

    func testListModelsReturnsParsedList() async throws {
        let json = #"{"models":[{"name":"llama3.2:3b","modified_at":"x","size":1,"digest":"d","details":{"format":"gguf","family":"llama","parameter_size":"3B","quantization_level":"Q4"}}]}"#
        StubURLProtocol.enqueue(.json(json.data(using: .utf8)!))
        let client = makeClient()
        let models = try await client.listModels()
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].name, "llama3.2:3b")
    }

    func testListModelsThrowsOnHttpError() async {
        StubURLProtocol.enqueue(.json(Data("oops".utf8), status: 500))
        let client = makeClient()
        do {
            _ = try await client.listModels()
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaClientDetectAndListTests
```
Expected: FAIL — `OllamaClient` undefined.

- [ ] **Step 3: Implementation**

Create `Sources/AINotebookCore/OllamaClient.swift`:

```swift
import Foundation

/// Typed wrapper around the Ollama HTTP API. Lives in `AINotebookCore`
/// and is the ONLY file in `AINotebookCore` allowed to import URLSession.
/// All other Core files stay offline (enforced by CI grep gate).
public final class OllamaClient: @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    /// Best-effort 1.5s probe of `/api/tags`. Returns `true` if reachable.
    public func detect(timeout: TimeInterval = 1.5) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = timeout
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// `GET /api/tags` — returns the locally-installed models.
    public func listModels() async throws -> [OllamaModel] {
        let url = baseURL.appendingPathComponent("api/tags")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let (data, response) = try await sendData(req)
        try ensureSuccess(response: response, body: data)
        do {
            let list = try decoder.decode(OllamaModelList.self, from: data)
            return list.models
        } catch {
            throw OllamaError.decoding(message: String(describing: error))
        }
    }

    // MARK: - Helpers

    private func sendData(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .timedOut { throw OllamaError.timeout }
            throw OllamaError.notReachable
        } catch {
            throw OllamaError.notReachable
        }
    }

    private func ensureSuccess(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.notReachable
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyString = String(data: body, encoding: .utf8) ?? ""
            throw OllamaError.httpStatus(code: http.statusCode, body: bodyString)
        }
    }
}
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaClientDetectAndListTests
```
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaClient.swift Tests/AINotebookCoreTests/OllamaClientDetectAndListTests.swift
git commit -m "feat(core): add OllamaClient with detect + listModels"
```

---

## Task 8: `OllamaClient.pullModel(...)` streaming

**Files:**
- Modify: `Sources/AINotebookCore/OllamaClient.swift`
- Create: `Tests/AINotebookCoreTests/OllamaClientPullTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaClientPullTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaClientPullTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testPullEmitsEventsThenCompletes() async throws {
        let lines: [Data] = [
            #"{"status":"pulling manifest"}"#.data(using: .utf8)!,
            #"{"status":"downloading","digest":"sha256:abc","total":1000,"completed":500}"#.data(using: .utf8)!,
            #"{"status":"downloading","digest":"sha256:abc","total":1000,"completed":1000}"#.data(using: .utf8)!,
            #"{"status":"success"}"#.data(using: .utf8)!
        ]
        StubURLProtocol.enqueue(.ndjson(lines))

        let client = OllamaClient(session: StubURLProtocol.session())
        var collected: [OllamaPullEvent] = []
        for try await event in client.pullModel(name: "llama3.2:3b") {
            collected.append(event)
        }
        XCTAssertEqual(collected.count, 4)
        XCTAssertEqual(collected[0].status, "pulling manifest")
        XCTAssertEqual(collected[3].status, "success")
        XCTAssertTrue(collected[3].isTerminalSuccess)
    }

    func testPullThrowsOnHttp500() async {
        StubURLProtocol.enqueue(.json(Data("nope".utf8), status: 500))
        let client = OllamaClient(session: StubURLProtocol.session())
        do {
            for try await _ in client.pullModel(name: "llama3.2:3b") {}
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaClientPullTests
```
Expected: FAIL — `pullModel` undefined.

- [ ] **Step 3: Implementation — append to `OllamaClient.swift`**

Add the following methods inside the `OllamaClient` class (just before the `// MARK: - Helpers` line):

```swift
    /// `POST /api/pull` — streams `OllamaPullEvent`s. Terminates when the
    /// server emits `{"status":"success"}` or closes the stream.
    public func pullModel(name: String) -> AsyncThrowingStream<OllamaPullEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/pull")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try encoder.encode(["name": name])

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 10_000 { break }
                        }
                        continuation.finish(throwing: OllamaError.httpStatus(
                            code: http.statusCode,
                            body: String(data: data, encoding: .utf8) ?? ""
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        do {
                            let event = try decoder.decode(OllamaPullEvent.self, from: lineData)
                            continuation.yield(event)
                            if event.isTerminalSuccess {
                                break
                            }
                        } catch {
                            continuation.finish(throwing: OllamaError.decoding(
                                message: String(describing: error)
                            ))
                            return
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    if urlError.code == .timedOut {
                        continuation.finish(throwing: OllamaError.timeout)
                    } else {
                        continuation.finish(throwing: OllamaError.notReachable)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaClientPullTests
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaClient.swift Tests/AINotebookCoreTests/OllamaClientPullTests.swift
git commit -m "feat(core): add OllamaClient.pullModel streaming"
```

---

## Task 9: `OllamaClient.embed(...)`

**Files:**
- Modify: `Sources/AINotebookCore/OllamaClient.swift`
- Create: `Tests/AINotebookCoreTests/OllamaClientEmbedTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaClientEmbedTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaClientEmbedTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testEmbedReturnsVectors() async throws {
        let body = #"{"embeddings":[[0.1,0.2],[0.3,0.4]]}"#
        StubURLProtocol.enqueue(.json(body.data(using: .utf8)!))
        let client = OllamaClient(session: StubURLProtocol.session())
        let vectors = try await client.embed(model: "nomic-embed-text", input: ["a", "b"])
        XCTAssertEqual(vectors, [[0.1, 0.2], [0.3, 0.4]])
    }

    func testEmbedThrowsOnHttp404() async {
        StubURLProtocol.enqueue(.json(Data("nope".utf8), status: 404))
        let client = OllamaClient(session: StubURLProtocol.session())
        do {
            _ = try await client.embed(model: "x", input: ["y"])
            XCTFail("expected throw")
        } catch let OllamaError.httpStatus(code, _) {
            XCTAssertEqual(code, 404)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaClientEmbedTests
```
Expected: FAIL.

- [ ] **Step 3: Implementation — append to `OllamaClient.swift`**

Add inside the `OllamaClient` class (just before `// MARK: - Helpers`):

```swift
    /// `POST /api/embed` — returns one `[Double]` per input string.
    public func embed(model: String, input: [String]) async throws -> [[Double]] {
        let url = baseURL.appendingPathComponent("api/embed")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(OllamaEmbedRequest(model: model, input: input))

        let (data, response) = try await sendData(req)
        try ensureSuccess(response: response, body: data)
        do {
            let decoded = try decoder.decode(OllamaEmbedResponse.self, from: data)
            return decoded.embeddings
        } catch {
            throw OllamaError.decoding(message: String(describing: error))
        }
    }
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaClientEmbedTests
```
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaClient.swift Tests/AINotebookCoreTests/OllamaClientEmbedTests.swift
git commit -m "feat(core): add OllamaClient.embed"
```

---

## Task 10: `OllamaClient.chat(...)` streaming

**Files:**
- Modify: `Sources/AINotebookCore/OllamaClient.swift`
- Create: `Tests/AINotebookCoreTests/OllamaClientChatTests.swift`

- [ ] **Step 1: Write failing test**

Create `Tests/AINotebookCoreTests/OllamaClientChatTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class OllamaClientChatTests: XCTestCase {
    override func setUp() { StubURLProtocol.reset() }

    func testChatStreamsChunksUntilDone() async throws {
        let lines: [Data] = [
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":"He"},"done":false}"#.data(using: .utf8)!,
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":"llo"},"done":false}"#.data(using: .utf8)!,
            #"{"model":"llama3.2:3b","created_at":"t","message":{"role":"assistant","content":""},"done":true}"#.data(using: .utf8)!
        ]
        StubURLProtocol.enqueue(.ndjson(lines))
        let client = OllamaClient(session: StubURLProtocol.session())

        var collected: [String] = []
        for try await chunk in client.chat(model: "llama3.2:3b", messages: [
            OllamaChatMessage(role: .user, content: "Say hi.")
        ]) {
            collected.append(chunk.message.content)
            if chunk.done { break }
        }
        XCTAssertEqual(collected.joined(), "Hello")
    }
}
```

- [ ] **Step 2: Verify fail**

```bash
swift test --filter OllamaClientChatTests
```
Expected: FAIL.

- [ ] **Step 3: Implementation — append to `OllamaClient.swift`**

Add inside the class (before `// MARK: - Helpers`):

```swift
    /// `POST /api/chat` — streams `OllamaChatChunk`s. Ends after the chunk
    /// with `done == true`.
    public func chat(
        model: String,
        messages: [OllamaChatMessage],
        options: OllamaChatRequest.Options? = nil
    ) -> AsyncThrowingStream<OllamaChatChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = baseURL.appendingPathComponent("api/chat")
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try encoder.encode(OllamaChatRequest(
                        model: model,
                        messages: messages,
                        stream: true,
                        options: options
                    ))

                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse,
                       !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 10_000 { break }
                        }
                        continuation.finish(throwing: OllamaError.httpStatus(
                            code: http.statusCode,
                            body: String(data: data, encoding: .utf8) ?? ""
                        ))
                        return
                    }

                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let lineData = line.data(using: .utf8) else { continue }
                        do {
                            let chunk = try decoder.decode(OllamaChatChunk.self, from: lineData)
                            continuation.yield(chunk)
                            if chunk.done { break }
                        } catch {
                            continuation.finish(throwing: OllamaError.decoding(
                                message: String(describing: error)
                            ))
                            return
                        }
                    }
                    continuation.finish()
                } catch let urlError as URLError {
                    if urlError.code == .timedOut {
                        continuation.finish(throwing: OllamaError.timeout)
                    } else {
                        continuation.finish(throwing: OllamaError.notReachable)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```

- [ ] **Step 4: Verify pass**

```bash
swift test --filter OllamaClientChatTests
```
Expected: PASS, 1 test.

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/OllamaClient.swift Tests/AINotebookCoreTests/OllamaClientChatTests.swift
git commit -m "feat(core): add OllamaClient.chat streaming"
```

---

## Task 11: Localization keys for onboarding + `AppSettings` extensions

**Files:**
- Modify: `Sources/AINotebookCore/Localization.swift`
- Modify: `Sources/AINotebookCore/AppSettings.swift`
- Modify: `Tests/AINotebookCoreTests/AppSettingsTests.swift`
- Modify: `Tests/AINotebookCoreTests/LocalizationTests.swift`

- [ ] **Step 1: Add settings tests**

Open `/Users/lukasoplt/Documents/AI_Notebook/Tests/AINotebookCoreTests/AppSettingsTests.swift` and ADD these methods at the bottom of the `AppSettingsTests` class (before the closing `}`):

```swift
    func testHasCompletedOnboardingDefaultsFalse() {
        let defaults = makeSuite("test.onb.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertFalse(settings.hasCompletedOnboarding)
    }

    func testHasCompletedOnboardingPersists() {
        let suite = "test.onb-persist.\(UUID().uuidString)"
        let defaults = makeSuite(suite)
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        settings.hasCompletedOnboarding = true
        XCTAssertEqual(defaults.bool(forKey: "hasCompletedOnboarding"), true)
    }

    func testSelectedModelsDefaults() {
        let defaults = makeSuite("test.models.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        XCTAssertEqual(settings.selectedChatModel, "llama3.2:3b")
        XCTAssertEqual(settings.selectedEmbeddingModel, "nomic-embed-text")
    }

    func testSelectedModelsPersist() {
        let defaults = makeSuite("test.models-w.\(UUID().uuidString)")
        let settings = AppSettings(
            defaults: defaults,
            preferredLanguages: ["en-US"]
        )
        settings.selectedChatModel = "llama3.1:8b"
        settings.selectedEmbeddingModel = "mxbai-embed-large"
        XCTAssertEqual(defaults.string(forKey: "selectedChatModel"), "llama3.1:8b")
        XCTAssertEqual(defaults.string(forKey: "selectedEmbeddingModel"), "mxbai-embed-large")
    }
```

- [ ] **Step 2: Verify they fail**

```bash
swift test --filter AppSettingsTests
```
Expected: FAIL — `hasCompletedOnboarding`, `selectedChatModel`, `selectedEmbeddingModel` undefined.

- [ ] **Step 3: Extend `AppSettings.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookCore/AppSettings.swift`.

Replace the `private enum Keys` block with:

```swift
    private enum Keys {
        static let language = "language"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let selectedChatModel = "selectedChatModel"
        static let selectedEmbeddingModel = "selectedEmbeddingModel"
    }
```

Replace the existing `init(...)` with this version (it adds the three new defaults reads):

```swift
    public init(
        defaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        if let raw = defaults.string(forKey: Keys.language),
           let stored = AppLanguage(rawValue: raw) {
            self.language = stored
        } else {
            self.language = detectInitialLanguage(preferredLanguages: preferredLanguages)
        }

        self.hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        self.selectedChatModel =
            defaults.string(forKey: Keys.selectedChatModel) ?? "llama3.2:3b"
        self.selectedEmbeddingModel =
            defaults.string(forKey: Keys.selectedEmbeddingModel) ?? "nomic-embed-text"
    }
```

Add these `@Published` declarations directly below the existing `language` declaration:

```swift
    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published public var selectedChatModel: String {
        didSet { defaults.set(selectedChatModel, forKey: Keys.selectedChatModel) }
    }

    @Published public var selectedEmbeddingModel: String {
        didSet { defaults.set(selectedEmbeddingModel, forKey: Keys.selectedEmbeddingModel) }
    }
```

- [ ] **Step 4: Run tests, verify pass**

```bash
swift test --filter AppSettingsTests
```
Expected: PASS, 8 tests (4 original + 4 new).

- [ ] **Step 5: Add localization tests**

Open `/Users/lukasoplt/Documents/AI_Notebook/Tests/AINotebookCoreTests/LocalizationTests.swift`. Replace the `testKnownStringsExact` method body with:

```swift
    func testKnownStringsExact() {
        let en = AppText(language: .english)
        XCTAssertEqual(en.string(.settings), "Settings")
        XCTAssertEqual(en.string(.notebooks), "Notebooks")
        XCTAssertEqual(en.string(.create), "Create")
        XCTAssertEqual(en.string(.cancel), "Cancel")
        XCTAssertEqual(en.string(.delete), "Delete")
        XCTAssertEqual(en.string(.welcome), "Welcome")
        XCTAssertEqual(en.string(.openOllamaDownload), "Open download page")

        let cs = AppText(language: .czech)
        XCTAssertEqual(cs.string(.settings), "Nastavení")
        XCTAssertEqual(cs.string(.notebooks), "Poznámkové bloky")
        XCTAssertEqual(cs.string(.create), "Vytvořit")
        XCTAssertEqual(cs.string(.welcome), "Vítejte")
        XCTAssertEqual(cs.string(.openOllamaDownload), "Otevřít stránku ke stažení")
    }
```

- [ ] **Step 6: Verify they fail**

```bash
swift test --filter LocalizationTests
```
Expected: FAIL — `.welcome` and `.openOllamaDownload` undefined.

- [ ] **Step 7: Extend `Localization.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookCore/Localization.swift`.

Inside the `Key` enum (after the existing last case), add:

```swift
        case welcome
        case welcomeBody
        case continueLabel
        case onboardingDetectTitle
        case onboardingDetectBody
        case onboardingDetectChecking
        case onboardingDetectFound
        case openOllamaDownload
        case onboardingDetectWaiting
        case onboardingPickModelsTitle
        case onboardingPickModelsBody
        case chatModel
        case embeddingModel
        case onboardingPullTitle
        case onboardingPullBody
        case onboardingPullingChat
        case onboardingPullingEmbedding
        case onboardingDoneTitle
        case onboardingDoneBody
        case ollamaUnreachable
        case startUsingApp
```

Inside `private func english(_:)` (after the existing last case), add:

```swift
        case .welcome:                     "Welcome"
        case .welcomeBody:                 "AI Notebook keeps everything local. To run AI, we'll use Ollama on your Mac."
        case .continueLabel:               "Continue"
        case .onboardingDetectTitle:       "Check Ollama"
        case .onboardingDetectBody:        "We're looking for a running Ollama on your Mac."
        case .onboardingDetectChecking:    "Checking…"
        case .onboardingDetectFound:       "Ollama is running."
        case .openOllamaDownload:          "Open download page"
        case .onboardingDetectWaiting:     "Waiting for Ollama to start…"
        case .onboardingPickModelsTitle:   "Pick models"
        case .onboardingPickModelsBody:    "Defaults are fine for most people. You can change them later in Settings."
        case .chatModel:                   "Chat model"
        case .embeddingModel:              "Embedding model"
        case .onboardingPullTitle:         "Downloading models"
        case .onboardingPullBody:          "This is a one-time download. Keep the app open."
        case .onboardingPullingChat:       "Chat model"
        case .onboardingPullingEmbedding:  "Embedding model"
        case .onboardingDoneTitle:         "All set"
        case .onboardingDoneBody:          "You can now create your first notebook."
        case .ollamaUnreachable:           "Cannot reach Ollama. Is it running?"
        case .startUsingApp:               "Start using the app"
```

Inside `private func czech(_:)` (after the existing last case), add:

```swift
        case .welcome:                     "Vítejte"
        case .welcomeBody:                 "AI Notebook udržuje vše lokálně. K AI použijeme Ollamu spuštěnou na vašem Macu."
        case .continueLabel:               "Pokračovat"
        case .onboardingDetectTitle:       "Kontrola Ollamy"
        case .onboardingDetectBody:        "Hledáme spuštěnou Ollamu na vašem Macu."
        case .onboardingDetectChecking:    "Hledám…"
        case .onboardingDetectFound:       "Ollama běží."
        case .openOllamaDownload:          "Otevřít stránku ke stažení"
        case .onboardingDetectWaiting:     "Čekám, až se Ollama spustí…"
        case .onboardingPickModelsTitle:   "Vyberte modely"
        case .onboardingPickModelsBody:    "Výchozí hodnoty vyhovují většině uživatelů. Změnit je můžete později v Nastavení."
        case .chatModel:                   "Model pro chat"
        case .embeddingModel:              "Model pro embeddingy"
        case .onboardingPullTitle:         "Stahuji modely"
        case .onboardingPullBody:          "Tohle je jednorázové stažení. Nechte aplikaci spuštěnou."
        case .onboardingPullingChat:       "Model pro chat"
        case .onboardingPullingEmbedding:  "Model pro embeddingy"
        case .onboardingDoneTitle:         "Hotovo"
        case .onboardingDoneBody:          "Teď můžete vytvořit svůj první poznámkový blok."
        case .ollamaUnreachable:           "Nelze se připojit k Ollamě. Je spuštěná?"
        case .startUsingApp:               "Začít používat aplikaci"
```

- [ ] **Step 8: Verify all tests pass**

```bash
swift test
```
Expected: all tests pass (count is M0+M1+M2-so-far; the exact count depends on previous tasks but localization 4 + appsettings 8 must be included).

- [ ] **Step 9: Commit**

```bash
git add Sources/AINotebookCore/AppSettings.swift Sources/AINotebookCore/Localization.swift Tests/AINotebookCoreTests/AppSettingsTests.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(core): add onboarding state to AppSettings + 21 onboarding strings"
```

---

## Task 12: Onboarding view model + step enum

**Files:**
- Create: `Sources/AINotebookApp/Onboarding/OnboardingStep.swift`
- Create: `Sources/AINotebookApp/Onboarding/OnboardingViewModel.swift`

(No standalone tests for the view model in M2 — it's exercised via the UI smoke test in Task 15. Future milestones can add ViewInspector-style unit tests if needed.)

- [ ] **Step 1: Create `OnboardingStep.swift`**

Make the directory first:
```bash
mkdir -p Sources/AINotebookApp/Onboarding
```

Then create `Sources/AINotebookApp/Onboarding/OnboardingStep.swift`:

```swift
import Foundation

public enum OnboardingStep: Int, CaseIterable, Sendable {
    case welcome
    case detectOllama
    case pickModels
    case pullModels
    case done
}
```

- [ ] **Step 2: Create `OnboardingViewModel.swift`**

Create `Sources/AINotebookApp/Onboarding/OnboardingViewModel.swift`:

```swift
import Foundation
import SwiftUI
import AINotebookCore

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome

    @Published var isOllamaReachable = false
    @Published var detectStatusMessage = ""

    @Published var chatPullFraction: Double? = nil
    @Published var chatPullStatus = ""

    @Published var embeddingPullFraction: Double? = nil
    @Published var embeddingPullStatus = ""

    @Published var pullError: String?

    private let client: OllamaClient
    private let settings: AppSettings
    private var pollTask: Task<Void, Never>?

    init(client: OllamaClient, settings: AppSettings) {
        self.client = client
        self.settings = settings
    }

    func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    // MARK: - Step 2: detect Ollama

    func startDetectionPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let up = await client.detect()
                await MainActor.run {
                    self.isOllamaReachable = up
                }
                if up { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2s
            }
        }
    }

    func stopDetectionPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func openOllamaDownloadPage() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Step 4: pull models

    func runModelPulls() async {
        pullError = nil
        let chatModel = settings.selectedChatModel
        let embedModel = settings.selectedEmbeddingModel

        do {
            chatPullStatus = "Starting…"
            for try await event in client.pullModel(name: chatModel) {
                chatPullStatus = event.status
                chatPullFraction = event.fractionComplete
                if event.isTerminalSuccess { chatPullFraction = 1.0 }
            }

            embeddingPullStatus = "Starting…"
            for try await event in client.pullModel(name: embedModel) {
                embeddingPullStatus = event.status
                embeddingPullFraction = event.fractionComplete
                if event.isTerminalSuccess { embeddingPullFraction = 1.0 }
            }

            advance() // → .done
        } catch {
            pullError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func markCompleted() {
        settings.hasCompletedOnboarding = true
    }
}
```

- [ ] **Step 3: Build**

```bash
swift build
```
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookApp/Onboarding/OnboardingStep.swift Sources/AINotebookApp/Onboarding/OnboardingViewModel.swift
git commit -m "feat(app): add OnboardingStep + OnboardingViewModel"
```

---

## Task 13: Per-step views + `OnboardingView` container

**Files:**
- Create: `Sources/AINotebookApp/Onboarding/WelcomeStepView.swift`
- Create: `Sources/AINotebookApp/Onboarding/DetectOllamaStepView.swift`
- Create: `Sources/AINotebookApp/Onboarding/PickModelsStepView.swift`
- Create: `Sources/AINotebookApp/Onboarding/PullModelsStepView.swift`
- Create: `Sources/AINotebookApp/Onboarding/DoneStepView.swift`
- Create: `Sources/AINotebookApp/Onboarding/OnboardingView.swift`

- [ ] **Step 1: Create `WelcomeStepView.swift`**

```swift
import SwiftUI
import AINotebookCore

struct WelcomeStepView: View {
    @EnvironmentObject private var settings: AppSettings
    var onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text(settings.text.string(.welcome))
                .font(.largeTitle).bold()
            Text(settings.text.string(.welcomeBody))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button(settings.text.string(.continueLabel), action: onContinue)
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(40)
    }
}
```

- [ ] **Step 2: Create `DetectOllamaStepView.swift`**

```swift
import SwiftUI
import AINotebookCore

struct DetectOllamaStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: viewModel.isOllamaReachable ? "checkmark.circle.fill" : "cloud.bolt")
                .font(.system(size: 48))
                .foregroundStyle(viewModel.isOllamaReachable ? .green : .secondary)
            Text(settings.text.string(.onboardingDetectTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingDetectBody))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if viewModel.isOllamaReachable {
                Text(settings.text.string(.onboardingDetectFound))
                    .foregroundStyle(.green)
                Button(settings.text.string(.continueLabel)) {
                    viewModel.stopDetectionPolling()
                    viewModel.advance()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            } else {
                ProgressView()
                Text(settings.text.string(.onboardingDetectWaiting))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                Button(settings.text.string(.openOllamaDownload)) {
                    viewModel.openOllamaDownloadPage()
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { viewModel.startDetectionPolling() }
        .onDisappear { viewModel.stopDetectionPolling() }
    }
}
```

- [ ] **Step 3: Create `PickModelsStepView.swift`**

```swift
import SwiftUI
import AINotebookCore

struct PickModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    private let chatChoices = ["llama3.2:3b", "llama3.1:8b", "mistral:7b"]
    private let embedChoices = ["nomic-embed-text", "mxbai-embed-large"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(settings.text.string(.onboardingPickModelsTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingPickModelsBody))
                .foregroundStyle(.secondary)

            Picker(settings.text.string(.chatModel), selection: $settings.selectedChatModel) {
                ForEach(chatChoices, id: \.self) { Text($0).tag($0) }
            }
            Picker(settings.text.string(.embeddingModel), selection: $settings.selectedEmbeddingModel) {
                ForEach(embedChoices, id: \.self) { Text($0).tag($0) }
            }

            Spacer()
            HStack {
                Spacer()
                Button(settings.text.string(.continueLabel)) {
                    viewModel.advance()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
```

- [ ] **Step 4: Create `PullModelsStepView.swift`**

```swift
import SwiftUI
import AINotebookCore

struct PullModelsStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(settings.text.string(.onboardingPullTitle))
                .font(.title).bold()
            Text(settings.text.string(.onboardingPullBody))
                .foregroundStyle(.secondary)

            modelProgress(
                title: settings.text.string(.onboardingPullingChat),
                fraction: viewModel.chatPullFraction,
                status: viewModel.chatPullStatus
            )
            modelProgress(
                title: settings.text.string(.onboardingPullingEmbedding),
                fraction: viewModel.embeddingPullFraction,
                status: viewModel.embeddingPullStatus
            )

            if let error = viewModel.pullError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.runModelPulls() }
    }

    private func modelProgress(title: String, fraction: Double?, status: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            ProgressView(value: fraction ?? 0)
                .progressViewStyle(.linear)
            Text(status)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
```

- [ ] **Step 5: Create `DoneStepView.swift`**

```swift
import SwiftUI
import AINotebookCore

struct DoneStepView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text(settings.text.string(.onboardingDoneTitle))
                .font(.largeTitle).bold()
            Text(settings.text.string(.onboardingDoneBody))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 40)
            Button(settings.text.string(.startUsingApp)) {
                viewModel.markCompleted()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
        }
        .padding(40)
    }
}
```

- [ ] **Step 6: Create `OnboardingView.swift`** (the dispatcher)

```swift
import SwiftUI
import AINotebookCore

struct OnboardingView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        switch viewModel.step {
        case .welcome:
            WelcomeStepView { viewModel.advance() }
        case .detectOllama:
            DetectOllamaStepView(viewModel: viewModel)
        case .pickModels:
            PickModelsStepView(viewModel: viewModel)
        case .pullModels:
            PullModelsStepView(viewModel: viewModel)
        case .done:
            DoneStepView(viewModel: viewModel)
        }
    }
}
```

- [ ] **Step 7: Build**

```bash
swift build
```
Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add Sources/AINotebookApp/Onboarding/
git commit -m "feat(app): add onboarding wizard views (welcome, detect, pick, pull, done)"
```

---

## Task 14: Inject `OllamaClient` and gate `ContentView` behind onboarding

**Files:**
- Modify: `Sources/AINotebookApp/AINotebookApp.swift`
- Modify: `Sources/AINotebookApp/ContentView.swift`

- [ ] **Step 1: Replace `AINotebookApp.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookApp/AINotebookApp.swift` and replace the entire file with:

```swift
import SwiftUI
import AINotebookCore

@main
struct AINotebookAppEntry: App {
    @StateObject private var settings: AppSettings
    @StateObject private var store: NotebookStore
    @StateObject private var ollama: OllamaClientHolder
    @StateObject private var onboarding: OnboardingViewModel

    init() {
        let settings = AppSettings()
        _settings = StateObject(wrappedValue: settings)

        let store: NotebookStore
        do {
            let path = try StorePath.production()
            store = try NotebookStore(path: path)
        } catch {
            fatalError("Failed to open AINotebook database: \(error)")
        }
        _store = StateObject(wrappedValue: store)

        let client = OllamaClient()
        _ollama = StateObject(wrappedValue: OllamaClientHolder(client: client))
        _onboarding = StateObject(wrappedValue: OnboardingViewModel(
            client: client,
            settings: settings
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(ollama)
                .environmentObject(onboarding)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                EmptyView()
            }
        }
    }
}

/// `OllamaClient` itself is a final class, so it can't be `@StateObject`'d
/// directly without `ObservableObject` conformance — wrap it in a holder.
@MainActor
final class OllamaClientHolder: ObservableObject {
    let client: OllamaClient
    init(client: OllamaClient) { self.client = client }
}
```

- [ ] **Step 2: Replace `ContentView.swift`**

Open `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookApp/ContentView.swift` and replace the entire file with:

```swift
import SwiftUI
import AINotebookCore

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: NotebookStore
    @EnvironmentObject private var ollama: OllamaClientHolder
    @EnvironmentObject private var onboarding: OnboardingViewModel

    @State private var selectedNotebookId: Int64?
    @State private var showSettings = false

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainUI
            } else {
                OnboardingView(viewModel: onboarding)
                    .environmentObject(settings)
            }
        }
    }

    private var mainUI: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedNotebookId)
                .environmentObject(settings)
                .environmentObject(store)
        } detail: {
            detail
        }
        .navigationTitle(settings.text.string(.appName))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSettings = true
                } label: {
                    Label(settings.text.string(.settings), systemImage: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(settings)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedNotebookId,
           let notebook = store.notebooks.first(where: { $0.id == id }) {
            NotebookDetailView(notebook: notebook)
                .environmentObject(settings)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(settings.text.string(.noNotebookSelected))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

The implementation comment above flags the onboarding VM init wart — for M2 this is acceptable since the wizard runs once. A cleaner refactor (hoisting VM construction to `AINotebookApp`) can come in M7.

- [ ] **Step 3: Build**

```bash
swift build
```
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookApp/AINotebookApp.swift Sources/AINotebookApp/ContentView.swift
git commit -m "feat(app): inject OllamaClientHolder + gate ContentView on onboarding"
```

---

## Task 15: Final verification + tag + merge

- [ ] **Step 1: Clean build + full test run**

```bash
swift package clean
swift build
swift test --parallel
```

Expected:
- Build success.
- All tests pass. Approximate count: M0+M1 (38) + OllamaModel(2) + OllamaPullEvent(4) + OllamaWireTypes(4) + OllamaClientDetectAndList(4) + OllamaClientPull(2) + OllamaClientEmbed(2) + OllamaClientChat(1) + AppSettings new(4) = ~61 tests.

- [ ] **Step 2: Smoke test the app — onboarding path**

Step 2a: reset onboarding flag so we land on the wizard:
```bash
defaults delete com.aiexposurescanner.app hasCompletedOnboarding 2>/dev/null || true
# Note: actual UserDefaults suite is the app bundle id; if the app uses
# the default suite, the above command fails harmlessly.
```

Easier: temporarily delete the app's UserDefaults preference file or use a fresh user. For M2 smoke, the simpler path is to launch the app and use the in-window Settings to toggle `hasCompletedOnboarding` back to false… but Settings doesn't expose that yet. Easiest workaround for the smoke test: comment out the toggle in the init OR delete the UserDefaults plist for this app while it's quit. For the verification step here, assume one of:

  (a) you ran the app previously and onboarding is unset → wizard shows; or
  (b) skip the wizard smoke test and proceed.

Run:
```bash
swift run AINotebookApp
```

If the wizard appears:
- Welcome → click Continue
- Detect: if Ollama is installed, it should turn green within ~2 s; if not, click "Open download page" to verify the link opens
- Pick models: leave defaults, click Continue
- Pull: progress bars fill (real download — may take minutes; cancel by quitting if needed)
- Done: click Start; main UI appears
- Verify hasCompletedOnboarding flag survived restart (re-launch → goes straight to main UI)

If you didn't get the wizard (because the flag is already true), skip to the next step.

- [ ] **Step 3: Smoke test the app — main path**

```bash
swift run AINotebookApp
```
Same checks as M1: create / rename / delete a notebook; language switch.

- [ ] **Step 4: Tag**

```bash
git tag -a m2-ollama -m "M2 Ollama client + onboarding wizard complete"
```

- [ ] **Step 5: Merge to main**

```bash
git checkout main
git merge --ff-only m2-ollama
git log --oneline | head -10
```

---

## Acceptance criteria (M2 done when ALL true)

- `swift build` succeeds.
- `swift test --parallel` reports ~61 tests passing, 0 failures.
- `OllamaClient` exposes `detect`, `listModels`, `pullModel`, `embed`, `chat`.
- CI privacy grep now allows URLSession in `OllamaClient.swift` only.
- Launching the app with `hasCompletedOnboarding == false` shows the wizard; after completion the flag flips and subsequent launches land on the main UI.
- All onboarding strings are bilingual.
- Local git tag `m2-ollama` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **URLProtocol stubbing:** `StubURLProtocol` is registered only on the session passed to the client under test — `URLSession.shared` and the real production client are unaffected.
- **AsyncThrowingStream cancellation:** both `pullModel` and `chat` set `continuation.onTermination` to cancel the inner task. SwiftUI views consuming these streams via `.task { for try await … }` get free cancellation when the view goes away.
- **Onboarding VM wart in `ContentView.init`:** documented inline — fix during M7 polish.
- **Real network in smoke test:** `pullModel` against a live Ollama daemon downloads multi-GB files. For CI we do not run this — only the URLProtocol-stubbed unit tests run.
