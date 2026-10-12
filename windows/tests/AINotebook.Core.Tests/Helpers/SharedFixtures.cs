using System.Text.Json;

namespace AINotebook.Core.Tests.Helpers;

/// <summary>Repo-root Tests/fixtures, linked into the test output by MSBuild.</summary>
internal static class SharedFixtures
{
    public static string Path(string relativePath) =>
        System.IO.Path.Combine(AppContext.BaseDirectory, "SharedFixtures", relativePath);

    public static JsonElement Json(string relativePath)
    {
        using var document = JsonDocument.Parse(File.ReadAllBytes(Path(relativePath)));
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new JsonException("A shared fixture must be an object.");
        return document.RootElement.Clone();
    }

    public static IReadOnlyList<string> ContractFiles() =>
        Directory.GetFiles(Path("contracts"), "*.json")
            .OrderBy(System.IO.Path.GetFileName, StringComparer.Ordinal).ToArray();
}
