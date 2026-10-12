using System.Text;

namespace AINotebook.Core.Text;

// MarkdownLite v1 — the small, deterministic Markdown subset used to render
// assistant answers. Normative rules: tools/contracts/gen_markdown_fixtures.py
// (reference parser) and docs/design/tokens-v1.md. Literal port of the reference
// and of Sources/AINotebookCore/MarkdownLite.swift; the shared fixture
// Tests/fixtures/contracts/markdown-lite-v1.json guards parity.
//
// Works on UTF-16 chars: every marker is ASCII and only space/tab count as
// whitespace, so slicing only happens at ASCII positions (never inside a
// surrogate pair) and no host Unicode classification is involved.

public abstract record MarkdownInline;
public sealed record MarkdownText(string Value) : MarkdownInline;
public sealed record MarkdownStrong(IReadOnlyList<MarkdownInline> Children) : MarkdownInline;
public sealed record MarkdownEmphasis(IReadOnlyList<MarkdownInline> Children) : MarkdownInline;
public sealed record MarkdownCode(string Value) : MarkdownInline;
/// <summary>Href is always http(s) or mailto (checked by the parser).</summary>
public sealed record MarkdownLink(string Href, IReadOnlyList<MarkdownInline> Children) : MarkdownInline;
/// <summary>`[N]` citation marker (1–999).</summary>
public sealed record MarkdownCite(int Number) : MarkdownInline;

/// <summary>Start is the number of the first item; null for bullet lists.</summary>
public sealed record MarkdownList(bool Ordered, int? Start, IReadOnlyList<MarkdownListItem> Items);
/// <summary>Sublist = second level (at most two levels).</summary>
public sealed record MarkdownListItem(IReadOnlyList<MarkdownInline> Inlines, MarkdownList? Sublist = null);

public abstract record MarkdownBlock;
public sealed record MarkdownParagraph(IReadOnlyList<MarkdownInline> Inlines) : MarkdownBlock;
public sealed record MarkdownHeading(int Level, IReadOnlyList<MarkdownInline> Inlines) : MarkdownBlock;
public sealed record MarkdownListBlock(MarkdownList List) : MarkdownBlock;
public sealed record MarkdownQuote(IReadOnlyList<MarkdownInline> Inlines) : MarkdownBlock;
public sealed record MarkdownCodeBlock(string Text) : MarkdownBlock;
public sealed record MarkdownRule : MarkdownBlock;

public static class MarkdownLite
{
    public static IReadOnlyList<MarkdownBlock> Parse(string text) => new BlockParser(text).Run();

    /// <summary>Inline-only parse (for renderers that format single lines).</summary>
    public static IReadOnlyList<MarkdownInline> ParseInlines(string text) => Inlines.Parse(text, links: true);

    // ---------------------------------------------------------------- helpers

    private const string Punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~";

    private static bool IsWs(char c) => c is ' ' or '\t';
    private static bool IsPunct(char c) => Punctuation.Contains(c);
    private static bool IsWord(char c) => !IsWs(c) && !IsPunct(c);
    private static bool IsDigit(char c) => c is >= '0' and <= '9';
    private static string Trim(string s) => s.Trim(' ', '\t');
    private static char AsciiLower(char c) => c is >= 'A' and <= 'Z' ? (char)(c + 32) : c;

    private static int Run(string s, int i, char c)
    {
        var j = i;
        while (j < s.Length && s[j] == c) j++;
        return j - i;
    }

    private static int DigitRun(string s, int i)
    {
        var j = i;
        while (j < s.Length && IsDigit(s[j])) j++;
        return j - i;
    }

    private static int Number(string digits)
    {
        var n = 0;
        foreach (var c in digits) n = n * 10 + (c - '0');
        return n;
    }

    // ---------------------------------------------------------------- inlines

    private static class Inlines
    {
        private static readonly string[] Schemes = ["http://", "https://", "mailto:"];

        public static IReadOnlyList<MarkdownInline> Parse(string s, bool links)
        {
            var output = new List<MarkdownInline>();
            var buf = new StringBuilder();

            void Flush()
            {
                if (buf.Length == 0) return;
                output.Add(new MarkdownText(buf.ToString()));
                buf.Clear();
            }

            var i = 0;
            var n = s.Length;
            while (i < n)
            {
                var ch = s[i];
                if (ch == '\\' && i + 1 < n && IsPunct(s[i + 1]))
                {
                    buf.Append(s[i + 1]);
                    i += 2;
                }
                else if (ch == '`')
                {
                    var r = Run(s, i, '`');
                    var j = CodeClose(s, i + r, r);
                    if (j < 0)
                    {
                        buf.Append(s, i, r);
                        i += r;
                        continue;
                    }
                    var v = s[(i + r)..j];
                    if (v.Length >= 2 && v[0] == ' ' && v[^1] == ' ' && v.Any(c => c != ' '))
                        v = v[1..^1];
                    Flush();
                    output.Add(new MarkdownCode(v));
                    i = j + r;
                }
                else if (ch == '[')
                {
                    if (Cite(s, i) is { } cite)
                    {
                        Flush();
                        output.Add(new MarkdownCite(cite.Number));
                        i = cite.End;
                    }
                    else if (links && Link(s, i) is { } link)
                    {
                        Flush();
                        output.Add(new MarkdownLink(link.Href, Parse(link.Text, links: false)));
                        i = link.End;
                    }
                    else
                    {
                        buf.Append('[');
                        i++;
                    }
                }
                else if (ch is '*' or '_')
                {
                    var r = Run(s, i, ch);
                    var strong = ch == '*' && r >= 2;
                    var match = ch == '*' ? Star(s, i, strong) : r == 1 ? Underscore(s, i) : null;
                    if (match is not { } m)
                    {
                        buf.Append(ch, r);
                        i += r;
                        continue;
                    }
                    Flush();
                    var children = Parse(m.Content, links);
                    output.Add(strong ? new MarkdownStrong(children) : new MarkdownEmphasis(children));
                    i = m.End;
                }
                else
                {
                    buf.Append(ch);
                    i++;
                }
            }
            Flush();
            return output;
        }

