using System.Globalization;
using AINotebook.Core.Models;

namespace AINotebook.Core.Ingestion;

/// <summary>
/// Bounded .eml (RFC 5322/MIME) and Outlook .msg (MS-OXMSG in MS-CFB) reader producing canonical text
/// (contract ingestion-mail-v1, reference tools/contracts/gen_mail_fixtures.py, same output as macOS
/// MailReader): "Subject: …\nFrom: …\nTo: …\nCc: …\nDate: …\nAttachments: a, b\n\n&lt;body&gt;". Header
/// lines with an empty value are omitted; field labels are fixed English. Attachments are listed by name
/// only — their payloads (and any macro or embedded object) are never decoded, read or executed.
/// </summary>
internal static class MailReader
{
    internal const int MaxMimeDepth = 32;
    internal const int MaxMimeParts = 10_000;
    internal const int MaxAttachments = 10_000;

    internal sealed record Fields(string Subject, string From, string To, string Cc, string Date);

    internal static CanonicalDocument Read(byte[] data, string fileExtension, string fallback, IngestionLimits limits,
        CancellationToken ct = default)
    {
        if (data.Length > limits.FileBytes) throw new FolderIngestionException("fileLimit");
        var budget = new MailByteBudget(limits.OfficeBytes);
        (Fields Fields, List<string> Attachments, string Body) parsed;
        if (data.Length >= 8 && data.AsSpan(0, 8).SequenceEqual(CompoundFile.Magic)) parsed = ReadMsg(data, fallback, budget, ct);
        else if (MailText.AsciiLower(fileExtension.TrimStart('.')) == "msg") throw new FolderIngestionException("corruptArchive");
        else parsed = ReadEml(data, fallback, budget, ct);
        var (fields, attachments, body) = parsed;
        var lines = new List<string>();
        foreach (var (label, value) in new[] { ("Subject", fields.Subject), ("From", fields.From), ("To", fields.To),
                     ("Cc", fields.Cc), ("Date", fields.Date) })
            if (value.Length > 0) lines.Add($"{label}: {value}");
        if (attachments.Count > 0) lines.Add("Attachments: " + string.Join(", ", attachments));
        var builder = new ScalarTextBuilder(limits.TextScalars);
        string head = string.Join("\n", lines);
        builder.Append(head);
        if (head.Length > 0 && body.Length > 0) builder.Append("\n\n");
        builder.Append(body);
        return new CanonicalDocument(builder.ToString(), fields.Subject.Length == 0 ? null : fields.Subject,
            SourceType.Email.RawValue(), Array.Empty<PageBoundary>(), Array.Empty<string>(), null);
    }

    // ---- EML ---------------------------------------------------------------------------------

    internal sealed class Entity
    {
        public string Kind = "text/plain";
        public Dictionary<string, string> Params = new(StringComparer.Ordinal);
        public string Disposition = "";
        public string Name = "";
        public string TransferEncoding = "";
        public int BodyStart;
        public int BodyEnd;
        public List<Entity> Children = [];

        public bool IsMultipart => Kind.StartsWith("multipart/", StringComparison.Ordinal) &&
                                   Params.TryGetValue("boundary", out var boundary) && boundary.Length > 0;
        public bool IsAttachment => Disposition == "attachment" || (Disposition != "inline" && Name.Length > 0);
    }

    private readonly record struct Line(int Start, int ContentEnd, int Next);

    /// <summary>The line starting at i (&lt; end): LF ends a line; a CR before it is not content.</summary>
    private static Line LineAt(byte[] data, int i, int end)
    {
        int j = Array.IndexOf(data, (byte)0x0A, i, end - i);
        if (j < 0) return new Line(i, end, end);
        return new Line(i, j > i && data[j - 1] == 0x0D ? j - 1 : j, j + 1);
    }

