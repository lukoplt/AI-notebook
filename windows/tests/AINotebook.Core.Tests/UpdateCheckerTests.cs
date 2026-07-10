using System.Net;
using System.Text;
using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class UpdateCheckerTests
{
    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            LastRequest = request;
            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            });
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            => throw new HttpRequestException("connection refused");
    }

    private const string ReleasesJson = """
    [
      {
        "tag_name": "v99.0.0",
        "prerelease": false,
        "html_url": "https://github.com/lukoplt/AI-notebook/releases/tag/v99.0.0",
        "assets": [
          {"name": "AINotebook-v99.0.0-windows-setup.exe",
           "browser_download_url": "https://dl/AINotebook-v99.0.0-windows-setup.exe"},
          {"name": "AINotebook-v99.0.0-macos.dmg",
           "browser_download_url": "https://dl/AINotebook-v99.0.0-macos.dmg"}
        ]
      }
    ]
    """;

    [Fact]
    public async Task FetchesParsesAndEvaluates()
    {
        var handler = new StubHandler(HttpStatusCode.OK, ReleasesJson);
        var checker = new UpdateChecker(new HttpClient(handler));
        var info = await checker.CheckAsync();
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("99.0.0", info.LatestVersion);
        Assert.Equal("https://dl/AINotebook-v99.0.0-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public async Task SendsRequiredHeadersToTheReleasesEndpoint()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "[]");
        var checker = new UpdateChecker(new HttpClient(handler));
        _ = await checker.CheckAsync();
        var req = handler.LastRequest!;
        Assert.Equal("https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30",
                     req.RequestUri!.ToString());
        Assert.Contains(req.Headers.UserAgent, p => p.Product?.Name == "AINotebook");
        Assert.Contains(req.Headers.Accept, a => a.MediaType == "application/vnd.github+json");
    }

    [Fact]
    public async Task NoNewerReleaseMeansNotAvailable()
    {
        // v0.0.1 is older than any real current version.
        var json = """[{"tag_name":"v0.0.1","prerelease":false,"html_url":"https://x","assets":[{"name":"A-windows-setup.exe","browser_download_url":"https://dl/A"}]}]""";
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.OK, json)));
        Assert.False((await checker.CheckAsync()).IsUpdateAvailable);
    }

    [Fact]
    public async Task HttpErrorThrows()
    {
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.Forbidden, "")));
        await Assert.ThrowsAnyAsync<Exception>(() => checker.CheckAsync());
    }

    [Fact]
    public async Task NetworkErrorPropagates()
    {
        var checker = new UpdateChecker(new HttpClient(new ThrowingHandler()));
        await Assert.ThrowsAsync<HttpRequestException>(() => checker.CheckAsync());
    }

    [Fact]
    public async Task MalformedJsonThrows()
    {
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.OK, "not-json")));
        await Assert.ThrowsAnyAsync<Exception>(() => checker.CheckAsync());
    }
}
