using System.Text.Json;
using AINotebook.Core.Providers;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Microsoft.Data.Sqlite;
using Xunit;
using ProviderModelLimits = AINotebook.Core.Providers.ProviderModelLimits;

namespace AINotebook.Core.Tests.Storage;

public class ProviderModelLimitsStoreTests
{
    [Fact]
    public void FixtureProviderEndpointEditsInvalidateOnlyTheirAutomaticLimits()
    {
        var cases = SharedFixtures.Json("contracts/provider-store-v1.json").GetProperty("cases")
            .EnumerateArray().Where(c => c.TryGetProperty("operation", out var operation) &&
                operation.GetString() == "providerUpdate").ToArray();
        Assert.NotEmpty(cases);
        foreach (var c in cases)
        {
            using var store = new NotebookStore(StorePath.InMemory);
            var id = c.GetProperty("providerId").GetString()!;
            var otherId = c.GetProperty("otherProviderId").GetString()!;
            var model = c.GetProperty("model").GetString()!;
            var before = c.GetProperty("before");
            var after = c.GetProperty("after");
            var provider = new ProviderConfig(id,
                ProviderTypeExtensions.FromStorageString(before.GetProperty("type").GetString()!),
                "Original", before.GetProperty("baseURL").GetString()!, true, true,
                DateTimeOffset.FromUnixTimeSeconds(1_700_000_000).UtcDateTime);
            store.SaveProvider(provider);
            store.SaveProvider(provider with { Id = otherId });
            var automatic = new ProviderModelLimits(id, model, c.GetProperty("contextWindow").GetInt32(),
                c.GetProperty("runtimeContext").GetInt32(), c.GetProperty("maxOutputTokens").GetInt32(), "auto");
            var otherModel = automatic with { Model = model + ":other" };
            var otherProvider = automatic with { ProviderId = otherId };
            var user = automatic with { Model = model + ":user", Source = "user" };
            foreach (var row in new[] { automatic, otherModel, otherProvider, user })
                store.SaveProviderModelLimits(row);

            var updated = provider with
            {
                Type = ProviderTypeExtensions.FromStorageString(after.GetProperty("type").GetString()!),
                BaseUrl = after.GetProperty("baseURL").GetString()!,
                Name = "Renamed", Enabled = false
            };
            store.SaveProvider(updated);

            var retained = c.GetProperty("expectedAutoRetained").GetBoolean();
            Assert.Equal(retained ? automatic : null, store.ProviderModelLimits(id, model));
            Assert.Equal(retained ? otherModel : null, store.ProviderModelLimits(id, otherModel.Model));
            Assert.Equal(user, store.ProviderModelLimits(id, user.Model));
            Assert.Equal(otherProvider, store.ProviderModelLimits(otherId, model));
            Assert.Equal(updated, store.Provider(id));
            if (!retained)
            {
                store.SaveProviderModelLimits(ProviderLimitPolicy.Automatic(id, updated.Type, model,
                    c.GetProperty("refreshedWindow").GetInt32()));
                Assert.Equal(c.GetProperty("expectedRefreshedRuntime").GetInt32(),
                    store.ProviderModelLimits(id, model)!.RuntimeContext);
            }
        }
    }

    [Fact]
    public void Wp3AutomaticWritePreservesUserOverrideAcrossStoreApis()
    {
        var fixture = StoreCase("user-survives-auto");
        using var store = new NotebookStore(StorePath.InMemory);
        var user = UserLimits();
        AddProvider(store, user.ProviderId);
        store.SaveProviderModelLimits(user);
        var automatic = new AINotebook.Core.Storage.ProviderModelLimits(
            user.ProviderId, user.Model, user.ContextWindow,
            fixture.GetProperty("autoRuntime").GetInt32(), 1024, "auto");

        store.SetModelLimits(automatic);

        Assert.Equal(user, store.ProviderModelLimits(user.ProviderId, user.Model));
        var stored = store.ModelLimits(user.ProviderId, user.Model)!;
        Assert.Equal(fixture.GetProperty("expectedRuntime").GetInt32(), stored.RuntimeContext);
        Assert.Equal("user", stored.Source);

        var updated = user with { MaxOutputTokens = user.MaxOutputTokens + 1 };
        store.SetModelLimits(new(updated.ProviderId, updated.Model, updated.ContextWindow,
            updated.RuntimeContext, updated.MaxOutputTokens, updated.Source));
        store.SaveProviderModelLimits(new(automatic.ProviderId, automatic.Model, automatic.ContextWindow,
            automatic.RuntimeContext, automatic.MaxOutputTokens, automatic.Source));
        Assert.Equal(updated, store.ProviderModelLimits(user.ProviderId, user.Model));

        store.DeleteProviderModelLimits(user.ProviderId, user.Model);
        store.SetModelLimits(automatic);
        Assert.Equal(automatic, store.ModelLimits(user.ProviderId, user.Model));
    }

