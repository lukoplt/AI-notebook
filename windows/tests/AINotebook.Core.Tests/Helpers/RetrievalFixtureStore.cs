using System.Runtime.CompilerServices;
using System.Text.Json;
using AINotebook.Core.Storage;
using Dapper;

namespace AINotebook.Core.Tests.Helpers;

internal static class RetrievalFixtureStore
{
    private sealed class Counter { internal int Statements; }
    private static readonly ConditionalWeakTable<NotebookStore, Counter> Counters = new();

    internal static IEnumerable<JsonElement> Cases() => SharedFixtures.Json("contracts/retrieval-scope-v1.json")
        .GetProperty("cases").EnumerateArray().Select(c => c.Clone()).ToArray();

    internal static NotebookStore Create(string caseName = "all")
    {
        var store = V19TestStore.Create();
        try { Seed(store, caseName); return store; }
        catch { store.Dispose(); throw; }
    }

    internal static void Seed(NotebookStore store, string caseName = "all")
    {
        var fixture = SharedFixtures.Json("contracts/retrieval-scope-v1.json");
        var selected = Cases().Single(c => c.GetProperty("name").GetString() == caseName);
        var seed = fixture.GetProperty("seed");
        lock (store.Gate)
        {
            using var tx = store.Connection.BeginTransaction();
            foreach (var n in seed.GetProperty("notebooks").EnumerateArray())
                store.Connection.Execute("INSERT INTO notebooks(id,name,created_at,updated_at) VALUES($id,$name,$created,$updated)",
                    new { id = Id(n, "id"), name = Text(n, "name"), created = Text(n, "createdAt"), updated = Text(n, "updatedAt") }, tx);
            foreach (var f in seed.GetProperty("folders").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO folder_sources(id,notebook_id,root_path,path_identity,display_name,include_exts,ignore_globs,limits,created_at)
                    VALUES($id,$notebook,$root,$identity,$display,$include,$ignore,$limits,$created)
                    """, new { id = Id(f, "id"), notebook = Id(f, "notebookId"), root = Text(f, "rootPath"),
                    identity = f.GetProperty("pathIdentity").GetRawText(), display = Text(f, "displayName"),
                    include = f.GetProperty("includeExts").GetRawText(), ignore = f.GetProperty("ignoreGlobs").GetRawText(),
                    limits = f.GetProperty("limits").GetRawText(), created = Text(f, "createdAt") }, tx);
            // Source pointers are assigned only after their referenced revisions exist.
            foreach (var s in seed.GetProperty("sources").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO sources(id,notebook_id,type,title,status,ingested_at,folder_id,rel_path,availability,eligible)
                    VALUES($id,$notebook,$type,$title,$status,$ingested,$folder,$path,$availability,$eligible)
                    """, new { id = Id(s, "id"), notebook = Id(s, "notebookId"), type = Text(s, "type"), title = Text(s, "title"),
                    status = Text(s, "status"), ingested = Text(s, "ingestedAt"), folder = NullableId(s, "folderId"),
                    path = NullableText(s, "relPath"), availability = Text(s, "availability"), eligible = Id(s, "eligible") }, tx);
            foreach (var r in seed.GetProperty("revisions").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                    VALUES($id,$source,$revision,$hash,$text,$format,$chunker,$created)
                    """, new { id = Id(r, "id"), source = Id(r, "sourceId"), revision = Id(r, "revision"),
                    hash = Text(r, "contentHash"), text = Text(r, "canonicalText"), format = Id(r, "textFormatVersion"),
                    chunker = Id(r, "chunkerVersion"), created = Text(r, "createdAt") }, tx);
            foreach (var s in seed.GetProperty("sources").EnumerateArray())
                store.Connection.Execute("UPDATE sources SET current_revision=$current,published_revision_id=$published WHERE id=$id",
                    new { id = Id(s, "id"), current = NullableId(s, "currentRevision"), published = NullableId(s, "publishedRevisionId") }, tx);
            foreach (var c in seed.GetProperty("chunks").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count,char_start,char_end)
                    VALUES($id,$source,$revision,$ord,$text,$tokens,$start,$end)
                    """, new { id = Id(c, "id"), source = Id(c, "sourceId"), revision = Id(c, "revisionId"), ord = Id(c, "ord"),
                    text = Text(c, "text"), tokens = Id(c, "tokenCount"), start = NullableId(c, "charStart"), end = NullableId(c, "charEnd") }, tx);
            foreach (var g in seed.GetProperty("generations").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO index_generations(id,notebook_id,provider_id,endpoint_revision,model,model_digest,dims,
                        normalization,query_format_version,doc_format_version,chunker_version,state,created_at)
                    VALUES($id,$notebook,$provider,$endpoint,$model,$digest,$dims,$normalization,$query,$doc,$chunker,$state,$created)
                    """, new { id = Id(g, "id"), notebook = Id(g, "notebookId"), provider = Text(g, "providerId"),
                    endpoint = Text(g, "endpointRevision"), model = Text(g, "model"), digest = NullableText(g, "modelDigest"),
                    dims = Id(g, "dims"), normalization = Text(g, "normalization"), query = Text(g, "queryFormatVersion"),
                    doc = Text(g, "docFormatVersion"), chunker = Text(g, "chunkerVersion"), state = Text(g, "state"), created = Text(g, "createdAt") }, tx);
            foreach (var m in seed.GetProperty("manifest").EnumerateArray())
                store.Connection.Execute("""
                    INSERT INTO index_generation_manifest(generation_id,source_id,revision_id,state,reason)
                    VALUES($generation,$source,$revision,$state,$reason)
                    """, new { generation = Id(m, "generationId"), source = Id(m, "sourceId"), revision = Id(m, "revisionId"),
                    state = Text(m, "state"), reason = NullableText(m, "reason") }, tx);
            foreach (var e in seed.GetProperty("embeddings").EnumerateArray())
            {
                byte[] blob = e.GetProperty("vector").EnumerateArray().SelectMany(v =>
                {
                    int bits = BitConverter.SingleToInt32Bits(v.GetSingle());
                    return new[] { (byte)bits, (byte)(bits >> 8), (byte)(bits >> 16), (byte)(bits >> 24) };
                }).ToArray();
                store.Connection.Execute("INSERT INTO chunk_embeddings(chunk_id,generation_id,embedding) VALUES($chunk,$generation,$blob)",
                    new { chunk = Id(e, "chunkId"), generation = Id(e, "generationId"), blob }, tx);
            }
            if (selected.GetProperty("active").ValueKind == JsonValueKind.Null)
                store.Connection.Execute("UPDATE index_generations SET state='retired' WHERE notebook_id=$notebook AND state='active'",
                    new { notebook = Id(selected, "notebookId") }, tx);
            tx.Commit();
            var counter = Counters.GetValue(store, _ => new Counter());
            Interlocked.Exchange(ref counter.Statements, 0);
            store.RetrievalStatementExecuted = _ => Interlocked.Increment(ref counter.Statements);
        }
    }

    internal static void ApplyEvent(string caseName, NotebookStore store)
    {
        var c = Cases().Single(c => c.GetProperty("name").GetString() == caseName);
        lock (store.Gate)
        {
            using var tx = store.Connection.BeginTransaction();
            foreach (var e in c.GetProperty("events").EnumerateArray())
                switch (Text(e, "kind"))
                {
                    case "setAvailability":
                        store.Connection.Execute("UPDATE sources SET availability=$value WHERE id=$source", new { source = Id(e, "sourceId"), value = Text(e, "value") }, tx);
                        break;
                    case "setEligible":
                        store.Connection.Execute("UPDATE sources SET eligible=$value WHERE id=$source", new { source = Id(e, "sourceId"), value = Id(e, "value") }, tx);
                        break;
                    case "setFolder":
                        store.Connection.Execute("UPDATE sources SET folder_id=$folder,rel_path=$path WHERE id=$source",
                            new { source = Id(e, "sourceId"), folder = Id(e, "folderId"), path = Text(e, "relPath") }, tx);
                        break;
                    case "publish":
                        long source = Id(e, "sourceId"), revision = Id(e, "revisionId");
                        string text = $"needle revision {revision}";
                        store.Connection.Execute("""
                            INSERT INTO source_revisions(id,source_id,revision,content_hash,canonical_text,text_format_version,chunker_version,created_at)
                            SELECT $revision,$source,coalesce(max(revision),0)+1,$hash,$text,1,1,'2026-01-01 00:00:00.000'
                            FROM source_revisions WHERE source_id=$source
                            """, new { source, revision, hash = $"fixture-{revision}", text }, tx);
                        store.Connection.Execute("INSERT INTO source_chunks(id,source_id,revision_id,ord,text,token_count) VALUES($chunk,$source,$revision,0,$text,4)",
                            new { chunk = revision * 10, source, revision, text }, tx);
                        store.Connection.Execute("UPDATE sources SET current_revision=$revision,published_revision_id=$revision WHERE id=$source", new { source, revision }, tx);
                        break;
                    case "switchGeneration":
                        store.Connection.Execute("UPDATE index_generations SET state='retired' WHERE id=$old", new { old = Id(e, "oldId") }, tx);
                        store.Connection.Execute("UPDATE index_generations SET state='active' WHERE id=$next", new { next = Id(e, "newId") }, tx);
                        break;
                    default: throw new InvalidOperationException("Unknown retrieval fixture event");
                }
            tx.Commit();
        }
    }

    internal static int SqlStatementCount(NotebookStore store) => Counters.TryGetValue(store, out var counter) ? Volatile.Read(ref counter.Statements) : 0;
    private static long Id(JsonElement row, string key) => row.GetProperty(key).GetInt64();
    private static string Text(JsonElement row, string key) => row.GetProperty(key).GetString()!;
    private static long? NullableId(JsonElement row, string key) => row.GetProperty(key).ValueKind == JsonValueKind.Null ? null : Id(row, key);
    private static string? NullableText(JsonElement row, string key) => row.GetProperty(key).ValueKind == JsonValueKind.Null ? null : Text(row, key);
}
