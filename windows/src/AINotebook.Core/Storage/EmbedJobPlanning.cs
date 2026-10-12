using AINotebook.Core.Ingestion;

namespace AINotebook.Core.Storage;

/// <summary>The durable <c>{selection, copyExisting}</c> options of an embed job.</summary>
internal sealed record EmbedJobOptions(EmbeddingSelection Selection, bool CopyExisting)
{
    /// <summary>Null when the options do not decode.</summary>
    public static EmbedJobOptions? Parse(string json) =>
        IngestionGenerationSQL.ReadOptions(json) is { } options ? new EmbedJobOptions(options.Selection, options.CopyExisting) : null;
}

/// <summary>One embed job row as the planners see it.</summary>
internal sealed record EmbedJobSnapshot(long Id, string Target, string State, int Attempts, long? NextRetryAt, string? Error,
    EmbedJobOptions? Options)
{
    public bool IsBootstrap => Target.StartsWith("notebook:", StringComparison.Ordinal);

    /// <summary>queued|running|paused, or failed with an automatic retry pending.</summary>
    public bool IsUnfinished => State switch
    {
        "queued" or "running" or "paused" => true,
        "failed" => Attempts < 5 && NextRetryAt is not null,
        _ => false
    };

    /// <summary>A notebook-target job nobody owns that would still run (<c>ingestion-build-merge-v1</c> §1).</summary>
    public bool IsUnclaimedBootstrap => IsBootstrap && State != "running" && IsUnfinished;

    /// <summary>The selection of a copy-existing (incremental) bootstrap.</summary>
    public EmbeddingSelection? IncrementalSelection => Options is { CopyExisting: true } options ? options.Selection : null;
}

/// <summary>One generation of the notebook as the planners see it.</summary>
internal sealed record GenerationSnapshot(long Id, string State, GenerationIdentity Identity);

/// <summary>The embed job behind the status and the generation behind its chunk counts.</summary>
internal sealed record StatusEmbedJob(EmbedJobSnapshot Job, bool Bootstrap, long? ProgressGenerationId);

internal enum BootstrapStartupAction { Keep, Merge, Noop }

/// <summary>Pure decisions of <c>indexing-status-v1</c> §8 and <c>ingestion-build-merge-v1</c>.</summary>
internal static class EmbedJobPlanning
{
    /// <summary>Same vector space: every field equal; an unknown selection dimension matches any.</summary>
    public static bool Compatible(EmbeddingSelection selection, GenerationIdentity identity) =>
        IngestionGenerationSQL.SameSpace(selection, ToSelection(identity));

    public static EmbeddingSelection ToSelection(GenerationIdentity identity) => new(identity.ProviderId, identity.EndpointRevision,
        identity.Model, identity.ModelDigest, identity.Dims, identity.Normalization, identity.QueryFormatVersion,
        identity.DocFormatVersion, identity.ChunkerVersion);

    /// <summary>
    /// <c>indexing-status-v1</c> §8: running first, then any other unfinished job, then finished ones, the highest id
    /// within a class; a copy-existing bootstrap of a building space reports that generation.
    /// </summary>
    public static StatusEmbedJob? StatusJob(IReadOnlyList<EmbedJobSnapshot> jobs, IReadOnlyList<GenerationSnapshot> generations)
    {
        static int Rank(EmbedJobSnapshot job) => job.State == "running" ? 0 : job.IsUnfinished ? 1 : 2;
        var pick = jobs.OrderBy(Rank).ThenByDescending(j => j.Id).FirstOrDefault();
        if (pick is null) return null;
        if (GenerationTarget(pick.Target) is long generationId) return new StatusEmbedJob(pick, false, generationId);
        if (pick.IncrementalSelection is { } selection)
        {
            long? building = generations.Where(g => g.State == "building" && Compatible(selection, g.Identity))
                .Select(g => (long?)g.Id).Max();
            if (building is not null) return new StatusEmbedJob(pick, false, building);
        }
        return new StatusEmbedJob(pick, pick.IsBootstrap, null);
    }

    /// <summary>The generation whose verified identity a build request adopts (<c>ingestion-build-merge-v1</c> §2).</summary>
    public static GenerationSnapshot? ResolveBuild(EmbeddingSelection selection, bool copyExisting,
        IReadOnlyList<GenerationSnapshot> generations)
    {
        if (selection.Dims is > 0 || !copyExisting) return null;
        foreach (string state in new[] { "building", "active" })
        {
            var match = generations.Where(g => g.State == state && Compatible(selection, g.Identity)).MaxBy(g => g.Id);
            if (match is not null) return match;
        }
        return null;
    }

    /// <summary>Unclaimed incremental bootstraps the generation job of <paramref name="identity"/> covers, in id order (§3).</summary>
    public static IReadOnlyList<long> Superseded(GenerationIdentity identity, IReadOnlyList<EmbedJobSnapshot> jobs) =>
        jobs.Where(j => j.IsUnclaimedBootstrap && j.IncrementalSelection is { } selection && Compatible(selection, identity))
            .Select(j => j.Id).Order().ToArray();

    /// <summary>What runtime start does with one existing bootstrap (§4).</summary>
    public static BootstrapStartupAction Startup(EmbedJobSnapshot job, IReadOnlyList<GenerationSnapshot> generations, bool needsEmbedding)
    {
        if (!job.IsUnclaimedBootstrap || job.IncrementalSelection is not { } selection) return BootstrapStartupAction.Keep;
        var resolved = ResolveBuild(selection, copyExisting: true, generations);
        if (resolved is null) return BootstrapStartupAction.Keep;
        return resolved.State == "building" || needsEmbedding ? BootstrapStartupAction.Merge : BootstrapStartupAction.Noop;
    }

    public static long? GenerationTarget(string target) =>
        target.StartsWith("generation:", StringComparison.Ordinal) && long.TryParse(target.AsSpan("generation:".Length),
            System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out long id) ? id : null;
}
