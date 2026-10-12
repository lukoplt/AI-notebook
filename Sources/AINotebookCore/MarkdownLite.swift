import Foundation

// MarkdownLite v1 — the small, deterministic Markdown subset used to render
// assistant answers. Normative rules: tools/contracts/gen_markdown_fixtures.py
// (reference parser) and docs/design/tokens-v1.md. This is a literal port; the
// shared fixture Tests/fixtures/contracts/markdown-lite-v1.json guards parity
// with the C# implementation (windows/src/AINotebook.Core/Text/MarkdownLite.cs).
//
// The parser works on Unicode scalars. Every marker is ASCII and only space/tab
// count as whitespace, so no host Unicode classification is involved.

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case strong([MarkdownInline])
    case emphasis([MarkdownInline])
    case code(String)
    /// `href` is always http(s) or mailto (checked by the parser).
    case link(href: String, children: [MarkdownInline])
    /// `[N]` citation marker (1–999).
    case cite(Int)
}

public struct MarkdownList: Equatable, Sendable {
    public var ordered: Bool
    /// Number of the first item; `nil` for bullet lists.
    public var start: Int?
    public var items: [MarkdownListItem]

    public init(ordered: Bool, start: Int?, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

public struct MarkdownListItem: Equatable, Sendable {
    public var inlines: [MarkdownInline]
    /// Second level (at most two levels); its items never have a sublist.
    public var sublist: MarkdownList?

    public init(inlines: [MarkdownInline], sublist: MarkdownList? = nil) {
        self.inlines = inlines
        self.sublist = sublist
    }
}

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, inlines: [MarkdownInline])
    case list(MarkdownList)
    case quote([MarkdownInline])
    case code(String)
    case rule
}

public enum MarkdownLite {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        BlockParser(Array(text.unicodeScalars)).run()
    }

    /// Inline-only parse (exposed for renderers that format single lines).
    public static func parseInlines(_ text: String) -> [MarkdownInline] {
        InlineParser.parse(Array(text.unicodeScalars)[...], links: true)
    }
}

// MARK: - Scalar helpers

fileprivate typealias Scalars = ArraySlice<Unicode.Scalar>

private enum Chars {
    static let punctuation: Set<Unicode.Scalar> = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~".unicodeScalars)

    static func isWhitespace(_ c: Unicode.Scalar) -> Bool { c == " " || c == "\t" }
    static func isPunctuation(_ c: Unicode.Scalar) -> Bool { punctuation.contains(c) }
    static func isWord(_ c: Unicode.Scalar) -> Bool { !isWhitespace(c) && !isPunctuation(c) }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 48 && c.value <= 57 }

    static func string(_ s: Scalars) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: s)
        return String(view)
    }

    static func trim(_ s: Scalars) -> Scalars {
        var lo = s.startIndex
        var hi = s.endIndex
        while lo < hi, isWhitespace(s[lo]) { lo += 1 }
        while hi > lo, isWhitespace(s[hi - 1]) { hi -= 1 }
        return s[lo..<hi]
    }

    /// Length of the run of `c` starting at `i`.
    static func run(_ s: Scalars, _ i: Int, _ c: Unicode.Scalar) -> Int {
        var j = i
        while j < s.endIndex, s[j] == c { j += 1 }
        return j - i
    }

    static func digitRun(_ s: Scalars, _ i: Int) -> Int {
        var j = i
        while j < s.endIndex, isDigit(s[j]) { j += 1 }
        return j - i
    }

    static func number(_ s: Scalars) -> Int {
        s.reduce(0) { $0 * 10 + Int($1.value - 48) }
    }

    static func asciiLower(_ c: Unicode.Scalar) -> Unicode.Scalar {
        (c.value >= 65 && c.value <= 90) ? Unicode.Scalar(c.value + 32)! : c
    }
}

// MARK: - Inlines

private enum InlineParser {
    static let schemes: [[Unicode.Scalar]] = ["http://", "https://", "mailto:"].map { Array($0.unicodeScalars) }

