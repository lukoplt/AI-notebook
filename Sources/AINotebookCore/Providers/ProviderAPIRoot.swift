import Foundation
import Darwin

public enum ProviderEndpoint: String, Sendable {
    case chat, models, embeddings
}

public enum ProviderConfigurationError: String, Error, Sendable {
    case invalidBaseURL, unsupportedEndpoint, missingProvider, disabledProvider, invalidLimits
}

/// Validates an exact API prefix without changing its host, port or escaped path.
/// Legacy version insertion is deliberately separate from runtime request building.
public enum ProviderAPIRoot {
    public static func normalize(_ baseURL: String) throws -> String {
        // Controls are invalid even at the edges: trimming must not repair them.
        guard !baseURL.unicodeScalars.contains(where: {
            $0.value < 0x20 || (0x7F...0x9F).contains($0.value)
        }) else {
            throw ProviderConfigurationError.invalidBaseURL
        }

        let trimmed = baseURL.unicodeScalars
            .drop(while: { $0.properties.isWhitespace })
            .reversed()
            .drop(while: { $0.properties.isWhitespace })
            .reversed()
        var root = String(String.UnicodeScalarView(trimmed))
        guard !root.isEmpty,
              !root.unicodeScalars.contains(where: { $0.properties.isWhitespace }),
              !root.contains("\\"), !root.contains("?"), !root.contains("#"),
              let schemeEnd = root.range(of: "://"),
              ["http", "https"].contains(root[..<schemeEnd.lowerBound].lowercased())
        else {
            throw ProviderConfigurationError.invalidBaseURL
        }

        let remainder = root[schemeEnd.upperBound...]
        let authority = remainder.prefix(while: { $0 != "/" })
        try validateAuthority(authority)

        while root.hasSuffix("/") { root.removeLast() }
        guard URL(string: root, encodingInvalidCharacters: false) != nil else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        return root
    }

    public static func convertLegacy(type: ProviderType, baseURL: String) throws -> String {
        let root = try normalize(baseURL)
        if (type == .openai || type == .openaiCompatible) && !root.hasSuffix("/v1") {
            return root + "/v1"
        }
        return root
    }

    public static func build(
        type: ProviderType,
        baseURL: String,
        endpoint: ProviderEndpoint
    ) throws -> URL {
        // Invalid configuration takes precedence over an unsupported endpoint.
        let root = try normalize(baseURL)
        let path: String
        switch (type, endpoint) {
        case (.openai, .chat), (.openaiCompatible, .chat): path = "chat/completions"
        case (.openai, .models), (.openaiCompatible, .models): path = "models"
        case (.openai, .embeddings), (.openaiCompatible, .embeddings): path = "embeddings"
        case (.anthropic, .chat): path = "v1/messages"
        case (.anthropic, .models): path = "v1/models"
        case (.openwebui, .chat): path = "api/chat/completions"
        case (.openwebui, .models): path = "api/models"
        case (.ollama, .chat): path = "api/chat"
        case (.ollama, .models): path = "api/tags"
        case (.ollama, .embeddings): path = "api/embed"
        case (.anthropic, .embeddings), (.openwebui, .embeddings):
            throw ProviderConfigurationError.unsupportedEndpoint
        }
        guard let url = URL(string: root + "/" + path, encodingInvalidCharacters: false) else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        return url
    }

    private static func validateAuthority(_ authority: Substring) throws {
        guard !authority.isEmpty, !authority.contains("@"), !authority.contains("%") else {
            throw ProviderConfigurationError.invalidBaseURL
        }

        if authority.first == "[" {
            guard let close = authority.firstIndex(of: "]") else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            let literal = String(authority[authority.index(after: authority.startIndex)..<close])
            var address = in6_addr()
            guard literal.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            let suffix = authority[authority.index(after: close)...]
            if !suffix.isEmpty {
                guard suffix.first == ":" else {
                    throw ProviderConfigurationError.invalidBaseURL
                }
                try validatePort(suffix.dropFirst())
            }
        } else {
            guard !authority.contains("["), !authority.contains("]") else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            try validateHostname(parts[0])
            if parts.count == 2 { try validatePort(parts[1]) }
        }
    }

    private static func validatePort(_ port: Substring) throws {
        guard !port.isEmpty, port.utf8.allSatisfy(isDigit),
              let number = Int(port), (1...65535).contains(number)
        else {
            throw ProviderConfigurationError.invalidBaseURL
        }
    }

    private static func validateHostname(_ suppliedHost: Substring) throws {
        let host = suppliedHost.last == "." ? suppliedHost.dropLast() : suppliedHost
        guard !host.isEmpty, host.utf8.count <= 253 else {
            throw ProviderConfigurationError.invalidBaseURL
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if host.contains("."), host.utf8.allSatisfy({ isDigit($0) || $0 == 0x2E }) {
            guard labels.count == 4, labels.allSatisfy({
                !$0.isEmpty && ($0.count == 1 || $0.first != "0")
                    && $0.utf8.allSatisfy(isDigit)
                    && Int($0).map { (0...255).contains($0) } == true
            }) else {
                throw ProviderConfigurationError.invalidBaseURL
            }
            return
        }
        // WHATWG "ends in a number": a numeric (decimal or 0x-hex) last label makes
        // URL parsers reinterpret the host as IPv4 (.NET: 1234 -> 0.0.4.210), so
        // only the strict dotted quad above may be numeric (contract §5).
        if let last = labels.last {
            let lower = Array(last.lowercased().utf8)
            let isHex = lower.count >= 2 && lower[0] == 0x30 && lower[1] == 0x78
                && lower.dropFirst(2).allSatisfy { isDigit($0) || (0x61...0x66).contains($0) }
            if (!lower.isEmpty && lower.allSatisfy(isDigit)) || isHex {
                throw ProviderConfigurationError.invalidBaseURL
            }
        }
        guard labels.allSatisfy({ label in
            let bytes = Array(label.utf8)
            return (1...63).contains(bytes.count)
                && bytes.first.map(isAlphanumeric) == true
                && bytes.last.map(isAlphanumeric) == true
                && bytes.allSatisfy { isAlphanumeric($0) || $0 == 0x2D }
        }) else {
            throw ProviderConfigurationError.invalidBaseURL
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
