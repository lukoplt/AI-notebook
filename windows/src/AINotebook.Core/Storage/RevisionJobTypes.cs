namespace AINotebook.Core.Storage;

public sealed record RevisionDraft(string ContentHash, string CanonicalText, int TextFormatVersion, int ChunkerVersion);

public sealed record SourceRevision(long Id, long SourceId, int Revision, RevisionDraft Draft, long CreatedAt);

public sealed record RevisionChunkDraft(string Text, int TokenCount, int? PageHint,
    int? CharStart, int? CharEnd, string? Lang, bool LangInherited);

public sealed record JobFence(long JobId, string LeaseToken);

/// <summary>Options contain only nonsecret scheduling/embedding selection data; frozen after the first claim.</summary>
public sealed record IngestJobDraft(string Kind, string Target, long? TargetRevision, string OptionsJson = "{}");

public sealed record IngestJob(long Id, IngestJobDraft Draft, int Attempts, long? NextRetryAt,
    string State, long? LeaseUntil, string? LeaseToken, string? Error);

public interface IIngestLeaseClock
{
    long Now { get; }
    Task WaitUntilAsync(long deadline, CancellationToken ct);
}

public sealed class SystemIngestLeaseClock : IIngestLeaseClock
{
    public long Now => DateTimeOffset.UtcNow.ToUnixTimeSeconds();

    public async Task WaitUntilAsync(long deadline, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        while (deadline > Now)
        {
            // Recheck the wall clock after each bounded delay, including clock adjustments.
            long remaining = deadline - Now;
            if (remaining > 0)
                await Task.Delay(TimeSpan.FromSeconds(Math.Min(remaining, 86_400)), ct).ConfigureAwait(false);
        }
    }
}
