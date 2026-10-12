import Foundation

/// One strict `/api/embed` response for exactly one formatted input (benchmark-v1 §3).
public struct StrictEmbeddingResult: Sendable {
    /// Native-dimension vector as returned by the provider (not yet projected).
    public let vector: [Float]
    /// Provider-processed input tokens for this single input, when reported.
    public let promptTokens: Int?
    public let totalDurationNs: Int64?
    public let loadDurationNs: Int64?

    public init(vector: [Float], promptTokens: Int?, totalDurationNs: Int64?, loadDurationNs: Int64?) {
        self.vector = vector
        self.promptTokens = promptTokens
        self.totalDurationNs = totalDurationNs
        self.loadDurationNs = loadDurationNs
    }
}

public protocol StrictEmbeddingTransport: Sendable {
    func embed(model: String, input: String, nativeDims: Int, inputLimit: Int) async throws -> StrictEmbeddingResult
}

/// Exact offline token counter for a documented tokenizer (benchmark-v1 §7).
public protocol ExactTokenCounting: Sendable {
    func count(_ text: String, tokenizerId: String) async throws -> Int
}

/// The one typed server length rejection; every other provider failure propagates.
public struct EmbeddingInputTooLong: Error, Equatable, Sendable { public init() {} }

public struct EmbeddedPart: Codable, Equatable, Sendable {
    /// Half-open Unicode scalar offsets into the raw (unformatted) input.
    public let start: Int
    public let end: Int
    public let tokens: Int

    public init(start: Int, end: Int, tokens: Int) {
        self.start = start
        self.end = end
        self.tokens = tokens
    }
}

public struct EmbeddedInput: Sendable {
    public let vector: [Float]
    public let parts: [EmbeddedPart]
    public let successfulTokens: Int
    public let rejectedRequests: Int

    public init(vector: [Float], parts: [EmbeddedPart], successfulTokens: Int, rejectedRequests: Int) {
        self.vector = vector
        self.parts = parts
        self.successfulTokens = successfulTokens
        self.rejectedRequests = rejectedRequests
    }
}

public struct EmbeddingTelemetryEvent: Equatable, Sendable {
    /// `request`, `response`, `lengthRejected` or `partAccepted`.
    public let kind: String
    public let purpose: EmbeddingPurpose
    public let tokens: Int?
    public let start: Int?
    public let end: Int?

    public init(kind: String, purpose: EmbeddingPurpose, tokens: Int? = nil, start: Int? = nil, end: Int? = nil) {
        self.kind = kind
        self.purpose = purpose
        self.tokens = tokens
        self.start = start
        self.end = end
    }
}

/// Nonthrowing by design: an observer can never drop embedding work.
public protocol EmbeddingTelemetryObserving: Sendable {
    func record(_ event: EmbeddingTelemetryEvent) async
}

/// Strict complete-input embedding: format once, `truncate:false`, split by scalar
/// bisection on a typed length rejection or an over-limit exact count, pool every
/// accepted leaf exactly once.
public struct StrictEmbeddingPipeline: Sendable {
    private let transport: any StrictEmbeddingTransport
    private let counter: (any ExactTokenCounting)?
    private let observer: (any EmbeddingTelemetryObserving)?

    public init(transport: any StrictEmbeddingTransport, counter: (any ExactTokenCounting)? = nil,
                observer: (any EmbeddingTelemetryObserving)? = nil) {
        self.transport = transport
        self.counter = counter
        self.observer = observer
    }

    private final class Accumulator {
        var vectors: [[Float]] = []
        var parts: [EmbeddedPart] = []
        var rejected = 0
    }

    public func embed(_ text: String, profile: EmbeddingProfile, purpose: EmbeddingPurpose,
                      effectiveLimit: Int) async throws -> EmbeddedInput {
        guard !text.unicodeScalars.isEmpty else { throw EmbeddingProfileError(code: "emptyInput") }
        guard effectiveLimit >= 1, effectiveLimit <= profile.maxInputTokens else {
            throw EmbeddingProfileError(code: "invalidEffectiveLimit")
        }
        let state = Accumulator()
        try await visit(text, start: 0, profile: profile, purpose: purpose, limit: effectiveLimit, state: state)
        let vector = try EmbeddingInput.pool(state.vectors, scalarWeights: state.parts.map { $0.end - $0.start })
        return EmbeddedInput(vector: vector, parts: state.parts,
                             successfulTokens: state.parts.reduce(0) { $0 + $1.tokens },
                             rejectedRequests: state.rejected)
    }

    private func emit(_ event: EmbeddingTelemetryEvent) async {
        if let observer { await observer.record(event) }
    }

