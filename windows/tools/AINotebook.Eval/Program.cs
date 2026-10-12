using System.Text;
using AINotebook.Core.Eval;
using AINotebook.Core.Ollama;

const string Usage = """
Usage: AINotebook.Eval --benchmark|--calibrate [options]
       AINotebook.Eval --dataset multilingual [options]

WP7 benchmark and chat-token calibration (benchmark-v1):
  --benchmark | --calibrate     Exactly one command
  --mode live|fixture           Default live; fixture never contacts a provider
  --root DIR                    Corpus (default: eval/multilingual)
  --host URL                    Ollama API root (default: http://127.0.0.1:11434)
  --profiles all|ID,...         Embedding profiles in catalog order (default: all)
  --chunks N,...                Synthetic chunk counts (default: 100000,200000)
  --chat-model NAME             Chat calibration subject (default: llama3.2:3b)
  --calibration FILE            token-estimate v2 resource; required for a live benchmark
  --ollama-pid N                Ollama root process; required for a live benchmark
  --tokenizer-root DIR          Offline documented tokenizers (optional)
  --embedding-counts all        Calibrate only
  --queries N --warmup N        Measured/warmup queries per row (default: 200/20)
  --concurrent both|off|on      Concurrent-ingestion rows (default: both)
  --seed N --fetch-k N --top-k N --evidence-share-bp N
  --runtime-context N --max-output N
  --json FILE --out FILE        Required, distinct report paths
  Reference protocol: warm p95 < 300000 us at 100000 chunks, 200 queries, no ingestion.
  Exit codes: 0 complete, 1 incomplete or failure, 2 invalid arguments.

Retrieval eval:

  --root DIR          Corpus directory (default: eval/multilingual)
  --mode lexical|ollama
                      Retrieval mode (default: lexical; no embedding calls)
  --model NAME        Required for ollama; unavailable in lexical mode
  --host URL          Ollama API root (default: http://127.0.0.1:11434)
  --top-k N           Ranked recall limit (default: 16)
  --fetch-k N         Candidate limit per branch, at least top-k (default: 32)
  --json FILE         Write the versioned JSON report
  --out FILE          Write the Markdown report
  --validate-only     Validate the corpus without retrieval or a provider
  --help              Show this help

The existing English dataset is supported by the Swift ainotebook-eval executable.
""";

Console.OutputEncoding = new UTF8Encoding(false);
if (args.Contains("--help", StringComparer.Ordinal))
{
    Console.Write(Usage + '\n');
    return 0;
}

if (args.Contains("--benchmark", StringComparer.Ordinal) || args.Contains("--calibrate", StringComparer.Ordinal))
    return await RunBenchmark(args);

try
{
    var options = EvalOptions.Parse(args);
    var loaded = EvalRunner.Load(options.Root);
    if (options.ValidateOnly)
    {
        Console.Write(FormattableString.Invariant(
            $"Validated {loaded.Corpus.Documents.Count} documents and {loaded.Corpus.Questions.Count} queries.\n"));
        return 0;
    }

    var embedder = options.Mode == "ollama"
        ? new OllamaEmbeddingAdapter(new OllamaClient(baseUrl: new Uri(options.Host.TrimEnd('/') + "/")))
        : null;
    var report = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, options, embedder);
    var markdown = report.Markdown();
    Console.Write(markdown);
    if (options.JsonPath is not null)
        await WriteAtomic(options.JsonPath, report.JsonBytes());
    if (options.MarkdownPath is not null)
        await WriteAtomic(options.MarkdownPath, new UTF8Encoding(false).GetBytes(markdown));
    return 0;
}
catch (EvalFailure failure) when (failure.Code == "usage")
{
    Console.Error.Write("usage\n" + Usage + '\n');
    return 2;
}
catch (Exception failure)
{
    Console.Error.Write((failure is EvalFailure eval ? eval.Code : failure.Message) + '\n');
    return 1;
}

static async Task<int> RunBenchmark(string[] args)
{
    BenchmarkOptions options;
    try { options = BenchmarkOptions.Parse(args); }
    catch (BenchmarkException)
    {
        Console.Error.Write("invalidArguments\n" + Usage + '\n');
        return 2;
    }
    using var cancel = new CancellationTokenSource();
    Console.CancelKeyPress += (_, e) => { e.Cancel = true; cancel.Cancel(); };
    try
    {
        byte[] json;
        string markdown;
        bool complete;
        if (options.Command == "benchmark")
        {
            var report = await BenchmarkRunner.RunAsync(options, cancel.Token);
            report.Validate();
            (json, markdown, complete) = (report.JsonBytes(), report.Markdown(), report.Status == "complete");
        }
        else
        {
            var report = await BenchmarkRunner.CalibrateAsync(options, cancel.Token);
            report.Validate();
            (json, markdown, complete) = (report.JsonBytes(), report.Markdown(), report.Status == "complete");
        }
        cancel.Token.ThrowIfCancellationRequested();
        // Incomplete reports are still written: they are clearly marked diagnostics, never a success.
        await WriteAtomic(options.Json, json);
        await WriteAtomic(options.Out, new UTF8Encoding(false).GetBytes(markdown));
        Console.Write(markdown);
        return complete ? 0 : 1;
    }
    catch (OperationCanceledException)
    {
        Console.Error.Write("cancelled\n");
        return 1;
    }
    catch (Exception failure)
    {
        Console.Error.Write(failure switch
        {
            BenchmarkException b => b.Code,
            EvalFailure e => e.Code,
            AINotebook.Core.Rag.EmbeddingProfileException p => p.Code,
            _ => failure.GetType().Name,
        } + '\n');
        return 1;
    }
}

static async Task WriteAtomic(string destination, byte[] bytes)
{
    var fullPath = Path.GetFullPath(destination);
    var temporary = Path.Combine(Path.GetDirectoryName(fullPath)!,
        $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
    try
    {
        await File.WriteAllBytesAsync(temporary, bytes);
        File.Move(temporary, fullPath, overwrite: true);
    }
    finally
    {
        if (File.Exists(temporary)) File.Delete(temporary);
    }
}