    [Fact]
    public void UserOverrideSurvivesAutoRefresh()
    {
        var c = SharedFixtures.Json("contracts/provider-store-v1.json").GetProperty("cases")
            .EnumerateArray().Single(x => x.GetProperty("name").GetString() == "user-survives-auto");
        using var store = new NotebookStore(StorePath.InMemory);
        var id = c.GetProperty("providerId").GetString()!;
        var model = c.GetProperty("model").GetString()!;
        store.SaveProvider(new(id, ProviderType.Ollama, "P", "http://localhost:11434", true, true, DateTime.UtcNow));
        var user = new ProviderModelLimits(id, model, c.GetProperty("contextWindow").GetInt32(),
            c.GetProperty("runtimeContext").GetInt32(), c.GetProperty("maxOutputTokens").GetInt32(), "user");
        store.SaveProviderModelLimits(user);
        var automatic = ProviderLimitPolicy.Automatic(id, ProviderType.Ollama, model, 32768);
        store.SaveProviderModelLimits(automatic);
        Assert.Equal(user, store.ProviderModelLimits(id, model));
        store.DeleteProviderModelLimits(id, model);
        store.SaveProviderModelLimits(automatic);
        Assert.Equal("auto", store.ProviderModelLimits(id, model)!.Source);
        store.DeleteProvider(id);
        Assert.Null(store.ProviderModelLimits(id, model));
    }

    [Fact]
    public void FixtureProvidersWithTheSameTaggedModelRemainIndependent()
    {
        var c = StoreCase("provider-isolation");
        using var store = new NotebookStore(StorePath.InMemory);
        var ids = c.GetProperty("providerIds").EnumerateArray().Select(x => x.GetString()!).ToArray();
        var runtimes = c.GetProperty("runtimes").EnumerateArray().Select(x => x.GetInt32()).ToArray();
        var model = c.GetProperty("model").GetString()!;
        var rows = ids.Select((id, i) => new ProviderModelLimits(id, model, 32768, runtimes[i], 333, "user")).ToArray();
        foreach (var row in rows)
        {
            AddProvider(store, row.ProviderId);
            store.SaveProviderModelLimits(row);
        }
        foreach (var row in rows) Assert.Equal(row, store.ProviderModelLimits(row.ProviderId, model));

        var edited = rows[0] with { MaxOutputTokens = 444 };
        store.SaveProviderModelLimits(edited);
        Assert.Equal(edited, store.ProviderModelLimits(ids[0], model));
        Assert.Equal(rows[1], store.ProviderModelLimits(ids[1], model));
        store.DeleteProviderModelLimits(ids[0], model);
        Assert.Null(store.ProviderModelLimits(ids[0], model));
        Assert.Equal(rows[1], store.ProviderModelLimits(ids[1], model));
    }

    [Fact]
    public void FixtureProviderDeletionCascadesOnlyItsLimits()
    {
        var c = StoreCase("delete-cascades");
        using var store = new NotebookStore(StorePath.InMemory);
        var id = c.GetProperty("providerId").GetString()!;
        var model = c.GetProperty("model").GetString()!;
        AddProvider(store, id);
        AddProvider(store, "other");
        store.SaveProviderModelLimits(new(id, model, null, 8192, 1024, "auto"));
        var other = new ProviderModelLimits("other", model, null, 8192, 1024, "auto");
        store.SaveProviderModelLimits(other);

        store.DeleteProvider(id);

        Assert.Null(store.ProviderModelLimits(id, model));
        Assert.Equal(other, store.ProviderModelLimits("other", model));
        lock (store.Gate)
        {
            using var cmd = store.Connection.CreateCommand();
            cmd.CommandText = "SELECT count(*) FROM provider_model_limits WHERE provider_id=$id";
            cmd.Parameters.AddWithValue("$id", id);
            Assert.Equal(c.GetProperty("expectedRows").GetInt64(), (long)cmd.ExecuteScalar()!);
        }
    }

