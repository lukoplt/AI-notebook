using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core;

/// Fetches the GitHub releases list and evaluates it against the running
/// version. Throws on any failure — the auto-check path swallows, the
/// manual "Check now" path shows a localized message.
public sealed class UpdateChecker
{
    private const string ReleasesUrl =
        "https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30";
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    private readonly HttpClient _http;

    public UpdateChecker(HttpClient http) => _http = http;

    private sealed record WireAsset(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("browser_download_url")] string BrowserDownloadUrl);

    private sealed record WireRelease(
        [property: JsonPropertyName("tag_name")] string TagName,
        [property: JsonPropertyName("prerelease")] bool Prerelease,
        [property: JsonPropertyName("html_url")] string HtmlUrl,
        [property: JsonPropertyName("assets")] IReadOnlyList<WireAsset> Assets);

    public async Task<UpdateInfo> CheckAsync(CancellationToken ct = default)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(Timeout);

        using var req = new HttpRequestMessage(HttpMethod.Get, ReleasesUrl);
        // GitHub's API rejects requests without a User-Agent (403).
        req.Headers.UserAgent.Add(new ProductInfoHeaderValue("AINotebook", AINotebookVersion.Current));
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));

        using var resp = await _http.SendAsync(req, timeoutCts.Token);
        resp.EnsureSuccessStatusCode();
        var json = await resp.Content.ReadAsStringAsync(timeoutCts.Token);
        var wire = JsonSerializer.Deserialize<List<WireRelease>>(json)
            ?? throw new JsonException("null releases payload");

        var releases = wire
            .Select(w => new UpdateRelease(
                w.TagName, w.Prerelease, w.HtmlUrl,
                w.Assets.Select(a => new UpdateReleaseAsset(a.Name, a.BrowserDownloadUrl)).ToList()))
            .ToList();

        return UpdateCheck.Evaluate(releases, AINotebookVersion.Current, UpdateCheck.WindowsAssetSuffix);
    }
}
