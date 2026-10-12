import Foundation

public struct EvalOptions: Equatable, Sendable {
    public let root: String
    public let mode: String
    public let model: String?
    public let host: String
    public let topK: Int
    public let fetchK: Int
    public let jsonPath: String?
    public let markdownPath: String?
    public let validateOnly: Bool

    public static func parse(_ args: [String]) throws -> EvalOptions {
        let valued: Set<String> = ["--dataset", "--root", "--mode", "--model", "--host",
                                   "--top-k", "--fetch-k", "--json", "--out"]
        var seen = Set<String>(), values: [String: String] = [:], index = 0
        while index < args.count {
            let flag = args[index]
            guard (valued.contains(flag) || flag == "--validate-only"), seen.insert(flag).inserted
            else { throw EvalFailure("usage") }
            index += 1
            if flag == "--validate-only" { continue }
            guard index < args.count, !args[index].hasPrefix("--"), !args[index].isEmpty
            else { throw EvalFailure("usage") }
            values[flag] = args[index]
            index += 1
        }
        guard values["--dataset"] == "multilingual" else { throw EvalFailure("usage") }
        let mode = values["--mode"] ?? "lexical", model = values["--model"]
        guard ["lexical", "ollama"].contains(mode),
              mode == "ollama" ? model?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false : model == nil
        else { throw EvalFailure("usage") }
        func integer(_ flag: String, fallback: Int) throws -> Int {
            guard let text = values[flag] else { return fallback }
            guard text.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int32(text), value > 0 else { throw EvalFailure("usage") }
            return Int(value)
        }
        let topK = try integer("--top-k", fallback: 16), fetchK = try integer("--fetch-k", fallback: 32)
        guard fetchK >= topK else { throw EvalFailure("usage") }
        let host: String
        do { host = try ProviderAPIRoot.normalize(values["--host"] ?? "http://127.0.0.1:11434") }
        catch { throw EvalFailure("usage") }
        return EvalOptions(root: values["--root"] ?? "eval/multilingual", mode: mode, model: model,
            host: host, topK: topK, fetchK: fetchK, jsonPath: values["--json"], markdownPath: values["--out"],
            validateOnly: seen.contains("--validate-only"))
    }
}

