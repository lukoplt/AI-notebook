import Foundation

/// FTS5 MATCH expressions for `chunks_fts` (and the path index), contract fts-query-v2
/// (`docs/contracts/fts-query-v2.md`, fixture `fts-query-v2.json`): the v1 tokenizer and
/// exact phrases, minus cs/sk/en/de function words, plus one stem-prefix phrase per
/// inflectable word. `matchExpressionV1` is the frozen folder-rag-v1 §7 builder.
public struct FTSQueryBuilder: Sendable {
    private let tables: UnicodeTables
    public init(tables: UnicodeTables) { self.tables = tables }

    public static let minStem = 4

    /// Function words in key form (simple lowercase of the NFD base scalars).
    public static let stopwords: [String: [String]] = [
        "cs": """
            a aby ale ani asi az bez bude budou by byl byla byli bylo co coz do i jak jaka jake
            jaky jakou jakym je jeho jeji jejich jen jsem jsi jsme jsou jste k kam kde kdo kdy kdyz ke
            kolik ktera ktere kteri kterou ktery kterym ma maji mame mate me mezi mi mit mu muze my na
            nad nam nas ne nebo neni nez o od ode on ona oni ono pod podle pokud po pro proc protoze
            pri s se si sve ta tak take tam te ten tedy tento teto tim to tom tomu toto tu ty u uz v
            ve vsak z za ze zda najdi najit ukaz rekni vypis uved
            """,
        "sk": """
            a aby aj ak ako aka ake aky akym ale alebo ani bez bol bola boli bolo by co do este i
            ich je jeho jej k kde kedy kolko kto ktora ktore ktori ktory ku lebo ma maju na nad nie o
            od po pod podla pre preco pri s sa si so som sme ste su ta tak tam to tu uz v vo z za ze
            zo
            """,
        "en": """
            a about an and are as at be been by can could did do does find for from had has have
            how i in is it its me my of on or our please should show tell that the their there these
            this those to was were what when where which who whom why will with would you your
            """,
        "de": """
            aber als am an auch auf aus bei bin bis bitte das dass dem der des die ein eine einem
            einen einer eines er es fur gibt hat haben ich im in ist mit nach nicht oder sein sich sie
            sind so um und uns uber von vom was wann warum welche welcher welches wer wie wir wo zu
            zum zur
            """,
    ].mapValues { Array(Set($0.split(whereSeparator: \.isWhitespace).map(String.init))).sorted() }

    /// Inflectional endings in key form, longest first (ties in code-unit order).
    public static let suffixes: [String] = Set("""
        ami emi ech ich ych ach ove ovi ova ovy ovu ost osti eho emu imu ymu ymi imi ou em om um am im
        ym ho mu ej ia ie iu a e i o u y en es s ing ed ungen ung
        """.split(whereSeparator: \.isWhitespace).map(String.init)).sorted {
            $0.unicodeScalars.count != $1.unicodeScalars.count
                ? $0.unicodeScalars.count > $1.unicodeScalars.count
                : $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) { $0.value < $1.value }
        }

    private static let stopKeys: Set<[UInt32]> = Set(stopwords.values.joined().map { $0.unicodeScalars.map(\.value) })
    private static let suffixKeys: [[UInt32]] = suffixes.map { $0.unicodeScalars.map(\.value) }

    private struct Token {
        let scalars: [UInt32]
        let groups: [[UInt32]]
        let key: [UInt32]
    }

    /// v1 tokenization (§7.1–2): NFC, then maximal L/N/Co runs continued by marks.
    private func runs(_ query: String) -> [[UInt32]] {
        var result: [[UInt32]] = [], run: [UInt32] = []
        for cp in tables.nfc(query.unicodeScalars.map(\.value)) {
            let category = tables.generalCategory(cp)
            let base = category.hasPrefix("L") || category.hasPrefix("N") || category == "Co"
            if base || (!run.isEmpty && category.hasPrefix("M")) { run.append(cp) }
            else if !run.isEmpty { result.append(run); run.removeAll(keepingCapacity: true) }
        }
        if !run.isEmpty { result.append(run) }
        return result
    }

    private static func string(_ scalars: [UInt32]) -> String {
        String(String.UnicodeScalarView(scalars.map { UnicodeScalar($0)! }))
    }
    private static func phrase(_ scalars: [UInt32]) -> String {
        "\"" + string(scalars).replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func token(_ scalars: [UInt32]) -> Token {
        var groups: [[UInt32]] = []
        for cp in tables.nfd(scalars) {
            if tables.generalCategory(cp).hasPrefix("M"), !groups.isEmpty { groups[groups.count - 1].append(cp) }
            else { groups.append([cp]) }
        }
        return Token(scalars: scalars, groups: groups, key: groups.map { tables.simpleLowercase($0[0]) })
    }

    private func prefixable(_ token: Token) -> Bool {
        guard token.groups.count >= Self.minStem,
              token.groups.allSatisfy({ tables.generalCategory($0[0]).hasPrefix("L") }) else { return false }
        // Acronyms and camel case stay exact (ZXQV must not match ZXQVR).
        return !token.groups.dropFirst().contains { ["Lu", "Lt"].contains(tables.generalCategory($0[0])) }
    }

    private static func stemLength(_ key: [UInt32]) -> Int {
        for suffix in suffixKeys where key.count - suffix.count >= minStem && key.suffix(suffix.count).elementsEqual(suffix) {
            return key.count - suffix.count
        }
        return key.count
    }

    /// The content tokens of a query (fts-query-v2 steps 1–4), in key form; used by the
    /// path/metadata search to test query terms against path segments.
    internal func contentTokens(_ query: String) -> [(text: String, key: String, stem: String?)] {
        content(query).map { token in
            (Self.string(token.scalars), Self.string(token.key),
             prefixable(token) ? Self.string(Array(token.key.prefix(Self.stemLength(token.key)))) : nil)
        }
    }

    /// Keys of every token of a text (fts-query-v2 steps 1–2), in order; for path matching.
    internal func keys(_ text: String) -> [String] {
        runs(text).map { Self.string(token($0).key) }
    }

    private func content(_ query: String) -> ArraySlice<Token> {
        var unique: [Token] = [], seen = Set<[UInt32]>()
        for run in runs(query) {
            let token = token(run)
            if seen.insert(token.key).inserted { unique.append(token) }
        }
        let content = unique.filter { !Self.stopKeys.contains($0.key) }
        return (content.isEmpty ? unique : content).prefix(RagContractV1.Retrieval.maxFtsTokens)
    }

    /// fts-query-v2. Nil when the query has no token (lexical branch empty).
    public func matchExpression(_ query: String) -> String? {
        var phrases: [String] = []
        for token in content(query) {
            phrases.append(Self.phrase(token.scalars))
            guard prefixable(token) else { continue }
            let stem = tables.nfc(Array(token.groups.prefix(Self.stemLength(token.key)).joined()))
            let prefix = Self.phrase(stem) + "*"
            if !phrases.contains(prefix) { phrases.append(prefix) }
        }
        return phrases.isEmpty ? nil : phrases.joined(separator: " OR ")
    }

    /// Frozen folder-rag-v1 §7 builder (fts-query-v1.json): every token exact, OR-joined.
    public func matchExpressionV1(_ query: String) -> String? {
        var tokens: [String] = [], seen = Set<[UInt32]>()
        for run in runs(query) where tokens.count < RagContractV1.Retrieval.maxFtsTokens && seen.insert(run).inserted {
            tokens.append(Self.phrase(run))
        }
        return tokens.isEmpty ? nil : tokens.joined(separator: " OR ")
    }
}
