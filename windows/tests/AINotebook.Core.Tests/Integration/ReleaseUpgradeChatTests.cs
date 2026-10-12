using System.Text.Json;
using AINotebook.Core.Models;
using AINotebook.Core.Providers;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Xunit;

namespace AINotebook.Core.Tests.Integration;

/// <summary>
/// WP9: v18 upgrade → multilingual folder ingestion → scoped context pack → persisted v2 citations → restart,
/// through the real Core graph.
/// </summary>
public sealed class ReleaseUpgradeChatTests
{
    [Fact]
    public void FixtureScenarioNamesAreExactlySupported()
    {
        var fixture = ReleaseFixture.Load();
        Assert.Equal("release-integration", fixture.Contract);
        Assert.Equal(1, fixture.Version);
        Assert.Equal(ReleaseFixture.SupportedCases, fixture.Cases.Select(c => c.Name));
    }

    [Fact]
    public void FolderSessionUsesRetrievalEndpointIdentity()
    {
        using var http = new HttpClient(new ReleaseEmbeddingHandler());
        foreach (var row in ReleaseFixture.Load().EndpointCases)
        {
            var type = row.Type switch
            {
                "ollama" => ProviderType.Ollama,
                "openai_compatible" => ProviderType.OpenAICompatible,
                _ => throw new InvalidDataException("unhandled endpoint fixture type"),
            };
            var config = new ProviderConfig("wp9", type, "WP9", row.Root, true, true, DateTime.UnixEpoch);
            var session = new FolderEmbeddingSession(config, "wp9-2d", null, null, "1", "1", http);
            Assert.Equal(row.Expected, session.Selection.EndpointRevision);
            Assert.Equal(EmbeddingEndpointRevision.Make(type, ProviderApiRoot.Normalize(row.Root)),
                session.Identity(2).EndpointRevision);
        }
    }

    [Fact]
    public async Task UpgradeFolderChatAndCitationReload()
    {
        var h = await ReleaseHarness.OpenAsync();
        try
        {
            var row = h.Fixture.CaseNamed("upgrade-chat");
            Assert.Equal(1, h.Integer("SELECT count(*) FROM grdb_migrations WHERE identifier='v19_folder_rag'"));
            var legacy = Assert.Single(h.Store.Messages(31));
            Assert.Equal("saved answer", legacy.Content);
            var legacyCitation = Assert.Single(legacy.Citations);
            Assert.Equal(1101, legacyCitation.ChunkId);
            Assert.Empty(legacyCitation.Spans);

            var handle = await h.PrepareAsync();
            Assert.Empty(h.Store.Messages(h.SessionId));
            await h.AssertPackAsync(handle.Request, row.Name);

            var reply = await h.SendAsync(handle);
            Assert.Equal(PreparedContextRequestJson.Encode(handle.Request), Assert.Single(h.Transport.Requests));
            Assert.Equal(row.Expected.SavedMarkers, reply.Citations.Select(c => c.Marker).ToArray());
            foreach (var citation in reply.Citations)
                Assert.Equal(CitationsCodec.Encode([handle.Request.CitationMap.Single(c => c.Marker == citation.Marker)]),
                    CitationsCodec.Encode([citation]));
            long assistantId = Assert.IsType<long>(reply.Id);
            using (var raw = JsonDocument.Parse(h.RawCitations(assistantId)))
                Assert.Equal(row.Expected.CitationVersion, raw.RootElement.GetProperty("v").GetInt32());
            string saved = CitationsCodec.Encode(reply.Citations)!;

            await h.CloseAsync();
            await h.ReopenAsync();
            Assert.Equal(saved, CitationsCodec.Encode(h.Store.Messages(h.SessionId).Last().Citations));
            Assert.Single(h.Store.Folders(h.NotebookId));
            Assert.Null(h.Previews.Sent(h.SessionId, assistantId));
        }
        finally
        {
            await h.CloseAsync();
            h.RemoveTemporaryFiles();
        }
    }

    [Fact]
    public async Task ExplicitEmptyScopeDoesNotEmbedOrCite()
    {
        var h = await ReleaseHarness.OpenAsync();
        try
        {
            var row = h.Fixture.CaseNamed("empty-selection");
            int before = h.QueryEmbedding.Calls;
            var handle = await h.PrepareAsync(new RetrievalScope.Selection(new HashSet<long>(), new HashSet<long>()));
            Assert.Equal(row.Expected.Citations, handle.Request.CitationMap.Length);
            Assert.Equal(row.Expected.QueryEmbeddingCalls, h.QueryEmbedding.Calls - before);
            Assert.DoesNotContain(handle.Request.Messages.SelectMany(m => m.Sections), s => s.Kind == "map");
            Assert.Empty((await h.SendAsync(handle)).Citations);
        }
        finally
        {
            await h.CloseAsync();
            h.RemoveTemporaryFiles();
        }
    }

    [Fact]
    public async Task ZeroEvidenceBudgetPersistsNoCitations()
    {
        var h = await ReleaseHarness.OpenAsync();
        try
        {
            var row = h.Fixture.CaseNamed("zero-evidence");
            var handle = await h.PrepareAsync(cap: row.Cap);
            Assert.Equal(row.Expected.Citations, handle.Request.CitationMap.Length);
            Assert.Equal(row.Expected.EvidenceSections,
                handle.Request.Messages.SelectMany(m => m.Sections).Count(s => s.Kind == "evidence"));
            Assert.Empty((await h.SendAsync(handle)).Citations);
            Assert.Empty(h.Store.Messages(h.SessionId).Last().Citations);
        }
        finally
        {
            await h.CloseAsync();
            h.RemoveTemporaryFiles();
        }
    }
}
