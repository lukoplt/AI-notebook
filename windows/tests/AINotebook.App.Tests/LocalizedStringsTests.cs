using System.Xml.Linq;
using Xunit;

namespace AINotebook.App.Tests;

public class LocalizedStringsTests
{
    private static HashSet<string> Names(string reswPath) =>
        XDocument.Load(reswPath).Root!
            .Elements("data")
            .Select(d => (string)d.Attribute("name")!)
            .ToHashSet();

    // NOTE: requires WinUI? No — pure XML. Runs anywhere with .NET (incl. Windows CI).
    [Fact]
    public void Both_languages_have_the_same_keys()
    {
        var en = Names("en.resw");
        var cs = Names("cs.resw");

        // In-app update check: +9 (updateBannerTitle, updateDownloadButton, updateLaterButton,
        // updateAutoCheckToggle, updateCheckNowButton, updateStatusChecking, updateStatusUpToDate,
        // updateStatusAvailable, updateStatusFailed).
        // W-1 PDF export: +1 (exportNotePdf).
        // W-3 personas: +5 (personaMenu, personaNone, personaNew,
        // personaNamePlaceholder, personaInstructionsPlaceholder).
        // WP2 provider failures: +5 localized, sanitized error categories.
        // WP6 folders, explicit scopes and re-index: +51 (ingestion-ui-v1 localization cases).
        // WP8 context pack: +32 (Overview, context preview, snapshot citations, omission reasons).
        // Grouped Sources: +7 (folderShowFiles, folderHideFiles, folderFilesCount, folderLoadMoreFiles,
        // folderNoFiles, sourceLanguageLabel, sourceLanguageMixed).
        // UI redesign W1 shell: +19 (shellNewChat … close; names shared with the macOS AppText.Key).
        // UI redesign W2 chat thread + composer: +21 (chatEmptyTitle, composer*, messageCopy, chatRetry, …).
        // UI redesign W3 right panel: +10 (sourcesAddText, folderSummary*, notesSearchPlaceholder, toolHistory,
        // contextPanel*, citationsPanelEmpty, citationPage).
        // UI redesign W4 document, settings page, tools: +12 (settings* sections, webSearchToggle, toolScope*, exportMenu).
        // UI redesign W5 cleanup: −18 keys only the removed pages used (chatSessionsLabel, chatErrorPrefix,
        // notesSectionTitle, sourcesSectionTitle, aiToolsEmpty*, webSearchToggleLabel, …).
        // macOS parity pass: +9 (settingsUpdates, settingsLimits, about*, toolScope, toolsPickTemplate, documentExport),
        // −11 (settingsProviders/License/Notices, toolScopeNotebook, exportMenu, renameChat*, unsaved* dialog keys).
        // UI redesign C1: +4 (renameChat, renameChatTitle, chatStopButton, chatStopped).
        // Office/OOXML indexing fix: +3 (sourceErrorMissingPart, sourceErrorDamaged, sourceErrorNotDownloaded).
        // Indexing progress: +20 (indexing* status strip, folderChecking, folderNoChanges, folderChangedFiles).
        // Memory pressure: +2 (indexingExtractingSlowed, indexingExtractingPaused).
        // Scan behind work (indexing-status-v1 §7): +1 (indexingWithScan).
        // Retry cap (ingestion-retry-cap-v1): +4 (indexingSourceErrorsGaveUp, indexingRetryAllFailed, sourceRetryButton,
        // sourceGaveUp).
        // Model listing limits (provider-listing-limits-v1 §5): +1 (contextPreviewSetContextSize).
        const int expected = 433;
        Assert.Equal(expected, en.Count);
        Assert.Equal(expected, cs.Count);
        Assert.True(en.SetEquals(cs), "en-US and cs-CZ must define the identical key set");
    }

