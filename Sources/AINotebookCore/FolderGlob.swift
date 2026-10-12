/// The folder exclusion grammar, evaluated over Unicode scalars without
/// normalization or host-dependent casing.
public struct FolderGlob: Sendable {
    private let components: [[UInt32]]
    private let anchored: Bool
    private let caseSensitive: Bool
    private let tables: UnicodeTables

    public init(_ pattern: String, caseSensitive: Bool, tables: UnicodeTables) throws {
        let scalars = pattern.unicodeScalars.map(\.value)
        let unsupported: Set<UInt32> = [0x5B, 0x5D, 0x7B, 0x7D, 0x5C]
        guard !scalars.isEmpty, scalars.first != 0x21,
              !scalars.contains(where: unsupported.contains) else {
            throw IngestionError(code: "unsupportedSyntax")
        }
        // Removing empty components strips outer separators and collapses
        // interior runs. A trailing slash alone never makes a rule anchored.
        let parts = scalars.split(separator: 0x2F)
        guard !parts.isEmpty else { throw IngestionError(code: "unsupportedSyntax") }
        anchored = scalars.first == 0x2F || parts.count > 1
        components = parts.map { part in
            part.map { caseSensitive ? $0 : tables.simpleLowercase($0) }
        }
        self.caseSensitive = caseSensitive
        self.tables = tables
    }

    public func matches(_ relativePath: String) -> Bool {
        let scalars = relativePath.unicodeScalars.map {
            caseSensitive ? $0.value : tables.simpleLowercase($0.value)
        }
        let path = scalars.split(separator: 0x2F, omittingEmptySubsequences: false).map(Array.init)
        if !anchored {
            return path.contains { Self.matchesComponent(components[0], $0) }
        }

        // matched[j] means the pattern processed so far matches exactly the
        // first j path components. The final row tests all ancestor prefixes
        // together, without retrying the matcher for every ancestor.
        var matched = [Bool](repeating: false, count: path.count + 1)
        matched[0] = true
        for component in components {
            var next = [Bool](repeating: false, count: path.count + 1)
            if component == [0x2A, 0x2A] {
                next[0] = matched[0]
                for index in path.indices {
                    next[index + 1] = matched[index + 1] || next[index]
                }
            } else {
                for index in path.indices where matched[index] {
                    next[index + 1] = Self.matchesComponent(component, path[index])
                }
            }
            matched = next
        }
        return matched.dropFirst().contains(true)
    }

    private static func matchesComponent(_ pattern: [UInt32], _ text: [UInt32]) -> Bool {
        if !pattern.contains(0x2A), !pattern.contains(0x3F) { return pattern == text }
        var matched = [Bool](repeating: false, count: text.count + 1)
        matched[0] = true
        for scalar in pattern {
            var next = [Bool](repeating: false, count: text.count + 1)
            if scalar == 0x2A {
                next[0] = matched[0]
                for index in text.indices {
                    next[index + 1] = matched[index + 1] || next[index]
                }
            } else {
                for index in text.indices {
                    next[index + 1] = matched[index] && (scalar == 0x3F || scalar == text[index])
                }
            }
            matched = next
        }
        return matched[text.count]
    }
}
