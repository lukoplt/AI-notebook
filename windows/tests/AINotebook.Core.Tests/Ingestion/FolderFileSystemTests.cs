using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Ingestion;

public sealed class FolderFileSystemTests
{
    [Fact]
    public async Task PartialSiblingCompletion()
    {
        var row = Cases().Single(c => Name(c) == "partial-sibling");
        var fs = new ScriptedFS(row);
        var result = await new FolderWalk(fs).WalkAsync(fs.Root, () => false, _ => Task.CompletedTask);
        Assert.Equal(new[] { "good" }, result.Completed);
        Assert.Equal(new[] { "bad", "" }, result.Incomplete);
        Assert.False(result.RootUnavailable);
        Assert.Equal(new[] { "", "bad", "good" }, fs.ListCalls);
    }

    [Fact]
    public async Task AllWalkTraces()
    {
        var rows = Cases();
        Assert.All(rows, c => Assert.Contains(c.GetProperty("operation").GetString(), new[] { "walk", "identity", "open", "scan", "rules" }));
        var visited = new HashSet<string>();
        foreach (var row in rows.Where(c => c.GetProperty("operation").GetString() == "walk"))
        {
            Assert.True(visited.Add(Name(row)));
            var fs = new ScriptedFS(row);
            var paths = new List<string>();
            var result = await new FolderWalk(fs).WalkAsync(fs.Root, () => false, entry => { paths.Add(entry.RelPath); return Task.CompletedTask; });
            var expected = row.GetProperty("expected"); var completion = expected.GetProperty("completion");
            Assert.Equal(Strings(completion, "completed"), result.Completed);
            Assert.Equal(Strings(completion, "incomplete"), result.Incomplete);
            Assert.Equal(completion.GetProperty("rootUnavailable").GetBoolean(), result.RootUnavailable);
            Assert.Equal(Strings(expected, "listCalls"), fs.ListCalls);
            if (expected.TryGetProperty("visitedPaths", out var pathRows)) Assert.Equal(pathRows.EnumerateArray().Select(x => x.GetString()), paths);
            Assert.Equal(0, fs.ReadCalls);
        }
        Assert.Equal(7, visited.Count);

        var partial = new ScriptedFS(rows.Single(c => Name(c) == "partial-sibling"));
        bool cancel = false;
        var stopped = await new FolderWalk(partial).WalkAsync(partial.Root, () => cancel,
            entry => { cancel = true; return Task.CompletedTask; });
        Assert.Empty(stopped.Completed);
        Assert.Contains("", stopped.Incomplete);
        Assert.DoesNotContain("good", partial.ListCalls);

        var denied = new ScriptedFS(rows.Single(c => Name(c) == "nested-eligible-file")) { DenyRoot = true };
        var unavailable = await new FolderWalk(denied).WalkAsync(denied.Root, () => false, _ => Task.CompletedTask);
        Assert.True(unavailable.RootUnavailable);
        Assert.Empty(unavailable.Completed);

        var exceptional = new ScriptedFS(rows.Single(c => Name(c) == "nested-eligible-file"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => new FolderWalk(exceptional).WalkAsync(exceptional.Root,
            () => false, _ => throw new InvalidOperationException("visitor failed")));

        var swapped = new ScriptedFS(rows.Single(c => Name(c) == "nested-eligible-file"))
        {
            ObserveStamp = (path, call, stamp) => path == "nested" && call >= 2 ? stamp with { Identity = "replacement" } : stamp
        };
        var swappedPaths = new List<string>();
        var swappedResult = await new FolderWalk(swapped).WalkAsync(swapped.Root, () => false,
            entry => { swappedPaths.Add(entry.RelPath); return Task.CompletedTask; });
        Assert.Empty(swappedResult.Completed);
        Assert.Equal(new[] { "nested", "" }, swappedResult.Incomplete);
        Assert.DoesNotContain("nested/a.md", swappedPaths);

        using var orderedRow = JsonDocument.Parse(rows.Single(c => Name(c) == "partial-sibling").GetRawText()
            .Replace("bad", "z", StringComparison.Ordinal).Replace("good", "a", StringComparison.Ordinal));
        var ordered = new ScriptedFS(orderedRow.RootElement);
        bool cancelledAfterSibling = false;
        var trailing = await new FolderWalk(ordered).WalkAsync(ordered.Root, () => cancelledAfterSibling,
            entry => { cancelledAfterSibling = entry.RelPath == "z"; return Task.CompletedTask; });
        Assert.Equal(new[] { "a" }, trailing.Completed);
        Assert.Contains("", trailing.Incomplete);
    }

    [Fact]
    public async Task NativeLinksAndContainment()
    {
        using var tree = new Tree();
        string outside = Directory.CreateDirectory(Path.Combine(tree.Path, "outside")).FullName;
        File.WriteAllText(Path.Combine(outside, "secret.md"), "outside");
        string rootPath = Directory.CreateDirectory(Path.Combine(tree.Path, "docs")).FullName;
        File.WriteAllText(Path.Combine(rootPath, "safe.md"), "safe");
        Directory.CreateDirectory(Path.Combine(rootPath, "nested"));
        File.WriteAllText(Path.Combine(rootPath, "nested", "child.md"), "nested");
        int targetReads = 0;
        var fs = new NativeFolderFileSystem(bytesRead: _ => targetReads++); var root = Root(fs, rootPath);
        bool createdSymlink = false;
        try
        {
            File.CreateSymbolicLink(Path.Combine(rootPath, "link.md"), Path.Combine(outside, "secret.md"));
            Directory.CreateSymbolicLink(Path.Combine(rootPath, "dir-link"), outside);
            createdSymlink = true;
        }
        catch (Exception e) when (OperatingSystem.IsWindows() && e is UnauthorizedAccessException or IOException) { }
        if (createdSymlink)
        {
            Assert.Contains(fs.List(root, ""), e => e.RelPath == "link.md" && e.IsLink);
            Error("interiorLink", () => fs.Hash(root, "link.md", 100));
            Error("interiorLink", () => fs.Hash(root, "dir-link/secret.md", 100));
        }
        if (OperatingSystem.IsWindows())
        {
            string junction = Path.Combine(rootPath, "junction");
            var start = new ProcessStartInfo("cmd.exe") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true };
            start.ArgumentList.Add("/c"); start.ArgumentList.Add("mklink"); start.ArgumentList.Add("/J");
            start.ArgumentList.Add(junction); start.ArgumentList.Add(outside);
            using var process = Process.Start(start)!;
            await process.WaitForExitAsync();
            Assert.True(process.ExitCode == 0, "Mandatory junction creation failed: " + await process.StandardError.ReadToEndAsync());
            Assert.Contains(fs.List(root, ""), e => e.RelPath == "junction" && e.IsLink);
            Error("interiorLink", () => fs.Hash(root, "junction/secret.md", 100));
        }
        else Assert.True(createdSymlink);
        Error("outsideRoot", () => fs.Hash(root, "../outside/secret.md", 100));
        Error("outsideRoot", () => fs.Hash(root, "/outside/secret.md", 100));
        Assert.Equal(0, targetReads);
        var visited = new List<string>();
        var completion = await new FolderWalk(fs).WalkAsync(root, () => false, entry => { visited.Add(entry.RelPath); return Task.CompletedTask; });
        Assert.Equal(new[] { "" }, completion.Completed);
        Assert.Contains("nested/child.md", visited);
        Assert.DoesNotContain(visited, p => p.EndsWith("secret.md", StringComparison.Ordinal));
        Assert.Equal("outside", File.ReadAllText(Path.Combine(outside, "secret.md")));
    }