public enum EvalRunner {
    public static func load(root: URL) throws -> (corpus: EvalCorpus, hash: String) {
        func read(_ relative: String) throws -> Data {
            guard EvalCorpus.safeRelativePath(relative) else { throw EvalFailure("invalid_path") }
            var url = root
            do {
                for component in relative.split(separator: "/") {
                    url.appendPathComponent(String(component))
                    if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                        throw EvalFailure("invalid_path")
                    }
                }
                return try Data(contentsOf: url)
            } catch let error as EvalFailure { throw error }
            catch { throw EvalFailure("missing_file") }
        }
        let manifest = try read("manifest.json"), queries = try read("queries.json")
        var rejectedPath = false
        do {
            let corpus = try EvalCorpus.load(manifest: manifest, queries: queries) { relative in
                do { return try read(relative) }
                catch let error as EvalFailure {
                    // The pure corpus reader maps file-reader errors to missing_file.
                    // Preserve this filesystem adapter's more specific path rejection.
                    rejectedPath = error.code == "invalid_path"
                    throw error
                }
            }
            return (corpus, EvalCorpus.sha256(manifest + Data([0]) + queries))
        } catch {
            if rejectedPath { throw EvalFailure("invalid_path") }
            throw error
        }
    }

    @MainActor
    public static func run(corpus: EvalCorpus, corpusHash: String, options: EvalOptions,
                           embedder: (any EmbeddingProducing)? = nil, pack: EvalPackHook? = nil) async throws -> EvalReportV1 {
        let includeVectors = options.mode == "ollama"
        let client: any EmbeddingProducing
        if includeVectors {
            guard let embedder, options.model?.isEmpty == false else { throw EvalFailure("invalid_embedding") }
            client = embedder
        } else {
            client = NoEvalEmbedding()
        }
        let model = options.model ?? "eval-lexical"
        let store = try NotebookStore(path: .inMemory)
        var notebookMap: [Int64: Int64] = [:], sourceMap: [Int64: Int64] = [:]
        var evidenceByChunk: [Int64: EvalEvidence] = [:]
        for notebookId in Set(corpus.documents.map { $0.metadata.notebookId }).sorted() {
            notebookMap[notebookId] = try store.createNotebook(name: "Multilingual eval \(notebookId)").id!
        }
        for loaded in corpus.documents.sorted(by: { $0.metadata.documentId < $1.metadata.documentId }) {
            try Task.checkCancellation()
            let d = loaded.metadata
            guard let notebookId = notebookMap[d.notebookId] else { throw EvalFailure("source_mapping") }
            let source = try store.createSource(notebookId: notebookId,
                type: d.path.hasSuffix(".txt") ? .text : .markdown, title: d.documentId, uri: nil, rawPath: nil)
            let sourceId = source.id!
            sourceMap[d.sourceId] = sourceId
            let windows = try EvalCorpus.windows(loaded.text)
            try store.replaceChunks(sourceId: sourceId, chunks: windows.map {
                ChunkDraft(text: $0.text, tokenCount: max(1, ($0.end - $0.start + 3) / 4))
            })
            let persisted = try store.chunks(sourceId: sourceId)
            guard persisted.count == windows.count else { throw EvalFailure("chunk_mapping") }
            // Compatibility ingestion reconstructs its own canonical text. Keep the
            // exact eval windows/hash here until WP7 adopts production scalar spans.
            for (chunk, window) in zip(persisted, windows) {
                evidenceByChunk[chunk.id!] = EvalEvidence(chunkId: chunk.id!,
                    span: EvalSpan(documentId: d.documentId, contentHash: d.contentHash,
                                   start: window.start, end: window.end), text: window.text)
            }
        }
        var dimensions: Int?
        if includeVectors {
            let evidence = evidenceByChunk.values.sorted { $0.chunkId < $1.chunkId }
            for start in stride(from: 0, to: evidence.count, by: 16) {
                try Task.checkCancellation()
                let batch = Array(evidence[start..<min(start + 16, evidence.count)])
                let vectors = try await client.embed(model: model, inputs: batch.map(\.text))
                guard vectors.count == batch.count, let dim = vectors.first?.count, dim > 0,
                      dimensions == nil || dimensions == dim,
                      vectors.allSatisfy({ $0.count == dim && $0.allSatisfy(\.isFinite) && $0.contains(where: { $0 != 0 }) })
                else { throw EvalFailure("invalid_embedding") }
                dimensions = dim
                // Validate the whole batch before committing any of its vectors.
                for (item, vector) in zip(batch, vectors) {
                    try store.storeEmbedding(chunkId: item.chunkId, model: model, vector: EmbeddingVector(values: vector))
                }
            }
        }
        let retriever = Retriever(store: store, client: client, model: model)
        var rows: [EvalQueryRow] = []
        for question in corpus.questions {
            try Task.checkCancellation()
            let selected = corpus.selectedDocuments(for: question)
            let sourceIds = Set(selected.compactMap { sourceMap[$0.metadata.sourceId] })
            guard sourceIds.count == selected.count, let notebookId = notebookMap[question.notebookId]
            else { throw EvalFailure("source_mapping") }
            let withChunks = selected.filter { !$0.text.unicodeScalars.isEmpty }.count
            if question.caseType == "overview" {
                rows.append(EvalQueryRow(queryId: question.queryId, text: question.text, language: question.language,
                    caseType: question.caseType, status: "deferred_overview_wp8", filesInScope: selected.count,
                    candidatesWithChunks: withChunks, lexical: [], vector: [], fused: [],
                    metrics: Dictionary(uniqueKeysWithValues: EvalMetrics.names.map { ($0, .notApplicable) })))
                continue
            }
            let hits = try await retriever.candidates(notebookId: notebookId, query: question.text,
                fetchK: options.fetchK, sourceIds: sourceIds, includeVectors: includeVectors)
            func hydrate(_ hits: [RetrievalHit]) throws -> [EvalEvidence] {
                try hits.map { hit in
                    guard let evidence = evidenceByChunk[hit.chunkId], sourceIds.contains(hit.sourceId)
                    else { throw EvalFailure("evidence_mapping") }
                    return evidence
                }
            }
            let lexical = try hydrate(hits.lexical), vector = try hydrate(hits.vector), fused = try hydrate(hits.fused)
            let packed: [EvalSpan]?
            if let pack { packed = sourceIds.isEmpty ? [] : try await pack(question, fused) }
            else { packed = nil }
            if let packed {
                let documents = Dictionary(uniqueKeysWithValues: selected.map { ($0.metadata.documentId, $0) })
                for span in packed {
                    guard let document = documents[span.documentId], span.contentHash == document.metadata.contentHash,
                          span.start >= 0, span.start < span.end, span.end <= document.text.unicodeScalars.count
                    else { throw EvalFailure("invalid_packed_span") }
                }
            }
            guard let gold = corpus.gold[question.queryId] else { throw EvalFailure("invalid_gold") }
            let metrics = try EvalMetrics.measure(gold: gold, lexical: lexical.map(\.span), fused: fused.map(\.span),
                topK: options.topK, includeVectors: includeVectors, packed: packed)
            rows.append(EvalQueryRow(queryId: question.queryId, text: question.text, language: question.language,
                caseType: question.caseType, status: "measured", filesInScope: selected.count, candidatesWithChunks: withChunks,
                lexical: lexical.map(\.span), vector: vector.map(\.span), fused: fused.map(\.span), metrics: metrics))
        }
        return EvalReportV1.assemble(corpus: corpus, corpusHash: corpusHash, platform: "macos", mode: options.mode,
            model: options.model, dimensions: dimensions, topK: options.topK, fetchK: options.fetchK,
            rows: rows, hasPackingHook: pack != nil)
    }
}

private struct NoEvalEmbedding: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        throw EvalFailure("unexpected_embedding")
    }
}