    [Fact]
    public void FixtureResetDeletesOverrideAndRestoresAutomaticLimits()
    {
        var c = StoreCase("reset-auto");
        using var store = new NotebookStore(StorePath.InMemory);
        var id = c.GetProperty("providerId").GetString()!;
        var model = c.GetProperty("model").GetString()!;
        AddProvider(store, id);
        store.SaveProviderModelLimits(new(id, model, null, 4096, 333, "user"));
        store.DeleteProviderModelLimits(id, model);
        Assert.Null(store.ProviderModelLimits(id, model));
        store.DeleteProviderModelLimits(id, model);
        var automatic = ProviderLimitPolicy.Automatic(id, ProviderType.Ollama, model, null);
        store.SaveProviderModelLimits(automatic);
        var saved = Assert.IsType<ProviderModelLimits>(store.ProviderModelLimits(id, model));
        Assert.Equal(c.GetProperty("expectedSource").GetString(), saved.Source);
        Assert.Equal(c.GetProperty("expectedRuntime").GetInt32(), saved.RuntimeContext);
        Assert.True(saved.IsAssumed);
    }

    [Fact]
    public void InvalidLimitsNeverOverwriteExistingRows()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var valid = UserLimits();
        AddProvider(store, valid.ProviderId);
        store.SaveProviderModelLimits(valid);
        var invalid = new List<ProviderModelLimits>
        {
            valid with { ProviderId = "" },
            valid with { ProviderId = " \t" },
            valid with { Model = "" },
            valid with { Model = " \t\n" },
            valid with { ContextWindow = 0 },
            valid with { RuntimeContext = -1 },
            valid with { MaxOutputTokens = -1 },
            valid with { MaxOutputTokens = valid.RuntimeContext + 1 },
            valid with { Source = "" },
            valid with { Source = "AUTO" },
            valid with { Source = "imported" }
        };
        foreach (var c in SharedFixtures.Json("contracts/provider-limits-v1.json").GetProperty("cases").EnumerateArray())
        {
            if (!c.TryGetProperty("user", out var user)) continue;
            invalid.Add(valid with
            {
                ContextWindow = c.GetProperty("window").ValueKind == JsonValueKind.Null ? null : c.GetProperty("window").GetInt32(),
                RuntimeContext = user.GetProperty("runtimeContext").GetInt32(),
                MaxOutputTokens = user.GetProperty("maxOutputTokens").GetInt32()
            });
        }
        foreach (var row in invalid)
        {
            Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(() => store.SaveProviderModelLimits(row)).Code);
            Assert.Equal(valid, store.ProviderModelLimits(valid.ProviderId, valid.Model));
        }
    }

    [Fact]
    public void MissingProviderCannotOwnLimits()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var row = UserLimits() with { ProviderId = "missing-provider" };
        var error = Assert.Throws<SqliteException>(() => store.SaveProviderModelLimits(row));
        Assert.Equal(19, error.SqliteErrorCode);
        Assert.Equal(787, error.SqliteExtendedErrorCode);
        Assert.Null(store.ProviderModelLimits(row.ProviderId, row.Model));
    }

    [Fact]
    public void DatabaseChecksRejectInvalidRows()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var valid = UserLimits();
        AddProvider(store, valid.ProviderId);
        store.SaveProviderModelLimits(valid);
        var invalid = new[]
        {
            valid with { Model = " " },
            valid with { ContextWindow = 0 },
            valid with { ContextWindow = -1 },
            valid with { RuntimeContext = 0 },
            valid with { RuntimeContext = -1 },
            valid with { MaxOutputTokens = 0 },
            valid with { MaxOutputTokens = -1 },
            valid with { MaxOutputTokens = valid.RuntimeContext },
            valid with { MaxOutputTokens = valid.RuntimeContext + 1 },
            valid with { RuntimeContext = valid.ContextWindow!.Value + 1 },
            valid with { Source = "unknown" }
        };
        lock (store.Gate)
        {
            foreach (var row in invalid)
            {
                using var cmd = store.Connection.CreateCommand();
                cmd.CommandText = """
                    UPDATE provider_model_limits SET model=$model,context_window=$window,
                        runtime_context=$runtime,max_output_tokens=$output,source=$source
                    WHERE provider_id=$id AND model=$originalModel
                    """;
                cmd.Parameters.AddWithValue("$model", row.Model);
                cmd.Parameters.AddWithValue("$window", (object?)row.ContextWindow ?? DBNull.Value);
                cmd.Parameters.AddWithValue("$runtime", row.RuntimeContext);
                cmd.Parameters.AddWithValue("$output", row.MaxOutputTokens);
                cmd.Parameters.AddWithValue("$source", row.Source);
                cmd.Parameters.AddWithValue("$id", valid.ProviderId);
                cmd.Parameters.AddWithValue("$originalModel", valid.Model);
                Assert.Equal(19, Assert.Throws<SqliteException>(() => cmd.ExecuteNonQuery()).SqliteErrorCode);
            }
        }
        Assert.Equal(valid, store.ProviderModelLimits(valid.ProviderId, valid.Model));
    }

    [Fact]
    public void LimitsAndDeletionSurviveDiskReopen()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"ainotebook-provider-limits-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = new StorePath(Path.Combine(directory, "limits.sqlite"));
        var user = UserLimits();
        var automatic = new ProviderModelLimits(user.ProviderId, "unlisted:tag", null, 8192, 1024, "auto");
        try
        {
            using (var store = new NotebookStore(path))
            {
                AddProvider(store, user.ProviderId);
                store.SaveProviderModelLimits(user);
                store.SaveProviderModelLimits(automatic);
            }
            using (var store = new NotebookStore(path))
            {
                Assert.Equal(user, store.ProviderModelLimits(user.ProviderId, user.Model));
                Assert.Equal(automatic, store.ProviderModelLimits(automatic.ProviderId, automatic.Model));
                store.SaveProviderModelLimits(user with { RuntimeContext = 8192, Source = "auto" });
                Assert.Equal(user, store.ProviderModelLimits(user.ProviderId, user.Model));
                store.DeleteProviderModelLimits(automatic.ProviderId, automatic.Model);
            }
            using (var store = new NotebookStore(path))
            {
                Assert.Equal(user, store.ProviderModelLimits(user.ProviderId, user.Model));
                Assert.Null(store.ProviderModelLimits(automatic.ProviderId, automatic.Model));
            }
        }
        finally { Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public async Task ParallelReadsWritesAndDeletesLeaveValidIndependentRows()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var template = UserLimits();
        AddProvider(store, template.ProviderId);
        var rows = Enumerable.Range(0, 24).Select(i => template with { Model = $"{template.Model}:{i}" }).ToArray();
        await Task.WhenAll(rows.Select(row => Task.Run(() =>
        {
            for (var attempt = 0; attempt < 12; attempt++)
            {
                store.SaveProviderModelLimits(row);
                store.SaveProviderModelLimits(row with { RuntimeContext = 8192, Source = "auto" });
                Assert.Equal(row, store.ProviderModelLimits(row.ProviderId, row.Model));
                store.DeleteProviderModelLimits(row.ProviderId, row.Model);
                Assert.Null(store.ProviderModelLimits(row.ProviderId, row.Model));
            }
            store.SaveProviderModelLimits(row);
        })));
        foreach (var row in rows)
        {
            var actual = Assert.IsType<ProviderModelLimits>(store.ProviderModelLimits(row.ProviderId, row.Model));
            actual.Validate();
            Assert.Equal(row, actual);
        }
    }

    [Fact]
    public void ReadsValidateStoredLimits()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var row = UserLimits();
        AddProvider(store, row.ProviderId);
        store.SaveProviderModelLimits(row);
        lock (store.Gate)
        {
            using var cmd = store.Connection.CreateCommand();
            cmd.CommandText = "PRAGMA ignore_check_constraints=ON";
            cmd.ExecuteNonQuery();
            try
            {
                cmd.CommandText = "UPDATE provider_model_limits SET max_output_tokens=runtime_context WHERE provider_id=$id AND model=$model";
                cmd.Parameters.AddWithValue("$id", row.ProviderId);
                cmd.Parameters.AddWithValue("$model", row.Model);
                Assert.Equal(1, cmd.ExecuteNonQuery());
            }
            finally
            {
                cmd.Parameters.Clear();
                cmd.CommandText = "PRAGMA ignore_check_constraints=OFF";
                cmd.ExecuteNonQuery();
            }
        }
        Assert.Equal("invalidLimits", Assert.Throws<ProviderConfigurationException>(() => store.ProviderModelLimits(row.ProviderId, row.Model)).Code);
    }

    private static JsonElement StoreCase(string name) => SharedFixtures.Json("contracts/provider-store-v1.json")
        .GetProperty("cases").EnumerateArray().Single(x => x.GetProperty("name").GetString() == name);

    private static ProviderModelLimits UserLimits()
    {
        var c = StoreCase("user-survives-auto");
        return new(c.GetProperty("providerId").GetString()!, c.GetProperty("model").GetString()!,
            c.GetProperty("contextWindow").GetInt32(), c.GetProperty("runtimeContext").GetInt32(),
            c.GetProperty("maxOutputTokens").GetInt32(), c.GetProperty("source").GetString()!);
    }

    private static void AddProvider(NotebookStore store, string id) =>
        store.SaveProvider(new(id, ProviderType.Ollama, id, "http://localhost:11434", true, true, DateTime.UtcNow));
}
