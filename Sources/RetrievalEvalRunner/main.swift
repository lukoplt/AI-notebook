import AINotebookCore
import Foundation
import NaturalLanguage

// FR-D2 / W-4 — local retrieval eval runner.
//
// Builds an in-memory notebook from eval/corpus, embeds it, runs eval/queries.json
// through the real hybrid retriever, and reports recall at three settings so the
// FR-D3 reranker decision has numbers behind it. Never runs in CI: with the
// Ollama embedder it needs a local model, and it is slow by design.
//
//   swift run ainotebook-eval                          # offline lexical embedder
//   swift run ainotebook-eval --embedder ollama        # real embeddings
//
// Full options:
//   --corpus <dir>        default eval/corpus
//   --queries <file>      default eval/queries.json
//   --embedder lexical|nl|ollama   default lexical
//   --model <name>        default nomic-embed-text (ollama only)
//   --host <url>          default http://127.0.0.1:11434
//   --out <file.md>       also write a markdown report

// MARK: - Arguments

struct Options {
    var corpus = "eval/corpus"
    var queries = "eval/queries.json"
    var embedder = "lexical"
    var model = "nomic-embed-text"
    var host = "http://127.0.0.1:11434"
    var out: String?
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while let flag = args.first {
        args.removeFirst()
        func value() -> String {
            guard let v = args.first else {
                FileHandle.standardError.write(Data("missing value for \(flag)\n".utf8))
                exit(2)
            }
            args.removeFirst()
            return v
        }
        switch flag {
        case "--corpus":   o.corpus = value()
        case "--queries":  o.queries = value()
        case "--embedder": o.embedder = value()
        case "--model":    o.model = value()
        case "--host":     o.host = value()
        case "--out":      o.out = value()
        case "-h", "--help":
            print("""
            usage: ainotebook-eval [--corpus DIR] [--queries FILE]
                                   [--embedder lexical|nl|ollama] [--model NAME]
                                   [--host URL] [--out FILE.md]
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown flag \(flag)\n".utf8))
            exit(2)
        }
    }
    return o
}

// MARK: - Fixture decoding

struct GoldRef: Decodable { let doc: String; let phrase: String }
struct FixtureQuery: Decodable { let text: String; let gold: [GoldRef] }
struct Fixture: Decodable {
    let cut: Int
    let pool: Int
    let queries: [FixtureQuery]
}

/// Whitespace-insensitive comparison, so a gold phrase still matches after the
/// corpus file has been re-wrapped or the chunker has moved a line break.
func normalized(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

// MARK: - Offline embedder

/// Deterministic, dependency-free embedder for running the eval without a model
/// server. Hashes word tokens and character 4-grams into a fixed-width vector
/// (the "hashing trick"), so morphological variants overlap — "roasting" and
/// "roasted" share most of their 4-grams — while unrelated text stays close to
/// orthogonal.
///
/// This is a LEXICAL model with fuzzy matching, not a semantic one. It cannot
/// connect a query to a passage that shares no surface form, which real
/// sentence embeddings can. Any recall it reports is therefore a FLOOR for what
/// a real embedding model would achieve, and the gap is largest on
/// paraphrase-heavy queries. Interpret results accordingly.
struct LexicalHashingEmbedder: EmbeddingProducing {
    let dim: Int = 384

    private func fnv1a(_ s: some Sequence<UInt8>) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    private func tokens(_ text: String) -> [(String, Float)] {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
        var out: [(String, Float)] = []
        for w in words {
            out.append((w, 1.0))
            let padded = Array("^\(w)$")
            guard padded.count >= 4 else { continue }
            for i in 0...(padded.count - 4) {
                out.append((String(padded[i..<(i + 4)]), 0.45))
            }
        }
        return out
    }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        inputs.map { text in
            var counts: [String: (weight: Float, n: Float)] = [:]
            for (tok, w) in tokens(text) {
                counts[tok, default: (w, 0)].n += 1
            }
            var v = [Float](repeating: 0, count: dim)
            for (tok, entry) in counts {
                let h = fnv1a(Array(tok.utf8))
                let idx = Int(h % UInt64(dim))
                let sign: Float = (h >> 63) & 1 == 0 ? 1 : -1
                // Sublinear term frequency: the tenth occurrence of a word says
                // far less than the second.
                v[idx] += sign * entry.weight * (1 + log(entry.n))
            }
            var mag: Float = 0
            for x in v { mag += x * x }
            mag = mag.squareRoot()
            guard mag > 0 else { return v }
            return v.map { $0 / mag }
        }
    }
}

// MARK: - On-device semantic embedder

/// Semantic embedder built on Apple's NaturalLanguage framework, which ships
/// with macOS — no model server, no download, no network. Chunks are embedded
/// by averaging the sentence vectors they contain (falling back to word
/// vectors), then L2-normalising.
///
/// These are small, older static embeddings, well below a modern
/// sentence-transformer in quality, so they are not a substitute for the
/// `ollama` mode when a real decision needs the real pipeline. They are however
/// genuinely SEMANTIC — synonyms and paraphrases land near each other, which
/// `LexicalHashingEmbedder` cannot do at all. Running both brackets the answer:
/// lexical is a floor, NaturalLanguage a conservative middle.
final class NaturalLanguageEmbedder: EmbeddingProducing, @unchecked Sendable {
    private let lock = NSLock()
    private let sentence = NLEmbedding.sentenceEmbedding(for: .english)
    private let word = NLEmbedding.wordEmbedding(for: .english)

    var isAvailable: Bool { sentence != nil || word != nil }
    var dimension: Int { sentence?.dimension ?? word?.dimension ?? 0 }

    private func vector(for text: String) -> [Float] {
        let dim = dimension
        guard dim > 0 else { return [] }
        var sum = [Double](repeating: 0, count: dim)
        var n = 0

        if let sentence {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if let v = sentence.vector(for: String(text[range])) {
                    for i in 0..<min(dim, v.count) { sum[i] += v[i] }
                    n += 1
                }
                return true
            }
        }
        if n == 0, let word {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = text
            tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
                if let v = word.vector(for: String(text[range]).lowercased()) {
                    for i in 0..<min(dim, v.count) { sum[i] += v[i] }
                    n += 1
                }
                return true
            }
        }
        guard n > 0 else { return [Float](repeating: 0, count: dim) }

        var out = sum.map { Float($0 / Double(n)) }
        var mag: Float = 0
        for x in out { mag += x * x }
        mag = mag.squareRoot()
        if mag > 0 { out = out.map { $0 / mag } }
        return out
    }

    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        // `withLock` rather than lock/defer-unlock: the scoped form is the one
        // that is legal to call from an async context, and nothing inside
        // suspends, so holding it across the whole batch is fine.
        lock.withLock { inputs.map(vector(for:)) }
    }
}

// MARK: - Reporting types

struct Measurement {
    let label: String
    let cut: Int
    let fetch: Int
    let report: EvalReport
}

struct QueryDiagnostic {
    let query: String
    let goldRankInPool: Int?   // nil = never retrieved, even in the wide window
}

// MARK: - Run

let opts = parseOptions()
let cwd = FileManager.default.currentDirectoryPath

func resolve(_ path: String) -> URL {
    path.hasPrefix("/") ? URL(fileURLWithPath: path)
                        : URL(fileURLWithPath: cwd).appendingPathComponent(path)
}

let corpusURL = resolve(opts.corpus)
let queriesURL = resolve(opts.queries)

let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: queriesURL))

let docURLs = try FileManager.default
    .contentsOfDirectory(at: corpusURL, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "md" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !docURLs.isEmpty else {
    FileHandle.standardError.write(Data("no .md documents in \(corpusURL.path)\n".utf8))
    exit(1)
}

let embedder: EmbeddingProducing
switch opts.embedder {
case "lexical":
    embedder = LexicalHashingEmbedder()
case "nl":
    let nl = NaturalLanguageEmbedder()
    guard nl.isAvailable else {
        FileHandle.standardError.write(Data("NaturalLanguage English embeddings unavailable\n".utf8))
        exit(1)
    }
    embedder = nl
case "ollama":
    guard let url = URL(string: opts.host) else {
        FileHandle.standardError.write(Data("bad --host \(opts.host)\n".utf8))
        exit(2)
    }
    let client = OllamaClient(baseURL: url)
    guard await client.detect() else {
        FileHandle.standardError.write(Data("""
        Ollama is not reachable at \(opts.host).
        Start it, pull the embedding model, then re-run:
          ollama pull \(opts.model)

        """.utf8))
        exit(1)
    }
    embedder = client
default:
    FileHandle.standardError.write(Data("--embedder must be 'lexical', 'nl' or 'ollama'\n".utf8))
    exit(2)
}

let modelKey: String
switch opts.embedder {
case "ollama": modelKey = opts.model
case "nl":     modelKey = "apple-nl-sentence"
default:       modelKey = "lexical-hashing-384"
}

print("corpus:   \(docURLs.count) documents from \(corpusURL.path)")
print("queries:  \(fixture.queries.count) from \(queriesURL.lastPathComponent)")
print("embedder: \(opts.embedder) (\(modelKey))")
print("")

// 1) Ingest — real Chunker, real store, so chunk boundaries match production.
let store = try NotebookStore(path: .inMemory)
let notebook = try store.createNotebook(name: "D2 eval")
let notebookId = notebook.id!

var chunksByDoc: [String: [SourceChunk]] = [:]
var totalChunks = 0
for url in docURLs {
    let name = url.deletingPathExtension().lastPathComponent
    let text = try String(contentsOf: url, encoding: .utf8)
    let source = try store.createSource(
        notebookId: notebookId, type: .markdown, title: name, uri: nil, rawPath: url.path)
    try store.replaceChunks(sourceId: source.id!, chunks: Chunker.chunk(text))
    let chunks = try store.chunks(sourceId: source.id!)
    chunksByDoc[name] = chunks
    totalChunks += chunks.count
}
print("ingested: \(totalChunks) chunks")

// 2) Embed every chunk, batched the way the production Embedder batches.
var embedded = 0
for (_, chunks) in chunksByDoc {
    for batch in stride(from: 0, to: chunks.count, by: 16).map({
        Array(chunks[$0..<min($0 + 16, chunks.count)])
    }) {
        let vectors = try await embedder.embed(model: modelKey, inputs: batch.map(\.embeddingText))
        for (chunk, vector) in zip(batch, vectors) {
            try store.storeEmbedding(
                chunkId: chunk.id!, model: modelKey, vector: EmbeddingVector(values: vector))
        }
        embedded += batch.count
    }
}
print("embedded: \(embedded) chunks")

// 3) Resolve every gold phrase to exactly one chunk. A phrase matching zero or
//    several chunks is a broken fixture, not a retrieval result, so fail loudly
//    rather than quietly scoring against the wrong target.
var evalQueries: [EvalQuery] = []
var fixtureErrors: [String] = []
for q in fixture.queries {
    var goldIds: Set<Int64> = []
    for ref in q.gold {
        guard let chunks = chunksByDoc[ref.doc] else {
            fixtureErrors.append("query \"\(q.text)\": no document named \(ref.doc)")
            continue
        }
        let needle = normalized(ref.phrase)
        let matches = chunks.filter { normalized($0.text).contains(needle) }
        switch matches.count {
        case 1: goldIds.insert(matches[0].id!)
        case 0: fixtureErrors.append("query \"\(q.text)\": phrase not found in \(ref.doc): \(ref.phrase)")
        default:
            fixtureErrors.append(
                "query \"\(q.text)\": phrase spans \(matches.count) chunks in \(ref.doc) — "
                + "make it more specific: \(ref.phrase)")
        }
    }
    evalQueries.append(EvalQuery(text: q.text, goldChunkIds: goldIds))
}

if !fixtureErrors.isEmpty {
    FileHandle.standardError.write(Data(("\nfixture errors:\n  "
        + fixtureErrors.joined(separator: "\n  ") + "\n").utf8))
    exit(1)
}

// 4) Measure. Three settings, one question each.
let retriever = Retriever(store: store, client: embedder, model: modelKey)
let cut = fixture.cut
let pool = fixture.pool

let production = Measurement(
    label: "production", cut: cut, fetch: cut,
    report: try await RetrievalEval.run(
        retriever: retriever, notebookId: notebookId, queries: evalQueries, k: cut, fetchK: cut))

let wideFetch = Measurement(
    label: "wide fetch, same cut", cut: cut, fetch: pool,
    report: try await RetrievalEval.run(
        retriever: retriever, notebookId: notebookId, queries: evalQueries, k: cut, fetchK: pool))

let ceiling = Measurement(
    label: "candidate pool", cut: pool, fetch: pool,
    report: try await RetrievalEval.run(
        retriever: retriever, notebookId: notebookId, queries: evalQueries, k: pool, fetchK: pool))

// 4b) Cut sweep. A reranker's actual value proposition is "recall of a wide cut
//     at the context cost of a narrow one", so the honest comparison is against
//     simply widening the cut, which costs nothing but prompt tokens.
var sweep: [(cut: Int, recall: Double)] = []
for c in [4, 8, 12, 16, 20, pool].filter({ $0 <= pool }) {
    let r = try await RetrievalEval.run(
        retriever: retriever, notebookId: notebookId, queries: evalQueries, k: c, fetchK: pool)
    sweep.append((c, r.meanRecall))
}

// 5) Per-query diagnostics: where does each gold chunk actually sit in the wide
//    window? That is what says whether a failure is a ranking problem (a
//    reranker could fix it) or a retrieval problem (it could not).
var diagnostics: [QueryDiagnostic] = []
for q in evalQueries {
    let hits = try await retriever.search(notebookId: notebookId, query: q.text, topK: pool)
    let rank = hits.firstIndex { q.goldChunkIds.contains($0.chunkId) }
    diagnostics.append(QueryDiagnostic(query: q.text, goldRankInPool: rank.map { $0 + 1 }))
}

let missedEntirely = diagnostics.filter { $0.goldRankInPool == nil }
let rankedBelowCut = diagnostics.filter { ($0.goldRankInPool ?? 0) > cut }
let headroom = ceiling.report.meanRecall - wideFetch.report.meanRecall
let wideFetchGain = wideFetch.report.meanRecall - production.report.meanRecall

func pct(_ x: Double) -> String { String(format: "%.3f", x) }

print("")
print("  recall@\(cut)  (fetch \(cut))   = \(pct(production.report.meanRecall))   <- production pipeline")
print("  recall@\(cut)  (fetch \(pool))  = \(pct(wideFetch.report.meanRecall))   <- wider window, same cut")
print("  recall@\(pool) (fetch \(pool))  = \(pct(ceiling.report.meanRecall))   <- candidate-pool ceiling")
print("")
print("  wide-fetch gain      = \(pct(wideFetchGain))  (free — no reranker needed)")
print("  reranker headroom    = \(pct(headroom))  (ceiling minus wide-fetch cut)")
print("")
print("  gold below the cut but inside the pool: \(rankedBelowCut.count)/\(evalQueries.count)")
print("  gold missing from the pool entirely:    \(missedEntirely.count)/\(evalQueries.count)")
print("")
print("  cut sweep (fetch \(pool)) — what widening the cut alone would buy:")
for step in sweep { print("    recall@\(step.cut)\t= \(pct(step.recall))") }

if !missedEntirely.isEmpty {
    print("\n  never retrieved (retrieval failure — a reranker cannot help these):")
    for d in missedEntirely { print("    - \(d.query)") }
}
if !rankedBelowCut.isEmpty {
    print("\n  retrieved but ranked too low (a reranker could plausibly help these):")
    for d in rankedBelowCut.sorted(by: { ($0.goldRankInPool ?? 0) < ($1.goldRankInPool ?? 0) }) {
        print("    - rank \(d.goldRankInPool!): \(d.query)")
    }
}

// 6) Optional markdown report.
if let out = opts.out {
    var md = """
    # Retrieval eval — recall@\(cut) (FR-D2)

    | setting | fetch | cut | mean recall | hit rate |
    |---|---|---|---|---|
    """
    for m in [production, wideFetch, ceiling] {
        md += "\n| \(m.label) | \(m.fetch) | \(m.cut) | \(pct(m.report.meanRecall)) | \(pct(m.report.hitRate)) |"
    }
    md += """


    - corpus: \(docURLs.count) documents, \(totalChunks) chunks
    - queries: \(evalQueries.count)
    - embedder: \(opts.embedder) (\(modelKey))
    - wide-fetch gain: \(pct(wideFetchGain))
    - reranker headroom: \(pct(headroom))
    - gold below cut but inside pool: \(rankedBelowCut.count)/\(evalQueries.count)
    - gold missing from pool: \(missedEntirely.count)/\(evalQueries.count)

    ## Cut sweep (fetch \(pool))

    What simply returning more chunks would buy, with no reranker at all.

    | cut | mean recall |
    |---|---|
    """
    for step in sweep { md += "\n| \(step.cut) | \(pct(step.recall)) |" }
    md += """


    ## Per-query gold rank in the \(pool)-candidate window

    | rank | query |
    |---|---|
    """
    for d in diagnostics {
        md += "\n| \(d.goldRankInPool.map(String.init) ?? "—") | \(d.query) |"
    }
    md += "\n"
    try md.write(to: resolve(out), atomically: true, encoding: .utf8)
    print("\nwrote \(out)")
}
