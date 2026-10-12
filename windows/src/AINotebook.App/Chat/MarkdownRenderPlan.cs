using System.Globalization;
using AINotebook.Core.Text;

namespace AINotebook.App.Chat;

/// <summary>Kind of a rendered answer block (spec §5).</summary>
public enum RenderBlockKind { Paragraph, Heading, ListItem, Quote, Code, Rule }

/// <summary>
/// One styled run of an answer. Nested strong/emphasis/link markup is flattened into flags so the
/// WinUI renderer only maps flags onto Runs, Hyperlinks and citation chips.
/// </summary>
public sealed record RenderSpan(string Text, bool Strong = false, bool Emphasis = false, bool Code = false,
    string? Href = null, int? Cite = null);

/// <param name="Level">Heading level 1–3, or list depth 1–2.</param>
/// <param name="Marker">List marker ("•", "◦", "3.") for list items.</param>
public sealed record RenderBlock(RenderBlockKind Kind, int Level, string? Marker, IReadOnlyList<RenderSpan> Spans,
    string? CodeText = null);

/// <summary>
/// Pure projection of <see cref="MarkdownLite"/> blocks into a flat render plan (no WinUI types,
/// covered by App.Tests). <c>MarkdownRenderer</c> turns the plan into RichTextBlocks.
/// </summary>
public static class MarkdownRenderPlan
{
    public static IReadOnlyList<RenderBlock> Build(string markdown) => Build(MarkdownLite.Parse(markdown ?? ""));

    public static IReadOnlyList<RenderBlock> Build(IReadOnlyList<MarkdownBlock> blocks)
    {
        var plan = new List<RenderBlock>();
        foreach (var block in blocks)
        {
            switch (block)
            {
                case MarkdownParagraph p:
                    plan.Add(new RenderBlock(RenderBlockKind.Paragraph, 0, null, Spans(p.Inlines)));
                    break;
                case MarkdownHeading h:
                    plan.Add(new RenderBlock(RenderBlockKind.Heading, Math.Clamp(h.Level, 1, 3), null, Spans(h.Inlines)));
                    break;
                case MarkdownQuote q:
                    plan.Add(new RenderBlock(RenderBlockKind.Quote, 0, null, Spans(q.Inlines)));
                    break;
                case MarkdownCodeBlock c:
                    plan.Add(new RenderBlock(RenderBlockKind.Code, 0, null, Array.Empty<RenderSpan>(), c.Text));
                    break;
                case MarkdownRule:
                    plan.Add(new RenderBlock(RenderBlockKind.Rule, 0, null, Array.Empty<RenderSpan>()));
                    break;
                case MarkdownListBlock l:
                    AddList(plan, l.List, 1);
                    break;
            }
        }
        return plan;
    }

    private static void AddList(List<RenderBlock> plan, MarkdownList list, int depth)
    {
        int number = list.Start ?? 1;
        foreach (var item in list.Items)
        {
            string marker = list.Ordered
                ? number.ToString(CultureInfo.InvariantCulture) + "."
                : depth == 1 ? "•" : "◦";
            plan.Add(new RenderBlock(RenderBlockKind.ListItem, depth, marker, Spans(item.Inlines)));
            if (item.Sublist is { } sub) AddList(plan, sub, Math.Min(depth + 1, 2));
            number++;
        }
    }

    /// <summary>Flattens inline markup; adjacent spans with identical styling are merged.</summary>
    public static IReadOnlyList<RenderSpan> Spans(IReadOnlyList<MarkdownInline> inlines)
    {
        var spans = new List<RenderSpan>();
        Walk(inlines, strong: false, em: false, href: null, spans);
        return spans;
    }

    private static void Walk(IReadOnlyList<MarkdownInline> inlines, bool strong, bool em, string? href, List<RenderSpan> spans)
    {
        foreach (var inline in inlines)
        {
            switch (inline)
            {
                case MarkdownText t: Append(spans, new RenderSpan(t.Value, strong, em, false, href)); break;
                case MarkdownCode c: Append(spans, new RenderSpan(c.Value, strong, em, true, href)); break;
                case MarkdownStrong s: Walk(s.Children, true, em, href, spans); break;
                case MarkdownEmphasis e: Walk(e.Children, strong, true, href, spans); break;
                case MarkdownLink l: Walk(l.Children, strong, em, l.Href, spans); break;
                case MarkdownCite cite:
                    spans.Add(new RenderSpan("[" + cite.Number.ToString(CultureInfo.InvariantCulture) + "]", Cite: cite.Number));
                    break;
            }
        }
    }

    private static void Append(List<RenderSpan> spans, RenderSpan span)
    {
        if (span.Text.Length == 0) return;
        if (spans.Count > 0 && spans[^1] is { Cite: null } last && last with { Text = span.Text } == span)
        {
            spans[^1] = last with { Text = last.Text + span.Text };
            return;
        }
        spans.Add(span);
    }
}
