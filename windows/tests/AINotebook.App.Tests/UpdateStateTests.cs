using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.Core;
using Xunit;

namespace AINotebook.App.Tests;

public class UpdateStateTests
{
    [Fact]
    public void PropertyChanged_fires_for_Available()
    {
        var state = new UpdateState();
        var raised = new List<string?>();
        state.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        state.Available = new UpdateInfo(true, "9.9.9", "https://example.com/download", "https://example.com/notes");

        Assert.Contains(nameof(UpdateState.Available), raised);
        Assert.Equal("9.9.9", state.Available!.LatestVersion);
    }

    [Fact]
    public void PropertyChanged_fires_for_BannerDismissed()
    {
        var state = new UpdateState();
        var raised = new List<string?>();
        state.PropertyChanged += (_, e) => raised.Add(e.PropertyName);

        state.BannerDismissed = true;

        Assert.Contains(nameof(UpdateState.BannerDismissed), raised);
        Assert.True(state.BannerDismissed);
    }
}
