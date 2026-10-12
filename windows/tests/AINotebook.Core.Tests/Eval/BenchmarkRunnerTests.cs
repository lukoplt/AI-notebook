using System.Text;
using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class BenchmarkRunnerTests
{
    private static readonly JsonElement Root = SharedFixtures.Json("contracts/benchmark-run-v1.json");
    private static string CorpusRoot => Path.Combine(AppContext.BaseDirectory, "EvalMultilingual");

    private static IEnumerable<JsonElement> Cases(string kind) =>
        Root.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("kind").GetString() == kind);

    private static string Code(Action action) => Assert.Throws<BenchmarkException>(action).Code;

    [Fact]
    public void ParserRejectsRepeatedFlagsAndKeepsContractDefaults()
    {
        var o = BenchmarkOptions.Parse(["--benchmark", "--mode", "fixture", "--json", "a.json", "--out", "a.md"]);
        Assert.Equal(16, o.TopK); Assert.Equal(32, o.FetchK); Assert.Equal(new[] { 100000, 200000 }, o.ChunkCounts);
        Assert.Equal(7, o.ProfileIds.Count);
        Assert.Throws<BenchmarkException>(() => BenchmarkOptions.Parse(["--benchmark", "--mode", "fixture",
            "--queries", "200", "--queries", "1", "--json", "a", "--out", "b"]));
    }

    [Fact]
    public void SharedCliCases()
    {
        int n = 0;
        foreach (var c in Cases("cli"))
        {
            string name = c.GetProperty("name").GetString()!;
            var args = c.GetProperty("args").EnumerateArray().Select(x => x.GetString()!).ToArray();
            if (c.TryGetProperty("error", out var error))
            {
                Assert.True(error.GetString() == Code(() => BenchmarkOptions.Parse(args)), name);
                Assert.Equal(2, c.GetProperty("exitCode").GetInt32());
                n++;
                continue;
            }
            var o = BenchmarkOptions.Parse(args);
            var actual = JsonSerializer.SerializeToElement(new
            {
                calibration = o.Calibration, chatModel = o.ChatModel, chunkCounts = o.ChunkCounts, command = o.Command,
                concurrent = o.Concurrent, embeddingCounts = o.EmbeddingCounts, evidenceShareBp = o.EvidenceShareBp, fetchK = o.FetchK,
                host = o.Host, json = o.Json, maxOutput = o.MaxOutput, mode = o.Mode, ollamaPid = o.OllamaPid, @out = o.Out,
                profileIds = o.ProfileIds, queries = o.Queries, root = o.Root, runtimeContext = o.RuntimeContext, seed = o.Seed,
                tokenizerRoot = o.TokenizerRoot, topK = o.TopK, warmup = o.Warmup,
            });
            Assert.True(JsonElement.DeepEquals(c.GetProperty("expected"), actual), name + ": " + actual.GetRawText());
            n++;
        }
        Assert.Equal(24, n);
    }

    [Fact]
    public void PackedRecallUsesExactRetainedSpanAndRevision()
    {
        const string text = "prefix gold"; string hash = EvalCorpus.Sha256(Encoding.UTF8.GetBytes(text));
        var revision = new BenchmarkRevision(1, 10, "d", hash, text, [new ChunkReference(100, 1, 10, 0)]);
        var citation = new Citation(1, 100, 1, "prefix")
        {
            RevisionId = 10, Text = "prefix",
            Spans = new[] { new CitationSpan(0, 6, null, null) }, ChunkIds = new long[] { 100 }
        };
        var gold = new[] { new EvalSpan("d", hash, 7, 11) };
        var a = BenchmarkRunner.Audit([citation], "Claim [1] [99]", [revision], gold);
        Assert.Equal(1, a.SnapshotsCorrect); Assert.Equal(1, a.AnswerMarkersCorrect);
        Assert.Equal(2, a.AnswerMarkersTotal); Assert.Equal(0, a.AnswerGoldSupported);
        Assert.Equal(0, EvalMetrics.Recall(gold, a.Packed).Found);
        var stale = BenchmarkRunner.Audit([citation with { RevisionId = 11 }], "[1]", [revision], gold);
        Assert.Equal(0, stale.SnapshotsCorrect); Assert.Empty(stale.Packed);
    }

    private static EvalSpan Span(JsonElement s) => new(s.GetProperty("document_id").GetString()!, s.GetProperty("content_hash").GetString()!,
        s.GetProperty("start").GetInt32(), s.GetProperty("end").GetInt32());

    [Fact]
    public void SharedAuditCases()
    {
        int n = 0;
        foreach (var c in Cases("audit"))
        {
            string name = c.GetProperty("name").GetString()!;
            var revisions = c.GetProperty("revisions").EnumerateArray().Select(r => new BenchmarkRevision(r.GetProperty("sourceId").GetInt64(),
                r.GetProperty("revisionId").GetInt64(), r.GetProperty("documentId").GetString()!, r.GetProperty("contentHash").GetString()!,
                r.GetProperty("text").GetString()!, r.GetProperty("chunks").EnumerateArray().Select(x => new ChunkReference(
                    x.GetProperty("chunkId").GetInt64(), x.GetProperty("sourceId").GetInt64(), x.GetProperty("revisionId").GetInt64(),
                    x.GetProperty("ord").GetInt32())).ToArray())).ToArray();
            var citations = c.GetProperty("citations").EnumerateArray().Select(x => new Citation(x.GetProperty("marker").GetInt32(),
                x.GetProperty("chunkId").GetInt64(), x.GetProperty("sourceId").GetInt64(), x.GetProperty("snippet").GetString()!)
            {
                RevisionId = x.GetProperty("revisionId").GetInt64(),
                Text = x.GetProperty("text").GetString(),
                Spans = x.GetProperty("spans").EnumerateArray().Select(s => new CitationSpan(s.GetProperty("start").GetInt64(), s.GetProperty("end").GetInt64(), null, null)).ToArray(),
                ChunkIds = x.GetProperty("chunkIds").EnumerateArray().Select(i => i.GetInt64()).ToArray(),
            }).ToArray();
            var gold = c.GetProperty("gold").EnumerateArray().Select(Span).ToArray();
            var audit = BenchmarkRunner.Audit(citations, c.GetProperty("answer").GetString()!, revisions, gold);
            var e = c.GetProperty("expected");
            Assert.Equal(e.GetProperty("packed").EnumerateArray().Select(Span), audit.Packed);
            Assert.True(e.GetProperty("snapshotsCorrect").GetInt32() == audit.SnapshotsCorrect, name);
            Assert.Equal(e.GetProperty("snapshotsTotal").GetInt32(), audit.SnapshotsTotal);
            Assert.True(e.GetProperty("answerMarkersCorrect").GetInt32() == audit.AnswerMarkersCorrect, name);
            Assert.Equal(e.GetProperty("answerMarkersTotal").GetInt32(), audit.AnswerMarkersTotal);
            Assert.True(e.GetProperty("answerGoldSupported").GetInt32() == audit.AnswerGoldSupported, name);
            Assert.Equal(e.GetProperty("answerMarkersJudged").GetInt32(), audit.AnswerMarkersJudged);
            var recall = EvalMetrics.Recall(gold, audit.Packed);
            Assert.True(JsonElement.DeepEquals(e.GetProperty("packedRecall"), JsonSerializer.SerializeToElement(recall, BenchmarkJson.SnakeOptions)), name);
            n++;
        }
        Assert.Equal(8, n);
    }

    private static (EvalCorpus Corpus, string Hash) MiniCorpus()
    {
        string Hash(string t) => EvalCorpus.Sha256(Encoding.UTF8.GetBytes(t));
        var texts = new Dictionary<string, string> { ["documents/x.txt"] = "Alpha text.", ["documents/y.txt"] = "Beta text.", ["documents/z.txt"] = "" };
        object Doc(string id, long source, string path, string rel) => new
        {
            content_hash = Hash(texts[path]), document_id = id, encoding = "utf-8", folder_id = 1, language = "en", notebook_id = 1,
            path, raw_sha256 = Hash(texts[path]), rel_path = rel, source_id = source,
        };
        var manifest = JsonSerializer.SerializeToUtf8Bytes(new
        {
            contract = "eval-corpus", corpus_id = "mini", license = "MIT", version = 1,
            documents = new[] { Doc("x", 1, "documents/x.txt", "a/x.txt"), Doc("y", 2, "documents/y.txt", "b/y.txt"), Doc("z", 3, "documents/z.txt", "c/z.txt") },
        });
        var queries = JsonSerializer.SerializeToUtf8Bytes(new
        {
            contract = "eval-queries", corpus_id = "mini", version = 1,
            queries = new object[]
            {
                new
                {
                    absent_reason = (string?)null, case_type = "overview", language = "en", notebook_id = 1, query_id = "overview",
                    overview_document_ids = new[] { "x", "y" }, scope = new { kind = "all" }, tags = Array.Empty<string>(), text = "Summarize",
                    gold = new[]
                    {
                        new { content_hash = Hash(texts["documents/x.txt"]), document_id = "x", occurrence = 1, phrase = "Alpha" },
                        new { content_hash = Hash(texts["documents/y.txt"]), document_id = "y", occurrence = 1, phrase = "Beta" },
                    },
                },
                new
                {
                    absent_reason = "empty_scope", case_type = "empty_selection", language = "en", notebook_id = 1, query_id = "empty",
                    overview_document_ids = Array.Empty<string>(), scope = new { kind = "selection", sourceIds = Array.Empty<long>(), folderIds = Array.Empty<long>() },
                    tags = Array.Empty<string>(), text = "Anything?", gold = Array.Empty<object>(),
                },
            },
        });
        return (EvalCorpus.Load(manifest, queries, p => Encoding.UTF8.GetBytes(texts[p])), new string('0', 64));
    }

    [Fact]
    public async Task SharedQueryCases()
    {
        int n = 0;
        var (corpus, hash) = MiniCorpus();
        var options = BenchmarkOptions.Parse(["--benchmark", "--mode", "fixture", "--profiles", "nomic-v2-256", "--queries", "3", "--warmup", "1",
            "--json", "a", "--out", "b"]) with { ChunkCounts = [] };
        var env = BenchmarkRunner.FixtureEnvironment(options);
        var report = await BenchmarkRunner.RunAsync(options, corpus, hash, env, CancellationToken.None);
        var rows = report.Candidates.Single().Quality.Queries.ToDictionary(r => r.Eval.QueryId);
        foreach (var c in Cases("query"))
        {
            string name = c.GetProperty("name").GetString()!;
            var e = c.GetProperty("expected");
            switch (name)
            {
                case "empty-selection":
                {
                    var row = rows["empty"];
                    Assert.Equal(e.GetProperty("citations").GetInt32(), row.CitationMap.Count);
                    Assert.Null(row.PreparedHash);
                    Assert.Null(row.AnswerText);
                    Assert.All(row.Eval.Metrics.Values, m => Assert.Equal("not_applicable", m.Status));
                    break;
                }
                case "overview":
                {
                    var row = rows["overview"];
                    var overview = e.GetProperty("overview");
                    Assert.Equal(new BenchmarkOverview(overview.GetProperty("filesInScope").GetInt32(),
                        overview.GetProperty("publishedCandidateFiles").GetInt32(), overview.GetProperty("filesIncluded").GetInt32()), row.Overview);
                    Assert.Equal("not_applicable", row.Eval.Metrics["packed_evidence_recall"].Status);
                    Assert.Null(row.Timing);
                    break;
                }
                case "hit-own-revision":
                {
                    var input = c.GetProperty("input");
                    var revisions = input.GetProperty("revisions").EnumerateArray().ToDictionary(
                        r => (r.GetProperty("sourceId").GetInt64(), r.GetProperty("revisionId").GetInt64()),
                        r => new BenchmarkRevision(r.GetProperty("sourceId").GetInt64(), r.GetProperty("revisionId").GetInt64(),
                            r.GetProperty("documentId").GetString()!, r.GetProperty("contentHash").GetString()!, "", []));
                    var spans = input.GetProperty("hits").EnumerateArray().Select(h => BenchmarkRunner.SpanFor(
                        new ChunkReference(h.GetProperty("chunkId").GetInt64(), h.GetProperty("sourceId").GetInt64(), h.GetProperty("revisionId").GetInt64(), 0),
                        h.GetProperty("start").GetInt32(), h.GetProperty("end").GetInt32(), revisions)).ToArray();
                    Assert.Equal(e.GetProperty("spans").EnumerateArray().Select(Span), spans);
                    break;
                }
                default: throw new InvalidOperationException(name);
            }
            n++;
        }
        Assert.Equal(3, n);
        // Only the overview question reached the provider: one chat call, no embedding, retrieval or neighbour call.
        Assert.Equal(1, env.Counters.ChatCalls);
        Assert.Equal(0, env.Counters.EmbeddingCalls);
        Assert.Equal(0, env.Counters.RetrievalCalls);
        Assert.Equal(0, env.Counters.NeighbourCalls);
        Assert.Equal(0, env.Counters.LeakedPins);
    }

    [Fact]
    public async Task SharedPhaseCases()
    {
        var (corpus, hash) = EvalRunner.Load(CorpusRoot);
        int n = 0;
        foreach (var c in Cases("phase"))
        {
            string name = c.GetProperty("name").GetString()!;
            var input = c.GetProperty("input");
            var expected = c.GetProperty("expected");
            var options = BenchmarkOptions.Parse(["--benchmark", "--mode", "fixture",
                "--profiles", string.Join(',', input.GetProperty("profiles").EnumerateArray().Select(x => x.GetString())),
                "--chunks", string.Join(',', input.GetProperty("chunkCounts").EnumerateArray().Select(x => x.GetInt32())),
                "--concurrent", input.GetProperty("concurrent").GetString()!,
                "--queries", input.GetProperty("queries").GetInt32().ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--warmup", input.GetProperty("warmup").GetInt32().ToString(System.Globalization.CultureInfo.InvariantCulture),
                "--json", "a", "--out", "b"]);
            var trace = new List<BenchmarkPhaseEvent>();
            using var cts = new CancellationTokenSource();
            var cancelAt = input.TryGetProperty("cancelAt", out var ca) ? ca : default;
            string work = Path.Combine(Path.GetTempPath(), "wp7-phase-" + Guid.NewGuid().ToString("N"));
            var template = BenchmarkRunner.FixtureEnvironment(options, work);
            var env = new BenchmarkRunEnvironment
            {
                Platform = template.Platform, Host = template.Host, CaptureAsync = template.CaptureAsync, VerifyAsync = template.VerifyAsync,
                ObserveChatAsync = template.ObserveChatAsync, NowUs = template.NowUs, StartSampler = template.StartSampler,
                MemoryMethod = template.MemoryMethod, ChatDigest = template.ChatDigest, TokenFamily = template.TokenFamily,
                ShowTemplateSha256 = template.ShowTemplateSha256, Estimator = template.Estimator, CalibrationHash = template.CalibrationHash,
                WorkDirectory = work, PaceConcurrentQueries = true, Trace = trace.Add,
                BeforeMeasuredQuery = (phase, chunks, index) =>
                {
                    if (cancelAt.ValueKind == JsonValueKind.Object && phase == cancelAt.GetProperty("phase").GetString()
                        && chunks == cancelAt.GetProperty("chunks").GetInt32() && index == cancelAt.GetProperty("measuredQuery").GetInt32())
                        cts.Cancel();
                },
            };
            BenchmarkReportV1? report = null;
            string? error = null;
            try { report = await BenchmarkRunner.RunAsync(options, corpus, hash, env, cts.Token); }
            catch (OperationCanceledException) { error = "cancelled"; }
            try
            {
                var expectedTrace = expected.GetProperty("trace").EnumerateArray().Select(t => new BenchmarkPhaseEvent(t.GetProperty("phase").GetString()!,
                    t.GetProperty("profileId").GetString()!, t.GetProperty("chunks").ValueKind == JsonValueKind.Null ? null : t.GetProperty("chunks").GetInt32()));
                Assert.Equal(expectedTrace, trace);
                var counters = expected.GetProperty("counters");
                Assert.Equal(0, env.Counters.LeakedPins);
                if (expected.TryGetProperty("error", out var e))
                {
                    Assert.Equal(e.GetString(), error);
                    Assert.Null(report);
                    Assert.Equal(counters.GetProperty("completedMeasuredQueries").GetInt32(), env.Counters.CompletedMeasuredQueries);
                    Assert.Equal(counters.GetProperty("writerAwaited").GetBoolean(), env.Counters.WriterAwaited);
                    Assert.Equal(counters.GetProperty("samplerAwaited").GetBoolean(), env.Counters.SamplerAwaited);
                    Assert.Equal(counters.GetProperty("privateDatabasesRemoved").GetBoolean(), env.Counters.PrivateDatabasesRemoved);
                    Assert.False(counters.GetProperty("successArtifact").GetBoolean());
                }
                else
                {
                    Assert.Null(error);
                    Assert.Equal(counters.GetProperty("candidates").GetInt32(), report!.Candidates.Count);
                    Assert.Equal(counters.GetProperty("performanceRows").GetInt32(), report.Candidates.Sum(x => x.Performance.Count));
                    Assert.Equal(counters.GetProperty("httpCalls").GetInt32(), env.Counters.HttpCalls);
                    Assert.All(report.Candidates.SelectMany(x => x.Performance), p =>
                    {
                        Assert.Equal(counters.GetProperty("measuredQueriesPerRow").GetInt32(), p.Samples.Count);
                        Assert.Equal(counters.GetProperty("warmupQueriesPerRow").GetInt32(), p.WarmupQueries);
                    });
                    Assert.All(report.Candidates, x => Assert.Equal("complete", x.Status));
                    Assert.All(report.Candidates, x => Assert.Equal(corpus.Questions.Count, x.Quality.Queries.Count));
                    Assert.True(env.Counters.PrivateDatabasesRemoved);
                    report.Validate();
                }
                Assert.Empty(Directory.Exists(work) ? Directory.GetFiles(work, "*.sqlite") : []);
            }
            finally { if (Directory.Exists(work)) Directory.Delete(work, true); }
            n++;
        }
        Assert.Equal(3, n);
    }

    [Fact]
    public async Task FixtureRunIsDeterministicAndMeasuresRealPackedEvidence()
    {
        var (corpus, hash) = EvalRunner.Load(CorpusRoot);
        var options = BenchmarkOptions.Parse(["--benchmark", "--mode", "fixture", "--profiles", "nomic-v2-256", "--chunks", "1000",
            "--queries", "3", "--warmup", "1", "--concurrent", "off", "--json", "a", "--out", "b"]);
        var first = await BenchmarkRunner.RunAsync(options, corpus, hash, BenchmarkRunner.FixtureEnvironment(options), CancellationToken.None);
        var second = await BenchmarkRunner.RunAsync(options, corpus, hash, BenchmarkRunner.FixtureEnvironment(options), CancellationToken.None);
        Assert.Equal(first.JsonBytes(), second.JsonBytes());
        Assert.Equal(first.Markdown(), second.Markdown());
        Assert.Equal("fixture", first.Mode);
        var candidate = Assert.Single(first.Candidates);
        Assert.True(candidate.Status == "complete", candidate.ErrorCode);
        Assert.Equal(144, candidate.Quality.Queries.Count);
        Assert.Equal("measured", candidate.Quality.Metrics["packed_evidence_recall"].Status);
        Assert.True(candidate.Ingest.SuccessfulTokens > 0);
        Assert.Equal("measured", candidate.Ingest.ServiceTokenStatus);
        Assert.Single(candidate.Performance);
        first.Validate();
    }

    [Fact]
    public async Task FixtureCalibrationFitsTrainBodiesAndChecksRenderedPrompts()
    {
        var (corpus, hash) = EvalRunner.Load(CorpusRoot);
        var options = BenchmarkOptions.Parse(["--calibrate", "--mode", "fixture", "--json", "c.json", "--out", "c.md"]);
        var env = BenchmarkRunner.FixtureEnvironment(options);
        try
        {
            var report = await BenchmarkRunner.CalibrateAsync(options, corpus, hash, env, CancellationToken.None);
            report.Validate();
            Assert.Equal("complete", report.Status);
            Assert.Equal("ollama:" + env.ChatDigest, report.Family);
            Assert.Equal("ollama-raw-prompt", report.Method);
            Assert.Equal(hash, report.CorpusHash);
            Assert.NotEmpty(report.Rates);
            Assert.Contains(report.Samples, x => x.Split == "holdout");
            Assert.Contains(report.PromptChecks, x => x.Split == "holdout");
            Assert.All(report.PromptChecks, x => Assert.NotNull(x.ActualTokens));
            var train = report.Samples.Where(x => x.Split == "train")
                .Select(x => new TokenSample(x.Id, report.Family, x.Language, "train", x.Scalars, x.Tokens!.Value)).ToArray();
            Assert.Equal(TokenCalibration.Fit(train), report.Rates);
            Assert.EndsWith("\n", report.Markdown());
            Assert.False(Directory.Exists(env.WorkDirectory) && Directory.GetFiles(env.WorkDirectory, "*.sqlite").Length > 0);
        }
        finally { if (Directory.Exists(env.WorkDirectory)) Directory.Delete(env.WorkDirectory, true); }
    }
}
