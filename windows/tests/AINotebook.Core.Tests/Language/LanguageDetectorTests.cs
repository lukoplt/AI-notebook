using System.Security.Cryptography;
using System.Numerics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class LanguageDetectorTests
{
    private const string ManifestName = "lang-detector-v1.manifest.json";
    private const string ArtifactName = "lang-detector-v1.json";

    private static Dictionary<string, byte[]> Bundle()
    {
        var envelope = SharedFixtures.Json("lang/loading-bundle-v1.json");
        Assert.Equal("lang-loading-bundle", envelope.GetProperty("contract").GetString());
        Assert.Equal(1, envelope.GetProperty("testOnly").GetInt32());
        var result = envelope.GetProperty("resources").EnumerateObject().ToDictionary(
            property => property.Name, property => Convert.FromBase64String(property.Value.GetString()!), StringComparer.Ordinal);
        foreach (var name in envelope.GetProperty("sharedUnicodeResources").EnumerateArray())
            result.Add(name.GetString()!, LanguageDetector.ReadBundledResource(name.GetString()!));
        using var model = JsonDocument.Parse(result[ArtifactName]);
        Assert.Equal("wp4-loader-test-only", model.RootElement.GetProperty("modelId").GetString());
        return result;
    }

    private static LanguageDetector Load(Dictionary<string, byte[]> resources) =>
        LanguageDetector.Load(name => resources.TryGetValue(name, out var bytes) ? bytes : throw new FileNotFoundException(name));

    private static byte[] JsonBytes(JsonNode node) => Encoding.UTF8.GetBytes(node.ToJsonString() + "\n");

    private static void SetPointer(JsonNode root, string pointer, JsonNode? value)
    {
        var pieces = pointer.Split('/').Skip(1).Select(x => x.Replace("~1", "/").Replace("~0", "~")).ToArray();
        JsonNode parent = root;
        foreach (var piece in pieces.SkipLast(1))
            parent = parent is JsonArray array ? array[int.Parse(piece)]! : parent[piece]!;
        if (parent is JsonArray list) list[int.Parse(pieces[^1])] = value;
        else parent[pieces[^1]] = value;
    }

    private static JsonNode Row(JsonNode manifest, string section, string split, string language, int? bucket = null) =>
        manifest[section]!.AsArray().Single(row => row!["split"]!.GetValue<string>() == split &&
            row["language"]!.GetValue<string>() == language && (bucket is null || row["bucketStart"]!.GetValue<int>() == bucket))!;

    private static void ReconcileEvaluation(JsonNode manifest)
    {
        foreach (var support in manifest["support"]!.AsArray())
        {
            var count = Row(manifest, "counts", support!["split"]!.GetValue<string>(), support["language"]!.GetValue<string>(), support["bucketStart"]!.GetValue<int>());
            support["evaluated"] = count["originals"]!.GetValue<long>() + count["augmented"]!.GetValue<long>();
            support["originalGroups"] = count["originalGroups"]!.GetValue<long>();
        }
        var negatives = manifest["negativeLanguages"]!.AsArray().Select(x => x!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
        foreach (var metric in manifest["metrics"]!.AsArray().Where(row => row!["language"]!.GetValue<string>() != "all"))
        {
            string split = metric!["split"]!.GetValue<string>(), language = metric["language"]!.GetValue<string>(), name = metric["name"]!.GetValue<string>();
            int bucket = metric["bucketStart"]!.GetValue<int>();
            var count = Row(manifest, "counts", split, language, bucket);
            long evaluated = count["originals"]!.GetValue<long>() + count["augmented"]!.GetValue<long>();
            long accepted = bucket == 0 ? 0 : Row(manifest, "support", split, language, bucket)["accepted"]!.GetValue<long>();
            bool negative = negatives.Contains(language);
            long denominator = name switch
            {
                "acceptanceCoverage" => evaluated, "acceptedError" => accepted,
                "csSkConfusion" => language is "cs" or "sk" ? accepted : 0,
                "foreignAcceptance" => negative ? evaluated : 0, _ => throw new InvalidOperationException()
            };
            long numerator = name == "acceptanceCoverage" || negative && name is "acceptedError" or "foreignAcceptance" ? accepted : 0;
            metric["numerator"] = numerator;
            metric["denominator"] = denominator;
            metric["rateBp"] = denominator == 0 ? null : JsonValue.Create((long)((BigInteger)10000 * numerator / denominator));
        }
        foreach (var aggregate in manifest["metrics"]!.AsArray().Where(row => row!["language"]!.GetValue<string>() == "all"))
        {
            var matching = manifest["metrics"]!.AsArray().Where(row => row!["language"]!.GetValue<string>() != "all" &&
                row["split"]!.GetValue<string>() == aggregate!["split"]!.GetValue<string>() && row["bucketStart"]!.GetValue<int>() == aggregate["bucketStart"]!.GetValue<int>() &&
                row["name"]!.GetValue<string>() == aggregate["name"]!.GetValue<string>()).ToArray();
            long numerator = matching.Sum(row => row!["numerator"]!.GetValue<long>()), denominator = matching.Sum(row => row!["denominator"]!.GetValue<long>());
            aggregate!["numerator"] = numerator;
            aggregate["denominator"] = denominator;
            aggregate["rateBp"] = denominator == 0 ? null : JsonValue.Create((long)((BigInteger)10000 * numerator / denominator));
        }
    }

    private static Dictionary<string, byte[]> NonzeroBundle(bool augmented = true)
    {
        var resources = Bundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest["corpus"]![0]!["originalRecords"] = 1L;
        manifest["corpus"]![0]!["files"]![0]!["records"] = 1L;
        Row(manifest, "caps", "validation", "cs")["maxOriginalRecords"] = 1L;
        var original = Row(manifest, "counts", "validation", "cs", 200);
        original["originals"] = 1L;
        original["originalGroups"] = 1L;
        if (augmented)
        {
            var prefix = Row(manifest, "counts", "validation", "cs", 12);
            prefix["augmented"] = 1L;
            prefix["originalGroups"] = 1L;
        }
        manifest["augmentation"] = JsonSerializer.SerializeToNode(new[] { new
        {
            algorithm = augmented ? "scalar-prefix-v1" : "none-v1", splits = new[] { "validation" },
            lengths = augmented ? new[] { 12 } : Array.Empty<int>(), inputCount = 1L, outputCount = augmented ? 1L : 0L
        } });
        ReconcileEvaluation(manifest);
        resources[ManifestName] = JsonBytes(manifest);
        return resources;
    }

    private static void AddOwnedDocument(Dictionary<string, byte[]> resources, JsonNode manifest, long originals = 1)
    {
        manifest["corpus"]!.AsArray().Add(JsonSerializer.SerializeToNode(new
        {
            id = "wp4-owned-test",
            files = new[] { new { role = "ownedExamples", url = "https://example.invalid/wp4-owned-test", snapshotDate = "2026-10-09",
                sha256 = new string('0', 64), formatVersion = "wp4-test-only", records = originals } },
            licenseIds = new[] { "LicenseRef-WP4-Test-Only" }, licenseSelectionPolicy = "Invented test data", languageSelectionPolicy = "Owned gold labels",
            deduplicationPolicy = "No duplicates", translationGroupPolicy = "Held-out owned source", originalRecords = originals,
            languageMappings = new[] { new { sourceLanguage = "cs", detectorLanguage = "cs" }, new { sourceLanguage = "und", detectorLanguage = "und" },
                new { sourceLanguage = "mul", detectorLanguage = "mul" } }
        }));
        manifest["documentMetrics"]!.AsArray().Add(JsonSerializer.SerializeToNode(new
        { sourceId = "wp4-owned-test", goldLabel = "mixed", predictedLabel = "und", count = 1L }));
        manifest["attribution"]!["sourceIds"]!.AsArray().Add("wp4-owned-test");
        var model = JsonNode.Parse(resources[ArtifactName])!;
        model["attribution"]!["sourceIds"]!.AsArray().Add("wp4-owned-test");
        resources[ArtifactName] = JsonBytes(model);
        manifest["artifactSha256"] = Convert.ToHexStringLower(SHA256.HashData(resources[ArtifactName]));
    }

    private static Dictionary<string, byte[]> EnabledBucketBundle(long acceptedPerTarget = 250, long negativeOriginals = 200)
    {
        var resources = Bundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        var model = JsonNode.Parse(resources[ArtifactName])!;
        var targets = model["targets"]!.AsArray().Select(x => x!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
        long originals = 0;
        foreach (var support in manifest["support"]!.AsArray().Where(x => x!["bucketStart"]!.GetValue<int>() == 12))
        {
            string split = support!["split"]!.GetValue<string>(), language = support["language"]!.GetValue<string>();
            long count = targets.Contains(language) ? acceptedPerTarget : negativeOriginals;
            Row(manifest, "caps", split, language)["maxOriginalRecords"] = count;
            var row = Row(manifest, "counts", split, language, 12);
            row["originals"] = count;
            row["originalGroups"] = 200L;
            support["accepted"] = targets.Contains(language) ? count : 0L;
            originals += count;
        }
        manifest["corpus"]![0]!["originalRecords"] = originals;
        manifest["corpus"]![0]!["files"]![0]!["records"] = originals;
        manifest["augmentation"]![0]!["inputCount"] = originals;
        manifest["calibration"]!["disabledBuckets"]!.AsArray().RemoveAt(0);
        model["thresholds"]![0]!["enabled"] = 1;
        resources[ArtifactName] = JsonBytes(model);
        manifest["artifactSha256"] = Convert.ToHexStringLower(SHA256.HashData(resources[ArtifactName]));
        ReconcileEvaluation(manifest);
        resources[ManifestName] = JsonBytes(manifest);
        return resources;
    }

    private static void SetMetricNumerator(JsonNode manifest, string split, string language, string name, long numerator)
    {
        var rows = manifest["metrics"]!.AsArray().Where(x => x!["split"]!.GetValue<string>() == split &&
            x["bucketStart"]!.GetValue<int>() == 12 && x["name"]!.GetValue<string>() == name).ToArray();
        var row = rows.Single(x => x!["language"]!.GetValue<string>() == language)!;
        row["numerator"] = numerator;
        var aggregate = rows.Single(x => x!["language"]!.GetValue<string>() == "all")!;
        aggregate["numerator"] = rows.Where(x => x!["language"]!.GetValue<string>() != "all").Sum(x => x!["numerator"]!.GetValue<long>());
        foreach (var changed in new[] { row, aggregate })
        {
            long denominator = changed["denominator"]!.GetValue<long>();
            changed["rateBp"] = denominator == 0 ? null : JsonValue.Create((long)((BigInteger)10000 * changed["numerator"]!.GetValue<long>() / denominator));
        }
    }

    [Fact]
    public void EnabledBucketAtSupportMinimaIsAvailable() => Assert.True(Load(EnabledBucketBundle()).IsAvailable);

    [Theory]
    [InlineData("validation", "cs", "groups")]
    [InlineData("test", "cs", "groups")]
    [InlineData("validation", "fr", "groups")]
    [InlineData("test", "fr", "groups")]
    [InlineData("validation", "cs", "acceptedTrue")]
    [InlineData("test", "cs", "acceptedTrue")]
    [InlineData("validation", "sk", "acceptedTrue")]
    [InlineData("test", "sk", "acceptedTrue")]
    [InlineData("validation", "de", "acceptedTotal")]
    [InlineData("test", "de", "acceptedTotal")]
    public void EnabledBucketRejectsInsufficientSupport(string split, string language, string field)
    {
        var resources = EnabledBucketBundle(field == "acceptedTrue" ? 500 : 250);
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        if (field == "groups") Row(manifest, "counts", split, language, 12)["originalGroups"] = 199L;
        else Row(manifest, "support", split, language, 12)["accepted"] = field == "acceptedTrue" ? 99L : 249L;
        ReconcileEvaluation(manifest);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Theory]
    [InlineData("validation", "acceptedError")]
    [InlineData("test", "acceptedError")]
    [InlineData("validation", "csSkConfusion")]
    [InlineData("test", "csSkConfusion")]
    [InlineData("validation", "foreignAcceptance")]
    [InlineData("test", "foreignAcceptance")]
    public void EnabledBucketAcceptsExactMetricGateEquality(string split, string metric)
    {
        var resources = EnabledBucketBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        if (metric == "foreignAcceptance")
        {
            Row(manifest, "support", split, "fr", 12)["accepted"] = 12L;
            ReconcileEvaluation(manifest);
        }
        else
        {
            string language = metric == "csSkConfusion" ? "cs" : "de";
            long numerator = metric == "csSkConfusion" ? 5 : 20;
            SetMetricNumerator(manifest, split, language, "acceptedError", numerator);
            if (metric == "csSkConfusion") SetMetricNumerator(manifest, split, language, metric, numerator);
        }
        resources[ManifestName] = JsonBytes(manifest);
        Assert.True(Load(resources).IsAvailable);
    }

    [Theory]
    [InlineData("validation", "acceptedError")]
    [InlineData("test", "acceptedError")]
    [InlineData("validation", "csSkConfusion")]
    [InlineData("test", "csSkConfusion")]
    [InlineData("validation", "foreignAcceptance")]
    [InlineData("test", "foreignAcceptance")]
    public void EnabledBucketRejectsGateViolationsHiddenByFlooredRates(string split, string metric)
    {
        var resources = EnabledBucketBundle(metric == "acceptedError" ? 2501 : 5001, metric == "foreignAcceptance" ? 1667 : 200);
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        if (metric == "foreignAcceptance")
        {
            Row(manifest, "support", split, "fr", 12)["accepted"] = 101L;
            ReconcileEvaluation(manifest);
        }
        else
        {
            string language = metric == "csSkConfusion" ? "cs" : "de";
            long numerator = metric == "csSkConfusion" ? 101 : 201;
            SetMetricNumerator(manifest, split, language, "acceptedError", numerator);
            if (metric == "csSkConfusion") SetMetricNumerator(manifest, split, language, metric, numerator);
        }
        var gate = manifest["metrics"]!.AsArray().Single(x => x!["split"]!.GetValue<string>() == split &&
            x["bucketStart"]!.GetValue<int>() == 12 && x["language"]!.GetValue<string>() == "all" && x["name"]!.GetValue<string>() == metric)!;
        Assert.Equal(metric == "acceptedError" ? 200L : 100L, gate["rateBp"]!.GetValue<long>());
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void EnabledThresholdMustBelongToRecordedCalibrationGrid()
    {
        var resources = EnabledBucketBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        var model = JsonNode.Parse(resources[ArtifactName])!;
        model["thresholds"]![0]!["minMargin"] = 2;
        resources[ArtifactName] = JsonBytes(model);
        manifest["artifactSha256"] = Convert.ToHexStringLower(SHA256.HashData(resources[ArtifactName]));
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void NonzeroAugmentationOnlyBucketAndOwnedDocumentProvenanceAreAvailable()
    {
        var resources = NonzeroBundle();
        Assert.True(Load(resources).IsAvailable);
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        AddOwnedDocument(resources, manifest);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.True(Load(resources).IsAvailable);
    }

    [Fact]
    public void EmptyScalarPrefixConfigurationWithZeroDerivedOutputIsAvailable()
    {
        var resources = NonzeroBundle(false);
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest["augmentation"]![0]!["algorithm"] = "scalar-prefix-v1";
        resources[ManifestName] = JsonBytes(manifest);
        Assert.True(Load(resources).IsAvailable);
    }

    [Fact]
    public void CountedExamplesCannotHaveZeroOriginalGroups()
    {
        var resources = NonzeroBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        Row(manifest, "counts", "validation", "cs", 200)["originalGroups"] = 0L;
        ReconcileEvaluation(manifest);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void AugmentationCannotBeReportedInAnInactiveSplit()
    {
        var resources = NonzeroBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest["corpus"]![0]!["originalRecords"] = 2L;
        manifest["corpus"]![0]!["files"]![0]!["records"] = 2L;
        Row(manifest, "caps", "train", "cs")["maxOriginalRecords"] = 1L;
        Row(manifest, "counts", "train", "cs", 200)["originals"] = 1L;
        Row(manifest, "counts", "train", "cs", 200)["originalGroups"] = 1L;
        manifest["augmentation"]![0]!["splits"] = new JsonArray("train");
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void OwnedDocumentRecordsCannotFundTextCounts()
    {
        var resources = NonzeroBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest["corpus"]![0]!["originalRecords"] = 0L;
        manifest["corpus"]![0]!["files"]![0]!["records"] = 0L;
        AddOwnedDocument(resources, manifest);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    public void OwnedSourceCanSupplySeparateTechnicalTextAndDocumentRecords(int documentCount)
    {
        var resources = NonzeroBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest["corpus"]![0]!["originalRecords"] = 0L;
        manifest["corpus"]![0]!["files"]![0]!["records"] = 0L;
        AddOwnedDocument(resources, manifest, documentCount + 1);
        manifest["documentMetrics"]![0]!["count"] = documentCount;
        resources[ManifestName] = JsonBytes(manifest);
        Assert.True(Load(resources).IsAvailable);
    }

    [Fact]
    public void DocumentCountsCannotExceedTheirOwnedSourceRecords()
    {
        var resources = NonzeroBundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        AddOwnedDocument(resources, manifest, 0);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void EverySharedLoadingCase()
    {
        var original = Bundle();
        var cases = SharedFixtures.Json("contracts/lang-loading-v1.json").GetProperty("cases");
        Assert.Equal(77, cases.GetArrayLength());
        foreach (var item in cases.EnumerateArray())
        {
            var resources = original.ToDictionary(pair => pair.Key, pair => pair.Value.ToArray(), StringComparer.Ordinal);
            var input = item.GetProperty("input");
            string operation = item.GetProperty("operation").GetString()!;
            string resource = input.TryGetProperty("resource", out var resourceName) ? resourceName.GetString()! : "";
            switch (operation)
            {
                case "unchanged": break;
                case "removeResource": resources.Remove(resource); break;
                case "flipByte": resources[resource][input.GetProperty("byteIndex").GetInt32()] ^= 1; break;
                case "setManifestValue":
                case "addUnknownManifestKey":
                    var manifest = JsonNode.Parse(resources[resource])!;
                    SetPointer(manifest, input.GetProperty("pointer").GetString()!, JsonNode.Parse(input.GetProperty("value").GetRawText()));
                    resources[resource] = JsonBytes(manifest);
                    break;
                case "duplicateManifestKey":
                    string text = Encoding.UTF8.GetString(resources[resource]);
                    resources[resource] = Encoding.UTF8.GetBytes("{\"version\":1," + text[1..]);
                    break;
                case "replaceArtifactWithSynthetic":
                    resources[resource] = Encoding.UTF8.GetBytes(SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("model").GetRawText() + "\n");
                    var matchingDigest = JsonNode.Parse(resources[ManifestName])!;
                    matchingDigest["artifactSha256"] = Convert.ToHexStringLower(SHA256.HashData(resources[resource]));
                    resources[ManifestName] = JsonBytes(matchingDigest);
                    break;
                case "setResourceValues":
                    foreach (var change in input.GetProperty("changes").EnumerateArray())
                    {
                        string changedResource = change.GetProperty("resource").GetString()!;
                        var document = JsonNode.Parse(resources[changedResource])!;
                        SetPointer(document, change.GetProperty("pointer").GetString()!, JsonNode.Parse(change.GetProperty("value").GetRawText()));
                        resources[changedResource] = JsonBytes(document);
                    }
                    if (input.GetProperty("refreshArtifactDigest").GetBoolean())
                    {
                        var updatedManifest = JsonNode.Parse(resources[ManifestName])!;
                        updatedManifest["artifactSha256"] = Convert.ToHexStringLower(SHA256.HashData(resources[ArtifactName]));
                        resources[ManifestName] = JsonBytes(updatedManifest);
                    }
                    break;
                default: Assert.Fail("Unknown fixture operation: " + operation); break;
            }
            Assert.True(item.GetProperty("expected").GetProperty("isAvailable").GetBoolean() == Load(resources).IsAvailable,
                item.GetProperty("name").GetString());
        }
    }

    [Fact]
    public void ProductionShapedTestBundleCanLoadWithDisabledBuckets()
    {
        var detector = Load(Bundle());
        Assert.True(detector.IsAvailable);
        var result = detector.DetectText("This is a sufficiently long sentence.");
        Assert.NotNull(result);
        Assert.Equal("und", result.Label);
        Assert.Equal("bucketDisabled", result.Reason);
        Assert.NotNull(detector.DetectDocument("This is a sufficiently long sentence."));
    }

    [Fact]
    public void UnavailablePreservesNullForBothInputRepresentations()
    {
        foreach (var detector in new[] { LanguageDetector.Unavailable, LanguageDetector.Load(_ => throw new FileNotFoundException()) })
        {
            Assert.False(detector.IsAvailable);
            Assert.Null(detector.DetectText("Toto je dostatečně dlouhý český text."));
            Assert.Null(detector.DetectText(new ushort[] { 65, 0xD800 }));
            Assert.Null(detector.DetectDocument("This is a complete document."));
            Assert.Null(detector.DetectDocument(new ushort[] { 65, 0xD800 }));
        }
        Assert.Equal(new ChunkLanguage(null, false), ChunkLanguage.Resolve(null, null, "cs"));
    }

    [Fact]
    public void EveryInheritanceCase()
    {
        foreach (var item in SharedFixtures.Json("contracts/lang-inheritance-v1.json").GetProperty("cases").EnumerateArray())
        {
            var input = item.GetProperty("input");
            LanguageFixtureAssert.Equal(item.GetProperty("expected"), ChunkLanguage.Resolve(
                input.GetProperty("label").GetString(), input.GetProperty("reason").GetString(), input.GetProperty("documentLabel").GetString()),
                item.GetProperty("name").GetString()!);
        }
    }

    [Theory]
    [InlineData("/environment/unexpected", "0")]
    [InlineData("/corpus/0/files/0/snapshotDate", "\"2026-02-30\"")]
    [InlineData("/corpus/0/files/0/records", "true")]
    [InlineData("/corpus/0/languageMappings/1/sourceLanguage", "\"ces\"")]
    [InlineData("/corpus/0/languageMappings/0/detectorLanguage", "\"zz\"")]
    [InlineData("/negativeLanguages/1", "\"fr\"")]
    [InlineData("/negativeLanguages/0", "\"cs\"")]
    [InlineData("/split/splitBp/train", "7999")]
    [InlineData("/caps/1/language", "\"cs\"")]
    [InlineData("/counts/0/originals", "1")]
    [InlineData("/support/0/evaluated", "1")]
    [InlineData("/support/0/accepted", "1")]
    [InlineData("/metrics/0/numerator", "1")]
    [InlineData("/metrics/0/rateBp", "0")]
    [InlineData("/metrics/1/name", "\"acceptedError\"")]
    [InlineData("/calibration/candidates/0/minMargins", "[2,1]")]
    [InlineData("/calibration/candidates/0/minWinningScores", "[-120000,-120000]")]
    [InlineData("/calibration/disabledBuckets", "[]")]
    [InlineData("/augmentation/0/lengths", "[1]")]
    [InlineData("/augmentation/0/splits", "[\"train\",\"train\"]")]
    [InlineData("/attribution/sourceIds", "[\"unlisted\"]")]
    [InlineData("/environment/unicodeFiles/1/url", "\"https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt\"")]
    public void ManifestSchemaAndReconciliationFailuresAreUnavailable(string pointer, string jsonValue)
    {
        var resources = Bundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        SetPointer(manifest, pointer, JsonNode.Parse(jsonValue));
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Theory]
    [InlineData("caps")]
    [InlineData("counts")]
    [InlineData("support")]
    [InlineData("metrics")]
    public void MissingCoverageRowsAreUnavailable(string section)
    {
        var resources = Bundle();
        var manifest = JsonNode.Parse(resources[ManifestName])!;
        manifest[section]!.AsArray().RemoveAt(0);
        resources[ManifestName] = JsonBytes(manifest);
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void UnicodeProvenanceAndLicenseAreVerified()
    {
        var resources = Bundle();
        resources["UNICODE-LICENSE.txt"][0] ^= 1;
        Assert.False(Load(resources).IsAvailable);
        resources = Bundle();
        var source = JsonNode.Parse(resources["unicode-sources-v1.json"])!;
        source["tableSha256"] = new string('0', 64);
        resources["unicode-sources-v1.json"] = JsonBytes(source);
        Assert.False(Load(resources).IsAvailable);
    }

    [Theory]
    [InlineData("\"\\ud800\"")]
    [InlineData("1e0")]
    [InlineData("1.0")]
    [InlineData("9223372036854775808")]
    public void InvalidManifestTokensAreUnavailable(string token)
    {
        var resources = Bundle();
        string valid = JsonNode.Parse(resources[ManifestName])!.ToJsonString();
        string changed = valid.Replace("\"version\":1,", "\"version\":" + token + ",", StringComparison.Ordinal);
        Assert.NotEqual(valid, changed);
        resources[ManifestName] = Encoding.UTF8.GetBytes(changed + "\n");
        Assert.False(Load(resources).IsAvailable);
    }

    [Fact]
    public void ResourceAccessorRejectsArbitraryNames()
    {
        Assert.Throws<InvalidDataException>(() => LanguageDetector.ReadBundledResource("../unicode-15.1.0.json"));
        Assert.Throws<InvalidDataException>(() => LanguageDetector.ReadBundledResource("AINotebook.Core.Language.unicode-15.1.0.json"));
    }

    [Fact]
    public async Task ParallelCallsReturnIndependentSnapshots()
    {
        byte[] bytes = Encoding.UTF8.GetBytes(SharedFixtures.Json("contracts/lang-score-v1.json").GetProperty("model").GetRawText() + "\n");
        var detector = LanguageDetector.CreateForTests(bytes, UnicodeTables.LoadBundled());
        const string input = "aaaa aaaa aaaa";
        var text = JsonSerializer.SerializeToElement(detector.DetectText(input), LanguageFixtureAssert.Json);
        var document = JsonSerializer.SerializeToElement(detector.DetectDocument(input), LanguageFixtureAssert.Json);
        var results = await Task.WhenAll(Enumerable.Range(0, 16).Select(_ => Task.Run(() =>
            (Text: detector.DetectText(input)!, Document: detector.DetectDocument(input)!))));
        results[0].Text.WordScalars[0][0] = 0;
        results[0].Text.Profiles["xa"].WeightedSums[0] = 0;
        results[0].Document.Windows[0].Expected.WordScalars[0][0] = 0;
        foreach (var result in results.Skip(1))
        {
            LanguageFixtureAssert.Equal(text, result.Text, "parallel text");
            LanguageFixtureAssert.Equal(document, result.Document, "parallel document");
        }
        LanguageFixtureAssert.Equal(text, detector.DetectText(input), "later text");
        LanguageFixtureAssert.Equal(document, detector.DetectDocument(input), "later document");
        var units = input.Select(c => (ushort)c).ToArray();
        LanguageFixtureAssert.Equal(text, detector.DetectText(units), "UTF16 text");
        LanguageFixtureAssert.Equal(document, detector.DetectDocument(units), "UTF16 document");
    }

    [Fact]
    public void BundledAvailabilityReflectsActualResourcesWithoutThrowing()
    {
        var detector = LanguageDetector.LoadBundled();
        Assert.Same(detector, LanguageDetector.LoadBundled());
        Assert.Equal(detector.IsAvailable, detector.DetectText("This is a sufficiently long sentence.") is not null);
    }
}
