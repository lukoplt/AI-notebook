using System.Globalization;
using Xunit;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Tests.Storage;

public class SqliteDateTests
{
    [Fact]
    public void RoundTrips_Utc_DateTime()
    {
        // A UTC instant with non-zero milliseconds, truncated to ms precision.
        var original = new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc);

        string text = SqliteDate.ToDb(original);
        Assert.Equal("2026-05-24 21:50:39.694", text);

        DateTime parsed = SqliteDate.FromDb(text);
        Assert.Equal(DateTimeKind.Utc, parsed.Kind);
        Assert.Equal(original, parsed);
    }

    [Fact]
    public void ToDb_AlwaysWrites_ThreeMillisecondDigits()
    {
        // Whole second => still ".000"
        var whole = new DateTime(2026, 1, 2, 3, 4, 5, 0, DateTimeKind.Utc);
        Assert.Equal("2026-01-02 03:04:05.000", SqliteDate.ToDb(whole));
    }

    [Fact]
    public void ToDb_Converts_Local_To_Utc()
    {
        // A Local kind value must be normalized to UTC before formatting.
        var utc = new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc);
        var local = utc.ToLocalTime(); // Kind == Local
        Assert.Equal("2026-05-24 21:50:39.694", SqliteDate.ToDb(local));
    }

    [Fact]
    public void FromDb_Parses_Known_Production_String_As_Utc()
    {
        // Verbatim production sample from the extraction.
        DateTime parsed = SqliteDate.FromDb("2026-05-24 21:50:39.694");
        Assert.Equal(DateTimeKind.Utc, parsed.Kind);
        Assert.Equal(
            new DateTime(2026, 5, 24, 21, 50, 39, 694, DateTimeKind.Utc),
            parsed);
    }
}
