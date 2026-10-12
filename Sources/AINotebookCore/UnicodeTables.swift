import CryptoKit
import Foundation

/// Unicode 15.1 data shared by language detection, glob matching and FTS.
/// Scalar operations deliberately do not use the operating system's Unicode data.
public struct UnicodeTables: Sendable {
    public enum LoadError: Error, Equatable {
        case missingResource(String)
        case hashMismatch
        case corruptData
        case incompatibleVersion
        case inconsistentTable
    }

    private struct Category: Decodable, Sendable {
        let start: UInt32
        let end: UInt32
        let name: String
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            start = try c.decode(UInt32.self)
            end = try c.decode(UInt32.self)
            name = try c.decode(String.self)
            guard c.isAtEnd else { throw LoadError.corruptData }
        }
    }
    private struct Mapping: Decodable {
        let scalar: UInt32
        let values: [UInt32]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            scalar = try c.decode(UInt32.self)
            values = try c.decode([UInt32].self)
            guard c.isAtEnd else { throw LoadError.corruptData }
        }
    }
    private struct Table: Decodable {
        let format: Int
        let unicodeVersion: String
        let normalizationTablesVersion: String
        let categories: [Category]
        let ccc: [[UInt32]]
        let decomposition: [Mapping]
        let compositionExclusions: [UInt32]
        let composition: [[UInt32]]
        let caseFold: [Mapping]
        let simpleLower: [[UInt32]]
    }
    private let categories: [Category]
    private let classes: [UInt32: UInt8]
    private let decomposition: [UInt32: [UInt32]]
    private let composition: [UInt64: UInt32]
    private let folds: [UInt32: [UInt32]]
    private let lowercase: [UInt32: UInt32]
    /// `wordClass` of every BMP scalar, precomputed from `categories`.
    private let wordClassBMP: [UInt8]
    /// Canonical combining class of every BMP scalar (the `classes` values).
    private let cccBMP: [UInt8]
    /// Per BMP scalar: `hasDecomposition`, `hasFold`, `composesAsSecond` (the
    /// dictionaries stay authoritative; a clear bit only skips a lookup that would miss).
    private let flagsBMP: [UInt8]
    private static let hasDecomposition: UInt8 = 1, hasFold: UInt8 = 2, composesAsSecond: UInt8 = 4

    static let normalizationVersion = "ucd-15.1.0-default-full-v1"
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isScalar(_ cp: UInt32) -> Bool {
        cp <= 0x10FFFF && !(0xD800...0xDFFF).contains(cp)
    }
    private static func pairKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        UInt64(a) << 32 | UInt64(b)
    }

    public init(data: Data, expectedSHA256: String) throws {
        guard Self.sha256(data) == expectedSHA256 else { throw LoadError.hashMismatch }
        let table: Table
        do { table = try JSONDecoder().decode(Table.self, from: data) }
        catch { throw LoadError.corruptData }
        guard table.format == 1, table.unicodeVersion == "15.1.0",
              table.normalizationTablesVersion == Self.normalizationVersion else {
            throw LoadError.incompatibleVersion
        }
        let categoryNames: Set<String> = ["Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No",
            "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So", "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co"]
        var lastEnd: UInt32?
        for row in table.categories {
            guard row.start <= row.end, row.end <= 0x10FFFF,
                  lastEnd.map({ $0 < row.start }) ?? true, categoryNames.contains(row.name) else {
                throw LoadError.inconsistentTable
            }
            lastEnd = row.end
        }
        func pairs(_ rows: [[UInt32]], valueValid: (UInt32) -> Bool) throws -> [UInt32: UInt32] {
            var result: [UInt32: UInt32] = [:]
            var previous: UInt32?
            for row in rows {
                guard row.count == 2, Self.isScalar(row[0]), valueValid(row[1]),
                      previous.map({ $0 < row[0] }) ?? true else { throw LoadError.inconsistentTable }
                previous = row[0]
                result[row[0]] = row[1]
            }
            return result
        }
        func mappings(_ rows: [Mapping]) throws -> [UInt32: [UInt32]] {
            var result: [UInt32: [UInt32]] = [:]
            var previous: UInt32?
            for row in rows {
                guard Self.isScalar(row.scalar), !row.values.isEmpty,
                      row.values.allSatisfy(Self.isScalar), row.values != [row.scalar],
                      previous.map({ $0 < row.scalar }) ?? true else { throw LoadError.inconsistentTable }
                previous = row.scalar
                result[row.scalar] = row.values
            }
            return result
        }
        let ccc = try pairs(table.ccc) { (1...255).contains($0) }
        let lower = try pairs(table.simpleLower, valueValid: Self.isScalar)
        guard lower.allSatisfy({ $0.key != $0.value }) else { throw LoadError.inconsistentTable }
        let decomposed = try mappings(table.decomposition)
        let fold = try mappings(table.caseFold)
        var excluded = Set<UInt32>()
        var lastExcluded: UInt32?
        for cp in table.compositionExclusions {
            guard Self.isScalar(cp), lastExcluded.map({ $0 < cp }) ?? true else { throw LoadError.inconsistentTable }
            excluded.insert(cp)
            lastExcluded = cp
        }
        var composed: [UInt64: UInt32] = [:]
        var lastPair: UInt64?
        for row in table.composition {
            guard row.count == 3, row.allSatisfy(Self.isScalar) else { throw LoadError.inconsistentTable }
            let key = Self.pairKey(row[0], row[1])
            guard lastPair.map({ $0 < key }) ?? true, !excluded.contains(row[2]),
                  decomposed[row[2]] == [row[0], row[1]], ccc[row[0], default: 0] == 0 else {
                throw LoadError.inconsistentTable
            }
            composed[key] = row[2]
            lastPair = key
        }
        for (cp, values) in decomposed where values.count == 2 && !excluded.contains(cp) {
            guard composed[Self.pairKey(values[0], values[1])] == cp else { throw LoadError.inconsistentTable }
        }
        // Validate the decomposition graph iteratively, so corrupt cycles or deep
        // chains cannot recurse on the call stack during loading or normalization.
        var visited = Set<UInt32>()
        for cp in decomposed.keys {
            var active = Set<UInt32>()
            var stack: [(UInt32, Bool)] = [(cp, false)]
            while let (node, exiting) = stack.popLast() {
                if exiting { active.remove(node); visited.insert(node); continue }
                if visited.contains(node) { continue }
                guard active.insert(node).inserted else { throw LoadError.inconsistentTable }
                stack.append((node, true))
                for child in decomposed[node, default: []].reversed() { stack.append((child, false)) }
            }
        }
        categories = table.categories
        var wordClasses = [UInt8](repeating: Self.otherClass, count: 0x10000)
        for row in table.categories where row.start <= 0xFFFF {
            let value = Self.wordClass(category: row.name)
            guard value != Self.otherClass else { continue }
            for cp in Int(row.start)...Int(min(row.end, 0xFFFF)) { wordClasses[cp] = value }
        }
        wordClassBMP = wordClasses
        var combining = [UInt8](repeating: 0, count: 0x10000), flags = [UInt8](repeating: 0, count: 0x10000)
        for (cp, value) in ccc where cp <= 0xFFFF { combining[Int(cp)] = UInt8(value) }
        for cp in decomposed.keys where cp <= 0xFFFF { flags[Int(cp)] |= Self.hasDecomposition }
        for cp in fold.keys where cp <= 0xFFFF { flags[Int(cp)] |= Self.hasFold }
        for key in composed.keys where key & 0xFFFF_FFFF <= 0xFFFF { flags[Int(key & 0xFFFF_FFFF)] |= Self.composesAsSecond }
        for cp in Array(0x1161..<0x1176) + Array(0x11A8..<0x11C3) { flags[cp] |= Self.composesAsSecond } // Hangul V, T
        cccBMP = combining
        flagsBMP = flags
        classes = ccc.mapValues(UInt8.init)
        decomposition = decomposed
        composition = composed
        folds = fold
        lowercase = lower
    }

    public static func bundled() throws -> UnicodeTables { try cached.get() }
    private static let cached: Result<UnicodeTables, Error> = Result {
        let data = try resourceData("unicode-15.1.0.json")
        let sidecar = try resourceData("unicode-15.1.0.json.sha256")
        guard let hash = String(data: sidecar, encoding: .utf8), hash.count == 65, hash.last == "\n" else {
            throw LoadError.corruptData
        }
        return try UnicodeTables(data: data, expectedSHA256: String(hash.dropLast()))
    }
    static func resourceData(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Language") else {
            throw LoadError.missingResource(name)
        }
        do { return try Data(contentsOf: url) }
        catch { throw LoadError.missingResource(name) }
    }

    public func generalCategory(_ scalar: UInt32) -> String {
        precondition(Self.isScalar(scalar))
        var low = 0, high = categories.count
        while low < high {
            let middle = low + (high - low) / 2
            let row = categories[middle]
            if scalar < row.start { high = middle }
            else if scalar > row.end { low = middle + 1 }
            else { return row.name }
        }
        return "Cn"
    }
    static let otherClass: UInt8 = 0, letterClass: UInt8 = 1, markClass: UInt8 = 2
    private static func wordClass(category: String) -> UInt8 {
        switch category {
        case "Lu", "Ll", "Lt", "Lm", "Lo": return letterClass
        case "Mn", "Mc", "Me": return markClass
        default: return otherClass
        }
    }
    /// The language detector's word classes of `generalCategory` (letter, mark or
    /// other) without a string comparison for BMP scalars.
    func wordClass(_ scalar: UInt32) -> UInt8 {
        scalar <= 0xFFFF ? wordClassBMP[Int(scalar)] : Self.wordClass(category: generalCategory(scalar))
    }
    public func combiningClass(_ scalar: UInt32) -> UInt8 {
        precondition(Self.isScalar(scalar))
        return ccc(scalar)
    }
    @inline(__always) private func ccc(_ scalar: UInt32) -> UInt8 {
        scalar <= 0xFFFF ? cccBMP[Int(scalar)] : classes[scalar, default: 0]
    }
    @inline(__always) private func lacks(_ flag: UInt8, _ scalar: UInt32) -> Bool {
        scalar <= 0xFFFF && flagsBMP[Int(scalar)] & flag == 0
    }
    public func simpleLowercase(_ scalar: UInt32) -> UInt32 {
        precondition(Self.isScalar(scalar))
        return lowercase[scalar, default: scalar]
    }
    public func fullCaseFold(_ scalars: [UInt32]) -> [UInt32] {
        precondition(scalars.allSatisfy(Self.isScalar))
        var out: [UInt32] = []
        out.reserveCapacity(scalars.count)
        for scalar in scalars {
            if !lacks(Self.hasFold, scalar), let folded = folds[scalar] { out.append(contentsOf: folded) }
            else { out.append(scalar) }
        }
        return out
    }
    public func nfd(_ scalars: [UInt32]) -> [UInt32] {
        precondition(scalars.allSatisfy(Self.isScalar))
        var expanded: [UInt32] = []
        expanded.reserveCapacity(scalars.count)
        var stack: [UInt32] = []
        for scalar in scalars {
            if lacks(Self.hasDecomposition, scalar), !(0xAC00..<0xD7A4).contains(scalar) {
                expanded.append(scalar)
                continue
            }
            stack.append(scalar)
            while let cp = stack.popLast() {
                if (0xAC00..<0xD7A4).contains(cp) {
                    let s = cp - 0xAC00
                    expanded.append(0x1100 + s / 588)
                    expanded.append(0x1161 + (s % 588) / 28)
                    if s % 28 != 0 { expanded.append(0x11A7 + s % 28) }
                } else if !lacks(Self.hasDecomposition, cp), let parts = decomposition[cp] {
                    stack.append(contentsOf: parts.reversed())
                } else { expanded.append(cp) }
            }
        }
        var start = 0
        while start < expanded.count {
            if ccc(expanded[start]) == 0 { start += 1; continue }
            var end = start + 1
            while end < expanded.count && ccc(expanded[end]) != 0 { end += 1 }
            if end - start > 1 {
                var buckets = Array(repeating: [UInt32](), count: 256)
                for cp in expanded[start..<end] { buckets[Int(ccc(cp))].append(cp) }
                var index = start
                for bucket in buckets { for cp in bucket { expanded[index] = cp; index += 1 } }
            }
            start = end
        }
        return expanded
    }
    public func nfc(_ scalars: [UInt32]) -> [UInt32] {
        let ordered = nfd(scalars)
        var out: [UInt32] = []
        out.reserveCapacity(ordered.count)
        var starter: Int?
        var last: UInt8 = 0
        for cp in ordered {
            let current = ccc(cp)
            if let index = starter, (last == 0 || last < current), let replacement = compose(out[index], cp) {
                out[index] = replacement
            } else {
                if current == 0 { starter = out.count }
                out.append(cp)
                last = current
            }
        }
        return out
    }
    private func compose(_ a: UInt32, _ b: UInt32) -> UInt32? {
        if lacks(Self.composesAsSecond, b) { return nil }
        if (0x1100..<0x1113).contains(a), (0x1161..<0x1176).contains(b) {
            return 0xAC00 + (a - 0x1100) * 588 + (b - 0x1161) * 28
        }
        if (0xAC00..<0xD7A4).contains(a), (a - 0xAC00) % 28 == 0, (0x11A8..<0x11C3).contains(b) {
            return a + b - 0x11A7
        }
        return composition[Self.pairKey(a, b)]
    }
}
