using Xunit;

namespace AINotebook.Core.Tests;

public class SmokeTest
{
    [Fact]
    public void Toolchain_Is_Wired()
    {
        Assert.Equal(4, 2 + 2);
    }
}
