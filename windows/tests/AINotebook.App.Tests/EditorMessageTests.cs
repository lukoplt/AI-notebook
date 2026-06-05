using AINotebook.App.Editor;
using Xunit;

public class EditorMessageTests
{
    [Fact] public void Decode_ready() =>
        Assert.IsType<EditorMessage.Ready>(MarkdownHtmlBridge.Decode("{\"kind\":\"ready\"}"));
    [Fact] public void Decode_change_markdown() =>
        Assert.Equal("hi", Assert.IsType<EditorMessage.Change>(
            MarkdownHtmlBridge.Decode("{\"kind\":\"change\",\"markdown\":\"hi\"}")).Markdown);
    [Fact] public void Decode_attachment_allFields()
    {
        var a = Assert.IsType<EditorMessage.AttachmentRequest>(MarkdownHtmlBridge.Decode(
            "{\"kind\":\"attachment\",\"requestId\":\"r\",\"filename\":\"a.png\",\"mime\":\"image/png\",\"base64\":\"AA==\"}"));
        Assert.Equal("a.png", a.Filename);
    }
    [Fact] public void Decode_unknown_returnsNull() =>
        Assert.Null(MarkdownHtmlBridge.Decode("{\"kind\":\"nope\"}"));
    [Fact] public void Escape_order_backslash_backtick_dollar() =>
        Assert.Equal("\\\\ \\` \\$", MarkdownHtmlBridge.EscapeForTemplateLiteral("\\ ` $"));
}