        private static int CodeClose(string s, int start, int run)
        {
            var p = start;
            while (p < s.Length)
            {
                if (s[p] == '`')
                {
                    var r = Run(s, p, '`');
                    if (r == run) return p;
                    p += r;
                }
                else p++;
            }
            return -1;
        }

        /// <summary>Index after an escape or complete code span at p, else -1.</summary>
        private static int Skip(string s, int p)
        {
            if (s[p] == '\\' && p + 1 < s.Length && IsPunct(s[p + 1])) return p + 2;
            if (s[p] == '`')
            {
                var r = Run(s, p, '`');
                var j = CodeClose(s, p + r, r);
                return j >= 0 ? j + r : p + r;
            }
            return -1;
        }

        private static (int Number, int End)? Cite(string s, int i)
        {
            var d = DigitRun(s, i + 1);
            var end = i + 1 + d;
            if (d is < 1 or > 3 || s[i + 1] == '0' || end >= s.Length || s[end] != ']') return null;
            if (end + 1 < s.Length && s[end + 1] == '(') return null;
            return (Number(s[(i + 1)..end]), end + 1);
        }

        private static (string Text, string Href, int End)? Link(string s, int i)
        {
            var close = s.IndexOf(']', i + 1);
            if (close < 0 || close + 1 >= s.Length || s[close + 1] != '(') return null;
            var u = close + 2;
            var p = u;
            var depth = 0;
            while (p < s.Length)
            {
                var c = s[p];
                if (IsWs(c)) return null;
                if (c == '(') depth++;
                else if (c == ')')
                {
                    if (depth == 0) break;
                    depth--;
                }
                p++;
            }
            if (p >= s.Length) return null;
            var href = s[u..p];
            // ASCII-only case folding (OrdinalIgnoreCase would also fold e.g. 'ı' to 'I').
            var allowed = Schemes.Any(x => href.Length > x.Length
                && x.Select((c, k) => AsciiLower(href[k]) == c).All(same => same));
            if (!allowed) return null;
            return (s[(i + 1)..close], href, p + 1);
        }

        private static (string Content, int End)? Star(string s, int i, bool strong)
        {
            var s0 = i + (strong ? 2 : 1);
            if (s0 >= s.Length || IsWs(s[s0])) return null;
            var p = s0 + 1;
            while (p < s.Length)
            {
                var k = Skip(s, p);
                if (k >= 0) { p = k; continue; }
                if (s[p] == '*')
                {
                    var r = Run(s, p, '*');
                    var q = p + r;
                    var fits = strong ? r >= 2 : r == 1 || r >= 3;
                    if (fits && !IsWs(s[p - 1])) return (s[s0..(q - (strong ? 2 : 1))], q);
                    p = q;
                    continue;
                }
                p++;
            }
            return null;
        }

        private static (string Content, int End)? Underscore(string s, int i)
        {
            var s0 = i + 1;
            if (i > 0 && IsWord(s[i - 1])) return null;
            if (s0 >= s.Length || IsWs(s[s0])) return null;
            var p = s0 + 1;
            while (p < s.Length)
            {
                var k = Skip(s, p);
                if (k >= 0) { p = k; continue; }
                if (s[p] == '_')
                {
                    var r = Run(s, p, '_');
                    var q = p + r;
                    if (r == 1 && !IsWs(s[p - 1]) && (q == s.Length || !IsWord(s[q]))) return (s[s0..p], q);
                    p = q;
                    continue;
                }
                p++;
            }
            return null;
        }
    }

    // ----------------------------------------------------------------- blocks

    private sealed class BlockParser(string text)
    {
        private sealed class Item(string first)
        {
            public List<string> Lines { get; } = [first];
            public PendingList? Sub { get; set; }
        }

        private sealed class PendingList(bool ordered, int start)
        {
            public bool Ordered { get; } = ordered;
            public int Start { get; } = start;
            public List<Item> Items { get; } = [];
        }

        private readonly List<MarkdownBlock> _blocks = [];
        private List<string>? _para;
        private List<string>? _quote;
        private PendingList? _list;
        private Item? _last;
        private bool _blank;

