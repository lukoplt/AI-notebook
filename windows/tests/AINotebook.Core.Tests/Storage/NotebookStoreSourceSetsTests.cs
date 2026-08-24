using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// FR-C2 named source sets (schema v13) — the saved scope presets the chat
/// scope picker offers. Shipped in Epic C without storage tests.
/// </summary>
public class NotebookStoreSourceSetsTests
{
    private static (NotebookStore store, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("NB").Id!.Value);
    }

    private static long NewSource(NotebookStore store, long nb, string title) =>
        store.CreateSource(nb, SourceType.Text, title, null, null).Id!.Value;

    [Fact]
    public void SetsAreScopedToTheirNotebookAndListedByName()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A").Id!.Value;
        var b = store.CreateNotebook("B").Id!.Value;

        store.CreateSourceSet(a, "Zebra");
        store.CreateSourceSet(a, "Alpha");
        store.CreateSourceSet(b, "Other");

        Assert.Equal(new[] { "Alpha", "Zebra" }, store.SourceSets(a).Select(s => s.Name).ToArray());
        Assert.Equal(new[] { "Other" }, store.SourceSets(b).Select(s => s.Name).ToArray());
    }

    [Fact]
    public void CreateTrimsTheName()
    {
        var (store, nb) = NewStore();
        using var _ = store;

        var set = store.CreateSourceSet(nb, "  Reading list  ");

        Assert.Equal("Reading list", set.Name);
        Assert.Equal("Reading list", store.SourceSets(nb).Single().Name);
    }

    [Fact]
    public void MembersRoundTripAndAreReplacedWholesale()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var one = NewSource(store, nb, "One");
        var two = NewSource(store, nb, "Two");
        var three = NewSource(store, nb, "Three");
        var set = store.CreateSourceSet(nb, "Set");

        store.SetSourceSetMembers(set.Id, new[] { one, two });
        Assert.Equal(new[] { one, two }, store.SourceSetMembers(set.Id).OrderBy(x => x).ToArray());

        // Replacement, not union — this is what makes "save current selection"
        // overwrite rather than accumulate.
        store.SetSourceSetMembers(set.Id, new[] { three });
        Assert.Equal(new[] { three }, store.SourceSetMembers(set.Id).ToArray());
    }

    [Fact]
    public void AnEmptyMemberListIsAllowedAndYieldsAnEmptySet()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var source = NewSource(store, nb, "One");
        var set = store.CreateSourceSet(nb, "Set");
        store.SetSourceSetMembers(set.Id, new[] { source });

        store.SetSourceSetMembers(set.Id, Array.Empty<long>());

        Assert.Empty(store.SourceSetMembers(set.Id));
    }

    [Fact]
    public void RenameChangesOnlyTheTargetSet()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var first = store.CreateSourceSet(nb, "First");
        store.CreateSourceSet(nb, "Second");

        store.RenameSourceSet(first.Id, "  Renamed  ");

        Assert.Equal(new[] { "Renamed", "Second" },
            store.SourceSets(nb).Select(s => s.Name).OrderBy(n => n).ToArray());
    }

    [Fact]
    public void DeletingASetRemovesItsMembershipsButKeepsTheSources()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var source = NewSource(store, nb, "One");
        var set = store.CreateSourceSet(nb, "Set");
        store.SetSourceSetMembers(set.Id, new[] { source });

        store.DeleteSourceSet(set.Id);

        Assert.Empty(store.SourceSets(nb));
        Assert.Empty(store.SourceSetMembers(set.Id));
        Assert.Single(store.Sources(nb));
    }

    [Fact]
    public void DeletingASourceDropsItFromEverySetItBelongedTo()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var doomed = NewSource(store, nb, "Doomed");
        var kept = NewSource(store, nb, "Kept");
        var set = store.CreateSourceSet(nb, "Set");
        store.SetSourceSetMembers(set.Id, new[] { doomed, kept });

        store.DeleteSource(doomed);

        // A stale member id would silently narrow every future chat scoped to
        // this set, so the membership row has to go with the source.
        Assert.Equal(new[] { kept }, store.SourceSetMembers(set.Id).ToArray());
    }
}
