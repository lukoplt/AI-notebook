using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class SystemPromptTests
{
    // SystemPromptTests.testRendersHitsAsNumberedBlocks
    [Fact]
    public void RendersHitsAsNumberedBlocks()
    {
        var hits = new[]
        {
            new RetrievalHit(1, 1, 0.5f, "alpha facts"),
            new RetrievalHit(2, 1, 0.4f, "beta facts"),
        };
        var prompt = SystemPrompt.Compose(hits);
        Assert.Contains("[1] alpha facts", prompt);
        Assert.Contains("[2] beta facts", prompt);
    }

    // SystemPromptTests.testIncludesCitationInstruction
    [Fact]
    public void IncludesCitationInstruction()
    {
        var prompt = SystemPrompt.Compose(Array.Empty<RetrievalHit>());
        Assert.Contains("cite", prompt.ToLowerInvariant());
        Assert.Contains("[N]", prompt);
    }

    // SystemPromptTests.testNoHitsStillProducesValidPrompt
    [Fact]
    public void NoHitsStillProducesNonEmptyPrompt() =>
        Assert.False(string.IsNullOrEmpty(SystemPrompt.Compose(Array.Empty<RetrievalHit>())));

    // Includes note section when provided (ChatEngineCurrentNoteContextTests companion).
    [Fact]
    public void IncludesNoteSectionWhenProvided()
    {
        var prompt = SystemPrompt.Compose(Array.Empty<RetrievalHit>(), "flour 500g");
        Assert.Contains("CURRENTLY OPEN NOTE", prompt);
        Assert.Contains("flour 500g", prompt);
    }

    [Fact]
    public void OmitsNoteSectionWhenNullOrBlank()
    {
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", SystemPrompt.Compose(Array.Empty<RetrievalHit>(), null));
        Assert.DoesNotContain("CURRENTLY OPEN NOTE", SystemPrompt.Compose(Array.Empty<RetrievalHit>(), "   "));
    }
}
