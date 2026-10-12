# Indexed file formats and default extensions — normative contract v1

*Status: 2026-10-10. Fixture: `Tests/fixtures/contracts/ingestion-formats-v1.json` (assets in `Tests/fixtures/ingestion/formats/`). Executable reference: `tools/contracts/gen_mail_fixtures.py` (`--check` must pass). Swift (`SourceType.detect`, `FolderRules.defaults`, `FolderDefaultsUpgrade`) and C# (`SourceTypeExtensions.Detect`, `FolderRules.Defaults`, `FolderDefaultsUpgrade`) must reproduce every case. Companion of `ingestion-mail-v1.md`; extends `folder-rag-v1.md` without changing it; no schema change.*

## 1. Extension → kind

Detection uses the ASCII-lowercased extension after the last `.` of the file name; a name whose only dot is the leading one (`.eml`) has no extension. Unknown extensions are not detected (folder files with an unknown included extension read as `text`, unchanged).

| Extensions | Kind |
|---|---|
| `pdf` | `pdf` |
| `txt` | `text` |
| `md`, `markdown` | `markdown` |
| `docx`, `docm` | `docx` |
| `pptx`, `pptm` | `pptx` |
| `xlsx`, `xlsm` | `xlsx` |
| `eml`, `msg` | `email` (`ingestion-mail-v1.md`) |

Legacy binary formats (`doc`, `xls`, `xlsb`) and templates (`dotm`, …) are not supported.

## 2. Macro-enabled OOXML

`.docm`, `.pptm` and `.xlsm` packages are read by the same bounded OOXML reader as their macro-free kind. Their main part differs only in its content type (e.g. `application/vnd.ms-excel.sheet.macroEnabled.main+xml`); the reader resolves the main part through the package `officeDocument` relationship and never consults content types. The VBA project (`vbaProject.bin`, relationship type `…/vbaProject`) is never extracted, parsed or executed: no reader follows that relationship. Its declared size still counts toward the package's `maxOfficeDecompressedBytes` preflight like every other member. The canonical text, descriptor `type` and source `type` equal those of the macro-free kind.

## 3. Default include extensions

`FolderRules.defaults.includeExts` (and the set of extensions a folder rule may include) is

`["pdf","txt","md","markdown","docx","pptx","xlsx","docm","pptm","xlsm","eml","msg"]`.

## 4. One-time upgrade of existing folders

The previous default was `["pdf","txt","md","markdown","docx","pptx","xlsx"]`. On store open, after all migrations, `FolderDefaultsUpgrade` runs once per database, in one write transaction, recorded by the marker row `grdb_migrations.identifier = 'data_folder_include_exts_v2'` (a data upgrade outside the numbered migration list; GRDB and the Windows migrator ignore unknown identifiers). If the marker exists, or `folder_sources` does not exist yet, nothing happens (the marker is written only when the table exists). Otherwise, for every folder in ascending id order:

1. A folder is upgraded only when its stored `include_exts` JSON array is a permutation of the old default (same elements, same count). Any other list — subsets, supersets, duplicates, unparsable JSON — is a user customization and stays unchanged.
2. Upgraded folders store the new default as compact JSON (`["pdf",…,"msg"]`).
3. Inventory rows of the folder with `kind='skipped'`, `skip_reason='unsupported_ext'` whose extension is one of the added `docm pptm xlsm eml msg` are reclassified like a rule change: `skip_reason='over_limit'` when `size_bytes` exceeds the folder's `maxFileBytes` (an unparsable limits document leaves the row to the next scan), else `kind='eligible'`, `skip_reason=NULL` (an observed file awaiting extraction, `folder-rag-v1` §7).
4. A folder scan job (`kind='scan'`, `target='folder:<id>'`, options `{"verifyAll":false}`, immediately due) is queued unless one is already queued — the same as an applied rule change. The scan classifies every file against the stored rules on every pass, so previously skipped files become sources even though their mtime/size are unchanged (an unknown path is always hashed).

The fixture's `upgrade` cases give a stored list and the list after the upgrade.