        public IReadOnlyList<MarkdownBlock> Run()
        {
            var fenceRun = 0;
            List<string>? fence = null;
            var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
            foreach (var raw in normalized.Split('\n'))
            {
                if (fence is not null)
                {
                    var t = Trim(raw);
                    if (t.Length >= fenceRun && MarkdownLite.Run(t, 0, '`') == t.Length)
                    {
                        _blocks.Add(new MarkdownCodeBlock(string.Join("\n", fence)));
                        fence = null;
                    }
                    else fence.Add(raw);
                    continue;
                }
                var c = Trim(raw);
                if (c.Length == 0)
                {
                    CloseParagraph();
                    CloseQuote();
                    if (_list is not null) _blank = true;
                    continue;
                }
                var ticks = MarkdownLite.Run(c, 0, '`');
                if (ticks >= 3 && c.IndexOf('`', ticks) < 0)
                {
                    CloseAll();
                    fenceRun = ticks;
                    fence = [];
                    continue;
                }
                if (IsRule(c))
                {
                    CloseAll();
                    _blocks.Add(new MarkdownRule());
                    continue;
                }
                var h = Heading(c);
                if (h > 0)
                {
                    CloseAll();
                    _blocks.Add(new MarkdownHeading(h, Inlines.Parse(Trim(c[h..]), links: true)));
                    continue;
                }
                if (c[0] == '>')
                {
                    CloseParagraph();
                    CloseList();
                    var body = c[1..];
                    if (body.Length > 0 && IsWs(body[0])) body = body[1..];
                    _quote ??= [];
                    if (body.Length > 0) _quote.Add(body);
                    continue;
                }
                if (c[0] == '|')
                {
                    CloseAll();
                    if (!IsTableSeparator(c)) _blocks.Add(new MarkdownParagraph(Inlines.Parse(c, links: true)));
                    continue;
                }
                if (ListMarker(c) is { } m)
                {
                    CloseParagraph();
                    CloseQuote();
                    var item = new Item(m.Body);
                    if (Indent(raw) >= 2 && _list is { } open)
                    {
                        var parent = open.Items[^1];
                        parent.Sub ??= new PendingList(m.Ordered, m.Number);
                        parent.Sub.Items.Add(item);
                    }
                    else
                    {
                        if (_list is { } current && current.Ordered != m.Ordered) CloseList();
                        _list ??= new PendingList(m.Ordered, m.Number);
                        _list.Items.Add(item);
                    }
                    _last = item;
                    _blank = false;
                    continue;
                }
                if (_list is not null && !_blank)
                {
                    _last!.Lines.Add(c);
                    continue;
                }
                CloseQuote();
                CloseList();
                _para ??= [];
                _para.Add(c);
            }
            if (fence is not null) _blocks.Add(new MarkdownCodeBlock(string.Join("\n", fence)));
            CloseAll();
            return _blocks;
        }

        private static int Indent(string raw)
        {
            var w = 0;
            foreach (var c in raw)
            {
                if (c == ' ') w += 1;
                else if (c == '\t') w += 4;
                else break;
            }
            return w;
        }

        // c is trimmed and non-empty.
        private static (bool Ordered, int Number, string Body)? ListMarker(string c)
        {
            if (c[0] is '-' or '*' or '+' && c.Length > 1 && IsWs(c[1])) return (false, 0, Trim(c[2..]));
            var d = DigitRun(c, 0);
            if (d is >= 1 and <= 9 && d + 1 < c.Length && c[d] == '.' && IsWs(c[d + 1]))
                return (true, Number(c[..d]), Trim(c[(d + 2)..]));
            return null;
        }

        private static bool IsRule(string c) => c.Length >= 3 && c[0] is '-' or '*' or '_' && c.All(x => x == c[0]);

        private static int Heading(string c)
        {
            var h = MarkdownLite.Run(c, 0, '#');
            return h is >= 1 and <= 3 && h < c.Length && IsWs(c[h]) ? h : 0;
        }

        private static bool IsTableSeparator(string c) =>
            c.Contains('-') && c.All(x => x is '|' or '-' or ':' || IsWs(x));

        private void CloseParagraph()
        {
            if (_para is null) return;
            _blocks.Add(new MarkdownParagraph(Inlines.Parse(string.Join(" ", _para), links: true)));
            _para = null;
        }

        private void CloseQuote()
        {
            if (_quote is null) return;
            _blocks.Add(new MarkdownQuote(Inlines.Parse(string.Join(" ", _quote), links: true)));
            _quote = null;
        }

        private void CloseList()
        {
            if (_list is null) return;
            _blocks.Add(new MarkdownListBlock(Build(_list)));
            _list = null;
            _last = null;
            _blank = false;
        }

        private void CloseAll()
        {
            CloseParagraph();
            CloseQuote();
            CloseList();
        }

        private static MarkdownList Build(PendingList list) =>
            new(list.Ordered, list.Ordered ? list.Start : null,
                list.Items.Select(item => new MarkdownListItem(
                    Inlines.Parse(string.Join(" ", item.Lines), links: true),
                    item.Sub is null ? null : Build(item.Sub))).ToArray());
    }
}