    [Fact]
    public void Provider_controls_have_exact_English_and_Czech_text()
    {
        var en = XDocument.Load("en.resw").Root!.Elements("data").ToDictionary(x => (string)x.Attribute("name")!, x => x.Element("value")!.Value);
        var cs = XDocument.Load("cs.resw").Root!.Elements("data").ToDictionary(x => (string)x.Attribute("name")!, x => x.Element("value")!.Value);
        foreach (var (key, english, czech) in new[]
        {
            ("providerPresetLabel", "Preset", "Předvolba"),
            ("providerPresetCustom", "Custom", "Vlastní"),
            ("providerPresetLocalHelp", "Start the local server, then check its API root. An API key is optional.", "Spusťte místní server a ověřte kořen API. Klíč API je volitelný."),
            ("providerPresetRemoteHelp", "Enter your API key and check the API root.", "Zadejte klíč API a ověřte kořen API."),
            ("providerPresetCustomHelp", "Enter the exact API root, including any version or proxy path.", "Zadejte přesný kořen API včetně verze a cesty proxy."),
            ("providerRefreshModels", "Refresh models", "Obnovit modely"),
            ("providerManualModelId", "Model ID", "ID modelu"),
            ("providerApplyModel", "Apply model ID", "Použít ID modelu"),
            ("providerListingVerified", "Model listing verified. Generation has not been tested.", "Seznam modelů byl ověřen. Generování nebylo testováno."),
            ("providerListingUnsupported", "Model listing is unavailable; generation has not been verified. Enter a model ID manually.", "Seznam modelů není dostupný; generování nebylo ověřeno. Zadejte ID modelu ručně."),
            ("providerRuntimeContext", "Runtime context", "Použitý kontext"),
            ("providerMaxOutputTokens", "Maximum output tokens", "Maximum tokenů odpovědi"),
            ("providerContextWindow", "Model context limit", "Limit kontextu modelu"),
            ("providerContextUnknown", "Unknown", "Neznámý"),
            ("providerLimitsAssumption", "Application assumption", "Předpoklad aplikace"),
            ("providerLimitsUserOverride", "User override", "Uživatelské nastavení"),
            ("providerLimitsSave", "Save limits", "Uložit limity"),
            ("providerLimitsReset", "Reset to automatic", "Obnovit automatické nastavení"),
            ("providerLimitsInvalid", "Enter positive whole numbers. Output must be smaller than runtime context, which must not exceed the known model limit.", "Zadejte kladná celá čísla. Maximum odpovědi musí být menší než použitý kontext, který nesmí překročit známý limit modelu."),
            ("providerInvalidRoot", "Enter an HTTP or HTTPS API root without credentials, a query, or a fragment.", "Zadejte kořen API HTTP nebo HTTPS bez přihlašovacích údajů, dotazu a fragmentu."),
            ("providerContextTooLong", "The provider rejected the request length. Reduce runtime context.", "Poskytovatel odmítl délku požadavku. Snižte použitý kontext."),
            ("providerEmbeddingSelectionConverted", "The previous embedding provider supports chat only. Embeddings now use local Ollama (nomic-embed-text).", "Předchozí poskytovatel embeddingů podporuje pouze chat. Embeddingy nyní používají místní Ollamu (nomic-embed-text)."),
            ("providerConnectionFailed", "The provider could not be reached.", "K poskytovateli se nepodařilo připojit."),
            ("providerResponseInvalid", "The provider returned an unexpected response.", "Poskytovatel vrátil neočekávanou odpověď."),
            ("providerRequestFailed", "The provider request failed.", "Požadavek poskytovateli selhal."),
            ("providerSelectionUnavailable", "Select an enabled provider in Settings.", "V Nastavení vyberte povoleného poskytovatele."),
            ("providerEndpointUnsupported", "This provider does not support the requested operation.", "Tento poskytovatel nepodporuje požadovanou operaci."),
        })
        {
            Assert.Equal(english, en[key]);
            Assert.Equal(czech, cs[key]);
            Assert.True(Enum.TryParse<AINotebook.App.Services.StringKey>(char.ToUpperInvariant(key[0]) + key[1..], out _));
        }
    }

    [Fact]
    public void No_value_is_empty()
    {
        foreach (var path in new[] { "en.resw", "cs.resw" })
            foreach (var d in XDocument.Load(path).Root!.Elements("data"))
                Assert.False(string.IsNullOrWhiteSpace((string?)d.Element("value")),
                    $"{path}: '{(string?)d.Attribute("name")}' has no value");
    }
    /// <summary>UI redesign C1: Czech UI says "notebook" (declined), never "blok" (macOS LocalizationTests parity).</summary>
    [Fact]
    public void Czech_text_says_notebook_not_blok()
    {
        var blok = new System.Text.RegularExpressions.Regex(@"\b(poznámkov\w* )?blok(u|y|ů|em|ům|ích|ách)?\b",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        foreach (var d in XDocument.Load("cs.resw").Root!.Elements("data"))
        {
            string value = (string?)d.Element("value") ?? "";
            Assert.False(blok.IsMatch(value), $"{(string?)d.Attribute("name")}: {value}");
        }
    }
}
