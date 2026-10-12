using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;

namespace AINotebook.App.ViewModels;

/// <summary>
/// One labelled block of the preview. Not 'required' and parameterless: the WinUI
/// XamlTypeInfo generator emits an activator for every x:DataType (see MessageViewModel).
/// </summary>
public sealed class ContextPreviewRow
{
    public string Label { get; set; } = "";
    public string Text { get; set; } = "";
}

/// <summary>
/// Immutable projection of one memory-only <see cref="ContextPreviewSnapshot"/>: logical
/// messages, the provider's exact wire order (Core's tested projection), options, token
/// estimates, coverage and the included/omitted ledgers. Labels are localized; the request's
/// model-facing text is shown unmodified. Never reads live provider settings or credentials.
/// </summary>
public sealed class ContextPreviewViewModel
{
    private static readonly IReadOnlyDictionary<string, StringKey> Reasons = new Dictionary<string, StringKey>
    {
        ["evidenceBudget"] = StringKey.ContextOmittedEvidenceBudget,
        ["topK"] = StringKey.ContextOmittedTopK,
        ["historyBudget"] = StringKey.ContextOmittedHistoryBudget,
        ["mapBudget"] = StringKey.ContextOmittedMapBudget,
        ["externalBudget"] = StringKey.ContextOmittedExternalBudget,
        ["truncated"] = StringKey.ContextOmittedTruncated,
        ["duplicate"] = StringKey.ContextOmittedDuplicate,
        ["revisionMismatch"] = StringKey.ContextOmittedRevisionMismatch,
        ["neighbourBudget"] = StringKey.ContextOmittedNeighbourBudget,
        ["legacyNoSpan"] = StringKey.ContextOmittedLegacyNoSpan,
        ["emptySelection"] = StringKey.ContextOmittedEmptySelection,
    };

    private readonly Func<StringKey, string> _text;

    public ContextPreviewViewModel() : this(null) { }

    public ContextPreviewViewModel(Func<StringKey, string>? text) => _text = text ?? (key => key.ToString());

    public ObservableCollection<ContextPreviewRow> Rows { get; } = new();
    /// <summary>Anthropic's top-level system text; null for providers that send it as a message.</summary>
    public string? WireSystem { get; private set; }
    public IReadOnlyList<ChatTurn> WireMessages { get; private set; } = Array.Empty<ChatTurn>();
    public string ProviderType { get; private set; } = "";
    public string ProviderId { get; private set; } = "";
    public string Model { get; private set; } = "";
    public int RuntimeContext { get; private set; }
    public int MaxOutputTokens { get; private set; }
    public int EstimatorVersion { get; private set; }
    /// <summary>Sum of section estimates plus 4 per logical message; never an exact tokenizer count.</summary>
    public long EstimatedTokens { get; private set; }
    public bool ContextWindowAssumed { get; private set; }
    public bool IsUnavailable { get; private set; }

    public static StringKey? ReasonKey(string reason) => Reasons.TryGetValue(reason, out var key) ? key : null;

