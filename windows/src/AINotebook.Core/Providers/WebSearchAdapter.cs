using System.Net.Http.Json;
using System.Web;

namespace AINotebook.Core.Providers;

public record WebSearchResult(string Title, string Snippet, string Url);

public interface IWebSearch
{
    Task<IReadOnlyList<WebSearchResult>> SearchAsync(string query, int maxResults = 5, CancellationToken ct = default);
}

/// <summary>
/// E3: Web search via DuckDuckGo Instant Answer API.
/// Returns abstract + related topics as search snippets.
/// For richer SERP results, swap this implementation with a Brave/Serper adapter.
/// </summary>
public sealed class DuckDuckGoWebSearch : IWebSearch
{
    private readonly HttpClient _http;

    public DuckDuckGoWebSearch(HttpClient http) => _http = http;

    public async Task<IReadOnlyList<WebSearchResult>> SearchAsync(
        string query, int maxResults = 5, CancellationToken ct = default)
    {
        var encoded = HttpUtility.UrlEncode(query);
        var url = $"https://api.duckduckgo.com/?q={encoded}&format=json&no_html=1&skip_disambig=1";

        var doc = await _http.GetFromJsonAsync<DdgResponse>(url, ct);
        if (doc is null) return [];

        var results = new List<WebSearchResult>();

        if (!string.IsNullOrWhiteSpace(doc.AbstractText))
            results.Add(new WebSearchResult(doc.Heading ?? query, doc.AbstractText, doc.AbstractURL ?? ""));

        foreach (var topic in doc.RelatedTopics ?? [])
        {
            if (results.Count >= maxResults) break;
            if (string.IsNullOrWhiteSpace(topic.Text)) continue;
            results.Add(new WebSearchResult(topic.Text[..Math.Min(topic.Text.Length, 80)], topic.Text, topic.FirstURL ?? ""));
        }

        return results;
    }

    private sealed class DdgResponse
    {
        public string? AbstractText { get; init; }
        public string? AbstractURL { get; init; }
        public string? Heading { get; init; }
        public List<DdgTopic>? RelatedTopics { get; init; }
    }

    private sealed class DdgTopic
    {
        public string? Text { get; init; }
        public string? FirstURL { get; init; }
    }
}
