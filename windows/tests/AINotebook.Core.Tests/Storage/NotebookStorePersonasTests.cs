using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

/// <summary>
/// FR-C5 personas (schema v18) — the named preset of instructions + source set
/// + model behind the chat persona picker.
/// </summary>
public class NotebookStorePersonasTests
{
    private static (NotebookStore store, long notebookId) NewStore()
    {
        var store = new NotebookStore(StorePath.InMemory);
        return (store, store.CreateNotebook("NB").Id!.Value);
    }

    [Fact]
    public void CreateRoundTripsEveryFieldAndTrimsTheName()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var set = store.CreateSourceSet(nb, "Set");

        var created = store.CreatePersona(
            nb, "  Reviewer  ", "Be terse.", sourceSetId: set.Id, model: "ollama:llama3");

        var loaded = store.Personas(nb).Single();
        Assert.Equal("Reviewer", created.Name);
        Assert.Equal("Reviewer", loaded.Name);
        Assert.Equal("Be terse.", loaded.Instructions);
        Assert.Equal(set.Id, loaded.SourceSetId);
        Assert.Equal("ollama:llama3", loaded.Model);
        Assert.Equal(nb, loaded.NotebookId);
    }

    [Fact]
    public void OptionalFieldsStayNullRatherThanBecomingEmptyStrings()
    {
        var (store, nb) = NewStore();
        using var _ = store;

        store.CreatePersona(nb, "Plain");

        var loaded = store.Personas(nb).Single();
        Assert.Null(loaded.SourceSetId);
        Assert.Null(loaded.Model);
        // Instructions default to empty, not null — the column is NOT NULL and
        // the view model treats blank as "fall through to notebook instructions".
        Assert.Equal("", loaded.Instructions);
    }

    [Fact]
    public void PersonasAreScopedToTheirNotebookAndOrderedByName()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var a = store.CreateNotebook("A").Id!.Value;
        var b = store.CreateNotebook("B").Id!.Value;

        store.CreatePersona(a, "Zebra");
        store.CreatePersona(a, "Alpha");
        store.CreatePersona(b, "Other");

        Assert.Equal(new[] { "Alpha", "Zebra" }, store.Personas(a).Select(p => p.Name).ToArray());
        Assert.Equal(new[] { "Other" }, store.Personas(b).Select(p => p.Name).ToArray());
    }

    [Fact]
    public void UpdateRewritesNameInstructionsSourceSetAndModel()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var set = store.CreateSourceSet(nb, "Set");
        var persona = store.CreatePersona(nb, "Before", "old", null, "ollama:a");

        store.UpdatePersona(persona with
        {
            Name = "  After  ",
            Instructions = "new",
            SourceSetId = set.Id,
            Model = "openai:gpt"
        });

        var loaded = store.Personas(nb).Single();
        Assert.Equal("After", loaded.Name);
        Assert.Equal("new", loaded.Instructions);
        Assert.Equal(set.Id, loaded.SourceSetId);
        Assert.Equal("openai:gpt", loaded.Model);
    }

    [Fact]
    public void UpdateCanClearTheSourceSetAndModelBackToNull()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var set = store.CreateSourceSet(nb, "Set");
        var persona = store.CreatePersona(nb, "P", "i", set.Id, "ollama:a");

        store.UpdatePersona(persona with { SourceSetId = null, Model = null });

        var loaded = store.Personas(nb).Single();
        Assert.Null(loaded.SourceSetId);
        Assert.Null(loaded.Model);
    }

    [Fact]
    public void DeleteRemovesOnlyTheTargetPersona()
    {
        var (store, nb) = NewStore();
        using var _ = store;
        var doomed = store.CreatePersona(nb, "Doomed");
        store.CreatePersona(nb, "Kept");

        store.DeletePersona(doomed.Id);

        Assert.Equal(new[] { "Kept" }, store.Personas(nb).Select(p => p.Name).ToArray());
    }

    [Fact]
    public void DeletingANotebookTakesItsPersonasWithIt()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB").Id!.Value;
        store.CreatePersona(nb, "P");

        store.DeleteNotebook(nb);

        Assert.Empty(store.Personas(nb));
    }
}
