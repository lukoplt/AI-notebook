using System.Text.Json;
using System.Text.Json.Nodes;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

/// <summary>
/// Shared <c>ingestion-adaptive-concurrency-v1</c> fixture (contract <c>ingestion-memory-pressure-v1</c> addendum A):
/// capacity, target, governor, adaptive admission and probe mappings.
/// </summary>
public sealed class AdaptiveConcurrencyContractTests
{
    private static JsonElement Fixture()
    {
        var fixture = SharedFixtures.Json("contracts/ingestion-adaptive-concurrency-v1.json");
        Assert.Equal("ingestion-adaptive-concurrency", fixture.GetProperty("contract").GetString());
        Assert.Equal(1, fixture.GetProperty("version").GetInt32());
        return fixture;
    }

    private static IReadOnlyList<JsonElement> Cases(string operation) =>
        Fixture().GetProperty("cases").EnumerateArray().Where(c => c.GetProperty("operation").GetString() == operation).ToArray();

    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;

    [Fact]
    public void ConstantsMatchFixture()
    {
        var f = Fixture();
        Assert.Equal(AdaptiveConcurrency.MaxWorkersCap, f.GetProperty("maxWorkers").GetInt32());
        Assert.Equal(AdaptiveConcurrency.InitialWorkers, f.GetProperty("initialWorkers").GetInt32());
        Assert.Equal(AdaptiveConcurrency.BatteryWorkers, f.GetProperty("batteryWorkers").GetInt32());
        Assert.Equal(AdaptiveConcurrency.BusyWorkers, f.GetProperty("busyWorkers").GetInt32());
        Assert.Equal(AdaptiveConcurrency.ConstrainedWorkers, f.GetProperty("constrainedWorkers").GetInt32());
        Assert.Equal(AdaptiveConcurrency.MaxHashWidth, f.GetProperty("maxHashWidth").GetInt32());
        Assert.Equal(AdaptiveConcurrency.MinBudgetBytes, f.GetProperty("minBudgetBytes").GetInt64());
        Assert.Equal(AdaptiveConcurrency.MaxBudgetBytes, f.GetProperty("maxBudgetBytes").GetInt64());
        Assert.Equal(AdaptiveConcurrency.BudgetPercent, f.GetProperty("budgetPercent").GetInt64());
        Assert.Equal(AdaptiveConcurrency.RaiseAfterMs, f.GetProperty("raiseAfterMs").GetInt64());
        Assert.Equal(AdaptiveConcurrency.SampleIntervalMs, f.GetProperty("sampleIntervalMs").GetInt64());
        Assert.Equal(Enum.GetValues<ThermalState>().Select(AdaptiveConcurrency.ContractName),
            f.GetProperty("thermal").EnumerateArray().Select(e => e.GetString()!));
    }

    [Fact]
    public void CapacityFunctionsMatchFixture()
    {
        var workers = Cases("max-workers");
        var budgets = Cases("memory-budget");
        var widths = Cases("hash-width");
        Assert.True(workers.Count >= 8 && budgets.Count >= 5 && widths.Count >= 4);
        foreach (var row in workers)
            Assert.True(row.GetProperty("expected").GetInt32() == AdaptiveConcurrency.MaxWorkers(row.GetProperty("input").GetInt32()), Name(row));
        foreach (var row in budgets)
            Assert.True(row.GetProperty("expected").GetInt64() == AdaptiveConcurrency.MemoryBudget(row.GetProperty("input").GetInt64()), Name(row));
        foreach (var row in widths)
            Assert.True(row.GetProperty("expected").GetInt32() == AdaptiveConcurrency.HashWidth(row.GetProperty("input").GetInt32()), Name(row));
    }

    [Fact]
    public void TargetMatchesFixture()
    {
        var rows = Cases("target");
        Assert.True(rows.Count >= 20);
        foreach (var row in rows)
        {
            var i = row.GetProperty("input");
            var thermal = Enum.GetValues<ThermalState>().Single(t => AdaptiveConcurrency.ContractName(t) == i.GetProperty("thermal").GetString());
            var sample = new SystemSample(i.GetProperty("cores").GetInt32(), i.GetProperty("loadMilli").GetInt32(), thermal,
                i.GetProperty("lowPower").GetBoolean(), i.GetProperty("onBattery").GetBoolean());
            var memory = Enum.Parse<MemoryPressureLevel>(i.GetProperty("memory").GetString()!, ignoreCase: true);
            Assert.True(row.GetProperty("expected").GetInt32() == AdaptiveConcurrency.Target(sample, i.GetProperty("ownWorkers").GetInt32(), memory),
                Name(row));
        }
    }

