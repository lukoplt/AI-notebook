using System.Collections.Frozen;
using System.Globalization;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AINotebook.Core.Language;

/// <summary>An offline detector. Missing or invalid bundled data leaves detection unavailable.</summary>
public sealed class LanguageDetector
{
    private readonly LanguageScorer? _scorer;
    private static readonly string[] ResourceNames =
    [
        "lang-detector-v1.manifest.json", "lang-detector-v1.json", "unicode-15.1.0.json",
        "unicode-15.1.0.json.sha256", "unicode-sources-v1.json", "UNICODE-LICENSE.txt", "NOTICE", "ATTRIBUTION.md"
    ];
    private static readonly Lazy<LanguageDetector> Bundled = new(() => Load(ReadBundledResource));
    public static LanguageDetector Unavailable { get; } = new(null);
    public bool IsAvailable => _scorer is not null;
    private LanguageDetector(LanguageScorer? scorer) => _scorer = scorer;
    public static LanguageDetector LoadBundled() => Bundled.Value;

    public LanguageTextResult? DetectText(string text) => _scorer is { } scorer
        ? ScoreText(LanguageNormalization.Stream(text, scorer.Tables, scorer.Model.Parameters.InputCapScalars), scorer) : null;
    public LanguageTextResult? DetectText(IReadOnlyList<ushort> utf16Units) => _scorer is { } scorer
        ? ScoreText(LanguageNormalization.Stream(utf16Units, scorer.Tables, scorer.Model.Parameters.InputCapScalars), scorer) : null;
    public LanguageDocumentResult? DetectDocument(string text) => _scorer is { } scorer
        ? LanguageDocument.Detect(LanguageNormalization.Stream(text, scorer.Tables, scorer.Model.Parameters.InputCapScalars), scorer) : null;
    public LanguageDocumentResult? DetectDocument(IReadOnlyList<ushort> utf16Units) => _scorer is { } scorer
        ? LanguageDocument.Detect(LanguageNormalization.Stream(utf16Units, scorer.Tables, scorer.Model.Parameters.InputCapScalars), scorer) : null;

    /// <summary>Ingestion's per-chunk detection: exactly the label and reason of <see cref="DetectText(string)"/>
    /// (contract lang-detector-v1), without its diagnostics.</summary>
    internal LanguageTextDecision? DecideText(string text)
    {
        if (_scorer is not { } scorer) return null;
        var stream = LanguageNormalization.Stream(text, scorer.Tables, scorer.Model.Parameters.InputCapScalars);
        return scorer.Fast.Decide(stream.AsSpan(0, Math.Min(stream.Length, scorer.Model.Parameters.TextCapScalars)));
    }

    /// <summary>Ingestion's document detection: exactly the aggregate (label, reason, shares, coverage) of
    /// <see cref="DetectDocument(string)"/>, without per-window diagnostics.</summary>
    internal LanguageAggregate? DecideDocument(string text) => _scorer is { } scorer
        ? scorer.Fast.DecideDocument(LanguageNormalization.Stream(text, scorer.Tables, scorer.Model.Parameters.InputCapScalars))
        : null;

    private static LanguageTextResult ScoreText(int[] stream, LanguageScorer scorer) =>
        scorer.Score(stream.Length <= scorer.Model.Parameters.TextCapScalars ? stream : stream[..scorer.Model.Parameters.TextCapScalars]);

    internal static LanguageDetector CreateForTests(byte[] modelData, UnicodeTables tables) =>
        new(new LanguageScorer(LanguageModel.Parse(modelData, tables, true), tables));

    internal static byte[] ReadBundledResource(string name)
    {
        LanguageJson.Require(ResourceNames.Contains(name, StringComparer.Ordinal), "Unknown language resource name.");
        using var stream = typeof(LanguageDetector).Assembly.GetManifestResourceStream("AINotebook.Core.Language." + name)
            ?? throw new FileNotFoundException("Missing embedded language resource: " + name);
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }

    internal static LanguageDetector Load(Func<string, byte[]> readResource)
    {
        try
        {
            // Only these fixed names ever reach the reader. Manifest paths are
            // checked against repository paths; they cannot request a file.
            var resources = ResourceNames.ToDictionary(name => name, name => readResource(name).ToArray(), StringComparer.Ordinal);
            var tables = LanguageBundleIntegrity.LoadTables(resources);
            var model = LanguageModel.Parse(resources["lang-detector-v1.json"], tables, false);
            using var manifest = LanguageJson.Parse(resources["lang-detector-v1.manifest.json"]);
            LanguageManifest.Validate(manifest.RootElement, model, resources);
            return new(new LanguageScorer(model, tables));
        }
        catch (Exception error) when (error is InvalidDataException or IOException or UnauthorizedAccessException or JsonException or FormatException or
            ArgumentException or InvalidOperationException or KeyNotFoundException or OverflowException)
        {
            return Unavailable;
        }
    }
}

