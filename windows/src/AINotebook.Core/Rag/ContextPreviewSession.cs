namespace AINotebook.Core.Rag;

/// <summary>Memory-only preview bytes with a shared draft/sent cap and FIFO sent retention.</summary>
public sealed class ContextPreviewSession
{
    private sealed record Entry(long SessionId, long AssistantId, byte[] Bytes);

    private readonly object _gate = new();
    private readonly List<Entry> _entries = [];
    private readonly int _maxTurns;
    private readonly int _maxBytes;
    private ulong _generation;
    private long? _draftSessionId;
    private byte[]? _draftKey;
    private byte[]? _draftBytes;
    // A temporary insertion can exceed Int32.MaxValue before FIFO eviction.
    private long _retainedBytes;

    public ContextPreviewSession(int maxTurns = RagContractV1.Pack.PreviewTurnsInMemory,
        int maxBytes = (int)RagContractV1.Pack.PreviewMaxBytes)
    {
        if (maxTurns <= 0) throw new ArgumentOutOfRangeException(nameof(maxTurns));
        if (maxBytes < 0) throw new ArgumentOutOfRangeException(nameof(maxBytes));
        _maxTurns = maxTurns;
        _maxBytes = maxBytes;
    }

    public int RetainedBytes { get { lock (_gate) return checked((int)_retainedBytes); } }
    public ulong Generation { get { lock (_gate) return _generation; } }
    public long? DraftSessionId { get { lock (_gate) return _draftSessionId; } }

    public ulong BeginDraft(long sessionId, byte[] key)
    {
        if (key is null || key.Length != 32)
            throw new ArgumentException("A draft key must contain a 32-byte SHA-256 digest.", nameof(key));
        lock (_gate)
        {
            ulong next = checked(_generation + 1);
            byte[] copiedKey = key.ToArray();
            ClearDraftLocked();
            _generation = next;
            _draftSessionId = sessionId;
            _draftKey = copiedKey;
            return next;
        }
    }

    public bool CompleteDraft(ulong generation, byte[] key, byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        lock (_gate)
        {
            if (generation != _generation || _draftKey is null || key is null
                || !_draftKey.AsSpan().SequenceEqual(key) || bytes.Length > _maxBytes)
                return false;
            byte[] copiedBytes = bytes.ToArray();
            _retainedBytes -= _draftBytes?.Length ?? 0;
            _draftBytes = copiedBytes;
            _retainedBytes += copiedBytes.Length;
            EvictToByteLimitLocked();
            return true;
        }
    }

    public byte[]? Draft(byte[] key)
    {
        lock (_gate)
            return key is not null && _draftKey is not null && _draftKey.AsSpan().SequenceEqual(key)
                ? _draftBytes?.ToArray() : null;
    }

    public void InvalidateDraft()
    {
        lock (_gate)
        {
            ulong next = checked(_generation + 1);
            ClearDraftLocked();
            _generation = next;
        }
    }

    /// <summary>Copies sent bytes into the shared preview budget.</summary>
    public bool Retain(byte[] bytes, long sessionId, long assistantId)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        lock (_gate)
        {
            if (bytes.Length > _maxBytes) return false;
            return RetainLocked(bytes.ToArray(), sessionId, assistantId);
        }
    }

    public byte[]? Sent(long sessionId, long assistantId)
    {
        lock (_gate)
            return _entries.FirstOrDefault(e => e.SessionId == sessionId && e.AssistantId == assistantId)?.Bytes.ToArray();
    }

    /// <summary>Transfers a ready draft atomically, without charging its bytes twice.</summary>
    public bool PromoteDraft(long sessionId, long assistantId)
    {
        lock (_gate)
        {
            if (_draftSessionId != sessionId || _draftBytes is null) return false;
            ulong next = checked(_generation + 1);
            byte[] bytes = _draftBytes;
            ClearDraftLocked();
            _generation = next;
            return RetainLocked(bytes, sessionId, assistantId);
        }
    }

    public void Clear(long sessionId)
    {
        lock (_gate)
        {
            if (_draftSessionId == sessionId)
            {
                ulong next = checked(_generation + 1);
                ClearDraftLocked();
                _generation = next;
            }
            for (int index = _entries.Count - 1; index >= 0; index--)
                if (_entries[index].SessionId == sessionId) RemoveEntryLocked(index);
        }
    }

    private bool RetainLocked(byte[] bytes, long sessionId, long assistantId)
    {
        int replaced = _entries.FindIndex(e => e.SessionId == sessionId && e.AssistantId == assistantId);
        if (replaced >= 0) RemoveEntryLocked(replaced);
        _entries.Add(new(sessionId, assistantId, bytes));
        _retainedBytes += bytes.Length;
        while (_entries.Count(e => e.SessionId == sessionId) > _maxTurns)
            RemoveEntryLocked(_entries.FindIndex(e => e.SessionId == sessionId));
        EvictToByteLimitLocked();
        return _entries.Any(e => e.SessionId == sessionId && e.AssistantId == assistantId);
    }

    private void ClearDraftLocked()
    {
        _retainedBytes -= _draftBytes?.Length ?? 0;
        _draftBytes = null;
        _draftKey = null;
        _draftSessionId = null;
    }

    private void RemoveEntryLocked(int index)
    {
        _retainedBytes -= _entries[index].Bytes.Length;
        _entries.RemoveAt(index);
    }

    private void EvictToByteLimitLocked()
    {
        while (_retainedBytes > _maxBytes && _entries.Count > 0) RemoveEntryLocked(0);
    }
}
