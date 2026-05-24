import Foundation
import GRDB

enum BuiltinTransformations {

    static let summary = Transformation(
        name: "Summary",
        promptTemplate: """
        Summarize the following source text in 3-5 short bullet points. Keep
        names, numbers, and dates exact. Output Markdown bullets only — no
        preamble.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let keyPoints = Transformation(
        name: "Key points",
        promptTemplate: """
        Extract the 5-10 most important key points from the following source
        text. Output as a Markdown numbered list. Each item should be one
        sentence, concrete, and self-contained.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let entities = Transformation(
        name: "Entities",
        promptTemplate: """
        Extract people, organizations, places, and dates from the following
        source text. Output as Markdown sections (## People, ## Organizations,
        ## Places, ## Dates) with bullet points under each. Include only
        entities literally present in the text.

        SOURCE TEXT:
        {{source_text}}
        """,
        scope: .source,
        isBuiltin: true
    )

    static let all: [Transformation] = [summary, keyPoints, entities]

    /// Idempotent: only inserts each builtin if a row with that name +
    /// is_builtin = 1 doesn't already exist.
    static func seedIfNeeded(_ db: Database) throws {
        for t in all {
            let exists: Bool = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM transformations WHERE name = ? AND is_builtin = 1",
                arguments: [t.name]
            ) ?? false
            if !exists {
                var copy = t
                try copy.insert(db)
            }
        }
    }
}
