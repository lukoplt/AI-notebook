using System.Globalization;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Eval;

/// <summary>
/// WP7 benchmark/calibration CLI options (benchmark-v1 §8 <c>cli</c>). Every rejection is
/// <c>invalidArguments</c> (exit 2) and happens before any provider or store operation.
/// <see cref="EmbeddingCounts"/> is the contract §9 extra field (<c>--embedding-counts all</c>).
/// </summary>
public sealed record BenchmarkOptions(string Command, string Mode, string Root, string Host,
    IReadOnlyList<string> ProfileIds, IReadOnlyList<int> ChunkCounts, string ChatModel,
    string? Calibration, string? TokenizerRoot, int Queries, int Warmup, string Concurrent, int Seed,
    int FetchK, int TopK, int EvidenceShareBp, int RuntimeContext, int MaxOutput, int? OllamaPid, string Json, string Out,
    string? EmbeddingCounts = null)
{
    public const string DefaultHost = "http://127.0.0.1:11434";
    public const string DefaultRoot = "eval/multilingual";
    public const string DefaultChatModel = "llama3.2:3b";

    private static readonly string[] Flags =
    [
        "--mode", "--root", "--host", "--profiles", "--chunks", "--chat-model", "--calibration", "--tokenizer-root",
        "--embedding-counts", "--queries", "--warmup", "--concurrent", "--seed", "--fetch-k", "--top-k",
        "--evidence-share-bp", "--runtime-context", "--max-output", "--ollama-pid", "--json", "--out",
    ];

    public static BenchmarkOptions Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        var commands = new List<string>();
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (int i = 0; i < args.Count; i++)
        {
            string a = args[i];
            if (a is "--benchmark" or "--calibrate") { commands.Add(a[2..]); continue; }
            if (!Flags.Contains(a, StringComparer.Ordinal) || values.ContainsKey(a) || i + 1 >= args.Count) throw Invalid();
            values[a] = args[++i];
        }
        if (commands.Count != 1) throw Invalid();

        string Text(string flag, string fallback)
        {
            if (!values.TryGetValue(flag, out var v)) return fallback;
            return v.Length == 0 ? throw Invalid() : v;
        }
        string? Optional(string flag) => values.TryGetValue(flag, out var v) ? (v.Length == 0 ? throw Invalid() : v) : null;
        int Number(string flag, int fallback) => values.TryGetValue(flag, out var v) ? Decimal(v) : fallback;

        IReadOnlyList<string> profiles = EmbeddingProfiles.Ids;
        if (values.TryGetValue("--profiles", out var p) && p != "all")
        {
            var ids = p.Split(',');
            if (ids.Length == 0 || ids.Distinct(StringComparer.Ordinal).Count() != ids.Length
                || ids.Any(id => !EmbeddingProfiles.Ids.Contains(id, StringComparer.Ordinal)))
                throw Invalid();
            profiles = ids;
        }
        IReadOnlyList<int> chunks = [100_000, 200_000];
        if (values.TryGetValue("--chunks", out var c))
        {
            var counts = c.Split(',').Select(Decimal).ToArray();
            if (counts.Distinct().Count() != counts.Length || counts.Any(x => x <= 0)) throw Invalid();
            chunks = counts;
        }
        int? pid = values.TryGetValue("--ollama-pid", out var pidText) ? Decimal(pidText) : null;
        var o = new BenchmarkOptions(commands[0], Text("--mode", "live"), Text("--root", DefaultRoot), Text("--host", DefaultHost),
            profiles, chunks, Text("--chat-model", DefaultChatModel), Optional("--calibration"), Optional("--tokenizer-root"),
            Number("--queries", 200), Number("--warmup", 20), Text("--concurrent", "both"), Number("--seed", 17),
            Number("--fetch-k", 32), Number("--top-k", 16), Number("--evidence-share-bp", 6000),
            Number("--runtime-context", 8192), Number("--max-output", 1024), pid,
            Optional("--json") ?? throw Invalid(), Optional("--out") ?? throw Invalid(), Optional("--embedding-counts"));
        if (o.Mode is not ("live" or "fixture") || o.Concurrent is not ("both" or "off" or "on") || o.Json == o.Out
            || o.TopK <= 0 || o.FetchK < o.TopK || o.FetchK > 1024 || o.EvidenceShareBp > 10_000
            || o.MaxOutput <= 0 || o.MaxOutput >= o.RuntimeContext || o.Queries <= 0
            || (o.EmbeddingCounts is not null && (o.Command != "calibrate" || o.EmbeddingCounts != "all"))
            || o.OllamaPid is <= 0)
            throw Invalid();
        if (o.Command == "benchmark" && o.Mode == "live" && (o.Calibration is null || o.OllamaPid is null)) throw Invalid();
        return o;
    }

    /// <summary>Invariant unsigned decimal, at most 10 ASCII digits and ≤ Int32.MaxValue.</summary>
    private static int Decimal(string text)
    {
        if (text.Length == 0 || text.Length > 10 || !text.All(char.IsAsciiDigit)
            || !long.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out long v) || v > int.MaxValue)
            throw Invalid();
        return (int)v;
    }

    private static BenchmarkException Invalid() => new("invalidArguments");
}
