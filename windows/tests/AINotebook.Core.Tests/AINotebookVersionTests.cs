using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class AINotebookVersionTests
{
    private static string RepoVersion()
        => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "VERSION")).Trim();

    /// The in-code constant must always match the repo-root VERSION file —
    /// a release bump that forgets the constant fails CI here.
    [Fact]
    public void VersionMatchesRepoVersionFile()
        => Assert.Equal(RepoVersion(), AINotebookVersion.Current);

    [Fact]
    public void VersionIsSemverShape()
    {
        var parts = AINotebookVersion.Current.Split('.');
        Assert.Equal(3, parts.Length);
        Assert.All(parts, p => Assert.True(int.TryParse(p, out _)));
    }
}