internal static class LanguageBundleIntegrity
{
    internal const string UnicodeBase = "https://www.unicode.org/Public/15.1.0/ucd/";
    private const string ArchiveUrl = "https://www.unicode.org/Public/zipped/15.1.0/UCD.zip";
    private const string ArchiveSha256 = "cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177";
    internal static readonly FrozenDictionary<string, string> UnicodePins = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["UnicodeData.txt"] = "2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86",
        ["CaseFolding.txt"] = "4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf",
        ["DerivedNormalizationProps.txt"] = "8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1",
        ["NormalizationTest.txt"] = "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e"
    }.ToFrozenDictionary(StringComparer.Ordinal);

    internal static UnicodeTables LoadTables(IReadOnlyDictionary<string, byte[]> resources)
    {
        var sidecar = resources["unicode-15.1.0.json.sha256"];
        LanguageJson.Require(sidecar.Length == 65 && sidecar[^1] == 10, "Invalid table hash sidecar.");
        string expectedHash = Encoding.ASCII.GetString(sidecar, 0, 64);
        Digest(resources["unicode-15.1.0.json"], expectedHash);
        using var document = LanguageJson.Parse(resources["unicode-sources-v1.json"]);
        var sources = document.RootElement;
        LanguageJson.Keys(sources, "format", "unicodeVersion", "normalizationTablesVersion", "archive", "files", "license", "tableSha256", "normalizationRows");
        LanguageJson.Int(sources.GetProperty("format"), 1, 1);
        LanguageJson.Int(sources.GetProperty("normalizationRows"), 19074, 19074);
        LanguageJson.Require(LanguageJson.Text(sources.GetProperty("unicodeVersion")) == "15.1.0" &&
            LanguageJson.Text(sources.GetProperty("normalizationTablesVersion")) == UnicodeTables.NormalizationVersion, "Invalid Unicode provenance version.");
        Digest(resources["unicode-15.1.0.json"], LanguageJson.Text(sources.GetProperty("tableSha256")));
        var archive = sources.GetProperty("archive");
        LanguageJson.Keys(archive, "url", "sha256");
        LanguageJson.Require(LanguageJson.Text(archive.GetProperty("url")) == ArchiveUrl, "Invalid Unicode archive URL.");
        SameDigest(LanguageJson.Text(archive.GetProperty("sha256")), ArchiveSha256);
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var file in LanguageJson.Array(sources.GetProperty("files"), 4, 4))
        {
            LanguageJson.Keys(file, "name", "url", "sha256");
            string name = LanguageJson.Text(file.GetProperty("name"));
            LanguageJson.Require(seen.Add(name) && UnicodePins.ContainsKey(name) &&
                LanguageJson.Text(file.GetProperty("url")) == UnicodeBase + name, "Invalid Unicode source.");
            SameDigest(LanguageJson.Text(file.GetProperty("sha256")), UnicodePins[name]);
        }
        var license = sources.GetProperty("license");
        LanguageJson.Keys(license, "url", "sha256", "retrievedAt", "licenseId");
        LanguageJson.Require(LanguageJson.Text(license.GetProperty("url")) == "https://www.unicode.org/license.txt" &&
            LanguageJson.Text(license.GetProperty("licenseId")) == "Unicode-3.0", "Invalid Unicode license provenance.");
        CalendarDate(LanguageJson.Text(license.GetProperty("retrievedAt")));
        Digest(resources["UNICODE-LICENSE.txt"], LanguageJson.Text(license.GetProperty("sha256")));
        return UnicodeTables.Load(resources["unicode-15.1.0.json"], expectedHash);
    }

    private static byte[] HexDigest(string value)
    {
        LanguageJson.Require(value.Length == 64 && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f'), "Invalid SHA-256 hex.");
        return Convert.FromHexString(value);
    }
    internal static void Digest(byte[] bytes, string expected) =>
        LanguageJson.Require(CryptographicOperations.FixedTimeEquals(SHA256.HashData(bytes), HexDigest(expected)), "Resource SHA-256 mismatch.");
    internal static void SameDigest(string actual, string expected) =>
        LanguageJson.Require(CryptographicOperations.FixedTimeEquals(HexDigest(actual), HexDigest(expected)), "Pinned SHA-256 mismatch.");
    internal static void CalendarDate(string value) => LanguageJson.Require(
        DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _), "Invalid calendar date.");
}

internal static class LanguageManifest
{
    private static readonly string[] Splits = ["train", "validation", "test"];
    private static readonly string[] EvaluationSplits = ["validation", "test"];
    private static readonly int[] Buckets = [0, 12, 32, 80, 200];
    private static readonly string[] MetricNames = ["acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage"];
    private static string Text(JsonElement value, string key) => LanguageJson.Text(value.GetProperty(key));
    private static long Number(JsonElement value, string key) => LanguageJson.Int(value.GetProperty(key));
    private static JsonElement[] Rows(JsonElement value, string key) => LanguageJson.Array(value.GetProperty(key));
    private static string[] Strings(JsonElement value) => LanguageJson.Array(value).Select(x => LanguageJson.Text(x)).ToArray();
    private static void Require(bool valid, string reason) => LanguageJson.Require(valid, reason);

