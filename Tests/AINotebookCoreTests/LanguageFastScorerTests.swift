import Foundation
import XCTest
@testable import AINotebookCore

/// The label-only fast path (`LanguageScorer.fast`, used by ingestion) must decide
/// exactly what the full diagnostic scorer decides: label, reason, counts, winner,
/// runner-up, margin, coverage and every profile's combined score, for every
/// `lang-*` fixture input and a large deterministic synthetic corpus, on the
/// synthetic fixture models and the production model.
final class LanguageFastScorerTests: XCTestCase {
    private struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
    }

    private static let words: [String: [String]] = [
        "cs": "smlouva faktura dodavatel odběratel termín plnění příloha cena celkem objednávka zakázka projekt rozpočet schůzka zápis vedení společnost oddělení zaměstnanec mzda dovolená převod účet platba splatnost záloha dokument kontrola revize návrh schválení podpis ředitel jednatel že který také jsou byl".split(separator: " ").map(String.init),
        "sk": "zmluva faktúra dodávateľ odberateľ termín plnenia príloha cena spolu objednávka zákazka projekt rozpočet stretnutie zápisnica vedenie spoločnosť oddelenie zamestnanec mzda dovolenka prevod účet platba splatnosť záloha dokument kontrola revízia návrh schválenie podpis riaditeľ konateľ že ktorý tiež sú bol".split(separator: " ").map(String.init),
        "en": "contract invoice supplier customer deadline delivery appendix price total order project budget meeting minutes management company department employee salary holiday transfer account payment due deposit document review revision proposal approval signature director board the which also are was".split(separator: " ").map(String.init),
        "de": "Vertrag Rechnung Lieferant Kunde Frist Lieferung Anlage Preis gesamt Bestellung Auftrag Projekt Budget Besprechung Protokoll Leitung Gesellschaft Abteilung Mitarbeiter Gehalt Urlaub Überweisung Konto Zahlung Fälligkeit Anzahlung Dokument Prüfung Straße größer daß welcher auch sind war".split(separator: " ").map(String.init),
    ]
    /// Odd pieces: combining marks (attached, leading, stacked), decomposed and
    /// precomposed letters, case-fold expansions, Hangul, CJK, supplementary letters
    /// and marks, emoji, digits, punctuation, controls and non-characters.
    private static let oddities: [String] = [
        "e\u{301}", "\u{301}", "a\u{323}\u{302}", "\u{0308}x", "ﬀ", "ß", "ẞ", "İ", "ǅ", "Ωmega", "ΣΑΣ", "ﬁle",
        "한국어", "\u{1100}\u{1161}\u{11A8}", "中文字", "𝐀𝐁𝐂", "𐐀𐐨", "𝅘𝅥𝅮", "\u{1D167}", "😀", "👩‍💻", "123", "4,5",
        "—", "…", "\t", "\n\n", "\u{0}", "\u{FEFF}", "\u{FFFD}", "\u{E000}", "\u{10FFFD}", "ʼ", "ꙮ", "ـ", "x\u{20DD}",
        "Ǆemal", "ŉ", "ΐ", "\u{0345}", "ͅ", "ﬃ", "ΆΈΉ", "Ⅻ", "①", "\u{200D}", "\u{034F}",
    ]

    private static func sample(_ rng: inout SplitMix) -> String {
        let languages = ["cs", "sk", "en", "de"]
        var language = rng.pick(languages)
        let pieces = [0, 1, 2, 3, 5, 8, 13, 30, 80, 200, 600, 1500, 3000][rng.below(13)]
        var text = ""
        for i in 0..<pieces {
            if rng.below(40) == 0 { language = rng.pick(languages) } // mixed documents
            switch rng.below(20) {
            case 0: text += rng.pick(oddities)
            case 1: text += rng.pick(Self.words[language]!).uppercased()
            case 2: text += String(rng.pick(Self.words[language]!).reversed())
            case 3:
                let word = rng.pick(Self.words[language]!)
                text += String(word.prefix(1 + rng.below(max(word.count, 1))))
            case 4: text += String(UnicodeScalar(UInt8(33 + rng.below(94))))
            default: text += rng.pick(Self.words[language]!)
            }
            if i + 1 < pieces { text += rng.pick([" ", " ", " ", ", ", ". ", "\n", "-", "", "  "]) }
        }
        return text
    }

    private func assertSame(_ scorer: LanguageScorer, _ stream: [UInt32], _ name: String) {
        let slice = Array(stream.prefix(scorer.model.parameters.textCapScalars))
        let full = scorer.score(slice), fast = scorer.fast.decide(slice)
        let expected = LanguageTextDecision(
            label: full.label, reason: full.reason, letterCount: full.letterCount, wordCount: full.wordCount,
            winner: full.winner, runnerUp: full.runnerUp, margin: full.margin, coverageBp: full.coverageBp,
            combinedScores: scorer.model.profiles.map { full.profiles[$0.id]!.combinedScore })
        XCTAssertEqual(fast, expected, name)
    }

    private func assertSameDocument(_ scorer: LanguageScorer, _ stream: [UInt32], _ name: String) {
        let full = LanguageDocument.detect(stream: stream, scorer: scorer)
        let fast = scorer.fast.decideDocument(stream: stream)
        let expected = LanguageAggregate(sampledLetters: full.sampledLetters, acceptedLetters: full.acceptedLetters,
            unknownLetters: full.unknownLetters, sharesBp: full.sharesBp, unknownShareBp: full.unknownShareBp,
            langCoverageBp: full.langCoverageBp, label: full.label, reason: full.reason)
        XCTAssertEqual(fast, expected, name)
    }

    private func check(_ scorer: LanguageScorer, _ text: String, _ name: String) {
        let stream = LanguageNormalization.stream(text, tables: scorer.tables, cap: scorer.model.parameters.inputCapScalars)
        assertSame(scorer, stream, name)
        assertSameDocument(scorer, stream, name)
    }

    private func syntheticScorer(_ model: [String: Any], tables: UnicodeTables) throws -> LanguageScorer {
        let bytes = try JSONSerialization.data(withJSONObject: model) + Data([10])
        return LanguageScorer(model: try LanguageModel.parse(bytes, tables: tables, allowSynthetic: true), tables: tables)
    }

    private func productionScorer(tables: UnicodeTables) throws -> LanguageScorer {
        let data = try UnicodeTables.resourceData("lang-detector-v1.json")
        return LanguageScorer(model: try LanguageModel.parse(data, tables: tables, allowSynthetic: false), tables: tables)
    }

    func testFixtureInputsDecideIdentically() throws {
        let tables = try UnicodeTables.bundled()
        let score = try SharedFixtures.json("contracts/lang-score-v1.json")
        let model = try XCTUnwrap(score["model"] as? [String: Any])
        let synthetic = try syntheticScorer(model, tables: tables)
        let production = try productionScorer(tables: tables)
        var checked = 0
        for c in try XCTUnwrap(score["cases"] as? [[String: Any]]) {
            let input = try XCTUnwrap(c["input"] as? String), name = try XCTUnwrap(c["name"] as? String)
            check(synthetic, input, name)
            check(production, input, name + " (production)")
            checked += 1
        }
        // Supplemental score cases run on their own model variants.
        for c in try XCTUnwrap(SharedFixtures.json("contracts/lang-runtime-v1.json")["cases"] as? [[String: Any]])
            where c["operation"] as? String == "score" {
            var object = model
            for (key, value) in try XCTUnwrap(c["modelOverrides"] as? [String: Any]) {
                if key == "parameters" {
                    var parameters = try XCTUnwrap(object[key] as? [String: Any])
                    for (field, replacement) in try XCTUnwrap(value as? [String: Any]) { parameters[field] = replacement }
                    object[key] = parameters
                } else { object[key] = value }
            }
            let input = try XCTUnwrap(c["input"] as? String), name = try XCTUnwrap(c["name"] as? String)
            check(try syntheticScorer(object, tables: tables), input, name)
            check(production, input, name + " (production)")
            checked += 1
        }
        for c in try XCTUnwrap(SharedFixtures.json("contracts/lang-release-v1.json")["cases"] as? [[String: Any]]) {
            let input = try XCTUnwrap(c["input"] as? String), name = try XCTUnwrap(c["name"] as? String)
            check(production, input, name)
            check(synthetic, input, name + " (synthetic)")
            checked += 1
        }
        XCTAssertEqual(checked, 32 + 6 + 844)
    }

    func testSyntheticCorpusDecidesIdentically() throws {
        let tables = try UnicodeTables.bundled()
        let synthetic = try syntheticScorer(try XCTUnwrap(SharedFixtures.json("contracts/lang-score-v1.json")["model"] as? [String: Any]),
                                            tables: tables)
        let production = try productionScorer(tables: tables)
        var rng = SplitMix(state: 0x1A2B_3C4D)
        var labels: [String: Int] = [:]
        // AINOTEBOOK_LANG_FAST_CASES raises the corpus size (e.g. 20000 in a release build).
        let count = Int(ProcessInfo.processInfo.environment["AINOTEBOOK_LANG_FAST_CASES"] ?? "") ?? 300
        for index in 0..<count {
            let text = Self.sample(&rng)
            check(production, text, "synthetic-\(index)")
            if index % 4 == 0 { check(synthetic, text, "synthetic-\(index) (synthetic model)") }
            labels[production.fast.decide(Array(LanguageNormalization.stream(text, tables: tables, cap: 8192))).label, default: 0] += 1
        }
        // The corpus exercises accepted labels of every target and abstentions.
        for label in ["cs", "de", "en", "sk", "und"] { XCTAssertGreaterThan(labels[label, default: 0], 0, label) }
    }

    /// The detector entry points ingestion uses agree with the diagnostic ones.
    func testDetectorDecisionsMatchDiagnostics() throws {
        let detector = LanguageDetector.bundled()
        XCTAssertTrue(detector.isAvailable)
        var rng = SplitMix(state: 42)
        for index in 0..<60 {
            let text = Self.sample(&rng)
            let full = try XCTUnwrap(detector.detectText(text)), fast = try XCTUnwrap(detector.decideText(text))
            XCTAssertEqual([fast.label, fast.reason], [full.label, full.reason], "text \(index)")
            let document = try XCTUnwrap(detector.detectDocument(text)), aggregate = try XCTUnwrap(detector.decideDocument(text))
            XCTAssertEqual([aggregate.label, aggregate.reason], [document.label, document.reason], "document \(index)")
            XCTAssertEqual(aggregate.sharesBp, document.sharesBp, "document \(index)")
            XCTAssertEqual(aggregate.langCoverageBp, document.langCoverageBp, "document \(index)")
        }
        XCTAssertNil(LanguageDetector.unavailable.decideText("text"))
        XCTAssertNil(LanguageDetector.unavailable.decideDocument("text"))
    }

    /// Opt-in (AINOTEBOOK_CPU_BENCH=1): normalization, full scorer and fast path on
    /// chunk-sized synthetic prose with the production model.
    func testBenchmarkFullVersusFast() throws {
        guard ProcessInfo.processInfo.environment["AINOTEBOOK_CPU_BENCH"] == "1" else {
            throw XCTSkip("set AINOTEBOOK_CPU_BENCH=1 to run the language scorer benchmark")
        }
        let tables = try UnicodeTables.bundled()
        let production = try productionScorer(tables: tables)
        var rng = SplitMix(state: 7)
        var texts: [String] = []
        for _ in 0..<2000 {
            var text = "", language = rng.pick(["cs", "sk", "en", "de"])
            while text.unicodeScalars.count < 1800 {
                if rng.below(60) == 0 { language = rng.pick(["cs", "sk", "en", "de"]) }
                text += rng.pick(Self.words[language]!) + rng.pick([" ", " ", " ", ", ", ". "])
            }
            texts.append(text)
        }
        func seconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        }
        var streams: [[UInt32]] = []
        let normalize = seconds { streams = texts.map { LanguageNormalization.stream($0, tables: tables, cap: 5_000_000) } }
        var fullLabels: [String] = [], fastLabels: [String] = []
        let full = seconds { fullLabels = streams.map { production.score(Array($0.prefix(8192))).label } }
        let fast = seconds { fastLabels = streams.map { production.fast.decide(Array($0.prefix(8192))).label } }
        let fullDocument = seconds { _ = streams.map { LanguageDocument.detect(stream: $0, scorer: production).label } }
        let fastDocument = seconds { _ = streams.map { production.fast.decideDocument(stream: $0).label } }
        XCTAssertEqual(fullLabels, fastLabels)
        print(String(format: "LANG-BENCH swift %d chunks (~1800 scalars): normalize %.3fs | text full %.3fs fast %.3fs (%.1fx) | document full %.3fs fast %.3fs (%.1fx)",
                     texts.count, normalize, full, fast, full / max(fast, 1e-9), fullDocument, fastDocument,
                     fullDocument / max(fastDocument, 1e-9)))
    }
}