    /// `s` is parsed as an independent string (indices are re-based to 0).
    static func parse(_ input: Scalars, links: Bool) -> [MarkdownInline] {
        let s = Scalars(Array(input))
        let n = s.count
        var out: [MarkdownInline] = []
        var buf = String.UnicodeScalarView()

        func flush() {
            if !buf.isEmpty {
                out.append(.text(String(buf)))
                buf = String.UnicodeScalarView()
            }
        }

        var i = 0
        while i < n {
            let ch = s[i]
            if ch == "\\", i + 1 < n, Chars.isPunctuation(s[i + 1]) {
                buf.append(s[i + 1])
                i += 2
            } else if ch == "`" {
                let r = Chars.run(s, i, "`")
                let j = codeClose(s, i + r, r)
                if j < 0 {
                    buf.append(contentsOf: s[i..<(i + r)])
                    i += r
                    continue
                }
                var v = s[(i + r)..<j]
                if v.count >= 2, v.first == " ", v.last == " ", v.contains(where: { $0 != " " }) {
                    v = v.dropFirst().dropLast()
                }
                flush()
                out.append(.code(Chars.string(v)))
                i = j + r
            } else if ch == "[" {
                if let c = cite(s, i) {
                    flush()
                    out.append(.cite(c.number))
                    i = c.end
                } else if links, let l = link(s, i) {
                    flush()
                    out.append(.link(href: Chars.string(l.href), children: parse(l.text, links: false)))
                    i = l.end
                } else {
                    buf.append("[")
                    i += 1
                }
            } else if ch == "*" || ch == "_" {
                let r = Chars.run(s, i, ch)
                let match: (content: Scalars, end: Int)?
                let strong: Bool
                if ch == "*" {
                    strong = r >= 2
                    match = star(s, i, strong: strong)
                } else {
                    strong = false
                    match = r == 1 ? underscore(s, i) : nil
                }
                guard let m = match else {
                    buf.append(contentsOf: s[i..<(i + r)])
                    i += r
                    continue
                }
                flush()
                let children = parse(m.content, links: links)
                out.append(strong ? .strong(children) : .emphasis(children))
                i = m.end
            } else {
                buf.append(ch)
                i += 1
            }
        }
        flush()
        return out
    }

    static func codeClose(_ s: Scalars, _ start: Int, _ run: Int) -> Int {
        var p = start
        while p < s.count {
            if s[p] == "`" {
                let r = Chars.run(s, p, "`")
                if r == run { return p }
                p += r
            } else {
                p += 1
            }
        }
        return -1
    }

    /// Index after an escape or complete code span at `p`, else -1.
    static func skip(_ s: Scalars, _ p: Int) -> Int {
        if s[p] == "\\", p + 1 < s.count, Chars.isPunctuation(s[p + 1]) { return p + 2 }
        if s[p] == "`" {
            let r = Chars.run(s, p, "`")
            let j = codeClose(s, p + r, r)
            return j >= 0 ? j + r : p + r
        }
        return -1
    }

    static func cite(_ s: Scalars, _ i: Int) -> (number: Int, end: Int)? {
        let d = Chars.digitRun(s, i + 1)
        let end = i + 1 + d
        guard (1...3).contains(d), s[i + 1] != "0", end < s.count, s[end] == "]" else { return nil }
        if end + 1 < s.count, s[end + 1] == "(" { return nil }
        return (Chars.number(s[(i + 1)..<end]), end + 1)
    }

    static func link(_ s: Scalars, _ i: Int) -> (text: Scalars, href: Scalars, end: Int)? {
        guard let close = s[(i + 1)...].firstIndex(of: "]"),
              close + 1 < s.count, s[close + 1] == "(" else { return nil }
        let u = close + 2
        var p = u
        var depth = 0
        while p < s.count {
            let c = s[p]
            if Chars.isWhitespace(c) { return nil }
            if c == "(" {
                depth += 1
            } else if c == ")" {
                if depth == 0 { break }
                depth -= 1
            }
            p += 1
        }
        guard p < s.count else { return nil }
        let href = s[u..<p]
        let allowed = schemes.contains { scheme in
            href.count > scheme.count && zip(href, scheme).allSatisfy { Chars.asciiLower($0) == $1 }
        }
        guard allowed else { return nil }
        return (s[(i + 1)..<close], href, p + 1)
    }

