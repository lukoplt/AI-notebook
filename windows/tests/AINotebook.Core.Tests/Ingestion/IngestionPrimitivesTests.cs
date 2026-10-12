using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class IngestionPrimitivesTests
{
    [Fact]
    public void StrictEncodingFixtures()
    {
        var rows = Cases("ingestion-encoding-v1");
        var visited = new HashSet<string>();
        foreach (var row in rows)
        {
            Assert.True(visited.Add(row.GetProperty("name").GetString()!));
            Assert.Equal("decode", row.GetProperty("operation").GetString());
            var input = row.GetProperty("input");
            var expected = row.GetProperty("expected");
            var bytes = input.GetProperty("bytes").EnumerateArray().Select(x => x.GetByte()).ToArray();
            string fallback = input.GetProperty("fallback").GetString()!;
            if (expected.TryGetProperty("error", out var error))
                Error(error.GetString()!, () => TextDecoding.Decode(bytes, fallback, 100));
            else
            {
                var actual = TextDecoding.Decode(bytes, fallback, 100);
                Assert.Equal(expected.GetProperty("text").GetString(), actual.Text);
                Assert.Equal(expected.GetProperty("encoding").GetString(), actual.Encoding);
            }
        }
        Assert.Equal(rows.Length, visited.Count);
        Assert.Equal(12, visited.Count);
    }

    [Fact]
    public void GlobUsesPinnedSimpleLowercase()
    {
        var tables = UnicodeTables.LoadBundled();
        Assert.True(new FolderGlob("/İ/**/𐐀?.md/", false, tables).Matches("i/𐐨😀.md"));
        Error("unsupportedSyntax", () => new FolderGlob("///", true, tables));
        Assert.False(new FolderGlob("?.md", true, tables).Matches("e\u0301.md"));
        Assert.True(new FolderGlob("?.md", true, tables).Matches("😀.md"));
    }

    [Fact]
    public void AllGlobFixtures()
    {
        var tables = UnicodeTables.LoadBundled();
        var rows = Cases("glob-v1");
        var visited = new HashSet<string>();
        foreach (var row in rows)
        {
            Assert.True(visited.Add(row.GetProperty("name").GetString()!));
            string pattern = row.GetProperty("pattern").GetString()!;
            bool sensitive = row.GetProperty("caseSensitive").GetBoolean();
            if (row.TryGetProperty("expectedError", out var error))
                Error(error.GetString()!, () => new FolderGlob(pattern, sensitive, tables));
            else
                Assert.Equal(row.GetProperty("matches").GetBoolean(),
                    new FolderGlob(pattern, sensitive, tables).Matches(row.GetProperty("path").GetString()!));
        }
        Assert.Equal(rows.Length, visited.Count);
        Assert.Equal(53, visited.Count);
        // Long wildcard runs must not require recursive/exponential backtracking.
        Assert.False(new FolderGlob(new string('*', 500) + "z", true, tables).Matches(new string('a', 500)));
    }

    [Fact]
    public void CanonicalAndSpans()
    {
        var rows = Cases("ingestion-canonical-v1");
        var visited = new HashSet<string>();
        foreach (var row in rows)
        {
            Assert.True(visited.Add(row.GetProperty("name").GetString()!));
            Assert.Equal("canonical", row.GetProperty("operation").GetString());
            var input = row.GetProperty("input");
            var expected = row.GetProperty("expected");
            var doc = CanonicalText.Assemble(input.GetProperty("kind").GetString()!,
                Strings(input, "parts"), Strings(input, "names"), input.GetProperty("maxScalars").GetInt32());
            if (expected.TryGetProperty("error", out var error))
            {
                Error(error.GetString()!, () => ScalarChunker.Bounded(doc.Text, doc.Pages,
                    input.GetProperty("maxChunks").GetInt32(), input.GetProperty("window").GetInt32(),
                    input.GetProperty("overlap").GetInt32()));
                continue;
            }
            Assert.Equal(expected.GetProperty("text").GetString(), doc.Text);
            Assert.Equal(expected.GetProperty("pages").EnumerateArray().Select(p =>
                new PageBoundary(p.GetProperty("page").GetInt32(), p.GetProperty("start").GetInt32(),
                    p.GetProperty("end").GetInt32())), doc.Pages);
            var chunks = ScalarChunker.Bounded(doc.Text, doc.Pages, input.GetProperty("maxChunks").GetInt32(),
                input.GetProperty("window").GetInt32(), input.GetProperty("overlap").GetInt32());
            var expectedChunks = expected.GetProperty("chunks").EnumerateArray().ToArray();
            Assert.Equal(expectedChunks.Length, chunks.Count);
            for (int n = 0; n < chunks.Count; n++)
            {
                var chunk = chunks[n]; var e = expectedChunks[n];
                Assert.Equal(e.GetProperty("text").GetString(), chunk.Text);
                Assert.Equal(e.GetProperty("start").GetInt32(), chunk.CharStart);
                Assert.Equal(e.GetProperty("end").GetInt32(), chunk.CharEnd);
                Assert.Equal(e.GetProperty("tokens").GetInt32(), chunk.TokenCount);
                Assert.Equal(string.Concat(doc.Text.EnumerateRunes().Skip(chunk.CharStart!.Value)
                    .Take(chunk.CharEnd!.Value - chunk.CharStart.Value)), chunk.Text);
                var pages = doc.Pages.Where(p => p.End > p.Start && p.Start < chunk.CharEnd && p.End > chunk.CharStart).ToArray();
                Assert.Equal(pages.FirstOrDefault()?.Page, chunk.PageHint);
                if (e.TryGetProperty("pageFrom", out var from))
                {
                    Assert.Equal(from.GetInt32(), pages.First().Page);
                    Assert.Equal(e.GetProperty("pageTo").GetInt32(), pages.Last().Page);
                }
            }
        }
        Assert.Equal(rows.Length, visited.Count);
        Assert.Equal(9, visited.Count);
        var sheets = CanonicalText.Assemble("xlsx", new[] { "A1: 😀", "" }, new[] { "One", "Two" }, 100);
        Assert.Equal("## One\nA1: 😀\n\n## Two\n", sheets.Text);
        Assert.Equal(new[] { "One", "Two" }, sheets.SheetNames);
        Assert.Null(Assert.Single(ScalarChunker.Bounded("x", new[] { new PageBoundary(1, 0, 0) }, 1)).PageHint);
        var blankPages = CanonicalText.Assemble("pdf", new[] { "", " \t", "" }, null, 6);
        Assert.Equal("\n\n \t\n\n", blankPages.Text);
        Assert.Empty(ScalarChunker.Bounded(blankPages.Text, blankPages.Pages, 1));
    }

    [Fact]
    public void LimitsBeforeAppend()
    {
        Assert.Equal("😀", TextDecoding.Decode(Encoding.UTF8.GetBytes("😀"), "none", 1).Text);
        Error("textLimit", () => TextDecoding.Decode(Encoding.UTF8.GetBytes("😀x"), "cp1250", 1));
        Error("textLimit", () => CanonicalText.Assemble("pdf", new[] { "A", "B" }, null, 3));
        Error("textLimit", () => CanonicalText.Assemble("pptx", new[] { "" }, null, 10));
        Error("chunkLimit", () => ScalarChunker.Bounded(new string('x', 4097), Array.Empty<PageBoundary>(), 2));
        Assert.Empty(ScalarChunker.Bounded("", Array.Empty<PageBoundary>(), 0));
        foreach (byte value in new byte[] { 0x81, 0x83, 0x88, 0x90, 0x98 })
            Error("unsupportedEncoding", () => TextDecoding.Decode(new[] { value }, "cp1250", 1));
        // Cross fixed decoder-buffer boundaries with supplementary scalars and strict terminal errors.
        string text = new string('a', 65535) + "😀ě";
        Assert.Equal(text, TextDecoding.Decode(Encoding.UTF8.GetBytes(text), "none", 65537).Text);
        foreach (var codec in new Encoding[] { new UnicodeEncoding(false, true, true), new UnicodeEncoding(true, true, true) })
        {
            var bytes = codec.GetPreamble().Concat(codec.GetBytes(text)).ToArray();
            Assert.Equal(text, TextDecoding.Decode(bytes, "none", 65537).Text);
            Error("unsupportedEncoding", () => TextDecoding.Decode(bytes[..^1], "cp1250", 100000));
        }
    }

    [Fact]
    public void RuleValidation()
    {
        var tables = UnicodeTables.LoadBundled();
        var rules = (FolderRules.Defaults with { IncludeExts = new[] { ".MD", "TXT" } }).Validate(tables, true);
        Assert.Equal(new[] { "md", "txt" }, rules.IncludeExts);
        Assert.Equal("cp1250", FolderRules.Defaults.EncodingFallback);
        Assert.Equal(1_000_000, IngestionLimits.Defaults.Cells);
        Assert.Equal(IngestionLimits.Defaults, IngestionLimits.FromJson("{}"));
        Assert.Equal(IngestionLimits.Defaults, IngestionLimits.FromJson(IngestionLimits.Defaults.ToJson()));
        Error("unsupportedSyntax", () => (rules with { IncludeExts = new[] { "*.md" } }).Validate(tables, true));
        Error("unsupportedSyntax", () => (rules with { IgnoreGlobs = new[] { "!secret" } }).Validate(tables, true));
        Error("unsupportedEncoding", () => (rules with { EncodingFallback = "latin1" }).Validate(tables, true));
        Error("fileLimit", () => (IngestionLimits.Defaults with { FileBytes = 0 }).Validate());
        Error("officeLimit", () => (IngestionLimits.Defaults with { OfficeBytes = 209_715_201 }).Validate());
        Error("textLimit", () => (IngestionLimits.Defaults with { TextScalars = 5_000_001 }).Validate());
        Error("pageLimit", () => (IngestionLimits.Defaults with { PdfPages = 2001 }).Validate());
        Error("chunkLimit", () => (IngestionLimits.Defaults with { Chunks = 5001 }).Validate());
        Error("cellLimit", () => (IngestionLimits.Defaults with { Cells = 1_000_001 }).Validate());
        string[] extensions = ["md"];
        var snapshot = rules with { IncludeExts = extensions };
        extensions[0] = "txt";
        Assert.Equal("md", Assert.Single(snapshot.IncludeExts));
    }

    private static JsonElement[] Cases(string name) => SharedFixtures.Json($"contracts/{name}.json")
        .GetProperty("cases").EnumerateArray().ToArray();
    private static string[] Strings(JsonElement input, string key) => input.GetProperty(key).EnumerateArray()
        .Select(x => x.GetString()!).ToArray();
    private static void Error(string code, Action action) => Assert.Equal(code, Assert.Throws<FolderIngestionException>(action).Code);
}
