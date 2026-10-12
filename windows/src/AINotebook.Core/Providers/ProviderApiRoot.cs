using System.Globalization;
using System.Net;
using System.Net.Sockets;

namespace AINotebook.Core.Providers;

public enum ProviderEndpoint { Chat, Models, Embeddings }

/// <summary>Validates exact endpoint prefixes without rewriting stored configuration.</summary>
public static class ProviderApiRoot
{
    public static string Normalize(string baseUrl)
    {
        // Uri parsers can discard controls, including surrounding tabs/newlines.
        if (baseUrl is null || baseUrl.Any(char.IsControl)) throw InvalidBaseUrl();
        var root = baseUrl.Trim();
        if (root.Length == 0 || root.Any(char.IsWhiteSpace) ||
            root.IndexOfAny(['\\', '?', '#']) >= 0)
            throw InvalidBaseUrl();

        var separator = root.IndexOf("://", StringComparison.Ordinal);
        if (separator < 0 ||
            !(root[..separator].Equals("http", StringComparison.OrdinalIgnoreCase) ||
              root[..separator].Equals("https", StringComparison.OrdinalIgnoreCase)))
            throw InvalidBaseUrl();

        var start = separator + 3;
        var end = root.IndexOf('/', start);
        var authority = end < 0 ? root[start..] : root[start..end];
        ValidateAuthority(authority);

        if (!Uri.TryCreate(root, UriKind.Absolute, out _)) throw InvalidBaseUrl();
        return root.TrimEnd('/');
    }

    public static string ConvertLegacy(ProviderType type, string baseUrl)
    {
        var root = Normalize(baseUrl);
        return (type is ProviderType.OpenAI or ProviderType.OpenAICompatible) &&
            !root.EndsWith("/v1", StringComparison.Ordinal) ? root + "/v1" : root;
    }

    public static Uri Build(ProviderType type, string baseUrl, ProviderEndpoint endpoint)
    {
        // Invalid configuration takes precedence over an unsupported endpoint.
        var root = Normalize(baseUrl);
        var path = (type, endpoint) switch
        {
            (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Chat) => "chat/completions",
            (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Models) => "models",
            (ProviderType.OpenAI or ProviderType.OpenAICompatible, ProviderEndpoint.Embeddings) => "embeddings",
            (ProviderType.Anthropic, ProviderEndpoint.Chat) => "v1/messages",
            (ProviderType.Anthropic, ProviderEndpoint.Models) => "v1/models",
            (ProviderType.OpenWebUI, ProviderEndpoint.Chat) => "api/chat/completions",
            (ProviderType.OpenWebUI, ProviderEndpoint.Models) => "api/models",
            (ProviderType.Ollama, ProviderEndpoint.Chat) => "api/chat",
            (ProviderType.Ollama, ProviderEndpoint.Models) => "api/tags",
            (ProviderType.Ollama, ProviderEndpoint.Embeddings) => "api/embed",
            _ => throw new ProviderConfigurationException("unsupportedEndpoint")
        };
        return Append(root, path);
    }

    internal static Uri BuildOllama(string baseUrl, string path) => Append(Normalize(baseUrl), path);

    private static Uri Append(string root, string path)
    {
        // Ordinary Uri canonicalization would unescape proxy paths and collapse
        // dot segments. Normalize has already validated the complete root.
        if (!Uri.TryCreate(root + "/" + path,
            new UriCreationOptions { DangerousDisablePathAndQueryCanonicalization = true }, out var uri))
            throw InvalidBaseUrl();
        return uri;
    }

    private static void ValidateAuthority(string authority)
    {
        if (authority.Length == 0 || authority.IndexOfAny(['@', '%']) >= 0)
            throw InvalidBaseUrl();

        string suffix;
        if (authority[0] == '[')
        {
            var close = authority.IndexOf(']');
            if (close <= 1 ||
                !IPAddress.TryParse(authority[1..close], out var ip) ||
                ip.AddressFamily != AddressFamily.InterNetworkV6)
                throw InvalidBaseUrl();
            suffix = authority[(close + 1)..];
        }
        else
        {
            if (authority.IndexOfAny(['[', ']']) >= 0) throw InvalidBaseUrl();
            var colon = authority.IndexOf(':');
            var host = colon < 0 ? authority : authority[..colon];
            suffix = colon < 0 ? "" : authority[colon..];
            ValidateHost(host);
        }

        if (suffix.Length == 0) return;
        if (suffix[0] != ':' || suffix.Length == 1 || !suffix[1..].All(IsAsciiDigit) ||
            !int.TryParse(suffix[1..], NumberStyles.None, CultureInfo.InvariantCulture, out var port) ||
            port is < 1 or > 65535)
            throw InvalidBaseUrl();
    }

    private static void ValidateHost(string host)
    {
        // Exactly one terminal DNS root dot is allowed and remains in the URL.
        var dns = host.EndsWith('.') ? host[..^1] : host;
        if (dns.Length is < 1 or > 253) throw InvalidBaseUrl();
        var labels = dns.Split('.');
        foreach (var label in labels)
        {
            if (label.Length is < 1 or > 63 || !IsAsciiAlphanumeric(label[0]) ||
                !IsAsciiAlphanumeric(label[^1]) ||
                !label.All(c => IsAsciiAlphanumeric(c) || c == '-'))
                throw InvalidBaseUrl();
        }

        var last = labels[^1];
        // WHATWG's hexadecimal numeric form includes bare "0x". Reject these
        // before System.Uri can reinterpret the host as a different IPv4 address.
        var endsInNumber = last.All(IsAsciiDigit) ||
            (last.StartsWith("0x", StringComparison.OrdinalIgnoreCase) && last[2..].All(IsAsciiHex));
        if (!endsInNumber) return;
        if (labels.Length != 4 || labels.Any(label => label.Length > 3 || !label.All(IsAsciiDigit) ||
            (label.Length > 1 && label[0] == '0') ||
            !int.TryParse(label, NumberStyles.None, CultureInfo.InvariantCulture, out var octet) || octet > 255))
            throw InvalidBaseUrl();
    }

    private static bool IsAsciiDigit(char c) => c is >= '0' and <= '9';
    private static bool IsAsciiAlphanumeric(char c) => IsAsciiDigit(c) || c is >= 'A' and <= 'Z' or >= 'a' and <= 'z';
    private static bool IsAsciiHex(char c) => IsAsciiDigit(c) || c is >= 'A' and <= 'F' or >= 'a' and <= 'f';
    private static ProviderConfigurationException InvalidBaseUrl() => new("invalidBaseURL");
}