    [Fact]
    public void OpenRace()
    {
        foreach (var row in Cases().Where(c => c.GetProperty("operation").GetString() == "open"))
        {
            var i = row.GetProperty("input");
            Error(row.GetProperty("expected").GetProperty("error").GetString()!, () => FolderAccessPolicy.ValidateOpened(
                Stamp(i.GetProperty("enumerated")), Stamp(i.GetProperty("opened")), i.GetProperty("openedIsLink").GetBoolean(),
                i.GetProperty("parentBefore").GetString()!, i.GetProperty("parentAfter").GetString()!));
        }
        using var tree = new Tree();
        string rootPath = Directory.CreateDirectory(Path.Combine(tree.Path, "docs")).FullName;
        string dir = Directory.CreateDirectory(Path.Combine(rootPath, "dir")).FullName;
        File.WriteAllText(Path.Combine(dir, "a.md"), "old");
        int reads = 0;
        var fs = new NativeFolderFileSystem(_ =>
        {
            Directory.Move(dir, Path.Combine(rootPath, "old-dir"));
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, "a.md"), "new");
        }, _ => reads++);
        var root = Root(fs, rootPath);
        Error("outsideRoot", () => fs.Hash(root, "dir/a.md", 100));
        Assert.Equal(0, reads);
        string leaf = Path.Combine(rootPath, "race.md");
        string target = Path.Combine(tree.Path, "outside.md");
        File.WriteAllText(leaf, "inside");
        File.WriteAllText(target, "outside");
        bool canLink = true;
        string probe = Path.Combine(rootPath, "probe-link.md");
        try { File.CreateSymbolicLink(probe, target); File.Delete(probe); }
        catch (Exception e) when (OperatingSystem.IsWindows() && e is UnauthorizedAccessException or IOException) { canLink = false; }
        if (canLink)
        {
            var raced = new NativeFolderFileSystem(_ => { File.Delete(leaf); File.CreateSymbolicLink(leaf, target); }, _ => reads++);
            Error("interiorLink", () => raced.Hash(root, "race.md", 100));
            Assert.Equal(0, reads);
            Assert.Equal("outside", File.ReadAllText(target));
        }
        var stable = new NativeFolderFileSystem();
        var pinned = Root(stable, rootPath);
        Directory.Move(rootPath, Path.Combine(tree.Path, "old-root"));
        Directory.CreateDirectory(rootPath);
        Error("rootIdentityChanged", () => stable.List(pinned, ""));
    }

    [Fact]
    public void StreamingHashAndCancellation()
    {
        using var tree = new Tree();
        byte[] bytes = Enumerable.Range(0, 200_000).Select(x => (byte)(x % 251)).ToArray();
        File.WriteAllBytes(Path.Combine(tree.Path, "a.md"), bytes);
        var blocks = new List<int>();
        var fs = new NativeFolderFileSystem(bytesRead: count => blocks.Add(count));
        var root = Root(fs, tree.Path);
        var read = fs.Hash(root, "a.md", bytes.Length);
        Assert.Empty(read.Bytes);
        Assert.Equal(Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), read.Sha256);
        Assert.Equal(bytes.Length, blocks.Sum());
        Assert.All(blocks, n => Assert.InRange(n, 1, 65536));
        blocks.Clear();
        Error("fileLimit", () => fs.Hash(root, "a.md", bytes.Length - 1));
        Assert.Empty(blocks);
        string snapshotPath;
        using (var snapshot = fs.Snapshot(root, "a.md", bytes.Length))
        {
            snapshotPath = snapshot.Path;
            Assert.EndsWith(".md", snapshotPath);
            Assert.Equal(bytes, File.ReadAllBytes(snapshotPath));
            Assert.Equal(read.Stamp, snapshot.Stamp);
            Assert.Equal(read.Sha256, snapshot.Hash);
        }
        Assert.False(File.Exists(snapshotPath));
        using var cancelled = new CancellationTokenSource();
        var cancellable = new NativeFolderFileSystem(bytesRead: _ => cancelled.Cancel());
        Assert.ThrowsAny<OperationCanceledException>(() => cancellable.Hash(root, "a.md", bytes.Length, cancelled.Token));
        using (File.Open(Path.Combine(tree.Path, "a.md"), FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
    }

    [Fact]
    public void VolumeIdentity()
    {
        var names = new HashSet<string>();
        foreach (var row in Cases().Where(c => c.GetProperty("operation").GetString() == "identity"))
        {
            names.Add(Name(row));
            var input = row.GetProperty("input"); var expected = row.GetProperty("expected");
            switch (input.GetProperty("action").GetString())
            {
                case "resolve-root":
                    var resolver = new FixtureIdentity(Identity(input.GetProperty("resolvedIdentity")));
                    using (var store = new NotebookStore(StorePath.InMemory))
                    {
                        long nb = store.CreateNotebook("identity").Id!.Value;
                        var created = store.CreateFolder(nb, Draft(input.GetProperty("selectedPath").GetString()!), resolver, 0);
                        Assert.Equal(Identity(expected.GetProperty("identity")).RootFileId, created.Identity.RootFileId);
                        Assert.Equal(Identity(expected.GetProperty("identity")).VolumeId, created.Identity.VolumeId);
                        Assert.Equal(Identity(expected.GetProperty("identity")).Components, created.Identity.Components);
                        Assert.Equal(expected.GetProperty("rootResolutions").GetInt32(), resolver.Calls);
                    }
                    break;
                case "validate-root":
                    Error(expected.GetProperty("error").GetString()!, () => FolderAccessPolicy.ValidateRoot(
                        Identity(input.GetProperty("persistedIdentity")), Identity(input.GetProperty("openedIdentity"))));
                    break;
                case "containment":
                    var identity = Identity(input.GetProperty("rootIdentity"));
                    Error(expected.GetProperty("error").GetString()!, () => FolderAccessPolicy.ValidateContainment(identity,
                        identity.VolumeId, Strings(input, "resolvedComponents")));
                    break;
                case "canonicalize-paths":
                    // The filesystem supplies actual on-disk spelling, not a globally folded path.
                    var paths = Strings(input, "paths"); var canonical = Strings(input, "canonicalPaths");
                    var map = paths.Select((p, n) => (p, n)).ToDictionary(x => x.p, x => canonical[x.n], StringComparer.Ordinal);
                    Assert.Equal(Strings(expected, "sourcePaths"), FolderAccessPolicy.CanonicalPaths(paths, p => map[p]));
                    break;
                default: Assert.Fail("Unknown identity action"); break;
            }
        }
        Assert.Equal(6, names.Count);
        using var tree = new Tree();
        var native = new NativeFolderFileSystem();
        var root = Root(native, tree.Path);
        Assert.Equal(native.Stat(root, "").Identity, root.Identity.RootFileId);
        Assert.NotEmpty(root.Identity.VolumeId);
        string caseProbe = Path.Combine(tree.Path, "CASE-probe.md");
        File.WriteAllText(caseProbe, "case");
        Assert.Equal(!File.Exists(Path.Combine(tree.Path, "case-probe.md")), native.CaseSensitive(root));
        File.Delete(caseProbe);
        File.WriteAllText(Path.Combine(tree.Path, "😀.md"), "x");
        File.WriteAllText(Path.Combine(tree.Path, "\uE000.md"), "y");
        Assert.Equal(new[] { "\uE000.md", "😀.md" }, native.List(root, "").Select(e => e.RelPath));
        Assert.Equal(root.Identity.RootFileId, native.Resolve(Path.Combine(tree.Path, ".")).RootFileId);
    }

    internal static FolderSource Root(IFolderPathIdentity fs, string path) => new(1, 1, Draft(path), fs.Resolve(path), "idle", 0, null, null, 0);
    private static FolderDraft Draft(string path) => new(path, "Docs", new[] { "md" }, Array.Empty<string>(), "{}", "cp1250", true);
    private static FolderIdentity Identity(JsonElement e) => new(e.GetProperty("volumeId").GetString()!, Strings(e, "components"), e.GetProperty("rootFileId").GetString()!);
    private static FileStamp Stamp(JsonElement e) => new(e.GetProperty("identity").GetString()!, e.GetProperty("mtimeNs").GetInt64(), e.GetProperty("sizeBytes").GetInt64());
    private static JsonElement[] Cases() => SharedFixtures.Json("contracts/ingestion-scan-v1.json").GetProperty("cases").EnumerateArray().ToArray();
    private static string Name(JsonElement row) => row.GetProperty("name").GetString()!;
    private static string[] Strings(JsonElement e, string key) => e.GetProperty(key).EnumerateArray().Select(x => x.GetString()!).ToArray();
    private static void Error(string code, Action action) => Assert.Equal(code, Assert.Throws<FolderIngestionException>(action).Code);
    private sealed class FixtureIdentity(FolderIdentity identity) : IFolderPathIdentity
    {
        public int Calls;
        public FolderIdentity Resolve(string path) { Calls++; return identity; }
    }
    private sealed class Tree : IDisposable
    {
        public string Path { get; } = Directory.CreateDirectory(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "wp6-win-fs-" + Guid.NewGuid())).FullName;
        public void Dispose() => Directory.Delete(Path, true);
    }
}

