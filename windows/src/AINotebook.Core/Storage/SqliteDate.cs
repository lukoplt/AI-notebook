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
    /// form, but we accept it for robustness).</summary>
    public static DateTime FromDb(string text)
    {
        // Numeric unix-epoch fallback: only when the value has no date/time
        // separators (so a real "yyyy-MM-dd HH:mm:ss.fff" string never matches).
        if (double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var epoch)
            && !text.Contains('-') && !text.Contains(':'))
        {
            return DateTimeOffset.FromUnixTimeMilliseconds((long)(epoch * 1000)).UtcDateTime;
        }
        var parsed = DateTime.ParseExact(
            text,
            Format,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);
        return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
    }
}
