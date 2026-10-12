using System.Text.Json;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests;

public class SharedFixturesTests
{
    [Fact]
    public void ConstantsFixtureLoads()
    {
        var fixture = SharedFixtures.Json("contracts/constants-v1.json");
        Assert.Equal("constants", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
    }

    [Fact]
    public void EveryContractFixtureHasEnvelopeAndUniqueCaseNames()
    {
        var files = SharedFixtures.ContractFiles();
        Assert.NotEmpty(files);
        Assert.Equal(files.OrderBy(Path.GetFileName, StringComparer.Ordinal), files);
        foreach (var path in files)
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            var fixture = doc.RootElement;
            Assert.Equal(JsonValueKind.Object, fixture.ValueKind);
            Assert.Equal(JsonValueKind.String, fixture.GetProperty("contract").ValueKind);
            Assert.True(fixture.GetProperty("version").TryGetInt32(out _), path);
            // Value tables without cases: constants-v1, ui-tokens-v1.
            var file = Path.GetFileName(path);
            if (file.StartsWith("constants-", StringComparison.Ordinal)
                || file.StartsWith("ui-tokens-", StringComparison.Ordinal)) continue;
            var cases = fixture.GetProperty("cases");
            Assert.Equal(JsonValueKind.Array, cases.ValueKind);
            var names = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in cases.EnumerateArray())
            {
                var name = item.GetProperty("name");
                Assert.Equal(JsonValueKind.String, name.ValueKind);
                Assert.True(names.Add(name.GetString()!), $"Duplicate case name in {path}: {name}");
            }
        }
    }
}
