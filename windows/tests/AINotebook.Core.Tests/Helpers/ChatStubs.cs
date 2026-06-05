using System.Runtime.CompilerServices;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;

namespace AINotebook.Core.Tests.Helpers;

public sealed class MockChatClient : IChatStreaming
{
    private readonly string[] _tokens;
    public List<IReadOnlyList<ChatTurn>> CapturedMessages { get; } = new();
    public int Calls => CapturedMessages.Count;

    public MockChatClient(params string[] tokens) => _tokens = tokens;

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        CapturedMessages.Add(messages);
        foreach (var t in _tokens)
        {
            await Task.Yield();
            yield return t;
        }
    }
}

public sealed class StaggeredChat : IChatStreaming
{
    private readonly string[] _tokens;
    public StaggeredChat(params string[] tokens) => _tokens = tokens;

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        foreach (var t in _tokens)
        {
            await Task.Delay(1, ct);
            yield return t;
        }
    }
}

public sealed class FlakyChat : IChatStreaming
{
    private readonly int _failTimes;
    private readonly string _finalToken;
    public int Attempts { get; private set; }

    public FlakyChat(int failTimes, string finalToken = "ok")
    {
        _failTimes = failTimes;
        _finalToken = finalToken;
    }

    public async IAsyncEnumerable<string> StreamAsync(
        string model, IReadOnlyList<ChatTurn> messages,
        [EnumeratorCancellation] CancellationToken ct = default)
    {
        Attempts++;
        if (Attempts <= _failTimes)
        {
            await Task.Yield();
            throw new OllamaException.Timeout();
        }
        await Task.Yield();
        yield return _finalToken;
    }
}
