import AINotebookCore
import SwiftUI

/// Renders MarkdownLite blocks (assistant answers) with tokens. Citation
/// markers `[N]` become small highlighted chips inside the text; clicking one
/// calls `onCite(N)`. Links open only for the http/https/mailto targets the
/// parser accepted.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    var style: DesignTokens.TypeStyle = .message
    var onCite: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(12)) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let marker = MarkdownInlineRenderer.citeMarker(url) {
                onCite(marker)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let inlines):
            text(inlines).tokenFont(style).tokenForeground(.text1)
        case .heading(let level, let inlines):
            text(inlines)
                .tokenFont(level == 1 ? .title : .headline)
                .tokenForeground(.text1)
                .padding(.top, DesignTokens.spacing(4))
        case .list(let list):
            listView(list, nested: false)
        case .quote(let inlines):
            HStack(alignment: .top, spacing: DesignTokens.spacing(12)) {
                Rectangle()
                    .fill(DesignTokens.color(.border))
                    .frame(width: DesignTokens.size(.focusRing))
                text(inlines).tokenFont(style).tokenForeground(.text2)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .tokenFont(.mono)
                    .tokenForeground(.text1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(DesignTokens.spacing(12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(radius: .md, fill: .surface2)
        case .rule:
            Hairline().padding(.vertical, DesignTokens.spacing(4))
        }
    }

    private func listView(_ list: MarkdownList, nested: Bool) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: DesignTokens.spacing(4)) {
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.spacing(8)) {
                        Text(list.ordered ? "\((list.start ?? 1) + index)." : (nested ? "◦" : "•"))
                            .tokenFont(style)
                            .tokenForeground(.text2)
                            .monospacedDigit()
                        text(item.inlines).tokenFont(style).tokenForeground(.text1)
                    }
                    if let sub = item.sublist {
                        AnyView(listView(sub, nested: true))
                            .padding(.leading, DesignTokens.spacing(24))
                    }
                }
            }
        }
    }

    private func text(_ inlines: [MarkdownInline]) -> Text {
        Text(MarkdownInlineRenderer.attributed(inlines))
    }
}

/// MarkdownLite inlines → AttributedString with token styling.
enum MarkdownInlineRenderer {
    static let citeScheme = "ainb-cite"

    static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        var out = AttributedString()
        for inline in inlines { out.append(render(inline, intent: [])) }
        return out
    }

    private static func render(_ inline: MarkdownInline, intent: InlinePresentationIntent) -> AttributedString {
        switch inline {
        case .text(let value):
            var s = AttributedString(value)
            if !intent.isEmpty { s.inlinePresentationIntent = intent }
            return s
        case .strong(let children):
            return children.reduce(into: AttributedString()) {
                $0.append(render($1, intent: intent.union(.stronglyEmphasized)))
            }
        case .emphasis(let children):
            return children.reduce(into: AttributedString()) {
                $0.append(render($1, intent: intent.union(.emphasized)))
            }
        case .code(let value):
            var s = AttributedString(value)
            s.font = DesignTokens.font(.mono)
            s.backgroundColor = DesignTokens.color(.surface2)
            return s
        case .link(let href, let children):
            var s = children.reduce(into: AttributedString()) { $0.append(render($1, intent: intent)) }
            if let url = URL(string: href) {
                s.link = url
                s.foregroundColor = DesignTokens.color(.focus)
            }
            return s
        case .cite(let n):
            // Thin spaces pad the highlighted marker so it reads as a chip.
            var s = AttributedString("\u{2009}\(n)\u{2009}")
            s.font = DesignTokens.font(.caption).monospacedDigit()
            s.foregroundColor = DesignTokens.color(.text2)
            s.backgroundColor = DesignTokens.color(.surface2)
            s.baselineOffset = 1
            s.link = URL(string: "\(citeScheme):\(n)")
            var out = AttributedString("\u{200A}")
            out.append(s)
            return out
        }
    }

    static func citeMarker(_ url: URL) -> Int? {
        guard url.scheme == citeScheme else { return nil }
        return Int(url.absoluteString.dropFirst(citeScheme.count + 1))
    }

    /// Markers that appear inline in the answer text.
    static func citeMarkers(in blocks: [MarkdownBlock]) -> Set<Int> {
        var found = Set<Int>()
        func visit(_ inlines: [MarkdownInline]) {
            for inline in inlines {
                switch inline {
                case .cite(let n): found.insert(n)
                case .strong(let c), .emphasis(let c), .link(_, let c): visit(c)
                case .text, .code: break
                }
            }
        }
        func visit(_ list: MarkdownList) {
            for item in list.items {
                visit(item.inlines)
                if let sub = item.sublist { visit(sub) }
            }
        }
        for block in blocks {
            switch block {
            case .paragraph(let i), .heading(_, let i), .quote(let i): visit(i)
            case .list(let l): visit(l)
            case .code, .rule: break
            }
        }
        return found
    }
}

private let previewMarkdown = """
## Shrnutí

Podle zdrojů je **výsledek** stabilní [1] a *žluťoučký kůň* souhlasí [2]. Viz [web](https://example.com).

- první bod s `kódem`
- druhý bod
  - vnořený

> Citace z dokumentu.

```
let x = 1
```
"""

#Preview("Markdown light") {
    ScrollView {
        MarkdownView(blocks: MarkdownLite.parse(previewMarkdown)).padding()
    }
    .frame(width: 560, height: 420)
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.light)
}

#Preview("Markdown dark") {
    ScrollView {
        MarkdownView(blocks: MarkdownLite.parse(previewMarkdown)).padding()
    }
    .frame(width: 560, height: 420)
    .background(DesignTokens.color(.bg))
    .preferredColorScheme(.dark)
}
