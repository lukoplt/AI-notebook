using System.Text;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Text primitives of the bounded e-mail readers (contract ingestion-mail-v1, reference
/// tools/contracts/gen_mail_fixtures.py, same rules as macOS MailText). Text is processed as Unicode
/// scalar values (int code points), never UTF-16 units. Decoding never fails: unknown or invalid
/// input degrades to a fallback single-byte codec or U+FFFD.
/// </summary>
internal static class MailText
{
    internal static bool IsWhite(int value) => value is >= 9 and <= 13 or 0x20 or 0x85 or 0xA0 or 0x1680
        or 0x2028 or 0x2029 or 0x202F or 0x205F or 0x3000 or >= 0x2000 and <= 0x200A;

    internal static List<int> Scalars(string text)
    {
        var result = new List<int>(text.Length);
        foreach (var rune in text.EnumerateRunes()) result.Add(rune.Value);
        return result;
    }

    internal static string FromScalars(IEnumerable<int> scalars)
    {
        var builder = new StringBuilder();
        foreach (int value in scalars) builder.Append(new Rune(value).ToString());
        return builder.ToString();
    }

    private static string Slice(IReadOnlyList<int> scalars, int start, int end)
    {
        var builder = new StringBuilder();
        for (int i = start; i < end; i++) builder.Append(new Rune(scalars[i]).ToString());
        return builder.ToString();
    }

    /// <summary>Whitespace runs become one U+0020; leading/trailing whitespace is removed.</summary>
    internal static string Collapse(string text)
    {
        var builder = new StringBuilder(text.Length);
        bool pending = false;
        foreach (var rune in text.EnumerateRunes())
        {
            if (IsWhite(rune.Value))
            {
                pending = builder.Length > 0;
                continue;
            }
            if (pending)
            {
                builder.Append(' ');
                pending = false;
            }
            builder.Append(rune.ToString());
        }
        return builder.ToString();
    }

    internal static string Trim(string text)
    {
        var scalars = Scalars(text);
        int lo = 0, hi = scalars.Count;
        while (lo < hi && IsWhite(scalars[lo])) lo++;
        while (hi > lo && IsWhite(scalars[hi - 1])) hi--;
        return lo == 0 && hi == scalars.Count ? text : Slice(scalars, lo, hi);
    }

    /// <summary>CRLF and lone CR become LF.</summary>
    internal static string NormalizeNewlines(string text) => text.Replace("\r\n", "\n").Replace('\r', '\n');

    internal static string AsciiLower(string text)
    {
        var chars = text.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
            if (chars[i] is >= 'A' and <= 'Z') chars[i] = (char)(chars[i] + 32);
        return new string(chars);
    }

    internal static string AsciiUpper(string text)
    {
        var chars = text.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
            if (chars[i] is >= 'a' and <= 'z') chars[i] = (char)(chars[i] - 32);
        return new string(chars);
    }

    // ---- Charsets ----------------------------------------------------------------------------

    private static readonly Dictionary<string, string> Labels = new(StringComparer.Ordinal)
    {
        ["utf-8"] = "utf-8", ["utf8"] = "utf-8", ["us-ascii"] = "utf-8", ["ascii"] = "utf-8", ["ansi_x3.4-1968"] = "utf-8",
        ["iso-8859-1"] = "windows-1252", ["iso8859-1"] = "windows-1252", ["latin1"] = "windows-1252", ["l1"] = "windows-1252",
        ["windows-1252"] = "windows-1252", ["cp1252"] = "windows-1252",
        ["iso-8859-2"] = "iso-8859-2", ["iso8859-2"] = "iso-8859-2", ["latin2"] = "iso-8859-2", ["l2"] = "iso-8859-2",
        ["windows-1250"] = "windows-1250", ["cp1250"] = "windows-1250", ["x-cp1250"] = "windows-1250",
    };

    /// <summary>MAPI code page to codec.</summary>
    internal static string CodecForCodePage(uint codePage) => codePage switch
    {
        1250 => "windows-1250",
        1252 or 28591 => "windows-1252",
        28592 => "iso-8859-2",
        65001 or 20127 => "utf-8",
        _ => "auto"
    };

    /// <summary>ASCII-lowercased label without surrounding whitespace/quotes to codec, else "auto".</summary>
    internal static string CodecForLabel(string label)
    {
        var value = AsciiLower(label).Trim(' ', '\t', '\r', '\n', '"', '\'');
        return Labels.TryGetValue(value, out var codec) ? codec : "auto";
    }

    /// <summary>codec: utf-8, windows-1250, windows-1252, iso-8859-2 or auto. Invalid UTF-8 falls back
    /// to windows-1250 (folder fallback cp1250) or windows-1252.</summary>
    internal static string Decode(ReadOnlySpan<byte> bytes, string codec, string fallback)
    {
        var table = Table(codec);
        if (table is not null) return SingleByte(bytes, table);
        return StrictUtf8(bytes) ?? SingleByte(bytes, fallback == "cp1250" ? Windows1250 : Windows1252);
    }

    private static ushort[]? Table(string codec) => codec switch
    {
        "windows-1250" => Windows1250,
        "windows-1252" => Windows1252,
        "iso-8859-2" => Iso88592,
        _ => null
    };

    private static string SingleByte(ReadOnlySpan<byte> bytes, ushort[] table)
    {
        var chars = new char[bytes.Length];
        for (int i = 0; i < bytes.Length; i++) chars[i] = bytes[i] < 0x80 ? (char)bytes[i] : (char)table[bytes[i] - 0x80];
        return new string(chars);
    }

    /// <summary>Same strict rules as TextDecoding: no overlongs, surrogates or values above U+10FFFF.</summary>
    internal static string? StrictUtf8(ReadOnlySpan<byte> bytes)
    {
        var builder = new StringBuilder(bytes.Length);
        int i = 0, n = bytes.Length;
        while (i < n)
        {
            byte first = bytes[i];
            if (first < 0x80)
            {
                builder.Append((char)first);
                i++;
                continue;
            }
            int length;
            int value;
            if (first is >= 0xC2 and <= 0xDF) { length = 2; value = first & 0x1F; }
            else if (first is >= 0xE0 and <= 0xEF) { length = 3; value = first & 0x0F; }
            else if (first is >= 0xF0 and <= 0xF4) { length = 4; value = first & 0x07; }
            else return null;
            if (i + length > n) return null;
            for (int k = 1; k < length; k++)
            {
                byte next = bytes[i + k];
                if (next is < 0x80 or > 0xBF) return null;
                value = value << 6 | (next & 0x3F);
            }
            int minimum = length switch { 2 => 0x80, 3 => 0x800, _ => 0x10000 };
            if (value < minimum || value > 0x10FFFF || value is >= 0xD800 and <= 0xDFFF) return null;
            builder.Append(new Rune(value).ToString());
            i += length;
        }
        return builder.ToString();
    }

    /// <summary>UTF-16LE; unpaired surrogates and an odd trailing byte become U+FFFD.</summary>
    internal static string Utf16Le(ReadOnlySpan<byte> bytes)
    {
        var builder = new StringBuilder(bytes.Length / 2 + 1);
        int n = bytes.Length - bytes.Length % 2, i = 0;
        while (i < n)
        {
            int unit = bytes[i] | bytes[i + 1] << 8;
            i += 2;
            if (unit is >= 0xD800 and <= 0xDBFF && i < n)
            {
                int low = bytes[i] | bytes[i + 1] << 8;
                if (low is >= 0xDC00 and <= 0xDFFF)
                {
                    builder.Append((char)unit).Append((char)low);
                    i += 2;
                    continue;
                }
            }
            builder.Append(unit is >= 0xD800 and <= 0xDFFF ? '�' : (char)unit);
        }
        if (bytes.Length % 2 == 1) builder.Append('�');
        return builder.ToString();
    }

    // ---- Transfer encodings ------------------------------------------------------------------

    internal static int Base64Value(int c) => c switch
    {
        >= 'A' and <= 'Z' => c - 'A',
        >= 'a' and <= 'z' => c - 'a' + 26,
        >= '0' and <= '9' => c - '0' + 52,
        '+' => 62,
        '/' => 63,
        _ => -1
    };

    internal static int HexValue(int c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'A' and <= 'F' => c - 'A' + 10,
        >= 'a' and <= 'f' => c - 'a' + 10,
        _ => -1
    };

    /// <summary>Every non-alphabet byte (whitespace, '=', junk) is ignored; a trailing single sextet is dropped.</summary>
    internal static byte[] Base64Lenient(ReadOnlySpan<byte> data)
    {
        var output = new List<byte>(data.Length / 4 * 3 + 2);
        int buffer = 0, count = 0;
        foreach (byte b in data)
        {
            int value = Base64Value(b);
            if (value < 0) continue;
            buffer = buffer << 6 | value;
            if (++count == 4)
            {
                output.Add((byte)(buffer >> 16));
                output.Add((byte)(buffer >> 8));
                output.Add((byte)buffer);
                buffer = 0;
                count = 0;
            }
        }
        if (count == 2) output.Add((byte)(buffer >> 4));
        else if (count == 3)
        {
            output.Add((byte)(buffer >> 10));
            output.Add((byte)(buffer >> 2));
        }
        return output.ToArray();
    }

    internal static byte[] QuotedPrintable(ReadOnlySpan<byte> data)
    {
        var output = new List<byte>(data.Length);
        int i = 0, n = data.Length;
        while (i < n)
        {
            byte b = data[i];
            if (b != 0x3D)
            {
                output.Add(b);
                i++;
                continue;
            }
            int j = i + 1;
            while (j < n && (data[j] == 0x20 || data[j] == 0x09)) j++;
            if (j < n && data[j] == 0x0A) { i = j + 1; continue; }
            if (j + 1 < n && data[j] == 0x0D && data[j + 1] == 0x0A) { i = j + 2; continue; }
            if (j == n) { i = n; continue; }
            if (i + 2 < n && HexValue(data[i + 1]) >= 0 && HexValue(data[i + 2]) >= 0)
            {
                output.Add((byte)(HexValue(data[i + 1]) << 4 | HexValue(data[i + 2])));
                i += 3;
                continue;
            }
            output.Add(b);
            i++;
        }
        return output.ToArray();
    }

    // ---- RFC 2047 encoded words --------------------------------------------------------------

    private static (int End, string Label, byte[] Bytes)? EncodedWord(List<int> text, int i)
    {
        int n = text.Count;
        if (i + 1 >= n || text[i] != '=' || text[i + 1] != '?') return null;
        int j = i + 2, k = j;
        while (k < n && text[k] != '?' && !IsWhite(text[k])) k++;
        if (k == j || k >= n || text[k] != '?') return null;
        int labelEnd = j;
        while (labelEnd < k && text[labelEnd] != '*') labelEnd++;
        string label = AsciiLower(Slice(text, j, labelEnd));
        if (k + 2 >= n || text[k + 2] != '?' || text[k + 1] is not ('b' or 'B' or 'q' or 'Q')) return null;
        bool base64 = text[k + 1] is 'b' or 'B';
        int p = k + 3, q = p;
        while (q < n && text[q] != '?' && !IsWhite(text[q])) q++;
        if (q + 1 >= n || text[q] != '?' || text[q + 1] != '=') return null;
        var raw = new byte[q - p];
        for (int m = p; m < q; m++)
        {
            if (text[m] is < 0x21 or > 0x7E) return null;
            raw[m - p] = (byte)text[m];
        }
        byte[] data;
        if (base64)
        {
            int length = raw.Length;
            while (length > 0 && raw[length - 1] == 0x3D) length--;
            for (int m = 0; m < length; m++) if (Base64Value(raw[m]) < 0) return null;
            if (length % 4 == 1) return null;
            data = Base64Lenient(raw.AsSpan(0, length));
        }
        else
        {
            var output = new List<byte>(raw.Length);
            int m = 0;
            while (m < raw.Length)
            {
                byte c = raw[m];
                if (c == 0x5F) { output.Add(0x20); m++; }
                else if (c == 0x3D)
                {
                    if (m + 2 < raw.Length && HexValue(raw[m + 1]) >= 0 && HexValue(raw[m + 2]) >= 0)
                    {
                        output.Add((byte)(HexValue(raw[m + 1]) << 4 | HexValue(raw[m + 2])));
                        m += 3;
                    }
                    else return null;
                }
                else { output.Add(c); m++; }
            }
            data = output.ToArray();
        }
        return (q + 2, label, data);
    }

    /// <summary>Encoded words decoded; whitespace between adjacent words dropped; adjacent words with the
    /// same (lowercased) label concatenate bytes before decoding.</summary>
    internal static string DecodeWords(string value, string fallback)
    {
        var text = Scalars(value);
        var output = new StringBuilder(value.Length);
        string? pendingLabel = null;
        var pendingBytes = new List<byte>();
        int gapStart = 0, i = 0;
        void Flush() => output.Append(Decode(pendingBytes.ToArray(), CodecForLabel(pendingLabel!), fallback));
        while (i < text.Count)
        {
            if (text[i] == '=' && EncodedWord(text, i) is { } word)
            {
                if (pendingLabel is not null && pendingLabel == word.Label) pendingBytes.AddRange(word.Bytes);
                else
                {
                    if (pendingLabel is not null) Flush();
                    pendingLabel = word.Label;
                    pendingBytes = new List<byte>(word.Bytes);
                }
                i = gapStart = word.End;
                continue;
            }
            if (pendingLabel is not null && !IsWhite(text[i]))
            {
                Flush();
                output.Append(Slice(text, gapStart, i));
                pendingLabel = null;
            }
            if (pendingLabel is null) output.Append(new Rune(text[i]).ToString());
            i++;
        }
        if (pendingLabel is not null)
        {
            Flush();
            output.Append(Slice(text, gapStart, text.Count));
        }
        return output.ToString();
    }

    internal static string DecodeHeader(string value, string fallback) => Collapse(DecodeWords(value, fallback));

    // ---- Parameters (RFC 2045 / RFC 2231) ----------------------------------------------------

    /// <summary>"type/sub; a=b; c=\"q\\\"x\"" to (lowercased type, lowercased name to value; first wins).</summary>
    internal static (string Kind, Dictionary<string, string> Params) Parameters(string value)
    {
        var segments = new List<string>();
        var current = new StringBuilder();
        bool quoted = false, escape = false;
        foreach (char c in value)
        {
            if (escape) { current.Append(c); escape = false; }
            else if (quoted && c == '\\') { current.Append(c); escape = true; }
            else if (c == '"') { current.Append(c); quoted = !quoted; }
            else if (c == ';' && !quoted) { segments.Add(current.ToString()); current.Clear(); }
            else current.Append(c);
        }
        segments.Add(current.ToString());
        string kind = AsciiLower(Trim(segments[0]));
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var segment in segments.Skip(1))
        {
            int equals = segment.IndexOf('=');
            if (equals < 0) continue;
            string name = AsciiLower(Trim(segment[..equals]));
            string raw = Trim(segment[(equals + 1)..]);
            if (raw.Length >= 2 && raw[0] == '"' && raw[^1] == '"')
            {
                string inner = raw[1..^1];
                var unquoted = new StringBuilder(inner.Length);
                int k = 0;
                while (k < inner.Length)
                {
                    if (inner[k] == '\\' && k + 1 < inner.Length) { unquoted.Append(inner[k + 1]); k += 2; }
                    else { unquoted.Append(inner[k]); k++; }
                }
                raw = unquoted.ToString();
            }
            if (name.Length > 0) result.TryAdd(name, raw);
        }
        return (kind, result);
    }

    private static byte[] PercentDecoded(string text)
    {
        var raw = Encoding.UTF8.GetBytes(text);
        var output = new List<byte>(raw.Length);
        int k = 0;
        while (k < raw.Length)
        {
            if (raw[k] == 0x25 && k + 2 < raw.Length && HexValue(raw[k + 1]) >= 0 && HexValue(raw[k + 2]) >= 0)
            {
                output.Add((byte)(HexValue(raw[k + 1]) << 4 | HexValue(raw[k + 2])));
                k += 3;
            }
            else { output.Add(raw[k]); k++; }
        }
        return output.ToArray();
    }

    /// <summary>RFC 2231 extended value or numbered continuations (max 100), else the plain value
    /// (encoded words allowed).</summary>
    internal static string Parameter(Dictionary<string, string> parameters, string name, string fallback)
    {
        if (parameters.TryGetValue(name + "*", out var single)) return Collapse(Extended([(single, true)], fallback));
        var segments = new List<(string, bool)>();
        for (int index = 0; index < 100; index++)
        {
            if (parameters.TryGetValue($"{name}*{index}*", out var extended)) segments.Add((extended, true));
            else if (parameters.TryGetValue($"{name}*{index}", out var plain)) segments.Add((plain, false));
            else break;
        }
        if (segments.Count > 0) return Collapse(Extended(segments, fallback));
        return parameters.TryGetValue(name, out var value) ? DecodeHeader(value, fallback) : "";
    }

    private static string Extended(List<(string Value, bool IsExtended)> segments, string fallback)
    {
        string codec = "auto";
        var data = new List<byte>();
        for (int index = 0; index < segments.Count; index++)
        {
            var (value, isExtended) = segments[index];
            if (isExtended)
            {
                string payload = value;
                if (index == 0 && value.Count(c => c == '\'') >= 2)
                {
                    int first = value.IndexOf('\'');
                    int second = value.IndexOf('\'', first + 1);
                    codec = CodecForLabel(value[..first]);
                    payload = value[(second + 1)..];
                }
                data.AddRange(PercentDecoded(payload));
            }
            else data.AddRange(Encoding.UTF8.GetBytes(value));
        }
        return Decode(data.ToArray(), codec, fallback);
    }

    // ---- HTML to text ------------------------------------------------------------------------

    private static readonly HashSet<string> BlockElements = new(StringComparer.Ordinal)
    {
        "address", "article", "aside", "blockquote", "center", "dd", "div", "dl", "dt", "fieldset", "figure",
        "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li", "main", "nav", "ol", "p",
        "pre", "section", "table", "tr", "ul"
    };
    private static readonly HashSet<string> SkippedElements = new(StringComparer.Ordinal) { "head", "script", "style", "title" };
    private static readonly Dictionary<string, int> Entities = new(StringComparer.Ordinal)
    {
        ["amp"] = '&', ["lt"] = '<', ["gt"] = '>', ["quot"] = '"', ["apos"] = '\'', ["nbsp"] = 0xA0
    };

    private static bool IsLetter(int c) => c is >= 'A' and <= 'Z' or >= 'a' and <= 'z';
    private static bool IsAlnum(int c) => IsLetter(c) || c is >= '0' and <= '9';

    private static int Find(List<int> html, string needle, int start, bool foldCase = false)
    {
        if (start > html.Count || needle.Length > html.Count) return -1;
        for (int index = start; index + needle.Length <= html.Count; index++)
        {
            bool matched = true;
            for (int offset = 0; offset < needle.Length; offset++)
            {
                int actual = html[index + offset];
                if (foldCase && actual is >= 'A' and <= 'Z') actual += 32;
                if (actual != needle[offset]) { matched = false; break; }
            }
            if (matched) return index;
        }
        return -1;
    }

    /// <summary>Tags removed; head/script/style/title content skipped; block elements start a line,
    /// &lt;br&gt; breaks (at most one blank line); whitespace collapsed; the six basic named and all numeric
    /// character references decoded.</summary>
    internal static string HtmlToText(string value)
    {
        var html = Scalars(value);
        int n = html.Count;
        var output = new StringBuilder(value.Length);
        bool pending = false, atStart = true;
        int newlines = 0;

        void Text(int scalar)
        {
            if (IsWhite(scalar)) { pending = true; return; }
            if (pending && !atStart && newlines == 0) output.Append(' ');
            pending = false;
            newlines = 0;
            atStart = false;
            output.Append(new Rune(scalar).ToString());
        }
        void Line(bool hard)
        {
            pending = false;
            if (atStart) return;
            if (hard)
            {
                if (newlines < 2) { output.Append('\n'); newlines++; }
            }
            else if (newlines == 0)
            {
                output.Append('\n');
                newlines = 1;
            }
        }

        int i = 0;
        while (i < n)
        {
            int scalar = html[i];
            if (scalar == '<')
            {
                if (i + 3 < n && html[i + 1] == '!' && html[i + 2] == '-' && html[i + 3] == '-')
                {
                    int end = Find(html, "-->", i + 4);
                    i = end < 0 ? n : end + 3;
                    continue;
                }
                if (i + 1 < n && html[i + 1] is '!' or '?')
                {
                    int end = Find(html, ">", i + 2);
                    i = end < 0 ? n : end + 1;
                    continue;
                }
                int j = i + 1;
                bool closing = j < n && html[j] == '/';
                if (closing) j++;
                int k = j;
                while (k < n && IsAlnum(html[k])) k++;
                if (k == j || !IsLetter(html[j]))
                {
                    Text(scalar);
                    i++;
                    continue;
                }
                string name = AsciiLower(Slice(html, j, k));
                int quote = -1;
                while (k < n)
                {
                    int c = html[k];
                    if (quote >= 0) { if (c == quote) quote = -1; }
                    else if (c is '"' or '\'') quote = c;
                    else if (c == '>') break;
                    k++;
                }
                i = k + 1;
                if (!closing && SkippedElements.Contains(name))
                {
                    int end = Find(html, "</" + name, Math.Min(i, n), foldCase: true);
                    if (end < 0) i = n;
                    else
                    {
                        int close = Find(html, ">", end);
                        i = close < 0 ? n : close + 1;
                    }
                    continue;
                }
                if (name == "br") Line(true);
                else if (BlockElements.Contains(name)) Line(false);
                else if (name is "td" or "th") pending = true;
                continue;
            }
            if (scalar == '&')
            {
                int end = -1;
                for (int m = i + 1; m < Math.Min(i + 12, n); m++)
                    if (html[m] == ';') { end = m; break; }
                if (end > i + 1)
                {
                    int decoded = -1;
                    if (html[i + 1] == '#')
                    {
                        int start = i + 2;
                        int radix = 10;
                        if (start < end && html[start] is 'x' or 'X') { start++; radix = 16; }
                        int count = end - start;
                        bool allowed = count is >= 1 and <= 8;
                        long code = 0;
                        for (int m = start; allowed && m < end; m++)
                        {
                            int digit = radix == 16 ? HexValue(html[m]) : html[m] is >= '0' and <= '9' ? html[m] - '0' : -1;
                            if (digit < 0) allowed = false;
                            else code = code * radix + digit;
                        }
                        if (allowed)
                            decoded = code == 0 || code is >= 0xD800 and <= 0xDFFF || code > 0x10FFFF ? 0xFFFD : (int)code;
                    }
                    else if (Entities.TryGetValue(Slice(html, i + 1, end), out var named)) decoded = named;
                    if (decoded >= 0)
                    {
                        Text(decoded);
                        i = end + 1;
                        continue;
                    }
                }
            }
            Text(scalar);
            i++;
        }
        while (output.Length > 0 && output[^1] == '\n') output.Length--;
        return output.ToString();
    }

    // ---- Tables (bytes 0x80..0xFF; undefined positions are U+FFFD) ----------------------------

    internal static readonly ushort[] Windows1250 =
    [
        0x20AC, 0xFFFD, 0x201A, 0xFFFD, 0x201E, 0x2026, 0x2020, 0x2021, 0xFFFD, 0x2030, 0x0160, 0x2039, 0x015A, 0x0164, 0x017D, 0x0179,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0xFFFD, 0x2122, 0x0161, 0x203A, 0x015B, 0x0165, 0x017E, 0x017A,
        0x00A0, 0x02C7, 0x02D8, 0x0141, 0x00A4, 0x0104, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x015E, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x017B,
        0x00B0, 0x00B1, 0x02DB, 0x0142, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x0105, 0x015F, 0x00BB, 0x013D, 0x02DD, 0x013E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9
    ];

    internal static readonly ushort[] Windows1252 =
    [
        0x20AC, 0xFFFD, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0xFFFD, 0x017D, 0xFFFD,
        0xFFFD, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0xFFFD, 0x017E, 0x0178,
        0x00A0, 0x00A1, 0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x00A6, 0x00A7, 0x00A8, 0x00A9, 0x00AA, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x00AF,
        0x00B0, 0x00B1, 0x00B2, 0x00B3, 0x00B4, 0x00B5, 0x00B6, 0x00B7, 0x00B8, 0x00B9, 0x00BA, 0x00BB, 0x00BC, 0x00BD, 0x00BE, 0x00BF,
        0x00C0, 0x00C1, 0x00C2, 0x00C3, 0x00C4, 0x00C5, 0x00C6, 0x00C7, 0x00C8, 0x00C9, 0x00CA, 0x00CB, 0x00CC, 0x00CD, 0x00CE, 0x00CF,
        0x00D0, 0x00D1, 0x00D2, 0x00D3, 0x00D4, 0x00D5, 0x00D6, 0x00D7, 0x00D8, 0x00D9, 0x00DA, 0x00DB, 0x00DC, 0x00DD, 0x00DE, 0x00DF,
        0x00E0, 0x00E1, 0x00E2, 0x00E3, 0x00E4, 0x00E5, 0x00E6, 0x00E7, 0x00E8, 0x00E9, 0x00EA, 0x00EB, 0x00EC, 0x00ED, 0x00EE, 0x00EF,
        0x00F0, 0x00F1, 0x00F2, 0x00F3, 0x00F4, 0x00F5, 0x00F6, 0x00F7, 0x00F8, 0x00F9, 0x00FA, 0x00FB, 0x00FC, 0x00FD, 0x00FE, 0x00FF
    ];

    internal static readonly ushort[] Iso88592 =
    [
        0x0080, 0x0081, 0x0082, 0x0083, 0x0084, 0x0085, 0x0086, 0x0087, 0x0088, 0x0089, 0x008A, 0x008B, 0x008C, 0x008D, 0x008E, 0x008F,
        0x0090, 0x0091, 0x0092, 0x0093, 0x0094, 0x0095, 0x0096, 0x0097, 0x0098, 0x0099, 0x009A, 0x009B, 0x009C, 0x009D, 0x009E, 0x009F,
        0x00A0, 0x0104, 0x02D8, 0x0141, 0x00A4, 0x013D, 0x015A, 0x00A7, 0x00A8, 0x0160, 0x015E, 0x0164, 0x0179, 0x00AD, 0x017D, 0x017B,
        0x00B0, 0x0105, 0x02DB, 0x0142, 0x00B4, 0x013E, 0x015B, 0x02C7, 0x00B8, 0x0161, 0x015F, 0x0165, 0x017A, 0x02DD, 0x017E, 0x017C,
        0x0154, 0x00C1, 0x00C2, 0x0102, 0x00C4, 0x0139, 0x0106, 0x00C7, 0x010C, 0x00C9, 0x0118, 0x00CB, 0x011A, 0x00CD, 0x00CE, 0x010E,
        0x0110, 0x0143, 0x0147, 0x00D3, 0x00D4, 0x0150, 0x00D6, 0x00D7, 0x0158, 0x016E, 0x00DA, 0x0170, 0x00DC, 0x00DD, 0x0162, 0x00DF,
        0x0155, 0x00E1, 0x00E2, 0x0103, 0x00E4, 0x013A, 0x0107, 0x00E7, 0x010D, 0x00E9, 0x0119, 0x00EB, 0x011B, 0x00ED, 0x00EE, 0x010F,
        0x0111, 0x0144, 0x0148, 0x00F3, 0x00F4, 0x0151, 0x00F6, 0x00F7, 0x0159, 0x016F, 0x00FA, 0x0171, 0x00FC, 0x00FD, 0x0163, 0x02D9
    ];
}
