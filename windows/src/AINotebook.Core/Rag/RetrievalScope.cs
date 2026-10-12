using System.Collections.Frozen;
using System.Text.Json;

namespace AINotebook.Core.Rag;

/// <summary>
/// Sources unioned with current folder members. Empty selection means no results.
/// </summary>
public abstract record RetrievalScope
{
    private RetrievalScope() { }

    public sealed record All : RetrievalScope;

    public sealed record Selection(IReadOnlySet<long> SourceIds, IReadOnlySet<long> FolderIds) : RetrievalScope
    {
        // Snapshot the sets so their contents and the scope's hash cannot change later.
        public IReadOnlySet<long> SourceIds { get; } = SourceIds.ToFrozenSet();
        public IReadOnlySet<long> FolderIds { get; } = FolderIds.ToFrozenSet();

        public bool Equals(Selection? other) => other is not null
            && SourceIds.SetEquals(other.SourceIds) && FolderIds.SetEquals(other.FolderIds);

        public override int GetHashCode()
        {
            var hash = new HashCode();
            hash.Add(SourceIds.Count);
            foreach (var id in SourceIds.Order()) hash.Add(id);
            hash.Add(FolderIds.Count);
            foreach (var id in FolderIds.Order()) hash.Add(id);
            return hash.ToHashCode();
        }
    }

    public bool IsEmptySelection => this is Selection { SourceIds.Count: 0, FolderIds.Count: 0 };

    public static RetrievalScope Union(IEnumerable<RetrievalScope> scopes)
    {
        var sources = new HashSet<long>();
        var folders = new HashSet<long>();
        foreach (var scope in scopes)
        {
            if (scope is All) return new All();
            if (scope is Selection selection)
            {
                sources.UnionWith(selection.SourceIds);
                folders.UnionWith(selection.FolderIds);
            }
        }
        return new Selection(sources, folders);
    }
}

public static class RetrievalScopeJson
{
    public static string Serialize(RetrievalScope scope) => scope switch
    {
        RetrievalScope.All => JsonSerializer.Serialize(new { kind = "all" }),
        RetrievalScope.Selection selection => JsonSerializer.Serialize(new
        {
            kind = "selection", sourceIds = selection.SourceIds.Order().ToArray(),
            folderIds = selection.FolderIds.Order().ToArray()
        }),
        _ => throw new ArgumentException("Unknown retrieval scope.", nameof(scope))
    };

    public static RetrievalScope Deserialize(string raw)
    {
        using var document = JsonDocument.Parse(raw);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String)
            throw new JsonException("Scope requires a string kind.");
        return kind.GetString() switch
        {
            "all" => new RetrievalScope.All(),
            "selection" => new RetrievalScope.Selection(ReadIds(root, "sourceIds"), ReadIds(root, "folderIds")),
            _ => throw new JsonException("Unknown scope kind.")
        };
    }

    private static IReadOnlySet<long> ReadIds(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var array) || array.ValueKind != JsonValueKind.Array)
            throw new JsonException($"Scope requires an array: {key}.");
        var ids = new HashSet<long>();
        foreach (var item in array.EnumerateArray())
            ids.Add(ReadId(item));
        return ids;
    }

    private static long ReadId(JsonElement item)
    {
        if (item.ValueKind == JsonValueKind.Number)
        {
            if (item.TryGetInt64(out var id)) return id;
            // Match Swift JSONDecoder's Int64(exactly: Double) fallback. Scope
            // uses ordinary Codable; only the citations codec bans . / e / E.
            // The upper bound is exclusive because Double rounds Int64.MaxValue
            // up to 2^63, which must not be converted to an Int64.
            if (item.TryGetDouble(out var number) && double.IsFinite(number)
                && number >= long.MinValue && number < 9_223_372_036_854_775_808d
                && number == Math.Truncate(number))
                return (long)number;
        }
        throw new JsonException("Scope IDs must decode to Int64 values.");
    }
}
