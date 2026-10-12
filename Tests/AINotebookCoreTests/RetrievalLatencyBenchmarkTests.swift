import Foundation
import GRDB
import XCTest
@testable import AINotebookCore

private struct NoEmbedding: EmbeddingProducing {
    func embed(model: String, inputs: [String]) async throws -> [[Float]] { throw CancellationError() }
}

/// Deterministic xorshift64* stream; identical on every run so templates are reusable.
private struct BenchRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2_685_821_657_736_338_717
    }
    mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) * 2 - 1 }
}

/// Opt-in latency benchmark of the pinned retrieval path (AINOTEBOOK_RETRIEVAL_BENCH=1) on a
/// file-backed store shaped like a large spreadsheet-heavy folder: ~7.5k sources, ~500k chunks (mostly
/// spreadsheet rows), Czech prose documents and one active 768-d generation. Measures scope
/// resolution, the lexical branch, the vector branch and the fused query (searchEmbedded) for
/// typical Czech questions; the query vector is synthetic (embedding latency is excluded).
/// Uses only APIs that predate the retrieval-quality work, so an older checkout runs it too.
@MainActor
final class RetrievalLatencyBenchmarkTests: XCTestCase {
    private func setting(_ name: String, _ fallback: Int) -> Int {
        Int(ProcessInfo.processInfo.environment["AINOTEBOOK_RETRIEVAL_BENCH_\(name)"] ?? "") ?? fallback
    }

    nonisolated static let modelKey = "local:nomic-embed-text"

    /// Inflected Czech vocabulary (lemma forms), common function words and spreadsheet labels.
    private static let nouns = [
        "smlouva smlouvy smlouvě smlouvu smlouvou smluv smlouvami",
        "faktura faktury faktuře fakturu fakturou faktur fakturami",
        "dodavatel dodavatele dodavateli dodavatelem dodavatelů",
        "odběratel odběratele odběrateli odběratelem",
        "nájemné nájemného nájemným nájem nájmu",
        "lhůta lhůty lhůtě lhůtu lhůtou lhůt",
        "výpověď výpovědi výpovědní výpovědní",
        "objednávka objednávky objednávce objednávku objednávkou objednávek",
        "zaměstnanec zaměstnance zaměstnanci zaměstnancem zaměstnanců",
        "projekt projektu projektem projekty projektů",
        "rozpočet rozpočtu rozpočtem rozpočty",
        "elektřina elektřiny elektřině elektřinu",
        "údržba údržby údržbě údržbu",
        "server serveru serverem servery",
        "reklamace reklamaci reklamací",
        "cena ceny ceně cenu cenou cen",
        "platba platby platbě platbu platbou plateb",
        "splatnost splatnosti splatností",
        "zakázka zakázky zakázce zakázku zakázek",
        "sklad skladu skladem sklady",
        "materiál materiálu materiálem materiály",
        "zboží", "služba služby službě službu služeb",
        "pojištění pojištěním", "doprava dopravy dopravě dopravu",
        "účetnictví", "daň daně dani daní", "mzda mzdy mzdě mzdu mezd",
        "pobočka pobočky pobočce pobočku", "oddělení", "porada porady poradě poradu",
        "zápis zápisu zápisem", "příloha přílohy příloze přílohu", "termín termínu termínem",
        "dodávka dodávky dodávce dodávku dodávek", "kontrola kontroly kontrole kontrolu",
    ].map { $0.split(separator: " ").map(String.init) }
    private static let verbs = ["je", "jsou", "byl", "byla", "bude", "činí", "činila", "končí", "skončí", "platí",
                                "uhradí", "uhradil", "schválil", "schválila", "objednal", "dodal", "převzal", "zajistí",
                                "požaduje", "obsahuje", "uvádí", "stanoví", "navrhuje", "potvrdil"]
    private static let adjectives = ["rámcové", "kupní", "servisní", "měsíční", "roční", "celkové", "nové", "původní",
                                     "zálohové", "dílčí", "smluvní", "provozní", "technické", "obchodní", "finanční"]
    private static let function = ["a", "v", "na", "se", "s", "z", "do", "o", "k", "pro", "že", "to", "ve", "od",
                                   "po", "za", "který", "která", "které", "jak", "také", "podle", "při", "mezi"]
    private static let companies = ["Novák s.r.o.", "Dvořák a syn", "Elektro Morava a.s.", "Stavby Praha",
                                    "Svoboda Trading", "Krejčí Logistik", "Horák Servis", "Beneš IT"]

