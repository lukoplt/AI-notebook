using System.Text;
using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalCorpusTests
{
    private static byte[] Bytes(JsonElement c, string key) => Encoding.UTF8.GetBytes(
        c.TryGetProperty(key + "_json", out var raw) ? raw.GetString()! : c.GetProperty(key).GetRawText());

    private static void Check(JsonElement c)
    {
        var name = c.GetProperty("name").GetString();
        var expected = c.GetProperty("expected");
        var files = c.GetProperty("files");
        var reads = 0;
        EvalCorpus? result = null;
        var error = Record.Exception(() => result = EvalCorpus.Load(
            Bytes(c, "manifest"), Bytes(c, "queries"), p =>
            {
                reads++;
                return files.GetProperty(p).EnumerateArray().Select(b => b.GetByte()).ToArray();
            }));
        if (expected.GetProperty("error").ValueKind != JsonValueKind.Null)
        {
            Assert.True(error is EvalFailure, $"{name}: expected EvalFailure, got {error}");
            var code = expected.GetProperty("error").GetString();
            Assert.True(code == ((EvalFailure)error).Code,
                $"{name}: expected {code}, got {((EvalFailure)error).Code}");
            Assert.Null(result);
            if (code == "invalid_path") Assert.Equal(0, reads);
            return;
        }

        Assert.True(error is null, $"{name}: unexpected failure: {error}");
        Assert.NotNull(result);
        var spans = expected.GetProperty("spans").EnumerateArray().ToArray();
        Assert.Equal(result.Questions.Count, result.Gold.Count);
        Assert.Equal(spans.Length, result.Gold.Values.Sum(g => g.Count));
        foreach (var q in result.Questions)
        {
            var wanted = spans.Where(s => s.GetProperty("query_id").GetString() == q.QueryId)
                .Select(s => new EvalSpan(s.GetProperty("document_id").GetString()!,
                    s.GetProperty("content_hash").GetString()!, s.GetProperty("start").GetInt32(),
                    s.GetProperty("end").GetInt32()));
            Assert.Equal(wanted, result.Gold[q.QueryId]);
            if (q.CaseType == "empty_selection") Assert.Empty(result.SelectedDocuments(q));
        }
    }

    [Fact]
    public void SharedValidatorCases()
    {
        var cases = SharedFixtures.Json("contracts/eval-assets-v1.json").GetProperty("cases");
        var visited = new HashSet<string>(StringComparer.Ordinal);
        void Visit(JsonElement c)
        {
            Assert.True(visited.Add(c.GetProperty("name").GetString()!));
            Check(c);
            if (c.TryGetProperty("subcases", out var subs))
                foreach (var sub in subs.EnumerateArray()) Visit(sub);
        }

        Assert.Equal(27, cases.GetArrayLength());
        foreach (var c in cases.EnumerateArray()) Visit(c);
        Assert.Equal(156, visited.Count);
    }

    [Fact]
    public void EntireCorpusAndEveryGoldReference()
    {
        var root = Path.Combine(AppContext.BaseDirectory, "EvalMultilingual");
        var manifest = File.ReadAllBytes(Path.Combine(root, "manifest.json"));
        var queries = File.ReadAllBytes(Path.Combine(root, "queries.json"));
        var corpus = EvalCorpus.Load(manifest, queries, p => File.ReadAllBytes(Path.Combine(root, p)));
        Assert.Equal("multilingual-v1", corpus.CorpusId);
        Assert.Equal(44, corpus.Documents.Count);
        Assert.Equal(144, corpus.Questions.Count);
        using var manifestJson = JsonDocument.Parse(manifest);
        using var queryJson = JsonDocument.Parse(queries);
        Assert.Equal(manifestJson.RootElement.GetProperty("documents").EnumerateArray()
            .Select(d => d.GetProperty("document_id").GetString()), corpus.Documents.Select(d => d.Metadata.DocumentId));
        Assert.Equal(queryJson.RootElement.GetProperty("queries").EnumerateArray()
            .Select(q => q.GetProperty("query_id").GetString()), corpus.Questions.Select(q => q.QueryId));
        var byId = corpus.Documents.ToDictionary(d => d.Metadata.DocumentId, StringComparer.Ordinal);
        foreach (var q in corpus.Questions)
        {
            var selected = corpus.SelectedDocuments(q);
            var expectedIds = corpus.Documents.Where(d => d.Metadata.NotebookId == q.NotebookId
                && (q.Scope is RetrievalScope.All || q.Scope is RetrievalScope.Selection s
                    && (s.SourceIds.Contains(d.Metadata.SourceId)
                        || d.Metadata.FolderId is long folder && s.FolderIds.Contains(folder))))
                .Select(d => d.Metadata.DocumentId);
            Assert.Equal(expectedIds, selected.Select(d => d.Metadata.DocumentId));
            Assert.Equal(q.Gold.Count, corpus.Gold[q.QueryId].Count);
            for (var i = 0; i < q.Gold.Count; i++)
            {
                var g = q.Gold[i];
                var span = corpus.Gold[q.QueryId][i];
                Assert.Equal(g.DocumentId, span.DocumentId);
                Assert.Equal(g.ContentHash, span.ContentHash);
                Assert.Contains(byId[g.DocumentId], selected);
                var text = byId[g.DocumentId].Text;
                var phrase = string.Concat(text.EnumerateRunes().Skip(span.Start)
                    .Take(span.End - span.Start).Select(r => r.ToString()));
                Assert.Equal(g.Phrase, phrase);
            }
            if (q.CaseType == "empty_selection") Assert.Empty(selected);
            if (q.CaseType == "overview")
                Assert.True(q.OverviewDocumentIds.ToHashSet(StringComparer.Ordinal)
                    .SetEquals(corpus.Gold[q.QueryId].Select(g => g.DocumentId)));
        }
        Assert.Equal(172, corpus.Gold.Values.Sum(g => g.Count));
        Assert.Equal(4, corpus.Questions.Count(q => q.CaseType == "empty_selection"));
    }

    [Fact]
    public void ScalarWindowsRetainExactTextAndOverlap()
    {
        var windows = EvalCorpus.Windows("😀abcdéf", size: 4, overlap: 1);
        Assert.Equal(new[] { 0, 3, 6 }, windows.Select(w => w.Start));
        Assert.Equal(new[] { 4, 7, 8 }, windows.Select(w => w.End));
        Assert.Equal(new[] { "😀abc", "cdé", "́f" }, windows.Select(w => w.Text));
        Assert.Equal("invalid_window", Assert.Throws<EvalFailure>(() => EvalCorpus.Windows("x", 4, 4)).Code);
    }

    [Fact]
    public void SharedWindowCases()
    {
        var cases = SharedFixtures.Json("contracts/eval-assets-v1.json").GetProperty("window_cases");
        Assert.Equal(3, cases.GetArrayLength());
        foreach (var c in cases.EnumerateArray())
        {
            var input = c.GetProperty("input");
            var expected = c.GetProperty("expected");
            IReadOnlyList<EvalWindow> Run() => EvalCorpus.Windows(input.GetProperty("text").GetString()!,
                input.GetProperty("size").GetInt32(), input.GetProperty("overlap").GetInt32());
            if (expected.GetProperty("error").ValueKind != JsonValueKind.Null)
                Assert.Equal(expected.GetProperty("error").GetString(), Assert.Throws<EvalFailure>(() => Run()).Code);
            else
                Assert.Equal(expected.GetProperty("windows").EnumerateArray().Select(w => new EvalWindow(
                    w.GetProperty("start").GetInt32(), w.GetProperty("end").GetInt32(), w.GetProperty("text").GetString()!)), Run());
        }
    }
}