internal sealed class ScriptedFS : IFolderFileSystem
{
    public FolderSource Root { get; }
    private readonly bool _sensitive;
    private readonly Dictionary<string, FileStamp> _stamps;
    private readonly Dictionary<string, FolderEntry[]> _directories;
    private readonly HashSet<string> _denied;
    private readonly List<string> _calls = [];
    private readonly object _gate = new();
    private readonly Dictionary<string, int> _statCalls = new();
    public string[] ListCalls { get { lock (_gate) return _calls.ToArray(); } }
    public bool DenyRoot { get; init; }
    public Func<string, int, FileStamp, FileStamp>? ObserveStamp { get; init; }
    public int ReadCalls { get; private set; }
    public ScriptedFS(JsonElement row)
    {
        var i = row.GetProperty("input"); var r = i.GetProperty("root");
        var identity = new FolderIdentity(r.GetProperty("volumeId").GetString()!,
            r.GetProperty("components").EnumerateArray().Select(x => x.GetString()!).ToArray(), r.GetProperty("rootFileId").GetString()!);
        var draft = new FolderDraft(r.GetProperty("rootPath").GetString()!, r.GetProperty("displayName").GetString()!,
            new[] { "md" }, Array.Empty<string>(), "{}", "cp1250", true);
        Root = new FolderSource(r.GetProperty("id").GetInt64(), r.GetProperty("notebookId").GetInt64(), draft, identity, "idle", 0, null, null, 0);
        _sensitive = i.GetProperty("caseSensitive").GetBoolean();
        _stamps = i.GetProperty("stats").EnumerateObject().ToDictionary(p => p.Name, p => new FileStamp(
            p.Value.GetProperty("identity").GetString()!, p.Value.GetProperty("mtimeNs").GetInt64(), p.Value.GetProperty("sizeBytes").GetInt64()));
        _directories = i.GetProperty("directories").EnumerateObject().ToDictionary(p => p.Name, p => p.Value.EnumerateArray().Select(e =>
            new FolderEntry(e.GetProperty("relPath").GetString()!, e.GetProperty("isDirectory").GetBoolean(), e.GetProperty("isLink").GetBoolean(),
                _stamps[e.GetProperty("relPath").GetString()!])).ToArray());
        var errors = i.GetProperty("listErrors").EnumerateObject().ToArray();
        Assert.All(errors, e => Assert.Equal("permissionDenied", e.Value.GetString()));
        _denied = errors.Select(e => e.Name).ToHashSet();
    }
    public FolderIdentity Resolve(string rootPath)
    {
        if (DenyRoot) throw new UnauthorizedAccessException();
        Assert.Equal(Root.Draft.RootPath, rootPath); return Root.Identity;
    }
    public bool CaseSensitive(FolderSource root) => _sensitive;
    public IReadOnlyList<FolderEntry> List(FolderSource root, string directory)
    {
        lock (_gate) _calls.Add(directory);
        if (_denied.Contains(directory)) throw new UnauthorizedAccessException(directory);
        Assert.True(_directories.ContainsKey(directory), "Unexpected list: " + directory);
        return _directories[directory];
    }
    public FileStamp Stat(FolderSource root, string relativePath)
    {
        Assert.True(_stamps.ContainsKey(relativePath), "Unexpected stat: " + relativePath);
        lock (_gate)
        {
            int call = _statCalls.GetValueOrDefault(relativePath) + 1;
            _statCalls[relativePath] = call;
            return ObserveStamp?.Invoke(relativePath, call, _stamps[relativePath]) ?? _stamps[relativePath];
        }
    }
    public FolderRead Hash(FolderSource root, string relativePath, long maxBytes)
    { ReadCalls++; Assert.Fail("Walk must not hash file bodies"); throw new InvalidOperationException(); }
    public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes)
    { ReadCalls++; Assert.Fail("Walk must not snapshot file bodies"); throw new InvalidOperationException(); }
}