    static let queries = [
        "Jaká je výše nájemného ve smlouvě s dodavatelem?",
        "Kdy končí výpovědní lhůta u rámcové smlouvy?",
        "Kolik činila faktura za elektřinu v březnu 2024?",
        "Které faktury jsou po splatnosti?",
        "Jaké jsou platební podmínky v kupní smlouvě?",
        "Kdo je kontaktní osoba pro reklamace zboží?",
        "Jaký je celkový rozpočet projektu na rok 2025?",
        "Najdi objednávku od firmy Novák ohledně dodávky materiálu",
        "Jaká je cena za údržbu serveru?",
        "Kolik zaměstnanců má pobočka v Brně?",
        "What is the total budget of the project?",
        "Wann endet die Kündigungsfrist des Vertrags?",
    ]

    private static func sentence(_ random: inout BenchRandom) -> String {
        var words: [String] = []
        let length = 8 + random.below(10)
        for i in 0..<length {
            switch (i + random.below(3)) % 5 {
            case 0, 3: words.append(function[random.below(function.count)])
            case 1:
                let lemma = nouns[min(nouns.count - 1, random.below(nouns.count) * random.below(nouns.count) / nouns.count)]
                words.append(lemma[random.below(lemma.count)])
            case 2: words.append(random.below(2) == 0 ? verbs[random.below(verbs.count)] : adjectives[random.below(adjectives.count)])
            default: words.append(random.below(4) == 0 ? String(random.below(100_000)) : function[random.below(function.count)])
            }
        }
        return words.joined(separator: " ").prefix(1).uppercased() + words.joined(separator: " ").dropFirst() + ". "
    }

    private static func sheetRow(sheet: Int, row: Int, _ random: inout BenchRandom) -> String {
        let lemma = nouns[random.below(nouns.count)]
        let label = lemma[0].prefix(1).uppercased() + lemma[0].dropFirst()
        let cells = [
            "A\(row): \(label) \(["FV", "OBJ", "SML", "DL"][random.below(4)])-\(2020 + random.below(6))-\(String(format: "%05d", random.below(99_999)))",
            "B\(row): \(random.below(500_000)) Kč",
            "C\(row): \(companies[random.below(companies.count)])",
            "D\(row): \(1 + random.below(28)).\(1 + random.below(12)).\(2020 + random.below(6))",
            "E\(row): \(adjectives[random.below(adjectives.count)]) \(lemma[random.below(lemma.count)])",
            "F\(row): \(random.below(1000)) ks",
        ]
        return cells.joined(separator: "\t")
    }

    private struct Shape {
        let sheets, sheetRows, docs, docChunks, dims, vectorCap: Int
        var name: String { "retrieval-bench-\(sheets)x\(sheetRows)-\(docs)x\(docChunks)-d\(dims)-v\(vectorCap).sqlite" }
    }

