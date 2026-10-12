using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
using Xunit.Abstractions;

namespace AINotebook.Core.Tests.Language;

/// <summary>
/// The label-only fast path (<see cref="LanguageScorer.Fast"/>, used by ingestion) must decide exactly what the full
/// diagnostic scorer decides: label, reason, counts, winner, runner-up, margin, coverage and every profile's combined
/// score, for every lang-* fixture input and a large deterministic synthetic corpus, on the synthetic fixture models
/// and the production model.
/// </summary>
public sealed class LanguageFastScorerTests(ITestOutputHelper output)
{
    private static readonly Lazy<UnicodeTables> Tables = new(UnicodeTables.LoadBundled);

    private struct SplitMix(ulong state)
    {
        private ulong _state = state;
        public ulong Next()
        {
            _state += 0x9E3779B97F4A7C15UL;
            ulong z = _state;
            z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
            z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
            return z ^ (z >> 31);
        }
        public int Below(int n) => (int)(Next() % (ulong)n);
        public T Pick<T>(IReadOnlyList<T> values) => values[Below(values.Count)];
    }

    private static readonly Dictionary<string, string[]> Words = new()
    {
        ["cs"] = "smlouva faktura dodavatel odběratel termín plnění příloha cena celkem objednávka zakázka projekt rozpočet schůzka zápis vedení společnost oddělení zaměstnanec mzda dovolená převod účet platba splatnost záloha dokument kontrola revize návrh schválení podpis ředitel jednatel že který také jsou byl".Split(' '),
        ["sk"] = "zmluva faktúra dodávateľ odberateľ termín plnenia príloha cena spolu objednávka zákazka projekt rozpočet stretnutie zápisnica vedenie spoločnosť oddelenie zamestnanec mzda dovolenka prevod účet platba splatnosť záloha dokument kontrola revízia návrh schválenie podpis riaditeľ konateľ že ktorý tiež sú bol".Split(' '),
        ["en"] = "contract invoice supplier customer deadline delivery appendix price total order project budget meeting minutes management company department employee salary holiday transfer account payment due deposit document review revision proposal approval signature director board the which also are was".Split(' '),
        ["de"] = "Vertrag Rechnung Lieferant Kunde Frist Lieferung Anlage Preis gesamt Bestellung Auftrag Projekt Budget Besprechung Protokoll Leitung Gesellschaft Abteilung Mitarbeiter Gehalt Urlaub Überweisung Konto Zahlung Fälligkeit Anzahlung Dokument Prüfung Straße größer daß welcher auch sind war".Split(' '),
    };
    private static readonly string[] Languages = ["cs", "sk", "en", "de"];

    /// <summary>Combining marks (attached, leading, stacked), decomposed and precomposed letters, case-fold expansions,
    /// Hangul, CJK, supplementary letters and marks, emoji, digits, punctuation, controls and non-characters.</summary>
    private static readonly string[] Oddities =
    [
        "é", "́", "ậ", "̈x", "ﬀ", "ß", "ẞ", "İ", "ǅ", "Ωmega", "ΣΑΣ", "ﬁle",
        "한국어", "각", "中文字", "𝐀𝐁𝐂", "𐐀𐐨", "𝅘𝅥𝅮", "\U0001D167", "😀", "👩‍💻", "123", "4,5",
        "—", "…", "\t", "\n\n", "\0", "﻿", "�", "", "\U0010FFFD", "ʼ", "ꙮ", "ـ", "x⃝",
        "Ǆemal", "ŉ", "ΐ", "ͅ", "ﬃ", "ΆΈΉ", "Ⅻ", "①", "‍", "͏", "\uD800", "a\uDC00b",
    ];
    private static readonly string[] Separators = [" ", " ", " ", ", ", ". ", "\n", "-", "", "  "];
    private static readonly int[] PieceCounts = [0, 1, 2, 3, 5, 8, 13, 30, 80, 200, 600, 1500, 3000];

    private static string Sample(ref SplitMix rng)
    {
        string language = rng.Pick(Languages);
        int pieces = rng.Pick(PieceCounts);
        var text = new StringBuilder();
        for (int i = 0; i < pieces; i++)
        {
            if (rng.Below(40) == 0) language = rng.Pick(Languages); // mixed documents
            string word = rng.Pick(Words[language]);
            text.Append(rng.Below(20) switch
            {
                0 => rng.Pick(Oddities),
                1 => word.ToUpperInvariant(),
                2 => new string(word.Reverse().ToArray()),
                3 => word[..(1 + rng.Below(word.Length))],
                4 => ((char)(33 + rng.Below(94))).ToString(),
                _ => word,
            });
            if (i + 1 < pieces) text.Append(rng.Pick(Separators));
        }
        return text.ToString();
    }

