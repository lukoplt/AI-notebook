using System.Collections.ObjectModel;
using AINotebook.Core.Models;

namespace AINotebook.Core.Rag;

public sealed class ContextPackException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

public sealed record PackModel(string ProviderId, string Model, int RuntimeContext,
    int MaxOutputTokens, bool ContextWindowKnown, string ProviderType);
public sealed record PreparedPackModel(string ProviderId, string Model, int RuntimeContext,
    int MaxOutputTokens, bool ContextWindowKnown);
public sealed record ContextPreviewSnapshot(PreparedContextRequest Request, string ProviderType);

public sealed record PackScopeSnapshot(string Kind, string Name, long[] SourceIds,
    long[] FolderIds, string[] Languages, string? LastFullScan, string ScanState)
{
    private readonly long[] _sourceIds = SourceIds.ToArray();
    private readonly long[] _folderIds = FolderIds.ToArray();
    private readonly string[] _languages = Languages.ToArray();
    public long[] SourceIds { get => _sourceIds.ToArray(); init => _sourceIds = value.ToArray(); }
    public long[] FolderIds { get => _folderIds.ToArray(); init => _folderIds = value.ToArray(); }
    public string[] Languages { get => _languages.ToArray(); init => _languages = value.ToArray(); }
}

public sealed record PackCorpusCoverage(int FilesInScope, int Searchable, int Pending,
    int Error, int Skipped, int Missing, int Unavailable, int RefreshPending,
    int RefreshError, bool Partial);
public sealed record PackTurnCoverage(int Passages, int FilesIncluded,
    int CandidatesWithPublishedChunks, bool Overview);
public sealed record PackHistoryTurn(long Id, string User, string Assistant);
public sealed record PackExternal(string Id, string Kind, string Text, string Language);

/// <summary>Hydrated passage boundary: absolute for spans, relative for legacy text.</summary>
public sealed record PackPrefix(long End, int Tokens);
/// <summary>Budget-only prefix offsets are always relative to the passage start (§8).</summary>
public sealed record PackBudgetPrefix(long EndScalar, int Tokens);

public sealed record PackPassage(long ChunkId, long SourceId, long RevisionId, long? FolderId,
    string RelPath, string DisplayName, string Language, string Text, int Ordinal,
    long? Start, long? End, int? PageFrom, int? PageTo, long RrfMicro,
    PackPrefix[] TruncationCandidates)
{
    private readonly PackPrefix[] _truncationCandidates = (TruncationCandidates ?? []).ToArray();
    public PackPrefix[] TruncationCandidates
    {
        get => _truncationCandidates.ToArray();
        init => _truncationCandidates = (value ?? []).ToArray();
    }
}

/// <summary>PathRank: 1-based rank among the question's path matches (retrieval-paths-v1), null when
/// unmatched; MatchDate: YYYYMMDD of a path match, when known; MatchProject (retrieval-paths v2 §6): the
/// match's project directory, grouping inventory answers. All are omitted from JSON when null.</summary>
public sealed record PackFile(long SourceId, long? FolderId, string RelPath,
    string DisplayName, string Descriptor, bool MetadataMatch, long? PublishedRevisionId,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] int? PathRank = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] int? MatchDate = null,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? MatchProject = null);

/// <summary>An already scoped, hydrated snapshot. No live storage or provider state.</summary>
public sealed record ContextPackInput(string Question, string Mode, string UserInstructions,
    PackHistoryTurn[] History, PackExternal[] External, PackPassage[] Candidates,
    PackPassage[] Neighbours, PackPassage[] OverviewCandidates, PackFile[] FolderMap,
    PackScopeSnapshot Scope, PackCorpusCoverage Coverage, PackModel Model,
    long? GenerationId, IReadOnlyDictionary<string, long> SourceRevisions,
    int? EvidenceBudgetCap, int FetchK, int TopK,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] bool? PathInventory = null)
{
    private readonly PackHistoryTurn[] _history = History.ToArray();
    private readonly PackExternal[] _external = External.ToArray();
    private readonly PackPassage[] _candidates = Candidates.ToArray();
    private readonly PackPassage[] _neighbours = Neighbours.ToArray();
    private readonly PackPassage[] _overviewCandidates = OverviewCandidates.ToArray();
    private readonly PackFile[] _folderMap = FolderMap.ToArray();
    private readonly IReadOnlyDictionary<string, long> _sourceRevisions = CopyRevisions(SourceRevisions);
    public PackHistoryTurn[] History { get => _history.ToArray(); init => _history = value.ToArray(); }
    public PackExternal[] External { get => _external.ToArray(); init => _external = value.ToArray(); }
    public PackPassage[] Candidates { get => _candidates.ToArray(); init => _candidates = value.ToArray(); }
    public PackPassage[] Neighbours { get => _neighbours.ToArray(); init => _neighbours = value.ToArray(); }
    public PackPassage[] OverviewCandidates { get => _overviewCandidates.ToArray(); init => _overviewCandidates = value.ToArray(); }
    public PackFile[] FolderMap { get => _folderMap.ToArray(); init => _folderMap = value.ToArray(); }
    public IReadOnlyDictionary<string, long> SourceRevisions
    {
        get => CopyRevisions(_sourceRevisions);
        init => _sourceRevisions = CopyRevisions(value);
    }
    private static IReadOnlyDictionary<string, long> CopyRevisions(IReadOnlyDictionary<string, long> value) =>
        new ReadOnlyDictionary<string, long>(new Dictionary<string, long>(value, StringComparer.Ordinal));
}

