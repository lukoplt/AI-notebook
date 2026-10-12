using System.Text.Json.Serialization;

namespace AINotebook.Core.Language;

/// <summary>Only short, completed detections may inherit a confident document language.</summary>
public sealed record ChunkLanguage(
    [property: JsonPropertyName("lang"), JsonIgnore(Condition = JsonIgnoreCondition.Never)] string? Lang,
    [property: JsonPropertyName("langInherited")] bool LangInherited)
{
    public static ChunkLanguage Resolve(string? label, string? reason, string? documentLabel)
    {
        if (label is null) return new(null, false);
        if (label == "und" && reason is "minLetters" or "minWords" && documentLabel is "cs" or "de" or "en" or "sk")
            return new(documentLabel, true);
        return new(label, false);
    }
}
