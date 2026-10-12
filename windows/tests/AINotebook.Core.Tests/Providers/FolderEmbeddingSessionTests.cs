using AINotebook.Core.Ingestion;
using AINotebook.Core.Ollama;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Providers;

/// <summary>
/// WP6 folder ingestion embeds through the WP5/WP7 <see cref="ProviderEmbeddingSession"/>: one endpoint
/// identity, one format-version policy, one document/query path.
/// </summary>
public sealed class FolderEmbeddingSessionTests
{
    private sealed class RecordingTransport : IStrictEmbeddingTransport
    {
        public readonly List<string> Inputs = [];

        public Task<StrictEmbeddingResult> EmbedAsync(string model, string input, int nativeDims, int inputLimit, CancellationToken ct = default)
        {
            lock (Inputs) Inputs.Add(input);
            return Task.FromResult(new StrictEmbeddingResult([3f, 4f], input.EnumerateRunes().Count(), 1, 0));
        }
    }

    private static readonly EmbeddingProfile Profile =
        new("fixture", "fixture-model", "fixture-only", "q: ", "d: ", 2, 2, 64, false);

    private static ProviderConfig Local(string baseUrl = "http://localhost:11434/") =>
        new("local", ProviderType.Ollama, "Local", baseUrl, true, false, DateTime.UnixEpoch);

    [Fact]
    public void RawCaptureUsesTheSharedEndpointIdentityAndProviderSession()
    {
        var config = Local();
        var folder = new FolderEmbeddingSession(config, "embed-a", null, null, "1", "1", new HttpClient());
        string root = ProviderApiRoot.Normalize(config.BaseUrl);
        Assert.Equal(EmbeddingEndpointRevision.Make(ProviderType.Ollama, root), folder.Selection.EndpointRevision);
        Assert.Equal(folder.Selection.EndpointRevision, folder.Provider.EndpointRevision);
        Assert.Equal("local:embed-a", folder.Provider.StorageKey);
        Assert.Null(folder.Provider.Profile); // format 1 is the raw-input path
    }

    [Fact]
    public void RawCaptureRejectsFormatsTheSharedPolicyDoesNotSupport()
    {
        foreach (var (query, doc) in new[]
                 {
                     (Profile.FormatVersion(EmbeddingPurpose.Query), Profile.FormatVersion(EmbeddingPurpose.Document)),
                     // embedding-raw-format-v2: "2" is a raw format, but query and document formats must agree.
                     ("2", "1"), ("1", "2"), ("3", "3"),
                 })
        {
            var error = Assert.Throws<RetrievalException>(() =>
                new FolderEmbeddingSession(Local(), "m", null, null, query, doc, new HttpClient()));
            Assert.Equal("unsupportedQueryFormat", error.Code);
        }
        Assert.Equal("invalidValue", Assert.Throws<ProviderConfigurationException>(() =>
            new FolderEmbeddingSession(Local(), "m", null, null, " ", "1", new HttpClient())).Code);
    }

    [Fact]
    public async Task ProfileSessionEmbedsDocumentsWithTheDocumentPrefix()
    {
        var identity = new GenerationIdentity("local", "rev", Profile.Model, "sha256:abc", 2, "l2",
            Profile.FormatVersion(EmbeddingPurpose.Query), Profile.FormatVersion(EmbeddingPurpose.Document), "2");
        var transport = new RecordingTransport();
        var provider = new ProviderEmbeddingSession("local:" + Profile.Model, "rev", identity, Profile,
            new StrictEmbeddingPipeline(transport), Profile.MaxInputTokens);
        var folder = new FolderEmbeddingSession(provider);
        Assert.Equal(new EmbeddingSelection(identity.ProviderId, identity.EndpointRevision, identity.Model, identity.ModelDigest,
            identity.Dims, identity.Normalization, identity.QueryFormatVersion, identity.DocFormatVersion, identity.ChunkerVersion),
            folder.Selection);
        var vectors = await folder.EmbedAsync(["abc"]);
        Assert.Equal([0.6f, 0.8f], vectors.Single());
        Assert.Equal(["d: abc"], transport.Inputs);
        Assert.Equal(identity, folder.Identity(2));
        Assert.Equal(identity, folder.VerifiedIdentity);
        Assert.Equal("invalidVector", Assert.Throws<FolderIngestionException>(() => folder.Identity(3)).Code);
    }

    [Fact]
    public void OnlyProfileSessionsAdaptDirectly()
    {
        var raw = new ProviderEmbeddingSession(new OllamaEmbeddingAdapter(new OllamaClient(new HttpClient(), new Uri("http://localhost:11434"))),
            "m", "local:m", "rev");
        Assert.Equal("unsupportedEmbeddingProfile",
            Assert.Throws<EmbeddingProfileException>(() => new FolderEmbeddingSession(raw)).Code);
    }
}
