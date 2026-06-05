using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Rag;

public class FollowupSuggesterTests
{
    // FollowupSuggesterTests.testParsesAndStripsMarkers
    [Fact]
    public async Task ParsesAndStripsMarkers()
    {
        var chat = new MockChatClient("What about X?\n2. How does Y work?\n- Z?");
        var suggester = new FollowupSuggester(chat, "m");

        var questions = await suggester.GenerateAsync("original question", "original answer");

        Assert.Equal(new[] { "What about X?", "How does Y work?", "Z?" }, questions);
    }
}
