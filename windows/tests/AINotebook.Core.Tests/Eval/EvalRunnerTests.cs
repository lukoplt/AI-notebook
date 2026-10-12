using System.Diagnostics;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalRunnerTests
{
    private static string CorpusRoot => Path.Combine(AppContext.BaseDirectory, "EvalMultilingual");
    private static EvalOptions Lexical => EvalOptions.Parse(["--dataset", "multilingual"]);
    private static EvalOptions Ollama => EvalOptions.Parse(["--dataset", "multilingual", "--mode", "ollama", "--model", "fixture-model"]);

    [Fact]
    public void SharedOptions()
    {
        static IEnumerable<JsonElement> Descendants(JsonElement c)
        {
            yield return c;
            if (c.TryGetProperty("subcases", out var subs))
                foreach (var sub in subs.EnumerateArray())
                    foreach (var value in Descendants(sub)) yield return value;
        }
        var cases = SharedFixtures.Json("contracts/eval-cli-v1.json").GetProperty("cases");
        Assert.Equal(6, cases.GetArrayLength());
        var visited = new HashSet<string>();
        foreach (var c in cases.EnumerateArray().SelectMany(Descendants))
        {
            var name = c.GetProperty("name").GetString()!;
            Assert.True(visited.Add(name));
            var args = c.GetProperty("args").EnumerateArray().Select(x => x.GetString()!).ToArray();
            var expected = c.GetProperty("expected");
            // folder-rag-v1 §5 was tightened after this fixture: numeric last labels
            // must be strict dotted-quad IPv4, never System.Uri's shorthand address.
            if (name == "host-single-numeric-label")
            {
                Assert.Equal("http://1234/ollama", expected.GetProperty("host").GetString());
                Assert.Equal("usage", Assert.Throws<EvalFailure>(() => EvalOptions.Parse(args)).Code);
                continue;
            }
            if (expected.TryGetProperty("error", out var error))
            {
                Assert.Equal(error.GetString(), Assert.Throws<EvalFailure>(() => EvalOptions.Parse(args)).Code);
                continue;
            }
            var actual = EvalOptions.Parse(args);
            Assert.Equal(expected.GetProperty("root").GetString(), actual.Root);
            Assert.Equal(expected.GetProperty("mode").GetString(), actual.Mode);
            Assert.Equal(expected.GetProperty("model").GetString(), actual.Model);
            Assert.Equal(expected.GetProperty("host").GetString(), actual.Host);
            Assert.Equal(expected.GetProperty("top_k").GetInt32(), actual.TopK);
            Assert.Equal(expected.GetProperty("fetch_k").GetInt32(), actual.FetchK);
            Assert.Equal(expected.GetProperty("json_path").GetString(), actual.JsonPath);
            Assert.Equal(expected.GetProperty("markdown_path").GetString(), actual.MarkdownPath);
            Assert.Equal(expected.GetProperty("validate_only").GetBoolean(), actual.ValidateOnly);
        }
        Assert.Equal(107, visited.Count);
    }

    [Fact]
    public void PrefixedHostRetainsApiRoot()
    {
        var options = EvalOptions.Parse(["--dataset", "multilingual", "--host", "https://localhost/ollama"]);
        var adapted = new Uri(options.Host.TrimEnd('/') + "/");
        Assert.Equal("https://localhost/ollama/api/embed", new Uri(adapted, "api/embed").AbsoluteUri);
        // WP2's merged adapter now uses this contract-aware join directly.
        Assert.Equal("https://localhost/ollama/api/embed",
            ProviderApiRoot.Build(ProviderType.Ollama, adapted.OriginalString, ProviderEndpoint.Embeddings).AbsoluteUri);
    }

    [Fact]
    public async Task OfflineRunHasEveryRowAndNoInventedHybridOrPackingScore()
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        var client = new RecordingEmbedder((_, _) => throw new InvalidOperationException("Offline mode called provider"));
        var report = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Lexical, client);
        Assert.Equal(44, report.Documents);
        Assert.Equal(144, report.QueriesTotal);
        Assert.Equal(144, report.Queries.Count);
        Assert.Equal("windows", report.Platform);
        Assert.Null(report.Model);
        Assert.Null(report.Dimensions);
        Assert.Equal("not_available", report.Metrics["hybrid_recall_at_top_k"].Status);
        Assert.Equal("not_available", report.Metrics["packed_evidence_recall"].Status);
        Assert.Empty(client.Calls);
        foreach (var row in report.Queries.Where(q => q.CaseType == "empty_selection"))
        {
            Assert.Equal(0, row.FilesInScope);
            Assert.Equal(0, row.CandidatesWithChunks);
            Assert.Empty(row.Lexical);
            Assert.Empty(row.Vector);
            Assert.Empty(row.Fused);
        }
        Assert.Equal(4, report.Queries.Count(q => q.Status == "deferred_overview_wp8"));
        foreach (var row in report.Queries.Where(q => q.CaseType == "overview"))
        {
            Assert.Empty(row.Fused);
            Assert.All(row.Metrics.Values, m => Assert.Equal(EvalMetric.NotApplicable, m));
        }
        AssertGroupTotals(report);
    }

    [Fact]
    public async Task InjectedEmptyPackIsMeasuredZero()
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        var calls = new List<string>();
        var report = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Lexical, pack: (q, evidence, _) =>
        {
            calls.Add(q.QueryId);
            var selected = loaded.Corpus.SelectedDocuments(q).Select(d => d.Metadata.DocumentId).ToHashSet();
            Assert.All(evidence, e => Assert.Contains(e.Span.DocumentId, selected));
            Assert.DoesNotContain(q.CaseType, new[] { "overview", "empty_selection" });
            return Task.FromResult<IReadOnlyList<EvalSpan>>([]);
        });
        Assert.Equal(136, calls.Count);
        Assert.Equal("measured", report.Capabilities.PackedEvidence);
        Assert.Equal("measured", report.Metrics["packed_evidence_recall"].Status);
        Assert.Equal(0, report.Metrics["packed_evidence_recall"].RecallBp);
        Assert.True(report.Metrics["packed_evidence_recall"].Total > 0);
        AssertGroupTotals(report);
    }

    [Fact]
    public async Task OfflineOutputIsDeterministicAndHashUsesOriginalEnvelopeBytes()
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        var expectedHash = EvalCorpus.Sha256(File.ReadAllBytes(Path.Combine(CorpusRoot, "manifest.json"))
            .Concat(new byte[] { 0 }).Concat(File.ReadAllBytes(Path.Combine(CorpusRoot, "queries.json"))).ToArray());
        Assert.Equal(expectedHash, loaded.Hash);
        var first = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Lexical);
        var second = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Lexical);
        Assert.Equal(first.JsonBytes(), second.JsonBytes());
        Assert.Equal(first.Markdown(), second.Markdown());
        Assert.Equal(loaded.Corpus.Questions.Select(q => q.QueryId), first.Queries.Select(q => q.QueryId));
    }

    private static void AssertGroupTotals(EvalReportV1 report)
    {
        foreach (var (name, metric) in report.Metrics.Where(p => p.Value.Status == "measured"))
            foreach (var groups in new[] { report.ByLanguage, report.ByCaseType })
            {
                Assert.Equal(metric.Found, groups.Values.Sum(g => g[name].Found ?? 0));
                Assert.Equal(metric.Total, groups.Values.Sum(g => g[name].Total ?? 0));
            }
    }

    [Fact]
    public async Task SharedScopedBranchesReachReportWithoutLosingFullUnion()
    {
        var cases = EvalRetrievalTests.Cases().Where(c => c.GetProperty("kind").GetString() == "retrieval"
            && !c.GetProperty("expected").TryGetProperty("error", out _)).ToArray();
        Assert.Equal(7, cases.Length);
        foreach (var c in cases)
        {
            var input = c.GetProperty("input");
            var corpus = BranchCorpus(input);
            var vectors = input.GetProperty("documents").EnumerateArray()
                .SelectMany(d => d.GetProperty("chunks").EnumerateArray())
                .GroupBy(x => x.GetProperty("text").GetString()!, StringComparer.Ordinal)
                .ToDictionary(g => g.Key, g => Vector(g.First().GetProperty("vector")), StringComparer.Ordinal);
            var query = input.GetProperty("query").GetString()!;
            var client = new RecordingEmbedder((texts, _) => texts.Select(t => t == query
                ? Vector(input.GetProperty("query_vector")) : vectors[t]).ToArray());
            var include = input.GetProperty("include_vectors").GetBoolean();
            var options = (include ? Ollama : Lexical) with
            { TopK = input.GetProperty("top_k").GetInt32(), FetchK = input.GetProperty("fetch_k").GetInt32() };
            var report = await EvalRunner.RunAsync(corpus, new string('a', 64), options, client);
            var row = Assert.Single(report.Queries);
            foreach (var (key, spans) in new[] { ("lexical", row.Lexical), ("vector", row.Vector), ("fused", row.Fused) })
                Assert.Equal(c.GetProperty("expected").GetProperty(key).EnumerateArray().Select(x => x.GetProperty("document_id").GetString()),
                    spans.Select(s => s.DocumentId));
            Assert.Equal(corpus.SelectedDocuments(corpus.Questions[0]).Count, row.FilesInScope);
            Assert.All(row.Fused, span => Assert.Contains(span.DocumentId, corpus.SelectedDocuments(corpus.Questions[0]).Select(d => d.Metadata.DocumentId)));
            var ingestCalls = include ? (corpus.Documents.Count + 15) / 16 : 0;
            Assert.Equal(ingestCalls + c.GetProperty("expected").GetProperty("embedding_calls").GetInt32(), client.Calls.Count);
        }
    }

    internal static EvalCorpus BranchCorpus(JsonElement input)
    {
        var documents = input.GetProperty("documents").EnumerateArray().ToArray();
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal);
        var metadata = documents.Select(d =>
        {
            var id = d.GetProperty("document_id").GetString()!;
            var text = string.Join("\n", d.GetProperty("chunks").EnumerateArray().Select(c => c.GetProperty("text").GetString()));
            files[$"documents/{id}.txt"] = Encoding.UTF8.GetBytes(text);
            var hash = EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text));
            return new { document_id = id, source_id = d.GetProperty("source_id").GetInt64(), notebook_id = d.GetProperty("notebook_id").GetInt64(),
                folder_id = d.GetProperty("folder_id").GetInt64(), path = $"documents/{id}.txt", rel_path = $"{id}.txt", language = "en", encoding = "utf-8", raw_sha256 = hash, content_hash = hash };
        }).ToArray();
        var scope = RetrievalScopeJson.Deserialize(input.GetProperty("scope").GetRawText());
        var nb = input.GetProperty("notebook_id").GetInt64();
        var selected = metadata.Where(d => d.notebook_id == nb && (scope is RetrievalScope.All ||
            scope is RetrievalScope.Selection s && (s.SourceIds.Contains(d.source_id) || s.FolderIds.Contains(d.folder_id)))).ToArray();
        var gold = selected.Take(1).Select(d => new { document_id = d.document_id, content_hash = d.content_hash,
            phrase = Encoding.UTF8.GetString(files[d.path]), occurrence = 1 }).ToArray();
        var manifest = JsonSerializer.SerializeToUtf8Bytes(new { contract = "eval-corpus", version = 1, corpus_id = "fixture-runner", license = "MIT", documents = metadata });
        var queries = JsonSerializer.SerializeToUtf8Bytes(new { contract = "eval-queries", version = 1, corpus_id = "fixture-runner", queries = new[] {
            new { query_id = "q1", text = input.GetProperty("query").GetString(), language = "en", case_type = selected.Length == 0 ? "empty_selection" : "scope",
                tags = Array.Empty<string>(), notebook_id = nb, scope = input.GetProperty("scope"), gold,
                absent_reason = selected.Length == 0 ? "empty_scope" : null, overview_document_ids = Array.Empty<string>() } } });
        return EvalCorpus.Load(manifest, queries, p => files[p]);
    }

    [Fact]
    public async Task EmbeddingBatchesUseSortedCanonicalWindowsAndSkipEmptyOrOverviewQueries()
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        var expected = loaded.Corpus.Documents.OrderBy(d => d.Metadata.DocumentId, StringComparer.Ordinal)
            .SelectMany(d => EvalCorpus.Windows(d.Text)).Select(w => w.Text).ToArray();
        var client = new RecordingEmbedder((texts, _) => texts.Select(_ => new[] { 1f, 0f }).ToArray());
        var report = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Ollama, client);
        var batches = (expected.Length + 15) / 16;
        Assert.Equal(expected, client.Calls.Take(batches).SelectMany(c => c.Inputs));
        Assert.All(client.Calls.Take(batches - 1), c => Assert.Equal(16, c.Inputs.Length));
        Assert.Equal(expected.Length - 16 * (batches - 1), client.Calls[batches - 1].Inputs.Length);
        Assert.All(client.Calls, c => Assert.Equal("fixture-model", c.Model));
        Assert.Equal(batches + 136, client.Calls.Count);
        Assert.Equal(2, report.Dimensions);
        Assert.Equal("measured", report.Metrics["hybrid_recall_at_top_k"].Status);
        AssertGroupTotals(report);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("extra")]
    [InlineData("empty")]
    [InlineData("zero")]
    [InlineData("nan")]
    [InlineData("infinite")]
    [InlineData("dimensions")]
    [InlineData("later-dimensions")]
    public async Task InvalidEmbeddingBatchFailsWithoutQueryExecution(string defect)
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        var client = new RecordingEmbedder((texts, call) =>
        {
            var values = texts.Select(_ => new[] { 1f, 0f }).ToArray();
            switch (defect)
            {
                case "missing": return values[..^1];
                case "extra": return values.Concat(new[] { new[] { 1f, 0f } }).ToArray();
                case "empty": values[0] = []; break;
                case "zero": values[0] = [0, 0]; break;
                case "nan": values[0] = [float.NaN, 0]; break;
                case "infinite": values[0] = [float.PositiveInfinity, 0]; break;
                case "dimensions": values[1] = [1, 0, 0]; break;
                case "later-dimensions" when call == 2: return texts.Select(_ => new[] { 1f, 0f, 0f }).ToArray();
            }
            return values;
        });
        var error = await Assert.ThrowsAsync<EvalFailure>(() => EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Ollama, client));
        Assert.Equal("invalid_embedding", error.Code);
        Assert.Equal(defect == "later-dimensions" ? 2 : 1, client.Calls.Count);
    }

    [Fact]
    public async Task CancellationBetweenBatchesStopsRun()
    {
        var loaded = EvalRunner.Load(CorpusRoot);
        using var cancel = new CancellationTokenSource();
        var client = new RecordingEmbedder((texts, _) => { cancel.Cancel(); return texts.Select(_ => new[] { 1f, 0f }).ToArray(); });
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, Ollama, client, ct: cancel.Token));
        Assert.Single(client.Calls);
    }

    [Theory]
    [InlineData("document")]
    [InlineData("hash")]
    [InlineData("negative")]
    [InlineData("empty")]
    [InlineData("past-end")]
    [InlineData("scope")]
    public async Task InvalidPackedSpansAreRejected(string defect)
    {
        var fixture = EvalRetrievalTests.Cases().Single(c => c.GetProperty("name").GetString() == "folder-before-limit");
        var corpus = BranchCorpus(fixture.GetProperty("input"));
        var d = corpus.SelectedDocuments(corpus.Questions[0])[0];
        var span = new EvalSpan(d.Metadata.DocumentId, d.Metadata.ContentHash, 0, 1);
        span = defect switch
        {
            "document" => span with { DocumentId = "missing" },
            "hash" => span with { ContentHash = new string('0', 64) },
            "negative" => span with { Start = -1 },
            "empty" => span with { End = 0 },
            "past-end" => span with { End = d.Text.EnumerateRunes().Count() + 1 },
            "scope" => new EvalSpan(corpus.Documents[0].Metadata.DocumentId, corpus.Documents[0].Metadata.ContentHash, 0, 1),
            _ => throw new InvalidOperationException()
        };
        var error = await Assert.ThrowsAsync<EvalFailure>(() => EvalRunner.RunAsync(corpus, new string('a', 64), Lexical,
            pack: (_, _, _) => Task.FromResult<IReadOnlyList<EvalSpan>>([span])));
        Assert.Equal("invalid_packed_span", error.Code);
    }

    [Fact]
    public void InternalSymlinkIsRejectedBeforeDocumentReadButExplicitRootIsAllowed()
    {
        using var temp = new TempCorpus();
        var outside = Path.Combine(temp.Container, "outside");
        Directory.CreateDirectory(outside);
        // Missing target file proves invalid_path precedes any document read/missing_file.
        LinkDirectory(Path.Combine(temp.Root, "documents"), outside);
        Assert.Equal("invalid_path", Assert.Throws<EvalFailure>(() => EvalRunner.Load(temp.Root)).Code);
        Directory.Delete(Path.Combine(temp.Root, "documents"));
        Directory.CreateDirectory(Path.Combine(temp.Root, "documents"));
        File.WriteAllText(Path.Combine(temp.Root, "documents", "a.txt"), "abc\n", new UTF8Encoding(false));
        var rootLink = Path.Combine(temp.Container, "selected-root");
        LinkDirectory(rootLink, temp.Root);
        Assert.Single(EvalRunner.Load(rootLink).Corpus.Documents);
    }

    [Fact]
    public void LeafReparsePointIsRejectedBeforeFileRead()
    {
        using var temp = new TempCorpus();
        Directory.CreateDirectory(Path.Combine(temp.Root, "documents"));
        var outside = Path.Combine(temp.Container, "outside");
        Directory.CreateDirectory(outside);
        // A directory link at the file path works as a junction on Windows too.
        // Checking only parents would try to read this directory and return missing_file.
        LinkDirectory(Path.Combine(temp.Root, "documents", "a.txt"), outside);
        Assert.Equal("invalid_path", Assert.Throws<EvalFailure>(() => EvalRunner.Load(temp.Root)).Code);
    }

    [Fact]
    public void MissingOrdinaryDocumentHasMissingFileError()
    {
        using var temp = new TempCorpus();
        Directory.CreateDirectory(Path.Combine(temp.Root, "documents"));
        Assert.Equal("missing_file", Assert.Throws<EvalFailure>(() => EvalRunner.Load(temp.Root)).Code);
    }

    private static void LinkDirectory(string path, string target)
    {
        try { Directory.CreateSymbolicLink(path, target); }
        catch (Exception error) when (OperatingSystem.IsWindows() &&
            error is UnauthorizedAccessException or PlatformNotSupportedException or IOException)
        {
            using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{path}\" \"{target}\"") { UseShellExecute = false })!;
            process.WaitForExit();
            Assert.Equal(0, process.ExitCode);
        }
        Assert.True((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0);
    }

    private sealed class TempCorpus : IDisposable
    {
        public string Container { get; } = Path.Combine(Path.GetTempPath(), "ainotebook-eval-" + Guid.NewGuid().ToString("N"));
        public string Root { get; }
        public TempCorpus()
        {
            Root = Path.Combine(Container, "root");
            Directory.CreateDirectory(Root);
            var fixture = SharedFixtures.Json("contracts/eval-assets-v1.json").GetProperty("cases")[0];
            File.WriteAllText(Path.Combine(Root, "manifest.json"), fixture.GetProperty("manifest").GetRawText(), new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(Root, "queries.json"), fixture.GetProperty("queries").GetRawText(), new UTF8Encoding(false));
        }
        public void Dispose() => Directory.Delete(Container, recursive: true);
    }

    private static float[] Vector(JsonElement values) => values.EnumerateArray().Select(v => v.GetSingle()).ToArray();

    private sealed class RecordingEmbedder(Func<IReadOnlyList<string>, int, float[][]> produce) : IEmbeddingProducing
    {
        public List<(string Model, string[] Inputs)> Calls { get; } = [];
        public Task<float[][]> EmbedAsync(string model, IReadOnlyList<string> inputs, CancellationToken ct = default)
        { Calls.Add((model, inputs.ToArray())); return Task.FromResult(produce(inputs, Calls.Count)); }
    }
}
