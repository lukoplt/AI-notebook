# Compact spreadsheet canonical text — normative contract v2

*Status: 2026-10-11. Fixture: `Tests/fixtures/contracts/ingestion-xlsx-v2.json` (assets `Tests/fixtures/ingestion/xlsx/*.xlsx` plus the shared `ingestion/workbook.xlsx` and `ingestion/formats/macro.xlsm`). Executable reference: `tools/contracts/gen_xlsx_fixtures.py` (`--check` must pass; `--measure` prints the v1/v2 size comparison of §9). Swift (`SpreadsheetText`, `XlsxReader`) and C# (`SpreadsheetText`, `XlsxReader`) must reproduce every case byte for byte. Supersedes the XLSX assembly of `folder-rag-v1.md` §3 "Assembly (`text_format_version = 1`)" for XLSX/XLSM only; every other kind keeps `text_format_version = 1` unchanged. Re-extraction of already published spreadsheets: `ingestion-reextract-v1.md` §7.*

## 1. Why

In a large folder with many spreadsheets, spreadsheets dominate the index: they can produce the vast majority of all chunks (hundreds per file, with every copy of a form template adding the same few hundred chunks again). Version 1 rendered every cell as `A1: value` and spelled out `[formula; no cached value]`, ` [cached formula]` and ` [date serial]`, so formula-heavy templates turned into hundreds of kilobytes of markers, references and raw serials. At embedding throughputs of a few dozen chunks per second that becomes the dominant indexing cost. Version 2 keeps every user-visible value and its row, and drops what carries no searchable content.

## 2. Layout

```
text   := block ("\n\n" block)*            -- one block per rendered sheet, workbook order
block  := "## " sheetName "\n" (row ("\n" row)*)?
row    := "R" rowNumber ": " cell (" | " cell)*
cell   := (columnName "=")? value
```

- Sheets: worksheets in workbook (`<sheets>`) order. Chart, dialog and macro sheets are skipped (unchanged). **Sheets whose `state` attribute is exactly `hidden` or `veryHidden` are skipped** (decision: they are not user-visible content; templates keep large lookup lists there). They are skipped at the same point as chart sheets — after the relationship-id checks, before name uniqueness, part resolution, cell materialization and every limit — so their cells never count toward `cellLimit`. A workbook whose sheets are all hidden renders `""` with no sheet names. `sheetNames` (descriptor `sheetCount`) lists exactly the rendered sheets.
- A rendered sheet without rendered cells keeps its heading (`"## Name\n"`), as in v1.
- Rows: ascending row number, one line per row with at least one rendered cell (§3); empty rows are omitted. `rowNumber` is the decimal row of the cell references.
- Cells: ascending column. A cell whose column is not exactly the previous rendered column of the same row plus one — the first cell counts from column 0, so a first cell outside column A — is prefixed with its column name and `=` (`B=`, `AA=`). A run of empty columns therefore collapses to one column marker; dense tables starting in column A carry no markers.
- No header-name prefixing (decision, measured in §9: prefixing every value with its first-row header grows the text by 58–67 %, cancelling most of the gain).

Example (`ingestion/workbook.xlsx`): `## Zeta\nR1: Příliš | C=A😀B\nR2: 42 | TRUE\nR3: 2 | C=2024-01-01\n\n## Alpha\nR1: last`.

## 3. Cell values

The value of a cell, before normalization, by its type `t` (default `n`):

| `t` | value |
|---|---|
| `s` | the shared string (runs `si/t` and `si/r/t` concatenated, unchanged); missing `<v>` → omitted |
| `inlineStr` | the inline string (`is/t`, `is/r/t`) |
| `str`, `d` | the `<v>` text as stored (formula string results; ISO 8601 date cells) |
| `b` | `0` → `FALSE`, `1` → `TRUE`, empty → omitted, anything else → `invalidCell` |
| `e` | **omitted** (error values such as `#N/A`, `#DIV/0!` carry no searchable content) |
| `n` | empty → omitted; a date-formatted cell (§6) renders §5 when that yields text, else §4; a value that is not a renderable number (§4 returns nothing) renders its raw `<v>` text |

