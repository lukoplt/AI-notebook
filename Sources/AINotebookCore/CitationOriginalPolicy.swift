import Foundation

/// Native adapters resolve filesystem identities before asking Core for a decision.
public struct CitationOriginalInput: Codable, Equatable, Sendable {
    public var relativePath: String
    public var rootComponents: [String]
    public var resolvedComponents: [String]
    public var caseSensitive: Bool
    public var exists: Bool
    public var isRegularFile: Bool
    public var sourceExists: Bool
    public var currentRevisionId: Int64?
    public var citedRevisionId: Int64?

    public init(relativePath: String, rootComponents: [String], resolvedComponents: [String],
                caseSensitive: Bool, exists: Bool, isRegularFile: Bool, sourceExists: Bool,
                currentRevisionId: Int64?, citedRevisionId: Int64?) {
        self.relativePath = relativePath
        self.rootComponents = rootComponents
        self.resolvedComponents = resolvedComponents
        self.caseSensitive = caseSensitive
        self.exists = exists
        self.isRegularFile = isRegularFile
        self.sourceExists = sourceExists
        self.currentRevisionId = currentRevisionId
        self.citedRevisionId = citedRevisionId
    }
}

public enum CitationOriginalDecision: String, Codable, Equatable, Sendable {
    case available
    case changed
    case unavailable
    case unsafe
}

public enum CitationOriginalPolicy {
    public static func evaluate(_ input: CitationOriginalInput) -> CitationOriginalDecision {
        let scalars = input.relativePath.unicodeScalars
        let parts = scalars.split(separator: "/", omittingEmptySubsequences: false)
        guard !scalars.isEmpty,
              !scalars.contains(where: { $0 == "\\" || $0 == ":" || $0.value < 32 }),
              parts.allSatisfy({ part in
                  !part.isEmpty && !part.elementsEqual(".".unicodeScalars)
                      && !part.elementsEqual("..".unicodeScalars)
              }) else { return .unsafe }
        guard input.sourceExists, input.exists, input.isRegularFile else { return .unavailable }
        guard !input.rootComponents.isEmpty,
              input.resolvedComponents.count > input.rootComponents.count else { return .unsafe }
        // The volume flag records how the native adapter obtained these identities.
        // Even on insensitive volumes, Core must not normalize or case-fold them.
        guard zip(input.rootComponents, input.resolvedComponents).allSatisfy({ root, resolved in
            root.unicodeScalars.elementsEqual(resolved.unicodeScalars)
        }) else { return .unsafe }
        return input.citedRevisionId != nil && input.currentRevisionId != input.citedRevisionId ? .changed : .available
    }
}
