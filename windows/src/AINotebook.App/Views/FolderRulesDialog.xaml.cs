using System.Globalization;
using AINotebook.App.Services;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Language;
using AINotebook.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

/// <summary>
/// Pure, UI-free folder-rule draft: comma-separated include extensions, newline ignore patterns, six positive integer
/// limits and the encoding fallback. Parsing compiles every glob and validates the process safety ceilings with Core.
/// </summary>
public sealed record FolderRulesDraft(string IncludeExtensions, string IgnoreGlobs, string FileBytes, string OfficeBytes,
    string TextScalars, string PdfPages, string Chunks, string Cells, string Encoding)
{
    public static FolderRulesDraft From(FolderSource folder)
    {
        ArgumentNullException.ThrowIfNull(folder);
        IngestionLimits limits;
        try { limits = IngestionLimits.FromJson(folder.Draft.LimitsJSON); }
        catch (FolderIngestionException) { limits = IngestionLimits.Defaults; }
        string N(long value) => value.ToString(CultureInfo.InvariantCulture);
        return new FolderRulesDraft(string.Join(", ", folder.Draft.IncludeExts), string.Join("\n", folder.Draft.IgnoreGlobs),
            N(limits.FileBytes), N(limits.OfficeBytes), N(limits.TextScalars), N(limits.PdfPages), N(limits.Chunks), N(limits.Cells),
            folder.Draft.EncodingFallback);
    }

    /// <summary>Returns validated rules, or null when any field is invalid (Save stays disabled).</summary>
    public FolderRules? TryBuild(UnicodeTables tables, bool caseSensitive)
    {
        ArgumentNullException.ThrowIfNull(tables);
        try
        {
            var extensions = IncludeExtensions.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            var globs = IgnoreGlobs.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n')
                .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (extensions.Length == 0) return null;
            var limits = new IngestionLimits(Positive(FileBytes), Positive(OfficeBytes), Narrow(TextScalars), Narrow(PdfPages),
                Narrow(Chunks), Narrow(Cells));
            return new FolderRules(extensions, globs, limits, Encoding).Validate(tables, caseSensitive);
        }
        catch (FolderIngestionException) { return null; }
        catch (FormatException) { return null; }
        catch (OverflowException) { return null; }
    }

    private static long Positive(string text)
    {
        long value = long.Parse(text.Trim(), NumberStyles.None, CultureInfo.InvariantCulture);
        return value > 0 ? value : throw new FormatException();
    }

    private static int Narrow(string text) => checked((int)Positive(text));
}

/// <summary>Edits a folder's rules. Saving awaits the Core rule transaction; failures keep the dialog open.</summary>
public sealed partial class FolderRulesDialog : ContentDialog
{
    private readonly FolderSource _folder;
    private readonly Func<FolderRules, Task> _save;
    private readonly ILocalizedStrings _strings;
    private readonly UnicodeTables _tables = UnicodeTables.LoadBundled();
    private FolderRules? _rules;
    private bool _loading = true;

    public FolderRulesDialog(FolderSource folder, Func<FolderRules, Task> save, ILocalizedStrings strings)
    {
        InitializeComponent();
        _folder = folder ?? throw new ArgumentNullException(nameof(folder));
        _save = save ?? throw new ArgumentNullException(nameof(save));
        _strings = strings ?? throw new ArgumentNullException(nameof(strings));

        Title = strings.Get(StringKey.FolderRulesTitle);
        PrimaryButtonText = strings.Get(StringKey.Save);
        CloseButtonText = strings.Get(StringKey.CancelButton);
        IncludeExtensionsBox.Header = strings.Get(StringKey.FolderIncludeExtensions);
        IgnoreGlobsBox.Header = strings.Get(StringKey.FolderIgnoreGlobs);
        FileBytesBox.Header = strings.Get(StringKey.FolderMaxFileBytes);
        OfficeBytesBox.Header = strings.Get(StringKey.FolderMaxOfficeBytes);
        TextScalarsBox.Header = strings.Get(StringKey.FolderMaxTextScalars);
        PdfPagesBox.Header = strings.Get(StringKey.FolderMaxPdfPages);
        ChunksBox.Header = strings.Get(StringKey.FolderMaxChunks);
        CellsBox.Header = strings.Get(StringKey.FolderMaxCells);
        EncodingBox.Header = strings.Get(StringKey.FolderEncodingFallback);
        EncodingCp1250Item.Content = strings.Get(StringKey.FolderEncodingCp1250);
        EncodingNoneItem.Content = strings.Get(StringKey.FolderEncodingNone);
        ValidationText.Text = strings.Get(StringKey.FolderRulesInvalid);
        ValidationText.Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["DangerBrush"];

        var draft = FolderRulesDraft.From(folder);
        IncludeExtensionsBox.Text = draft.IncludeExtensions;
        IgnoreGlobsBox.Text = draft.IgnoreGlobs;
        FileBytesBox.Text = draft.FileBytes;
        OfficeBytesBox.Text = draft.OfficeBytes;
        TextScalarsBox.Text = draft.TextScalars;
        PdfPagesBox.Text = draft.PdfPages;
        ChunksBox.Text = draft.Chunks;
        CellsBox.Text = draft.Cells;
        EncodingBox.SelectedItem = draft.Encoding == "none" ? EncodingNoneItem : EncodingCp1250Item;
        _loading = false;
        Validate();
    }

    private FolderRulesDraft Draft() => new(IncludeExtensionsBox.Text, IgnoreGlobsBox.Text, FileBytesBox.Text, OfficeBytesBox.Text,
        TextScalarsBox.Text, PdfPagesBox.Text, ChunksBox.Text, CellsBox.Text,
        (EncodingBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "cp1250");

    private void Validate()
    {
        if (_loading) return;
        // Glob validity is independent of the volume's case policy; folding is the conservative default.
        _rules = Draft().TryBuild(_tables, caseSensitive: false);
        IsPrimaryButtonEnabled = _rules is not null;
        ValidationText.Visibility = _rules is null ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnFieldChanged(object sender, TextChangedEventArgs e) => Validate();
    private void OnEncodingChanged(object sender, SelectionChangedEventArgs e) => Validate();

    private async void OnPrimaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        try
        {
            if (_rules is null)
            {
                args.Cancel = true;
                return;
            }
            await _save(_rules);
        }
        catch (Exception)
        {
            // Keep the dialog open; the rules were not committed.
            args.Cancel = true;
            ValidationText.Visibility = Visibility.Visible;
        }
        finally
        {
            deferral.Complete();
        }
    }
}
