namespace AINotebook.Core;

/// One GitHub release asset (REST API shape; JSON mapping lives in UpdateChecker).
public sealed record UpdateReleaseAsset(string Name, string BrowserDownloadUrl);

/// One GitHub release — only the fields the update check needs.
public sealed record UpdateRelease(
    string TagName, bool Prerelease, string HtmlUrl, IReadOnlyList<UpdateReleaseAsset> Assets);

/// Result of an update evaluation.
public sealed record UpdateInfo(
    bool IsUpdateAvailable, string LatestVersion, string DownloadUrl, string ReleaseNotesUrl)
{
    public static readonly UpdateInfo None = new(false, "", "", "");
}

/// Pure release-picking logic; the fetch layer is UpdateChecker.
public static class UpdateCheck
{
    public const string WindowsAssetSuffix = "-windows-setup.exe";

    /// Picks the highest-semver non-prerelease release carrying an asset with
    /// `assetSuffix`; available iff strictly newer than `currentVersion`.
    public static UpdateInfo Evaluate(
        IReadOnlyList<UpdateRelease> releases, string currentVersion, string assetSuffix)
    {
        var current = SemverComponents(currentVersion);
        if (current is null) return UpdateInfo.None;

        int[]? bestVersion = null;
        UpdateReleaseAsset? bestAsset = null;
        string bestNotes = "";
        foreach (var release in releases)
        {
            if (release.Prerelease) continue;
            var version = SemverComponents(release.TagName);
            if (version is null) continue;
            UpdateReleaseAsset? asset = null;
            foreach (var a in release.Assets)
            {
                if (a.Name.EndsWith(assetSuffix, StringComparison.Ordinal)) { asset = a; break; }
            }
            if (asset is null) continue;
            if (bestVersion is null || IsGreater(version, bestVersion))
            {
                bestVersion = version;
                bestAsset = asset;
                bestNotes = release.HtmlUrl;
            }
        }

        if (bestVersion is null || bestAsset is null || !IsGreater(bestVersion, current))
            return UpdateInfo.None;

        return new UpdateInfo(
            true, string.Join('.', bestVersion), bestAsset.BrowserDownloadUrl, bestNotes);
    }

    /// "v0.9.2" / "win-v0.8.0" / "0.9.2" → [major, minor, patch]; null otherwise.
    internal static int[]? SemverComponents(string tag)
    {
        var s = tag;
        if (s.StartsWith("win-v", StringComparison.Ordinal)) s = s["win-v".Length..];
        else if (s.StartsWith('v')) s = s[1..];
        var parts = s.Split('.');
        if (parts.Length != 3) return null;
        var numbers = new int[3];
        for (var i = 0; i < 3; i++)
        {
            if (!int.TryParse(parts[i], out var n) || n < 0) return null;
            numbers[i] = n;
        }
        return numbers;
    }

    internal static bool IsGreater(int[] a, int[] b)
    {
        for (var i = 0; i < Math.Min(a.Length, b.Length); i++)
        {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
    }
}
