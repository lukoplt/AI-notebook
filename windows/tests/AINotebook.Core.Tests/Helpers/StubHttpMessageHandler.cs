using System.Net;
using System.Text;

namespace AINotebook.Core.Tests.Helpers;

public sealed class StubHttpMessageHandler : HttpMessageHandler
{
    public sealed record Stub(int Status, string ContentType, string Body, bool ConnectionRefused = false);

    private readonly Queue<Stub> _queue = new();
    private readonly object _gate = new();

    public HttpRequestMessage? LastRequest { get; private set; }
    public string? LastRequestBody { get; private set; }
    public List<HttpRequestMessage> AllRequests { get; } = new();

    public StubHttpMessageHandler Json(string body, int status = 200)
    {
        lock (_gate) _queue.Enqueue(new Stub(status, "application/json", body));
        return this;
    }

    public StubHttpMessageHandler Ndjson(IEnumerable<string> lines, int status = 200)
    {
        // Join non-trailing-newline lines with '\n' (one JSON object per line).
        var body = string.Join("\n", lines);
        lock (_gate) _queue.Enqueue(new Stub(status, "application/x-ndjson", body));
        return this;
    }

    public StubHttpMessageHandler ConnectionRefused()
    {
        lock (_gate) _queue.Enqueue(new Stub(-1, "", "", ConnectionRefused: true));
        return this;
    }

    protected override async Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken cancellationToken)
    {
        LastRequest = request;
        AllRequests.Add(request);
        LastRequestBody = request.Content is null
            ? null
            : await request.Content.ReadAsStringAsync(cancellationToken);

        Stub stub;
        lock (_gate)
        {
            if (_queue.Count == 0)
                throw new InvalidOperationException("StubHttpMessageHandler: no queued response.");
            stub = _queue.Dequeue();
        }

        if (stub.ConnectionRefused)
        {
            // Mirror URLError(.cannotConnectToHost): a transport-level failure.
            throw new HttpRequestException("Connection refused (stub).");
        }

        var resp = new HttpResponseMessage((HttpStatusCode)stub.Status)
        {
            Content = new StringContent(stub.Body, Encoding.UTF8),
        };
        resp.Content.Headers.Remove("Content-Type");
        resp.Content.Headers.TryAddWithoutValidation("Content-Type", stub.ContentType);
        return resp;
    }
}
