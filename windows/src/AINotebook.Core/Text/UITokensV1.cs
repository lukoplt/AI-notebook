namespace AINotebook.Core.Text;

/// <summary>
/// Design tokens v1 — values of the shared contract Tests/fixtures/contracts/ui-tokens-v1.json
/// (human table: docs/design/tokens-v1.md). The App's Styles/Tokens.xaml carries the same
/// values as XAML resources; UITokensTests keeps both equal to the fixture. Never edit a
/// value here without a new contract version.
/// </summary>
public static class UITokensV1
{
    public sealed record ColorPair(string Light, string Dark);

    /// <param name="Weight">"regular" or "semibold".</param>
    /// <param name="LineWindows">Line height used on Windows (differs only for body).</param>
    public sealed record TypeSpec(int Size, int Line, int LineWindows, string Weight);

    /// <param name="FluentGlyph">Segoe Fluent Icons code point, hex (e.g. "E70F").</param>
    public sealed record IconSpec(string SfSymbol, string FluentGlyph)
    {
        /// <summary>The glyph as a one-char string, ready for FontIcon.Glyph.</summary>
        public string Glyph => ((char)Convert.ToInt32(FluentGlyph, 16)).ToString();
    }

    /// <summary>Colour tokens by contract name ("bg", "bg-sidebar", "text-1", …).</summary>
    public static readonly IReadOnlyDictionary<string, ColorPair> Colors = new Dictionary<string, ColorPair>(StringComparer.Ordinal)
    {
        ["bg"] = new("#FFFFFF", "#1E1E1E"),
        ["bg-sidebar"] = new("#F7F7F8", "#181818"),
        ["surface-1"] = new("#FFFFFF", "#252525"),
        ["surface-2"] = new("#F2F2F3", "#2E2E2E"),
        ["border"] = new("#E5E5E7", "#3A3A3A"),
        ["text-1"] = new("#0D0D0D", "#ECECEC"),
        ["text-2"] = new("#5D5D63", "#A7A7AD"),
        ["text-3"] = new("#8E8E93", "#6E6E73"),
        ["accent"] = new("#0D0D0D", "#ECECEC"),
        ["on-accent"] = new("#FFFFFF", "#0D0D0D"),
        ["focus"] = new("#2F6FEB", "#4C8DFF"),
        ["success"] = new("#1F8A4C", "#3FB96E"),
        ["warning"] = new("#B26A00", "#E0A33A"),
        ["danger"] = new("#C42B1C", "#FF6B5E"),
    };

    public static readonly IReadOnlyDictionary<string, TypeSpec> Type = new Dictionary<string, TypeSpec>(StringComparer.Ordinal)
    {
        ["title"] = new(20, 28, 28, "semibold"),
        ["headline"] = new(15, 22, 22, "semibold"),
        ["body"] = new(14, 22, 20, "regular"),
        ["message"] = new(15, 24, 24, "regular"),
        ["caption"] = new(12, 16, 16, "regular"),
        ["mono"] = new(13, 20, 20, "regular"),
    };

    public const string FontText = "Segoe UI Variable";
    public const string FontMono = "Cascadia Mono";
    public const string FontIcons = "Segoe Fluent Icons";

    /// <summary>4 px grid.</summary>
    public static readonly IReadOnlyList<int> Spacing = [4, 8, 12, 16, 24, 32];

