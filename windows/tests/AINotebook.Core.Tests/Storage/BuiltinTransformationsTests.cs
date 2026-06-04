using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class BuiltinTransformationsTests
{
    [Fact]
    public void EnglishSeedsFourBuiltinsWithExpectedNamesAndDescriptions()
    {
        using var store = new NotebookStore(StorePath.InMemory, AppLanguage.English);
        var builtins = store.Transformations().Where(t => t.IsBuiltin).ToList();
        Assert.Equal(4, builtins.Count);
        Assert.All(builtins, b =>
        {
            Assert.Equal(TransformationScope.Source, b.Scope);
            Assert.Contains("{{source_text}}", b.PromptTemplate);
        });
        var byName = builtins.ToDictionary(b => b.Name);
        Assert.Equal("3–5 bullet summary of a source.", byName["Summary"].Description);
        Assert.Equal("5–10 most important takeaways.", byName["Key points"].Description);
        Assert.Equal("People, organizations, places, dates.", byName["Entities"].Description);
        Assert.Equal("Concrete next-step actions found in the text.", byName["Action items"].Description);
    }

    [Fact]
    public void CzechSeedsFourBuiltinsWithCzechNames()
    {
        using var store = new NotebookStore(StorePath.InMemory, AppLanguage.Czech);
        var names = store.Transformations().Where(t => t.IsBuiltin).Select(t => t.Name).OrderBy(n => n).ToArray();
        Assert.Equal(new[] { "Entity", "Klíčové body", "Souhrn", "Úkoly" }, names);
    }

    [Fact]
    public void SeedIsIdempotentAcrossReopen()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-bt-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var s1 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal(4, s1.Transformations().Count(t => t.IsBuiltin));
            using (var s2 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal(4, s2.Transformations().Count(t => t.IsBuiltin)); // no duplicates
        }
        finally { Directory.Delete(dir, recursive: true); }
    }

    [Fact]
    public void BackfillsEmptyDescriptionsForExistingBuiltins()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ainb-bf-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var path = new StorePath(Path.Combine(dir, "db.sqlite"));
        try
        {
            using (var s1 = new NotebookStore(path, AppLanguage.English))
            {
                // simulate a pre-v9 builtin with empty description
                Dapper.SqlMapper.Execute(s1.Connection,
                    "UPDATE transformations SET description='' WHERE name='Summary' AND is_builtin=1");
                Assert.Equal("", s1.Transformations().Single(t => t.Name == "Summary").Description);
            }
            using (var s2 = new NotebookStore(path, AppLanguage.English))
                Assert.Equal("3–5 bullet summary of a source.",
                    s2.Transformations().Single(t => t.Name == "Summary").Description);
        }
        finally { Directory.Delete(dir, recursive: true); }
    }
}