    /// Seeds once per shape into a template file (reused across runs and checkouts).
    private func template(_ shape: Shape) throws -> URL {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AINOTEBOOK_RETRIEVAL_BENCH_DIR"] ?? NSTemporaryDirectory())
        let url = directory.appendingPathComponent(shape.name)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let building = directory.appendingPathComponent("retrieval-bench-building-\(UUID().uuidString).sqlite")
        let started = Date()
        let store = try NotebookStore(path: StorePath(fileURL: building), configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.createNotebook(name: "bench").id)
        try store.runOnDatabase { db in
            var random = BenchRandom(42)
            try db.execute(sql: """
                INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,normalization,
                  query_format_version,doc_format_version,chunker_version,state,created_at,activated_at)
                VALUES (1,?,'local','bench','nomic-embed-text',NULL,?,'l2','1','1','2','active','2026-10-11','2026-10-11')
                """, arguments: [notebookId, shape.dims])
            let source = try db.makeStatement(sql: """
                INSERT INTO sources(notebook_id,type,title,status,ingested_at) VALUES (?,?,?,'ready','2026-10-11 00:00:00.000')
                """)
            let revision = try db.makeStatement(sql: """
                INSERT INTO source_revisions(source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                VALUES (?,1,?,'',1,2,'2026-10-11 00:00:00.000')
                """)
            let publish = try db.makeStatement(sql: "UPDATE sources SET current_revision=?,published_revision_id=? WHERE id=?")
            let chunk = try db.makeStatement(sql: """
                INSERT INTO source_chunks(source_id,ord,text,token_count,revision_id,char_start,char_end,lang) VALUES (?,?,?,?,?,0,0,'cs')
                """)
            let manifest = try db.makeStatement(sql: """
                INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state) VALUES (1,?,?,'done')
                """)
            let embedding = try db.makeStatement(sql: "INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES (?,1,?)")
            var vector = [Float](repeating: 0, count: shape.dims)
            func add(type: String, title: String, texts: [String], embedded: Int) throws {
                try source.execute(arguments: [notebookId, type, title])
                let sourceId = db.lastInsertedRowID
                try revision.execute(arguments: [sourceId, "h\(sourceId)"])
                let revisionId = db.lastInsertedRowID
                try publish.execute(arguments: [revisionId, revisionId, sourceId])
                try manifest.execute(arguments: [sourceId, revisionId])
                for (ord, text) in texts.enumerated() {
                    try chunk.execute(arguments: [sourceId, ord, text, text.utf8.count / 4, revisionId])
                    guard ord < embedded else { continue }
                    let chunkId = db.lastInsertedRowID
                    for i in vector.indices { vector[i] = random.unit() }
                    let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
                    try embedding.execute(arguments: [chunkId, data])
                }
            }
            for s in 0..<shape.sheets {
                var rows: [String] = []
                for r in 0..<shape.sheetRows {
                    var text = "## List\(1 + r / 50)\n"
                    for line in 0..<4 { text += Self.sheetRow(sheet: s, row: r * 4 + line + 2, &random) + "\n" }
                    rows.append(text)
                }
                try add(type: "xlsx", title: "tabulka-\(s).xlsx", texts: rows, embedded: min(shape.vectorCap, rows.count))
            }
            let kinds = ["pdf", "docx", "email", "pdf", "docx"]
            for d in 0..<shape.docs {
                var parts: [String] = []
                for _ in 0..<shape.docChunks {
                    var text = ""
                    while text.unicodeScalars.count < 1_200 { text += Self.sentence(&random) }
                    parts.append(text)
                }
                try add(type: kinds[d % kinds.count], title: "dokument-\(d).\(kinds[d % kinds.count])", texts: parts, embedded: parts.count)
            }
        }
        try FileManager.default.moveItem(at: building, to: url)
        print(String(format: "RETRIEVAL-BENCH template %@ built in %.0fs", shape.name, Date().timeIntervalSince(started)))
        return url
    }