    public static readonly IReadOnlyDictionary<string, int> Radius = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["sm"] = 6,
        ["md"] = 10,
        ["lg"] = 16,
        ["pill"] = 999,
    };

    public static readonly IReadOnlyDictionary<string, int> Size = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["sidebarRow"] = 30,
        ["topBar"] = 44,
        ["hitMin"] = 28,
        ["primaryHitMin"] = 32,
        ["conversationMax"] = 760,
        ["sidebarMin"] = 240,
        ["sidebarMax"] = 300,
        ["panelMin"] = 320,
        ["panelMax"] = 420,
        ["iconRow"] = 16,
        ["iconTopBar"] = 18,
        ["userMessagePadV"] = 10,
        ["userMessagePadH"] = 14,
        ["userMessageMaxPercent"] = 80,
        ["composerMinLines"] = 1,
        ["composerMaxLines"] = 8,
        ["settingsContentMax"] = 640,
        ["onboardingCardMax"] = 520,
        ["focusRing"] = 2,
        ["borderWidth"] = 1,
        ["sidebarChatsVisible"] = 8,
    };

    public static readonly IReadOnlyDictionary<string, int> Motion = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["fastMs"] = 120,
        ["slowMs"] = 180,
    };

    public static readonly IReadOnlyDictionary<string, IconSpec> Icons = new Dictionary<string, IconSpec>(StringComparer.Ordinal)
    {
        ["newChat"] = new("square.and.pencil", "E70F"),
        ["search"] = new("magnifyingglass", "E721"),
        ["settings"] = new("gearshape", "E713"),
        ["notebook"] = new("book.closed", "E8F1"),
        ["chat"] = new("bubble.left", "E8BD"),
        ["chevronDown"] = new("chevron.down", "E70D"),
        ["chevronRight"] = new("chevron.right", "E76C"),
        ["back"] = new("chevron.left", "E72B"),
        ["add"] = new("plus", "E710"),
        ["more"] = new("ellipsis", "E712"),
        ["togglePanel"] = new("sidebar.right", "E8A0"),
        ["updateDot"] = new("circle.fill", "EA3B"),
        ["send"] = new("arrow.up", "E74A"),
        ["stop"] = new("stop.fill", "E71A"),
        ["previewContext"] = new("eye", "E890"),
        ["scope"] = new("scope", "E8B7"),
        ["persona"] = new("theatermasks", "E77B"),
        ["model"] = new("cpu", "E950"),
        ["copy"] = new("doc.on.doc", "E8C8"),
        ["regenerate"] = new("arrow.clockwise", "E72C"),
        ["saveAsNote"] = new("square.and.arrow.down", "E74E"),
        ["sentContext"] = new("doc.text.magnifyingglass", "E8A5"),
        ["edit"] = new("pencil", "E70F"),
        ["warning"] = new("exclamationmark.triangle", "E7BA"),
        ["addFile"] = new("doc.badge.plus", "E8E5"),
        ["addFolder"] = new("folder.badge.plus", "E8F4"),
        ["addUrl"] = new("link", "E71B"),
        ["addText"] = new("text.alignleft", "E8E4"),
        ["webSearch"] = new("globe", "E774"),
        ["overview"] = new("list.bullet.rectangle", "E8FD"),
        ["runTool"] = new("wand.and.stars", "E945"),
        ["note"] = new("note.text", "E7C3"),
        ["folder"] = new("folder", "E8B7"),
        ["file"] = new("doc", "E8A5"),
        ["scan"] = new("arrow.triangle.2.circlepath", "E895"),
        ["verify"] = new("checkmark.seal", "E73E"),
        ["rules"] = new("line.3.horizontal.decrease.circle", "E71C"),
        ["watch"] = new("binoculars", "E7B3"),
        ["delete"] = new("trash", "E74D"),
        ["tag"] = new("tag", "E8EC"),
        ["bulkSelect"] = new("checklist", "E762"),
        ["history"] = new("clock.arrow.circlepath", "E81C"),
        ["export"] = new("square.and.arrow.up", "EDE1"),
        ["instructions"] = new("text.badge.star", "E734"),
        ["backup"] = new("archivebox", "E896"),
        ["restore"] = new("arrow.uturn.backward", "E7A7"),
        ["openOriginal"] = new("arrow.up.forward.square", "E8A7"),
        ["citation"] = new("quote.opening", "E9D2"),
        ["info"] = new("info.circle", "E946"),
        ["error"] = new("xmark.octagon", "E783"),
        ["success"] = new("checkmark.circle", "E73E"),
        ["close"] = new("xmark", "E711"),
        ["providers"] = new("cloud", "E753"),
        ["modelsLimits"] = new("slider.horizontal.3", "E9E9"),
        ["indexing"] = new("square.stack.3d.up", "E81E"),
    };

    /// <summary>XAML resource key stem: "bg-sidebar" → "BgSidebar", "userMessagePadV" → "UserMessagePadV".</summary>
    public static string XamlKey(string token) =>
        string.Concat(token.Split('-').Where(p => p.Length > 0).Select(p => char.ToUpperInvariant(p[0]) + p[1..]));

    /// <summary>Parses "#RRGGBB"; false for anything else.</summary>
    public static bool TryParseHex(string hex, out byte red, out byte green, out byte blue)
    {
        red = green = blue = 0;
        if (hex.Length != 7 || hex[0] != '#' || !hex.Skip(1).All(char.IsAsciiHexDigit)) return false;
        var value = Convert.ToInt32(hex[1..], 16);
        red = (byte)(value >> 16);
        green = (byte)(value >> 8);
        blue = (byte)value;
        return true;
    }
}
