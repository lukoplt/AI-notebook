using System.Text.RegularExpressions;
using System.Xml.Linq;
using AINotebook.App.Services;
using Xunit;

namespace AINotebook.App.Tests;

/// <summary>UI redesign W5: every string the App asks for exists, and views use tokens only (spec §3, §4).</summary>
public sealed class RedesignHygieneTests
{
    private static IEnumerable<string> Sources(string pattern) =>
        Directory.EnumerateFiles(ShellNavigationTests.AppRoot(), pattern, SearchOption.AllDirectories)
            .Where(p => !p.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}")
                     && !p.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}"));

    [Fact]
    public void EveryLiteralStringKeyExistsInBothLanguages()
    {
        var en = XDocument.Load("en.resw").Root!.Elements("data").Select(d => (string)d.Attribute("name")!).ToHashSet();
        var cs = XDocument.Load("cs.resw").Root!.Elements("data").Select(d => (string)d.Attribute("name")!).ToHashSet();
        var missing = new List<string>();
        foreach (var file in Sources("*.cs"))
            foreach (Match m in Regex.Matches(File.ReadAllText(file), @"(?:_t|_l|_strings|\bt|Strings)(?:\.Get\(|\[)""(\w+)""[\)\]]"))
                if (!en.Contains(m.Groups[1].Value) || !cs.Contains(m.Groups[1].Value))
                    missing.Add($"{Path.GetFileName(file)}: {m.Groups[1].Value}");
        Assert.Empty(missing);
        // Every StringKey maps to a resource (the enum mirrors the .resw).
        foreach (var key in Enum.GetNames<StringKey>())
            Assert.Contains(char.ToLowerInvariant(key[0]) + key[1..], en);
    }

    [Fact]
    public void ViewsUseTokensNotHardCodedColours()
    {
        var offenders = new List<string>();
        foreach (var file in Sources("*.xaml").Concat(Sources("*.cs")))
        {
            string text = File.ReadAllText(file);
            foreach (var bad in new[] { "FromArgb", "Foreground=\"Red\"", "Colors.Green", "Colors.Red", "TextFillColor", "SystemFillColor",
                         "AccentButtonStyle", "Segoe MDL2", "\"Consolas\"" })
                if (text.Contains(bad, StringComparison.Ordinal)) offenders.Add($"{Path.GetFileName(file)}: {bad}");
        }
        Assert.Empty(offenders);
    }

    [Fact]
    public void FormerLiteralsAreLocalized()
    {
        string root = ShellNavigationTests.AppRoot();
        Assert.DoesNotContain("\"Save\"", File.ReadAllText(Path.Combine(root, "MainWindow.xaml.cs")));
        Assert.DoesNotContain("Content=\"Save\"", File.ReadAllText(Path.Combine(root, "Editor", "EditorWebView.xaml")));
        foreach (var dialog in new[] { "GlobalSearchDialog.xaml", "SourcePreviewDialog.xaml" })
            Assert.DoesNotContain("CloseButtonText=\"Close\"", File.ReadAllText(Path.Combine(root, "Views", dialog)));
    }

    [Fact]
    public void OnboardingIsACentredTokenCard()
    {
        string root = ShellNavigationTests.AppRoot();
        string page = File.ReadAllText(Path.Combine(root, "Onboarding", "OnboardingPage.xaml"));
        Assert.Contains("MaxWidth=\"{StaticResource SizeOnboardingCardMax}\"", page);
        foreach (var step in new[] { "WelcomeStep.xaml", "DetectOllamaStep.xaml", "PickModelsStep.xaml", "DoneStep.xaml" })
            Assert.Contains("PrimaryButtonStyle", File.ReadAllText(Path.Combine(root, "Onboarding", step)));
    }
}