    internal static void Validate(JsonElement manifest, LanguageModel model, IReadOnlyDictionary<string, byte[]> resources)
    {
        using var schema = JsonDocument.Parse(Schema);
        ValidateSchema(manifest, schema.RootElement, schema.RootElement);
        Require(Text(manifest, "modelId") == model.ModelId, "Artifact model ID differs from manifest.");
        Require(Text(manifest, "artifactPath") == "Sources/AINotebookCore/Resources/Language/lang-detector-v1.json", "Invalid artifact repository path.");
        LanguageBundleIntegrity.Digest(resources["lang-detector-v1.json"], Text(manifest, "artifactSha256"));
        Require(ValidTimestamp(Text(manifest, "createdAt")), "Invalid manifest timestamp.");
        var attribution = LanguageAttribution.Parse(manifest.GetProperty("attribution"), false);
        Require(model.Attribution.SameAs(attribution), "Artifact attribution differs from manifest.");
        Require(attribution.AttributionPath == "tools/lang/ATTRIBUTION.md" && attribution.NoticePath == "NOTICE", "Invalid attribution repository path.");
        LanguageBundleIntegrity.Digest(resources["ATTRIBUTION.md"], attribution.AttributionSha256);
        LanguageBundleIntegrity.Digest(resources["NOTICE"], attribution.NoticeSha256);
        ValidateEnvironment(manifest.GetProperty("environment"));
        var negatives = Strings(manifest.GetProperty("negativeLanguages"));
        Require(negatives.SequenceEqual(negatives.Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal)) &&
            !negatives.Intersect(model.Targets, StringComparer.Ordinal).Any(), "Invalid negative languages.");
        var languages = model.Targets.Concat(negatives).Order(StringComparer.Ordinal).ToArray();
        var corpus = ValidateCorpus(manifest, languages, attribution);
        ValidateSplits(manifest.GetProperty("split"));
        ValidateRecords(manifest, model, languages, negatives, corpus);
    }

    private static bool ValidTimestamp(string value)
    {
        if (value.Length != 20) return false;
        if (value[17] != '6' || value[18] != '0')
            return DateTimeOffset.TryParseExact(value, "yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out _);
        // Match the Swift loader: accept UTC month-end leap-second notation
        // without consulting an online schedule or the host's leap-second data.
        return value[10..] == "T23:59:60Z" &&
            DateOnly.TryParseExact(value[..10], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date) &&
            date.Day == DateTime.DaysInMonth(date.Year, date.Month);
    }

    private static void ValidateEnvironment(JsonElement environment)
    {
        var dependencies = Rows(environment, "dependencies");
        Unique(dependencies, x => Text(x, "name"));
        var files = Rows(environment, "unicodeFiles");
        Unique(files, x => Text(x, "url"));
        foreach (var file in files)
        {
            string url = Text(file, "url");
            Require(url.StartsWith(LanguageBundleIntegrity.UnicodeBase, StringComparison.Ordinal), "Invalid Unicode source URL.");
            string name = url[LanguageBundleIntegrity.UnicodeBase.Length..];
            Require(LanguageBundleIntegrity.UnicodePins.ContainsKey(name), "Unexpected Unicode source.");
            LanguageBundleIntegrity.SameDigest(Text(file, "sha256"), LanguageBundleIntegrity.UnicodePins[name]);
            Require(Text(file, "role") == (name == "NormalizationTest.txt" ? "normalizationTest" : "unicodeData"), "Invalid Unicode source role.");
            LanguageBundleIntegrity.CalendarDate(Text(file, "snapshotDate"));
        }
    }

    private static Dictionary<string, JsonElement> ValidateCorpus(JsonElement manifest, string[] languages, LanguageAttribution attribution)
    {
        var corpus = Unique(Rows(manifest, "corpus"), source => Text(source, "id"));
        Require(new HashSet<string>(corpus.Keys, StringComparer.Ordinal).SetEquals(attribution.SourceIds), "Attribution source IDs do not match corpus.");
        var allLicenses = new HashSet<string>(StringComparer.Ordinal);
        var mappedLanguages = new HashSet<string>(StringComparer.Ordinal);
        foreach (var source in corpus.Values)
        {
            var licenses = Strings(source.GetProperty("licenseIds"));
            Require(licenses.All(x => x.Length > 0) && licenses.Distinct(StringComparer.Ordinal).Count() == licenses.Length, "Invalid source licenses.");
            allLicenses.UnionWith(licenses);
            var files = Unique(Rows(source, "files"), file => (Text(file, "role"), Text(file, "url")));
            bool owned = IsOwnedSource(source);
            var mappings = Unique(Rows(source, "languageMappings"), x => Text(x, "sourceLanguage"));
            foreach (var mapping in mappings.Values)
            {
                string language = Text(mapping, "detectorLanguage");
                Require(languages.Contains(language, StringComparer.Ordinal) || owned && language is "und" or "mul",
                    "Mapping refers to an unadmitted language.");
                // Owned document labels are provenance, not negative text languages.
                if (languages.Contains(language, StringComparer.Ordinal)) mappedLanguages.Add(language);
            }
            foreach (var file in files.Values)
            {
                LanguageBundleIntegrity.CalendarDate(Text(file, "snapshotDate"));
                Require(Uri.TryCreate(Text(file, "url"), UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps && uri.Host.Length > 0, "Invalid source URL.");
            }
        }
        Require(mappedLanguages.SetEquals(languages), "Language mappings do not cover admitted languages.");
        // The bundle also redistributes the pinned Unicode tables, so their license is attributed too.
        allLicenses.Add("Unicode-3.0");
        Require(allLicenses.SetEquals(attribution.LicenseIds), "Attribution licenses do not match corpus licenses.");
        return corpus;
    }

    private static void ValidateSplits(JsonElement split)
    {
        var parts = split.GetProperty("splitBp");
        Require(Splits.Sum(name => Number(parts, name)) == 10000, "Split shares do not total 10000.");
        long limit = Number(split, "maxComponentMembers");
        var groups = Unique(Rows(split, "oversizedComponents"), x => Text(x, "groupId"));
        var blockIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var group in groups.Values)
        {
            long count = Number(group, "memberCount");
            Require(count > limit, "Oversized component is not oversized.");
            var blocks = Rows(group, "blocks");
            Require(blocks.Length == (count - 1) / limit + 1, "Wrong oversized block count.");
            BigInteger total = 0;
            for (int index = 0; index < blocks.Length; index++)
            {
                var block = blocks[index];
                long members = Number(block, "memberCount");
                Require(blockIds.Add(Text(block, "groupId")) && members <= limit && (index == blocks.Length - 1 || members == limit), "Invalid oversized block.");
                total += members;
            }
            Require(total == count, "Oversized block counts do not reconcile.");
        }
    }

    private static Dictionary<TKey, JsonElement> Unique<TKey>(IEnumerable<JsonElement> records, Func<JsonElement, TKey> key) where TKey : notnull
    {
        var result = new Dictionary<TKey, JsonElement>();
        foreach (var row in records) Require(result.TryAdd(key(row), row), "Duplicate manifest record key.");
        return result;
    }

    private static bool IsOwnedSource(JsonElement source) =>
        Rows(source, "files").Any(file => Text(file, "role") == "ownedExamples") &&
        !Rows(source, "files").Any(file => Text(file, "role") == "sentences");

    private static void ValidateRecords(JsonElement manifest, LanguageModel model, string[] languages,
        string[] negatives, Dictionary<string, JsonElement> corpus)
    {
        var caps = Unique(Rows(manifest, "caps"), x => (Split: Text(x, "split"), Language: Text(x, "language")));
        var counts = Unique(Rows(manifest, "counts"), x => (Split: Text(x, "split"), Language: Text(x, "language"), Bucket: (int)Number(x, "bucketStart")));
        Require(caps.Count == languages.Length * Splits.Length && counts.Count == languages.Length * Splits.Length * Buckets.Length,
            "Incomplete cap or count coverage.");
        var originals = new Dictionary<(string Split, string Language), BigInteger>();
        foreach (string split in Splits)
            foreach (string language in languages)
            {
                Require(caps.TryGetValue((split, language), out var cap), "Missing cap row.");
                BigInteger totalOriginals = 0;
                foreach (int bucket in Buckets)
                {
                    Require(counts.TryGetValue((split, language, bucket), out var row), "Missing count row.");
                    BigInteger examples = (BigInteger)Number(row, "originals") + Number(row, "augmented");
                    Require(Number(row, "originalGroups") <= examples, "More groups than counted examples.");
                    Require(examples == 0 || Number(row, "originalGroups") > 0, "Counted examples have no original group.");
                    totalOriginals += Number(row, "originals");
                }
                Require(totalOriginals <= Number(cap, "maxOriginalRecords"), "Original count exceeds selected cap.");
                originals[(split, language)] = totalOriginals;
                foreach (int bucket in Buckets)
                    Require(Number(counts[(split, language, bucket)], "originalGroups") <= totalOriginals, "Groups lack an original in their split/language.");
            }
        ValidateAugmentation(manifest, originals, counts);
        foreach (var row in Unique(Rows(manifest, "exclusions"), x => (Text(x, "sourceId"), Text(x, "split"), Text(x, "language"), Text(x, "reason"))).Values)
            Require(corpus.ContainsKey(Text(row, "sourceId")), "Exclusion refers to unknown source.");
        var documentCounts = new Dictionary<string, BigInteger>(StringComparer.Ordinal);
        foreach (var row in Unique(Rows(manifest, "documentMetrics"), x => (Text(x, "sourceId"), Text(x, "goldLabel"), Text(x, "predictedLabel"))).Values)
        {
            string sourceId = Text(row, "sourceId");
            Require(corpus.TryGetValue(sourceId, out var source) && IsOwnedSource(source),
                "Document metric must refer to a separate owned source.");
            documentCounts[sourceId] = documentCounts.GetValueOrDefault(sourceId) + Number(row, "count");
            Require(documentCounts[sourceId] <= Number(source, "originalRecords"), "Document counts exceed their source originals.");
        }
        // Owned sources may contain both technical text and document examples.
        // Only document-mode records are excluded from text counts/support.
        BigInteger textOriginals = corpus.Aggregate(BigInteger.Zero, (sum, source) =>
            sum + Number(source.Value, "originalRecords") - documentCounts.GetValueOrDefault(source.Key));
        Require(originals.Values.Aggregate(BigInteger.Zero, (sum, value) => sum + value) <= textOriginals,
            "Selected text originals exceed corpus originals after excluding documents.");

        var support = Unique(Rows(manifest, "support"), x => (Split: Text(x, "split"), Language: Text(x, "language"), Bucket: (int)Number(x, "bucketStart")));
        Require(support.Count == languages.Length * EvaluationSplits.Length * (Buckets.Length - 1), "Incomplete support coverage.");
        foreach (string split in EvaluationSplits)
            foreach (string language in languages)
                foreach (int bucket in Buckets.Skip(1))
                {
                    Require(support.TryGetValue((split, language, bucket), out var row), "Missing support row.");
                    var count = counts[(split, language, bucket)];
                    Require(Number(row, "evaluated") == (BigInteger)Number(count, "originals") + Number(count, "augmented") &&
                        Number(row, "originalGroups") == Number(count, "originalGroups") && Number(row, "accepted") <= Number(row, "evaluated"),
                        "Support does not reconcile with counts.");
                    if (model.Thresholds.Single(t => t.Start == bucket).Enabled == 0)
                        Require(Number(row, "accepted") == 0, "Disabled bucket has accepted predictions.");
                }
        var metrics = ValidateMetrics(manifest, languages, negatives, counts, support);
        ValidateCalibration(manifest, model, languages, support, metrics);
    }

    private static void ValidateAugmentation(JsonElement manifest,
        Dictionary<(string Split, string Language), BigInteger> originals,
        Dictionary<(string Split, string Language, int Bucket), JsonElement> counts)
    {
        var rules = Unique(Rows(manifest, "augmentation"), x => Text(x, "algorithm"));
        Require(!rules.ContainsKey("none-v1") || rules.Count == 1, "none-v1 must stand alone.");
        BigInteger derived = 0;
        var maximumBySplit = Splits.ToDictionary(split => split, _ => BigInteger.Zero, StringComparer.Ordinal);
        foreach (var (algorithm, rule) in rules)
        {
            var splits = Strings(rule.GetProperty("splits"));
            Require(splits.Distinct(StringComparer.Ordinal).Count() == splits.Length, "Duplicate augmentation split.");
            var lengths = LanguageJson.Array(rule.GetProperty("lengths")).Select(x => LanguageJson.Int(x)).ToArray();
            bool hasLengths = algorithm is "scalar-prefix-v1" or "concat-v1";
            Require(hasLengths ? StrictlyAscending(lengths) : lengths.Length == 0,
                "Invalid augmentation lengths.");
            BigInteger input = originals.Where(x => splits.Contains(x.Key.Split, StringComparer.Ordinal))
                .Aggregate(BigInteger.Zero, (sum, item) => sum + item.Value);
            Require(Number(rule, "inputCount") == input, "Augmentation input count does not reconcile.");
            long output = Number(rule, "outputCount");
            // Prefixes and concat-v1 anchors emit at most one example per original and length.
            int outputsPerOriginal = hasLengths ? lengths.Length : algorithm == "strip-marks-v1" ? 1 : 0;
            BigInteger maximum = input * outputsPerOriginal;
            Require(output <= maximum, "Augmentation output count exceeds possible derived examples.");
            foreach (string split in splits) maximumBySplit[split] += outputsPerOriginal;
            derived += output;
        }
        Require(derived == counts.Values.Aggregate(BigInteger.Zero, (sum, row) => sum + Number(row, "augmented")),
            "Augmentation outputs do not reconcile with counts.");
        foreach (var (key, originalCount) in originals)
        {
            BigInteger augmented = counts.Where(row => row.Key.Split == key.Split && row.Key.Language == key.Language)
                .Aggregate(BigInteger.Zero, (sum, row) => sum + Number(row.Value, "augmented"));
            Require(augmented <= originalCount * maximumBySplit[key.Split],
                "Augmented counts exceed the rules active for their split and language.");
        }
    }

    private static Dictionary<(string Split, string Language, int Bucket, string Name), JsonElement> ValidateMetrics(
        JsonElement manifest, string[] languages, string[] negatives,
        Dictionary<(string Split, string Language, int Bucket), JsonElement> counts,
        Dictionary<(string Split, string Language, int Bucket), JsonElement> support)
    {
        var metrics = Unique(Rows(manifest, "metrics"), x => (Split: Text(x, "split"), Language: Text(x, "language"),
            Bucket: (int)Number(x, "bucketStart"), Name: Text(x, "name")));
        Require(metrics.Count == EvaluationSplits.Length * Buckets.Length * (languages.Length + 1) * MetricNames.Length, "Incomplete metric coverage.");
        foreach (var row in metrics.Values)
        {
            long numerator = Number(row, "numerator"), denominator = Number(row, "denominator");
            Require(numerator <= denominator, "Metric numerator exceeds denominator.");
            var rate = row.GetProperty("rateBp");
            Require(denominator == 0 ? rate.ValueKind == JsonValueKind.Null :
                rate.ValueKind == JsonValueKind.Number && rate.GetInt64() == (BigInteger)10000 * numerator / denominator,
                "Metric rate is not its exact floored ratio.");
        }
        foreach (string split in EvaluationSplits)
            foreach (int bucket in Buckets)
            {
                foreach (string language in languages)
                {
                    BigInteger evaluated = (BigInteger)Number(counts[(split, language, bucket)], "originals") + Number(counts[(split, language, bucket)], "augmented");
                    long accepted = bucket == 0 ? 0 : Number(support[(split, language, bucket)], "accepted");
                    bool negative = negatives.Contains(language, StringComparer.Ordinal), csSk = language is "cs" or "sk";
                    foreach (string name in MetricNames)
                    {
                        Require(metrics.TryGetValue((split, language, bucket, name), out var row), "Missing language metric.");
                        BigInteger expectedDenominator = name switch
                        {
                            "acceptanceCoverage" => evaluated,
                            "acceptedError" => accepted,
                            "csSkConfusion" => csSk ? accepted : 0,
                            "foreignAcceptance" => negative ? evaluated : 0,
                            _ => throw new InvalidDataException("Invalid metric name.")
                        };
                        Require(Number(row, "denominator") == expectedDenominator, "Metric denominator does not reconcile.");
                        if (name == "acceptanceCoverage" || name == "acceptedError" && negative || name == "foreignAcceptance" && negative)
                            Require(Number(row, "numerator") == accepted, "Metric numerator does not reconcile with accepted predictions.");
                        if (name == "foreignAcceptance" && !negative || name == "csSkConfusion" && !csSk)
                            Require(Number(row, "numerator") == 0, "Impossible metric numerator.");
                    }
                    Require(Number(metrics[(split, language, bucket, "csSkConfusion")], "numerator") <=
                        Number(metrics[(split, language, bucket, "acceptedError")], "numerator"), "Confusion exceeds accepted errors.");
                }
                foreach (string name in MetricNames)
                {
                    Require(metrics.TryGetValue((split, "all", bucket, name), out var aggregate), "Missing aggregate metric.");
                    foreach (string field in new[] { "numerator", "denominator" })
                        Require(Number(aggregate, field) == languages.Aggregate(BigInteger.Zero, (sum, language) =>
                            sum + Number(metrics[(split, language, bucket, name)], field)), "Aggregate metrics do not reconcile.");
                }
            }
        return metrics;
    }

    private static void ValidateCalibration(JsonElement manifest, LanguageModel model, string[] languages,
        Dictionary<(string Split, string Language, int Bucket), JsonElement> support,
        Dictionary<(string Split, string Language, int Bucket, string Name), JsonElement> metrics)
    {
        var calibration = manifest.GetProperty("calibration");
        var candidates = Rows(calibration, "candidates");
        var disabled = Unique(Rows(calibration, "disabledBuckets"), x => (int)Number(x, "bucketStart"));
        Require(new HashSet<int>(disabled.Keys).SetEquals(model.Thresholds.Where(t => t.Enabled == 0).Select(t => t.Start)),
            "Disabled bucket declarations do not match artifact.");
        foreach (var row in disabled.Values) Require(Text(row, "reason").Length > 0, "Missing disabled bucket reason.");
        for (int index = 0; index < candidates.Length; index++)
        {
            var candidate = candidates[index];
            var threshold = model.Thresholds[index];
            Require(Number(candidate, "bucketStart") == threshold.Start, "Unordered calibration bucket.");
            foreach (var (field, value) in new[] { ("minWinningScores", threshold.MinWinningScore), ("minMargins", threshold.MinMargin), ("minKnownCoverageBp", threshold.MinKnownCoverageBp) })
            {
                var grid = LanguageJson.Array(candidate.GetProperty(field)).Select(x => LanguageJson.Int(x)).ToArray();
                Require(StrictlyAscending(grid), "Unsorted or duplicate calibration candidates.");
                if (threshold.Enabled != 0) Require(grid.Contains(value), "Enabled threshold is outside its calibration grid.");
            }
            if (threshold.Enabled == 0) continue;
            foreach (string split in EvaluationSplits)
            {
                foreach (string language in languages)
                    Require(Number(support[(split, language, threshold.Start)], "originalGroups") >= 200, "Enabled bucket lacks independent groups.");
                Require(Number(metrics[(split, "all", threshold.Start, "acceptedError")], "denominator") >= 1000 &&
                    Number(support[(split, "cs", threshold.Start)], "accepted") >= 100 &&
                    Number(support[(split, "sk", threshold.Start)], "accepted") >= 100, "Enabled bucket lacks accepted support.");
                foreach (var (name, limit) in new[] { ("acceptedError", 200), ("csSkConfusion", 100), ("foreignAcceptance", 100) })
                {
                    var metric = metrics[(split, "all", threshold.Start, name)];
                    long denominator = Number(metric, "denominator");
                    Require(denominator > 0 && (BigInteger)10000 * Number(metric, "numerator") <= (BigInteger)limit * denominator,
                        "Enabled bucket fails release metric gate.");
                }
            }
        }
    }

    private static bool StrictlyAscending(long[] values)
    {
        for (int index = 1; index < values.Length; index++) if (values[index - 1] >= values[index]) return false;
        return true;
    }

    private static void ValidateSchema(JsonElement value, JsonElement schema, JsonElement root)
    {
        if (schema.TryGetProperty("$ref", out var reference))
        {
            ValidateSchema(value, root.GetProperty("$defs").GetProperty(reference.GetString()![8..]), root);
            return;
        }
        if (schema.TryGetProperty("anyOf", out var alternatives))
        {
            foreach (var choice in alternatives.EnumerateArray())
            {
                try { ValidateSchema(value, choice, root); return; }
                catch (InvalidDataException) { }
            }
            throw new InvalidDataException("Value matches no allowed schema.");
        }
        if (schema.TryGetProperty("const", out var constant)) Require(EqualJson(value, constant), "Changed schema constant.");
        if (schema.TryGetProperty("enum", out var choices)) Require(choices.EnumerateArray().Any(choice => EqualJson(value, choice)), "Invalid enum value.");
        if (schema.TryGetProperty("type", out var type))
            Require(type.GetString() switch
            {
                "object" => value.ValueKind == JsonValueKind.Object,
                "array" => value.ValueKind == JsonValueKind.Array,
                "string" => value.ValueKind == JsonValueKind.String,
                "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _),
                "null" => value.ValueKind == JsonValueKind.Null,
                _ => false
            }, "Wrong schema value kind.");
        if (value.ValueKind == JsonValueKind.Object)
        {
            if (schema.TryGetProperty("required", out var required))
                foreach (var key in required.EnumerateArray()) Require(value.TryGetProperty(key.GetString()!, out _), "Missing required manifest key.");
            if (schema.TryGetProperty("properties", out var properties))
                foreach (var property in value.EnumerateObject())
                {
                    Require(properties.TryGetProperty(property.Name, out var propertySchema), "Unknown manifest key.");
                    ValidateSchema(property.Value, propertySchema, root);
                }
        }
        else if (value.ValueKind == JsonValueKind.Array)
        {
            if (schema.TryGetProperty("minItems", out var min)) Require(value.GetArrayLength() >= min.GetInt32(), "Too few array items.");
            if (schema.TryGetProperty("maxItems", out var max)) Require(value.GetArrayLength() <= max.GetInt32(), "Too many array items.");
            if (schema.TryGetProperty("items", out var itemSchema)) foreach (var item in value.EnumerateArray()) ValidateSchema(item, itemSchema, root);
        }
        else if (value.ValueKind == JsonValueKind.String)
        {
            if (schema.TryGetProperty("pattern", out var pattern))
            {
                if (pattern.GetString() == "^https://") Require(value.GetString()!.StartsWith("https://", StringComparison.Ordinal), "Expected HTTPS URL.");
                else LanguageJson.Text(value, pattern.GetString());
            }
            if (schema.TryGetProperty("minLength", out var min)) Require(value.GetString()!.EnumerateRunes().Count() >= min.GetInt32(), "String too short.");
        }
        else if (value.ValueKind == JsonValueKind.Number)
        {
            if (schema.TryGetProperty("minimum", out var min)) Require(value.GetInt64() >= min.GetInt64(), "Number below minimum.");
            if (schema.TryGetProperty("maximum", out var max)) Require(value.GetInt64() <= max.GetInt64(), "Number above maximum.");
        }
    }

    private static bool EqualJson(JsonElement first, JsonElement second)
    {
        if (first.ValueKind != second.ValueKind) return false;
        return first.ValueKind switch
        {
            JsonValueKind.Array => first.GetArrayLength() == second.GetArrayLength() && first.EnumerateArray().Zip(second.EnumerateArray()).All(pair => EqualJson(pair.First, pair.Second)),
            JsonValueKind.Object => first.EnumerateObject().Count() == second.EnumerateObject().Count() && first.EnumerateObject().All(p => second.TryGetProperty(p.Name, out var v) && EqualJson(p.Value, v)),
            JsonValueKind.String => first.GetString() == second.GetString(),
            JsonValueKind.Number => first.GetInt64() == second.GetInt64(),
            _ => first.GetRawText() == second.GetRawText()
        };
    }

    // tools/lang/schemas/manifest-v1.schema.json, embedded to avoid a runtime schema dependency or extra resource.
    private const string Schema = """
        {"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"urn:ainotebook:lang-detector-manifest:1","type":"object","additionalProperties":false,"required":["contract","version","modelId","artifactPath","artifactSha256","createdAt","corpus","negativeLanguages","environment","split","caps","augmentation","counts","exclusions","minimumSupport","calibration","support","metrics","documentMetrics","attribution"],"properties":{"contract":{"const":"lang-detector-manifest"},"version":{"const":1},"modelId":{"type":"string","pattern":"^[A-Za-z0-9._-]+$"},"artifactPath":{"type":"string"},"artifactSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"createdAt":{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"},"corpus":{"type":"array","items":{"$ref":"#/$defs/corpus"},"minItems":1},"negativeLanguages":{"type":"array","items":{"type":"string","pattern":"^[a-z]{2,3}$"},"minItems":1},"snapshotSkew":{"type":"object","additionalProperties":false,"required":["missingFromBase","cc0DetailMismatch","excludedIdsSha256","sampleIds"],"properties":{"missingFromBase":{"type":"integer","minimum":0,"maximum":9007199254740991},"cc0DetailMismatch":{"type":"integer","minimum":0,"maximum":9007199254740991},"excludedIdsSha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"sampleIds":{"type":"array","items":{"type":"integer","minimum":0,"maximum":9223372036854775807},"maxItems":20}}},"environment":{"type":"object","additionalProperties":false,"required":["exporterGitCommit","commandArguments","pythonVersion","dependencies","normalizationTablesVersion","unicodeFiles"],"properties":{"exporterGitCommit":{"type":"string","pattern":"^[0-9a-f]{40,64}$"},"commandArguments":{"type":"array","items":{"type":"string"},"minItems":1},"pythonVersion":{"type":"string"},"dependencies":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","version"],"properties":{"name":{"type":"string"},"version":{"type":"string"}}},"minItems":0},"normalizationTablesVersion":{"const":"ucd-15.1.0-default-full-v1"},"unicodeFiles":{"type":"array","items":{"$ref":"#/$defs/file"},"minItems":4,"maxItems":4}}},"split":{"type":"object","additionalProperties":false,"required":["algorithm","seed","splitBp","maxComponentMembers","oversizedComponents"],"properties":{"algorithm":{"const":"translation-components-sha256-v1"},"seed":{"type":"integer","minimum":0,"maximum":9007199254740991},"splitBp":{"type":"object","additionalProperties":false,"required":["train","validation","test"],"properties":{"train":{"type":"integer","minimum":1,"maximum":9998},"validation":{"type":"integer","minimum":1,"maximum":9998},"test":{"type":"integer","minimum":1,"maximum":9998}}},"maxComponentMembers":{"type":"integer","minimum":1,"maximum":9007199254740991},"oversizedComponents":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["groupId","memberCount","blocks"],"properties":{"groupId":{"type":"string","pattern":"^[0-9a-f]{64}$"},"memberCount":{"type":"integer","minimum":1,"maximum":9007199254740991},"blocks":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["groupId","memberCount"],"properties":{"groupId":{"type":"string","pattern":"^[0-9a-f]{64}$"},"memberCount":{"type":"integer","minimum":1,"maximum":9007199254740991}}},"minItems":1}}},"minItems":0}}},"caps":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["split","language","maxOriginalRecords"],"properties":{"split":{"enum":["train","validation","test"]},"language":{"type":"string"},"maxOriginalRecords":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"minItems":1},"augmentation":{"type":"array","items":{"$ref":"#/$defs/augmentation"},"minItems":1},"counts":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["split","language","bucketStart","originals","augmented","originalGroups"],"properties":{"split":{"enum":["train","validation","test"]},"language":{"type":"string"},"bucketStart":{"enum":[0,12,32,80,200]},"originals":{"type":"integer","minimum":0,"maximum":9007199254740991},"augmented":{"type":"integer","minimum":0,"maximum":9007199254740991},"originalGroups":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"minItems":1},"exclusions":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["sourceId","split","language","reason","count"],"properties":{"sourceId":{"type":"string"},"split":{"enum":["train","validation","test"]},"language":{"type":"string"},"reason":{"type":"string"},"count":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"minItems":0},"minimumSupport":{"type":"object","additionalProperties":false,"required":["groupsPerTarget","groupsPerNegativeLanguage","acceptedTotal","acceptedTrueCs","acceptedTrueSk"],"properties":{"groupsPerTarget":{"const":200},"groupsPerNegativeLanguage":{"const":200},"acceptedTotal":{"const":1000},"acceptedTrueCs":{"const":100},"acceptedTrueSk":{"const":100}}},"calibration":{"type":"object","additionalProperties":false,"required":["algorithm","candidates","tieBreak","disabledBuckets"],"properties":{"algorithm":{"const":"grid-max-accepted-v1"},"candidates":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["bucketStart","minWinningScores","minMargins","minKnownCoverageBp"],"properties":{"bucketStart":{"enum":[12,32,80,200]},"minWinningScores":{"type":"array","items":{"type":"integer","minimum":-7000000,"maximum":0},"minItems":1},"minMargins":{"type":"array","items":{"type":"integer","minimum":1,"maximum":7000000},"minItems":1},"minKnownCoverageBp":{"type":"array","items":{"type":"integer","minimum":0,"maximum":10000},"minItems":1}}},"minItems":4,"maxItems":4},"tieBreak":{"const":["minWinningScoreDescending","minMarginDescending","minKnownCoverageBpDescending"]},"disabledBuckets":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["bucketStart","reason"],"properties":{"bucketStart":{"enum":[12,32,80,200]},"reason":{"type":"string"}}},"minItems":0}}},"support":{"type":"array","items":{"$ref":"#/$defs/support"},"minItems":1},"metrics":{"type":"array","items":{"$ref":"#/$defs/metric"},"minItems":1},"documentMetrics":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["sourceId","goldLabel","predictedLabel","count"],"properties":{"sourceId":{"type":"string"},"goldLabel":{"enum":["cs","de","en","sk","mixed","und"]},"predictedLabel":{"enum":["cs","de","en","sk","mixed","und"]},"count":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"minItems":0},"attribution":{"type":"object","additionalProperties":false,"required":["sourceIds","licenseIds","attributionPath","attributionSha256","noticePath","noticeSha256"],"properties":{"sourceIds":{"type":"array","items":{"type":"string","pattern":"^[A-Za-z0-9_-]+$"},"minItems":0},"licenseIds":{"type":"array","items":{"type":"string"},"minItems":0},"attributionPath":{"type":"string"},"attributionSha256":{"type":"string","pattern":"^([0-9a-f]{64})?$"},"noticePath":{"type":"string"},"noticeSha256":{"type":"string","pattern":"^([0-9a-f]{64})?$"}}}},"$defs":{"file":{"type":"object","additionalProperties":false,"required":["role","url","snapshotDate","sha256","formatVersion","records"],"properties":{"role":{"enum":["sentences","links","attribution","ownedExamples","unicodeData","normalizationTest"]},"url":{"type":"string","pattern":"^https://"},"snapshotDate":{"type":"string","pattern":"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},"sha256":{"type":"string","pattern":"^[0-9a-f]{64}$"},"formatVersion":{"type":"string"},"records":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"corpus":{"type":"object","additionalProperties":false,"required":["id","files","licenseIds","licenseSelectionPolicy","languageSelectionPolicy","deduplicationPolicy","translationGroupPolicy","originalRecords","languageMappings"],"properties":{"id":{"type":"string","pattern":"^[A-Za-z0-9_-]+$"},"files":{"type":"array","items":{"$ref":"#/$defs/file"},"minItems":1},"licenseIds":{"type":"array","items":{"type":"string"},"minItems":1},"licenseSelectionPolicy":{"type":"string"},"languageSelectionPolicy":{"type":"string"},"deduplicationPolicy":{"type":"string"},"translationGroupPolicy":{"type":"string"},"originalRecords":{"type":"integer","minimum":0,"maximum":9007199254740991},"languageMappings":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,"required":["sourceLanguage","detectorLanguage"],"properties":{"sourceLanguage":{"type":"string","minLength":1},"detectorLanguage":{"type":"string","pattern":"^[a-z]{2,3}$"}}}}}},"augmentation":{"type":"object","additionalProperties":false,"required":["algorithm","splits","lengths","inputCount","outputCount"],"properties":{"algorithm":{"enum":["none-v1","scalar-prefix-v1","strip-marks-v1","concat-v1"]},"splits":{"type":"array","items":{"enum":["train","validation","test"]},"minItems":1,"maxItems":3},"lengths":{"type":"array","items":{"type":"integer","minimum":1,"maximum":5000000},"minItems":0},"inputCount":{"type":"integer","minimum":0,"maximum":9007199254740991},"outputCount":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"support":{"type":"object","additionalProperties":false,"required":["split","bucketStart","language","originalGroups","evaluated","accepted"],"properties":{"split":{"enum":["validation","test"]},"bucketStart":{"enum":[12,32,80,200]},"language":{"type":"string"},"originalGroups":{"type":"integer","minimum":0,"maximum":9007199254740991},"evaluated":{"type":"integer","minimum":0,"maximum":9007199254740991},"accepted":{"type":"integer","minimum":0,"maximum":9007199254740991}}},"metric":{"type":"object","additionalProperties":false,"required":["split","bucketStart","language","name","numerator","denominator","rateBp"],"properties":{"split":{"enum":["validation","test"]},"bucketStart":{"enum":[0,12,32,80,200]},"language":{"type":"string"},"name":{"enum":["acceptedError","csSkConfusion","foreignAcceptance","acceptanceCoverage"]},"numerator":{"type":"integer","minimum":0,"maximum":9007199254740991},"denominator":{"type":"integer","minimum":0,"maximum":9007199254740991},"rateBp":{"anyOf":[{"type":"integer","minimum":0,"maximum":10000},{"type":"null"}]}}}}}
        """;
}
