using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Rag;
using AINotebook.Core.Tests.Helpers;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;
namespace AINotebook.Core.Tests.Rag;

public sealed class FtsQueryBuilderTests(ITestOutputHelper output)
{
    private void Run(string fixture, int expectedRows, Func<FtsQueryBuilder, string, string?> build)
    {
        var builder = new FtsQueryBuilder(UnicodeTables.LoadBundled());
        var gate = new object();
        lock (gate)
        {
            using var connection = new SqliteConnection("Data Source=:memory:");
            connection.Open();
            using var cmd = connection.CreateCommand();
            cmd.CommandText = "SELECT sqlite_version()";
            output.WriteLine($"FTS provider=SQLitePCLRaw-e_sqlite3 os={Environment.OSVersion} sqlite={cmd.ExecuteScalar()}");
            cmd.CommandText = "CREATE VIRTUAL TABLE probe USING fts5(text, tokenize='unicode61 remove_diacritics 2')";
            cmd.ExecuteNonQuery();
            int rows = 0;
            foreach (var c in SharedFixtures.Json(fixture).GetProperty("cases").EnumerateArray())
            {
                rows++;
                var expression = build(builder, c.GetProperty("query").GetString()!);
                Assert.Equal(c.GetProperty("expectedMatchExpr").GetString(), expression);
                cmd.Parameters.Clear();
                cmd.CommandText = "DELETE FROM probe";
                cmd.ExecuteNonQuery();
                cmd.CommandText = "INSERT INTO probe(text) VALUES($text)";
                cmd.Parameters.AddWithValue("$text", c.GetProperty("documentText").GetString()!);
                cmd.ExecuteNonQuery();
                cmd.Parameters.Clear();
                if (expression is null) Assert.Equal(JsonValueKind.Null, c.GetProperty("shouldMatchDocument").ValueKind);
                else
                {
                    cmd.CommandText = "SELECT count(*) FROM probe WHERE probe MATCH $q";
                    cmd.Parameters.AddWithValue("$q", expression);
                    Assert.Equal(c.GetProperty("shouldMatchDocument").GetBoolean(), Convert.ToInt64(cmd.ExecuteScalar()) == 1);
                }
            }
            Assert.Equal(expectedRows, rows);
        }
    }

    /// <summary>Frozen folder-rag-v1 §7 builder.</summary>
    [Fact]
    public void SharedCasesOnESqlite3() => Run("contracts/fts-query-v1.json", 24, (b, q) => b.MatchExpressionV1(q));

    /// <summary>fts-query-v2: stopwords, stem prefixes, exact acronyms.</summary>
    [Fact]
    public void SharedV2CasesOnESqlite3() => Run("contracts/fts-query-v2.json", 24, (b, q) => b.MatchExpression(q));

    [Fact]
    public void V2ListsEqualFixture()
    {
        var fixture = SharedFixtures.Json("contracts/fts-query-v2.json");
        var stop = fixture.GetProperty("stopwords").EnumerateObject()
            .ToDictionary(p => p.Name, p => p.Value.EnumerateArray().Select(x => x.GetString()!).ToArray());
        Assert.Equal(stop.Keys.Order(), FtsQueryBuilder.Stopwords.Keys.Order());
        foreach (var (lang, words) in stop) Assert.Equal(words, FtsQueryBuilder.Stopwords[lang]);
        Assert.Equal(fixture.GetProperty("suffixes").EnumerateArray().Select(x => x.GetString()!), FtsQueryBuilder.Suffixes);
        Assert.Equal(FtsQueryBuilder.MinStem, fixture.GetProperty("minStem").GetInt32());
        Assert.Equal(RagContractV1.Retrieval.MaxFtsTokens, fixture.GetProperty("maxTokens").GetInt32());
    }
}
