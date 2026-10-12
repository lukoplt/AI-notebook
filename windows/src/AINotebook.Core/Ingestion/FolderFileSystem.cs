using System.Text;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

public sealed record FolderEntry(string RelPath, bool IsDirectory, bool IsLink, FileStamp Stamp);

/// <summary>Hash returns an empty Bytes payload; native hashing never retains a file copy.</summary>
public sealed record FolderRead(byte[] Bytes, FileStamp Stamp, string Sha256);

public interface IFolderFileSystem : IFolderPathIdentity
{
    bool CaseSensitive(FolderSource root);
    IReadOnlyList<FolderEntry> List(FolderSource root, string directory);
    FileStamp Stat(FolderSource root, string relativePath);
    FolderRead Hash(FolderSource root, string relativePath, long maxBytes);
    FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes);

    // Additive cancellation overloads keep existing deterministic filesystem adapters compatible.
    FolderRead Hash(FolderSource root, string relativePath, long maxBytes, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Hash(root, relativePath, maxBytes);
    }
    FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Snapshot(root, relativePath, maxBytes);
    }
}

/// <summary>Owns a private immutable copy. Disposing removes only that copy, never the original.</summary>
public sealed class FolderFileSnapshot : IDisposable
{
    public string Path { get; }
    public FileStamp Stamp { get; }
    public string Hash { get; }
    private int _disposed;

    internal FolderFileSnapshot(string path, FileStamp stamp, string hash)
    { Path = path; Stamp = stamp; Hash = hash; }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        if (!File.Exists(Path)) return;
        if (OperatingSystem.IsWindows())
            File.SetAttributes(Path, File.GetAttributes(Path) & ~FileAttributes.ReadOnly);
        File.Delete(Path);
    }
}

internal static class FolderAccessPolicy
{
    internal static void ValidateRoot(FolderIdentity persisted, FolderIdentity opened)
    {
        if (persisted.VolumeId != opened.VolumeId || persisted.RootFileId != opened.RootFileId ||
            !persisted.Components.SequenceEqual(opened.Components, StringComparer.Ordinal))
            throw new FolderIngestionException("rootIdentityChanged");
    }

    internal static void ValidateContainment(FolderIdentity root, string volume, IReadOnlyList<string> components)
    {
        if (root.VolumeId != volume || components.Count < root.Components.Count ||
            !root.Components.SequenceEqual(components.Take(root.Components.Count), StringComparer.Ordinal))
            throw new FolderIngestionException("outsideRoot");
    }

    internal static void ValidateOpened(FileStamp enumerated, FileStamp opened, bool isLink,
        string parentBefore, string parentAfter)
    {
        if (isLink) throw new FolderIngestionException("interiorLink");
        if (parentBefore != parentAfter) throw new FolderIngestionException("outsideRoot");
        if (enumerated != opened) throw new FolderIngestionException("changedDuringExtraction");
    }

    internal static IReadOnlyList<string> CanonicalPaths(IEnumerable<string> paths, Func<string, string> resolve) =>
        paths.Select(resolve).Distinct(StringComparer.Ordinal).Order(ScalarPathComparer.Instance).ToArray();

    internal static string[] RelativeComponents(string path, bool allowRoot = false)
    {
        if (path.Length == 0 && allowRoot) return Array.Empty<string>();
        var parts = path.Split('/');
        if (path.Length == 0 || path.Contains('\\') || path.Contains(':') || path.Contains('\0') ||
            parts.Any(p => p.Length == 0 || p is "." or ".."))
            throw new FolderIngestionException("outsideRoot");
        return parts;
    }
}

internal sealed class ScalarPathComparer : IComparer<string>
{
    internal static ScalarPathComparer Instance { get; } = new();
    public int Compare(string? x, string? y)
    {
        if (ReferenceEquals(x, y)) return 0;
        if (x is null) return -1;
        if (y is null) return 1;
        var left = x.EnumerateRunes(); var right = y.EnumerateRunes();
        while (true)
        {
            bool a = left.MoveNext(), b = right.MoveNext();
            if (!a || !b) return a == b ? 0 : a ? 1 : -1;
            int order = left.Current.Value.CompareTo(right.Current.Value);
            if (order != 0) return order;
        }
    }
}
