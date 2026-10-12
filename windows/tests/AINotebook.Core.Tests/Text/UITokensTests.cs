using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Xml.Linq;
using AINotebook.Core.Tests.Helpers;
using AINotebook.Core.Text;
using Xunit;

namespace AINotebook.Core.Tests.Text;

/// <summary>
/// UITokensV1 and the App's Styles/Tokens.xaml must both equal the shared
/// contract ui-tokens-v1.json (the Swift suite checks UITokensV1.swift the same way).
/// Tokens.xaml is parsed as plain XML because the WinUI App cannot build here.
/// </summary>
public class UITokensTests
{
    private static readonly XNamespace X = "http://schemas.microsoft.com/winfx/2006/xaml";
    private static readonly XNamespace P = "http://schemas.microsoft.com/winfx/2006/xaml/presentation";

    private static JsonElement Fixture()
    {
        var f = SharedFixtures.Json("contracts/ui-tokens-v1.json");
        Assert.Equal("ui-tokens", f.GetProperty("contract").GetString());
        Assert.Equal(1, f.GetProperty("version").GetInt32());
        return f;
    }

    private static Dictionary<string, JsonElement> Section(string name) =>
        Fixture().GetProperty(name).EnumerateObject().ToDictionary(p => p.Name, p => p.Value, StringComparer.Ordinal);

    private static void SameKeys<T>(IEnumerable<string> expected, IReadOnlyDictionary<string, T> actual) =>
        Assert.Equal(expected.OrderBy(k => k, StringComparer.Ordinal), actual.Keys.OrderBy(k => k, StringComparer.Ordinal));

    // ---- UITokensV1 constants

    [Fact]
    public void ColorsMatchFixture()
    {
        var colors = Section("colors");
        Assert.Equal(14, colors.Count);
        SameKeys(colors.Keys, UITokensV1.Colors);
        foreach (var (key, pair) in colors)
            Assert.Equal(new UITokensV1.ColorPair(pair.GetProperty("light").GetString()!, pair.GetProperty("dark").GetString()!),
                UITokensV1.Colors[key]);
    }

    [Fact]
    public void HexParsing()
    {
        foreach (var pair in UITokensV1.Colors.Values)
        {
            Assert.True(UITokensV1.TryParseHex(pair.Light, out _, out _, out _), pair.Light);
            Assert.True(UITokensV1.TryParseHex(pair.Dark, out _, out _, out _), pair.Dark);
        }
        Assert.True(UITokensV1.TryParseHex("#2F6FEB", out var r, out var g, out var b));
        Assert.Equal((47, 111, 235), (r, g, b));
        Assert.False(UITokensV1.TryParseHex("2F6FEB", out _, out _, out _));
        Assert.False(UITokensV1.TryParseHex("#2F6FEG", out _, out _, out _));
        Assert.False(UITokensV1.TryParseHex("#2F6FE", out _, out _, out _));
        Assert.Equal("BgSidebar", UITokensV1.XamlKey("bg-sidebar"));
        Assert.Equal("Text1", UITokensV1.XamlKey("text-1"));
        Assert.Equal("UserMessagePadV", UITokensV1.XamlKey("userMessagePadV"));
    }

    [Fact]
    public void TypeRampAndFontsMatchFixture()
    {
        var type = Section("type");
        SameKeys(type.Keys, UITokensV1.Type);
        foreach (var (key, o) in type)
        {
            var line = o.GetProperty("line").GetInt32();
            var lineWindows = o.TryGetProperty("lineWindows", out var lw) ? lw.GetInt32() : line;
            Assert.Equal(new UITokensV1.TypeSpec(o.GetProperty("size").GetInt32(), line, lineWindows,
                o.GetProperty("weight").GetString()!), UITokensV1.Type[key]);
        }
        var windows = Fixture().GetProperty("fonts").GetProperty("windows");
        Assert.Equal(UITokensV1.FontText, windows.GetProperty("text").GetString());
        Assert.Equal(UITokensV1.FontMono, windows.GetProperty("mono").GetString());
        Assert.Equal(UITokensV1.FontIcons, windows.GetProperty("icons").GetString());
    }

    [Fact]
    public void SpacingRadiusSizeMotionMatchFixture()
    {
        Assert.Equal(Fixture().GetProperty("spacing").EnumerateArray().Select(e => e.GetInt32()), UITokensV1.Spacing);
        foreach (var (name, actual) in new[] {
            ("radius", UITokensV1.Radius), ("size", UITokensV1.Size), ("motion", UITokensV1.Motion) })
        {
            var expected = Section(name);
            SameKeys(expected.Keys, actual);
            foreach (var (key, value) in expected) Assert.Equal(value.GetInt32(), actual[key]);
        }
    }

    [Fact]
    public void IconsMatchFixture()
    {
        var icons = Section("icons");
        SameKeys(icons.Keys, UITokensV1.Icons);
        foreach (var (key, o) in icons)
        {
            var spec = UITokensV1.Icons[key];
            Assert.Equal(new UITokensV1.IconSpec(o.GetProperty("sf").GetString()!, o.GetProperty("fluent").GetString()!), spec);
            var glyph = Convert.ToInt32(spec.FluentGlyph, 16);
            Assert.InRange(glyph, 0xE000, 0xF8FF); // private-use area of Segoe Fluent Icons
            Assert.Equal(((char)glyph).ToString(), spec.Glyph);
        }
    }

