using System.Xml.Linq;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>
/// WP8 Task 11: the context preview projection (logical messages, exact wire order, options,
/// assumption flag) and the exact EN/CS values of every new label. Pure: no DispatcherQueue.
/// </summary>
public sealed class ContextPackViewModelTests
{
    private static PreparedContextRequest Request(PackOptions options, bool contextWindowKnown = false) => new(1,
        new PreparedPackModel("provider-1", "test", 8192, 1024, contextWindowKnown),
        [new PackMessage("system", [new PackSection("rules", "RULES", 10)]),
         new PackMessage("user", [new PackSection("history", "old question", 12)]),
         new PackMessage("assistant", [new PackSection("history", "old answer", 12)]),
         new PackMessage("user", [new PackSection("question", "[QUESTION]\nnew question\n[/QUESTION]", 14)])],
        options, [], [], [new PackOmission("passage", "7", "topK")],
        new PackCoverage(new PackCorpusCoverage(0, 0, 0, 0, 0, 0, 0, 0, 0, false), new PackTurnCoverage(0, 0, 0, false)),
        null, []);

    [Fact]
    public void PreviewProjectsTheFrozenAnthropicOrderAndAssumption()
    {
        var vm = new ContextPreviewViewModel();
        vm.Load(new ContextPreviewSnapshot(Request(new PackOptions(null, 1024)), "anthropic"));
        Assert.True(vm.ContextWindowAssumed);
        Assert.Equal("RULES", vm.WireSystem);
        Assert.Equal(new[] { "user", "assistant", "user" }, vm.WireMessages.Select(m => m.Role.RawValue()));
        Assert.Equal("[QUESTION]\nnew question\n[/QUESTION]", vm.WireMessages[^1].Content);
        Assert.Equal(1024, vm.MaxOutputTokens);
        Assert.Equal(64, vm.EstimatedTokens);
        Assert.Contains(vm.Rows, r => r.Text == "max_tokens=1024" || r.Text.EndsWith("\nmax_tokens=1024", StringComparison.Ordinal));
        Assert.Equal("system (top-level)\nuser\nassistant\nuser",
            vm.Rows.Single(r => r.Label == nameof(StringKey.ContextPreviewWireOrder)).Text);
    }

    [Fact]
    public void OllamaPreviewKeepsRoleOrderSectionTextOptionsAndAssumption()
    {
        var vm = new ContextPreviewViewModel();
        vm.Load(new ContextPreviewSnapshot(Request(new PackOptions(8192, 1024)), "ollama"));
        Assert.Null(vm.WireSystem);
        Assert.Equal(new[] { "system", "user", "assistant", "user" }, vm.WireMessages.Select(m => m.Role.RawValue()));
        Assert.Equal(new[] { "RULES", "old question", "old answer", "[QUESTION]\nnew question\n[/QUESTION]" },
            vm.WireMessages.Select(m => m.Content));
        Assert.True(vm.ContextWindowAssumed);
        Assert.Contains(vm.Rows, r => r.Text.EndsWith("num_ctx=8192, num_predict=1024", StringComparison.Ordinal));
        var sections = vm.Rows.Where(r => r.Label.StartsWith(nameof(StringKey.ContextPreviewMessages), StringComparison.Ordinal)).ToArray();
        Assert.Equal(new[] { "RULES", "old question", "old answer", "[QUESTION]\nnew question\n[/QUESTION]" }, sections.Select(r => r.Text));
        Assert.Equal("ContextPreviewMessages · system · rules · 10", sections[0].Label);
        Assert.Contains(vm.Rows, r => r.Label == nameof(StringKey.ContextPreviewAssumedLimit) && r.Text == "8192");

        var known = new ContextPreviewViewModel();
        known.Load(new ContextPreviewSnapshot(Request(new PackOptions(8192, 1024), contextWindowKnown: true), "ollama"));
        Assert.False(known.ContextWindowAssumed);
        Assert.DoesNotContain(known.Rows, r => r.Label == nameof(StringKey.ContextPreviewAssumedLimit));
    }

    [Fact]
    public void OmissionsUseLocalizedReasonsAndEvictedPreviewsSayUnavailable()
    {
        var vm = new ContextPreviewViewModel(key => "<" + key + ">");
        vm.Load(new ContextPreviewSnapshot(Request(new PackOptions(null, 1024)), "openai"));
        Assert.Equal("passage 7 — <ContextOmittedTopK>", vm.Rows.Single(r => r.Label == "<ContextPreviewOmitted>").Text);
        foreach (var (reason, key) in new[]
        {
            ("evidenceBudget", StringKey.ContextOmittedEvidenceBudget), ("topK", StringKey.ContextOmittedTopK),
            ("historyBudget", StringKey.ContextOmittedHistoryBudget), ("mapBudget", StringKey.ContextOmittedMapBudget),
            ("externalBudget", StringKey.ContextOmittedExternalBudget), ("truncated", StringKey.ContextOmittedTruncated),
            ("duplicate", StringKey.ContextOmittedDuplicate), ("revisionMismatch", StringKey.ContextOmittedRevisionMismatch),
            ("neighbourBudget", StringKey.ContextOmittedNeighbourBudget), ("legacyNoSpan", StringKey.ContextOmittedLegacyNoSpan),
            ("emptySelection", StringKey.ContextOmittedEmptySelection),
        })
            Assert.Equal(key, ContextPreviewViewModel.ReasonKey(reason));
        vm.LoadUnavailable();
        Assert.True(vm.IsUnavailable);
        Assert.Equal("<ContextPreviewUnavailable>", Assert.Single(vm.Rows).Text);
    }

