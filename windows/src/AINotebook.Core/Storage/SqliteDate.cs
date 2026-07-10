using System.Globalization;

namespace AINotebook.Core.Storage;

/// <summary>
/// Date storage format used by the SQLite schema, ported 1:1 from GRDB's
/// DateFormatter (dateFormat "yyyy-MM-dd HH:mm:ss.SSS", locale en_US_POSIX,
/// timeZone GMT). Always 3 millisecond digits; values are written and read as UTC.
/// </summary>
public static class SqliteDate
{
    public const string Format = "yyyy-MM-dd HH:mm:ss.fff";

    // Legacy no-milliseconds shape: the v11 migration's data step used to
    // seed the built-in Ollama provider's created_at via
    // DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") instead of ToDb(...),
    // so every DB migrated before that fix (and the v17 repair migration)
    // carries a row in this shape. Tolerated here as defense-in-depth on top
    // of the v11 seed fix and the v17 repair.
    private const string NoMillisecondsFormat = "yyyy-MM-dd HH:mm:ss";

    /// <summary>Serialize a DateTime to the TEXT form, normalized to UTC.</summary>
    public static string ToDb(DateTime value)
    {
        // Unspecified is treated as already-UTC; Local is converted; Utc stays.
        DateTime utc = value.Kind switch
        {
            DateTimeKind.Utc => value,
            DateTimeKind.Local => value.ToUniversalTime(),
            _ => DateTime.SpecifyKind(value, DateTimeKind.Utc)
        };
        return utc.ToString(Format, CultureInfo.InvariantCulture);
    }

    /// <summary>Parse the TEXT form back into a UTC DateTime. Also tolerates a
    /// numeric unix epoch (GRDB's decoder accepts it; the app never wrote that
    /// form, but we accept it for robustness), and a legacy no-milliseconds
    /// "yyyy-MM-dd HH:mm:ss" shape (defense-in-depth: the v11 migration's data
    /// step used to write this via a raw ToString instead of ToDb(...); the
    /// seed is fixed and a v17 migration repairs existing rows, but this
    /// fallback keeps FromDb robust against any row that reaches it
    /// unrepaired).</summary>
    public static DateTime FromDb(string text)
    {
        // Numeric unix-epoch fallback: only when the value has no date/time
        // separators (so a real "yyyy-MM-dd HH:mm:ss.fff" string never matches).
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var epoch)
            && !text.Contains('-') && !text.Contains(':'))
        {
            return DateTimeOffset.FromUnixTimeMilliseconds((long)(epoch * 1000)).UtcDateTime;
        }
        if (DateTime.TryParseExact(
                text,
                Format,
                CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal,
                out var parsed))
        {
            return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
        }
        // Strict format failed: fall back to the legacy no-milliseconds shape.
        // Let a genuine format failure throw from this ParseExact call (not
        // the first) so callers see the standard FormatException.
        parsed = DateTime.ParseExact(
            text,
            NoMillisecondsFormat,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
        return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
    }
}
