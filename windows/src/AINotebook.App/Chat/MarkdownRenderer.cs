using AINotebook.Core.Text;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;

namespace AINotebook.App.Chat;

/// <summary>
/// Renders a MarkdownLite answer (spec §5) as token-styled WinUI blocks: RichTextBlocks for text,
/// a bordered block for quotes and code, and inline pill buttons for [N] citations. The parse and
/// flattening live in the pure <see cref="MarkdownRenderPlan"/>; this class only maps it.
/// </summary>
public static class MarkdownRenderer
{
    private static object Res(string key) => Application.Current.Resources[key];
    private static double Size(string key) => (double)Res(key);
    private static Brush Brush(string key) => (Brush)Res(key);

    /// <summary>Replaces <paramref name="host"/>'s children with the rendered answer.</summary>
    public static void Render(Panel host, string markdown, Action<int>? onCite)
    {
        host.Children.Clear();
        foreach (var block in MarkdownRenderPlan.Build(markdown)) host.Children.Add(Build(block, onCite));
    }

    private static UIElement Build(RenderBlock block, Action<int>? onCite)
    {
        switch (block.Kind)
        {
            case RenderBlockKind.Heading:
            {
                var text = Rich(block.Spans, onCite, Brush("Text1Brush"));
                (text.FontSize, text.LineHeight) = block.Level switch
                {
                    1 => (Size("FontSizeTitle"), Size("LineHeightTitle")),
                    2 => (Size("FontSizeHeadline"), Size("LineHeightHeadline")),
                    _ => (Size("FontSizeMessage"), Size("LineHeightMessage")),
                };
                text.FontWeight = FontWeights.SemiBold;
                text.Margin = new Thickness(0, Size("Space8"), 0, 0);
                return text;
            }
            case RenderBlockKind.ListItem:
            {
                var spans = new List<RenderSpan> { new(block.Marker + "  ") };
                spans.AddRange(block.Spans);
                var text = Rich(spans, onCite, Brush("Text1Brush"));
                double indent = Size("Space12");
                ((Paragraph)text.Blocks[0]).TextIndent = -indent;
                text.Margin = new Thickness(Size("Space16") * (block.Level - 1) + indent, 0, 0, 0);
                return text;
            }
            case RenderBlockKind.Quote:
                return new Border
                {
                    BorderBrush = Brush("BorderBrush"),
                    BorderThickness = new Thickness(Size("SizeFocusRing"), 0, 0, 0),
                    Padding = new Thickness(Size("Space12"), 0, 0, 0),
                    Child = Rich(block.Spans, onCite, Brush("Text2Brush")),
                };
            case RenderBlockKind.Code:
                return new Border
                {
                    Background = Brush("Surface2Brush"),
                    CornerRadius = (CornerRadius)Res("RadiusSm"),
                    Padding = (Thickness)Res("Pad12"),
                    Child = new ScrollViewer
                    {
                        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                        HorizontalScrollMode = ScrollMode.Auto,
                        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                        VerticalScrollMode = ScrollMode.Disabled,
                        Content = new TextBlock
                        {
                            Text = block.CodeText ?? "",
                            Style = (Style)Res("TextMono"),
                            Foreground = Brush("Text1Brush"),
                            IsTextSelectionEnabled = true,
                        },
                    },
                };
            case RenderBlockKind.Rule:
                return new Border
                {
                    Height = Size("SizeBorderWidth"),
                    Background = Brush("BorderBrush"),
                    Margin = new Thickness(0, Size("Space8"), 0, Size("Space8")),
                };
            default:
                return Rich(block.Spans, onCite, Brush("Text1Brush"));
        }
    }

    private static RichTextBlock Rich(IReadOnlyList<RenderSpan> spans, Action<int>? onCite, Brush foreground)
    {
        var rich = new RichTextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            IsTextSelectionEnabled = true,
            FontFamily = (FontFamily)Res("FontText"),
            FontSize = Size("FontSizeMessage"),
            LineHeight = Size("LineHeightMessage"),
            LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
            Foreground = foreground,
        };
        var paragraph = new Paragraph();
        foreach (var span in spans)
        {
            if (span.Cite is int number)
            {
                paragraph.Inlines.Add(CitationChip(number, onCite));
                continue;
            }
            var run = new Run { Text = span.Text };
            if (span.Strong) run.FontWeight = FontWeights.SemiBold;
            if (span.Emphasis) run.FontStyle = Windows.UI.Text.FontStyle.Italic;
            if (span.Code)
            {
                run.FontFamily = (FontFamily)Res("FontMono");
                run.FontSize = Size("FontSizeMono");
            }
            if (span.Href is { } href && Uri.TryCreate(href, UriKind.Absolute, out var uri))
            {
                // MarkdownLite only emits http(s)/mailto links; anything else stays text.
                var link = new Hyperlink { NavigateUri = uri, Foreground = Brush("FocusBrush") };
                link.Inlines.Add(run);
                paragraph.Inlines.Add(link);
            }
            else paragraph.Inlines.Add(run);
        }
        rich.Blocks.Add(paragraph);
        return rich;
    }

    /// <summary>[N] as a small pill; a click opens the Citations panel on that citation.</summary>
    private static InlineUIContainer CitationChip(int number, Action<int>? onCite)
    {
        var label = "[" + number.ToString(System.Globalization.CultureInfo.InvariantCulture) + "]";
        var button = new Button
        {
            Content = number.ToString(System.Globalization.CultureInfo.InvariantCulture),
            Style = (Style)Res("CitationChipStyle"),
            Margin = new Thickness(Size("Space4") / 2, 0, Size("Space4") / 2, 0),
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => onCite?.Invoke(number);
        return new InlineUIContainer { Child = button };
    }
}
