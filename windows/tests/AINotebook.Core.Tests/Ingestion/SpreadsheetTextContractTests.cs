using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Frozen v1 fixture cases whose expected XLSX canonical text is replaced by <c>ingestion-xlsx-v2</c> (its
/// <c>supersedes</c> map). The v1 files stay byte-identical; consumers swap in the v2 expectation for exactly the
/// listed cases.</summary>
internal static class SpreadsheetSupersession
{
    public static JsonElement Map() =>
        SharedFixtures.Json("contracts/ingestion-xlsx-v2.json").GetProperty("supersedes");

    /// <summary>The case row with its <c>expected</c> replaced when v2 supersedes it.</summary>
    public static JsonElement Apply(JsonElement row, string fixture)
    {
        if (!Map().TryGetProperty(fixture, out var cases) ||
            !cases.TryGetProperty(row.GetProperty("name").GetString()!, out var replacement)) return row;
        var node = JsonNode.Parse(row.GetRawText())!.AsObject();
        node["expected"] = JsonNode.Parse(replacement.GetRawText());
        using var document = JsonDocument.Parse(node.ToJsonString());
        return document.RootElement.Clone();
    }
}

/// <summary>Shared <c>ingestion-xlsx-v2</c> value renderers (same cases as macOS SpreadsheetTextContractTests).</summary>
public sealed class SpreadsheetTextContractTests
{
    private static JsonElement Fixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-xlsx-v2.json");
        Assert.Equal("ingestion-xlsx", fixture.GetProperty("contract").GetString());
        Assert.Equal(2, fixture.GetProperty("version").GetInt32());
        return fixture;
    }

    private static byte[]? Utf8(string? text) => text is null ? null : Encoding.UTF8.GetBytes(text);
    private static string? Text(JsonElement row)
    {
        var text = row.GetProperty("expected").GetProperty("text");
        return text.ValueKind == JsonValueKind.Null ? null : text.GetString();
    }

    [Fact]
    public void Constants()
    {
        var fixture = Fixture();
        Assert.Equal(SpreadsheetText.FormatVersion, fixture.GetProperty("textFormatVersion").GetInt32());
        Assert.Equal(SpreadsheetText.SignificantDigits, fixture.GetProperty("significantDigits").GetInt32());
        Assert.Equal(SpreadsheetText.CellSeparator, fixture.GetProperty("cellSeparator").GetString());
    }

    [Fact]
    public void ValueRenderers()
    {
        var counts = new Dictionary<string, int>();
        foreach (var row in Fixture().GetProperty("cases").EnumerateArray())
        {
            string name = row.GetProperty("name").GetString()!, operation = row.GetProperty("operation").GetString()!;
            var input = row.GetProperty("input");
            counts[operation] = counts.GetValueOrDefault(operation) + 1;
            switch (operation)
            {
                case "number":
                    Assert.True(Equal(Utf8(Text(row)), Utf8(SpreadsheetText.Number(input.GetProperty("raw").GetString()!))), name);
                    break;
                case "date":
                    Assert.True(Text(row) == SpreadsheetText.Date(input.GetProperty("raw").GetString()!,
                        input.GetProperty("date1904").GetBoolean()), name);
                    break;
                case "value":
                    Assert.True(Equal(Utf8(Text(row) ?? ""), Utf8(SpreadsheetText.Normalize(input.GetProperty("raw").GetString()!))), name);
                    break;
                case "extract":
                    break;
                default:
                    Assert.Fail("unknown operation " + operation);
                    break;
            }
        }
        Assert.True(counts["number"] >= 30);
        Assert.True(counts["date"] >= 20);
        Assert.True(counts["value"] >= 8);
        Assert.True(counts["extract"] >= 25);
    }

    [Fact]
    public void ColumnNamesAndCivilDays()
    {
        Assert.Equal(["A", "Z", "AA", "AZ", "BA", "ZZ", "AAA", "XFD"],
            new[] { 1, 26, 27, 52, 53, 702, 703, 16_384 }.Select(SpreadsheetText.ColumnName));
        Assert.Equal(0, SpreadsheetText.DaysFromCivil(1970, 1, 1));
        Assert.Equal((2024L, 2L, 29L), SpreadsheetText.CivilFromDays(SpreadsheetText.DaysFromCivil(2024, 2, 29)));
    }

    [Fact]
    public void SupersessionCoversOnlyListedCases()
    {
        var map = SpreadsheetSupersession.Map();
        Assert.Equal(["ingestion-formats-v1.json", "ingestion-office-v1.json", "ingestion-ooxml-v1.json",
            "release-integration-v1.json"], map.EnumerateObject().Select(p => p.Name).Order(StringComparer.Ordinal));
        Assert.Equal(9, map.GetProperty("ingestion-office-v1.json").EnumerateObject().Count());
        Assert.Equal(3, map.GetProperty("ingestion-ooxml-v1.json").EnumerateObject().Count());
    }

    private static bool Equal(byte[]? a, byte[]? b) => a is null ? b is null : b is not null && a.SequenceEqual(b);
}
