import Foundation
import GRDB

enum BuiltinTransformations {

    struct Spec {
        let name: String
        let description: String
        let prompt: String
    }

    static let english: [Spec] = [
        Spec(
            name: "Summary",
            description: "3–5 bullet summary of a source.",
            prompt: """
            Summarize the following source text in 3-5 short bullet points. Keep
            names, numbers, and dates exact. Output Markdown bullets only — no
            preamble.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Key points",
            description: "5–10 most important takeaways.",
            prompt: """
            Extract the 5-10 most important key points from the following source
            text. Output as a Markdown numbered list. Each item should be one
            sentence, concrete, and self-contained.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Entities",
            description: "People, organizations, places, dates.",
            prompt: """
            Extract people, organizations, places, and dates from the following
            source text. Output as Markdown sections (## People, ## Organizations,
            ## Places, ## Dates) with bullet points under each. Include only
            entities literally present in the text.

            SOURCE TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Action items",
            description: "Concrete next-step actions found in the text.",
            prompt: """
            List every action item or next-step task mentioned in the following
            source text. Output as a Markdown checklist (- [ ]). One item per
            line. Include only actions literally present in the text.

            SOURCE TEXT:
            {{source_text}}
            """
        )
    ]

    static let czech: [Spec] = [
        Spec(
            name: "Souhrn",
            description: "Shrnutí zdroje do 3–5 odrážek.",
            prompt: """
            Shrň následující zdrojový text do 3–5 krátkých odrážek. Zachovej přesně
            jména, čísla a data. Výstup pouze jako odrážky v Markdownu — bez úvodu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Klíčové body",
            description: "5–10 nejdůležitějších bodů.",
            prompt: """
            Extrahuj 5–10 nejdůležitějších klíčových bodů z následujícího zdrojového
            textu. Výstup jako Markdown číslovaný seznam. Každý bod jednou větou,
            konkrétně a sám o sobě srozumitelný.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Entity",
            description: "Lidé, organizace, místa, data.",
            prompt: """
            Extrahuj osoby, organizace, místa a data z následujícího zdrojového textu.
            Výstup jako Markdown sekce (## Osoby, ## Organizace, ## Místa, ## Data)
            s odrážkami pod každou. Zahrň pouze entity doslova přítomné v textu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        ),
        Spec(
            name: "Úkoly",
            description: "Konkrétní úkoly nebo akce zmíněné v textu.",
            prompt: """
            Vypiš všechny úkoly nebo další kroky uvedené v následujícím zdrojovém
            textu. Výstup jako Markdown checklist (- [ ]). Jeden úkol na řádek.
            Zahrň pouze úkoly doslova přítomné v textu.

            ZDROJOVÝ TEXT:
            {{source_text}}
            """
        )
    ]

    static func seedIfNeeded(_ db: Database, language: AppLanguage) throws {
        let specs = (language == .czech) ? czech : english
        for s in specs {
            let exists: Bool = try Bool.fetchOne(
                db,
                sql: "SELECT 1 FROM transformations WHERE name = ? AND is_builtin = 1",
                arguments: [s.name]
            ) ?? false
            if !exists {
                var copy = Transformation(
                    name: s.name,
                    promptTemplate: s.prompt,
                    scope: .source,
                    isBuiltin: true,
                    description: s.description
                )
                try copy.insert(db)
            } else {
                try db.execute(
                    sql: """
                    UPDATE transformations
                       SET description = ?
                     WHERE name = ? AND is_builtin = 1 AND (description IS NULL OR description = '')
                    """,
                    arguments: [s.description, s.name]
                )
            }
        }
    }
}
