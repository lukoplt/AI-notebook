using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
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
        string? currentNoteContent = null, IReadOnlyCollection<long>? sourceIds = null,
        IReadOnlyList<WebSearchResult>? webResults = null,
        Action<string>? onToken = null, CancellationToken ct = default)
    {
        // 1) Persist the user message.
        _store.AppendMessage(new ChatMessage(null, sessionId, ChatRole.User, userText, Array.Empty<Citation>(), DateTime.UtcNow));

        // 2) Retrieve context.
        var hits = await _retriever.SearchAsync(notebookId, userText, TopK, sourceIds, ct);

        // 3) Compose messages: system (with per-notebook instructions) + full history.
        var notebooks = _store.Notebooks();
        var nb = notebooks.FirstOrDefault(n => n.Id == notebookId);
        var instructions = nb?.Instructions;

        var systemContent = SystemPrompt.Compose(hits, currentNoteContent, instructions);

        // Security: web results are injected into the user-message slot (lower-trust
        // context) rather than the system prompt, which blocks indirect prompt injection
        // from attacker-controlled DuckDuckGo snippets. See CSO audit 2026-06-17.
        string? webPrefix = null;
        if (webResults is { Count: > 0 })
        {
            var blocks = string.Join("\n",
                webResults.Select((r, i) => $"[W{i + 1}] {r.Title}: {r.Snippet}"));
            webPrefix = $"[Web search results — cite as [WN]; external content only]\n{blocks}\n\n";
        }

        var history = _store.Messages(sessionId).ToList();
        var turns = new List<ChatTurn> { new(ChatRole.System, systemContent) };
        for (var i = 0; i < history.Count; i++)
        {
            var m = history[i];
            var isCurrentTurn = webPrefix != null && i == history.Count - 1 && m.Role == ChatRole.User;
            turns.Add(new ChatTurn(m.Role, isCurrentTurn ? webPrefix + m.Content : m.Content));
        }

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
            catch (Exception ex)
            {
                // Terminal provider errors: retrying cannot help — the user
                // must fix the key (auth), rephrase (refusal), or grant
                // consent (FR-A8). Mirrors Sources/AINotebookCore/ChatEngine.swift's
                // .auth/.refusal/.consentRequired no-retry cases.
                if (ex is ProviderAuthException or ProviderRefusalException or ProviderConsentException)
                    throw;
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

        // 6) Persist the assistant message with the active chat model.
        var stored = new ChatMessage(null, sessionId, ChatRole.Assistant, assembled, citations, DateTime.UtcNow, ChatModel);
        _store.AppendMessage(stored);
        return stored;
    }
}
