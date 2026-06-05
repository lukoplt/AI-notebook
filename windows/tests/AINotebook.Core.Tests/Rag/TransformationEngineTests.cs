using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class TransformationEngineTests
{
    private static long MakeTransformation(NotebookStore store, string name, string template)
    {
        var t = store.CreateTransformation(name, template, TransformationScope.Source, isBuiltin: false);
        return t.Id!.Value;
    }

    // TransformationEngineTests.testRunsTemplateOverSourceAndSavesAsNote
    [Fact]
    public async Task RunsTemplateOverSourceAndSavesAsNote()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Doc", null, null);
        store.ReplaceChunks(src.Id!.Value, new[]
        {
            new ChunkDraft("Alpha", 1, null),
            new ChunkDraft("Beta", 1, null),
        });
        var tId = MakeTransformation(store, "Summary", "TEMPLATE:\n{{source_text}}");

        var chat = new MockChatClient("- Alpha\n", "- Beta\n");
        var engine = new TransformationEngine(store, chat, "m");
        var note = await engine.RunAsync(tId, src.Id!.Value);

        Assert.Equal(NoteOrigin.Transformation, note.Origin);
        Assert.Equal("- Alpha\n- Beta\n", note.BodyMd);
        Assert.Contains("Sum", note.Title);

        var runs = store.TransformationRuns();
        Assert.Single(runs);
        Assert.Equal(src.Id!.Value, runs[0].SourceId);
        Assert.Equal(note.Id, runs[0].ResultNoteId);

        var userTurn = chat.CapturedMessages[0][0];
        Assert.Equal(ChatRole.User, userTurn.Role);
        Assert.Contains("Alpha", userTurn.Content);
        Assert.Contains("Beta", userTurn.Content);
        Assert.Contains("TEMPLATE:", userTurn.Content);
    }

    // TransformationEngineTests.testRejectsMissingSource
    [Fact]
    public async Task RejectsMissingSource()
    {
        var store = new NotebookStore(StorePath.InMemory);
        store.CreateNotebook("N", "");
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");
        var engine = new TransformationEngine(store, new MockChatClient("x"), "m");

        await Assert.ThrowsAsync<TransformationException.SourceNotFound>(
            () => engine.RunAsync(tId, 999));
    }

    // TransformationEngineStreamTests.testStreamsTokensWhileRunning
    [Fact]
    public async Task StreamsTokensWhileRunning()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Doc", null, null);
        store.ReplaceChunks(src.Id!.Value, new[] { new ChunkDraft("body", 1, null) });
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new StaggeredChat("alpha ", "beta ", "gamma");
        var engine = new TransformationEngine(store, chat, "m");

        var received = new List<string>();
        var note = await engine.RunAsync(tId, src.Id!.Value, onToken: t => received.Add(t));

        Assert.Equal(new[] { "alpha ", "beta ", "gamma" }, received);
        Assert.Equal("alpha beta gamma", note.BodyMd);
    }

    // TransformationNotebookScopeTests.testRunNotebookScopeConcatenatesAllSources
    [Fact]
    public async Task RunNotebookScopeConcatenatesAllSources()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var s1 = store.CreateSource(nb.Id!.Value, SourceType.Text, "S1", null, null);
        store.ReplaceChunks(s1.Id!.Value, new[] { new ChunkDraft("A1", 1, null) });
        var s2 = store.CreateSource(nb.Id!.Value, SourceType.Text, "S2", null, null);
        store.ReplaceChunks(s2.Id!.Value, new[] { new ChunkDraft("B1", 1, null) });
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new MockChatClient("Summary of all");
        var engine = new TransformationEngine(store, chat, "m");
        var note = await engine.RunNotebookScopeAsync(tId, nb.Id!.Value);

        Assert.Equal("Summary of all", note.BodyMd);
        var userTurn = chat.CapturedMessages[0][0];
        Assert.Contains("A1", userTurn.Content);
        Assert.Contains("B1", userTurn.Content);
    }

    // TransformationBatchTests.testRunsTemplateOnEverySourceProducingOneNoteEach
    [Fact]
    public async Task RunsTemplateOnEverySourceProducingOneNoteEach()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        for (var i = 0; i < 3; i++)
        {
            var s = store.CreateSource(nb.Id!.Value, SourceType.Text, $"S{i}", null, null);
            store.ReplaceChunks(s.Id!.Value, new[] { new ChunkDraft($"text{i}", 1, null) });
        }
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");

        var chat = new MockChatClient("out");
        var engine = new TransformationEngine(store, chat, "m");
        var notes = await engine.RunOnAllSourcesAsync(tId, nb.Id!.Value);

        Assert.Equal(3, notes.Count);
        Assert.Equal(3, chat.Calls);
        Assert.All(notes, n => Assert.Equal(NoteOrigin.Transformation, n.Origin));
    }

    // TransformationBatchTests.testEmptyNotebookReturnsEmptyArray
    [Fact]
    public async Task EmptyNotebookReturnsEmptyArray()
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("N", "");
        var tId = MakeTransformation(store, "Summary", "{{source_text}}");
        var engine = new TransformationEngine(store, new MockChatClient("x"), "m");

        var notes = await engine.RunOnAllSourcesAsync(tId, nb.Id!.Value);
        Assert.Empty(notes);
    }
}
