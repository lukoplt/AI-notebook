using System.Collections.Concurrent;
using System.Collections.Frozen;
using System.Runtime.CompilerServices;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

public sealed record GenerationIdentity(string ProviderId, string EndpointRevision, string Model,
    string? ModelDigest, int Dims, string Normalization, string QueryFormatVersion,
    string DocFormatVersion, string ChunkerVersion);

public sealed record IndexGeneration(long Id, long NotebookId, GenerationIdentity Identity,
    string State, long CreatedAt, long? ActivatedAt);

public sealed record ManifestEntry(long SourceId, long RevisionId, string State, string? Reason);

public sealed record QueryPin(string Token, long NotebookId, long? GenerationId, string? ModelKey,
    int? Dims, IReadOnlyDictionary<long, long> LexicalRevisions, IReadOnlyDictionary<long, long> VectorRevisions)
{
    public IReadOnlyDictionary<long, long> LexicalRevisions { get; } = LexicalRevisions.ToFrozenDictionary();
    public IReadOnlyDictionary<long, long> VectorRevisions { get; } = VectorRevisions.ToFrozenDictionary();
}

public sealed record GarbageCollectionResult(int Generations, int Revisions, int Chunks, int Vectors);

/// <summary>
/// Shares pin coordination across connections. Every caller first holds its store gate,
/// then acquires this lease, then opens SQLite's transaction. No lease spans an await.
/// </summary>
internal static class GenerationPinRegistry
{
    internal sealed class Entry
    {
        internal readonly object Gate = new();
        internal readonly Dictionary<string, QueryPin> Pins = new(StringComparer.Ordinal);
        // Includes both current owners and waiters so an empty entry cannot be replaced
        // with a different gate while another connection is waiting to enter it.
        internal int Users;
    }

    private static readonly object RegistryGate = new();
    private static readonly ConcurrentDictionary<string, Entry> Entries = new(StringComparer.Ordinal);
    private sealed class MemoryIdentity { internal readonly string Value = "memory:" + Guid.NewGuid().ToString("N"); }
    private static readonly ConditionalWeakTable<SqliteConnection, MemoryIdentity> MemoryIdentities = new();

    internal static string Identity(SqliteConnection connection)
    {
        var options = new SqliteConnectionStringBuilder(connection.ConnectionString);
        if (options.Mode == SqliteOpenMode.Memory || options.DataSource == ":memory:")
            return MemoryIdentities.GetValue(connection, _ => new MemoryIdentity()).Value;
        string path = Path.GetFullPath(connection.DataSource);
        // Resolve directory aliases as well as a symlink at the database filename.
        string root = Path.GetPathRoot(path)!;
        string resolved = root;
        foreach (string component in path[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            // Prefer an exact directory entry. If the filesystem accepted a case or
            // normalization alias, reuse its actual spelling. Exact matching first
            // keeps distinct files distinct on case-sensitive volumes.
            string candidate = Path.Combine(resolved, component);
            var entries = Directory.EnumerateFileSystemEntries(resolved).ToArray();
            resolved = entries.FirstOrDefault(entry => StringComparer.Ordinal.Equals(Path.GetFileName(entry), component))
                ?? entries.FirstOrDefault(entry => StringComparer.OrdinalIgnoreCase.Equals(
                    Path.GetFileName(entry).Normalize(), component.Normalize()))
                ?? candidate;
            FileSystemInfo info = Directory.Exists(resolved) ? new DirectoryInfo(resolved) : new FileInfo(resolved);
            if (info.LinkTarget is not null) resolved = info.ResolveLinkTarget(returnFinalTarget: true)!.FullName;
        }
        return "file:" + resolved;
    }

    internal static Lease Acquire(string identity)
    {
        Entry entry;
        lock (RegistryGate)
        {
            entry = Entries.GetOrAdd(identity, _ => new Entry());
            entry.Users++;
        }
        Monitor.Enter(entry.Gate);
        return new Lease(identity, entry);
    }

    internal sealed class Lease : IDisposable
    {
        private readonly string _identity;
        private Entry? _entry;
        internal Lease(string identity, Entry entry) { _identity = identity; _entry = entry; }

        internal Dictionary<string, QueryPin> Pins => (_entry ?? throw new ObjectDisposedException(nameof(Lease))).Pins;

        public void Dispose()
        {
            if (_entry is not { } entry) return;
            _entry = null;
            // Keep the entry gate through registry cleanup. Acquire never waits for an
            // entry gate while holding RegistryGate, so this order cannot invert locks.
            lock (RegistryGate)
            {
                entry.Users--;
                if (entry.Users == 0 && entry.Pins.Count == 0) Entries.TryRemove(_identity, out _);
            }
            Monitor.Exit(entry.Gate);
        }
    }
}
