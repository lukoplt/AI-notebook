import Foundation

public struct ChunkLanguage: Codable, Equatable, Sendable {
    public let lang: String?
    public let langInherited: Bool

    public static func resolve(label: String?, reason: String?, documentLabel: String?) -> ChunkLanguage {
        guard let label else { return ChunkLanguage(lang: nil, langInherited: false) }
        if label == "und", reason == "minLetters" || reason == "minWords",
           let documentLabel, ["cs", "de", "en", "sk"].contains(documentLabel) {
            return ChunkLanguage(lang: documentLabel, langInherited: true)
        }
        return ChunkLanguage(lang: label, langInherited: false)
    }

    private enum CodingKeys: String, CodingKey {
        case lang, langInherited
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lang, forKey: .lang)
        try container.encode(langInherited, forKey: .langInherited)
    }
}