    /// <summary>Unfolded headers (lowercased name, decoded raw value) and the body offset.</summary>
    private static (List<(string Name, string Value)> Headers, int BodyStart) Headers(byte[] data, int start, int end,
        string fallback, CancellationToken ct)
    {
        var raw = new List<(byte[] Name, List<byte> Value)>();
        bool open = false;
        int bodyStart = end;
        for (int position = start; position < end;)
        {
            ct.ThrowIfCancellationRequested();
            var line = LineAt(data, position, end);
            position = line.Next;
            if (line.ContentEnd == line.Start)
            {
                bodyStart = line.Next;
                break;
            }
            byte first = data[line.Start];
            if (first is 0x20 or 0x09)
            {
                if (open) raw[^1].Value.AddRange(data.AsSpan(line.Start, line.ContentEnd - line.Start).ToArray());
                continue;
            }
            int colon = Array.IndexOf(data, (byte)0x3A, line.Start, line.ContentEnd - line.Start);
            if (colon <= line.Start)
            {
                open = false;
                continue;
            }
            raw.Add((data[line.Start..colon], new List<byte>(data[(colon + 1)..line.ContentEnd])));
            open = true;
        }
        var headers = new List<(string, string)>(raw.Count);
        foreach (var (name, value) in raw)
        {
            int lo = 0, hi = name.Length;
            while (lo < hi && name[lo] is 0x20 or 0x09) lo++;
            while (hi > lo && name[hi - 1] is 0x20 or 0x09) hi--;
            var key = new char[hi - lo];
            for (int k = lo; k < hi; k++) key[k - lo] = (char)(name[k] is >= 65 and <= 90 ? name[k] + 32 : name[k]);
            headers.Add((new string(key), MailText.Decode(value.ToArray(), "auto", fallback)));
        }
        return (headers, bodyStart);
    }

    private static string? Header(List<(string Name, string Value)> headers, string name)
    {
        foreach (var (key, value) in headers) if (key == name) return value;
        return null;
    }

    private static (Entity Entity, List<(string Name, string Value)> Headers) ParseEntity(byte[] data, int start, int end,
        int depth, ref int parts, string fallback, CancellationToken ct)
    {
        if (depth > MaxMimeDepth) throw new FolderIngestionException("officeLimit");
        if (++parts > MaxMimeParts) throw new FolderIngestionException("officeLimit");
        var (headers, bodyStart) = Headers(data, start, end, fallback, ct);
        var entity = new Entity();
        var (kind, parameters) = MailText.Parameters(Header(headers, "content-type") ?? "");
        if (!kind.Contains('/')) (kind, parameters) = ("text/plain", new Dictionary<string, string>(StringComparer.Ordinal));
        entity.Kind = kind;
        entity.Params = parameters;
        var (disposition, dispositionParams) = MailText.Parameters(Header(headers, "content-disposition") ?? "");
        entity.Disposition = disposition;
        string filename = MailText.Parameter(dispositionParams, "filename", fallback);
        entity.Name = filename.Length == 0 ? MailText.Parameter(parameters, "name", fallback) : filename;
        entity.TransferEncoding = MailText.AsciiLower(MailText.Trim(Header(headers, "content-transfer-encoding") ?? ""));
        if (entity.IsMultipart)
        {
            var boundary = System.Text.Encoding.UTF8.GetBytes(parameters["boundary"]);
            foreach (var (partStart, partEnd) in Split(data, bodyStart, end, boundary, ct))
                entity.Children.Add(ParseEntity(data, partStart, partEnd, depth + 1, ref parts, fallback, ct).Entity);
        }
        else
        {
            entity.BodyStart = bodyStart;
            entity.BodyEnd = end;
        }
        return (entity, headers);
    }

    private static List<(int, int)> Split(byte[] data, int start, int end, byte[] boundary, CancellationToken ct)
    {
        var delimiter = new byte[] { 0x2D, 0x2D }.Concat(boundary).ToArray();
        var close = delimiter.Concat(new byte[] { 0x2D, 0x2D }).ToArray();
        var parts = new List<(int, int)>();
        int? open = null;
        for (int position = start; position < end;)
        {
            ct.ThrowIfCancellationRequested();
            var line = LineAt(data, position, end);
            position = line.Next;
            int stop = line.ContentEnd;
            while (stop > line.Start && data[stop - 1] is 0x20 or 0x09) stop--;
            var content = data.AsSpan(line.Start, stop - line.Start);
            bool isClose = content.SequenceEqual(close);
            if (!isClose && !content.SequenceEqual(delimiter)) continue;
            if (open is { } partStart)
            {
                int partEnd = line.Start;
                if (partEnd > partStart && data[partEnd - 1] == 0x0A)
                {
                    partEnd--;
                    if (partEnd > partStart && data[partEnd - 1] == 0x0D) partEnd--;
                }
                parts.Add((partStart, Math.Max(partStart, partEnd)));
            }
            if (isClose) return parts;
            open = line.Next;
        }
        if (open is { } last) parts.Add((last, end));
        return parts;
    }

    private static string LeafText(byte[] data, Entity entity, MailByteBudget budget, string fallback)
    {
        var body = data.AsSpan(entity.BodyStart, entity.BodyEnd - entity.BodyStart);
        byte[] bytes = entity.TransferEncoding switch
        {
            "base64" => MailText.Base64Lenient(body),
            "quoted-printable" => MailText.QuotedPrintable(body),
            _ => body.ToArray()
        };
        budget.Accept(bytes.Length);
        string text = MailText.NormalizeNewlines(MailText.Decode(bytes,
            MailText.CodecForLabel(entity.Params.GetValueOrDefault("charset", "")), fallback));
        if (entity.Kind == "text/html") text = MailText.HtmlToText(text);
        return MailText.Trim(text);
    }

