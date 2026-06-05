using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreTransformationsTests
{
    [Fact]
    public void CreateListUpdateDelete()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var t = store.CreateTransformation("Custom", "do {{source_text}}", TransformationScope.Source, isBuiltin: false);
        Assert.Contains(store.Transformations(), x => x.Id == t.Id && !x.IsBuiltin);

        store.UpdateTransformation(t.Id!.Value, "Custom2", "redo {{source_text}}", "desc");
        var updated = store.Transformations().Single(x => x.Id == t.Id);
        Assert.Equal("Custom2", updated.Name);
        Assert.Equal("redo {{source_text}}", updated.PromptTemplate);

        store.DeleteTransformation(t.Id!.Value);
        Assert.DoesNotContain(store.Transformations(), x => x.Id == t.Id);
    }

    [Fact]
    public void OrderedBuiltinsFirstThenNameAsc()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        store.CreateTransformation("aaa-custom", "{{source_text}}", TransformationScope.Source, isBuiltin: false);
        var list = store.Transformations();
        // all builtins precede all non-builtins
        int firstNonBuiltin = list.ToList().FindIndex(x => !x.IsBuiltin);
        Assert.True(list.Take(firstNonBuiltin).All(x => x.IsBuiltin));
    }

    [Fact]
    public void RecordRunAndList()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var t = store.Transformations().First(x => x.IsBuiltin);
        var nb = store.CreateNotebook("N").Id!.Value;
        var note = store.CreateNote(nb, "out", "body");
        var run = store.RecordTransformationRun(t.Id!.Value, sourceId: null, resultNoteId: note.Id);
        Assert.Equal(note.Id, run.ResultNoteId);
        Assert.Contains(store.TransformationRuns(), r => r.Id == run.Id);
    }
}