    // ---- Styles/Tokens.xaml

    private static XElement TokensXaml() => XDocument.Load(AppFile("Styles", "Tokens.xaml")).Root!;

    private static Dictionary<string, XElement> Keyed(XElement dictionary) =>
        dictionary.Elements().Where(e => e.Attribute(X + "Key") is not null)
            .ToDictionary(e => e.Attribute(X + "Key")!.Value, StringComparer.Ordinal);

    [Fact]
    public void TokensXamlThemeColorsMatchFixture()
    {
        var root = TokensXaml();
        Assert.Equal(P + "ResourceDictionary", root.Name);
        var themes = Keyed(root.Element(P + "ResourceDictionary.ThemeDictionaries")!);
        Assert.Equal(new[] { "Dark", "Default", "Light" }, themes.Keys.OrderBy(k => k, StringComparer.Ordinal));
        foreach (var (theme, dict) in themes)
        {
            var resources = Keyed(dict);
            Assert.Equal(UITokensV1.Colors.Count * 2, resources.Count);
            foreach (var (token, pair) in UITokensV1.Colors)
            {
                var hex = theme == "Light" ? pair.Light : pair.Dark; // Default = Dark (WinUI convention)
                var key = UITokensV1.XamlKey(token);
                var color = resources[key];
                Assert.Equal(P + "Color", color.Name);
                Assert.Equal(hex, color.Value.Trim());
                var brush = resources[key + "Brush"];
                Assert.Equal(P + "SolidColorBrush", brush.Name);
                Assert.Equal(hex, brush.Attribute("Color")!.Value);
            }
        }
    }

    [Fact]
    public void TokensXamlMetricsMatchFixture()
    {
        var r = Keyed(TokensXaml());
        void Value(string key, XName type, string expected)
        {
            Assert.True(r.TryGetValue(key, out var e), "missing " + key);
            Assert.Equal(type, e!.Name);
            Assert.Equal(expected, e.Value.Trim());
        }

        foreach (var (style, spec) in UITokensV1.Type)
        {
            Value("FontSize" + UITokensV1.XamlKey(style), X + "Double", spec.Size.ToString());
            Value("LineHeight" + UITokensV1.XamlKey(style), X + "Double", spec.LineWindows.ToString());
        }
        foreach (var space in UITokensV1.Spacing)
        {
            Value($"Space{space}", X + "Double", space.ToString());
            Value($"Pad{space}", P + "Thickness", space.ToString());
        }
        foreach (var (key, value) in UITokensV1.Radius) Value("Radius" + UITokensV1.XamlKey(key), P + "CornerRadius", value.ToString());
        foreach (var (key, value) in UITokensV1.Size) Value("Size" + UITokensV1.XamlKey(key), X + "Double", value.ToString());
        foreach (var (key, value) in UITokensV1.Motion) Value("Motion" + UITokensV1.XamlKey(key), X + "Int32", value.ToString());
        foreach (var (key, spec) in UITokensV1.Icons) Value("Icon" + UITokensV1.XamlKey(key), X + "String", spec.Glyph);
        Value("FontText", P + "FontFamily", UITokensV1.FontText);
        Value("FontMono", P + "FontFamily", UITokensV1.FontMono);
        Value("FontIcons", P + "FontFamily", UITokensV1.FontIcons);
    }

    [Fact]
    public void TokensXamlTextStylesUseTheTypeRamp()
    {
        var r = Keyed(TokensXaml());
        foreach (var (style, spec) in UITokensV1.Type)
        {
            var name = UITokensV1.XamlKey(style);
            var s = r["Text" + name];
            Assert.Equal(P + "Style", s.Name);
            Assert.Equal("TextBlock", s.Attribute("TargetType")!.Value);
            var setters = s.Elements(P + "Setter")
                .ToDictionary(e => e.Attribute("Property")!.Value, e => e.Attribute("Value")!.Value, StringComparer.Ordinal);
            Assert.Equal($"{{StaticResource FontSize{name}}}", setters["FontSize"]);
            Assert.Equal($"{{StaticResource LineHeight{name}}}", setters["LineHeight"]);
            Assert.Equal("BlockLineHeight", setters["LineStackingStrategy"]);
            Assert.Equal(spec.Weight == "semibold" ? "SemiBold" : "Normal", setters["FontWeight"]);
            Assert.Equal(style == "mono" ? "{StaticResource FontMono}" : "{StaticResource FontText}", setters["FontFamily"]);
        }
    }

    [Fact]
    public void AppXamlMergesTokens()
    {
        var app = XDocument.Load(AppFile("App.xaml")).Root!;
        var merged = app.Descendants(P + "ResourceDictionary.MergedDictionaries").Single();
        Assert.Contains(merged.Elements(P + "ResourceDictionary"),
            d => d.Attribute("Source")?.Value == "ms-appx:///Styles/Tokens.xaml");
    }

    private static string AppFile(string first, params string[] rest) => AppFileAt(Path.Combine([first, .. rest]));

    private static string AppFileAt(string relative, [CallerFilePath] string here = "")
    {
        for (var dir = new DirectoryInfo(Path.GetDirectoryName(here)!); dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "windows", "src", "AINotebook.App", relative);
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("App file not found: " + relative);
    }
}
