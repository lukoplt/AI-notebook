using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Win32.SafeHandles;

namespace AINotebook.Core.Ingestion;

/// <summary>Native identities and no-follow access. User files are never modified.</summary>
public sealed class NativeFolderFileSystem : IFolderFileSystem
{
    private readonly Action<string>? _beforeOpen;
    private readonly Action<int>? _bytesRead;
    public NativeFolderFileSystem() : this(null, null) { }
    internal NativeFolderFileSystem(Action<string>? beforeOpen = null, Action<int>? bytesRead = null)
    { _beforeOpen = beforeOpen; _bytesRead = bytesRead; }

    public FolderIdentity Resolve(string rootPath)
    {
        using var root = OpenRoot(rootPath);
        return Identity(root);
    }

    public bool CaseSensitive(FolderSource root)
    {
        using var opened = OpenRoot(root.Draft.RootPath, root.Identity);
        if (OperatingSystem.IsWindows())
        {
            if (WindowsCaseInfo(opened.Handle, 23, out uint flags, sizeof(uint))) return (flags & 1) != 0;
            int error = Marshal.GetLastPInvokeError();
            // Volumes without per-directory case flags use Win32's insensitive lookup.
            if (error is 1 or 50 or 87) return false;
            throw NativeError(error);
        }
        var attributes = new MacAttributeList { Count = 5, Volume = 0x80020000 };
        byte[] values = new byte[36];
        if (MacGetAttributes(Fd(opened.Handle), ref attributes, values, (nuint)values.Length, 0) != 0)
            throw NativeError(Marshal.GetLastPInvokeError());
        const uint sensitive = 0x100;
        if ((BitConverter.ToUInt32(values, 20) & sensitive) == 0)
            throw new IOException("The volume did not report its case sensitivity.");
        return (BitConverter.ToUInt32(values, 4) & sensitive) != 0;
    }

    public IReadOnlyList<FolderEntry> List(FolderSource root, string directory)
    {
        using var path = OpenPath(root, directory, forData: false);
        if (!path.Leaf.Info.Directory) throw new IOException("Expected a directory.");
        var entries = OperatingSystem.IsWindows() ? ListWindows(path.Leaf) : ListMac(path.Leaf);
        path.Validate();
        return entries.OrderBy(entry => entry.RelPath, ScalarPathComparer.Instance).ToArray();
    }

    public FileStamp Stat(FolderSource root, string relativePath)
    {
        using var path = OpenPath(root, relativePath, forData: false);
        return path.Leaf.Info.Stamp;
    }

    public FolderRead Hash(FolderSource root, string relativePath, long maxBytes) =>
        Hash(root, relativePath, maxBytes, CancellationToken.None);

    public FolderRead Hash(FolderSource root, string relativePath, long maxBytes, CancellationToken ct)
    {
        var result = ReadFile(root, relativePath, maxBytes, null, ct);
        // Hash streams the body; retaining payload bytes would defeat memory admission.
        return new FolderRead(Array.Empty<byte>(), result.Stamp, result.Hash);
    }

