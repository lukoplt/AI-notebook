using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>Shared <c>ingestion-memory-pressure-v1</c> fixture: graded admission and probe mappings.</summary>
public sealed class MemoryPressureContractTests
{
    private static IReadOnlyList<JsonElement> Cases(string operation)
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-memory-pressure-v1.json");
        Assert.Equal("ingestion-memory-pressure", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        Assert.Equal(MemoryPressureLevels.WarningLoadPercent, fixture.GetProperty("warningLoadPercent").GetInt32());
        Assert.Equal(MemoryPressureLevels.CriticalLoadPercent, fixture.GetProperty("criticalLoadPercent").GetInt32());
        return fixture.GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("operation").GetString() == operation).ToArray();
    }

    private static MemoryPressureLevel Level(string name) => Enum.Parse<MemoryPressureLevel>(name, ignoreCase: true);

    [Fact]
    public async Task AdmissionTracesMatchFixture()
    {
        var rows = Cases("admission");
        Assert.True(rows.Count >= 10);
        foreach (var row in rows)
        {
            string name = row.GetProperty("name").GetString()!;
            var input = row.GetProperty("input");
            var admission = new IngestionAdmission(input.GetProperty("maxExtractions").GetInt32(), input.GetProperty("memoryBytes").GetInt64());
            // Requests in issue order; a waiter's token is known only once granted.
            var requests = new List<(string Id, Task<Guid> Task)>();
            foreach (var e in input.GetProperty("events").EnumerateArray())
            {
                string op = e.GetProperty("operation").GetString()!;
                switch (op)
                {
                    case "pressure": admission.SetMemoryPressure(Level(e.GetProperty("level").GetString()!)); break;
                    case "blocked": admission.SetMemoryPressure(e.GetProperty("blocked").GetBoolean()); break;
                    case "acquire":
                        requests.Add((e.GetProperty("requestId").GetString()!, admission.AcquireExtractionAsync(e.GetProperty("bytes").GetInt64())));
                        break;
                    case "release":
                        string id = e.GetProperty("requestId").GetString()!;
                        admission.ReleaseExtraction(await requests.Single(r => r.Id == id).Task);
                        break;
                    default: Assert.Fail($"{name}: unknown operation {op}"); break;
                }
                // Grants set their task results synchronously (only continuations run asynchronously).
                var tokens = admission.ReservationTokens;
                var granted = requests.Where(r => r.Task.IsCompletedSuccessfully).ToDictionary(r => r.Task.Result, r => r.Id);
                var actual = new JsonObject
                {
                    ["level"] = MemoryPressureLevels.ContractName(admission.PressureLevel),
                    ["reservations"] = new JsonArray(tokens.Select(t => (JsonNode)JsonValue.Create(granted[t])!).ToArray()),
                    ["waiters"] = new JsonArray(requests.Where(r => !r.Task.IsCompleted).Select(r => (JsonNode)JsonValue.Create(r.Id)!).ToArray())
                };
                var expected = JsonNode.Parse(e.GetProperty("expected").GetRawText());
                Assert.True(JsonNode.DeepEquals(expected, actual), $"{name} {op}: expected {expected!.ToJsonString()} got {actual.ToJsonString()}");
            }
        }
    }

    [Fact]
    public void DarwinLevelMatchesFixture()
    {
        var rows = Cases("darwin-level");
        Assert.True(rows.Count >= 5);
        foreach (var row in rows)
            Assert.True(row.GetProperty("expected").GetString() ==
                MemoryPressureLevels.ContractName(MemoryPressureLevels.FromDarwin(row.GetProperty("input").GetInt32())),
                row.GetProperty("name").GetString());
    }

    [Fact]
    public void MemoryLoadMatchesFixture()
    {
        var rows = Cases("memory-load");
        Assert.True(rows.Count >= 5);
        foreach (var row in rows)
            Assert.True(row.GetProperty("expected").GetString() ==
                MemoryPressureLevels.ContractName(MemoryPressureLevels.FromMemoryLoad(row.GetProperty("input").GetInt32())),
                row.GetProperty("name").GetString());
    }

    [Fact]
    public void SampleWindowsFailsOpenOffWindows()
    {
        if (!OperatingSystem.IsWindows()) Assert.Equal(MemoryPressureLevel.Normal, MemoryPressureLevels.SampleWindows());
        else Assert.True(Enum.IsDefined(MemoryPressureLevels.SampleWindows()));
    }
}
