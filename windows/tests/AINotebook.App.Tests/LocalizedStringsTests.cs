using System.Xml.Linq;
using Xunit;

namespace AINotebook.App.Tests;

public class LocalizedStringsTests
{
    private static HashSet<string> Names(string reswPath) =>
        XDocument.Load(reswPath).Root!
            .Elements("data")
            .Select(d => (string)d.Attribute("name")!)
            .ToHashSet();

    // NOTE: requires WinUI? No — pure XML. Runs anywhere with .NET (incl. Windows CI).
    [Fact]
    public void Both_languages_have_the_same_234_keys()
    {
        var en = Names("en.resw");
        var cs = Names("cs.resw");

        // In-app update check: +9 (updateBannerTitle, updateDownloadButton, updateLaterButton,
        // updateAutoCheckToggle, updateCheckNowButton, updateStatusChecking, updateStatusUpToDate,
        // updateStatusAvailable, updateStatusFailed).
        // W-1 PDF export: +1 (exportNotePdf).
        Assert.Equal(234, en.Count);
        Assert.Equal(234, cs.Count);
        Assert.True(en.SetEquals(cs), "en-US and cs-CZ must define the identical key set");
    }

    [Fact]
    public void No_value_is_empty()
    {
        foreach (var path in new[] { "en.resw", "cs.resw" })
            foreach (var d in XDocument.Load(path).Root!.Elements("data"))
                Assert.False(string.IsNullOrWhiteSpace((string?)d.Element("value")),
                    $"{path}: '{(string?)d.Attribute("name")}' has no value");
    }
}
