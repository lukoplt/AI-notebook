using AINotebook.App.Shell;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>UI redesign W4: note document, settings page sections and the run-tool dialog.</summary>
public sealed class DocumentSettingsTests
{
    private static string Read(params string[] parts) => File.ReadAllText(Path.Combine([ShellNavigationTests.AppRoot(), .. parts]));

    [Fact]
    public void DocumentTopBarHasTitleStatusHistoryExportAndShortcuts()
    {
        string xaml = Read("Document", "NoteDocumentPage.xaml");
        foreach (string name in new[] { "BackButton", "TitleBox", "StatusText", "HistoryButton", "ExportButton", "ExportMarkdownItem",
            "ExportPdfItem", "SaveButton", "TogglePanelButton", "Editor", "AddTagButton" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        Assert.Contains("Modifiers=\"Control\" Key=\"S\"", xaml);
        Assert.Contains("Modifiers=\"Control,Shift\" Key=\"H\"", xaml);
        // The editor no longer carries its own title box or buttons (no "Save" literal).
        string editor = Read("Editor", "EditorWebView.xaml");
        Assert.DoesNotContain("Content=\"Save\"", editor);
        Assert.DoesNotContain("TitleBox", editor);
        Assert.False(File.Exists(Path.Combine(ShellNavigationTests.AppRoot(), "Views", "NotesPage.xaml")));
    }

    [Fact]
    public void SettingsPageHasEverySectionAndSetting()
    {
        Assert.Equal(6, Enum.GetValues<SettingsSection>().Length);
        string xaml = Read("Settings", "SettingsPage.xaml");
        foreach (string name in new[] { "GeneralSection", "ProvidersSection", "ModelsSection", "IndexingSection", "ToolsSection",
            "AboutSection", "LanguageCombo", "WebSearchToggle", "AutoUpdateToggle", "CheckUpdatesButton", "AddProviderButton",
            "ProvidersList", "ChatProviderCombo", "ChatModelCombo", "RefreshChatModelsButton", "ChatModelIdTextBox",
            "ApplyChatModelIdButton", "ManageModelsButton", "RuntimeContextTextBox", "MaxOutputTokensTextBox", "SaveLimitsButton",
            "ResetLimitsButton", "EmbeddingConversionNotice", "EmbedProviderCombo", "EmbedModelCombo", "EmbeddingModelIdTextBox",
            "ReindexButton", "ReindexDualSpaceNote", "IndexBuildsList", "VersionValue", "LicenseLink", "NoticesLink" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        Assert.Contains("<settings:TransformationEditorView />", xaml);
        // Privacy gate still guards cloud providers picked in the selectors.
        Assert.Contains("PrivacyGateDialog", Read("Settings", "SettingsPage.xaml.cs"));
        Assert.False(File.Exists(Path.Combine(ShellNavigationTests.AppRoot(), "Views", "SettingsDialog.xaml")));
    }

    [Fact]
    public void RunToolDialogReplacesTheTransformationsTab()
    {
        string xaml = Read("Tools", "RunToolDialog.xaml");
        foreach (string name in new[] { "TemplateCombo", "ScopeSeg", "ScopeSource", "ScopeNotebook", "ScopeAll", "SourceCombo", "RunBtn", "PreviewBtn" })
            Assert.Contains($"x:Name=\"{name}\"", xaml);
        Assert.DoesNotContain("Content=\"Source\"", xaml);
        Assert.DoesNotContain("Content=\"Notebook\"", xaml);
        Assert.False(File.Exists(Path.Combine(ShellNavigationTests.AppRoot(), "Views", "TransformationsPage.xaml")));
        Assert.DoesNotContain("Content=\"Source\"", Read("Settings", "TransformationEditorView.xaml"));
    }
}
