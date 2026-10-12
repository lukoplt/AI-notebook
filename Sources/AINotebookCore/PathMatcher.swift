import Foundation

/// One in-scope file as the path matcher sees it.
public struct PathMatchFile: Sendable, Equatable {
    public let sourceId: Int64
    public let relPath: String?
    public let title: String
    /// Seconds since 1970 (UTC), when known.
    public let mtime: Int64?
    public init(sourceId: Int64, relPath: String?, title: String, mtime: Int64?) {
        self.sourceId = sourceId
        self.relPath = relPath
        self.title = title
        self.mtime = mtime
    }
}

public struct PathMatch: Sendable, Equatable {
    public let sourceId: Int64
    /// Query content tokens matched by the path, title or date signals.
    public let matched: Int
    /// v2 (§6): Σ of matched terms' strengths (year segment 3, year key/date 2, undated mtime 1;
    /// other terms 2 in a directory, 1 in the name only).
    public let score: Int
    /// Σ over matched tokens of (files − files matching that token): rarer terms weigh more.
    public let weight: Int
    /// YYYYMMDD from the file name, else the path, else mtime (UTC); 0 when unknown.
    public let date: Int
    /// v2 (§6): the file's project directory (relative), "" for top-level and loose files.
    public let project: String

    public init(sourceId: Int64, matched: Int, score: Int, weight: Int, date: Int, project: String) {
        self.sourceId = sourceId
        self.matched = matched
        self.score = score
        self.weight = weight
        self.date = date
        self.project = project
    }
}

/// The best path-matching tier and whether the question is an inventory question
/// (a year or document-type term matched): retrieval-paths v2 (§6).
public struct PathRanking: Sendable, Equatable {
    public let matches: [PathMatch]
    public let inventory: Bool
    public static let none = PathRanking(matches: [], inventory: false)
}

/// retrieval-paths-v1 (`docs/contracts/retrieval-paths-v1.md`, fixture `retrieval-paths-v1.json`):
/// ranks files whose relative path and title match the question's fts-query-v2 content tokens.
public struct PathMatcher: Sendable {
    public static let maxMatchingFiles = 30
    private let builder: FTSQueryBuilder
    public init(tables: UnicodeTables) { builder = FTSQueryBuilder(tables: tables) }

