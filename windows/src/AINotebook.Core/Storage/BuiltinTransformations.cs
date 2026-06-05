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
        new("FAQ", "Common questions and answers from the source.",
            "Write a FAQ of 6-10 questions a reader is likely to ask about the\n" +
            "following source text. Each answer must be concise and grounded only\n" +
            "in the text — do not invent facts. Output Markdown with each question\n" +
            "in bold, then its answer on the next line.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Study guide", "Review questions and key terms for studying.",
            "Produce a study guide from the following source text using only what\n" +
            "it contains. Output two Markdown sections:\n\n" +
            "## Key terms\n" +
            "- term — short definition\n\n" +
            "## Review questions\n" +
            "8-12 questions a student should be able to answer (questions only, no\n" +
            "answers).\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Timeline", "Chronological list of events and dates.",
            "Build a chronological timeline from the following source text, ordered\n" +
            "earliest to latest. Output a Markdown list where each line is\n" +
            "'**<date/time>** — <event>'. Include only events and dates literally\n" +
            "present in the text and omit anything undated.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Briefing doc", "Executive briefing of the source.",
            "Write an executive briefing of the following source text, grounded in\n" +
            "the text with no speculation. Output these Markdown sections:\n\n" +
            "## Overview\n" +
            "2-3 sentences.\n\n" +
            "## Key points\n" +
            "bullets.\n\n" +
            "## Notable details\n" +
            "bullets.\n\n" +
            "## Open questions\n" +
            "bullets, if any.\n\n" +
            "SOURCE TEXT:\n{{source_text}}"),
        new("Glossary", "Key terms and definitions.",
            "Build a glossary from the following source text. Output a Markdown list\n" +
            "where each line is '**<term>** — <definition>'. Define each term only\n" +
            "from the text, include only terms that appear in the text, and sort the\n" +
            "list alphabetically.\n\n" +
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
        new("FAQ", "Časté otázky a odpovědi ze zdroje.",
            "Sestav FAQ se 6–10 otázkami, které čtenáře nejspíš k následujícímu\n" +
            "zdrojovému textu napadnou. Každá odpověď musí být stručná a založená\n" +
            "pouze na textu — nic si nevymýšlej. Výstup v Markdownu: každá otázka\n" +
            "tučně, odpověď na dalším řádku.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Studijní příručka", "Opakovací otázky a klíčové pojmy ke studiu.",
            "Vytvoř studijní příručku z následujícího zdrojového textu pouze z toho,\n" +
            "co obsahuje. Výstup dvě Markdown sekce:\n\n" +
            "## Klíčové pojmy\n" +
            "- pojem — krátká definice\n\n" +
            "## Opakovací otázky\n" +
            "8–12 otázek, na které by měl student umět odpovědět (pouze otázky, bez\n" +
            "odpovědí).\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Časová osa", "Chronologický seznam událostí a dat.",
            "Sestav chronologickou časovou osu z následujícího zdrojového textu,\n" +
            "seřazenou od nejstarší po nejnovější. Výstup jako Markdown seznam, kde\n" +
            "každý řádek je '**<datum/čas>** — <událost>'. Zahrň pouze události a\n" +
            "data doslova přítomná v textu a vynech cokoli bez data.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Briefing", "Stručný přehled zdroje.",
            "Napiš stručný přehled následujícího zdrojového textu, vycházej pouze\n" +
            "z textu a nespekuluj. Výstup tyto Markdown sekce:\n\n" +
            "## Přehled\n" +
            "2–3 věty.\n\n" +
            "## Klíčové body\n" +
            "odrážky.\n\n" +
            "## Zajímavé detaily\n" +
            "odrážky.\n\n" +
            "## Otevřené otázky\n" +
            "odrážky, pokud nějaké jsou.\n\n" +
            "ZDROJOVÝ TEXT:\n{{source_text}}"),
        new("Slovníček", "Klíčové pojmy a definice.",
            "Sestav slovníček z následujícího zdrojového textu. Výstup jako Markdown\n" +
            "seznam, kde každý řádek je '**<pojem>** — <definice>'. Každý pojem\n" +
            "definuj pouze z textu, zahrň jen pojmy, které se v textu objevují, a\n" +
            "seřaď seznam abecedně.\n\n" +
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
