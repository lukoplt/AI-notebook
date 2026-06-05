using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class AINotebookVersionTests
{
    // AINotebookVersionTests.testVersionMatchesExpected — UPDATE when version bumps.
    [Fact]
    public void VersionMatchesExpected() => Assert.Equal("0.7.3", AINotebookVersion.Current);
}
