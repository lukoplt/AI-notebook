using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

/// <summary>
/// FR-D1 contextual chunk enrichment (schema v14). Covers what the enricher
/// stores, what it sends, and that it stays inert on empty input.
///
/// NOTE: the number of model calls is deliberately NOT asserted here. The
/// implementation issues one call per chunk, while FR-D1 specifies one pass per
/// SOURCE with a document-level context shared by its chunks. Both platforms
/// have the same divergence, and pinning the current behaviour down in a test
/// would cement it — see docs/roadmap.md section 0.3.
/// </summary>
public class ContextualEnricherTests
{
    private static (NotebookStore store, long sourceId) SourceWithChunks(params string[] texts)
    {
        var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Doc", null, null);
        store.ReplaceChunks(src.Id!.Value, texts.Select(t => new ChunkDraft(t, 4, null)).ToList());
        return (store, src.Id!.Value);
    }

    [Fact]
    public async Task ContextIsStoredForEveryChunkOfTheSource()
    {
        var (store, sourceId) = SourceWithChunks("first passage", "second passage", "third passage");
        using var _ = store;
        var chat = new MockChatClient("about ", "coffee");

        await new ContextualEnricher(store, chat, () => "model").EnrichSourceAsync(sourceId);

        var chunks = store.Chunks(sourceId);
        Assert.Equal(3, chunks.Count);
        Assert.All(chunks, c => Assert.Equal("about coffee", c.Context));
    }

    [Fact]
    public async Task ChunksStartWithNoContextSoTheColumnStaysNullUntilEnrichmentRuns()
    {
        var (store, sourceId) = SourceWithChunks("only passage");
        using var _ = store;

        // Enrichment is opt-in; ingest without it must leave the column null so
        // EmbeddingText falls back to the bare chunk text.
        Assert.All(store.Chunks(sourceId), c => Assert.Null(c.Context));
    }

    [Fact]
    public async Task ThePromptCarriesBothTheDocumentPreviewAndTheChunkBeingDescribed()
    {
        var (store, sourceId) = SourceWithChunks("alpha passage", "beta passage");
        using var _ = store;
        var chat = new MockChatClient("ctx");

        await new ContextualEnricher(store, chat, () => "model").EnrichSourceAsync(sourceId);

        // Without the document around it, the model cannot say how a chunk
        // relates to the whole — that relationship is the entire point of D1.
        var prompt = chat.CapturedMessages[0].Single().Content;
        Assert.Contains("<document>", prompt);
        Assert.Contains("<chunk>", prompt);
        Assert.Contains("alpha passage", prompt);
    }

    [Fact]
    public async Task EachChunkIsDescribedAgainstTheSameDocumentPreview()
    {
        var (store, sourceId) = SourceWithChunks("alpha passage", "beta passage");
        using var _ = store;
        var chat = new MockChatClient("ctx");

        await new ContextualEnricher(store, chat, () => "model").EnrichSourceAsync(sourceId);

        // The preview is built once from the head of the document, so every
        // call must see the same <document> block even as <chunk> changes.
        var prompts = chat.CapturedMessages.Select(m => m.Single().Content).ToList();
        Assert.All(prompts, p => Assert.Contains("alpha passage", p));
        Assert.Contains(prompts, p => p.Contains("<chunk>\nbeta passage"));
    }

    [Fact]
    public async Task AnEmptySourceIsSkippedWithoutCallingTheModelAtAll()
    {
        var store = new NotebookStore(StorePath.InMemory);
        using var _ = store;
        var nb = store.CreateNotebook("NB");
        var src = store.CreateSource(nb.Id!.Value, SourceType.Text, "Empty", null, null);
        var chat = new MockChatClient("ctx");

        await new ContextualEnricher(store, chat, () => "model").EnrichSourceAsync(src.Id!.Value);

        Assert.Equal(0, chat.Calls);
    }

    [Fact]
    public async Task TheModelIsResolvedThroughTheGetterSoASettingsSwitchTakesEffect()
    {
        var (store, sourceId) = SourceWithChunks("passage");
        using var _ = store;
        var chat = new RecordingModelChat();

        var current = "first-model";
        await new ContextualEnricher(store, chat, () => current).EnrichSourceAsync(sourceId);
        current = "second-model";
        await new ContextualEnricher(store, chat, () => current).EnrichSourceAsync(sourceId);

        Assert.Equal(new[] { "first-model", "second-model" }, chat.Models.ToArray());
    }

    [Fact]
    public async Task CancellationStopsEnrichmentPartWayThrough()
    {
        var (store, sourceId) = SourceWithChunks("a", "b", "c");
        using var _ = store;
        var chat = new MockChatClient("ctx");
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new ContextualEnricher(store, chat, () => "model").EnrichSourceAsync(sourceId, cts.Token));
    }

    /// Records which model each call used, so the getter indirection is observable.
    private sealed class RecordingModelChat : IChatStreaming
    {
        public List<string> Models { get; } = new();

        public async IAsyncEnumerable<string> StreamAsync(
            string model, IReadOnlyList<ChatTurn> messages,
            [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
        {
            Models.Add(model);
            await Task.Yield();
            yield return "ctx";
        }
    }
}
