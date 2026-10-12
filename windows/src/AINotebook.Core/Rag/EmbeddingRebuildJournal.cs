using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core.Rag;

public sealed record EmbeddingRebuildTarget(
    [property: JsonPropertyName("notebookId")] long NotebookId,
    [property: JsonPropertyName("generationId")] long GenerationId);

public sealed record EmbeddingRebuildRecord(
    [property: JsonPropertyName("version")] int Version,
    [property: JsonPropertyName("previous")] EmbeddingModelChoice Previous,
    [property: JsonPropertyName("requested")] EmbeddingModelChoice Requested,
    [property: JsonPropertyName("targets")] IReadOnlyList<EmbeddingRebuildTarget> Targets);

/// <summary>
/// Local recovery record beside db.sqlite (<c>embedding-rebuild-v1.json</c>), written before activation.
/// It holds selections and generation IDs only: no roots, secrets or source text.
/// </summary>
public sealed class EmbeddingRebuildJournal(string path)
{
    public const string FileName = "embedding-rebuild-v1.json";

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
    };

    public string Path { get; } = path ?? throw new ArgumentNullException(nameof(path));

    public EmbeddingRebuildRecord? Read()
    {
        byte[] bytes;
        try { bytes = File.ReadAllBytes(Path); }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        EmbeddingRebuildRecord? record;
        try { record = JsonSerializer.Deserialize<EmbeddingRebuildRecord>(bytes, Json); }
        catch (JsonException) { throw new EmbeddingRecommendationException("invalidJournal"); }
        Validate(record);
        return record;
    }

    /// <summary>Atomic replace: unique same-directory temp file, flushed to disk, then moved over the journal.</summary>
    public void Write(EmbeddingRebuildRecord record)
    {
        Validate(record);
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(record, Json);
        string directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(Path))!;
        Directory.CreateDirectory(directory);
        string temp = System.IO.Path.Combine(directory, "." + FileName + "." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temp, Path, overwrite: true);
        }
        catch
        {
            try { File.Delete(temp); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            throw;
        }
    }

    /// <summary>Removes the journal; only an absent file is ignored.</summary>
    public void Clear()
    {
        try { File.Delete(Path); }
        catch (DirectoryNotFoundException) { }
    }

    private static void Validate(EmbeddingRebuildRecord? record)
    {
        if (record is null || record.Version != 1 || record.Targets is null || !ValidSelection(record.Previous)
            || !ValidSelection(record.Requested) || record.Requested.ProfileId is null
            || record.Targets.Any(t => t is null || t.NotebookId <= 0 || t.GenerationId <= 0)
            || record.Targets.Select(t => t.NotebookId).Distinct().Count() != record.Targets.Count
            || record.Targets.Select(t => t.GenerationId).Distinct().Count() != record.Targets.Count)
            throw new EmbeddingRecommendationException("invalidJournal");
    }

    private static bool ValidSelection(EmbeddingModelChoice? s)
    {
        if (s is null || string.IsNullOrEmpty(s.ProviderId) || string.IsNullOrEmpty(s.Model)) return false;
        if (s.ProfileId is null) return true;
        try { return EmbeddingProfiles.Require(s.ProfileId).Model == s.Model; }
        catch (EmbeddingProfileException) { return false; }
    }
}
