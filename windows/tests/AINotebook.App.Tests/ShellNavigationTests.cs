using System.ComponentModel;
using System.Runtime.CompilerServices;
using AINotebook.App.Services;
using AINotebook.App.Shell;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>
/// UI redesign shell (spec §2): navigation state, the Core-era coordinator mapping (§2.7) and the
/// sidebar projection. Pure view-model logic, no WinUI window. Replaces NotebookTabCompositionTests
/// (the Pivot tabs no longer exist).
/// </summary>
public sealed class ShellNavigationTests
{
    [Fact]
    public async Task TabRequestsMapOntoPanelThreadAndRunTool()
    {
        var nav = new NavigationState();
        await nav.NavigateAsync(new ShellSelection.Chat(1, 10));
        int runTool = 0;
        nav.RunToolRequested += () => runTool++;

        await nav.ApplyAsync(TabSwitchCoordinator.Tab.Sources);
        Assert.Equal(PanelSegment.Sources, nav.Panel);
        await nav.ApplyAsync(TabSwitchCoordinator.Tab.Notes);
        Assert.Equal(PanelSegment.Notes, nav.Panel);
        await nav.ApplyAsync(TabSwitchCoordinator.Tab.Transformations);
        Assert.Equal(1, runTool);

        // Chat returns from a document to the thread it was opened from.
        await nav.NavigateAsync(new ShellSelection.Note(1, 5));
        await nav.ApplyAsync(TabSwitchCoordinator.Tab.Chat);
        Assert.Equal(new ShellSelection.Chat(1, 10), nav.Selection);
    }

    [Fact]
    public void EveryTabHasAMapping()
    {
        // A new Tab case must be mapped in NavigationState.ApplyAsync (spec §2.7 is binding).
        Assert.Equal(4, Enum.GetValues<TabSwitchCoordinator.Tab>().Length);
    }

    [Fact]
    public async Task ShellConsumesCoordinatorsAndClearsThem()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long nb = store.CreateNotebook("A").Id!.Value;
        long note = store.CreateNote(nb, "n", "body").Id!.Value;
        var tabs = new TabSwitchCoordinator();
        var jump = new NoteJumpCoordinator();
        var shell = new ShellViewModel(new SidebarViewModel(store, new KeyStrings()), store, tabs, jump, new MemorySettings());
        Assert.Equal(new ShellSelection.NewChat(nb), shell.Navigation.Selection);

        tabs.Request(TabSwitchCoordinator.Tab.Sources);
        Assert.Null(tabs.Target);
        Assert.Equal(PanelSegment.Sources, shell.Navigation.Panel);