    private struct Stats { let p50, p95, max: Double }
    private func stats(_ samples: [Double]) -> Stats {
        let sorted = samples.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int((Double(sorted.count) * q).rounded(.up)) - 1)] }
        return Stats(p50: at(0.5), p95: at(0.95), max: sorted.last ?? 0)
    }
    private func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 }

    func testPinnedRetrievalLatency() async throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_RETRIEVAL_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_RETRIEVAL_BENCH=1 to run the retrieval latency benchmark")
        }
        let shape = Shape(sheets: setting("SHEETS", 2_500), sheetRows: setting("SHEET_ROWS", 160),
                          docs: setting("DOCS", 5_000), docChunks: setting("DOC_CHUNKS", 20),
                          dims: setting("DIMS", 768), vectorCap: setting("VECTOR_CAP", 64))
        let reps = setting("REPS", 3), fetchK = setting("FETCHK", RagContractV1.Retrieval.fetchK)
        let seed = try template(shape)
        let store = try NotebookStore(path: StorePath(fileURL: seed), configuredEmbeddingModelKey: nil)
        let notebookId = try XCTUnwrap(store.notebooks.first?.id)
        let counts = try store.runOnDatabase { db in
            (try Int.fetchOne(db, sql: "SELECT count(*) FROM sources")!, try Int.fetchOne(db, sql: "SELECT count(*) FROM source_chunks")!,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM chunk_embeddings")!)
        }
        let tables = try UnicodeTables.bundled()
        let builder = FTSQueryBuilder(tables: tables)
        let cache = VectorMatrixCache()
        let retriever = Retriever(store: store, client: NoEmbedding(), modelKey: { Self.modelKey }, cache: cache, tables: tables)
        let reader = store.makeRetrievalReader()
        var random = BenchRandom(7)
        let vectors = Self.queries.map { _ in (0..<shape.dims).map { _ in random.unit() } }
        func resolve() throws -> ResolvedRetrievalScope {
            try XCTUnwrap(ScopeResolver.resolve(store: store, notebookId: notebookId, scope: .all, modelKey: Self.modelKey))
        }
        var resolveMs: [Double] = [], lexicalMs: [Double] = [], vectorMs: [Double] = [], fusedMs: [Double] = []
        var lexicalHits: [Int] = [], status = ""
        for round in 0...reps {
            let warm = round > 0
            for (index, query) in Self.queries.enumerated() {
                var start = DispatchTime.now().uptimeNanoseconds
                let lexicalSnapshot = try resolve()
                if warm { resolveMs.append(ms(start)) }
                start = DispatchTime.now().uptimeNanoseconds
                let lexical = try await reader.lexical(lexicalSnapshot, expression: builder.matchExpression(query), limit: fetchK)
                if warm { lexicalMs.append(ms(start)) } else { lexicalHits.append(lexical.count) }
                await lexicalSnapshot.close()

                start = DispatchTime.now().uptimeNanoseconds
                let vectorPool = try await retriever.searchEmbedded(snapshot: try resolve(), query: "", queryVector: vectors[index], fetchK: fetchK)
                if warm { vectorMs.append(ms(start)) }
                status = vectorPool.diagnostics.vectorStatus + (vectorPool.diagnostics.streamed ? "/streamed" : "/cached")
                await vectorPool.close()

                start = DispatchTime.now().uptimeNanoseconds
                let fused = try await retriever.searchEmbedded(snapshot: try resolve(), query: query, queryVector: vectors[index], fetchK: fetchK)
                if warm { fusedMs.append(ms(start)) }
                await fused.close()
                if !warm {
                    print(String(format: "RETRIEVAL-BENCH cold q%02d lexicalHits=%d fused=%d %@", index, lexical.count, fused.fused.count, status))
                }
            }
        }
        let cacheStats = await cache.statistics()
        for (name, samples) in [("resolve", resolveMs), ("lexical", lexicalMs), ("vector", vectorMs), ("fused", fusedMs)] {
            let s = stats(samples)
            print(String(format: "RETRIEVAL-BENCH swift %@ sources=%d chunks=%d vectors=%d dims=%d fetchK=%d n=%d: p50=%.1fms p95=%.1fms max=%.1fms",
                         name, counts.0, counts.1, counts.2, shape.dims, fetchK, samples.count, s.p50, s.p95, s.max))
        }
        print("RETRIEVAL-BENCH swift vectorStatus=\(status) cacheResidentBytes=\(cacheStats.residentBytes) loads=\(cacheStats.loadCount) lexicalHits=\(lexicalHits)")
    }
}
