using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class UpdateCheckTests
{
    private static UpdateRelease Release(
        string tag, bool prerelease = false, string[]? assets = null,
        string html = "https://github.com/lukoplt/AI-notebook/releases/tag/x")
        => new(tag, prerelease, html,
            (assets ?? []).Select(a => new UpdateReleaseAsset(a, $"https://dl/{a}")).ToList());

    [Fact]
    public void NewerReleaseAvailable()
    {
        var releases = new[]
        {
            Release("v0.9.2", assets: ["AINotebook-v0.9.2-macos.dmg", "AINotebook-v0.9.2-windows-setup.exe"]),
            Release("v0.9.1", assets: ["AINotebook-v0.9.1-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.1", UpdateCheck.WindowsAssetSuffix);
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
        Assert.Equal("https://dl/AINotebook-v0.9.2-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public void EqualVersionIsNotAnUpdate()
        => Assert.False(UpdateCheck.Evaluate([Release("v0.9.2", assets: ["A-windows-setup.exe"])], "0.9.2", "-windows-setup.exe").IsUpdateAvailable);

    [Fact]
    public void OlderLatestIsNotAnUpdate()
        => Assert.False(UpdateCheck.Evaluate([Release("v0.9.0", assets: ["A-windows-setup.exe"])], "0.9.2", "-windows-setup.exe").IsUpdateAvailable);

    [Fact]
    public void PrereleaseIsIgnored()
    {
        var releases = new[]
        {
            Release("v1.0.0", prerelease: true, assets: ["A-windows-setup.exe"]),
            Release("v0.9.2", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.1", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
    }

    [Fact]
    public void NewestWithoutOurAssetFallsBackToNewestThatHasOne()
    {
        var releases = new[]
        {
            Release("v1.0.0", assets: ["A-macos.dmg"]),
            Release("win-v0.9.2", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.0", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
        Assert.Equal("https://dl/B-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public void EmptyListMeansNoUpdate()
        => Assert.Equal(UpdateInfo.None, UpdateCheck.Evaluate([], "0.9.2", "-windows-setup.exe"));

    [Fact]
    public void MalformedTagIsSkippedWithoutCrash()
    {
        var releases = new[]
        {
            Release("nightly-build", assets: ["A-windows-setup.exe"]),
            Release("v0.9.3", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.2", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.3", info.LatestVersion);
    }

    [Fact]
    public void SemverCompareNotLexicographic()
    {
        var releases = new[] { Release("v0.8.10", assets: ["A-windows-setup.exe"]) };
        Assert.True(UpdateCheck.Evaluate(releases, "0.8.9", "-windows-setup.exe").IsUpdateAvailable);
        Assert.False(UpdateCheck.Evaluate(releases, "0.8.10", "-windows-setup.exe").IsUpdateAvailable);
    }

    [Theory]
    [InlineData("v0.9.2", new[] { 0, 9, 2 })]
    [InlineData("win-v0.8.0", new[] { 0, 8, 0 })]
    [InlineData("0.9.2", new[] { 0, 9, 2 })]
    public void PrefixStripping(string tag, int[] expected)
        => Assert.Equal(expected, UpdateCheck.SemverComponents(tag));

    [Theory]
    [InlineData("nightly")]
    [InlineData("v1.2")]
    public void MalformedTagsYieldNull(string tag)
        => Assert.Null(UpdateCheck.SemverComponents(tag));

    [Fact]
    public void ReleaseNotesUrlComesFromHtmlUrl()
    {
        var releases = new[] { Release("v0.9.3", assets: ["A-windows-setup.exe"], html: "https://gh/rel/v0.9.3") };
        Assert.Equal("https://gh/rel/v0.9.3", UpdateCheck.Evaluate(releases, "0.9.2", "-windows-setup.exe").ReleaseNotesUrl);
    }
}
