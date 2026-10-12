using System.Text;
using System.Text.Json;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Shared ingestion-mail-v1 and ingestion-formats-v1 fixtures (same cases as macOS
/// MailContractTests). Every expected text is compared as UTF-8 bytes.</summary>
public sealed class MailContractTests
{
    private static JsonElement[] Cases(string file) =>
        SharedFixtures.Json("contracts/" + file).GetProperty("cases").EnumerateArray().ToArray();

    private static byte[] Utf8(string? text) => Encoding.UTF8.GetBytes(text ?? "");

    private static Task<CanonicalDocument> Extract(string asset, string fallback, JsonElement? limits)
    {
        var path = SharedFixtures.Path(asset);
        var kind = SourceTypeExtensions.Detect(Path.GetFileName(path)) ?? throw new InvalidOperationException(asset);
        var parsed = limits is { } value ? IngestionLimits.FromJson(value.GetRawText()) : IngestionLimits.Defaults;
        var rules = new FolderRules(FolderRules.Defaults.IncludeExts, Array.Empty<string>(), parsed, fallback);
        return new BoundedDocumentExtractor().ExtractAsync(new Uri(path), kind, rules);
    }

    [Fact]
    public async Task AllMailCases()
    {
        var all = Cases("ingestion-mail-v1.json");
        Assert.Equal(all.Length, all.Select(row => row.GetProperty("name").GetString()).Distinct().Count());
        var operations = new Dictionary<string, int>();
        foreach (var row in all)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            var expected = row.GetProperty("expected");
            string operation = row.GetProperty("operation").GetString()!;
            operations[operation] = operations.GetValueOrDefault(operation) + 1;
            switch (operation)
            {
                case "extract":
                {
                    string? error = expected.TryGetProperty("error", out var code) ? code.GetString() : null;
                    try
                    {
                        var document = await Extract(input.GetProperty("asset").GetString()!,
                            input.GetProperty("fallback").GetString()!, input.GetProperty("limits"));
                        Assert.True(error is null, $"{name}: expected {error}");
                        Assert.Equal(Utf8(expected.GetProperty("text").GetString()), Utf8(document.Text));
                        string? title = expected.GetProperty("title").ValueKind == JsonValueKind.Null
                            ? null : expected.GetProperty("title").GetString();
                        Assert.Equal(title, document.Title);
                        Assert.Equal("email", document.Kind);
                    }
                    catch (FolderIngestionException exception)
                    {
                        Assert.True(error == exception.Code, $"{name}: {exception.Code} != {error}");
                    }
                    break;
                }
                case "decode-header":
                    Assert.Equal(Utf8(expected.GetProperty("text").GetString()), Utf8(MailText.DecodeHeader(
                        input.GetProperty("text").GetString()!, input.GetProperty("fallback").GetString()!)));
                    break;
                case "html-to-text":
                    Assert.Equal(Utf8(expected.GetProperty("text").GetString()),
                        Utf8(MailText.HtmlToText(input.GetProperty("html").GetString()!)));
                    break;
                case "decode-charset":
                {
                    var bytes = input.GetProperty("bytes").EnumerateArray().Select(value => (byte)value.GetInt32()).ToArray();
                    var text = MailText.Decode(bytes, MailText.CodecForLabel(input.GetProperty("charset").GetString()!),
                        input.GetProperty("fallback").GetString()!);
                    Assert.Equal(Utf8(expected.GetProperty("text").GetString()), Utf8(text));
                    break;
                }
                case "filetime":
                    Assert.Equal(expected.GetProperty("text").GetString(), MailReader.Filetime(input.GetProperty("value").GetUInt64()));
                    break;
                default:
                    Assert.Fail("Unknown mail operation " + operation);
                    break;
            }
        }
        Assert.Equal(new Dictionary<string, int>
        {
            ["extract"] = 27, ["decode-header"] = 7, ["html-to-text"] = 7, ["decode-charset"] = 10, ["filetime"] = 4
        }, operations);
    }

    [Fact]
    public async Task FormatDetectionAndMacroEnabledOoxml()
    {
        var all = Cases("ingestion-formats-v1.json")
            .Select(row => SpreadsheetSupersession.Apply(row, "ingestion-formats-v1.json")).ToArray();
        Assert.Equal(all.Length, all.Select(row => row.GetProperty("name").GetString()).Distinct().Count());
        var counts = new Dictionary<string, int>();
        foreach (var row in all)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            var expected = row.GetProperty("expected");
            string operation = row.GetProperty("operation").GetString()!;
            counts[operation] = counts.GetValueOrDefault(operation) + 1;
            switch (operation)
            {
                case "detect":
                {
                    string? kind = expected.GetProperty("kind").ValueKind == JsonValueKind.Null
                        ? null : expected.GetProperty("kind").GetString();
                    Assert.True(kind == SourceTypeExtensions.Detect(input.GetProperty("filename").GetString()!)?.RawValue(), name);
                    break;
                }
                case "extract":
                {
                    var document = await Extract(input.GetProperty("asset").GetString()!, "cp1250", null);
                    Assert.Equal(expected.GetProperty("kind").GetString(), document.Kind);
                    Assert.Equal(Utf8(expected.GetProperty("text").GetString()), Utf8(document.Text));
                    break;
                }
                case "upgrade":
                    break;
                default:
                    Assert.Fail("Unknown formats operation " + operation);
                    break;
            }
        }
        Assert.Equal(18, counts["detect"]);
        Assert.Equal(3, counts["extract"]);
    }

    /// <summary>Deterministic byte mutations of every mail asset: the readers either produce text or fail with an
    /// ingestion error — never crash or hang.</summary>
    [Fact]
    public void MutatedMessagesFailCleanly()
    {
        var directory = SharedFixtures.Path("ingestion/formats");
        var names = Directory.GetFiles(directory).Select(Path.GetFileName)
            .Where(name => name!.EndsWith(".msg", StringComparison.Ordinal) || name.EndsWith(".eml", StringComparison.Ordinal))
            .OrderBy(name => name, StringComparer.Ordinal).ToArray();
        Assert.True(names.Length >= 10);
        ulong seed = 0x9E3779B97F4A7C15;
        int Next()
        {
            seed = unchecked(seed * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407);
            return (int)(seed >> 33);
        }
        int succeeded = 0, failed = 0;
        foreach (var name in names)
        {
            var original = File.ReadAllBytes(Path.Combine(directory, name!));
            for (int round = 0; round < 150; round++)
            {
                var bytes = (byte[])original.Clone();
                for (int k = 0, count = 1 + Next() % 8; k < count; k++)
                {
                    int index = Next() % bytes.Length;
                    bytes[index] = Next() % 3 == 0 ? (byte)0xFF : unchecked((byte)Next());
                }
                if (Next() % 10 == 0) bytes = bytes[..(Next() % bytes.Length)];
                try
                {
                    MailReader.Read(bytes, Path.GetExtension(name!), "cp1250", IngestionLimits.Defaults);
                    succeeded++;
                }
                catch (FolderIngestionException error)
                {
                    Assert.Contains(error.Code, new[] { "corruptArchive", "officeLimit", "textLimit" });
                    failed++;
                }
            }
        }
        Assert.True(succeeded > 0);
        Assert.True(failed > 0);
    }

    /// <summary>The legacy injectable Office extractor accepts macro-enabled packages too.</summary>
    [Fact]
    public async Task OfficeExtractorReadsMacroEnabledWorkbook()
    {
        var path = SharedFixtures.Path("ingestion/formats/macro.xlsm");
        var kind = SourceTypeExtensions.Detect(path)!.Value;
        var extracted = await new OfficeTextExtractor().ExtractAsync(new Uri(path), kind);
        // ingestion-xlsx-v2 supersedes the v1 `extract-xlsm` text.
        string expected = SpreadsheetSupersession.Map().GetProperty("ingestion-formats-v1.json")
            .GetProperty("extract-xlsm").GetProperty("text").GetString()!;
        Assert.Equal(expected, extracted.Text);
        Assert.Equal("## Data\nR1: Položka | 12", expected);
    }
}
