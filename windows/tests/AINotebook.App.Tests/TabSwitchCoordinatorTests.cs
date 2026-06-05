using AINotebook.App.Services;
using Xunit;

namespace AINotebook.App.Tests;

public class TabSwitchCoordinatorTests
{
    [Fact]
    public void Request_sets_target()
    {
        var c = new TabSwitchCoordinator();
        Assert.Null(c.Target);
        c.Request(TabSwitchCoordinator.Tab.Notes);
        Assert.Equal(TabSwitchCoordinator.Tab.Notes, c.Target);
    }

    [Fact]
    public void Clear_resets_target()
    {
        var c = new TabSwitchCoordinator();
        c.Request(TabSwitchCoordinator.Tab.Chat);
        c.Clear();
        Assert.Null(c.Target);
    }

    [Fact]
    public void Request_raises_property_changed()
    {
        var c = new TabSwitchCoordinator();
        string? changed = null;
        c.PropertyChanged += (_, e) => changed = e.PropertyName;
        c.Request(TabSwitchCoordinator.Tab.Transformations);
        Assert.Equal(nameof(TabSwitchCoordinator.Target), changed);
    }
}