    public static IEnumerable<object[]> Labels() => new[]
    {
        new object[] { "chatOverviewToggle", "Overview", "Přehled" },
        new object[] { "contextPreviewBeforeSend", "Show what will be sent", "Zobrazit, co se pošle" },
        new object[] { "contextPreviewSent", "Show sent context", "Zobrazit odeslaný kontext" },
        new object[] { "contextPreviewTitle", "Context preview", "Náhled kontextu" },
        new object[] { "contextPreviewPreparing", "Preparing context…", "Připravuji kontext…" },
        new object[] { "contextPreviewUnavailable", "This context preview is no longer in memory.", "Tento náhled kontextu už není v paměti." },
        new object[] { "contextPreviewEstimatedTokens", "Estimated tokens", "Odhad tokenů" },
        new object[] { "contextPreviewAssumedLimit", "Context size assumed by the app", "Velikost kontextu předpokládaná aplikací" },
        new object[] { "contextPreviewMessages", "Logical messages", "Logické zprávy" },
        new object[] { "contextPreviewWireOrder", "Sent message order", "Pořadí odeslaných zpráv" },
        new object[] { "contextPreviewOptions", "Request options", "Nastavení požadavku" },
        new object[] { "contextPreviewIncluded", "Included content", "Zahrnutý obsah" },
        new object[] { "contextPreviewOmitted", "Omitted content", "Vynechaný obsah" },
        new object[] { "contextPreviewCoverage", "Scope and turn coverage", "Pokrytí rozsahu a dotazu" },
        new object[] { "contextPreviewRecalculate", "Recalculate preview", "Přepočítat náhled" },
        new object[] { "contextPreviewClose", "Close preview", "Zavřít náhled" },
        new object[] { "contextTooSmall", "Context is too small. Increase its size or shorten the instructions.", "Kontext je příliš malý. Zvětšete ho nebo zkraťte instrukce." },
        new object[] { "citationOpenOriginal", "Open original", "Otevřít originál" },
        new object[] { "citationRevisionChanged", "The original has changed since this answer.", "Originál se od této odpovědi změnil." },
        new object[] { "citationOriginalUnavailable", "The original is unavailable.", "Originál není dostupný." },
        new object[] { "citationOriginalOutsideFolder", "The original is outside the selected folder.", "Originál je mimo vybranou složku." },
        new object[] { "contextOmittedEvidenceBudget", "Evidence budget exhausted", "Vyčerpán rozpočet důkazů" },
        new object[] { "contextOmittedTopK", "Passage limit reached", "Dosažen limit pasáží" },
        new object[] { "contextOmittedHistoryBudget", "Complete conversation turn did not fit", "Celý tah konverzace se nevešel" },
        new object[] { "contextOmittedMapBudget", "Map budget exhausted", "Vyčerpán rozpočet mapy" },
        new object[] { "contextOmittedExternalBudget", "Additional context did not fit", "Doplňující kontext se nevešel" },
        new object[] { "contextOmittedTruncated", "Excerpt shortened at a sentence boundary", "Úryvek zkrácen na hranici věty" },
        new object[] { "contextOmittedDuplicate", "Duplicate excerpt", "Duplicitní úryvek" },
        new object[] { "contextOmittedRevisionMismatch", "Different document revision", "Jiná revize dokumentu" },
        new object[] { "contextOmittedNeighbourBudget", "Neighbouring excerpt did not fit", "Sousední úryvek se nevešel" },
        new object[] { "contextOmittedLegacyNoSpan", "Legacy excerpt has no position data", "Starší úryvek nemá údaje o pozici" },
        new object[] { "contextOmittedEmptySelection", "No sources selected", "Nejsou vybrány žádné zdroje" }
    };

    [Theory]
    [MemberData(nameof(Labels))]
    public void ContextLabelsAreExact(string key, string english, string czech)
    {
        foreach (var (path, expected) in new[] { ("en.resw", english), ("cs.resw", czech) })
        {
            var row = XDocument.Load(path).Root!.Elements("data").Single(e => (string?)e.Attribute("name") == key);
            Assert.Equal(expected, (string?)row.Element("value"));
        }
        Assert.True(Enum.TryParse<StringKey>(char.ToUpperInvariant(key[0]) + key[1..], out _));
    }

    [Fact]
    public void ThereAreExactly32ContextPackLabels() => Assert.Equal(32, Labels().Count());
}