public sealed record PackSection(string Kind, string Text, int Tokens);
public sealed record PackMessage(string Role, PackSection[] Sections)
{
    private readonly PackSection[] _sections = Sections.ToArray();
    public PackSection[] Sections { get => _sections.ToArray(); init => _sections = value.ToArray(); }
}
public sealed record PackItem(string Kind, string Id);
public sealed record PackOmission(string Kind, string Id, string Reason);
public sealed record PackOptions(int? NumCtx, int? MaxTokens);
public sealed record PackCoverage(PackCorpusCoverage Corpus, PackTurnCoverage Turn);
public sealed record PackSourceRevision(long SourceId, long RevisionId);

/// <summary>Frozen contract §1b request. Use PreparedContextRequestJson for its wire-neutral JSON.</summary>
public sealed record PreparedContextRequest(int EstimatorVersion, PreparedPackModel Model,
    PackMessage[] Messages, PackOptions Options, Citation[] CitationMap,
    PackItem[] Included, PackOmission[] Omitted, PackCoverage Coverage,
    long? GenerationId, PackSourceRevision[] SourceRevisions)
{
    private readonly PackMessage[] _messages = Messages.ToArray();
    private readonly Citation[] _citationMap = CopyCitations(CitationMap);
    private readonly PackItem[] _included = Included.ToArray();
    private readonly PackOmission[] _omitted = Omitted.ToArray();
    private readonly PackSourceRevision[] _sourceRevisions = SourceRevisions.ToArray();
    public PackMessage[] Messages { get => _messages.ToArray(); init => _messages = value.ToArray(); }
    public Citation[] CitationMap { get => CopyCitations(_citationMap); init => _citationMap = CopyCitations(value); }
    public PackItem[] Included { get => _included.ToArray(); init => _included = value.ToArray(); }
    public PackOmission[] Omitted { get => _omitted.ToArray(); init => _omitted = value.ToArray(); }
    public PackSourceRevision[] SourceRevisions { get => _sourceRevisions.ToArray(); init => _sourceRevisions = value.ToArray(); }
    private static Citation[] CopyCitations(Citation[] value) => value.Select(c => c with
    {
        Spans = Array.AsReadOnly(c.Spans.ToArray()),
        ChunkIds = Array.AsReadOnly(c.ChunkIds.ToArray())
    }).ToArray();
}

public sealed record PackBudgetPassage(long Id, int Tokens, PackBudgetPrefix[] TruncationCandidates)
{
    private readonly PackBudgetPrefix[] _truncationCandidates = (TruncationCandidates ?? []).ToArray();
    public PackBudgetPrefix[] TruncationCandidates
    {
        get => _truncationCandidates.ToArray();
        init => _truncationCandidates = (value ?? []).ToArray();
    }
}

public sealed record PackBudgetInput(int RuntimeContext, int MaxOutputTokens, int MandatoryTokens,
    int? EvidenceBudgetCap, int TopK, PackBudgetPassage[] Passages,
    int MapTokensDesired, int NoteWebTokensDesired, int[] HistoryTurnTokensNewestFirst,
    int? MapCeilingTokens = null, int? EvidenceCeilingTokens = null)
{
    private readonly PackBudgetPassage[] _passages = Passages.ToArray();
    private readonly int[] _history = HistoryTurnTokensNewestFirst.ToArray();
    public PackBudgetPassage[] Passages { get => _passages.ToArray(); init => _passages = value.ToArray(); }
    public int[] HistoryTurnTokensNewestFirst { get => _history.ToArray(); init => _history = value.ToArray(); }
}

public sealed record PackBudgetResult(int Remainder, int EvidenceTarget, long[] IncludedPassageIds,
    long? TruncatedPassageId, long? TruncatedPassageEndScalar, int? TruncatedPassageTokens,
    int EvidenceTokens, int MapTokens, int NoteWebTokens, int HistoryTurnsIncluded,
    int HistoryTokens, int UnusedTokens)
{
    private readonly long[] _includedPassageIds = IncludedPassageIds.ToArray();
    public long[] IncludedPassageIds { get => _includedPassageIds.ToArray(); init => _includedPassageIds = value.ToArray(); }
}