    private func visit(_ raw: String, start: Int, profile: EmbeddingProfile, purpose: EmbeddingPurpose,
                       limit: Int, state: Accumulator) async throws {
        try Task.checkCancellation()
        let formatted = profile.format(raw, purpose: purpose)
        await emit(EmbeddingTelemetryEvent(kind: "request", purpose: purpose))
        let response: StrictEmbeddingResult?
        do {
            response = try await transport.embed(model: profile.model, input: formatted,
                                                 nativeDims: profile.nativeDims, inputLimit: limit)
        } catch is EmbeddingInputTooLong {
            response = nil
        }
        try Task.checkCancellation()
        if let r = response {
            let vector = try EmbeddingInput.project(r.vector, nativeDims: profile.nativeDims, dims: profile.dims)
            if let native = r.promptTokens, native < 0 { throw EmbeddingProfileError(code: "invalidTokenCount") }
            await emit(EmbeddingTelemetryEvent(kind: "response", purpose: purpose, tokens: r.promptTokens))
            let count: Int
            if let native = r.promptTokens {
                count = native
            } else if let counter {
                count = try await counter.count(formatted, tokenizerId: profile.tokenizerId)
                try Task.checkCancellation()
                guard count >= 0 else { throw EmbeddingProfileError(code: "invalidTokenCount") }
            } else {
                throw EmbeddingProfileError(code: "tokenCountUnavailable")
            }
            if count <= limit {
                let part = EmbeddedPart(start: start, end: start + raw.unicodeScalars.count, tokens: count)
                state.vectors.append(vector)
                state.parts.append(part)
                await emit(EmbeddingTelemetryEvent(kind: "partAccepted", purpose: purpose, tokens: count,
                                                   start: part.start, end: part.end))
                return
            }
            // A successful response above the ceiling: split the whole input.
        } else {
            state.rejected += 1
            await emit(EmbeddingTelemetryEvent(kind: "lengthRejected", purpose: purpose))
        }
        let (left, right) = try EmbeddingInput.bisect(raw)
        try await visit(left, start: start, profile: profile, purpose: purpose, limit: limit, state: state)
        try await visit(right, start: start + left.unicodeScalars.count, profile: profile, purpose: purpose,
                        limit: limit, state: state)
    }
}

/// Offline documented-tokenizer protocol client (benchmark-v1 §7). Pure codec plus a
/// long-lived helper process started with an argument array (never a shell string).
public struct OfflineTokenCount: Equatable, Sendable {
    public let tokens: Int
    public let tokenizerId: String
    public let revision: String
    public let assetsSha256: String

    public init(tokens: Int, tokenizerId: String, revision: String, assetsSha256: String) {
        self.tokens = tokens
        self.tokenizerId = tokenizerId
        self.revision = revision
        self.assetsSha256 = assetsSha256
    }
}

public enum OfflineTokenizerProtocol {
    /// One newline-terminated JSON request with sorted keys.
    public static func encodeRequest(requestId: String, tokenizerId: String, text: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["requestId": requestId, "tokenizerId": tokenizerId,
                                                               "text": text],
                                              options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func decodeResponse(_ line: Data, requestId: String, tokenizerId: String) throws -> OfflineTokenCount {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["requestId"] as? String == requestId else {
            throw EmbeddingProfileError(code: "tokenizerUnavailable")
        }
        if object["error"] != nil { throw EmbeddingProfileError(code: "tokenCountUnavailable") }
        guard let tokens = OllamaBenchmarkClient.nonnegativeInteger(object["tokens"]),
              object["tokenizerId"] as? String == tokenizerId,
              let revision = object["revision"] as? String, !revision.isEmpty,
              let assets = object["assetsSha256"] as? String, OllamaBenchmarkClient.isLowerHex64(assets) else {
            throw EmbeddingProfileError(code: "invalidTokenCount")
        }
        return OfflineTokenCount(tokens: tokens, tokenizerId: tokenizerId, revision: revision, assetsSha256: assets)
    }
}

/// Runs `tokenize_offline.py --root DIR` (or any compatible executable) once and
/// serializes requests over its stdin/stdout. Text is never logged.
public actor OfflineTokenizerProcess: ExactTokenCounting {
    private let executable: URL
    private let arguments: [String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var nextId = 0
    public private(set) var lastCount: OfflineTokenCount?

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    public func count(_ text: String, tokenizerId: String) async throws -> Int {
        try await countDetailed(text, tokenizerId: tokenizerId).tokens
    }

    public func countDetailed(_ text: String, tokenizerId: String) async throws -> OfflineTokenCount {
        try Task.checkCancellation()
        try start()
        nextId += 1
        let requestId = "r" + String(nextId)
        guard let input, let output else { throw EmbeddingProfileError(code: "tokenizerUnavailable") }
        do { try input.write(contentsOf: OfflineTokenizerProtocol.encodeRequest(requestId: requestId,
                                                                                 tokenizerId: tokenizerId, text: text)) }
        catch { throw EmbeddingProfileError(code: "tokenizerUnavailable") }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let result = try OfflineTokenizerProtocol.decodeResponse(Data(line), requestId: requestId,
                                                                         tokenizerId: tokenizerId)
                lastCount = result
                return result
            }
            let chunk = output.availableData
            guard !chunk.isEmpty else { throw EmbeddingProfileError(code: "tokenizerUnavailable") }
            buffer.append(chunk)
        }
    }

    public func terminate() {
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        output = nil
    }

    private func start() throws {
        if let process, process.isRunning { return }
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        p.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw EmbeddingProfileError(code: "tokenizerUnavailable") }
        process = p
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        buffer = Data()
    }
}