    /// <summary>multipart/alternative: the first text/plain child, else the first child yielding a body;
    /// other multiparts join their children's bodies.</summary>
    private static string? Body(byte[] data, Entity entity, MailByteBudget budget, string fallback, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (entity.IsMultipart)
        {
            var children = entity.Children.Where(child => !child.IsAttachment).ToList();
            if (entity.Kind == "multipart/alternative")
            {
                var plain = children.FirstOrDefault(child => child.Kind == "text/plain");
                if (plain is not null) return LeafText(data, plain, budget, fallback);
                foreach (var child in children)
                    if (Body(data, child, budget, fallback, ct) is { } value) return value;
                return null;
            }
            var bodies = new List<string>();
            foreach (var child in children)
                if (Body(data, child, budget, fallback, ct) is { } value) bodies.Add(value);
            return bodies.Count == 0 ? null : string.Join("\n\n", bodies.Where(value => value.Length > 0));
        }
        if (entity.IsAttachment || entity.Kind is not ("text/plain" or "text/html")) return null;
        return LeafText(data, entity, budget, fallback);
    }

    private static void Attachments(Entity entity, List<string> names)
    {
        if (entity.IsMultipart)
        {
            foreach (var child in entity.Children) Attachments(child, names);
        }
        else if (entity.IsAttachment && entity.Name.Length > 0)
        {
            if (names.Count >= MaxAttachments) throw new FolderIngestionException("officeLimit");
            names.Add(entity.Name);
        }
    }

    internal static (Fields, List<string>, string) ReadEml(byte[] data, string fallback, MailByteBudget budget,
        CancellationToken ct = default)
    {
        int start = 0;
        if (data.AsSpan().StartsWith("From "u8))
        {
            int newline = Array.IndexOf(data, (byte)0x0A);
            start = newline < 0 ? data.Length : newline + 1;
        }
        int parts = 0;
        var (root, headers) = ParseEntity(data, start, data.Length, 0, ref parts, fallback, ct);
        string Field(string name) => MailText.DecodeHeader(Header(headers, name) ?? "", fallback);
        var fields = new Fields(Field("subject"), Field("from"), Field("to"), Field("cc"), Field("date"));
        string text = Body(data, root, budget, fallback, ct) ?? "";
        var names = new List<string>();
        Attachments(root, names);
        return (fields, names, MailText.Trim(text));
    }

    // ---- MSG ---------------------------------------------------------------------------------

    private const uint TagSubject = 0x0037, TagSentName = 0x0042, TagSentEmail = 0x0065, TagSenderName = 0x0C1A,
        TagSenderEmail = 0x0C1F, TagSmtp = 0x5D01, TagDisplayCc = 0x0E03, TagDisplayTo = 0x0E04, TagBody = 0x1000,
        TagHtml = 0x1013, TagSubmitTime = 0x0039, TagDeliveryTime = 0x0E06, TagCodePage = 0x3FFD,
        TagInternetCodePage = 0x3FDE, TagAttachLongName = 0x3707, TagAttachShortName = 0x3704, TagDisplayName = 0x3001;

    private static string StreamName(uint property, uint type) =>
        string.Create(CultureInfo.InvariantCulture, $"__SUBSTG1.0_{property:X4}{type:X4}");

    private static string? MsgString(CompoundFile file, Dictionary<string, int> children, uint property, string codec,
        string fallback)
    {
        if (children.TryGetValue(StreamName(property, 0x001F), out var unicode))
        {
            var scalars = MailText.Scalars(MailText.Utf16Le(file.Stream(unicode)));
            while (scalars.Count > 0 && scalars[^1] == 0) scalars.RemoveAt(scalars.Count - 1);
            return MailText.FromScalars(scalars);
        }
        if (children.TryGetValue(StreamName(property, 0x001E), out var ansi))
        {
            var bytes = file.Stream(ansi);
            int length = bytes.Length;
            while (length > 0 && bytes[length - 1] == 0) length--;
            return MailText.Decode(bytes.AsSpan(0, length), codec, fallback);
        }
        return null;
    }

