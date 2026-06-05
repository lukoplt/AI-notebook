namespace AINotebook.Core.Storage;

/// <summary>
/// Where the SQLite database lives. Either an on-disk file path or the
/// in-memory marker (FilePath == null) for tests.
/// </summary>
public sealed class StorePath
{
    public string? FilePath { get; }
    public bool IsInMemory => FilePath is null;

    public StorePath(string? filePath) => FilePath = filePath;

    public static StorePath InMemory => new(null);

    /// <summary>
    /// %APPDATA%\AINotebook\db.sqlite, creating the parent directory on demand.
    /// </summary>
    public static StorePath Production()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var container = Path.Combine(appData, "AINotebook");
        Directory.CreateDirectory(container);
        return new StorePath(Path.Combine(container, "db.sqlite"));
    }
}