        // Citation "Open note" / tool result / search: the note opens as a document.
        jump.Request(note);
        await Task.Yield();
        Assert.Null(jump.Target);
        Assert.Equal(new ShellSelection.Note(nb, note), shell.Navigation.Selection);
    }

    [Fact]
    public async Task BackReturnsFromSettingsAndDocuments()
    {
        var nav = new NavigationState();
        await nav.NavigateAsync(new ShellSelection.Chat(1, 10));
        await nav.NavigateAsync(new ShellSelection.Note(1, 5));
        await nav.NavigateAsync(new ShellSelection.Settings(SettingsSection.Providers));
        Assert.Equal(1L, nav.NotebookId); // settings keep the notebook context

        Assert.True(await nav.GoBackAsync());
        Assert.Equal(new ShellSelection.Note(1, 5), nav.Selection);
        Assert.True(await nav.GoBackAsync());
        Assert.Equal(new ShellSelection.Chat(1, 10), nav.Selection);
        Assert.False(await nav.GoBackAsync()); // a thread is the root

        // A document of another notebook goes back to that notebook's new chat.
        await nav.NavigateAsync(new ShellSelection.Note(2, 7));
        await nav.GoBackAsync();
        Assert.Equal(new ShellSelection.NewChat(2), nav.Selection);
    }

    [Fact]
    public async Task LeaveGuardProtectsOnlyAnOpenNote()
    {
        var nav = new NavigationState();
        int asked = 0;
        bool allow = false;
        nav.LeaveGuard = () => { asked++; return Task.FromResult(allow); };

        Assert.True(await nav.NavigateAsync(new ShellSelection.Chat(1, 10)));
        Assert.Equal(0, asked);
        Assert.True(await nav.NavigateAsync(new ShellSelection.Note(1, 5)));
        Assert.False(await nav.NavigateAsync(new ShellSelection.Chat(1, 10)));
        Assert.Equal(new ShellSelection.Note(1, 5), nav.Selection);
        allow = true;
        Assert.True(await nav.NavigateAsync(new ShellSelection.Chat(1, 10)));
        Assert.Equal(2, asked);
        // Replace (a new chat became a real thread) never prompts.
        nav.Replace(new ShellSelection.Chat(1, 11));
        Assert.Equal(2, asked);
    }

    [Fact]
    public async Task PanelRemembersSegmentAndNoteChatTakesTheContextSlotInDocuments()
    {
        var nav = new NavigationState(PanelSegment.Citations);
        Assert.Equal(PanelSegment.Citations, nav.Panel);
        nav.TogglePanel();
        Assert.Null(nav.Panel);
        nav.TogglePanel();
        Assert.Equal(PanelSegment.Citations, nav.Panel);

        // Outside a note the note chat resolves to Context; inside a note Context resolves to the note chat.
        nav.ShowPanel(PanelSegment.NoteChat);
        Assert.Equal(PanelSegment.Context, nav.Panel);
        await nav.NavigateAsync(new ShellSelection.Note(1, 5));
        Assert.Equal(PanelSegment.NoteChat, nav.Panel);
        await nav.NavigateAsync(new ShellSelection.Chat(1, 10));
        Assert.Equal(PanelSegment.Context, nav.Panel);

        Assert.Equal(PanelSegment.Context, new NavigationState(PanelSegment.NoteChat).Panel); // remembered across launches
        Assert.Equal(PanelSegment.Sources, NavigationState.Resolve(PanelSegment.Sources, document: true));
    }

    [Fact]
    public void SidebarGroupsNotebooksAndCapsChatsAtEight()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long a = store.CreateNotebook("A").Id!.Value;
        long b = store.CreateNotebook("B").Id!.Value;
        for (int i = 0; i < 10; i++) store.CreateChatSession(a, "chat " + i);
        store.CreateChatSession(b, "only");
        var sidebar = new SidebarViewModel(store, new KeyStrings());

        // Collapsed by default: headers only.
        Assert.All(sidebar.Rows, row => Assert.IsType<SidebarNotebookRow>(row));
        Assert.Equal(2, sidebar.Rows.Count);

        sidebar.Toggle(a);
        var chats = sidebar.Rows.OfType<SidebarChatRow>().ToList();
        Assert.Equal(SidebarViewModel.VisibleChats, chats.Count);
        Assert.Equal("chat 9", chats[0].Title); // newest first
        int header = sidebar.Rows.ToList().FindIndex(r => r is SidebarNotebookRow n && n.NotebookId == a);
        var more = Assert.IsType<SidebarMoreRow>(sidebar.Rows[header + 1 + SidebarViewModel.VisibleChats]);
        Assert.Equal("ShellShowMore", more.Label);

        sidebar.ToggleShowAll(a);
        Assert.Equal(10, sidebar.Rows.OfType<SidebarChatRow>().Count());
        Assert.Equal("ShellShowLess", sidebar.Rows.OfType<SidebarMoreRow>().Single().Label);

        // Selecting an old chat expands its notebook, reveals it and highlights only that row.
        sidebar.ToggleShowAll(a);
        long oldest = store.ChatSessions(a).Last().Id!.Value;
        sidebar.SetActive(new ShellSelection.Chat(a, oldest));
        Assert.Single(sidebar.Rows.OfType<SidebarChatRow>(), r => r.IsActive);
        Assert.True(sidebar.Rows.OfType<SidebarChatRow>().Single(r => r.IsActive).SessionId == oldest);

        // New-chat state highlights the notebook header.
        sidebar.SetActive(new ShellSelection.NewChat(b));
        Assert.True(sidebar.Rows.OfType<SidebarNotebookRow>().Single(r => r.NotebookId == b).IsActive);
        Assert.DoesNotContain(sidebar.Rows.OfType<SidebarChatRow>(), r => r.IsActive);
    }

    [Fact]
    public void ChatDeleteAndNotebookRemovalPickTheNextSelection()
    {
        // Same rule as Swift ShellNavigation.selectionAfterDeleting: next (older), else previous, else none.
        Assert.Equal(3L, SidebarViewModel.SelectionAfterDeleting(2, [1, 2, 3]));
        Assert.Equal(2L, SidebarViewModel.SelectionAfterDeleting(3, [1, 2, 3]));
        Assert.Null(SidebarViewModel.SelectionAfterDeleting(1, [1]));
        Assert.Null(SidebarViewModel.SelectionAfterDeleting(9, [1, 2]));

        using var store = new NotebookStore(StorePath.InMemory);
        long a = store.CreateNotebook("A").Id!.Value;
        long first = store.CreateChatSession(a, "first").Id!.Value;
        long second = store.CreateChatSession(a, "second").Id!.Value;
        var sidebar = new SidebarViewModel(store, new KeyStrings());
        Assert.Equal(new ShellSelection.Chat(a, first), sidebar.DeleteChat(a, second, null));
        Assert.Equal(new ShellSelection.NewChat(a), sidebar.DeleteChat(a, first, null));

        Assert.Equal(new ShellSelection.Empty(), sidebar.DeleteNotebook(a));
        Assert.False(sidebar.HasNotebooks);
    }

    [Fact]
    public void ChatRenameTrimsIgnoresBlankAndRefreshesTheSidebar()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        long a = store.CreateNotebook("A").Id!.Value;
        long chat = store.CreateChatSession(a, "Old").Id!.Value;
        var sidebar = new SidebarViewModel(store, new KeyStrings());
        sidebar.SetActive(new ShellSelection.Chat(a, chat));

        Assert.True(sidebar.RenameChat(a, chat, "  Q3 review \n"));
        Assert.Equal("Q3 review", sidebar.Sessions(a).Single().Title);
        Assert.Equal("Q3 review", sidebar.Rows.OfType<SidebarChatRow>().Single().Title);
        Assert.True(sidebar.Rows.OfType<SidebarChatRow>().Single().IsActive);

        Assert.False(sidebar.RenameChat(a, chat, "   "));
        Assert.False(sidebar.RenameChat(a, chat, "Q3 review"));
        Assert.Equal("Q3 review", store.ChatSessions(a).Single().Title);

        // Sidebar flyout, top bar "…" and a double-click on the thread title all rename.
        string code = File.ReadAllText(Path.Combine(AppRoot(), "Shell", "ShellPage.xaml.cs"));
        Assert.Contains("Item(StringKey.RenameChat, \"IconEdit\"", code);
        string xaml = File.ReadAllText(Path.Combine(AppRoot(), "Shell", "ShellPage.xaml"));
        Assert.Contains("DoubleTapped=\"OnThreadTitleDoubleTapped\"", xaml);
    }

    [Theory]
    [InlineData("What is in the Q3 report?", "What is in the Q3 report?")]
    [InlineData("  Shrň\n\nmi   přílohy ", "Shrň mi přílohy")]
    [InlineData("", "New chat")]
    [InlineData("Compare the attached contracts and list every clause that differs between them",
        "Compare the attached contracts and list every c…")]
    public void NewChatsAreTitledAfterTheFirstQuestion(string question, string title)
    {
        string result = ChatTitles.FromQuestion(question, "New chat");
        Assert.Equal(title, result);
        Assert.True(result.Length <= ChatTitles.MaxLength);
    }

    [Fact]
    public void ShellXamlHasSidebarMainAreaAndPanelSegments()
    {
        string xaml = File.ReadAllText(Path.Combine(AppRoot(), "Shell", "ShellPage.xaml"));
        foreach (string name in new[] { "NewChatButton", "SearchButton", "SidebarList", "NewNotebookButton", "UpdateIndicator",
            "SettingsButton", "TopBar", "MainHost", "AppEmptyState", "RightPanel", "PanelTabs", "TabSources", "TabNotes",
            "TabContext", "TabCitations", "TabNoteChat", "PanelHost" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        Assert.Contains("ItemsSource=\"{x:Bind ViewModel.Sidebar.Rows, Mode=OneWay}\"", xaml);
        // Ctrl+N new chat, Ctrl+Shift+N new notebook, Ctrl+K search, Ctrl+Alt+0 panel, Alt+Left back (Ctrl+, in code).
        foreach (string accelerator in new[] { "Modifiers=\"Control\" Key=\"N\"", "Modifiers=\"Control,Shift\" Key=\"N\"",
                     "Modifiers=\"Control\" Key=\"K\"", "Modifiers=\"Control,Menu\" Key=\"Number0\"", "Modifiers=\"Menu\" Key=\"Left\"" })
            Assert.Contains(accelerator, xaml);
        Assert.Contains("(VirtualKey)188", File.ReadAllText(Path.Combine(AppRoot(), "Shell", "ShellPage.xaml.cs")));
        // The window hosts Mica and no menu bar (Save/History moved to the document top bar).
        string window = File.ReadAllText(Path.Combine(AppRoot(), "MainWindow.xaml"));
        Assert.Contains("<MicaBackdrop />", window);
        Assert.DoesNotContain("MenuBar", window);
        // Views use tokens only.
        Assert.DoesNotContain("#FF", xaml);
        Assert.DoesNotContain("Segoe MDL2", xaml);
        string app = File.ReadAllText(Path.Combine(AppRoot(), "App.xaml"));
        Assert.Contains("ms-appx:///Styles/Controls.xaml", app);
    }

    internal static string AppRoot([CallerFilePath] string here = "")
    {
        for (var dir = new DirectoryInfo(Path.GetDirectoryName(here)!); dir is not null; dir = dir.Parent)
        {
            string candidate = Path.Combine(dir.FullName, "windows", "src", "AINotebook.App");
            if (Directory.Exists(candidate)) return candidate;
        }
        throw new DirectoryNotFoundException("App sources not found from " + here);
    }
}

/// <summary>Returns the key itself, so tests assert which string was chosen.</summary>
internal sealed class KeyStrings : ILocalizedStrings
{
    public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
    public string this[string key] => key;
    public string Get(string key) => key;
    public string Get(StringKey key) => key.ToString();
    public void SetLanguage(AppLanguage language) { }
}

/// <summary>In-memory ISettingsService for shell tests.</summary>
internal sealed class MemorySettings : ISettingsService
{
    public event PropertyChangedEventHandler? PropertyChanged { add { } remove { } }
    public AppLanguage Language { get; set; } = AppLanguage.English;
    public bool HasCompletedOnboarding { get; set; } = true;
    public string SelectedChatModel { get; set; } = "llama3.2:3b";
    public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
    public string SelectedChatProviderId { get; set; } = ProviderConfig.OllamaId;
    public string SelectedEmbeddingProviderId { get; set; } = ProviderConfig.OllamaId;
    public bool AutoCheckUpdates { get; set; } = true;
    public DateTimeOffset? LastUpdateCheckUtc { get; set; }
    public bool WebSearchEnabled { get; set; }
    public string RightPanel { get; set; } = "";
    public double RightPanelWidth { get; set; } = 360;
}
