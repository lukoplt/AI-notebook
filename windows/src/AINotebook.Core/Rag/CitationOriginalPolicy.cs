using System.Text;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Rag;

/// <summary>
/// A native resolver's snapshot. Component identities are already canonical for
/// the filesystem, including its casing and symlink/reparse-point resolution.
/// </summary>
public sealed record CitationOriginalInput(string RelativePath, string[] RootComponents,
    string[] ResolvedComponents, bool CaseSensitive, bool Exists, bool IsRegularFile,
    bool SourceExists, long? CurrentRevisionId, long? CitedRevisionId)
{
    private readonly string[] _rootComponents = RootComponents.ToArray();
    private readonly string[] _resolvedComponents = ResolvedComponents.ToArray();

    public string[] RootComponents
    {
        get => _rootComponents.ToArray();
        init => _rootComponents = value.ToArray();
    }

    public string[] ResolvedComponents
    {
        get => _resolvedComponents.ToArray();
        init => _resolvedComponents = value.ToArray();
    }
}

[JsonConverter(typeof(JsonStringEnumConverter<CitationOriginalDecision>))]
public enum CitationOriginalDecision
{
    [JsonStringEnumMemberName("available")]
    Available,
    [JsonStringEnumMemberName("changed")]
    Changed,
    [JsonStringEnumMemberName("unavailable")]
    Unavailable,
    [JsonStringEnumMemberName("unsafe")]
    Unsafe
}

/// <summary>Pure original-opening policy; never resolves or opens a filesystem path.</summary>
public static class CitationOriginalPolicy
{
    public static CitationOriginalDecision Evaluate(CitationOriginalInput input)
    {
        ArgumentNullException.ThrowIfNull(input);
        string path = input.RelativePath;
        if (string.IsNullOrEmpty(path) || path.StartsWith('/') || path.Contains('\\')
            || path.Contains(':') || path.EnumerateRunes().Any(r => r.Value < 32)
            || path.Split('/').Any(part => part is "" or "." or ".."))
            return CitationOriginalDecision.Unsafe;

        if (!input.SourceExists || !input.Exists || !input.IsRegularFile)
            return CitationOriginalDecision.Unavailable;

        var root = input.RootComponents;
        var resolved = input.ResolvedComponents;
        // CaseSensitive describes native resolution; it never enables Core
        // lowercasing or normalization of these already resolved identities.
        if (root.Length == 0 || resolved.Length <= root.Length
            || !root.SequenceEqual(resolved.Take(root.Length), StringComparer.Ordinal))
            return CitationOriginalDecision.Unsafe;

        return input.CitedRevisionId is not null && input.CurrentRevisionId != input.CitedRevisionId
            ? CitationOriginalDecision.Changed : CitationOriginalDecision.Available;
    }
}
