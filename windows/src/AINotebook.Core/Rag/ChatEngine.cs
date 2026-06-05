using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Rag;

public sealed class ChatEngine
{
    private readonly NotebookStore _store;
    private readonly Retriever _retriever;
    private readonly IChatStreaming _chat;
    public string ChatModel { get; }
    public int TopK { get; }
    public int RetryAttempts { get; }
    public int RetryBackoffMillis { get; }

    public ChatEngine(
        NotebookStore store, Retriever retriever, IChatStreaming chat, string chatModel,
        int topK = 8, int retryAttempts = 2, int retryBackoffMillis = 250)
    {
        _store = store;
        _retriever = retriever;
        _chat = chat;
        ChatModel = chatModel;
        TopK = topK;
        RetryAttempts = retryAttempts;
        RetryBackoffMillis = retryBackoffMillis;
    }

    public async Task<ChatMessage> SendAsync(
        long sessionId, long notebookId, string userText,
        string? currentNoteContent = null, Action<string>? onToken = null,
        CancellationToken ct = default)
    {
        // 1) Persist the user message.
        _store.AppendMessage(new ChatMessage(null, sessionId, ChatRole.User, userText, Array.Empty<Citation>(), DateTime.UtcNow));

        // 2) Retrieve context.
        var hits = await _retriever.SearchAsync(notebookId, userText, TopK, ct);

        // 3) Compose messages: system + full history.
        var systemContent = SystemPrompt.Compose(hits, currentNoteContent);
        var history = _store.Messages(sessionId);
        var turns = new List<ChatTurn> { new(ChatRole.System, systemContent) };
        foreach (var m in history) turns.Add(new ChatTurn(m.Role, m.Content));

        // 4) Stream with retry + exponential backoff. total tries = RetryAttempts + 1.
        var assembled = "";
        var attempt = 0;
        while (true)
        {
            try
            {
                var partial = "";
                await foreach (var token in _chat.StreamAsync(ChatModel, turns, ct))
                {
                    partial += token;
                    onToken?.Invoke(token);
                }
                assembled = partial;
                break;
            }
            catch (Exception)
            {
                if (attempt >= RetryAttempts) throw;
                attempt++;
                var delayMs = RetryBackoffMillis * (int)Math.Pow(2, attempt - 1);
                await Task.Delay(delayMs, ct);
            }
        }

        // 5) Parse markers, dedupe first-seen, bound to 1..hits.Count, map to citations.
        var markers = CitationParser.Markers(assembled);
        var seen = new HashSet<int>();
        var citations = new List<Citation>();
        foreach (var m in markers)
        {
            if (!seen.Add(m)) continue;
            if (m < 1 || m > hits.Count) continue;
            var h = hits[m - 1];
            citations.Add(new Citation(m, h.ChunkId, h.SourceId, h.Snippet));
        }

        // 6) Persist the assistant message.
        var stored = new ChatMessage(null, sessionId, ChatRole.Assistant, assembled, citations, DateTime.UtcNow);
        _store.AppendMessage(stored);
        return stored;
    }
}
