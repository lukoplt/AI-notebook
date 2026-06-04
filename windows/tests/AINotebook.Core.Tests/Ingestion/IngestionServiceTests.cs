using AINotebook.Core;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public class IngestionServiceTests
{
    [Fact]
    public async Task IngestPlainTextEndToEnd()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var dir = Path.Combine(Path.GetTempPath(), "ing-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "memo.txt");
            File.WriteAllText(file, "Hello world. Second sentence.");

            var service = new IngestionService(store);
            var source = await service.IngestFileAsync(new Uri(file), nb.Id!.Value);

            // Refresh status from disk.
            var reloaded = store.Source(source.Id!.Value);
            Assert.NotNull(reloaded);
            Assert.Equal(SourceStatus.Ready, reloaded!.Status);
            Assert.Equal(SourceType.Text, reloaded.Type);
            Assert.Equal("memo", reloaded.Title);

            var chunks = store.Chunks(source.Id!.Value);
            Assert.True(chunks.Count > 0);
            Assert.Equal(0, chunks[0].Ord);
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }

    [Fact]
    public async Task IngestRawTextCreatesPersistedSource()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var service = new IngestionService(store);
        var source = await service.IngestRawTextAsync(
            "My note",
            string.Concat(Enumerable.Repeat("lorem ipsum ", 500)),
            nb.Id!.Value);

        Assert.Equal(SourceStatus.Ready, source.Status);
        Assert.Equal(SourceType.Text, source.Type);
        var chunks = store.Chunks(source.Id!.Value);
        Assert.True(chunks.Count > 1);
    }

    [Fact]
    public async Task IngestUnknownExtensionLeavesNoSourceRow()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("NB");

        var dir = Path.Combine(Path.GetTempPath(), "ing-" + Guid.NewGuid());
        Directory.CreateDirectory(dir);
        try
        {
            var file = Path.Combine(dir, "mystery.bin");
            File.WriteAllBytes(file, new byte[] { 0x01, 0x02, 0x03 });

            var service = new IngestionService(store);
            await Assert.ThrowsAsync<IngestionException.UnsupportedExtension>(
                () => service.IngestFileAsync(new Uri(file), nb.Id!.Value));

            // No source row should have been created.
            Assert.Empty(store.Sources(nb.Id!.Value));
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    }
}