Formulas are never evaluated: a formula cell renders its cached value like any other cell of its type, without a marker; a formula without a cached value (or with an empty cached value) is omitted.

**Normalization** of every value: each maximal run of U+0009, U+000A, U+000D, U+0020 becomes one U+0020, then leading and trailing U+0020 are removed. Other characters (including NBSP and every other Unicode space) are unchanged. A value that normalizes to `""` is omitted. Sheet names are not normalized.

## 4. Numbers

Pure decimal-string arithmetic (no binary floating point, no locale):

1. Trim U+0009/U+000A/U+000D/U+0020 at both ends. The rest must match `[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?` exactly, else **not a number**.
2. Exponent: if its digits without leading zeros are more than 5, **not a number**. Mantissa digits `D` = integer digits followed by fraction digits; `n` = number of integer digits. Remove leading zeros of `D` (decrementing `n` per zero), then trailing zeros. If `D` is empty the result is `0` (sign dropped; this precedes step 4's range check). Add the exponent to `n`, so value = 0.D × 10^n.
3. If `D` has more than 15 digits, keep 15 and round half up on the 16th digit (`≥ 5` increments, carrying; an all-nines carry becomes `1` with `n + 1`), then remove trailing zeros. This removes binary float noise (`0.30000000000000004` → `0.3`, `1234.5600000000002` → `1234.56`) at Excel's display precision.
4. If `n` is outside `[-400, 400]`, **not a number**.
5. Layout with `k = |D|` (ECMAScript `Number::toString` thresholds, uppercase `E`): `k ≤ n ≤ 21` → `D` followed by `n − k` zeros; `0 < n ≤ 21` → `D[0..n) "." D[n..)`; `−6 < n ≤ 0` → `"0." (−n zeros) D`; otherwise `D[0] ("." D[1..))? "E" ("+"|"-") |n − 1|`. Prefix `-` for negative values.

Examples: `42.0` → `42`, `-0` → `0`, `.5` → `0.5`, `1e5` → `100000`, `1E+21` → `1E+21`, `1.5E-7` → `1.5E-7`, `1,5` → not a number (rendered raw `1,5`).

## 5. Date serials

For a date-formatted numeric cell; nothing (→ §4 instead) unless the value parses per §4 to a positive number with `n ≤ 7` and integer part `≤ 3,000,000`:

1. Split the rounded decimal (§4 steps 1–3) into integer part `I` and fraction digits `F` (`m` digits). Fraction seconds: `0` if `F` is empty or `n ≤ −6`; else `round_half_up(F × 86400 / 10^m)` computed exactly in integers (`F × 864` divided by `10^(m−2)` for `m ≥ 2`; `F × 86400 / 10` for `m = 1`).
2. `total = I × 86400 + seconds`; `day = total div 86400`, `sod = total mod 86400`; clock = `HH:MM`, plus `:SS` when the seconds are non-zero.
3. `day = 0` → the clock alone (time-of-day values, both date systems).
4. Date system from `workbook.xml` `workbookPr/@date1904` (`1` or `true` → 1904; anything else, or absent → 1900). 1900: day 1–59 → 1899-12-31 + day; day 60 → `1900-02-29` (Excel's fictional leap day); day > 60 → 1899-12-30 + day. 1904: 1904-01-01 + day. Proleptic Gregorian civil arithmetic.
5. A year above 9999 → nothing. Otherwise `YYYY-MM-DD`, followed by `" " clock` when `sod > 0`.

Zero, negative and out-of-range serials therefore render as numbers. Every date/time-classified format renders this way, including elapsed-time formats (`[h]:mm` with 1.5 → `1900-01-01 12:00`) — a documented simplification.

## 6. Date formats and styles

Only numeric cells with a non-empty value consult styles. A cell's style index is its `s` attribute, or `0` when absent.

1. If no such cell exists, styles are not read. Otherwise, if the workbook has no `styles` relationship and no cell of a rendered sheet carries an `s` attribute, no cell is a date. Otherwise exactly one `styles` relationship is required (`invalidRelationship`).
2. Each used style index must exist in `styleSheet/cellXfs/xf` (`invalidCell`); its `numFmtId` defaults to `0`.
3. `numFmtId < 164`: built-in date formats are 14–22, 27–36, 45–47, 50–58. `numFmtId ≥ 164`: the `numFmts/numFmt` with that id must exist exactly once (`invalidCell`); its `formatCode` is a date format when, scanning left to right and skipping quoted literals (`"…"`) and the character after `\`, `_` or `*`, either a bracket `[…]` holds one or more repetitions of a single letter `h`, `m` or `s` (case-insensitive; elapsed time), or a letter `y m d h s` (case-insensitive) appears outside brackets. Other brackets (colors, conditions) are skipped; an unterminated bracket ends the scan (not a date). `E` is never a date token.

(These rules unify the two v1 readers, which differed for cells without `s`, missing custom formats and bracket runs such as `[hhh]`.)

## 7. Limits and errors (unchanged semantics)

`cellLimit` counts every materialized `<c>` of rendered sheets before any text is retained, exactly as v1. `textLimit` applies to the retained raw values exactly as v1 and to the rendered v2 text (`maxExtractedChars` scalars). All structural errors (`invalidCell`, `invalidRelationship`, `corruptArchive`, …) are unchanged; a non-numeric `t="n"` value is no longer an error on Windows (it renders raw on both platforms).

## 8. Revisions and the WP4 detector

Every XLSX/XLSM revision produced under this contract stores `source_revisions.text_format_version = 2` (`SpreadsheetText.formatVersion`); every other kind keeps `1`. Storage accepts both values. Revisions published under v1 stay valid and searchable; `ingestion-reextract-v1.md` §7 replaces them.

The language detector (`lang-detector-v1`) and the scalar chunker (v2) run on the canonical text unchanged. The detector discards digits and punctuation; v2 removes the per-cell one-letter column words (`A`, `B`, `AA` from `A1:`) and the English marker words (`formula`, `cached`, `date`, `serial`) that v1 injected into every document, so detector input is strictly closer to the user's words. Rows are newline-separated and the chunker's whitespace-preferring cut works as before.

## 9. Measurement

`python3 tools/contracts/gen_xlsx_fixtures.py --measure` (chunker v2: 2,048-scalar windows, 256 overlap):

| Synthetic workbook | v1 chars | v2 chars | v1 chunks | v2 chunks | saved | v2 + header names |
|---|---|---|---|---|---|---|
| form template (form + 120-row formula grid + hidden lookup) | 48,593 | 5,444 | 28 | 3 | 89 % | 8,924 |
| template with 1,200-row grid, 600-row hidden lookup | 457,088 | 52,085 | 256 | 29 | 89 % | 86,885 |
| dense data table (400 × 8, dates, float noise) | 66,086 | 43,994 | 37 | 25 | 32 % | 69,594 |
| sparse report (2 cells per row, scattered columns) | 6,055 | 5,049 | 4 | 3 | 25 % | 5,109 |

## 10. Superseded v1 fixture cases

The v1 fixtures stay byte-identical. `ingestion-xlsx-v2.json` carries `supersedes: {fixtureFile: {caseName | relPath: replacementExpected}}` for exactly the cases whose expected XLSX text changed: `ingestion-office-v1` (9 extract cases), `ingestion-ooxml-v1` (3), `ingestion-formats-v1` (`extract-xlsm`) and `release-integration-v1` (asset `sheets/workbook.xlsx`, `canonicalText`). Test harnesses on both platforms apply the replacement to exactly those cases; every other v1 case (all error cases, limits, packaging) still runs against its frozen expectation. The generator fails if a v1 fixture gains or loses an XLSX text case without a matching supersession entry.