    public void Load(ContextPreviewSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(snapshot);
        var request = snapshot.Request;
        IsUnavailable = false;
        ProviderType = snapshot.ProviderType;
        ProviderId = request.Model.ProviderId;
        Model = request.Model.Model;
        RuntimeContext = request.Model.RuntimeContext;
        MaxOutputTokens = request.Model.MaxOutputTokens;
        EstimatorVersion = request.EstimatorVersion;
        ContextWindowAssumed = !request.Model.ContextWindowKnown;
        EstimatedTokens = request.Messages.Sum(m => 4L + m.Sections.Sum(s => (long)s.Tokens));

        using (var wire = JsonDocument.Parse(ContextPackRendering.WireElement(request, snapshot.ProviderType).GetRawText()))
        {
            var root = wire.RootElement;
            WireSystem = root.TryGetProperty("system", out var system) ? system.GetString() : null;
            WireMessages = root.GetProperty("messages").EnumerateArray()
                .Select(m => new ChatTurn(ChatRoleExtensions.FromRawValue(m.GetProperty("role").GetString()!),
                    m.GetProperty("content").GetString()!))
                .ToArray();
        }

        Rows.Clear();
        string Invariant(FormattableString value) => value.ToString(CultureInfo.InvariantCulture);
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewOptions),
            Text = Invariant($"{ProviderType} · {ProviderId} · {Model}\n") + OptionsText(request)
        });
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewEstimatedTokens),
            Text = Invariant($"{EstimatedTokens} / {(long)RuntimeContext - MaxOutputTokens} (estimator v{EstimatorVersion})")
        });
        if (ContextWindowAssumed)
            Rows.Add(new ContextPreviewRow
            {
                Label = _text(StringKey.ContextPreviewAssumedLimit),
                Text = RuntimeContext.ToString(CultureInfo.InvariantCulture)
            });
        foreach (var message in request.Messages)
            foreach (var section in message.Sections)
                Rows.Add(new ContextPreviewRow
                {
                    Label = Invariant($"{_text(StringKey.ContextPreviewMessages)} · {message.Role} · {section.Kind} · {section.Tokens}"),
                    Text = section.Text
                });
        var order = new List<string>();
        if (WireSystem is not null) order.Add("system (top-level)");
        order.AddRange(WireMessages.Select(m => m.Role.RawValue()));
        Rows.Add(new ContextPreviewRow { Label = _text(StringKey.ContextPreviewWireOrder), Text = string.Join("\n", order) });
        var corpus = request.Coverage.Corpus;
        var turn = request.Coverage.Turn;
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewCoverage),
            Text = Invariant($"{(corpus.Partial ? "≥ " : "")}{corpus.FilesInScope} · {corpus.Searchable} / {corpus.Pending} / {corpus.Error} / {corpus.Skipped} / {corpus.Missing} / {corpus.Unavailable} · {corpus.RefreshPending} / {corpus.RefreshError}\n")
                + Invariant($"{turn.Passages} / {turn.FilesIncluded} · {turn.CandidatesWithPublishedChunks}{(turn.Overview ? " · Overview" : "")}")
        });
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewIncluded),
            Text = string.Join("\n", request.Included.Select(i => i.Kind + " " + i.Id))
        });
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewOmitted),
            Text = string.Join("\n", request.Omitted.Select(o => o.Kind + " " + o.Id + " — "
                + (ReasonKey(o.Reason) is StringKey key ? _text(key) : o.Reason)))
        });
    }

    /// <summary>An evicted or restarted sent preview; never rebuilt from current state.</summary>
    public void LoadUnavailable()
    {
        IsUnavailable = true;
        WireSystem = null;
        WireMessages = Array.Empty<ChatTurn>();
        Rows.Clear();
        Rows.Add(new ContextPreviewRow
        {
            Label = _text(StringKey.ContextPreviewTitle),
            Text = _text(StringKey.ContextPreviewUnavailable)
        });
    }

    /// <summary>A preparation in progress (or failed with the given localized message).</summary>
    public void LoadStatus(string message)
    {
        IsUnavailable = true;
        Rows.Clear();
        Rows.Add(new ContextPreviewRow { Label = _text(StringKey.ContextPreviewTitle), Text = message });
    }

    private static string OptionsText(PreparedContextRequest request)
    {
        var parts = new List<string>();
        // The provider adapter maps numCtx/maxTokens: Ollama num_ctx/num_predict, others max_tokens.
        if (request.Options.NumCtx is int context) parts.Add("num_ctx=" + context.ToString(CultureInfo.InvariantCulture));
        if (request.Options.MaxTokens is int output)
            parts.Add((request.Options.NumCtx is null ? "max_tokens=" : "num_predict=") + output.ToString(CultureInfo.InvariantCulture));
        return string.Join(", ", parts);
    }
}