    public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes) =>
        Snapshot(root, relativePath, maxBytes, CancellationToken.None);

    public FolderFileSnapshot Snapshot(FolderSource root, string relativePath, long maxBytes, CancellationToken ct)
    {
        ValidateRelativePath(relativePath);
        string temporary = Path.Combine(Path.GetTempPath(), "ainotebook-folder-" + Guid.NewGuid().ToString("N") + Path.GetExtension(relativePath));
        try
        {
            var options = new FileStreamOptions
            {
                Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.None,
                BufferSize = 65_536, Options = FileOptions.SequentialScan
            };
            if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
            (FileStamp Stamp, string Hash) result;
            using (var output = new FileStream(temporary, options))
                result = ReadFile(root, relativePath, maxBytes, output, ct);
            ct.ThrowIfCancellationRequested();
            if (OperatingSystem.IsWindows()) File.SetAttributes(temporary, FileAttributes.ReadOnly);
            else File.SetUnixFileMode(temporary, UnixFileMode.UserRead);
            return new FolderFileSnapshot(temporary, result.Stamp, result.Hash);
        }
        catch
        {
            if (File.Exists(temporary))
            {
                if (OperatingSystem.IsWindows()) File.SetAttributes(temporary, FileAttributes.Normal);
                File.Delete(temporary);
            }
            throw;
        }
    }

    private (FileStamp Stamp, string Hash) ReadFile(FolderSource root, string relativePath, long maximum, Stream? output, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (maximum < 0 || maximum > RagContractV1.Scan.MaxFileBytes) throw new FolderIngestionException("fileLimit");
        using var path = OpenPath(root, relativePath, forData: true);
        FileStamp initial = path.Leaf.Info.Stamp;
        if (path.Leaf.Info.Directory) throw new FolderIngestionException("outsideRoot");
        if (initial.SizeBytes > maximum) throw new FolderIngestionException("fileLimit");
        using var stream = new FileStream(path.Leaf.Handle, FileAccess.Read, 65_536, isAsync: false);
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        byte[] buffer = new byte[65_536];
        long used = 0;
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            int count = stream.Read(buffer, 0, buffer.Length);
            ct.ThrowIfCancellationRequested();
            if (count == 0) break;
            if (count > maximum - used) throw new FolderIngestionException("fileLimit");
            _bytesRead?.Invoke(count);
            ct.ThrowIfCancellationRequested();
            hash.AppendData(buffer, 0, count);
            output?.Write(buffer, 0, count);
            used += count;
        }
        NativeInfo after = GetInfo(path.Leaf.Handle);
        if (initial != after.Stamp || used != initial.SizeBytes) throw new FolderIngestionException("changedDuringExtraction");
        path.Validate();
        return (initial, Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant());
    }

    private OpenedPath OpenPath(FolderSource source, string relativePath, bool forData)
    {
        string[] components = ValidateRelativePath(relativePath);
        var opened = new OpenedPath(source);
        try
        {
            opened.Nodes.Add(OpenRoot(source.Draft.RootPath, source.Identity));
            for (int index = 0; index < components.Length; index++)
            {
                Node parent = opened.Leaf;
                if (!parent.Info.Directory) throw new FolderIngestionException("outsideRoot");
                string name = components[index];
                NativeInfo enumerated = ChildInfo(parent, name);
                if (enumerated.Link) throw new FolderIngestionException("interiorLink");
                if (forData && index == components.Length - 1)
                {
                    _beforeOpen?.Invoke(relativePath);
                    // Windows opens by the pinned parent's canonical name. Refuse a
                    // replacement of that name before opening its proposed child.
                    opened.Validate();
                }
                Node child = OpenChild(parent, name, forData && index == components.Length - 1, enumerated.Directory);
                opened.Nodes.Add(child);
                // Parent revocation takes precedence over a changed leaf stamp if a
                // replacement raced the final open after the preceding validation.
                if (enumerated.Stamp != child.Info.Stamp) opened.Validate();
                FolderAccessPolicy.ValidateOpened(enumerated.Stamp, child.Info.Stamp, child.Info.Link,
                    parent.Info.Stamp.Identity, parent.Info.Stamp.Identity);
                FolderAccessPolicy.ValidateContainment(source.Identity, child.Info.VolumeId, Components(child.Path));
            }
            opened.Validate();
            return opened;
        }
        catch { opened.Dispose(); throw; }
    }

    private static string[] ValidateRelativePath(string path)
    {
        if (path is null || path.Contains('\\') || path.Contains(':') || path.Contains('\0') || path.StartsWith('/'))
            throw new FolderIngestionException("outsideRoot");
        if (path.Length == 0) return Array.Empty<string>();
        string[] components = path.Split('/');
        if (components.Any(component => component is "" or "." or "..")) throw new FolderIngestionException("outsideRoot");
        return components;
    }

    private static Node OpenRoot(string path, FolderIdentity? expected = null)
    {
        SafeFileHandle? handle = null;
        try
        {
            if (OperatingSystem.IsWindows()) handle = OpenWindows(path, follow: true, read: false, directory: true);
            else if (OperatingSystem.IsMacOS()) handle = OpenMac(path, MacDirectory | MacCloseOnExec);
            else throw new PlatformNotSupportedException("Native folder ingestion supports Windows and macOS.");
            NativeInfo info = GetInfo(handle);
            if (!info.Directory) throw new FolderIngestionException("rootUnavailable");
            var root = new Node(handle, info, HandlePath(handle), "");
            if (expected is not null) FolderAccessPolicy.ValidateRoot(expected, Identity(root));
            return root;
        }
        catch (Exception error)
        {
            handle?.Dispose();
            if (error is IOException or UnauthorizedAccessException) throw new FolderIngestionException("rootUnavailable");
            throw;
        }
    }

    private static Node OpenChild(Node parent, string name, bool read, bool directory)
    {
        SafeFileHandle handle;
        if (OperatingSystem.IsWindows())
            handle = OpenWindows(parent.Path.TrimEnd('\\') + "\\" + name, follow: false, read, directory);
        else
        {
            int fd = MacOpenAt(Fd(parent.Handle), name, MacNoFollow | MacCloseOnExec | MacNonBlock | (directory ? MacDirectory : 0));
            if (fd < 0) throw MacOpenError();
            handle = new SafeFileHandle((IntPtr)fd, ownsHandle: true);
        }
        try
        {
            var info = GetInfo(handle);
            if (info.Link) throw new FolderIngestionException("interiorLink");
            string path = HandlePath(handle);
            string canonicalName = OperatingSystem.IsWindows() ? path[(path.LastIndexOf('\\') + 1)..] : path[(path.LastIndexOf('/') + 1)..];
            return new Node(handle, info, path, parent.RelPath.Length == 0 ? canonicalName : parent.RelPath + "/" + canonicalName);
        }
        catch { handle.Dispose(); throw; }
    }

    private static NativeInfo ChildInfo(Node parent, string name)
    {
        if (OperatingSystem.IsWindows())
        {
            using var handle = OpenWindows(parent.Path.TrimEnd('\\') + "\\" + name, follow: false, read: false, directory: false);
            return GetInfo(handle);
        }
        if (MacStatAt(Fd(parent.Handle), name, out var stat, 0x20) != 0) throw NativeError(Marshal.GetLastPInvokeError());
        // A different device is an interior mounted filesystem, outside the saved root volume.
        string volume = stat.Device == parent.Info.Device ? parent.Info.VolumeId : "mac-device:" + ((uint)stat.Device).ToString("x8");
        return Info(stat, volume);
    }

    private static FolderIdentity Identity(Node node) => new(node.Info.VolumeId, Components(node.Path), node.Info.Stamp.Identity);
    private static string[] Components(string path)
    {
        if (OperatingSystem.IsWindows())
        {
            string prefix = Path.GetPathRoot(path) ?? throw new FolderIngestionException("outsideRoot");
            return path[prefix.Length..].Split('\\', StringSplitOptions.RemoveEmptyEntries);
        }
        return path.Split('/', StringSplitOptions.RemoveEmptyEntries);
    }

    private sealed record NativeInfo(FileStamp Stamp, string VolumeId, bool Directory, bool Link, int Device = 0);
    private sealed record Node(SafeFileHandle Handle, NativeInfo Info, string Path, string RelPath) : IDisposable
    { public void Dispose() => Handle.Dispose(); }

    private sealed class OpenedPath(FolderSource root) : IDisposable
    {
        public List<Node> Nodes { get; } = [];
        public Node Leaf => Nodes[^1];
        public void Validate()
        {
            using var currentRoot = OpenRoot(root.Draft.RootPath, root.Identity);
            for (int index = 0; index < Nodes.Count; index++)
            {
                Node node = Nodes[index];
                NativeInfo actual = GetInfo(node.Handle);
                FolderAccessPolicy.ValidateContainment(root.Identity, actual.VolumeId, Components(HandlePath(node.Handle)));
                if (index == 0) continue;
                Node parent = Nodes[index - 1];
                string name = node.RelPath[(node.RelPath.LastIndexOf('/') + 1)..];
                NativeInfo current;
                try { current = ChildInfo(parent, name); }
                catch (IOException) { throw new FolderIngestionException("outsideRoot"); }
                if (current.Link && index == Nodes.Count - 1) throw new FolderIngestionException("interiorLink");
                if (current.Stamp.Identity != node.Info.Stamp.Identity || current.Link)
                    throw new FolderIngestionException(index == Nodes.Count - 1 && !node.Info.Directory ? "changedDuringExtraction" : "outsideRoot");
                // A pinned parent's name may now refer to a replacement. Reopen its original
                // name under the previous pinned parent before any body bytes are consumed.
                if (index < Nodes.Count - 1 && current.Stamp.Identity != actual.Stamp.Identity)
                    throw new FolderIngestionException("outsideRoot");
            }
        }
        public void Dispose()
        {
            for (int index = Nodes.Count - 1; index >= 0; index--) Nodes[index].Dispose();
        }
    }

    private static IReadOnlyList<FolderEntry> ListMac(Node directory)
    {
        int duplicate = MacDuplicate(Fd(directory.Handle));
        if (duplicate < 0) throw NativeError(Marshal.GetLastPInvokeError());
        IntPtr stream = MacOpenDirectory(duplicate);
        if (stream == IntPtr.Zero)
        {
            int error = Marshal.GetLastPInvokeError();
            MacClose(duplicate);
            throw NativeError(error);
        }
        var entries = new List<FolderEntry>();
        try
        {
            while (true)
            {
                Marshal.SetLastPInvokeError(0);
                IntPtr entry = MacReadDirectory(stream);
                if (entry == IntPtr.Zero)
                {
                    int error = Marshal.GetLastPInvokeError();
                    if (error != 0) throw NativeError(error);
                    break;
                }
                int length = (ushort)Marshal.ReadInt16(entry, 18);
                if (length is < 1 or > 1023) throw new IOException("Invalid native directory entry.");
                byte[] bytes = new byte[length];
                Marshal.Copy(entry + 21, bytes, 0, length);
                string name = new UTF8Encoding(false, true).GetString(bytes);
                if (name is "." or "..") continue;
                NativeInfo info = ChildInfo(directory, name);
                string relative = directory.RelPath.Length == 0 ? name : directory.RelPath + "/" + name;
                entries.Add(new FolderEntry(relative, info.Directory, info.Link, info.Stamp));
            }
        }
        finally { MacCloseDirectory(stream); }
        return entries;
    }

    private static IReadOnlyList<FolderEntry> ListWindows(Node directory)
    {
        var entries = new List<FolderEntry>();
        byte[] buffer = new byte[65_536];
        bool restart = true;
        while (true)
        {
            if (!WindowsDirectoryInfo(directory.Handle, restart ? 20 : 19, buffer, (uint)buffer.Length))
            {
                int error = Marshal.GetLastPInvokeError();
                if (error == 18) break;
                throw NativeError(error);
            }
            restart = false;
            int offset = 0;
            while (true)
            {
                uint next = BitConverter.ToUInt32(buffer, offset);
                uint nameBytes = BitConverter.ToUInt32(buffer, offset + 60);
                if (nameBytes > buffer.Length - offset - 88 || (nameBytes & 1) != 0) throw new IOException("Invalid native directory entry.");
                string name = new UnicodeEncoding(false, false, true).GetString(buffer, offset + 88, (int)nameBytes);
                if (name is not ("." or ".."))
                {
                    uint attributes = BitConverter.ToUInt32(buffer, offset + 56);
                    string id = directory.Info.VolumeId + ":" + BitConverter.ToUInt64(buffer, offset + 72).ToString("x16") + BitConverter.ToUInt64(buffer, offset + 80).ToString("x16");
                    long size = BitConverter.ToInt64(buffer, offset + 40);
                    long time = WindowsNs(BitConverter.ToInt64(buffer, offset + 24));
                    string relative = directory.RelPath.Length == 0 ? name : directory.RelPath + "/" + name;
                    entries.Add(new FolderEntry(relative, (attributes & 0x10) != 0, (attributes & 0x400) != 0, new FileStamp(id, time, size)));
                }
                if (next == 0) break;
                if (next < 88 || next > buffer.Length - offset - 88) throw new IOException("Invalid native directory offset.");
                offset += (int)next;
            }
        }
        return entries;
    }

    private static NativeInfo GetInfo(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows())
        {
            if (!WindowsIdInfo(handle, 18, out var id, (uint)Marshal.SizeOf<WinId>()) ||
                !WindowsBasicInfo(handle, 0, out var basic, (uint)Marshal.SizeOf<WinBasic>()) ||
                !WindowsStandardInfo(handle, 1, out var standard, (uint)Marshal.SizeOf<WinStandard>()))
                throw NativeError(Marshal.GetLastPInvokeError());
            string volume = "win:" + id.Volume.ToString("x16");
            return new NativeInfo(new FileStamp(volume + ":" + id.Low.ToString("x16") + id.High.ToString("x16"),
                WindowsNs(basic.Write), standard.Size), volume, (basic.Attributes & 0x10) != 0, (basic.Attributes & 0x400) != 0);
        }
        if (MacFileStat(Fd(handle), out var stat) != 0) throw NativeError(Marshal.GetLastPInvokeError());
        var attributes = new MacAttributeList { Count = 5, Volume = 0x80040000 };
        byte[] uuid = new byte[20];
        string macVolume = MacGetAttributes(Fd(handle), ref attributes, uuid, (nuint)uuid.Length, 0) == 0
            ? "mac:" + Convert.ToHexString(uuid.AsSpan(4, 16)).ToLowerInvariant()
            : "mac-device:" + ((uint)stat.Device).ToString("x8");
        return Info(stat, macVolume);
    }

    private static NativeInfo Info(MacStat stat, string volume)
    {
        int type = stat.Mode & 0xF000;
        return new NativeInfo(new FileStamp(volume + ":" + stat.Inode.ToString("x16"),
            checked(stat.ModifiedSeconds * 1_000_000_000 + stat.ModifiedNanoseconds), stat.Size), volume,
            type == 0x4000, type is not (0x4000 or 0x8000), stat.Device);
    }

    private static string HandlePath(SafeFileHandle handle)
    {
        if (OperatingSystem.IsWindows())
        {
            var path = new StringBuilder(1024);
            uint length = WindowsFinalPath(handle, path, (uint)path.Capacity, 0);
            if (length == 0) throw NativeError(Marshal.GetLastPInvokeError());
            if (length >= path.Capacity)
            {
                path = new StringBuilder(checked((int)length + 1));
                if (WindowsFinalPath(handle, path, (uint)path.Capacity, 0) == 0) throw NativeError(Marshal.GetLastPInvokeError());
            }
            return path.ToString().TrimEnd('\\');
        }
        byte[] bytes = new byte[4096];
        if (MacGetPath(Fd(handle), 50, bytes) != 0) throw NativeError(Marshal.GetLastPInvokeError());
        int end = Array.IndexOf(bytes, (byte)0);
        return new UTF8Encoding(false, true).GetString(bytes, 0, end < 0 ? bytes.Length : end);
    }

    private static SafeFileHandle OpenWindows(string path, bool follow, bool read, bool directory)
    {
        uint access = read ? 0x80000000 : directory ? 0x81U : 0x80U;
        var handle = WindowsCreateFile(path, access, 7, IntPtr.Zero, 3, 0x02000000U | (follow ? 0 : 0x00200000U), IntPtr.Zero);
        if (!handle.IsInvalid) return handle;
        int error = Marshal.GetLastPInvokeError();
        handle.Dispose();
        throw NativeError(error);
    }
    private static SafeFileHandle OpenMac(string path, int flags)
    {
        int fd = MacOpen(path, flags);
        if (fd < 0) throw NativeError(Marshal.GetLastPInvokeError());
        return new SafeFileHandle((IntPtr)fd, ownsHandle: true);
    }
    private static int Fd(SafeFileHandle handle) => handle.DangerousGetHandle().ToInt32();
    private static long WindowsNs(long time) => checked((time - 116_444_736_000_000_000L) * 100);
    private static Exception MacOpenError() => Marshal.GetLastPInvokeError() == 62
        ? new FolderIngestionException("interiorLink") : NativeError(Marshal.GetLastPInvokeError());
    private static Exception NativeError(int error) => error is 5 && OperatingSystem.IsWindows() || error is 1 or 13 && !OperatingSystem.IsWindows()
        ? new UnauthorizedAccessException("Native folder access was denied.", new Win32Exception(error))
        : new IOException("Native folder access failed.", new Win32Exception(error));

    private const int MacNonBlock = 4, MacNoFollow = 0x100, MacDirectory = 0x100000, MacCloseOnExec = 0x1000000;
    [StructLayout(LayoutKind.Sequential)] private struct WinId { public ulong Volume, Low, High; }
    [StructLayout(LayoutKind.Sequential)] private struct WinBasic { public long Creation, Access, Write, Change; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] private struct WinStandard { public long Allocation, Size; public uint Links; public byte DeletePending, Directory; }
    [StructLayout(LayoutKind.Sequential)] private struct MacAttributeList { public ushort Count, Reserved; public uint Common, Volume, Directory, File, Fork; }
    [StructLayout(LayoutKind.Sequential)] private struct MacStat
    {
        public int Device; public ushort Mode, Links; public ulong Inode; public uint User, Group; public int SpecialDevice;
        public long AccessSeconds, AccessNanoseconds, ModifiedSeconds, ModifiedNanoseconds, ChangeSeconds, ChangeNanoseconds, BirthSeconds, BirthNanoseconds;
        public long Size, Blocks; public int BlockSize; public uint Flags, Generation; public int Spare; public long Spare1, Spare2;
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle WindowsCreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WindowsIdInfo(SafeFileHandle handle, int kind, out WinId info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WindowsBasicInfo(SafeFileHandle handle, int kind, out WinBasic info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WindowsStandardInfo(SafeFileHandle handle, int kind, out WinStandard info, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WindowsCaseInfo(SafeFileHandle handle, int kind, out uint flags, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFileInformationByHandleEx", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool WindowsDirectoryInfo(SafeFileHandle handle, int kind, [Out] byte[] buffer, uint size);
    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint WindowsFinalPath(SafeFileHandle handle, StringBuilder path, uint size, uint flags);
    [DllImport("libc", EntryPoint = "open", SetLastError = true)] private static extern int MacOpen([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);
    [DllImport("libc", EntryPoint = "openat", SetLastError = true)] private static extern int MacOpenAt(int directory, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags);
    [DllImport("libc", EntryPoint = "fstat", SetLastError = true)] private static extern int MacFileStat(int fd, out MacStat stat);
    [DllImport("libc", EntryPoint = "fstatat", SetLastError = true)] private static extern int MacStatAt(int fd, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, out MacStat stat, int flags);
    // Darwin's public fcntl is variadic. Its fixed syscall entry avoids the Apple
    // ARM64 varargs ABI, which differs from a fixed third P/Invoke parameter.
    [DllImport("libc", EntryPoint = "__fcntl", SetLastError = true)] private static extern int MacGetPath(int fd, int command, [Out] byte[] path);
    [DllImport("libc", EntryPoint = "fgetattrlist", SetLastError = true)] private static extern int MacGetAttributes(int fd, ref MacAttributeList attributes, [Out] byte[] values, nuint size, uint options);
    [DllImport("libc", EntryPoint = "dup", SetLastError = true)] private static extern int MacDuplicate(int fd);
    [DllImport("libc", EntryPoint = "close", SetLastError = true)] private static extern int MacClose(int fd);
    [DllImport("libc", EntryPoint = "fdopendir", SetLastError = true)] private static extern IntPtr MacOpenDirectory(int fd);
    [DllImport("libc", EntryPoint = "readdir", SetLastError = true)] private static extern IntPtr MacReadDirectory(IntPtr directory);
    [DllImport("libc", EntryPoint = "closedir", SetLastError = true)] private static extern int MacCloseDirectory(IntPtr directory);
}
