using AINotebook.Core.Models;
using Dapper;
using Microsoft.Data.Sqlite;

namespace AINotebook.Core.Storage;

/// <summary>
/// Builtin transformations seeded on every store init. Idempotent by
/// (name, is_builtin=1); backfills empty/NULL descriptions. Prompts are
/// verbatim from Sources/AINotebookCore/BuiltinTransformations.swift.
/// </summary>
internal static class BuiltinTransformations
{
    private readonly record struct Spec(string Name, string Description, string Prompt);

    private static readonly Spec[] English =
    {
        new("Summary", "3–5 bullet summary of a source.",
            "Summarize the following source text in 3-5 short bullet points. Keep\n" +
            "names, numbers, and dates exact. Output Markdown bullets only — no\n" +
            "preamble.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Key points", "5–10 most important takeaways.",
            "Extract the 5-10 most important key points from the following source\n" +
            "text. Output as a Markdown numbered list. Each item should be one\n" +
            "sentence, concrete, and self-contained.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Entities", "People, organizations, places, dates.",
            "Extract people, organizations, places, and dates from the following\n" +
            "source text. Output as Markdown sections (## People, ## Organizations,\n" +
            "## Places, ## Dates) with bullet points under each. Include only\n" +
            "entities literally present in the text.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Action items", "Concrete next-step actions found in the text.",
            "List every action item or next-step task mentioned in the following\n" +
            "source text. Output as a Markdown checklist (- [ ]). One item per\n" +
            "line. Include only actions literally present in the text.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
    };

    private static readonly Spec[] Czech =
    {
        new("Souhrn", "Shrnutí zdroje do 3–5 odrážek.",
            "Shrň následující zdrojový text do 3–5 krátkých odrážek. Zachovej přesně\n" +
            "jména, čísla a data. Výstup pouze jako odrážky v Markdownu — bez úvodu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Klíčové body", "5–10 nejdůležitějších bodů.",
            "Extrahuj 5–10 nejdůležitějších klíčových bodů z následujícího zdrojového\n" +
            "textu. Výstup jako Markdown číslovaný seznam. Každý bod jednou větou,\n" +
            "konkrétně a sám o sobě srozumitelný.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Entity", "Lidé, organizace, místa, data.",
            "Extrahuj osoby, organizace, místa a data z následujícího zdrojového textu.\n" +
            "Výstup jako Markdown sekce (## Osoby, ## Organizace, ## Místa, ## Data)\n" +
            "s odrážkami pod každou. Zahrň pouze entity doslova přítomné v textu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Úkoly", "Konkrétní úkoly nebo akce zmíněné v textu.",
            "Vypiš všechny úkoly nebo další kroky uvedené v následujícím zdrojovém\n" +
            "textu. Výstup jako Markdown checklist (- [ ]). Jeden úkol na řádek.\n" +
            "Zahrň pouze úkoly doslova přítomné v textu.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
    };

    internal static void SeedIfNeeded(SqliteConnection conn, AppLanguage language)
    {
        var specs = language == AppLanguage.Czech ? Czech : English;
        foreach (var s in specs)
        {
            var exists = conn.ExecuteScalar<long?>(
                "SELECT 1 FROM transformations WHERE name=$name AND is_builtin=1",
                new { name = s.Name }) is not null;
            if (!exists)
            {
                conn.Execute(
                    """
                    INSERT INTO transformations(name, prompt_template, scope, is_builtin, description)
                    VALUES($name, $prompt, 'source', 1, $desc)
                    """,
                    new { name = s.Name, prompt = s.Prompt, desc = s.Description });
            }
            else
            {
                conn.Execute(
                    """
                    UPDATE transformations
                       SET description = $desc
                     WHERE name = $name AND is_builtin = 1 AND (description IS NULL OR description = '')
                    """,
                    new { desc = s.Description, name = s.Name });
            }
        }
    }
}
