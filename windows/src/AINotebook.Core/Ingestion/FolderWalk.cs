using System.Security;
using AINotebook.Core.Storage;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// A sequential, postorder walk. Only completely observed subtrees can reconcile missing files.
/// Filesystem work stays on the caller's worker thread; the scanner supplies that worker boundary.
/// </summary>
public sealed class FolderWalk(IFolderFileSystem fileSystem)
{
    private readonly IFolderFileSystem _fileSystem = fileSystem ?? throw new ArgumentNullException(nameof(fileSystem));

    public Task<ScanCompletion> WalkAsync(FolderSource root, Func<bool> cancelled,
        Func<FolderEntry, Task> visit, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(visit);
        return WalkAsync(root, cancelled, (entry, _) => visit(entry), ct);
    }

    /// <summary>
    /// <paramref name="visitAhead"/> also receives the entries that follow the visited one in its directory (walk
    /// order), so a visitor can prepare them ahead of their own visit. Each entry's outcome still belongs to its own
    /// visit.
    /// </summary>
    public async Task<ScanCompletion> WalkAsync(FolderSource root, Func<bool> cancelled,
        Func<FolderEntry, IEnumerable<FolderEntry>, Task> visitAhead, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(root);
        ArgumentNullException.ThrowIfNull(cancelled);
        ArgumentNullException.ThrowIfNull(visitAhead);
        bool IsCancelled() => ct.IsCancellationRequested || cancelled();

        if (IsCancelled()) return new ScanCompletion([], [""], false, null);
        FileStamp rootStamp;
        try
        {
            FolderAccessPolicy.ValidateRoot(root.Identity, _fileSystem.Resolve(root.Draft.RootPath));
            rootStamp = _fileSystem.Stat(root, "");
            if (!StringComparer.Ordinal.Equals(rootStamp.Identity, root.Identity.RootFileId))
                return Unavailable("rootIdentityChanged");
        }
        catch (OperationCanceledException) when (IsCancelled())
        {
            return new ScanCompletion([], [""], false, null);
        }
        catch (Exception error) when (IsAccessFailure(error))
        {
            return Unavailable(RootError(error));
        }

        var completed = new List<string>();
        var incomplete = new HashSet<string>(StringComparer.Ordinal);
        var stack = new Stack<DirectoryFrame>();
        stack.Push(new DirectoryFrame("", rootStamp.Identity, completed.Count));
        while (stack.Count != 0)
        {
            if (IsCancelled())
            {
                foreach (var pending in stack) incomplete.Add(pending.Path);
                break;
            }

            var frame = stack.Peek();
            if (frame.Entries is null)
            {
                try
                {
                    RequireIdentity(_fileSystem.Stat(root, frame.Path), frame.Identity);
                    var entries = _fileSystem.List(root, frame.Path);
                    RequireIdentity(_fileSystem.Stat(root, frame.Path), frame.Identity);
                    frame.Entries = entries.OrderBy(entry => entry.RelPath, ScalarPathComparer.Instance).ToArray();
                }
                catch (OperationCanceledException) when (IsCancelled())
                {
                    foreach (var pending in stack) incomplete.Add(pending.Path);
                    break;
                }
                catch (Exception error) when (IsAccessFailure(error))
                {
                    if (frame.Path.Length == 0) return Unavailable(RootError(error));
                    incomplete.Add(frame.Path);
                    stack.Pop();
                    if (stack.TryPeek(out var parent)) parent.Complete = false;
                    continue;
                }
                // Listing can trigger a cancellation signal; never visit newly returned entries afterward.
                continue;
            }

            if (frame.NextEntry < frame.Entries.Count)
            {
                FolderEntry entry = frame.Entries[frame.NextEntry++];
                RequireImmediateChild(frame.Path, entry.RelPath);
                try
                {
                    await visitAhead(entry, frame.Entries.Skip(frame.NextEntry)).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (IsCancelled())
                {
                    foreach (var pending in stack) incomplete.Add(pending.Path);
                    break;
                }
                catch (Exception error) when (IsAccessFailure(error))
                {
                    // As on macOS (contract ingestion-scan-perf-v1 §5): losing the root fails the whole walk; an entry
                    // that cannot be read (denied, locked, vanished, replaced) only leaves its directory incomplete.
                    if (error is FolderIngestionException { Code: "rootUnavailable" or "rootIdentityChanged" })
                        return Unavailable(RootError(error));
                    frame.Complete = false;
                    if (entry.IsDirectory && !entry.IsLink) incomplete.Add(entry.RelPath);
                    continue;
                }
                // Other visitor failures propagate. A rejected observation must never complete its subtree.
                if (entry.IsDirectory && !entry.IsLink)
                    stack.Push(new DirectoryFrame(entry.RelPath, entry.Stamp.Identity, completed.Count));
                continue;
            }

            try
            {
                // A visitor can take time: a directory replaced after listing cannot authorize deletions.
                RequireIdentity(_fileSystem.Stat(root, frame.Path), frame.Identity);
            }
            catch (OperationCanceledException) when (IsCancelled())
            {
                foreach (var pending in stack) incomplete.Add(pending.Path);
                break;
            }
            catch (Exception error) when (IsAccessFailure(error))
            {
                if (frame.Path.Length == 0) return Unavailable(RootError(error));
                frame.Complete = false;
                // Previously completed descendants now belong to an unverified directory identity.
                completed.RemoveRange(frame.CompletedStart, completed.Count - frame.CompletedStart);
            }

            stack.Pop();
            if (frame.Complete)
            {
                // DFS makes a frame's completed descendants contiguous, avoiding quadratic prefix scans.
                completed.RemoveRange(frame.CompletedStart, completed.Count - frame.CompletedStart);
                completed.Add(frame.Path);
            }
            else
            {
                incomplete.Add(frame.Path);
                if (stack.TryPeek(out var parent)) parent.Complete = false;
            }
        }

        return new ScanCompletion(completed.OrderBy(path => path, ScalarPathComparer.Instance).ToArray(),
            incomplete.OrderByDescending(Depth).ThenBy(path => path, ScalarPathComparer.Instance).ToArray(),
            false, null);
    }

    private static ScanCompletion Unavailable(string error) => new([], [""], true, error);
    private static string RootError(Exception error) =>
        error is FolderIngestionException { Code: "rootIdentityChanged" or "changedDuringExtraction" }
            ? "rootIdentityChanged" : "rootUnavailable";

    private static bool IsAccessFailure(Exception error) => error is IOException or UnauthorizedAccessException or
        SecurityException or FolderIngestionException
        {
            Code: "rootUnavailable" or "rootIdentityChanged" or "changedDuringExtraction" or "interiorLink" or "outsideRoot"
        };

    private static void RequireIdentity(FileStamp actual, string expected)
    {
        if (!StringComparer.Ordinal.Equals(actual.Identity, expected))
            throw new FolderIngestionException("changedDuringExtraction");
    }

    private static int Depth(string path) => path.Length == 0 ? 0 : 1 + path.Count(value => value == '/');

    private static void RequireImmediateChild(string parent, string path)
    {
        string prefix = parent.Length == 0 ? "" : parent + "/";
        if (!path.StartsWith(prefix, StringComparison.Ordinal)) throw new FolderIngestionException("outsideRoot");
        ReadOnlySpan<char> name = path.AsSpan(prefix.Length);
        if (name.Length == 0 || name.SequenceEqual(".") || name.SequenceEqual("..") || name.IndexOfAny('/', '\\', '\0') >= 0)
            throw new FolderIngestionException("outsideRoot");
    }

    private sealed class DirectoryFrame(string path, string identity, int completedStart)
    {
        public string Path { get; } = path;
        public string Identity { get; } = identity;
        public int CompletedStart { get; } = completedStart;
        public IReadOnlyList<FolderEntry>? Entries { get; set; }
        public int NextEntry { get; set; }
        public bool Complete { get; set; } = true;
    }
}