    [Fact]
    public void GovernorTracesMatchFixture()
    {
        var rows = Cases("governor");
        Assert.True(rows.Count >= 6);
        foreach (var row in rows)
        {
            var input = row.GetProperty("input");
            var governor = new ConcurrencyGovernor(input.GetProperty("cap").GetInt32());
            int index = 0;
            foreach (var sample in input.GetProperty("samples").EnumerateArray())
            {
                int limit = governor.Observe(sample.GetProperty("target").GetInt32(), sample.GetProperty("atMs").GetInt64());
                Assert.True(sample.GetProperty("expected").GetInt32() == limit, $"{Name(row)} #{index++}");
                Assert.Equal(limit, governor.Limit);
            }
        }
    }

    [Fact]
    public async Task AdmissionTracesMatchFixture()
    {
        var rows = Cases("admission");
        Assert.True(rows.Count >= 6);
        foreach (var row in rows)
        {
            string name = Name(row);
            var input = row.GetProperty("input");
            var admission = new IngestionAdmission(input.GetProperty("maxExtractions").GetInt32(), input.GetProperty("memoryBytes").GetInt64());
            var requests = new List<(string Id, Task<Guid> Task)>();
            foreach (var e in input.GetProperty("events").EnumerateArray())
            {
                string op = e.GetProperty("operation").GetString()!;
                switch (op)
                {
                    case "limit": admission.SetConcurrencyLimit(e.GetProperty("limit").GetInt32()); break;
                    case "pressure":
                        admission.SetMemoryPressure(Enum.Parse<MemoryPressureLevel>(e.GetProperty("level").GetString()!, ignoreCase: true));
                        break;
                    case "acquire":
                        requests.Add((e.GetProperty("requestId").GetString()!, admission.AcquireExtractionAsync(e.GetProperty("bytes").GetInt64())));
                        break;
                    case "release":
                        string id = e.GetProperty("requestId").GetString()!;
                        admission.ReleaseExtraction(await requests.Single(r => r.Id == id).Task);
                        break;
                    default: Assert.Fail($"{name}: unknown operation {op}"); break;
                }
                var tokens = admission.ReservationTokens;
                var granted = requests.Where(r => r.Task.IsCompletedSuccessfully).ToDictionary(r => r.Task.Result, r => r.Id);
                var actual = new JsonObject
                {
                    ["limit"] = admission.ConcurrencyLimit,
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
    public void ProbeMappingsMatchFixture()
    {
        var thermal = Cases("darwin-thermal");
        var power = Cases("windows-power");
        var load = Cases("windows-load");
        Assert.True(thermal.Count >= 4 && power.Count >= 5 && load.Count >= 5);
        foreach (var row in thermal)
            Assert.True(row.GetProperty("expected").GetString() ==
                AdaptiveConcurrency.ContractName(AdaptiveConcurrency.FromDarwinThermal(row.GetProperty("input").GetInt32())), Name(row));
        foreach (var row in power)
        {
            var i = row.GetProperty("input");
            var (onBattery, lowPower) = AdaptiveConcurrency.FromWindowsPower(i.GetProperty("acLineStatus").GetInt32(),
                i.GetProperty("systemStatusFlag").GetInt32());
            Assert.True(row.GetProperty("expected").GetProperty("onBattery").GetBoolean() == onBattery, Name(row));
            Assert.True(row.GetProperty("expected").GetProperty("lowPower").GetBoolean() == lowPower, Name(row));
        }
        foreach (var row in load)
        {
            var i = row.GetProperty("input");
            Assert.True(row.GetProperty("expected").GetInt32() == AdaptiveConcurrency.FromWindowsTimes(i.GetProperty("idle").GetInt64(),
                i.GetProperty("kernel").GetInt64(), i.GetProperty("user").GetInt64(), i.GetProperty("cores").GetInt32()), Name(row));
        }
    }

    [Fact]
    public void StandardAdmissionScalesWithMachine()
    {
        var admission = IngestionAdmission.Standard();
        Assert.Equal(AdaptiveConcurrency.MaxWorkers(Environment.ProcessorCount), admission.MaxExtractions);
        Assert.InRange(admission.MemoryBytes, AdaptiveConcurrency.MinBudgetBytes, AdaptiveConcurrency.MaxBudgetBytes);
        Assert.Equal(admission.MaxExtractions, admission.ConcurrencyLimit);
    }

    [Fact]
    public void ProbeFailsOpenOffWindows()
    {
        var sample = new WindowsSystemProbe().Sample();
        Assert.Equal(Environment.ProcessorCount, sample.Cores);
        Assert.True(sample.LoadMilli >= 0);
        if (!OperatingSystem.IsWindows()) Assert.Equal(new SystemSample(Environment.ProcessorCount, 0), sample);
    }

    [Fact]
    public void BackgroundPriorityRestoresThePoolThread()
    {
        var before = Thread.CurrentThread.Priority;
        int value = BackgroundPriority.Run(() => 42);
        Assert.Equal(42, value);
        Assert.Equal(before, Thread.CurrentThread.Priority);
    }
}
