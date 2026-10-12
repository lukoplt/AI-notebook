using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Language;

public sealed class UnicodeTablesTests
{
    private static byte[] Resource(string name)
    {
        using var stream = typeof(UnicodeTables).Assembly.GetManifestResourceStream("AINotebook.Core.Language." + name);
        Assert.NotNull(stream);
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }

    [Fact]
    public void SimpleLowerAndFullFoldAreDifferent()
    {
        var u = UnicodeTables.LoadBundled();
        Assert.Equal(105, u.SimpleLowercase(0x0130));
        Assert.Equal(0x10428, u.SimpleLowercase(0x10400));
        Assert.Equal(new[] { 105, 775, 115, 115 }, u.FullCaseFold(new[] { 0x0130, 0x1E9E }));
        Assert.Equal("Lo", u.GeneralCategory(0x11F02));
    }

    [Fact]
    public void AllNormalizationRows()
    {
        var u = UnicodeTables.LoadBundled();
        var path = SharedFixtures.Path("unicode/NormalizationTest-15.1.0.txt");
        const string expectedHash = "871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e";
        Assert.Equal(expectedHash, Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))));
        Assert.Equal(expectedHash + "\n", File.ReadAllText(path + ".sha256"));
        using var provenance = JsonDocument.Parse(Resource("unicode-sources-v1.json"));
        int rows = 0;
        foreach (var line in File.ReadLines(path))
        {
            var body = line.Split('#')[0].Trim();
            if (body.Length == 0 || body.StartsWith('@')) continue;
            var c = body.Split(';').Take(5).Select(field => field
                .Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture)).ToArray()).ToArray();
            Assert.Equal(5, c.Length);
            for (int i = 0; i < 3; i++) Assert.Equal(c[1], u.Nfc(c[i]));
            for (int i = 3; i < 5; i++) Assert.Equal(c[3], u.Nfc(c[i]));
            rows++;
        }
        Assert.Equal(19074, rows);
        Assert.Equal(provenance.RootElement.GetProperty("normalizationRows").GetInt32(), rows);
        var bytes = Resource("unicode-15.1.0.json");
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        Assert.Equal(hash + "\n", Encoding.ASCII.GetString(Resource("unicode-15.1.0.json.sha256")));
        Assert.Equal(provenance.RootElement.GetProperty("tableSha256").GetString(), hash);
    }

    [Fact]
    public void BadResourceHashThrows() => Assert.Throws<InvalidDataException>(() =>
        UnicodeTables.Load("{}\n"u8, new string('0', 64)));

    [Fact]
    public void EverySharedOperation()
    {
        var u = UnicodeTables.LoadBundled();
        foreach (var c in SharedFixtures.Json("contracts/unicode-tables-v1.json").GetProperty("cases").EnumerateArray())
        {
            int[] input = c.GetProperty("input").EnumerateArray().Select(x => x.GetInt32()).ToArray();
            var expected = c.GetProperty("expected");
            switch (c.GetProperty("operation").GetString())
            {
                case "category": Assert.Equal(expected.EnumerateArray().Select(x => x.GetString()), input.Select(u.GeneralCategory)); break;
                case "nfc": Assert.Equal(expected.EnumerateArray().Select(x => x.GetInt32()), u.Nfc(input)); break;
                case "fold": Assert.Equal(expected.EnumerateArray().Select(x => x.GetInt32()), u.FullCaseFold(input)); break;
                case "lower": Assert.Equal(expected.EnumerateArray().Select(x => x.GetInt32()), input.Select(u.SimpleLowercase)); break;
                default: Assert.Fail(c.GetProperty("name").GetString()); break;
            }
        }
    }
}