    private static void AssertSame(LanguageScorer scorer, int[] stream, string name)
    {
        var slice = stream.Take(scorer.Model.Parameters.TextCapScalars).ToArray();
        var full = scorer.Score(slice);
        var fast = scorer.Fast.Decide(slice);
        string Expected() => string.Join("|", full.Label, full.Reason, full.LetterCount, full.WordCount, full.Winner, full.RunnerUp,
            full.Margin, full.CoverageBp, string.Join(",", scorer.Model.Profiles.Select(p => full.Profiles[p.Id].CombinedScore)));
        string Actual() => string.Join("|", fast.Label, fast.Reason, fast.LetterCount, fast.WordCount, fast.Winner, fast.RunnerUp,
            fast.Margin, fast.CoverageBp, string.Join(",", fast.CombinedScores));
        Assert.True(Expected() == Actual(), $"{name}: expected {Expected()} actual {Actual()}");
    }

    private static void AssertSameDocument(LanguageScorer scorer, int[] stream, string name)
    {
        var full = LanguageDocument.Detect(stream, scorer);
        var fast = scorer.Fast.DecideDocument(stream);
        static string Map(IReadOnlyDictionary<string, long> values) =>
            string.Join(",", values.OrderBy(p => p.Key, StringComparer.Ordinal).Select(p => $"{p.Key}={p.Value}"));
        string expected = string.Join("|", full.SampledLetters, Map(full.AcceptedLetters), full.UnknownLetters, Map(full.SharesBp),
            full.UnknownShareBp, full.LangCoverageBp, full.Label, full.Reason);
        string actual = string.Join("|", fast.SampledLetters, Map(fast.AcceptedLetters), fast.UnknownLetters, Map(fast.SharesBp),
            fast.UnknownShareBp, fast.LangCoverageBp, fast.Label, fast.Reason);
        Assert.True(expected == actual, $"{name}: expected {expected} actual {actual}");
    }

    private static void Check(LanguageScorer scorer, string text, string name)
    {
        var stream = LanguageNormalization.Stream(text, scorer.Tables, scorer.Model.Parameters.InputCapScalars);
        AssertSame(scorer, stream, name);
        AssertSameDocument(scorer, stream, name);
    }

    private static LanguageScorer Synthetic(JsonElement? overrides = null)
    {
        var model = JsonNode.Parse(SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("model").GetRawText())!;
        if (overrides is JsonElement changes)
            foreach (var change in changes.EnumerateObject())
            {
                if (change.Name == "parameters")
                    foreach (var parameter in change.Value.EnumerateObject())
                        model["parameters"]![parameter.Name] = JsonNode.Parse(parameter.Value.GetRawText());
                else model[change.Name] = JsonNode.Parse(change.Value.GetRawText());
            }
        return new(LanguageModel.Parse(Encoding.UTF8.GetBytes(model.ToJsonString() + "\n"), Tables.Value, true), Tables.Value);
    }

    private static readonly Lazy<LanguageScorer> Production = new(() => new LanguageScorer(
        LanguageModel.Parse(LanguageDetector.ReadBundledResource("lang-detector-v1.json"), Tables.Value, false), Tables.Value));

    [Fact]
    public void FixtureInputsDecideIdentically()
    {
        var synthetic = Synthetic();
        int checkedCases = 0;
        foreach (var c in SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("cases").EnumerateArray())
        {
            string input = c.GetProperty("input").GetString()!, name = c.GetProperty("name").GetString()!;
            Check(synthetic, input, name);
            Check(Production.Value, input, name + " (production)");
            checkedCases++;
        }
        foreach (var c in SharedFixtures.Json("contracts/lang-runtime-v1.json").GetProperty("cases").EnumerateArray()
                     .Where(c => c.GetProperty("operation").GetString() == "score"))
        {
            string input = c.GetProperty("input").GetString()!, name = c.GetProperty("name").GetString()!;
            Check(Synthetic(c.GetProperty("modelOverrides")), input, name);
            Check(Production.Value, input, name + " (production)");
            checkedCases++;
        }
        foreach (var c in SharedFixtures.Json("contracts/lang-release-v1.json").GetProperty("cases").EnumerateArray())
        {
            string input = c.GetProperty("input").GetString()!, name = c.GetProperty("name").GetString()!;
            Check(Production.Value, input, name);
            Check(synthetic, input, name + " (synthetic)");
            checkedCases++;
        }
        Assert.Equal(32 + 6 + 844, checkedCases);
    }

