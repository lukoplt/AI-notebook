using AINotebook.App.Services;
using Xunit;

namespace AINotebook.App.Tests;

public sealed class StartupSmokeProfileTests
{
    [Fact]
    public void OrdinaryLaunchHasNoOverride() => Assert.Null(StartupSmokeProfile.Parse([]));

    [Fact]
    public void OverridesEveryPersistentPath()
    {
        string root = Path.Combine(Path.GetTempPath(), "ainotebook-smoke-test");
        var p = Assert.IsType<StartupSmokeProfile>(StartupSmokeProfile.Parse(["--startup-smoke", root]));
        Assert.Equal(Path.Combine(root, "db.sqlite"), p.DatabasePath);
        Assert.Equal(Path.Combine(root, "settings.json"), p.SettingsPath);
        Assert.Equal(Path.Combine(root, "attachments"), p.AttachmentsPath);
        Assert.Equal(Path.Combine(root, "smoke-result.json"), p.ResultPath);
    }

    [Fact]
    public void MissingProfileFails() =>
        Assert.Throws<ArgumentException>(() => StartupSmokeProfile.Parse(["--startup-smoke"]));

    [Fact]
    public void RelativeProfileFails() =>
        Assert.Throws<ArgumentException>(() => StartupSmokeProfile.Parse(["--startup-smoke", "profile"]));

    [Fact]
    public void TemporaryRootItselfFails() =>
        Assert.Throws<ArgumentException>(() => StartupSmokeProfile.Parse(["--startup-smoke", Path.GetTempPath()]));

    [Fact]
    public void TemporaryPrefixIsNotContainment()
    {
        string sibling = Path.TrimEndingDirectorySeparator(Path.GetTempPath()) + "-outside"
            + Path.DirectorySeparatorChar + "profile";
        Assert.Throws<ArgumentException>(() => StartupSmokeProfile.Parse(["--startup-smoke", sibling]));
    }

    [Fact]
    public void ExtraArgumentsFail() =>
        Assert.Throws<ArgumentException>(() => StartupSmokeProfile.Parse([
            "--startup-smoke", Path.Combine(Path.GetTempPath(), "ainotebook-smoke-test"), "--unexpected"]));
}
