using System.Text.Json;

namespace AINotebook.App.Editor;

public abstract record EditorMessage
{
    public sealed record Ready : EditorMessage;
    public sealed record Change(string Markdown) : EditorMessage;
    public sealed record Save(string Markdown) : EditorMessage;
    public sealed record AttachmentRequest(string RequestId, string Filename, string Mime, string Base64) : EditorMessage;
}

public static class MarkdownHtmlBridge
{
    // Returns null on unknown/invalid payloads (mirrors Swift: unknown payloads ignored in v1).
    public static EditorMessage? Decode(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("kind", out var kindEl) || kindEl.ValueKind != JsonValueKind.String)
                return null;
            switch (kindEl.GetString())
            {
                case "ready": return new EditorMessage.Ready();
                case "change":
                    return root.TryGetProperty("markdown", out var cmd) && cmd.ValueKind == JsonValueKind.String
                        ? new EditorMessage.Change(cmd.GetString()!) : null;
                case "save":
                    return root.TryGetProperty("markdown", out var smd) && smd.ValueKind == JsonValueKind.String
                        ? new EditorMessage.Save(smd.GetString()!) : null;
                case "attachment":
                    if (root.TryGetProperty("requestId", out var r) && r.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("filename", out var f) && f.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("mime", out var m) && m.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("base64", out var b) && b.ValueKind == JsonValueKind.String)
                        return new EditorMessage.AttachmentRequest(r.GetString()!, f.GetString()!, m.GetString()!, b.GetString()!);
                    return null;
                default: return null;
            }
        }
        catch (JsonException) { return null; }
    }

    // Mirrors Swift escape order: backslash, then backtick, then dollar.
    public static string EscapeForTemplateLiteral(string md) =>
        md.Replace("\\", "\\\\").Replace("`", "\\`").Replace("$", "\\$");
}
