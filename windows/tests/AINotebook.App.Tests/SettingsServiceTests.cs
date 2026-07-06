using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using Xunit;

namespace AINotebook.App.Tests;

// Regression guard for the v0.8.1 silent-launch bug: SettingsService used
// Windows.Storage.ApplicationData.Current, which throws in any process without
// MSIX package identity — including this test host and the shipped unpackaged
// app. Constructing the service here proves the store works without identity.
public class SettingsServiceTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("ainotebook-settings-tests").FullName;

    private string PathFor(string name) => Path.Combine(_dir, name + ".json");

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void Constructs_without_package_identity_and_uses_defaults()
    {
        var s = new SettingsService(PathFor("fresh"));

        Assert.False(s.HasCompletedOnboarding);
        Assert.Equal("llama3.2:3b", s.SelectedChatModel);
        Assert.Equal("nomic-embed-text", s.SelectedEmbeddingModel);
        Assert.Equal(ProviderConfig.OllamaId, s.SelectedChatProviderId);
        Assert.Equal(ProviderConfig.OllamaId, s.SelectedEmbeddingProviderId);
    }

    [Fact]
    public void Values_persist_across_instances()
    {
        var path = PathFor("roundtrip");

        var first = new SettingsService(path);
        first.Language = AppLanguage.Czech;
        first.HasCompletedOnboarding = true;
        first.SelectedChatModel = "gpt-4o-mini";
        first.SelectedEmbeddingModel = "text-embedding-3-small";
        first.SelectedChatProviderId = "11111111-1111-1111-1111-111111111111";
        first.SelectedEmbeddingProviderId = "22222222-2222-2222-2222-222222222222";

        var second = new SettingsService(path);
        Assert.Equal(AppLanguage.Czech, second.Language);
        Assert.True(second.HasCompletedOnboarding);
        Assert.Equal("gpt-4o-mini", second.SelectedChatModel);
        Assert.Equal("text-embedding-3-small", second.SelectedEmbeddingModel);
        Assert.Equal("11111111-1111-1111-1111-111111111111", second.SelectedChatProviderId);
        Assert.Equal("22222222-2222-2222-2222-222222222222", second.SelectedEmbeddingProviderId);
    }

    [Fact]
    public void Corrupt_settings_file_falls_back_to_defaults()
    {
        var path = PathFor("corrupt");
        File.WriteAllText(path, "{ not json !!!");

        var s = new SettingsService(path);

        Assert.False(s.HasCompletedOnboarding);
        Assert.Equal("llama3.2:3b", s.SelectedChatModel);
    }

    [Fact]
    public void Missing_parent_directory_is_not_required_for_reads()
    {
        // Default path creates its directory; a custom path must at least not
        // crash on load when the file is absent.
        var s = new SettingsService(Path.Combine(_dir, "sub", "none.json"));
        Assert.Equal("llama3.2:3b", s.SelectedChatModel);
    }
}
