using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Text;
using Xunit;

namespace AINotebook.Core.Tests.Text;

/// <summary>
/// Shared contract markdown-lite-v1.json (reference parser:
/// tools/contracts/gen_markdown_fixtures.py); the Swift suite runs the same cases.
/// The model is serialised back into the fixture's JSON shape and compared.
/// </summary>
public class MarkdownLiteTests
{
    private static JsonElement[] Cases()
    {
        var fixture = SharedFixtures.Json("contracts/markdown-lite-v1.json");
        Assert.Equal("markdown-lite", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture.GetProperty("cases").EnumerateArray().ToArray();
    }

    [Fact]
    public void EveryFixtureCase()
    {
        var cases = Cases();
        Assert.True(cases.Length >= 45);
        foreach (var c in cases)
        {
            var name = c.GetProperty("name").GetString()!;
            var expected = JsonNode.Parse(c.GetProperty("expected").GetRawText());
            var actual = ToJson(MarkdownLite.Parse(c.GetProperty("input").GetString()!));
            Assert.True(JsonNode.DeepEquals(expected, actual),
                $"{name}\nexpected: {expected!.ToJsonString()}\nactual:   {actual.ToJsonString()}");
        }
    }

    [Fact]
    public void EveryPrefixOfEveryCaseParses()
    {
        foreach (var c in Cases())
        {
            var input = c.GetProperty("input").GetString()!;
            // Cut on scalar boundaries, like the generator (never inside a surrogate pair).
            for (var cut = 0; cut <= input.Length; cut++)
            {
                if (cut > 0 && cut < input.Length && char.IsLowSurrogate(input[cut])) continue;
                MarkdownLite.Parse(input[..cut]);
            }
        }
    }

    [Fact]
    public void CrlfMatchesLf() =>
        Assert.True(JsonNode.DeepEquals(
            ToJson(MarkdownLite.Parse("- a\r\n  - b\r\n\r\ntext")),
            ToJson(MarkdownLite.Parse("- a\n  - b\n\ntext"))));

    // ---- model → fixture JSON shape

    private static JsonArray ToJson(IReadOnlyList<MarkdownBlock> blocks) =>
        new(blocks.Select(Block).ToArray<JsonNode?>());

    private static JsonNode Block(MarkdownBlock block) => block switch
    {
        MarkdownParagraph p => new JsonObject { ["type"] = "paragraph", ["inlines"] = Inlines(p.Inlines) },
        MarkdownHeading h => new JsonObject { ["type"] = "heading", ["level"] = h.Level, ["inlines"] = Inlines(h.Inlines) },
        MarkdownQuote q => new JsonObject { ["type"] = "quote", ["inlines"] = Inlines(q.Inlines) },
        MarkdownCodeBlock c => new JsonObject { ["type"] = "code", ["text"] = c.Text },
        MarkdownRule => new JsonObject { ["type"] = "rule" },
        MarkdownListBlock l => List(l.List, new JsonObject { ["type"] = "list" }),
        _ => throw new InvalidOperationException(block.ToString()),
    };

    private static JsonObject List(MarkdownList list, JsonObject into)
    {
        into["ordered"] = list.Ordered;
        if (list.Start is int start) into["start"] = start;
        into["items"] = new JsonArray(list.Items.Select(item =>
        {
            var o = new JsonObject { ["inlines"] = Inlines(item.Inlines) };
            if (item.Sublist is not null) o["sublist"] = List(item.Sublist, new JsonObject());
            return (JsonNode?)o;
        }).ToArray());
        return into;
    }

    private static JsonArray Inlines(IReadOnlyList<MarkdownInline> inlines) =>
        new(inlines.Select(Inline).ToArray<JsonNode?>());

    private static JsonNode Inline(MarkdownInline inline) => inline switch
    {
        MarkdownText t => new JsonObject { ["t"] = "text", ["v"] = t.Value },
        MarkdownCode c => new JsonObject { ["t"] = "code", ["v"] = c.Value },
        MarkdownStrong s => new JsonObject { ["t"] = "strong", ["c"] = Inlines(s.Children) },
        MarkdownEmphasis e => new JsonObject { ["t"] = "em", ["c"] = Inlines(e.Children) },
        MarkdownLink l => new JsonObject { ["t"] = "link", ["href"] = l.Href, ["c"] = Inlines(l.Children) },
        MarkdownCite n => new JsonObject { ["t"] = "cite", ["n"] = n.Number },
        _ => throw new InvalidOperationException(inline.ToString()),
    };
}
