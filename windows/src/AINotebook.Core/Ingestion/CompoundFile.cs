namespace AINotebook.Core.Ingestion;

/// <summary>One read/decoded byte counter per document (maxOfficeDecompressedBytes).</summary>
internal sealed class MailByteBudget(long maximum)
{
    public long Used { get; private set; }

    public void Accept(long count)
    {
        if (count < 0 || count > maximum - Used) throw new FolderIngestionException("officeLimit");
        Used += count;
    }
}

/// <summary>
/// Bounded, dependency-free reader of the OLE Compound File Binary format (MS-CFB) used by Outlook .msg
/// files (contract ingestion-mail-v1; same rules as macOS CompoundFile). Every sector chain is loop-checked,
/// every index range-checked, directory traversal is iterative and cycle-checked, and every sector read is
/// debited from the document byte budget. Structural damage is corruptArchive; exceeding a bound is
/// officeLimit. Stream contents are read only on demand (attachment payloads never).
/// </summary>
internal sealed class CompoundFile
{
    internal static readonly byte[] Magic = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1];
    internal const int MaxEntries = 100_000;
    private const uint EndOfChain = 0xFFFFFFFE, FreeSector = 0xFFFFFFFF, NoStream = 0xFFFFFFFF;

    internal sealed record Entry(string Name, byte Kind, uint Left, uint Right, uint Child, uint Start, ulong Size);

    private readonly byte[] _data;
    private readonly MailByteBudget _budget;
    private readonly CancellationToken _ct;
    private readonly int _sectorSize;
    private readonly int _sectorCount;
    private readonly uint _firstMiniFat;
    private readonly List<uint> _fat = [];
    private byte[]? _miniStream;
    private uint[] _miniFat = [];

    internal List<Entry> Entries { get; } = [];

    private static FolderIngestionException Corrupt() => new("corruptArchive");

    internal static int U16(byte[] data, int at) => data[at] | data[at + 1] << 8;
    internal static uint U32(byte[] data, int at) =>
        (uint)(data[at] | data[at + 1] << 8 | data[at + 2] << 16 | data[at + 3] << 24);

    internal CompoundFile(byte[] data, MailByteBudget budget, CancellationToken ct)
    {
        _data = data;
        _budget = budget;
        _ct = ct;
        if (data.Length < 512 || !data.AsSpan(0, 8).SequenceEqual(Magic)) throw Corrupt();
        int major = U16(data, 26), order = U16(data, 28), shift = U16(data, 30), miniShift = U16(data, 32);
        if (order != 0xFFFE || miniShift != 6 || U32(data, 56) != 4096 ||
            !((major == 3 && shift == 9) || (major == 4 && shift == 12))) throw Corrupt();
        _sectorSize = 1 << shift;
        if (data.Length < _sectorSize) throw Corrupt();
        _sectorCount = (data.Length - _sectorSize + _sectorSize - 1) / _sectorSize;
        uint fatCount = U32(data, 44), firstDirectory = U32(data, 48);
        _firstMiniFat = U32(data, 60);
        uint firstDifat = U32(data, 68), difatCount = U32(data, 72);
        if (fatCount > (uint)_sectorCount || difatCount > (uint)_sectorCount) throw Corrupt();
        var difat = new List<uint>(109);
        for (int k = 0; k < 109; k++) difat.Add(U32(data, 76 + 4 * k));
        uint sector = firstDifat;
        var seen = new HashSet<uint>();
        int perSector = _sectorSize / 4 - 1;
        for (uint step = 0; step < difatCount; step++)
        {
            ct.ThrowIfCancellationRequested();
            if (sector >= (uint)_sectorCount || !seen.Add(sector)) throw Corrupt();
            var block = ReadSector(sector);
            for (int k = 0; k < perSector; k++) difat.Add(U32(block, 4 * k));
            sector = U32(block, 4 * perSector);
        }
        var fatSectors = difat.Where(value => value != FreeSector).Take((int)fatCount).ToList();
        if (fatSectors.Count != (int)fatCount || fatSectors.Any(value => value >= (uint)_sectorCount) ||
            fatSectors.Distinct().Count() != fatSectors.Count) throw Corrupt();
        foreach (var fatSector in fatSectors)
        {
            ct.ThrowIfCancellationRequested();
            var block = ReadSector(fatSector);
            for (int k = 0; k < _sectorSize / 4; k++) _fat.Add(U32(block, 4 * k));
        }
        var directory = ChainBytes(firstDirectory, null);
        if (directory.Length / 128 > MaxEntries) throw new FolderIngestionException("officeLimit");
        for (int k = 0; k < directory.Length / 128; k++)
        {
            var raw = directory.AsSpan(128 * k, 128).ToArray();
            int nameLength = U16(raw, 64);
            byte kind = raw[66];
            if (kind is not (0 or 1 or 2 or 5)) throw Corrupt();
            if (kind != 0 && (nameLength < 2 || nameLength > 64 || nameLength % 2 == 1)) throw Corrupt();
            string name = kind == 0 ? "" : MailText.Utf16Le(raw.AsSpan(0, nameLength - 2));
            ulong low = U32(raw, 120), high = U32(raw, 124);
            Entries.Add(new Entry(name, kind, U32(raw, 68), U32(raw, 72), U32(raw, 76), U32(raw, 116),
                major == 3 ? low : low | high << 32));
        }
        if (Entries.Count == 0 || Entries[0].Kind != 5) throw Corrupt();
    }

    private byte[] ReadSector(uint index)
    {
        long offset = ((long)index + 1) * _sectorSize;
        _budget.Accept(_sectorSize);
        var block = new byte[_sectorSize];
        if (offset < _data.Length)
            Array.Copy(_data, offset, block, 0, (int)Math.Min(_sectorSize, _data.Length - offset));
        return block;
    }

    /// <summary>Sector indices from start; stops after needed sectors (null: at ENDOFCHAIN).</summary>
    private List<uint> Chain(uint start, int? needed, IReadOnlyList<uint> table, int limit)
    {
        var output = new List<uint>();
        var seen = new HashSet<uint>();
        uint sector = start;
        while (sector != EndOfChain)
        {
            if (needed is { } count && output.Count >= count) break;
            _ct.ThrowIfCancellationRequested();
            if (sector >= (uint)limit || sector >= (uint)table.Count || !seen.Add(sector)) throw Corrupt();
            output.Add(sector);
            sector = table[(int)sector];
        }
        if (needed is { } required && output.Count < required) throw Corrupt();
        return output;
    }

    private byte[] ChainBytes(uint start, int? size)
    {
        int? needed = size is { } s ? (s + _sectorSize - 1) / _sectorSize : null;
        var sectors = Chain(start, needed, _fat, _sectorCount);
        var bytes = new byte[sectors.Count * _sectorSize];
        for (int k = 0; k < sectors.Count; k++) ReadSector(sectors[k]).CopyTo(bytes, k * _sectorSize);
        return size is { } exact ? bytes[..exact] : bytes;
    }

    /// <summary>Child storages/streams of index keyed by ASCII-uppercased name, in-order; the first name wins.</summary>
    internal Dictionary<string, int> Children(int index)
    {
        var result = new Dictionary<string, int>(StringComparer.Ordinal);
        var seen = new HashSet<uint>();
        var stack = new Stack<uint>();
        uint node = Entries[index].Child;
        while (stack.Count > 0 || node != NoStream)
        {
            while (node != NoStream)
            {
                if (node >= (uint)Entries.Count || !seen.Add(node)) throw Corrupt();
                stack.Push(node);
                node = Entries[(int)node].Left;
            }
            uint current = stack.Pop();
            var entry = Entries[(int)current];
            if (entry.Kind is 1 or 2) result.TryAdd(MailText.AsciiUpper(entry.Name), (int)current);
            node = entry.Right;
        }
        return result;
    }

    internal byte[] Stream(int index)
    {
        var entry = Entries[index];
        if (entry.Kind != 2 || entry.Size > (ulong)_data.Length) throw Corrupt();
        int size = (int)entry.Size;
        if (size == 0) return [];
        if (size >= 4096) return ChainBytes(entry.Start, size);
        if (_miniStream is null)
        {
            var root = Entries[0];
            if (root.Size > (ulong)_data.Length) throw Corrupt();
            _miniStream = root.Size == 0 ? Array.Empty<byte>() : ChainBytes(root.Start, (int)root.Size);
            var table = _firstMiniFat == EndOfChain ? Array.Empty<byte>() : ChainBytes(_firstMiniFat, null);
            _miniFat = new uint[table.Length / 4];
            for (int k = 0; k < _miniFat.Length; k++) _miniFat[k] = U32(table, 4 * k);
        }
        var mini = _miniStream;
        var sectors = Chain(entry.Start, (size + 63) / 64, _miniFat, (mini.Length + 63) / 64);
        var bytes = new List<byte>(sectors.Count * 64);
        foreach (var sector in sectors)
        {
            int offset = (int)sector * 64;
            bytes.AddRange(mini.AsSpan(offset, Math.Min(64, mini.Length - offset)).ToArray());
        }
        if (bytes.Count < size) throw Corrupt();
        return bytes.GetRange(0, size).ToArray();
    }
}