    [Fact]
    public void SyntheticCorpusDecidesIdentically()
    {
        var synthetic = Synthetic();
        var rng = new SplitMix(0x1A2B3C4D);
        var labels = new Dictionary<string, int>();
        // AINOTEBOOK_LANG_FAST_CASES raises the corpus size (e.g. 20000 in a Release build).
        int count = int.TryParse(Environment.GetEnvironmentVariable("AINOTEBOOK_LANG_FAST_CASES"), NumberStyles.Integer,
            CultureInfo.InvariantCulture, out int n) ? n : 300;
        for (int index = 0; index < count; index++)
        {
            string text = Sample(ref rng);
            Check(Production.Value, text, $"synthetic-{index}");
            if (index % 4 == 0) Check(synthetic, text, $"synthetic-{index} (synthetic model)");
            string label = Production.Value.Fast.Decide(LanguageNormalization.Stream(text, Tables.Value, 8192)).Label;
            labels[label] = labels.GetValueOrDefault(label) + 1;
        }
        // The corpus exercises accepted labels of every target and abstentions.
        foreach (string label in new[] { "cs", "de", "en", "sk", "und" }) Assert.True(labels.GetValueOrDefault(label) > 0, label);
    }

    /// <summary>The detector entry points ingestion uses agree with the diagnostic ones.</summary>
    [Fact]
    public void DetectorDecisionsMatchDiagnostics()
    {
        var detector = LanguageDetector.LoadBundled();
        Assert.True(detector.IsAvailable);
        var rng = new SplitMix(42);
        for (int index = 0; index < 60; index++)
        {
            string text = Sample(ref rng);
            var full = detector.DetectText(text)!;
            var fast = detector.DecideText(text)!;
            Assert.Equal((full.Label, full.Reason), (fast.Label, fast.Reason));
            var document = detector.DetectDocument(text)!;
            var aggregate = detector.DecideDocument(text)!;
            Assert.Equal((document.Label, document.Reason, document.LangCoverageBp, document.UnknownShareBp),
                (aggregate.Label, aggregate.Reason, aggregate.LangCoverageBp, aggregate.UnknownShareBp));
            Assert.Equal(document.SharesBp.OrderBy(p => p.Key, StringComparer.Ordinal), aggregate.SharesBp.OrderBy(p => p.Key, StringComparer.Ordinal));
        }
        Assert.Null(LanguageDetector.Unavailable.DecideText("text"));
        Assert.Null(LanguageDetector.Unavailable.DecideDocument("text"));
    }

    /// <summary>Opt-in (AINOTEBOOK_CPU_BENCH=1): normalization, full scorer and fast path on chunk-sized synthetic prose
    /// with the production model.</summary>
    [Fact]
    public void BenchmarkFullVersusFast()
    {
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_CPU_BENCH") != "1") return;
        var scorer = Production.Value;
        var rng = new SplitMix(7);
        var texts = new List<string>();
        for (int i = 0; i < 2000; i++)
        {
            var text = new StringBuilder();
            string language = rng.Pick(Languages);
            while (text.Length < 1800)
            {
                if (rng.Below(60) == 0) language = rng.Pick(Languages);
                text.Append(rng.Pick(Words[language])).Append(rng.Pick(new[] { " ", " ", " ", ", ", ". " }));
            }
            texts.Add(text.ToString());
        }
        static double Seconds(Action body)
        {
            long start = Stopwatch.GetTimestamp();
            body();
            return Stopwatch.GetElapsedTime(start).TotalSeconds;
        }
        // Warm up (tiered JIT) so every measured pass runs optimized code.
        foreach (string text in texts.Take(200))
        {
            var warm = LanguageNormalization.Stream(text, scorer.Tables, 5_000_000);
            _ = scorer.Score(warm.Take(8192).ToArray());
            _ = scorer.Fast.Decide(warm.AsSpan(0, Math.Min(warm.Length, 8192)));
            _ = LanguageDocument.Detect(warm, scorer);
            _ = scorer.Fast.DecideDocument(warm);
        }
        int[][] streams = [];
        double normalize = Seconds(() => streams = texts.Select(t => LanguageNormalization.Stream(t, scorer.Tables, 5_000_000)).ToArray());
        string[] fullLabels = [], fastLabels = [];
        double full = Seconds(() => fullLabels = streams.Select(s => scorer.Score(s.Take(8192).ToArray()).Label).ToArray());
        double fast = Seconds(() => fastLabels = streams.Select(s => scorer.Fast.Decide(s.AsSpan(0, Math.Min(s.Length, 8192))).Label).ToArray());
        double fullDocument = Seconds(() => _ = streams.Select(s => LanguageDocument.Detect(s, scorer).Label).ToArray());
        double fastDocument = Seconds(() => _ = streams.Select(s => scorer.Fast.DecideDocument(s).Label).ToArray());
        Assert.Equal(fullLabels, fastLabels);
        output.WriteLine(string.Format(CultureInfo.InvariantCulture,
            "LANG-BENCH dotnet {0} chunks (~1800 scalars): normalize {1:F3}s | text full {2:F3}s fast {3:F3}s ({4:F1}x) | document full {5:F3}s fast {6:F3}s ({7:F1}x)",
            texts.Count, normalize, full, fast, full / Math.Max(fast, 1e-9), fullDocument, fastDocument, fullDocument / Math.Max(fastDocument, 1e-9)));
    }
}
