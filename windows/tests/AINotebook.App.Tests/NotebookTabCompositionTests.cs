using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.App.Tests;

// Guard against the "page exists but isn't wired to its tab host" class of regression
// (P0 bug in v0.8.0: all 4 tab host Grids contained only placeholder TextBlocks).
//
// Full UI-composition tests that instantiate NotebookDetailPage and verify host Grid
// children require a live WinUI XAML host and cannot run in this headless test project.
// These tests cover the next best thing: the coordinator wiring that drives tab behaviour.

public class NotebookTabCompositionTests
{
    private static readonly Notebook TestNotebook =
        new(Id: 1L, Name: "Test", Description: "", CreatedAt: default, UpdatedAt: default);

    [Theory]
    [InlineData(TabSwitchCoordinator.Tab.Sources)]
    [InlineData(TabSwitchCoordinator.Tab.Chat)]
    [InlineData(TabSwitchCoordinator.Tab.Notes)]
    [InlineData(TabSwitchCoordinator.Tab.Transformations)]
    public void TabSwitchCoordinator_Request_updates_SelectedTab_and_auto_clears(TabSwitchCoordinator.Tab tab)
    {
        var coordinator = new TabSwitchCoordinator();
        using var store = new NotebookStore(StorePath.InMemory);
        var vm = new NotebookDetailViewModel(TestNotebook, coordinator, new StubLocalizedStrings(), store);

        coordinator.Request(tab);

        Assert.Equal(tab, vm.SelectedTab);
        Assert.Null(coordinator.Target); // coordinator auto-clears after VM consumes it
    }

    [Fact]
    public void All_four_tab_values_are_distinct_integers_0_through_3()
    {
        // Ensures Pivot SelectedIndex 0..3 maps unambiguously to each Tab case.
        var values = Enum.GetValues<TabSwitchCoordinator.Tab>().Select(t => (int)t).ToArray();
        Assert.Equal(4, values.Length);
        Assert.Equal([0, 1, 2, 3], values.OrderBy(v => v).ToArray());
    }

    [Fact]
    public void NoteJumpCoordinator_Request_sets_target_and_raises_event()
    {
        var coordinator = new NoteJumpCoordinator();
        long? received = null;
        coordinator.TargetChanged += id => received = id;

        coordinator.Request(42L);

        Assert.Equal(42L, coordinator.Target);
        Assert.Equal(42L, received);
    }

    [Fact]
    public void NoteJumpCoordinator_Clear_resets_target_and_raises_event()
    {
        var coordinator = new NoteJumpCoordinator();
        coordinator.Request(99L);
        long? received = 999L;
        coordinator.TargetChanged += id => received = id;

        coordinator.Clear();

        Assert.Null(coordinator.Target);
        Assert.Null(received);
    }
}

/// Minimal ILocalizedStrings for tests that need a NotebookDetailViewModel.
file sealed class StubLocalizedStrings : ILocalizedStrings
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public string this[string key] => key;
    public string Get(string key) => key;
    public string Get(StringKey key) => key.ToString();
    public void SetLanguage(AppLanguage language) { }
}