    /// <summary>Top-level fixed-length properties: id to (type, 8 value bytes); the first entry per id wins.</summary>
    private static Dictionary<uint, (uint Type, byte[] Value)> Properties(CompoundFile file, Dictionary<string, int> children)
    {
        var result = new Dictionary<uint, (uint, byte[])>();
        if (!children.TryGetValue("__PROPERTIES_VERSION1.0", out var index)) return result;
        var data = file.Stream(index);
        for (int at = 32; at + 16 <= data.Length; at += 16)
        {
            uint tag = CompoundFile.U32(data, at);
            result.TryAdd(tag >> 16, (tag & 0xFFFF, data[(at + 8)..(at + 16)]));
        }
        return result;
    }

    /// <summary>FILETIME to "YYYY-MM-DDTHH:MM:SSZ" (UTC); 0 or a year above 9999 to "".</summary>
    internal static string Filetime(ulong value)
    {
        if (value == 0) return "";
        long seconds = (long)(value / 10_000_000) - 11_644_473_600;
        long days = seconds / 86_400, rest = seconds % 86_400;
        if (rest < 0) { rest += 86_400; days--; }
        long z = days + 719_468;
        long era = (z >= 0 ? z : z - 146_096) / 146_097;
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        long day = doy - (153 * mp + 2) / 5 + 1;
        long month = mp < 10 ? mp + 3 : mp - 9;
        long year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        if (year > 9999) return "";
        return string.Create(CultureInfo.InvariantCulture,
            $"{year:D4}-{month:D2}-{day:D2}T{rest / 3600:D2}:{rest / 60 % 60:D2}:{rest % 60:D2}Z");
    }

    internal static (Fields, List<string>, string) ReadMsg(byte[] data, string fallback, MailByteBudget budget,
        CancellationToken ct = default)
    {
        var file = new CompoundFile(data, budget, ct);
        var root = file.Children(0);
        var props = Properties(file, root);
        uint? Long(uint property) =>
            props.TryGetValue(property, out var value) && value.Type == 0x0003 ? CompoundFile.U32(value.Value, 0) : null;
        string codec = Long(TagCodePage) is { } page ? MailText.CodecForCodePage(page) : "auto";
        string htmlCodec = Long(TagInternetCodePage) is { } cpid ? MailText.CodecForCodePage(cpid) : codec;
        string Value(uint property, Dictionary<string, int>? children = null) =>
            MailText.Collapse(MsgString(file, children ?? root, property, codec, fallback) ?? "");

        string name = Value(TagSenderName);
        if (name.Length == 0) name = Value(TagSentName);
        string email = "";
        foreach (var property in new[] { TagSmtp, TagSenderEmail, TagSentEmail })
        {
            string candidate = Value(property);
            if (candidate.Contains('@')) { email = candidate; break; }
        }
        string from = name.Length > 0 && email.Length > 0 && name != email ? $"{name} <{email}>"
            : name.Length == 0 ? email : name;
        string date = "";
        foreach (var property in new[] { TagSubmitTime, TagDeliveryTime })
        {
            if (!props.TryGetValue(property, out var raw) || raw.Type != 0x0040) continue;
            date = Filetime(BitConverter.ToUInt64(raw.Value, 0));
            if (date.Length > 0) break;
        }
        var fields = new Fields(Value(TagSubject), from, Value(TagDisplayTo), Value(TagDisplayCc), date);
        string text = MsgString(file, root, TagBody, codec, fallback) is { } body
            ? MailText.Trim(MailText.NormalizeNewlines(body)) : "";
        if (text.Length == 0)
        {
            string? html = root.TryGetValue(StreamName(TagHtml, 0x0102), out var binary)
                ? MailText.Decode(file.Stream(binary), htmlCodec, fallback)
                : MsgString(file, root, TagHtml, codec, fallback);
            text = html is null ? "" : MailText.Trim(MailText.HtmlToText(MailText.NormalizeNewlines(html)));
        }
        var storages = root.Where(pair => pair.Key.StartsWith("__ATTACH_VERSION1.0_#", StringComparison.Ordinal) &&
                                          file.Entries[pair.Value].Kind == 1)
            .Select(pair => pair.Key).OrderBy(key => key, StringComparer.Ordinal).ToList();
        if (storages.Count > MaxAttachments) throw new FolderIngestionException("officeLimit");
        var names = new List<string>();
        foreach (var key in storages)
        {
            ct.ThrowIfCancellationRequested();
            var children = file.Children(root[key]);
            string attachment = Value(TagAttachLongName, children);
            if (attachment.Length == 0) attachment = Value(TagAttachShortName, children);
            if (attachment.Length == 0) attachment = Value(TagDisplayName, children);
            if (attachment.Length > 0) names.Add(attachment);
        }
        return (fields, names, text);
    }
}