    /// Token keys of a path/title are pure functions of the text: tokenizing thousands of paths
    /// per question dominated the query, so they are memoized process-wide (bounded).
    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [String]] = [:]
        func keys(_ text: String, _ make: (String) -> [String]) -> [String] {
            if let hit = lock.withLock({ entries[text] }) { return hit }
            let made = make(text)
            lock.withLock {
                if entries.count >= 200_000 { entries.removeAll(keepingCapacity: true) }
                entries[text] = made
            }
            return made
        }
    }
    private static let cache = KeyCache()
    private func keys(_ text: String) -> [String] { Self.cache.keys(text) { builder.keys($0) } }

    /// v2 (§6) document-type classes in key form; first class whose stem prefixes a term wins.
    public static let typeClasses: [(name: String, stems: [String])] = [
        ("offer", ["nabid", "ponuk", "offer", "proposal", "quotation", "angebot"]),
        ("order", ["objednav", "order", "bestell"]),
        ("contract", ["smlouv", "smluv", "zmluv", "contract", "agreement", "vertrag"]),
        ("invoice", ["faktur", "invoice", "rechnung"]),
        ("tender", ["vyberov", "tender", "ausschreib"]),
    ]

    static func typeStems(_ key: String) -> [String]? {
        typeClasses.first { $0.stems.contains { key.hasPrefix($0) } }?.stems
    }

    private struct Term {
        let key: String
        let stem: String?
        let year: Int?
        let types: [String]?
    }

    private static func digits(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy { $0.value >= 0x30 && $0.value <= 0x39 }
    }

    private static func validDate(_ key: String) -> Int? {
        guard key.unicodeScalars.count == 8, digits(key), let value = Int(key) else { return nil }
        let year = value / 10_000, month = value / 100 % 100, day = value % 100
        guard (1900...2099).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        return value
    }

    private static func utcDate(_ seconds: Int64) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return parts.year! * 10_000 + parts.month! * 100 + parts.day!
    }

    private func terms(_ query: String) -> [Term] {
        builder.contentTokens(query).map { token in
            let year = token.key.unicodeScalars.count == 4 && Self.digits(token.key) ? Int(token.key).flatMap { (1900...2099).contains($0) ? $0 : nil } : nil
            return Term(key: token.key, stem: token.stem, year: year, types: year == nil ? Self.typeStems(token.key) : nil)
        }
    }

    static func yearSegment(_ segment: String) -> Bool {
        guard segment.unicodeScalars.count == 4, digits(segment), let value = Int(segment) else { return false }
        return (1900...2099).contains(value)
    }

    private static func hit(_ term: Term, _ keys: [String], _ keySet: Set<String>) -> Bool {
        if let stem = term.stem, keys.contains(where: { $0.hasPrefix(stem) }) { return true }
        if let types = term.types, keys.contains(where: { key in types.contains { key.hasPrefix($0) } }) { return true }
        return term.stem == nil && keySet.contains(term.key)
    }

    /// 0 = no match. Year: 3 when a directory segment is the year, 2 when a key is the year or a
    /// date of that year, 1 when only the mtime of a file without any path/name year has it.
    /// Other terms: 2 when a directory key matches, 1 when only the name or title does.
    private static func strength(_ term: Term, file: PathMatchFile, segments: [String], dirKeys: [String], dirSet: Set<String>,
                                 nameKeys: [String], nameSet: Set<String>) -> Int {
        if let year = term.year {
            let text = String(year)
            if segments.contains(text) { return 3 }
            let keys = dirKeys + nameKeys
            if dirSet.contains(text) || nameSet.contains(text) || keys.contains(where: { (validDate($0) ?? 0) / 10_000 == year }) { return 2 }
            let dated = segments.contains(where: yearSegment) || keys.contains { validDate($0) != nil }
            guard !dated, let mtime = file.mtime else { return 0 }
            return utcDate(mtime) / 10_000 == year ? 1 : 0
        }
        if hit(term, dirKeys, dirSet) { return 2 }
        return hit(term, nameKeys, nameSet) ? 1 : 0
    }

    /// The directory below the last year segment, else the parent of the first type folder
    /// (below the top level), else the file's own directory.
    private func project(_ segments: [String]) -> String {
        if let year = segments.lastIndex(where: Self.yearSegment) {
            return segments.prefix(min(year + 2, segments.count)).joined(separator: "/")
        }
        for (index, segment) in segments.enumerated() where index > 0 {
            if keys(segment).contains(where: { Self.typeStems($0) != nil }) { return segments.prefix(index).joined(separator: "/") }
        }
        return segments.joined(separator: "/")
    }

    /// Files of the best match tier (most matched tokens, at least ⌈tokens / 2⌉), ordered by
    /// score, weight, date (newest first) and source id.
    public func rank(query: String, files: [PathMatchFile]) -> [PathMatch] {
        ranking(query: query, files: files).matches
    }

    public func ranking(query: String, files: [PathMatchFile]) -> PathRanking {
        let terms = terms(query)
        guard !terms.isEmpty, !files.isEmpty else { return .none }
        var rows: [(file: PathMatchFile, hits: [Int], score: Int, date: Int, segments: [String])] = []
        rows.reserveCapacity(files.count)
        for file in files {
            let path = file.relPath ?? ""
            let components = path.isEmpty ? [] : path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let segments = Array(components.dropLast())
            let name = file.relPath.map { String($0.split(separator: "/", omittingEmptySubsequences: false).last ?? "") } ?? file.title
            // "/" always ends a token, so the keys of `relPath/title` are the directory keys followed by
            // the `name/title` keys; files of one directory share its (memoized) directory keys.
            let dirKeys = self.keys(segments.joined(separator: "/"))
            let tailKeys = self.keys((components.last ?? "") + "/" + file.title)
            let keys = dirKeys + tailKeys
            let dirSet = Set(dirKeys), tailSet = Set(tailKeys)
            let strengths = terms.map { Self.strength($0, file: file, segments: segments, dirKeys: dirKeys, dirSet: dirSet,
                                                      nameKeys: tailKeys, nameSet: tailSet) }
            let nameKeys = self.keys(name)
            var date = nameKeys.compactMap(Self.validDate).last ?? keys.compactMap(Self.validDate).last ?? 0
            if date == 0, let mtime = file.mtime { date = Self.utcDate(mtime) }
            rows.append((file, strengths.indices.filter { strengths[$0] > 0 }, strengths.reduce(0, +), date, segments))
        }
        var df = [Int](repeating: 0, count: terms.count)
        for row in rows { for hit in row.hits { df[hit] += 1 } }
        let best = rows.map(\.hits.count).max() ?? 0
        guard best >= max(1, (terms.count + 1) / 2) else { return .none }
        let tier = rows.filter { $0.hits.count == best }
        let matches = tier.map { PathMatch(sourceId: $0.file.sourceId, matched: best, score: $0.score,
                                           weight: $0.hits.reduce(0) { $0 + files.count - df[$1] }, date: $0.date,
                                           project: project($0.segments)) }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                if a.weight != b.weight { return a.weight > b.weight }
                if a.date != b.date { return a.date > b.date }
                return a.sourceId < b.sourceId
            }
        let inventory = tier.contains { row in row.hits.contains { terms[$0].year != nil || terms[$0].types != nil } }
        return PathRanking(matches: matches, inventory: inventory)
    }
}
