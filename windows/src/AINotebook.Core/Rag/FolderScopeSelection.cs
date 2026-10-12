using System.Collections.Frozen;

namespace AINotebook.Core.Rag;

/// <summary>
/// The chat scope the user picked. Whole notebook resolves to <see cref="RetrievalScope.All"/>; selected mode is always
/// an explicit selection — an empty selection never becomes "all". Saved sets stay IDs and contribute their
/// <i>current</i> members per turn; folders stay folder IDs so membership is evaluated live per turn.
/// Input sets are copied on construction so a snapshot cannot change afterwards.
/// </summary>
public sealed record FolderScopeSelection(bool WholeNotebook, IReadOnlySet<long> SourceIds, IReadOnlySet<long> FolderIds,
    IReadOnlySet<long> SetIds)
{
    public IReadOnlySet<long> SourceIds { get; init; } = SourceIds.ToFrozenSet();
    public IReadOnlySet<long> FolderIds { get; init; } = FolderIds.ToFrozenSet();
    public IReadOnlySet<long> SetIds { get; init; } = SetIds.ToFrozenSet();

    public static FolderScopeSelection Whole { get; } = new(true, new HashSet<long>(), new HashSet<long>(), new HashSet<long>());

    public RetrievalScope Resolved(IReadOnlyDictionary<long, RetrievalScope> setScopes)
    {
        ArgumentNullException.ThrowIfNull(setScopes);
        if (WholeNotebook) return new RetrievalScope.All();
        var scopes = new List<RetrievalScope> { new RetrievalScope.Selection(SourceIds, FolderIds) };
        foreach (long id in SetIds.Order())
            // Persisted source sets always represent an explicit selection.
            if (setScopes.TryGetValue(id, out var scope) && scope is RetrievalScope.Selection) scopes.Add(scope);
        return RetrievalScope.Union(scopes);
    }

    public bool Equals(FolderScopeSelection? other) => other is not null && WholeNotebook == other.WholeNotebook &&
        SourceIds.SetEquals(other.SourceIds) && FolderIds.SetEquals(other.FolderIds) && SetIds.SetEquals(other.SetIds);

    public override int GetHashCode()
    {
        var hash = new HashCode();
        hash.Add(WholeNotebook);
        foreach (var set in new[] { SourceIds, FolderIds, SetIds })
        {
            hash.Add(set.Count);
            foreach (long id in set.Order()) hash.Add(id);
        }
        return hash.ToHashCode();
    }
}