    static func star(_ s: Scalars, _ i: Int, strong: Bool) -> (content: Scalars, end: Int)? {
        let s0 = i + (strong ? 2 : 1)
        guard s0 < s.count, !Chars.isWhitespace(s[s0]) else { return nil }
        var p = s0 + 1
        while p < s.count {
            let k = skip(s, p)
            if k >= 0 { p = k; continue }
            if s[p] == "*" {
                let r = Chars.run(s, p, "*")
                let q = p + r
                let fits = strong ? r >= 2 : (r == 1 || r >= 3)
                if fits, !Chars.isWhitespace(s[p - 1]) {
                    return (s[s0..<(q - (strong ? 2 : 1))], q)
                }
                p = q
                continue
            }
            p += 1
        }
        return nil
    }

    static func underscore(_ s: Scalars, _ i: Int) -> (content: Scalars, end: Int)? {
        let s0 = i + 1
        if i > 0, Chars.isWord(s[i - 1]) { return nil }
        guard s0 < s.count, !Chars.isWhitespace(s[s0]) else { return nil }
        var p = s0 + 1
        while p < s.count {
            let k = skip(s, p)
            if k >= 0 { p = k; continue }
            if s[p] == "_" {
                let r = Chars.run(s, p, "_")
                let q = p + r
                if r == 1, !Chars.isWhitespace(s[p - 1]), q == s.count || !Chars.isWord(s[q]) {
                    return (s[s0..<p], q)
                }
                p = q
                continue
            }
            p += 1
        }
        return nil
    }
}

// MARK: - Blocks

private final class BlockParser {
    private final class Item {
        var lines: [Scalars]
        var sub: PendingList?
        init(_ first: Scalars) { lines = [first] }
    }

    private final class PendingList {
        let ordered: Bool
        let start: Int
        var items: [Item] = []
        init(ordered: Bool, start: Int) { self.ordered = ordered; self.start = start }
    }

    private let text: [Unicode.Scalar]
    private var blocks: [MarkdownBlock] = []
    private var para: [Scalars]?
    private var quote: [Scalars]?
    private var list: PendingList?
    private var last: Item?
    private var blank = false

    init(_ text: [Unicode.Scalar]) { self.text = text }

    func run() -> [MarkdownBlock] {
        var fenceRun = 0
        var fence: [Scalars]?
        for raw in lines() {
            if fence != nil {
                let c = Chars.trim(raw)
                if c.count >= fenceRun, Chars.run(c, c.startIndex, "`") == c.count {
                    blocks.append(.code(joinLines(fence!)))
                    fence = nil
                } else {
                    fence!.append(raw)
                }
                continue
            }
            let c = Scalars(Array(Chars.trim(raw)))
            if c.isEmpty {
                closeParagraph()
                closeQuote()
                if list != nil { blank = true }
                continue
            }
            let ticks = Chars.run(c, 0, "`")
            if ticks >= 3, !c[ticks...].contains("`") {
                closeAll()
                fenceRun = ticks
                fence = []
                continue
            }
            if isRule(c) {
                closeAll()
                blocks.append(.rule)
                continue
            }
            let h = heading(c)
            if h > 0 {
                closeAll()
                blocks.append(.heading(level: h, inlines: InlineParser.parse(Chars.trim(c[h...]), links: true)))
                continue
            }
            if c[0] == ">" {
                closeParagraph()
                closeList()
                var body = c[1...]
                if let f = body.first, Chars.isWhitespace(f) { body = body.dropFirst() }
                if quote == nil { quote = [] }
                if !body.isEmpty { quote!.append(body) }
                continue
            }
            if c[0] == "|" {
                closeAll()
                if !isTableSeparator(c) { blocks.append(.paragraph(InlineParser.parse(c, links: true))) }
                continue
            }
            if let m = listMarker(c) {
                closeParagraph()
                closeQuote()
                let item = Item(m.rest)
                if indent(raw) >= 2, let open = list {
                    let parent = open.items[open.items.count - 1]
                    if parent.sub == nil { parent.sub = PendingList(ordered: m.ordered, start: m.number) }
                    parent.sub!.items.append(item)
                } else {
                    if let open = list, open.ordered != m.ordered { closeList() }
                    if list == nil { list = PendingList(ordered: m.ordered, start: m.number) }
                    list!.items.append(item)
                }
                last = item
                blank = false
                continue
            }
            if list != nil, !blank {
                last!.lines.append(c)
                continue
            }
            closeQuote()
            closeList()
            if para == nil { para = [] }
            para!.append(c)
        }
        if let fence { blocks.append(.code(joinLines(fence))) }
        closeAll()
        return blocks
    }

