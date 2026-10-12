import Foundation

/// WP7 benchmark/calibration CLI options (benchmark-v1 §8 `cli`). Every rejection is
/// `invalidArguments` (exit 2) and happens before any provider or store operation.
/// `embeddingCounts` is the contract §9 extra field (`--embedding-counts all`).
public struct BenchmarkOptions: Equatable, Sendable {
    public let command: String
    public let mode: String
    public let root: String
    public let host: String
    public let profileIds: [String]
    public let chunkCounts: [Int]
    public let chatModel: String
    public let calibration: String?
    public let tokenizerRoot: String?
    public let embeddingCounts: String?
    public let queries: Int
    public let warmup: Int
    public let concurrent: String
    public let seed: Int
    public let fetchK: Int
    public let topK: Int
    public let evidenceShareBp: Int
    public let runtimeContext: Int
    public let maxOutput: Int
    public let ollamaPid: Int32?
    public let json: String
    public let out: String

    public static let defaultHost = "http://127.0.0.1:11434"
    public static let defaultRoot = "eval/multilingual"
    public static let defaultChatModel = "llama3.2:3b"

    public init(command: String, mode: String, root: String, host: String, profileIds: [String], chunkCounts: [Int],
                chatModel: String, calibration: String?, tokenizerRoot: String?, embeddingCounts: String? = nil,
                queries: Int, warmup: Int, concurrent: String, seed: Int, fetchK: Int, topK: Int,
                evidenceShareBp: Int, runtimeContext: Int, maxOutput: Int, ollamaPid: Int32?, json: String, out: String) {
        self.command = command
        self.mode = mode
        self.root = root
        self.host = host
        self.profileIds = profileIds
        self.chunkCounts = chunkCounts
        self.chatModel = chatModel
        self.calibration = calibration
        self.tokenizerRoot = tokenizerRoot
        self.embeddingCounts = embeddingCounts
        self.queries = queries
        self.warmup = warmup
        self.concurrent = concurrent
        self.seed = seed
        self.fetchK = fetchK
        self.topK = topK
        self.evidenceShareBp = evidenceShareBp
        self.runtimeContext = runtimeContext
        self.maxOutput = maxOutput
        self.ollamaPid = ollamaPid
        self.json = json
        self.out = out
    }

    private static let flags: Set<String> = [
        "--mode", "--root", "--host", "--profiles", "--chunks", "--chat-model", "--calibration", "--tokenizer-root",
        "--embedding-counts", "--queries", "--warmup", "--concurrent", "--seed", "--fetch-k", "--top-k",
        "--evidence-share-bp", "--runtime-context", "--max-output", "--ollama-pid", "--json", "--out",
    ]

    public static func parse(_ args: [String]) throws -> BenchmarkOptions {
        let invalid = BenchmarkError(code: "invalidArguments")
        var commands: [String] = []
        var values: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--benchmark" || a == "--calibrate" { commands.append(String(a.dropFirst(2))); i += 1; continue }
            guard flags.contains(a), values[a] == nil, i + 1 < args.count else { throw invalid }
            values[a] = args[i + 1]
            i += 2
        }
        guard commands.count == 1 else { throw invalid }
        func text(_ flag: String, _ fallback: String) throws -> String {
            guard let v = values[flag] else { return fallback }
            guard !v.isEmpty else { throw invalid }
            return v
        }
        func optional(_ flag: String) throws -> String? {
            guard let v = values[flag] else { return nil }
            guard !v.isEmpty else { throw invalid }
            return v
        }
        func number(_ flag: String, _ fallback: Int) throws -> Int {
            guard let v = values[flag] else { return fallback }
            return try decimal(v)
        }
        var profiles = EmbeddingProfiles.ids
        if let p = values["--profiles"], p != "all" {
            let ids = p.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy(EmbeddingProfiles.ids.contains) else { throw invalid }
            profiles = ids
        }
        var chunks = [100_000, 200_000]
        if let c = values["--chunks"] {
            let counts = try c.split(separator: ",", omittingEmptySubsequences: false).map { try decimal(String($0)) }
            guard Set(counts).count == counts.count, counts.allSatisfy({ $0 > 0 }) else { throw invalid }
            chunks = counts
        }
        let pid = try values["--ollama-pid"].map { Int32(try decimal($0)) }
        guard let json = try optional("--json"), let out = try optional("--out") else { throw invalid }
        let o = BenchmarkOptions(
            command: commands[0], mode: try text("--mode", "live"), root: try text("--root", defaultRoot),
            host: try text("--host", defaultHost), profileIds: profiles, chunkCounts: chunks,
            chatModel: try text("--chat-model", defaultChatModel), calibration: try optional("--calibration"),
            tokenizerRoot: try optional("--tokenizer-root"), embeddingCounts: try optional("--embedding-counts"),
            queries: try number("--queries", 200), warmup: try number("--warmup", 20),
            concurrent: try text("--concurrent", "both"), seed: try number("--seed", 17),
            fetchK: try number("--fetch-k", 32), topK: try number("--top-k", 16),
            evidenceShareBp: try number("--evidence-share-bp", 6000), runtimeContext: try number("--runtime-context", 8192),
            maxOutput: try number("--max-output", 1024), ollamaPid: pid, json: json, out: out)
        guard ["live", "fixture"].contains(o.mode), ["both", "off", "on"].contains(o.concurrent), o.json != o.out,
              o.topK > 0, o.fetchK >= o.topK, o.fetchK <= 1024, o.evidenceShareBp <= 10_000,
              o.maxOutput > 0, o.maxOutput < o.runtimeContext, o.queries > 0,
              o.embeddingCounts == nil || (o.command == "calibrate" && o.embeddingCounts == "all"),
              (o.ollamaPid ?? 1) > 0 else { throw invalid }
        if o.command == "benchmark" && o.mode == "live" && (o.calibration == nil || o.ollamaPid == nil) { throw invalid }
        return o
    }

    /// Invariant unsigned decimal, at most 10 ASCII digits and ≤ Int32.max.
    private static func decimal(_ text: String) throws -> Int {
        guard !text.isEmpty, text.utf8.count <= 10, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let v = Int64(text), v <= Int64(Int32.max) else { throw BenchmarkError(code: "invalidArguments") }
        return Int(v)
    }
}
