using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public class NotebookStoreProvidersTests
{
    private static NotebookStore Fresh() => new(StorePath.InMemory);

    private static ProviderConfig MakeConfig(ProviderType type = ProviderType.OpenAI, string name = "OpenAI") =>
        new(Guid.NewGuid().ToString(), type, name, "https://api.openai.com",
            true, false, DateTime.UtcNow);

    [Fact]
    public void SaveAndFetchRoundTrips()
    {
        using var store = Fresh();
        var cfg = MakeConfig(ProviderType.OpenWebUI, "LAN server") with { BaseUrl = "http://192.168.1.50:3000" };
        store.SaveProvider(cfg);
        var loaded = store.Provider(cfg.Id)!;
        Assert.Equal(ProviderType.OpenWebUI, loaded.Type);
        Assert.Equal("LAN server", loaded.Name);
        Assert.Equal("http://192.168.1.50:3000", loaded.BaseUrl);
        Assert.True(loaded.Enabled);
        Assert.False(loaded.PrivacyAcknowledged);
    }

    // NotebookStoreProvidersTests.testUpdatePreservesPrivacyAcknowledgement (macOS parity)
    [Fact]
    public void UpdatePreservesPrivacyAcknowledgement()
    {
        using var store = Fresh();
        var cfg = MakeConfig(ProviderType.OpenAI, "OpenAI");
        store.SaveProvider(cfg);
        store.AcknowledgePrivacy(cfg.Id);

        // Re-save (e.g. a rename) still carries PrivacyAcknowledged == false,
        // exactly as AddProviderViewModel.SaveConfirmedAsync always constructs
        // cloud-type configs — the store must not let this clobber the flag.
        var renamed = cfg with { Name = "OpenAI renamed" };
        store.SaveProvider(renamed);

        var loaded = store.Provider(cfg.Id)!;
        Assert.Equal("OpenAI renamed", loaded.Name);
        Assert.True(loaded.PrivacyAcknowledged, "edit must not reset the consent flag");
    }

    [Fact]
    public void DeleteRemovesRow()
    {
        using var store = Fresh();
        var cfg = MakeConfig(ProviderType.OpenWebUI, "X") with { BaseUrl = "http://h:3000" };
        store.SaveProvider(cfg);
        store.DeleteProvider(cfg.Id);
        Assert.Null(store.Provider(cfg.Id));
    }

    // Regression: the v11 migration's data step used to seed the built-in
    // Ollama provider's created_at with DateTime.UtcNow.ToString("yyyy-MM-dd
    // HH:mm:ss") — no milliseconds — while SqliteDate.FromDb does a strict
    // ParseExact on "yyyy-MM-dd HH:mm:ss.fff". Every fresh DB (in-memory or
    // on-disk) therefore carried an unreadable seeded row, and Provider()/
    // Providers() threw FormatException the moment they touched it. This
    // must succeed on a brand-new store with no other setup.
    [Fact]
    public void SeededOllamaProvider_IsReadableRightAfterMigration()
    {
        using var store = Fresh();

        var cfg = store.Provider(ProviderConfig.OllamaId);

        Assert.NotNull(cfg);
        Assert.Contains(store.Providers(), p => p.Id == ProviderConfig.OllamaId);
    }
}