    // MARK: lines

    /// CRLF / CR → LF, split on LF keeping empty pieces.
    private func lines() -> [Scalars] {
        var out: [Scalars] = []
        var current: [Unicode.Scalar] = []
        var i = 0
        while i < text.count {
            let c = text[i]
            if c == "\r" || c == "\n" {
                out.append(Scalars(current))
                current = []
                if c == "\r", i + 1 < text.count, text[i + 1] == "\n" { i += 1 }
            } else {
                current.append(c)
            }
            i += 1
        }
        out.append(Scalars(current))
        return out
    }

    private func joinLines(_ lines: [Scalars]) -> String {
        lines.map(Chars.string).joined(separator: "\n")
    }

    private func joinSpaced(_ lines: [Scalars]) -> Scalars {
        var out: [Unicode.Scalar] = []
        for (k, line) in lines.enumerated() {
            if k > 0 { out.append(" ") }
            out.append(contentsOf: line)
        }
        return Scalars(out)
    }

    private func indent(_ raw: Scalars) -> Int {
        var w = 0
        for c in raw {
            if c == " " { w += 1 } else if c == "\t" { w += 4 } else { break }
        }
        return w
    }

    // MARK: line classification (c is trimmed, non-empty, 0-based)

    private func listMarker(_ c: Scalars) -> (ordered: Bool, number: Int, rest: Scalars)? {
        if c[0] == "-" || c[0] == "*" || c[0] == "+", c.count > 1, Chars.isWhitespace(c[1]) {
            return (false, 0, Chars.trim(c[2...]))
        }
        let d = Chars.digitRun(c, 0)
        if (1...9).contains(d), d + 1 < c.count, c[d] == ".", Chars.isWhitespace(c[d + 1]) {
            return (true, Chars.number(c[0..<d]), Chars.trim(c[(d + 2)...]))
        }
        return nil
    }

    private func isRule(_ c: Scalars) -> Bool {
        c.count >= 3 && (c[0] == "-" || c[0] == "*" || c[0] == "_") && c.allSatisfy { $0 == c[0] }
    }

    private func heading(_ c: Scalars) -> Int {
        let h = Chars.run(c, 0, "#")
        return (1...3).contains(h) && h < c.count && Chars.isWhitespace(c[h]) ? h : 0
    }

    private func isTableSeparator(_ c: Scalars) -> Bool {
        c.contains("-") && c.allSatisfy { $0 == "|" || $0 == "-" || $0 == ":" || Chars.isWhitespace($0) }
    }

    // MARK: closing

    private func closeParagraph() {
        if let para {
            blocks.append(.paragraph(InlineParser.parse(joinSpaced(para), links: true)))
            self.para = nil
        }
    }

    private func closeQuote() {
        if let quote {
            blocks.append(.quote(InlineParser.parse(joinSpaced(quote), links: true)))
            self.quote = nil
        }
    }

    private func closeList() {
        if let list {
            blocks.append(.list(build(list)))
            self.list = nil
            last = nil
            blank = false
        }
    }

    private func closeAll() {
        closeParagraph()
        closeQuote()
        closeList()
    }

    private func build(_ list: PendingList) -> MarkdownList {
        MarkdownList(
            ordered: list.ordered,
            start: list.ordered ? list.start : nil,
            items: list.items.map { item in
                MarkdownListItem(inlines: InlineParser.parse(joinSpaced(item.lines), links: true),
                                 sublist: item.sub.map(build))
            })
    }
}
