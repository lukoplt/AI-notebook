using System.Collections.ObjectModel;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Rag;

namespace AINotebook.Core.Eval;

public sealed class EvalFailure(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed record EvalDocument(string DocumentId, long SourceId, long NotebookId, long? FolderId,
    string Path, string RelPath, string Language, string Encoding, string RawSha256, string ContentHash);

public sealed record EvalGold(string DocumentId, string ContentHash, string Phrase, int Occurrence);

public sealed record EvalQuestion(string QueryId, string Text, string Language, string CaseType,
    IReadOnlyList<string> Tags, long NotebookId, RetrievalScope Scope, IReadOnlyList<EvalGold> Gold,
    string? AbsentReason, IReadOnlyList<string> OverviewDocumentIds);

public sealed record EvalSpan(string DocumentId, string ContentHash, int Start, int End);
public sealed record EvalWindow(int Start, int End, string Text);
public sealed record LoadedEvalDocument(EvalDocument Metadata, string Text);

/// <summary>
/// Validated, immutable corpus text and exact scalar gold. The caller supplies file bytes;
/// this loader performs no filesystem, store, provider or language-detector operations.
/// </summary>
public sealed class EvalCorpus
{
    private const long MaxJsonId = 9_007_199_254_740_991;

    public string CorpusId { get; }
    public IReadOnlyList<LoadedEvalDocument> Documents { get; }
    public IReadOnlyList<EvalQuestion> Questions { get; }
    public IReadOnlyDictionary<string, IReadOnlyList<EvalSpan>> Gold { get; }

    private EvalCorpus(string corpusId, List<LoadedEvalDocument> documents,
        IReadOnlyList<EvalQuestion> questions, Dictionary<string, IReadOnlyList<EvalSpan>> gold)
    {
        CorpusId = corpusId;
        Documents = documents.AsReadOnly();
        Questions = questions;
        Gold = new ReadOnlyDictionary<string, IReadOnlyList<EvalSpan>>(gold);
    }

    public static EvalCorpus Load(byte[] manifest, byte[] queries, Func<string, byte[]> readFile)
    {
        try
        {
            using var manifestJson = JsonDocument.Parse(manifest);
            using var queriesJson = JsonDocument.Parse(queries);
            var m = manifestJson.RootElement;
            var qs = queriesJson.RootElement;
            ValidateStrings(m);
            ValidateStrings(qs);
            Require(String(m, "contract") == "eval-corpus" && Integer(m.GetProperty("version")) == 1);
            Require(String(qs, "contract") == "eval-queries" && Integer(qs.GetProperty("version")) == 1);
            var corpusId = String(m, "corpus_id");
            Require(IsIdentifier(corpusId) && corpusId == String(qs, "corpus_id"));
            Require(String(m, "license") == "MIT");
            var metadata = m.GetProperty("documents").EnumerateArray().Select(ParseDocument).ToArray();
            var questions = Array.AsReadOnly(qs.GetProperty("queries").EnumerateArray().Select(ParseQuestion).ToArray());
            Require(metadata.Length > 0 && questions.Count > 0);

            // Identity checks precede path validation and all file reads.
            var documentIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var d in metadata)
                if (!documentIds.Add(d.DocumentId)) throw new EvalFailure("duplicate_document");
            var sourceIds = new HashSet<long>();
            foreach (var d in metadata)
                if (!sourceIds.Add(d.SourceId)) throw new EvalFailure("duplicate_source");
            var queryIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var q in questions)
                if (!queryIds.Add(q.QueryId)) throw new EvalFailure("duplicate_query");

            var folderNotebooks = new Dictionary<long, long>();
            // ValueTuple string equality is ordinal, with no Unicode normalization.
            var folderPaths = new HashSet<(long NotebookId, long FolderId, string RelPath)>();
            foreach (var d in metadata)
            {
                if (d.FolderId is not long folderId) continue;
                Require(!folderNotebooks.TryGetValue(folderId, out var notebookId) || notebookId == d.NotebookId);
                folderNotebooks[folderId] = d.NotebookId;
                if (!folderPaths.Add((d.NotebookId, folderId, d.RelPath))) throw new EvalFailure("invalid_path");
            }

            var documents = new List<LoadedEvalDocument>();
            var byId = new Dictionary<string, LoadedEvalDocument>(StringComparer.Ordinal);
            foreach (var d in metadata)
            {
                if (!SafeRelativePath(d.Path) || !SafeRelativePath(d.RelPath)) throw new EvalFailure("invalid_path");
                if (!IsHash(d.RawSha256) || !IsHash(d.ContentHash)) throw new EvalFailure("invalid_hash");
                byte[] bytes;
                try { bytes = readFile(d.Path); }
                catch (EvalFailure) { throw; }
                catch (Exception) { throw new EvalFailure("missing_file"); }
                if (Sha256(bytes) != d.RawSha256) throw new EvalFailure("raw_hash_mismatch");
                var text = Decode(bytes, d.Encoding);
                if (Sha256(Encoding.UTF8.GetBytes(text)) != d.ContentHash) throw new EvalFailure("content_hash_mismatch");
                var loaded = new LoadedEvalDocument(d, text);
                documents.Add(loaded);
                byId.Add(d.DocumentId, loaded);
            }

            var gold = new Dictionary<string, IReadOnlyList<EvalSpan>>(StringComparer.Ordinal);
            var corpus = new EvalCorpus(corpusId, documents, questions, gold);
            var notebooks = metadata.Select(d => d.NotebookId).ToHashSet();
            foreach (var q in questions)
            {
                Require(notebooks.Contains(q.NotebookId));
                if (q.Scope is RetrievalScope.Selection selection)
                    Require(selection.SourceIds.All(sourceIds.Contains) && selection.FolderIds.All(folderNotebooks.ContainsKey));
                var selectedIds = corpus.SelectedDocuments(q).Select(d => d.Metadata.DocumentId).ToHashSet(StringComparer.Ordinal);
                ValidateQuestionShape(q, selectedIds);
                if (q.Gold.Distinct().Count() != q.Gold.Count) throw new EvalFailure("invalid_gold");
                var resolved = new List<EvalSpan>();
                foreach (var g in q.Gold)
                {
                    if (!byId.TryGetValue(g.DocumentId, out var doc)) throw new EvalFailure("unknown_document");
                    if (!IsHash(g.ContentHash)) throw new EvalFailure("invalid_hash");
                    if (g.ContentHash != doc.Metadata.ContentHash) throw new EvalFailure("gold_hash_mismatch");
                    if (!selectedIds.Contains(g.DocumentId)) throw new EvalFailure("gold_out_of_scope");
                    var span = Occurrence(doc.Text, g.Phrase, g.Occurrence);
                    resolved.Add(new(g.DocumentId, g.ContentHash, span.Start, span.End));
                }
                gold.Add(q.QueryId, resolved.AsReadOnly());
            }
            return corpus;
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or OverflowException)
        {
            throw new EvalFailure("invalid_query");
        }
    }

    public static string Sha256(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    public static string Decode(byte[] bytes, string encoding)
    {
        try
        {
            // GetString retains a UTF-8 BOM as U+FEFF, part of canonical text.
            if (encoding == "utf-8") return new UTF8Encoding(false, true).GetString(bytes);
            if (encoding != "windows-1250") throw new EvalFailure("invalid_encoding");
            // .NET otherwise maps these undefined code-page bytes to controls.
            if (bytes.Any(b => b is 0x81 or 0x83 or 0x88 or 0x90 or 0x98))
                throw new EvalFailure("invalid_encoding");
            Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
            return Encoding.GetEncoding(1250, EncoderFallback.ExceptionFallback,
                DecoderFallback.ExceptionFallback).GetString(bytes);
        }
        catch (DecoderFallbackException) { throw new EvalFailure("invalid_encoding"); }
    }

    public static (int Start, int End) Occurrence(string text, string phrase, int number)
    {
        var haystack = text.EnumerateRunes().ToArray();
        var needle = phrase.EnumerateRunes().ToArray();
        if (needle.Length == 0 || number < 1) throw new EvalFailure("invalid_gold");
        var seen = 0;
        for (var start = 0; start <= haystack.Length - needle.Length; start++)
            if (haystack.AsSpan(start, needle.Length).SequenceEqual(needle) && ++seen == number)
                return (start, start + needle.Length);
        throw new EvalFailure("occurrence_not_found");
    }

    public static bool SafeRelativePath(string path) =>
        path.Length > 0 && !path.Contains('\\') && !path.Contains(':')
        && path.Split('/').All(p => p.Length > 0 && p != "." && p != "..");

    /// <summary>eval-scalars-v1: exact scalar windows, without trimming or normalization.</summary>
    public static IReadOnlyList<EvalWindow> Windows(string text, int size = 2048, int overlap = 256)
    {
        if (size <= 0 || overlap < 0 || overlap >= size) throw new EvalFailure("invalid_window");
        var scalars = text.EnumerateRunes().ToArray();
        var result = new List<EvalWindow>();
        var start = 0;
        while (start < scalars.Length)
        {
            var end = start + Math.Min(size, scalars.Length - start);
            var b = new StringBuilder();
            for (var i = start; i < end; i++) b.Append(scalars[i].ToString());
            result.Add(new(start, end, b.ToString()));
            if (end == scalars.Length) break;
            start = end - overlap;
        }
        return result.AsReadOnly();
    }

    public IReadOnlyList<LoadedEvalDocument> SelectedDocuments(EvalQuestion question) =>
        Documents.Where(d => d.Metadata.NotebookId == question.NotebookId && (question.Scope switch
        {
            RetrievalScope.All => true,
            RetrievalScope.Selection s => s.SourceIds.Contains(d.Metadata.SourceId)
                || d.Metadata.FolderId is long folder && s.FolderIds.Contains(folder),
            _ => false
        })).ToArray();

    private static EvalDocument ParseDocument(JsonElement d)
    {
        var id = String(d, "document_id");
        var language = String(d, "language");
        Require(IsIdentifier(id) && language is "cs" or "sk" or "en" or "de" or "mixed");
        var folder = d.GetProperty("folder_id");
        return new(id, Id(d.GetProperty("source_id")), Id(d.GetProperty("notebook_id")),
            folder.ValueKind == JsonValueKind.Null ? null : Id(folder), String(d, "path"), String(d, "rel_path"),
            language, String(d, "encoding"), String(d, "raw_sha256"), String(d, "content_hash"));
    }

    private static EvalQuestion ParseQuestion(JsonElement q)
    {
        var id = String(q, "query_id");
        var text = String(q, "text");
        var language = String(q, "language");
        var caseType = String(q, "case_type");
        Require(IsIdentifier(id) && text.Length > 0 && language is "cs" or "sk" or "en" or "de");
        Require(caseType is "answer" or "exact_identifier" or "scope" or "absent" or "empty_selection" or "overview");
        var scope = q.GetProperty("scope");
        // The WP0 codec accepts integral floating-point tokens; eval IDs are stricter.
        foreach (var key in new[] { "sourceIds", "folderIds" })
            if (scope.TryGetProperty(key, out var ids))
                foreach (var item in ids.EnumerateArray()) _ = Id(item);
        var gold = Array.AsReadOnly(q.GetProperty("gold").EnumerateArray().Select(g => new EvalGold(
            String(g, "document_id"), String(g, "content_hash"), String(g, "phrase"),
            checked((int)Integer(g.GetProperty("occurrence"))))).ToArray());
        var reason = q.GetProperty("absent_reason");
        return new(id, text, language, caseType, Strings(q.GetProperty("tags")), Id(q.GetProperty("notebook_id")),
            RetrievalScopeJson.Deserialize(scope.GetRawText()), gold,
            reason.ValueKind == JsonValueKind.Null ? null : StringValue(reason), Strings(q.GetProperty("overview_document_ids")));
    }

    private static void ValidateQuestionShape(EvalQuestion q, HashSet<string> selectedIds)
    {
        switch (q.CaseType)
        {
            case "absent":
                Require(q.AbsentReason == "not_in_corpus" && q.Gold.Count == 0 && q.OverviewDocumentIds.Count == 0);
                break;
            case "empty_selection":
                Require(q.AbsentReason == "empty_scope" && q.Gold.Count == 0
                    && q.OverviewDocumentIds.Count == 0 && selectedIds.Count == 0);
                break;
            case "overview":
                var overviewIds = q.OverviewDocumentIds.ToHashSet(StringComparer.Ordinal);
                Require(q.AbsentReason is null && overviewIds.Count > 0 && overviewIds.Count == q.OverviewDocumentIds.Count
                    && overviewIds.IsSubsetOf(selectedIds) && overviewIds.SetEquals(q.Gold.Select(g => g.DocumentId)));
                break;
            default:
                Require(q.AbsentReason is null && q.Gold.Count > 0 && q.OverviewDocumentIds.Count == 0);
                break;
        }
    }

    private static string String(JsonElement parent, string key) => StringValue(parent.GetProperty(key));

    private static string StringValue(JsonElement value)
    {
        Require(value.ValueKind == JsonValueKind.String);
        return value.GetString()!;
    }

    private static IReadOnlyList<string> Strings(JsonElement array) =>
        Array.AsReadOnly(array.EnumerateArray().Select(StringValue).ToArray());

    private static long Integer(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Number || value.GetRawText().IndexOfAny(['.', 'e', 'E']) >= 0
            || !value.TryGetInt64(out var number)) throw new EvalFailure("invalid_query");
        return number;
    }

    private static long Id(JsonElement value)
    {
        var id = Integer(value);
        Require(id > 0 && id <= MaxJsonId);
        return id;
    }

    private static bool IsIdentifier(string value) => value.Length > 0
        && IsAsciiLowerOrDigit(value[0]) && value.All(c => IsAsciiLowerOrDigit(c) || c == '-');

    private static bool IsAsciiLowerOrDigit(char c) => c is >= 'a' and <= 'z' or >= '0' and <= '9';

    private static bool IsHash(string value) => value.Length == 64
        && value.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    private static void Require(bool condition)
    {
        if (!condition) throw new EvalFailure("invalid_query");
    }

    private static void ValidateStrings(JsonElement element)
    {
        // GetString (and property.Name) throws on unpaired surrogate escapes, including
        // strings in ignored fields. Validate before any Rune enumeration can replace them.
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
                _ = element.GetString();
                break;
            case JsonValueKind.Array:
                foreach (var value in element.EnumerateArray()) ValidateStrings(value);
                break;
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    _ = property.Name;
                    ValidateStrings(property.Value);
                }
                break;
        }
    }
}
