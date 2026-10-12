using System.Text.Json;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Dapper;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AINotebook.Core.Tests.Storage;

public sealed class RevisionPageTests
{
    [Fact]
    public void SharedImmutableRevisionPageMaps()
    {
        var cases = SharedFixtures.Json("contracts/storage-revision-pages-v1.json").GetProperty("cases");
        var visited = new HashSet<string>();
        foreach (var fixture in cases.EnumerateArray())
        {
            Assert.True(visited.Add(fixture.GetProperty("name").GetString()!));
            var (store, directory, _) = V19TestStore.UpgradeCopy(null);
            try
            {
                string operation = fixture.GetProperty("operation").GetString()!;
                if (operation == "schema")
                {
                    V19TestStore.AssertQueries(store, fixture.GetProperty("queries"));
                    continue;
                }
                var input = fixture.GetProperty("input");
                long revision = store.InsertRevision(101, new("page-map", input.TryGetProperty("canonicalText", out var text)
                    ? text.GetString()! : "", 1, 2), 0).Id;
                Assert.Empty(store.RevisionPages(revision));
                switch (operation)
                {
                    case "pages":
                        AssertPageMap(store, revision, fixture);
                        break;
                    case "invalid-page":
                        lock (store.Gate)
                        {
                            var error = Assert.Throws<SqliteException>(() => InsertPage(store, revision, input));
                            Assert.Contains(fixture.GetProperty("expected").GetProperty("sqlError").GetString()!, error.Message);
                        }
                        Assert.Empty(store.RevisionPages(revision));
                        break;
                    default:
                        throw new InvalidOperationException($"Unknown revision-page fixture operation: {operation}");
                }
            }
            finally { store.Dispose(); Directory.Delete(directory, recursive: true); }
        }
        Assert.Equal(new[] { "durable-job-options-schema", "page-end-must-not-precede-start", "page-must-be-positive",
            "page-start-must-be-nonnegative", "pdf-empty-middle", "revision-pages-schema" }, visited.OrderBy(n => n).ToArray());
    }

    private static void AssertPageMap(NotebookStore store, long revision, JsonElement fixture)
    {
        lock (store.Gate)
        {
            foreach (var page in fixture.GetProperty("input").GetProperty("pages").EnumerateArray())
                InsertPage(store, revision, page);
        }
        var expected = fixture.GetProperty("expected").GetProperty("pages").EnumerateArray()
            .Select(page => new RevisionPage(revision, page.GetProperty("page").GetInt32(),
                page.GetProperty("charStart").GetInt32(), page.GetProperty("charEnd").GetInt32())).ToArray();
        Assert.Equal(expected, store.RevisionPages(revision));
        long next = store.InsertRevision(101, new("new-revision", "new", 1, 2), 1).Id;
        Assert.Empty(store.RevisionPages(next));
        Assert.Empty(store.RevisionPages(long.MaxValue));
        Assert.Equal(expected, store.RevisionPages(revision));
        lock (store.Gate)
        {
            foreach (string column in new[] { "revision_id", "page", "char_start", "char_end" })
            {
                var error = Assert.Throws<SqliteException>(() => store.Connection.Execute(
                    $"UPDATE revision_pages SET {column}={column} WHERE revision_id=$revision", new { revision }));
                Assert.Contains(fixture.GetProperty("expected").GetProperty("updateError").GetString()!, error.Message);
            }
            Assert.Throws<SqliteException>(() => InsertPage(store, revision,
                fixture.GetProperty("input").GetProperty("pages")[0]));
            Assert.Throws<SqliteException>(() => InsertPage(store, long.MaxValue,
                fixture.GetProperty("input").GetProperty("pages")[0]));
            store.Connection.Execute("DELETE FROM source_revisions WHERE id=$revision", new { revision });
        }
        Assert.Empty(store.RevisionPages(revision));
    }

    // The publication insert API belongs to WP6; seed its immutable rows through test SQL under the store gate.
    private static void InsertPage(NotebookStore store, long revision, JsonElement page)
    {
        lock (store.Gate) store.Connection.Execute("""
            INSERT INTO revision_pages(revision_id,page,char_start,char_end)
            VALUES($revision,$number,$start,$end)
            """, new { revision, number = page.GetProperty("page").GetInt32(),
                start = page.GetProperty("charStart").GetInt32(), end = page.GetProperty("charEnd").GetInt32() });
    }
}
