using System.Globalization;
using System.Text;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Compact spreadsheet canonical text, <c>text_format_version</c> 2 (contract <c>ingestion-xlsx-v2</c>, same rules as
/// macOS <c>SpreadsheetText</c>). Pure, locale-independent string arithmetic: no binary floating point, no formatters.
/// </summary>
internal static class SpreadsheetText
{
    /// <summary><c>source_revisions.text_format_version</c> of every XLSX revision rendered by these rules.</summary>
    public const int FormatVersion = 2;
    public const int SignificantDigits = 15;
    public const string CellSeparator = " | ";

    // §3 values

    /// <summary>Every maximal run of TAB/LF/CR/SPACE becomes one SPACE; SPACE is trimmed at both ends.</summary>
    public static string Normalize(string text)
    {
        var output = new StringBuilder(text.Length);
        bool pending = false;
        foreach (char value in text)
        {
            if (IsAsciiWhitespace(value)) { pending = true; continue; }
            if (pending && output.Length != 0) output.Append(' ');
            pending = false;
            output.Append(value);
        }
        return output.ToString();
    }

    /// <summary>The column name of a 1-based column (1 → A, 27 → AA).</summary>
    public static string ColumnName(int column)
    {
        var output = new StringBuilder();
        while (column > 0)
        {
            output.Insert(0, (char)('A' + (column - 1) % 26));
            column = (column - 1) / 26;
        }
        return output.ToString();
    }

    // §4 numbers

    /// <summary>value = 0.Digits × 10^Exponent; Digits are ASCII, no leading/trailing zero, at most 15.
    /// <c>Digits</c> empty means zero.</summary>
    public readonly record struct Decimal(bool Negative, string Digits, int Exponent)
    {
        public bool IsZero => Digits.Length == 0;
    }

    /// <summary>Null: not a numeric lexeme, or outside the representable exponent range.</summary>
    public static Decimal? Parse(string raw)
    {
        int start = 0, end = raw.Length;
        while (start < end && IsAsciiWhitespace(raw[start])) start++;
        while (end > start && IsAsciiWhitespace(raw[end - 1])) end--;
        int index = start;
        bool negative = false;
        if (index < end && raw[index] is '+' or '-') negative = raw[index++] == '-';
        var digits = new StringBuilder();
        int integerDigits = 0;
        while (index < end && IsDigit(raw[index])) { digits.Append(raw[index++]); integerDigits++; }
        if (index < end && raw[index] == '.')
        {
            index++;
            while (index < end && IsDigit(raw[index])) digits.Append(raw[index++]);
        }
        if (digits.Length == 0) return null;
        int exponent = 0;
        if (index < end && raw[index] is 'e' or 'E')
        {
            index++;
            int sign = 1;
            if (index < end && raw[index] is '+' or '-') sign = raw[index++] == '-' ? -1 : 1;
            int exponentStart = index;
            while (index < end && IsDigit(raw[index])) index++;
            if (exponentStart == index) return null;
            int significant = exponentStart;
            while (significant < index && raw[significant] == '0') significant++;
            if (index - significant > 5) return null;
            for (int position = significant; position < index; position++) exponent = exponent * 10 + (raw[position] - '0');
            exponent *= sign;
        }
        if (index != end) return null;
        string mantissa = digits.ToString();
        int leading = 0;
        while (leading < mantissa.Length && mantissa[leading] == '0') leading++;
        int n = integerDigits - leading;
        string significantDigits = mantissa[leading..].TrimEnd('0');
        if (significantDigits.Length == 0) return new Decimal(false, "", 0);
        n += exponent;
        if (significantDigits.Length > SignificantDigits)
        {
            bool roundUp = significantDigits[SignificantDigits] >= '5';
            char[] kept = significantDigits[..SignificantDigits].ToCharArray();
            if (roundUp)
            {
                int position = kept.Length - 1;
                while (position >= 0 && kept[position] == '9') kept[position--] = '0';
                if (position < 0)
                {
                    kept = ("1" + new string(kept))[..SignificantDigits].ToCharArray();
                    n++;
                }
                else kept[position]++;
            }
            significantDigits = new string(kept).TrimEnd('0');
        }
        if (n is < -400 or > 400) return null;
        return new Decimal(negative, significantDigits, n);
    }

    /// <summary>The compact decimal text (ECMAScript Number::toString layout, uppercase E), or null.</summary>
    public static string? Number(string raw)
    {
        if (Parse(raw) is not { } parsed) return null;
        if (parsed.IsZero) return "0";
        string d = parsed.Digits;
        int k = d.Length, n = parsed.Exponent;
        string body;
        if (k <= n && n <= 21) body = d + new string('0', n - k);
        else if (0 < n && n <= 21) body = d[..n] + "." + d[n..];
        else if (-6 < n && n <= 0) body = "0." + new string('0', -n) + d;
        else
        {
            int e = n - 1;
            body = (k > 1 ? d[..1] + "." + d[1..] : d) + "E" + (e >= 0 ? "+" : "-") +
                Math.Abs(e).ToString(CultureInfo.InvariantCulture);
        }
        return (parsed.Negative ? "-" : "") + body;
    }

    // §5 dates

    /// <summary>ISO date/time of a positive serial in the workbook's date system, or null (render as a number).</summary>
    public static string? Date(string raw, bool date1904)
    {
        if (Parse(raw) is not { } parsed || parsed.IsZero || parsed.Negative || parsed.Exponent > 7) return null;
        string d = parsed.Digits;
        int n = parsed.Exponent;
        long integer;
        string fraction;
        if (n <= 0)
        {
            integer = 0;
            fraction = new string('0', -n) + d;
        }
        else
        {
            string padded = d.Length >= n ? d : d + new string('0', n - d.Length);
            integer = long.Parse(padded[..n], NumberStyles.None, CultureInfo.InvariantCulture);
            fraction = padded[n..];
        }
        if (integer > 3_000_000) return null;
        long seconds = 0;
        if (fraction.Length != 0 && n > -6)
        {
            long f = 0;
            foreach (char digit in fraction) f = f * 10 + (digit - '0');
            int m = fraction.Length;
            long numerator, denominator;
            if (m == 1) (numerator, denominator) = (f * 86_400, 10);
            else
            {
                numerator = f * 864;
                denominator = 1;
                for (int i = 0; i < m - 2; i++) denominator *= 10;
            }
            seconds = numerator / denominator + (2 * (numerator % denominator) >= denominator ? 1 : 0);
        }
        long total = integer * 86_400 + seconds;
        long day = total / 86_400, secondOfDay = total % 86_400;
        long hours = secondOfDay / 3600, minutes = secondOfDay % 3600 / 60, rest = secondOfDay % 60;
        string clock = Pad(hours, 2) + ":" + Pad(minutes, 2) + (rest > 0 ? ":" + Pad(rest, 2) : "");
        if (day == 0) return clock;
        (long Year, long Month, long Day) civil;
        if (date1904) civil = CivilFromDays(DaysFromCivil(1904, 1, 1) + day);
        else if (day < 60) civil = CivilFromDays(DaysFromCivil(1899, 12, 31) + day);
        else if (day == 60) civil = (1900, 2, 29);
        else civil = CivilFromDays(DaysFromCivil(1899, 12, 30) + day);
        if (civil.Year > 9999) return null;
        string text = Pad(civil.Year, 4) + "-" + Pad(civil.Month, 2) + "-" + Pad(civil.Day, 2);
        return secondOfDay > 0 ? text + " " + clock : text;
    }

    /// <summary>Days since 1970-01-01 (proleptic Gregorian; H. Hinnant's integer algorithm).</summary>
    public static long DaysFromCivil(long year, long month, long day)
    {
        long y = month <= 2 ? year - 1 : year;
        long era = (y >= 0 ? y : y - 399) / 400;
        long yoe = y - era * 400;
        long doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1;
        long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    public static (long Year, long Month, long Day) CivilFromDays(long days)
    {
        long z = days + 719_468;
        long era = (z >= 0 ? z : z - 146_096) / 146_097;
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        long day = doy - (153 * mp + 2) / 5 + 1;
        long month = mp + (mp < 10 ? 3 : -9);
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day);
    }

    // §6 number formats

    public static bool IsBuiltInDate(int id) => id is >= 14 and <= 22 or >= 27 and <= 36 or
        >= 45 and <= 47 or >= 50 and <= 58;

    /// <summary>Ignores quoted/escaped literals and color/condition brackets; a bracket holding one repeated h, m or
    /// s (elapsed time) is a date/time token. Scientific E is deliberately not a date token.</summary>
    public static bool IsDateFormat(string code)
    {
        for (int index = 0; index < code.Length; index++)
        {
            char value = code[index];
            if (value == '"')
            {
                while (++index < code.Length && code[index] != '"') { }
            }
            else if (value is '\\' or '_' or '*') index++;
            else if (value == '[')
            {
                int end = code.IndexOf(']', index + 1);
                if (end < 0) return false;
                var content = code.AsSpan(index + 1, end - index - 1);
                if (content.Length > 0 && (content.IndexOfAnyExcept('h', 'H') < 0 ||
                    content.IndexOfAnyExcept('m', 'M') < 0 || content.IndexOfAnyExcept('s', 'S') < 0)) return true;
                index = end;
            }
            else if (value is 'y' or 'Y' or 'm' or 'M' or 'd' or 'D' or 'h' or 'H' or 's' or 'S') return true;
        }
        return false;
    }

    // §2 rows

    /// <summary>One rendered, non-empty cell value.</summary>
    public readonly record struct RenderedCell(int Row, int Column, string Text);

    /// <summary>Appends the row lines of one sheet (cells sorted by row, then column): <c>R&lt;row&gt;: v1 | v2 |
    /// &lt;COL&gt;=v3</c>, where a column that does not directly follow the previous rendered cell of the row (or
    /// column A for the first one) is prefixed with its name.</summary>
    public static void AppendRows(IEnumerable<RenderedCell> cells, ScalarTextBuilder output)
    {
        int currentRow = -1, previousColumn = 0;
        foreach (var cell in cells)
        {
            if (currentRow != cell.Row)
            {
                if (currentRow != -1) output.Append("\n");
                output.Append("R");
                output.Append(cell.Row.ToString(CultureInfo.InvariantCulture));
                output.Append(": ");
                currentRow = cell.Row;
                previousColumn = 0;
            }
            else output.Append(CellSeparator);
            if (cell.Column != previousColumn + 1)
            {
                output.Append(ColumnName(cell.Column));
                output.Append("=");
            }
            output.Append(cell.Text);
            previousColumn = cell.Column;
        }
    }

    private static bool IsAsciiWhitespace(char value) => value is '\t' or '\n' or '\r' or ' ';
    private static bool IsDigit(char value) => value is >= '0' and <= '9';
    private static string Pad(long value, int width) =>
        value.ToString(CultureInfo.InvariantCulture).PadLeft(width, '0');
}
