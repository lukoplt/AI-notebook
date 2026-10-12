using AINotebook.App.Chat;
using AINotebook.App.ViewModels;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>UI redesign W2: Markdown render plan, composer chips and the chat thread XAML contract.</summary>
public sealed class ChatSurfaceTests
{
    [Fact]
    public void RenderPlanFlattensInlineMarkupAndKeepsCitations()
    {
        var plan = MarkdownRenderPlan.Build("# Shrnutí\n\nTo je **tučně a *kurzíva*** s `kódem` a [odkazem](https://example.com) [12].");
        Assert.Equal(RenderBlockKind.Heading, plan[0].Kind);
        Assert.Equal(1, plan[0].Level);
        var spans = plan[1].Spans;
        Assert.Contains(spans, s => s is { Text: "tučně a ", Strong: true, Emphasis: false });
        Assert.Contains(spans, s => s is { Text: "kurzíva", Strong: true, Emphasis: true });
        Assert.Contains(spans, s => s is { Text: "kódem", Code: true });
        Assert.Contains(spans, s => s is { Text: "odkazem", Href: "https://example.com" });
        var cite = Assert.Single(spans, s => s.Cite is not null);
        Assert.Equal((12, "[12]"), (cite.Cite!.Value, cite.Text));
    }

    [Fact]
    public void RenderPlanListsQuotesCodeAndRules()
    {
        var plan = MarkdownRenderPlan.Build("3. one\n4. two\n   - nested\n\n> quoted\n\n```\ncode\n```\n\n---\n\n- a");
        Assert.Equal(new[] { "3.", "4.", "◦" }, plan.Take(3).Select(b => b.Marker));
        Assert.Equal(new[] { 1, 1, 2 }, plan.Take(3).Select(b => b.Level));
        Assert.Equal(RenderBlockKind.Quote, plan[3].Kind);
        Assert.Equal(("code", RenderBlockKind.Code), (plan[4].CodeText, plan[4].Kind));
        Assert.Equal(RenderBlockKind.Rule, plan[5].Kind);
        Assert.Equal("•", plan[6].Marker);
    }

    [Fact]
    public void RenderPlanToleratesEveryStreamingPrefix()
    {
        const string answer = "**Odpověď** podle [1] a `kódu`\n\n- bod *jedna*\n- bod [dva](https://x.cz)\n\n```\nlet x";
        for (int i = 0; i <= answer.Length; i++)
            Assert.NotNull(MarkdownRenderPlan.Build(answer[..i]));
        // Unsafe schemes stay literal text, never a link.
        Assert.DoesNotContain(MarkdownRenderPlan.Build("[x](javascript:alert(1))")[0].Spans, s => s.Href is not null);
    }

    [Fact]
    public void ModelChipShowsProviderNameAndPersonaModelWins()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var settings = new MemorySettings { SelectedChatModel = "llama3.2:3b" };
        string ollama = store.Providers().First(p => p.Id == ProviderConfig.OllamaId).Name;
        Assert.Equal($"{ollama} · llama3.2:3b", ModelChip.Format(store, settings, null));
        Assert.Equal($"{ollama} · qwen3:8b", ModelChip.Format(store, settings, $"{ProviderConfig.OllamaId}:qwen3:8b"));
        Assert.Equal("missing · m", ModelChip.Format(store, settings, "missing:m"));
    }

    [Fact]
    public void ChatThreadXamlHasComposerChipsAndNoHardCodedColours()
    {
        string root = ShellNavigationTests.AppRoot();
        string xaml = File.ReadAllText(Path.Combine(root, "Chat", "ChatThreadPage.xaml"));
        foreach (string name in new[] { "InputBox", "AddMenuButton", "AddFileItem", "AddFolderItem", "AddUrlItem", "WebSearchItem",
            "OverviewItem", "RunToolSubItem", "NewNoteItem", "ScopeButton", "PersonaButton", "ModelButton", "PreviewContextButton",
            "SendButton", "NewChatHero", "NotebookPickerButton", "QuietActions", "ErrorRow", "RetryButton", "FollowupList",
            "EditCard", "PendingUserBlock" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        // Web search appears only when enabled in Settings; Overview stays per message.
        Assert.Contains("Visibility=\"{x:Bind ViewModel.ShowWebSearchOption, Mode=OneWay, Converter={StaticResource BoolToVisibility}}\"", xaml);
        Assert.Contains("IsChecked=\"{x:Bind ViewModel.OverviewForNextMessage, Mode=TwoWay}\"", xaml);
        Assert.Contains("Visibility=\"{x:Bind ViewModel.HasPersonas, Mode=OneWay, Converter={StaticResource BoolToVisibility}}\"", xaml);
        string row = File.ReadAllText(Path.Combine(root, "Controls", "MessageRow.xaml"));
        foreach (string xamlText in new[] { xaml, row })
        {
            Assert.DoesNotContain("Foreground=\"Red\"", xamlText);
            Assert.DoesNotContain("#FF", xamlText);
            Assert.DoesNotContain("Segoe MDL2", xamlText);
        }
        Assert.False(File.Exists(Path.Combine(root, "Controls", "MessageBubble.xaml")));
        Assert.False(File.Exists(Path.Combine(root, "Views", "ChatPage.xaml")));
    }
}
