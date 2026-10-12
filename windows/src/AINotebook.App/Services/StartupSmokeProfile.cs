namespace AINotebook.App.Services;

/// <summary>
/// Headless startup smoke (<c>--startup-smoke &lt;absolute-temp-profile&gt;</c>): every persistent path the service
/// graph touches is redirected below one isolated directory under the temporary folder, so CI can exercise the real
/// unpackaged executable (DI graph, ordinary store migration, reopen) without a window or the user's profile.
/// </summary>
internal sealed record StartupSmokeProfile(string Root)
{
    internal const string Flag = "--startup-smoke";

    internal string DatabasePath => Path.Combine(Root, "db.sqlite");
    internal string SettingsPath => Path.Combine(Root, "settings.json");
    internal string AttachmentsPath => Path.Combine(Root, "attachments");
    internal string ResultPath => Path.Combine(Root, "smoke-result.json");

    /// <summary>Null for an ordinary launch; throws <see cref="ArgumentException"/> for malformed smoke arguments.</summary>
    internal static StartupSmokeProfile? Parse(IReadOnlyList<string> args)
    {
        ArgumentNullException.ThrowIfNull(args);
        if (!args.Contains(Flag, StringComparer.Ordinal)) return null;
        if (args.Count != 2 || args[0] != Flag)
            throw new ArgumentException("Expected --startup-smoke <temporary-profile>.");
        if (!Path.IsPathFullyQualified(args[1]))
            throw new ArgumentException("Smoke profile must be an absolute path.");
        string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(args[1]));
        string parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) + Path.DirectorySeparatorChar;
        if (!root.StartsWith(parent, StringComparison.OrdinalIgnoreCase) || root.Length == parent.Length)
            throw new ArgumentException("Smoke profile must be below the temporary directory.");
        return new StartupSmokeProfile(root);
    }

    internal void Create()
    {
        Directory.CreateDirectory(Root);
        Directory.CreateDirectory(AttachmentsPath);
    }
}
