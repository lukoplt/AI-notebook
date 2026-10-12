# WP1 — Multilingual Eval Assets Implementation Plan

> **For independent Codex workers:** Execute the numbered tasks in separate worktrees, starting each from its dependencies' merged commits. Touch only the files in that task's **Files** list. Do not invoke skills. Checkbox steps are mandatory, including the red test run. This document is a plan; no implementation is included in the planning commit.

**Goal:** Check in 44 original, license-clean cs/sk/en/de/mixed documents and 144 queries; validate exact revision/occurrence gold on both platforms; extend `ainotebook-eval` and add a portable Windows console runner with the same versioned JSON and Markdown reports, separate lexical/hybrid/candidate recall, and an injectable packed-evidence measurement boundary for WP8.

**Architecture:** A shared asset contract and adversarial fixtures precede two platform tracks. Pure Core code loads, validates and scores immutable canonical text. A small diagnostic method in each existing retriever exposes its two branches and their complete union without changing the legacy search API. Each runner builds a disposable in-memory store. Eval retains canonical scalar spans alongside stored chunk IDs until WP3/WP5 provide production spans. The existing English runner path remains supported. WP1 measures retrieval, not generated answers, detector quality, production ingestion, or the WP7 performance gate.

**Tech Stack:** Swift 6, Foundation, CryptoKit, XCTest, existing GRDB store; .NET 10 console, System.Text.Json, SHA256, xUnit, existing Microsoft.Data.Sqlite store; Python 3 standard library for deterministic fixture generation/checks. No new package dependency or networking implementation.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md:254` (§9), master plan `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md:39`, `docs/contracts/folder-rag-v1.md:57` (canonical text/spans), `docs/contracts/lang-detector-v1.md:376` (owned held-out examples). Format exemplar: `docs/superpowers/plans/2026-10-09-wp0-contracts.md:1`.

## Global Constraints

- TDD on both platforms: add the specified tests, run red, implement, run the filtered tests green, then the complete affected suite. Never remove assertions or regenerate expected output from the implementation under test to obtain green.
- Shared contracts are consumed through `Tests/AINotebookCoreTests/SharedFixtures.swift:12` and `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs:8`. Their APIs and existing contract files are not changed. New JSON files obey `Tests/fixtures/README.md:6`: envelope, integer version, unique case names, UTF-8 without BOM, LF, integer arithmetic.
- No edits to production extractors, migrations, App/UI/localization, `VERSION`, version constants, detector tables, or the WP0 generator. v19 belongs to WP3. New networking, if later needed, belongs under `Providers/`; these tasks only call existing embedding adapters. All Windows connection access remains inside the existing store gate.
- Preserve the existing English CLI and gold policy (`eval/README.md:34`, `Sources/RetrievalEvalRunner/main.swift:71`, `:336`): whitespace-insensitive phrase matching and exactly one matching chunk. Its `--embedder lexical` is the existing hashing embedder (`main.swift:98`), **not** a BM25 measurement. New multilingual `--mode lexical` means no embedding calls.
- Do not change existing `RetrievalEval.run`/`EvalReport`: their empty-gold policy is incompatible with absence queries (`Sources/AINotebookCore/RetrievalEval.swift:65`). Introduce separate multilingual types.
- WP0 review decisions override stale text in the checked-in contracts. In particular: BM25/metadata/neighbours/map/Overview use `published_revision_id`; vectors use each active manifest revision and are empty without an active generation; hydrate a hit's own revision. This WP's disposable fixture store has exactly one immutable revision per document and an explicitly named legacy backend, so it does not implement or certify those SQL rules.
- The packed hook receives retained spans, including the actual sentence-prefix end after truncation. `E == 0` means an empty measured pack, not an unavailable hook; truncated-away gold earns no credit. WP8 implements actual prefix costs, redistribution and map-share cap. WP1 does not implement budget allocation.
- Overview labels distinguish `(folder_id, dir)`; null folder group first, then numeric folder ID, scalar directory/path order, source ID last. `files_in_scope` and candidates with published chunks remain distinct. No detector-based retrieval filtering. Searchable and refresh freshness are separate WP6 measurements, not an inferred eval count.
- No changes to citations, glob/API-root rules, leases or Unicode tables. Consumers must retain WP0's whole-document citation rejection, pinned simple lowercase, authority validation, fenced leases and determinism fixes. No SQLite/library version is written into shared fixture bytes; diagnostic versions may be printed at runtime. The WP1 generator does no Unicode-category classification.
- Corpus text is newly written for this repository, with fictional organizations/people/amounts, no copied contracts or web material. It is held out from detector training and tuning. Provenance explicitly names Codex-assisted original authorship, MIT repository license, creation date, and no external sources; do not label it Tatoeba or CC0.
- No UI tasks are needed: there are no views, bindings, XAML changes or localization keys in this WP.
- Every task's commit uses a final trailer `Co-Authored-By: Codex <noreply@openai.com>`. Use explicit paths, not `git add .`. Leave the worktree clean. Full suites at the planning baseline: **381 Swift, 450 Windows Core, zero failures/skips** on 2026-10-09; implementation workers record their own starting counts because WP0 fixes are concurrent.

## File Structure

All unmarked paths below are **new**. Existing files are marked **modify** and grounded at their current insertion point. New paths have no current line number.

| Task | File(s) | Responsibility |
|---|---|---|
| 1A | `eval/multilingual/README.md`, `PROVENANCE.md`, `manifest.json`, `queries.json`, `documents/**` (exact inventory below) | Original assets, stable IDs, encoding, scope, hashes and labels |
| 1A | `tools/eval/update_eval_hashes.py`, `tools/eval/test_eval_assets.py` | Corpus hash generation/check and authoring QA |
| 1B | `Tests/fixtures/contracts/eval-assets-v1.json`, `eval-retrieval-v1.json`, `eval-report-v1.json`, `eval-cli-v1.json` | Validator failures, branch/metric/packing cases, report shape and CLI cases |
| 1B | `tools/eval/gen_eval_fixtures.py`, `tools/eval/test_eval_contracts.py`, `tools/eval/compare_reports.py` | Reproducible contract fixtures and report comparison |
| 1A | **modify** `eval/README.md:6` and `:12` | Both runner commands; deterministic tests in CI, live runs opt-in |
| 2 | `Sources/AINotebookCore/EvalCorpus.swift`, `Tests/AINotebookCoreTests/EvalCorpusTests.swift` | Swift DTOs, canonical decoding/hash, scope, validator, scalar windows |
| 3 | `windows/src/AINotebook.Core/Eval/EvalCorpus.cs`, `windows/tests/AINotebook.Core.Tests/Eval/EvalCorpusTests.cs` | Windows equivalent |
| 3 | **modify** `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj:36` | Copy actual multilingual corpus into test output |
| 4 | **modify** `Sources/AINotebookCore/Retriever.swift:114` and `:141`; new `RetrievalCandidates.swift`, `EvalMetrics.swift`, `EvalReportV1.swift` under `Sources/AINotebookCore/` | Diagnostic candidates, gold-span scoring, report writer |
| 4 | `Tests/AINotebookCoreTests/EvalRetrievalTests.swift`, `EvalMetricsTests.swift`, `EvalReportV1Tests.swift` | Swift branch/metric/report fixtures |
| 5 | **modify** `windows/src/AINotebook.Core/Rag/Retriever.cs:90` and `:119`; new `Models/RetrievalCandidates.cs`, `Eval/EvalMetrics.cs`, `Eval/EvalReportV1.cs` under Windows Core | Windows diagnostic API, scorer and writer |
| 5 | `windows/tests/AINotebook.Core.Tests/Eval/EvalRetrievalTests.cs`, `EvalMetricsTests.cs`, `EvalReportV1Tests.cs` | Windows branch/metric/report fixtures |
| 6 | **modify** `Sources/RetrievalEvalRunner/main.swift:55`, `:234`; new `Sources/AINotebookCore/EvalRunner.swift`, `Tests/AINotebookCoreTests/EvalRunnerTests.swift` | Multilingual CLI dispatch and testable orchestration |
| 7 | `windows/tools/AINotebook.Eval/AINotebook.Eval.csproj`, `Program.cs`, `packages.lock.json`; new `windows/src/AINotebook.Core/Eval/EvalRunner.cs`, `windows/tests/AINotebook.Core.Tests/Eval/EvalRunnerTests.cs` | Portable net10.0 runner and orchestration |

Execution DAG: **1A → 1B → (2 ∥ 3) → platform-local 4/5 → platform-local 6/7**. References to “Task 1” below mean the completed 1A+1B shared stage. More precisely 4 needs 1B+2, 5 needs 1B+3, 6 needs 1B+2+4, 7 needs 1B+3+5. All Swift tasks may overlap any Windows task whose dependencies are present. Tasks 1A/1B own all shared assets/docs/scripts; later tasks never rewrite them. No `Package.swift` edit is needed (`:46` already discovers the Swift runner). No solution/App project edit is needed for the direct Windows project command. The WP gate changes no files.

### Task 1A: [Shared] Author the corpus, provenance and asset QA

**Depends on:** WP0 contracts plus the binding review decisions in the assignment. **Parallel with:** none within WP1; WP2/WP3/WP8 may proceed on their own files.

**Files:** Only Task 1A paths in the table; `documents/**` is restricted to the inventory below. Do not modify existing contract fixtures or generators.

**Interfaces — Consumes:** Shared envelope rules at `Tests/fixtures/README.md:6`; scope wire representation from `docs/contracts/folder-rag-v1.md:9`; canonical decoded plain text and scalar offsets at `:59`. Swift `SharedFixtures.data(_ relativePath: String) throws -> Data`; C# `SharedFixtures.Json(string relativePath) -> JsonElement`.

**Interfaces — Produces (same wire format for BOTH platforms):** The following schemas and Task 2/3 APIs. JSON keys are snake_case except the existing `scope` object (`kind`, `sourceIds`, `folderIds`), which retains WP0's spelling. Numbers/IDs are decimal integers; IDs are positive and at most `2^53-1`. `document_id` and `query_id` are ASCII stable keys, unrelated to database IDs. Do not rename IDs when text changes.

| Wire object | Exact required fields | Swift property types / C# property types |
|---|---|---|
| manifest | `contract="eval-corpus"`, `version=1`, `corpus_id="multilingual-v1"`, `license="MIT"`, `documents` | `[EvalDocument]` / `IReadOnlyList<EvalDocument>` |
| document | `document_id`, `source_id`, `notebook_id`, `folder_id` (nullable), `path`, `rel_path`, `language`, `encoding`, `raw_sha256`, `content_hash` | String/string for text; Int64/long IDs; Int64?/long? folder |
| query file | `contract="eval-queries"`, `version=1`, `corpus_id`, `queries` | `[EvalQuestion]` / `IReadOnlyList<EvalQuestion>` |
| question | `query_id`, `text`, `language`, `case_type`, `tags`, `notebook_id`, `scope`, `gold`, `absent_reason` (nullable), `overview_document_ids` | String/string text, `[String]`/`IReadOnlyList<string>` arrays; `RetrievalScope` on both; `[EvalGold]`/`IReadOnlyList<EvalGold>` |
| gold | `document_id`, `content_hash`, `phrase`, `occurrence` | String/string, Int/int occurrence |
| resolved gold | `document_id`, `content_hash`, `start`, `end` | `EvalSpan` (String,String,Int,Int) / `EvalSpan` (string,string,int,int) |

`path` is relative to `eval/multilingual/`; e.g. `documents/cs/customer/contracts/master.md`. `rel_path` is relative to the fixture folder root; equal relative paths across different folders are intentional. `source_id` is a fixture identity used by scope JSON and is translated to actual store IDs at ingestion. `notebook_id` is also translated, never assumed to equal an allocated row ID. Folder membership comes solely from the manifest; do not infer it from the path or language.

Gold `content_hash = lowercase SHA256(UTF8(canonical_text))`; `raw_sha256 = lowercase SHA256(file_bytes)`. Canonical text is strictly decoded bytes, **without trimming, case folding, newline conversion, Unicode normalization or BOM removal**. Corpus source files contain no BOM and use LF, including a final LF. Encoding is exactly `utf-8` or `windows-1250`. Occurrence is **one-based among all exact scalar substring starts**, including overlaps. `ababa`/`aba` occurrence 2 resolves to `[2,5)`. A supplied hash must equal the document's recomputed hash before locating a phrase.

Allowed `case_type` values are exactly `answer`, `exact_identifier`, `scope`, `absent`, `empty_selection`, `overview`; `mixed` and `cp1250` are tags, so those dimensions can overlap case types. Freeze document/query ID and corpus ID grammar as `[a-z0-9][a-z0-9-]*`. Query ID uniqueness is per corpus, source ID uniqueness is across both fixture notebooks.

- [ ] **Step 1: Add the red asset test before the assets or generator.** `tools/eval/test_eval_assets.py` uses `unittest`, locating the repository from `Path(__file__).resolve().parents[2]`. Write these tests, then run the command below:

```python
import hashlib
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'eval/multilingual'

class EvalAssetsTests(unittest.TestCase):
    def test_real_corpus(self):
        m = json.loads((BASE / 'manifest.json').read_text(encoding='utf-8'))
        qs = json.loads((BASE / 'queries.json').read_text(encoding='utf-8'))['queries']
        self.assertEqual(44, len(m['documents']))
        self.assertEqual(144, len(qs))
        self.assertEqual(44, len({d['document_id'] for d in m['documents']}))
        self.assertEqual(144, len({q['query_id'] for q in qs}))
        counts = {lang: sum(d['language'] == lang for d in m['documents'])
                  for lang in ('cs', 'sk', 'en', 'de', 'mixed')}
        self.assertEqual({'cs': 10, 'sk': 10, 'en': 10, 'de': 10, 'mixed': 4}, counts)
        by_id = {}
        for d in m['documents']:
            raw = (BASE / d['path']).read_bytes()
            text = raw.decode(d['encoding'], errors='strict')
            self.assertEqual(hashlib.sha256(raw).hexdigest(), d['raw_sha256'])
            self.assertEqual(hashlib.sha256(text.encode('utf-8')).hexdigest(), d['content_hash'])
            self.assertTrue(text.endswith('\n'))
            self.assertNotIn('\r', text)
            by_id[d['document_id']] = (d, text)
        for q in qs:
            for g in q['gold']:
                d, text = by_id[g['document_id']]
                self.assertEqual(d['content_hash'], g['content_hash'], q['query_id'])
                starts = [i for i in range(len(text)) if text.startswith(g['phrase'], i)]
                self.assertTrue(g['phrase'])
                self.assertGreaterEqual(g['occurrence'], 1)
                self.assertLessEqual(g['occurrence'], len(starts), q['query_id'])
                s = q['scope']
                selected = (s['kind'] == 'all' or d['source_id'] in s['sourceIds']
                            or d['folder_id'] in s['folderIds'])
                self.assertTrue(d['notebook_id'] == q['notebook_id'] and selected)
        self.assertEqual(4, sum(q['case_type'] == 'absent' for q in qs))
        self.assertEqual(4, sum(q['case_type'] == 'empty_selection' for q in qs))
        self.assertEqual(4, sum(q['case_type'] == 'overview' for q in qs))

    def test_cp1250_is_real_bytes(self):
        p = BASE / 'documents/cs/customer/technical/legacy/terminal.txt'
        raw = p.read_bytes()
        with self.assertRaises(UnicodeDecodeError):
            raw.decode('utf-8', errors='strict')
        self.assertIn('Příliš žluťoučký kůň', raw.decode('cp1250', errors='strict'))

if __name__ == '__main__':
    unittest.main()
```

Run: `python3 -m unittest discover -s tools/eval -p 'test_eval_assets.py' -v` → **FAIL, FileNotFoundError for manifest/terminal**. Keep the failure evidence in the handoff, not in tracked output files.

- [ ] **Step 2: Write the 44 documents and provenance.** All named people/organizations are fictional. Each document has a title, date, owner, context, the specific facts below, and at least two plausible distracting facts. Invoices may be 120–220 words; other documents 250–500 words. At least eight technical/contract documents must exceed 4096 scalars so sibling chunks are real distractors. Do not generate forty copies of a single sentence template. Author each language naturally; no untranslated English filler in monolingual files. No binary Office/PDF assets are required by WP1: contracts/invoices/notes/technical content is Markdown/plain text, isolating retrieval from extraction.

For each language `L`, use notebook 1; customer folder `10,30,50,70` and supplier folder `20,40,60,80` for cs,sk,en,de respectively. Sources are 101–110, 201–210, 301–310, 401–410. The table gives **every actual path** by combining `documents/L/` with its suffix; the two `master.md` names deliberately collide only by relative path, never by document ID. IDs `cs-01`…`de-10` use the matching numbered row. These fact/identifier assignments are fixed; narrative is original prose written during this task.

| Row/path suffix | Czech facts (cs) | Slovak facts (sk) | English facts (en) | German facts (de) |
|---|---|---|---|---|
| 01 `customer/contracts/master.md` | Javor observatory cooling; `CS-JAV-241`; 36-hour response | Lipa archive ventilation; `SK-LIP-317`; 48-hour response | Alder workshop lighting; `EN-ALD-482`; 24-hour response | Birke laboratory pumps; `DE-BIR-526`; 30-hour response |
| 02 `supplier/contracts/master.md` | Morava sensors; `CS-MOR-242`; 18-month warranty | Váh seals; `SK-VAH-318`; 20-month warranty | Rowan valves; `EN-ROW-483`; 16-month warranty | Erle filters; `DE-ERL-527`; 22-month warranty |
| 03 `customer/finance/2026/10/invoice.md` | `FA-CS-2026-031`; 18 450 Kč; due 21 October | `FA-SK-2026-041`; 1 260 EUR; due 22 October | `INV-EN-2026-051`; 2 340 GBP; due 23 October | `RE-DE-2026-061`; 3 180 EUR; due 24 October |
| 04 `supplier/finance/2026/10/invoice.md` | `FA-CS-2026-032`; 9 870 Kč; due 28 October | `FA-SK-2026-042`; 845 EUR; due 29 October | `INV-EN-2026-052`; 1 725 GBP; due 30 October | `RE-DE-2026-062`; 2 460 EUR; due 31 October |
| 05 `customer/meetings/2026/kickoff.md` | `ZAP-CS-05`; pilot in room B12 on 4 November | `ZAP-SK-05`; pilot in room C14 on 5 November | `MIN-EN-05`; pilot in room D16 on 6 November | `PRO-DE-05`; pilot in room E18 on 9 November |
| 06 `customer/meetings/2026/risk.md` | `RIZ-CS-06`; spare relay stored in cabinet 7 | `RIZ-SK-06`; spare fuse stored in cabinet 8 | `RISK-EN-06`; spare fan stored in cabinet 9 | `RIS-DE-06`; spare gauge stored in cabinet 10 |
| 07 `supplier/meetings/2026/handover.md` | `PRE-CS-07`; calibration owned by Irena Vrbová | `ODO-SK-07`; calibration owned by Milan Brezový | `HAND-EN-07`; calibration owned by Eva Rowan | `UEB-DE-07`; calibration owned by Lena Hain |
| 08 `customer/technical/runbooks/recovery.md` | `RUN-CS-08`; restore from snapshot K31; check port 4317 | `RUN-SK-08`; restore from snapshot L42; check port 4318 | `RUN-EN-08`; restore from snapshot M53; check port 4319 | `RUN-DE-08`; restore from snapshot N64; check port 4320 |
| 09 `supplier/technical/interfaces/telemetry.md` | `API-CS-09`; `X-Javor-Trace`; retry after 17 seconds | `API-SK-09`; `X-Lipa-Trace`; retry after 19 seconds | `API-EN-09`; `X-Alder-Trace`; retry after 23 seconds | `API-DE-09`; `X-Birke-Trace`; retry after 29 seconds |
| 10 `customer/technical/legacy/terminal.txt` | actual windows-1250; `TERM-CS-10`; baud 19200; include “Příliš žluťoučký kůň” | UTF-8; `TERM-SK-10`; baud 38400; ľ/ĺ/ŕ/ô/ä in prose | UTF-8; `TERM-EN-10`; baud 57600; serial adapter reset sequence | UTF-8; `TERM-DE-10`; baud 115200; umlauts/ß in prose |

Four further documents: `mix-01`/501 at `documents/mixed/customer/meetings/rollout.md` (notebook 1, folder 90, cs/en, `ROLL-501`, Czech readiness decision and English rollback trigger); `mix-02`/502 at `documents/mixed/supplier/contracts/addendum.md` (notebook 1, folder 100, sk/de, `ADD-502`, Slovak delivery clause and German inspection deadline); `mix-03`/503 at `documents/loose/handover.md` (notebook 1, folder null, en/de, `LOOSE-503`, loose handover checklist); `mix-04`/504 at `documents/other-notebook/technical/recovery.md` (notebook 2, folder 110, cs/sk, `OTHER-504`, contradictory snapshot K99 for notebook-isolation queries). Set `rel_path` to `meetings/rollout.md`, `contracts/addendum.md`, `handover.md`, `technical/recovery.md` respectively. Two balanced language sections per mixed document, each ≥150 words. Record the expected document language `mixed`, not an asserted detector output.

Include an exactly repeated complete evidence sentence twice in cs-03; one query labels occurrence 2. Include a supplementary scalar (e.g. a tool emoji) and decomposed `e` + U+0301 before evidence in en-08, preserving its bytes. Gold phrases are shorter than 160 scalars and at least one fact phrase is beyond the first 240 scalars in each long document. Place eight gold spans inside a 256-scalar overlap, so both candidate chunks can correctly cover the same occurrence.

- [ ] **Step 3: Author exactly 144 questions, then calculate hashes.** For each of 44 documents write `ID-paraphrase`, `ID-identifier`, `ID-scope`: 132 queries. Monolingual query `language` matches its source except 16 paraphrases (four per target language) deliberately ask in a different cs/sk/en/de language. Twelve mixed-document questions use cs/sk/en/de, never `language=mixed`. `case_type` is `answer`, `exact_identifier`, or `scope`; add tags `mixed`, `cross_language`, `cp1250`, `repeated_phrase`, `overlap` as applicable. Use natural questions, not keyword bags; identifier queries are the deliberate exact-token exception. Scope questions reuse the paraphrase text on at least four documents so notebook/folder changes have matched controls. Include explicit source-only, folder-only, source+folder union, and loose-source selection. Same-path customer/supplier documents must have different facts and gold.

The other twelve are `absent-cs/sk/en/de` (`gold=[]`, `absent_reason="not_in_corpus"`, e.g. ask for an unrecorded insurance policy number), `empty-cs/sk/en/de` (`scope={"kind":"selection","sourceIds":[],"folderIds":[]}`, `gold=[]`, `absent_reason="empty_scope"`), and `overview-cs/sk/en/de`. Every overview uses notebook 1, one language's two folder IDs, and lists the ten corresponding document IDs in `overview_document_ids`; it has one gold phrase per listed document, all in its first scalar window. That is a coverage target, not a promise the budget packs all ten. Order `overview_document_ids` by the corrected directory round-robin rule; store no expected production selected list until WP8.

Concrete query content to include verbatim (gold phrase must appear in the authored document):

```json
{"query_id":"cs-01-paraphrase","text":"Za jak dlouho se má ozvat servis chlazení observatoře?","language":"cs","case_type":"answer","tags":[],"notebook_id":1,"scope":{"kind":"all"},"gold":[],"absent_reason":null,"overview_document_ids":[]}
```

Write the phrase `servis odpoví do 36 hodin` in cs-01, and after computing document hashes set this question's gold using `q['gold'] = [dict(document_id=d['document_id'], content_hash=d['content_hash'], phrase='servis odpoví do 36 hodin', occurrence=1)]`, where `d` is the manifest's cs-01 document and `q` is the shown question. The example is an authoring input; do not commit an answerable question with empty gold. Its scope variant asks the identical question with `folderIds:[10]`; the counterpart supplier contract does not contain the answer. Every answerable/scope/identifier/mixed question must have ≥1 gold; absent and empty-selection questions must have none. Hashes are generated from final text, never manually invented or silently refreshed during `--check`.

- [ ] **Step 4: Add the hash utility, finish asset QA, then commit.** `update_eval_hashes.py` accepts `--write` or `--check` (default check); recompute each document's raw/canonical SHA with strict decoding, replace each gold hash from its referenced document, and compare canonical JSON bytes with committed files. `--check` exits 1 on any difference and never writes; `--write` is an explicit authoring action. Unknown gold documents fail, never delete a gold item. Serialization: sorted keys, UTF-8, `ensure_ascii=False`, indent 2, final LF. Add an asset test that runs check twice and asserts manifest/query bytes do not change. Add authored-coverage assertions for all seven case tags/types, source/folder/union/empty scope and every required path/encoding.

```bash
python3 tools/eval/update_eval_hashes.py --write
python3 -m unittest discover -s tools/eval -p 'test_eval_assets.py' -v
python3 tools/eval/update_eval_hashes.py --check
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add eval/multilingual eval/README.md tools/eval/update_eval_hashes.py tools/eval/test_eval_assets.py
git commit -m "test(eval): author original multilingual corpus and occurrence gold" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: asset tests pass, check prints `44 documents, 144 queries; corpus hashes current`, existing full suites green. Review language quality, questions/facts, absence claims and provenance before freezing. This session authors assets and a small hash checker; it does not implement the cross-platform adversarial reference harness.

### Task 1B: [Shared] Freeze adversarial, metric, report and CLI contracts

**Depends on:** 1A. **Parallel with:** none within WP1. **Files:** Only Task 1B paths in the File Structure table; the corpus, its QA file and README are read-only in this task.

**Interfaces — Consumes:** Task 1A manifest/query schema; existing fixture envelopes and both SharedFixtures APIs. **Produces:** the four fixture schemas below, consumed by Swift `EvalCorpus.load(manifest:Data,queries:Data,readFile:(String)throws->Data)` / C# `EvalCorpus.Load(byte[],byte[],Func<string,byte[]>)`; Swift `EvalMetrics.measure(gold:lexical:fused:topK:includeVectors:packed:)` / C# `EvalMetrics.Measure(IReadOnlyList<EvalSpan>,IReadOnlyList<EvalSpan>,IReadOnlyList<EvalSpan>,int,bool,IReadOnlyList<EvalSpan>?)`; the exact report/CLI signatures in Tasks 4–7. New APIs are forward contracts, not presumed existing code.

- [ ] **Step 1: Write a failing contract-file test.** In `tools/eval/test_eval_contracts.py`, use unittest to read the four exact new contract paths and assert their contracts/versions, unique case names and counts 27/12/2/6. Add an assertion for overlapping `ababa` occurrence 2 expected `[2,5)`, and report `found=1,total=2,recall_bp=5000`. Run `python3 -m unittest discover -s tools/eval -p 'test_eval_contracts.py' -v` → **FAIL, FileNotFoundError for eval-assets-v1.json**.

- [ ] **Step 2: Implement the deterministic generator/checker.** Exact CLI: `python3 tools/eval/gen_eval_fixtures.py --write` writes the four new contracts; `--check` recomputes and compares bytes without writing. Default is `--check`. Invoke `update_eval_hashes.py --check` to verify the read-only corpus. Sort object keys, `ensure_ascii=False`, indent 2, final LF; arrays retain authored order. No clock, SQLite version, absolute path or Python version enters generated bytes. Print counts/version diagnostics to stdout. Store adversarial input construction and hand-authored expected results in the generator; do not derive expected error codes or expected metric totals from the validator/scorer being tested.

Use this reference occurrence function in the Python checker:

```python
def occurrence_span(text, phrase, occurrence):
    if not phrase or occurrence < 1:
        raise ValueError('invalid_gold')
    starts = [i for i in range(len(text)) if text.startswith(phrase, i)]
    if occurrence > len(starts):
        raise ValueError('occurrence_not_found')
    start = starts[occurrence - 1]
    return {'start': start, 'end': start + len(phrase)}
```

`eval-assets-v1.json` has `{contract:"eval-assets",version:1,cases:[...]}`. Each case contains a complete small `manifest`, `queries` object, `files` map from relative path to raw-byte integer array, and `expected` with nullable string `error` and `spans:[{query_id,document_id,content_hash,start,end}]`. Optional `manifest_json`/`queries_json` strings override the corresponding parsed object; pass their literal UTF-8 bytes to the loader, preserving invalid JSON/number tokens/surrogate escapes. Each invalid case isolates its first failure. Freeze the following **27** cases; derive SHA values from literal bytes while hard-coding span numbers/error codes:

| Cases | Literal input/change | Expected |
|---|---|---|
| `utf8`, `second-occurrence`, `overlapping-occurrence`, `astral-prefix` | `abc\n`/`abc`/1; `abc abc\n`/`abc`/2; `ababa`/`aba`/2; `😀 abc`/`abc`/1 | spans [0,3), [4,7), [2,5), [2,5) |
| `exact-whitespace`, `no-normalization` | `a  b`/`a b`; `é`/`é` | `occurrence_not_found` |
| `cp1250`, `bad-utf8`, `bad-cp1250`, `unsupported-encoding` | bytes for `Příliš`/`Příliš`; `[195,40]`; `[129]`; encoding `latin1` | [0,6); `invalid_encoding`; `invalid_encoding`; `invalid_encoding` |
| `missing-document`, `duplicate-document`, `duplicate-source`, `duplicate-query` | unknown gold ID; duplicate document_id; duplicate source_id; duplicate query_id | `unknown_document`; `duplicate_document`; `duplicate_source`; `duplicate_query` |
| `raw-hash`, `content-hash`, `gold-hash`, `hash-syntax` | each independently altered to 64 zeros; uppercase/nonhex hash | `raw_hash_mismatch`; `content_hash_mismatch`; `gold_hash_mismatch`; `invalid_hash` |
| `empty-phrase`, `zero-occurrence`, `large-occurrence` | `""`; 0; 99 | `invalid_gold`; `invalid_gold`; `occurrence_not_found` |
| `out-of-scope`, `other-notebook` | valid gold excluded by selected folder; valid gold belongs to notebook 2 | `gold_out_of_scope` for both |
| `empty-selection`, `duplicate-relative-path` | valid empty query; equal rel_path in folders 10 and 20 with gold in selected folder 20 | success with [] spans; success with only folder 20 gold |
| `bad-path`, `absent-with-gold` | document path `../outside.txt`; `case_type=absent` with gold | `invalid_path`; `invalid_query` |

Add table-driven subcases under `bad-path` for `/absolute`, `C:/absolute`, backslash, empty component, `.` and `..`; duplicate same-folder rel_path (`invalid_path`); absent file (`missing_file`). Under `utf8`, add a BOM-preservation subcase with bytes EF BB BF 61 and phrase `a` at scalar [1,2). Under `absent-with-gold`, freeze complete subcases for empty gold on answer, nonempty overview IDs on search, unknown scope kind, invalid document/query language, unknown source/folder selection IDs, malformed envelope/version/JSON, empty manifest/query arrays, mismatched corpus IDs, folder ID spanning notebooks, non-ASCII/empty identifiers, invalid/incorrect absent_reason, overview IDs outside selection or without exact gold coverage, and unpaired surrogate escapes (all `invalid_query`). Add nonpositive, >2^53−1, fractional and exponent numeric IDs as raw JSON subcases (`invalid_query`); a repeated identical gold tuple is `invalid_gold`. Under `zero-occurrence`, include occurrence −1 (`invalid_gold`). Keep every subcase a complete case object with its own unique name; both platform loops visit all subcases. No platform task adds or edits shared cases later.

Add a top-level `window_cases` array with three named cases: empty text→[]; `😀abcdéf`, size 4, overlap 1→[(0,4,`😀abc`),(3,7,`cdé`),(6,8,`́f`)]; size 4, overlap 4→`invalid_window`. Both platform window tests read these expected values. This is in addition to the 27 validator cases, not a new contract envelope.

Also place `unknown-query-notebook` under `absent-with-gold`: notebook_id=999 on an otherwise valid absent query with empty gold → `invalid_query`. Every query notebook must exist among manifest documents; an empty selection is represented by its scope, not by inventing a notebook.

`eval-retrieval-v1.json`: each case has `kind="retrieval"` or `"metrics"`. Retrieval inputs are `{documents:[{document_id,source_id,notebook_id,folder_id,chunks:[{text,vector}]}],notebook_id,query,query_vector,scope,fetch_k,top_k,include_vectors,rrf_k}`; expected is `{lexical,vector,fused,embedding_calls}`, each branch an array of `{document_id,ordinal}`. Metrics inputs are `{gold,lexical,fused,top_k,include_vectors,packed}` (arrays of EvalSpan, packed nullable); expected is the complete five-metric map. Freeze **12** cases: disjoint branches (fetch 1, union 2); same-hit dedup; equal-score stable ID tie; folder restriction before branch limit; other-notebook exclusion; empty selection with zero embed calls; lexical-only with zero embed calls; gold occurrence 2 not occurrence 1; overlap earns once; wrong hash earns zero; packed suffix omitted earns zero; measured empty pack versus absent hook. Use `fox on shelf` and `vector target` with vectors [0,1]/[1,0] and query vector [1,0] for the disjoint case. Expected lexical=[first], vector=[second], fused=[first,second]; topK=1 misses second, full candidate pool finds it. Under disjoint-branches include named subcases for fetch_k=0, rrf_k=0 (`invalid_fetch_k`), bad vector count/nonfinite/dimension (`invalid_embedding`); encode nonfinite mock values as string sentinel `nan`, decoded only by the test mock, never JSON NaN. All test dispatchers visit subcases. `measured-empty-pack` has the absent-hook version as a metric subcase.

`eval-report-v1.json`: two cases `measured` and `unavailable`, each contains report input, exact expected JSON object, and an `expected_markdown` string. Freeze fields/semantics in Task 4's report contract below. Include a query label containing `|`, LF and `é` to test Markdown escaping, and null metrics to test unavailable rendering. Include two positive search queries with two total gold items and one recovered item (5000 bp); absent/empty/overview rows must not enter that denominator.

`eval-cli-v1.json`: six cases: default multilingual lexical (16/32); explicit 2/4; topK=0 rejected; fetchK<topK rejected; unknown flag rejected; lexical with model argument rejected. Each contains `args` array and expected decoded options or `error="usage"`. All new-mode flags and expected strings are specified in Tasks 6/7. Legacy CLI is covered separately by its real smoke command.

Under `unknown-flag`, freeze named complete subcases for repeated flags, missing values, missing ollama model, empty model/path, invalid authority/port/userinfo/query/fragment/control/inner whitespace, and valid prefixed host `https://localhost/ollama`. Both CLI test loops recurse through subcases. The prefix case expects options.host to retain that root; a separate pure adapter-URI assertion proves Windows resolves `api/embed` to `https://localhost/ollama/api/embed` after its trailing-slash adaptation. No live HTTP call is made in this test.

- [ ] **Step 3: Complete reference checks and report comparator.** In `test_eval_contracts.py`, independently check exact scalar spans/hashes for valid validator cases, the 12 cases' pure integer ranking/metric arithmetic, contract envelopes, raw-invalid-input preservation, and generator `--check` determinism. Expected error codes remain authored expectations to be exercised by both Core validators; do not build a third full production validator in Python. `compare_reports.py MAC.json WIN.json [--ignore-platform]` parses JSON, optionally removes only `platform`, then recursively compares; it exits 1 and prints the first differing JSON path on mismatch. It must not erase missing metrics, candidate order or query rows. Unit-test that changing a denominator fails comparison. Keep report timing fields null in WP1, making offline parity deterministic.

Run:

```bash
python3 tools/eval/gen_eval_fixtures.py --write
python3 -m unittest discover -s tools/eval -p 'test_eval_assets.py' -v
python3 -m unittest discover -s tools/eval -p 'test_eval_contracts.py' -v
python3 tools/eval/gen_eval_fixtures.py --check
python3 tools/eval/gen_eval_fixtures.py --check
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
```

Expected: Python green; both checks print `44 documents, 144 queries; eval fixtures current`; shared envelopes pass; both full suites green, no skipped tests. Human review checks facts answer questions in all four languages, occurrence-2 label points to its intended context, no accidental answer to absence questions, paths cross directories/folders/notebooks as labelled, and provenance contains no external text. Asset hashes prove exact bytes, not the semantic truth of the questions.

- [ ] **Step 4: Commit.**

```bash
git add Tests/fixtures/contracts/eval-assets-v1.json Tests/fixtures/contracts/eval-retrieval-v1.json Tests/fixtures/contracts/eval-report-v1.json Tests/fixtures/contracts/eval-cli-v1.json tools/eval/gen_eval_fixtures.py tools/eval/test_eval_contracts.py tools/eval/compare_reports.py
git commit -m "test(eval): freeze shared validator metric report and CLI contracts" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

### Task 2: [Swift] Strict corpus loader, gold validator and scalar spans

**Depends on:** 1. **Parallel with:** 3, 5, 7 (when their dependencies are present).

**Files:** Create `Sources/AINotebookCore/EvalCorpus.swift`, `Tests/AINotebookCoreTests/EvalCorpusTests.swift`. Read-only grounding: `SharedFixtures.swift:7`, `Source.swift:73`, `Chunker.swift:16` (trimming/Character offsets explain the separate eval windows), `RetrievalScope.swift:1`. No existing source changes.

**Interfaces — Consumes:** `SharedFixtures.data(_:) throws -> Data`, `.json(_:) throws -> [String:Any]`; `RetrievalScope.all`/`.selection(sourceIds:Set<Int64>,folderIds:Set<Int64>)`.

**Interfaces — Produces (Swift; C# twin is Task 3):**

```swift
public struct EvalFailure: Error, Equatable, Sendable {
    public let code: String
    public init(_ code: String) { self.code = code }
}
public struct EvalSpan: Codable, Hashable, Sendable {
    public let documentId: String
    public let contentHash: String
    public let start: Int
    public let end: Int
    public init(documentId: String, contentHash: String, start: Int, end: Int) {
        self.documentId = documentId; self.contentHash = contentHash
        self.start = start; self.end = end
    }
}
public struct EvalWindow: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let text: String
}
// EvalDocument/EvalGold/EvalQuestion are Codable, Equatable, Sendable structs
// with public immutable properties spelled by Task 1's complete field table.
// Property spelling: documentId, sourceId, notebookId, folderId, relPath,
// rawSha256, contentHash, queryId, caseType, absentReason, overviewDocumentIds.
public struct LoadedEvalDocument: Sendable {
    public let metadata: EvalDocument
    public let text: String
}
public struct EvalCorpus: Sendable {
    public let corpusId: String
    public let documents: [LoadedEvalDocument]
    public let questions: [EvalQuestion]
    public let gold: [String: [EvalSpan]] // queryId -> ordered resolved gold
    public static func load(manifest: Data, queries: Data,
        readFile: (String) throws -> Data) throws -> EvalCorpus
    public static func decode(_ bytes: Data, encoding: String) throws -> String
    public static func sha256(_ bytes: Data) -> String
    public static func occurrence(in text: String, phrase: String,
        number: Int) throws -> Range<Int>
    public static func windows(_ text: String, size: Int = 2048,
        overlap: Int = 256) throws -> [EvalWindow]
    public static func safeRelativePath(_ path: String) -> Bool
    public func selectedDocuments(for question: EvalQuestion) -> [LoadedEvalDocument]
}
```

C# equivalent signatures frozen here: `EvalCorpus.Load(byte[] manifest, byte[] queries, Func<string,byte[]> readFile)`, `Decode(byte[],string) -> string`, `Sha256(byte[]) -> string`, `Occurrence(string,string,int) -> (int Start,int End)`, `Windows(string,int size=2048,int overlap=256) -> IReadOnlyList<EvalWindow>`, `SafeRelativePath(string) -> bool`, `SelectedDocuments(EvalQuestion) -> IReadOnlyList<LoadedEvalDocument>`. Both expose `CorpusId/Documents/Questions/Gold` with equivalent content.

- [ ] **Step 1: Write the fixture and real-corpus tests.** Use this actual fixture test; process each case and each optional `subcases` entry using the same `check` method (subcases contain complete case objects).

```swift
import Foundation
import XCTest
@testable import AINotebookCore

final class EvalCorpusTests: XCTestCase {
    private func check(_ c: [String: Any]) throws {
        let expected = try XCTUnwrap(c["expected"] as? [String: Any])
        let files = try XCTUnwrap(c["files"] as? [String: [Int]])
        let name = try XCTUnwrap(c["name"] as? String)
        func bytes(_ key: String) throws -> Data {
            if let raw = c[key + "_json"] as? String { return Data(raw.utf8) }
            return try JSONSerialization.data(withJSONObject: c[key]!)
        }
        do {
            let corpus = try EvalCorpus.load(
                manifest: bytes("manifest"), queries: bytes("queries"),
                readFile: { path in
                    guard let bytes = files[path] else { throw EvalFailure("missing_file") }
                    return Data(bytes.map { UInt8($0) })
                })
            XCTAssertTrue(expected["error"] is NSNull, name)
            let wanted = try XCTUnwrap(expected["spans"] as? [[String: Any]])
            XCTAssertEqual(corpus.gold.values.reduce(0) { $0 + $1.count }, wanted.count, name)
            for s in wanted {
                let g = EvalSpan(documentId: s["document_id"] as! String,
                    contentHash: s["content_hash"] as! String,
                    start: s["start"] as! Int, end: s["end"] as! Int)
                XCTAssertTrue(corpus.gold[s["query_id"] as! String, default: []].contains(g), name)
            }
        } catch let error as EvalFailure {
            XCTAssertEqual(error.code, expected["error"] as? String, name)
        }
    }

    func testSharedValidatorCases() throws {
        let cases = try XCTUnwrap(try SharedFixtures.json("contracts/eval-assets-v1.json")["cases"] as? [[String: Any]])
        for c in cases {
            try check(c)
            for sub in c["subcases"] as? [[String: Any]] ?? [] { try check(sub) }
        }
    }

    func testEntireCorpusAndEveryGoldReference() throws {
        let root = SharedFixtures.root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("eval/multilingual")
        let corpus = try EvalCorpus.load(
            manifest: Data(contentsOf: root.appendingPathComponent("manifest.json")),
            queries: Data(contentsOf: root.appendingPathComponent("queries.json")),
            readFile: { try Data(contentsOf: root.appendingPathComponent($0)) })
        XCTAssertEqual(corpus.documents.count, 44)
        XCTAssertEqual(corpus.questions.count, 144)
        for q in corpus.questions where !q.gold.isEmpty {
            XCTAssertEqual(corpus.gold[q.queryId]?.count, q.gold.count, q.queryId)
        }
        for q in corpus.questions where q.caseType == "empty_selection" {
            XCTAssertTrue(corpus.selectedDocuments(for: q).isEmpty)
        }
    }

    func testScalarWindowsRetainExactTextAndOverlap() throws {
        let text = "😀abcdéf"
        let windows = try EvalCorpus.windows(text, size: 4, overlap: 1)
        XCTAssertEqual(windows.map(\.start), [0, 3, 6])
        XCTAssertEqual(windows.map(\.end), [4, 7, 8])
        XCTAssertEqual(windows.map(\.text), ["😀abc", "cdé", "́f"])
        XCTAssertThrowsError(try EvalCorpus.windows(text, size: 4, overlap: 4))
    }
}
```

Add `testSharedWindowCases` reading `window_cases` from the same fixture and comparing each start/end/text or exact error code. The literal test above is a readable regression; the shared array drives parity.

Run: `swift test --filter EvalCorpusTests` → **FAIL: missing EvalCorpus/EvalSpan/EvalFailure**. The window example has eight scalars, not seven graphemes or nine UTF-16 units.

- [ ] **Step 2: Implement decoding, hashing, occurrences, paths and windows.** Import CryptoKit in the new file. Use explicit CodingKeys for snake_case DTO keys or one `.convertFromSnakeCase` decoder; the nested WP0 `RetrievalScope` keys stay camelCase. Add public initializers for DTOs used by runner/tests; no runtime dependence on fixture files. The essential pure functions are:

```swift
public static func sha256(_ bytes: Data) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}
public static func decode(_ bytes: Data, encoding: String) throws -> String {
    switch encoding {
    case "utf-8":
        guard String(data: bytes, encoding: .utf8) != nil else { throw EvalFailure("invalid_encoding") }
        // The failable initializer validates, but strips a BOM; preserve it here.
        return String(decoding: bytes, as: UTF8.self)
    case "windows-1250":
        guard let text = String(data: bytes, encoding: .windowsCP1250) else {
            throw EvalFailure("invalid_encoding")
        }
        return text
    default: throw EvalFailure("invalid_encoding")
    }
}
public static func occurrence(in text: String, phrase: String, number: Int) throws -> Range<Int> {
    let haystack = Array(text.unicodeScalars), needle = Array(phrase.unicodeScalars)
    guard !needle.isEmpty, number > 0 else { throw EvalFailure("invalid_gold") }
    guard needle.count <= haystack.count else { throw EvalFailure("occurrence_not_found") }
    var seen = 0
    for start in 0...(haystack.count - needle.count) {
        if haystack[start..<(start + needle.count)].elementsEqual(needle) {
            seen += 1
            if seen == number { return start..<(start + needle.count) }
        }
    }
    throw EvalFailure("occurrence_not_found")
}
public static func safeRelativePath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !path.isEmpty && !path.contains("\\") && !path.contains(":")
        && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}
public static func windows(_ text: String, size: Int = 2048,
                           overlap: Int = 256) throws -> [EvalWindow] {
    guard size > 0, overlap >= 0, overlap < size else { throw EvalFailure("invalid_window") }
    let scalars = Array(text.unicodeScalars)
    var start = 0, result: [EvalWindow] = []
    while start < scalars.count {
        let end = min(start + size, scalars.count)
        result.append(EvalWindow(start: start, end: end,
            text: String(String.UnicodeScalarView(scalars[start..<end]))))
        if end == scalars.count { break }
        start = end - overlap
    }
    return result
}
public func selectedDocuments(for q: EvalQuestion) -> [LoadedEvalDocument] {
    documents.filter { d in
        guard d.metadata.notebookId == q.notebookId else { return false }
        switch q.scope {
        case .all: return true
        case let .selection(sources, folders):
            return sources.contains(d.metadata.sourceId)
                || d.metadata.folderId.map { folders.contains($0) } == true
        }
    }
}
```

Keep `eval-scalars-v1` as this window algorithm's report identifier. It intentionally does no whitespace adjustment, unlike current production `Chunker`; no production chunker changes are authorized here. WP7 switches the runner adapter to published production spans and changes the reported identifier, retaining this deterministic baseline.

- [ ] **Step 3: Implement `load` with this fixed validation order.** Decode the two required envelopes; translate malformed JSON/missing required fields/wrong versions to `EvalFailure("invalid_query")`. Require matching corpus IDs and identifier syntax `[a-z0-9][a-z0-9-]*` for corpus/document/query IDs. Require nonempty question text; paths, hashes, encoding and gold phrase are validated by their specific rules below, so an empty phrase yields `invalid_gold`, not `invalid_query`. Document/query language sets are `{cs,sk,en,de,mixed}` / `{cs,sk,en,de}`. Reject unpaired surrogate escapes rather than allowing a replacement scalar. Preflight arithmetic JSON fields as decimal-integer tokens (no fraction/exponent/boolean), then validate positive JSON-safe IDs and supported case types. Then:

1. Scan manifest order for duplicate document IDs (`duplicate_document`), then duplicate source IDs (`duplicate_source`); scan query order for duplicate query IDs (`duplicate_query`). Check duplicate `(notebook_id,folder_id,rel_path)` only when folder is nonnull, with `Data(relPath.utf8)` as the Swift identity key (C# uses ordinal equality); reject as `invalid_path`. Each folder ID belongs to exactly one notebook (`invalid_query`). Empty manifests/queries are `invalid_query`.
2. Validate safe `path` and `rel_path` before `readFile`, returning `invalid_path`. Validate both document hashes as 64 lowercase ASCII hex characters (`invalid_hash`). `readFile` failures become `missing_file`. Compare raw SHA (`raw_hash_mismatch`), strictly decode (`invalid_encoding`), compare canonical UTF-8 SHA (`content_hash_mismatch`). Store original text and metadata in manifest order.
3. For each question, require its notebook ID to exist among manifest documents; reject unknown scope source/folder IDs and invalid question structure (`invalid_query`). Selection is a union intersected with the question's notebook. Compute selected IDs using the function above, even if that set is empty. Valid absence reason is `not_in_corpus` for absent and `empty_scope` for empty selection; other cases have null reason. Empty selection case must actually select zero IDs. Answer/identifier/scope questions have nonempty gold and no overview IDs; overview has nonempty distinct overview IDs and gold document IDs covering exactly that set. Overview IDs must all be selected. Absent/empty cases have empty gold and no overview IDs. Reject duplicate identical gold tuples (`invalid_gold`).
4. For each gold in authored order: unknown document → `unknown_document`; hash syntax → `invalid_hash`; mismatch with verified document hash → `gold_hash_mismatch`; document outside selection → `gold_out_of_scope`; locate exact occurrence using the code above; append one `EvalSpan`. Do not require that only one chunk covers it. Return **no partial corpus** on error.

Implement the actual gold loop with a verified document dictionary and selected ID set:

```swift
var resolved: [EvalSpan] = []
for g in q.gold {
    guard let doc = byId[g.documentId] else { throw EvalFailure("unknown_document") }
    guard Self.isHash(g.contentHash) else { throw EvalFailure("invalid_hash") }
    guard g.contentHash == doc.metadata.contentHash else { throw EvalFailure("gold_hash_mismatch") }
    guard selectedIds.contains(g.documentId) else { throw EvalFailure("gold_out_of_scope") }
    let span = try Self.occurrence(in: doc.text, phrase: g.phrase, number: g.occurrence)
    resolved.append(EvalSpan(documentId: g.documentId, contentHash: g.contentHash,
                             start: span.lowerBound, end: span.upperBound))
}
gold[q.queryId] = resolved
```

`isHash` is `s.utf8.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }`. Consume all frozen Task 1B subcases before implementing each rule; do not edit shared fixtures. Read closures in additional tests assert unsafe paths are rejected before being called.

- [ ] **Step 4: Green and commit.**

```bash
swift test --filter EvalCorpusTests
swift test
git add Sources/AINotebookCore/EvalCorpus.swift Tests/AINotebookCoreTests/EvalCorpusTests.swift
git commit -m "feat(eval): validate multilingual corpus and exact scalar gold in Swift" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all 27 cases plus their subcases, all 144 real queries, and the window test pass; full suite green. Report XCTest method count separately from fixture case count.

### Task 3: [Windows] Strict corpus loader, gold validator and scalar spans

**Depends on:** 1. **Parallel with:** 2, 4, 6 (when their dependencies are present).

**Files:** Create `windows/src/AINotebook.Core/Eval/EvalCorpus.cs`, `windows/tests/AINotebook.Core.Tests/Eval/EvalCorpusTests.cs`; modify only the corpus content ItemGroup in `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj:36`. Existing `Helpers/SharedFixtures.cs:8` stays unchanged. No Core csproj change is required; .NET 10 includes the code-pages assembly.

**Interfaces — Consumes:** `SharedFixtures.Json(string) -> JsonElement`; `RetrievalScopeJson.Deserialize(string) -> RetrievalScope` (`Rag/RetrievalScope.cs:67`); records `RetrievalScope.All` and `.Selection(IReadOnlySet<long>,IReadOnlySet<long>)`.

**Interfaces — Produces:** namespace `AINotebook.Core.Eval`; public records for the full Task 1 field table, PascalCase properties, `EvalFailure(string code) : Exception` with `string Code`; `EvalSpan(string DocumentId,string ContentHash,int Start,int End)`; `EvalWindow(int Start,int End,string Text)`; `LoadedEvalDocument(EvalDocument Metadata,string Text)`; `EvalCorpus` with read-only `string CorpusId`, `IReadOnlyList<LoadedEvalDocument> Documents`, `IReadOnlyList<EvalQuestion> Questions`, `IReadOnlyDictionary<string,IReadOnlyList<EvalSpan>> Gold`. Exact methods:

```csharp
public static EvalCorpus Load(byte[] manifest, byte[] queries, Func<string, byte[]> readFile);
public static string Decode(byte[] bytes, string encoding);
public static string Sha256(byte[] bytes);
public static (int Start, int End) Occurrence(string text, string phrase, int number);
public static IReadOnlyList<EvalWindow> Windows(string text, int size = 2048, int overlap = 256);
public static bool SafeRelativePath(string path);
public IReadOnlyList<LoadedEvalDocument> SelectedDocuments(EvalQuestion question);
```

Swift twin: `EvalCorpus.load(manifest:Data,queries:Data,readFile:(String)throws->Data) throws -> EvalCorpus`, `decode(_:encoding:)`, `sha256(_:)`, `occurrence(in:phrase:number:) throws -> Range<Int>`, `windows(_:size:overlap:)`, `safeRelativePath(_:)`, `selectedDocuments(for:)` as frozen in Task 2. Windows counts **Runes**, never UTF-16 units.

- [ ] **Step 1: Write red tests and link the actual corpus.** Append this ItemGroup (the existing `Tests/fixtures` link at `:36` already handles the new contracts):

```xml
<ItemGroup>
  <None Include="..\..\..\eval\multilingual\**\*">
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
    <Link>EvalMultilingual\%(RecursiveDir)%(Filename)%(Extension)</Link>
  </None>
</ItemGroup>
```

```csharp
using System.Text.Json;
using AINotebook.Core.Eval;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalCorpusTests
{
    private static void Check(JsonElement c)
    {
        var expected = c.GetProperty("expected");
        var files = c.GetProperty("files");
        byte[] Bytes(string key) => System.Text.Encoding.UTF8.GetBytes(
            c.TryGetProperty(key + "_json", out var raw) ? raw.GetString()! : c.GetProperty(key).GetRawText());
        EvalCorpus? result = null;
        var error = Record.Exception(() => result = EvalCorpus.Load(
            Bytes("manifest"), Bytes("queries"),
            p => files.GetProperty(p).EnumerateArray().Select(b => b.GetByte()).ToArray()));
        if (expected.GetProperty("error").ValueKind != JsonValueKind.Null)
        {
            Assert.Equal(expected.GetProperty("error").GetString(), Assert.IsType<EvalFailure>(error).Code);
            return;
        }
        Assert.Null(error);
        Assert.NotNull(result);
        var spans = expected.GetProperty("spans").EnumerateArray().ToArray();
        Assert.Equal(spans.Length, result.Gold.Values.Sum(g => g.Count));
        foreach (var s in spans)
            Assert.Contains(new EvalSpan(s.GetProperty("document_id").GetString()!,
                s.GetProperty("content_hash").GetString()!, s.GetProperty("start").GetInt32(),
                s.GetProperty("end").GetInt32()), result.Gold[s.GetProperty("query_id").GetString()!]);
    }

    [Fact]
    public void SharedValidatorCases()
    {
        foreach (var c in SharedFixtures.Json("contracts/eval-assets-v1.json").GetProperty("cases").EnumerateArray())
        {
            Check(c);
            if (c.TryGetProperty("subcases", out var subs))
                foreach (var sub in subs.EnumerateArray()) Check(sub);
        }
    }

    [Fact]
    public void EntireCorpusAndEveryGoldReference()
    {
        var root = Path.Combine(AppContext.BaseDirectory, "EvalMultilingual");
        var corpus = EvalCorpus.Load(File.ReadAllBytes(Path.Combine(root, "manifest.json")),
            File.ReadAllBytes(Path.Combine(root, "queries.json")),
            p => File.ReadAllBytes(Path.Combine(root, p)));
        Assert.Equal(44, corpus.Documents.Count);
        Assert.Equal(144, corpus.Questions.Count);
        foreach (var q in corpus.Questions.Where(q => q.Gold.Count > 0))
            Assert.Equal(q.Gold.Count, corpus.Gold[q.QueryId].Count);
        foreach (var q in corpus.Questions.Where(q => q.CaseType == "empty_selection"))
            Assert.Empty(corpus.SelectedDocuments(q));
    }

    [Fact]
    public void ScalarWindowsRetainExactTextAndOverlap()
    {
        var windows = EvalCorpus.Windows("😀abcdéf", size: 4, overlap: 1);
        Assert.Equal(new[] { 0, 3, 6 }, windows.Select(w => w.Start));
        Assert.Equal(new[] { 4, 7, 8 }, windows.Select(w => w.End));
        Assert.Equal(new[] { "😀abc", "cdé", "́f" }, windows.Select(w => w.Text));
        Assert.Throws<EvalFailure>(() => EvalCorpus.Windows("x", 4, 4));
    }
}
```

Add `SharedWindowCases`, reading every `window_cases` input/expected span from the shared fixture and comparing all start/end/text/error fields. Run: `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalCorpusTests` → **FAIL: missing Eval namespace/types**.

- [ ] **Step 2: Implement the pure primitives in the new Core file.**

```csharp
public static string Sha256(byte[] bytes) =>
    Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();

public static string Decode(byte[] bytes, string encoding)
{
    System.Text.Encoding.RegisterProvider(System.Text.CodePagesEncodingProvider.Instance);
    try
    {
        if (encoding == "utf-8") return new System.Text.UTF8Encoding(false, true).GetString(bytes);
        if (encoding != "windows-1250") throw new EvalFailure("invalid_encoding");
        // .NET code pages can map undefined bytes to controls: reject explicitly.
        if (bytes.Any(b => b is 0x81 or 0x83 or 0x88 or 0x90 or 0x98))
            throw new EvalFailure("invalid_encoding");
        return System.Text.Encoding.GetEncoding(1250,
            System.Text.EncoderFallback.ExceptionFallback,
            System.Text.DecoderFallback.ExceptionFallback).GetString(bytes);
    }
    catch (System.Text.DecoderFallbackException) { throw new EvalFailure("invalid_encoding"); }
}

public static (int Start, int End) Occurrence(string text, string phrase, int number)
{
    var haystack = text.EnumerateRunes().ToArray();
    var needle = phrase.EnumerateRunes().ToArray();
    if (needle.Length == 0 || number < 1) throw new EvalFailure("invalid_gold");
    var seen = 0;
    for (var start = 0; start <= haystack.Length - needle.Length; start++)
        if (haystack.AsSpan(start, needle.Length).SequenceEqual(needle) && ++seen == number)
            return (start, start + needle.Length);
    throw new EvalFailure("occurrence_not_found");
}

public static bool SafeRelativePath(string path) =>
    path.Length > 0 && !path.Contains('\\') && !path.Contains(':') &&
    path.Split('/').All(p => p.Length > 0 && p != "." && p != "..");

public static IReadOnlyList<EvalWindow> Windows(string text, int size = 2048, int overlap = 256)
{
    if (size <= 0 || overlap < 0 || overlap >= size) throw new EvalFailure("invalid_window");
    var scalars = text.EnumerateRunes().ToArray();
    var result = new List<EvalWindow>();
    var start = 0;
    while (start < scalars.Length)
    {
        var end = Math.Min(start + size, scalars.Length);
        var b = new System.Text.StringBuilder();
        for (var i = start; i < end; i++) b.Append(scalars[i].ToString());
        result.Add(new(start, end, b.ToString()));
        if (end == scalars.Length) break;
        start = end - overlap;
    }
    return result;
}

public IReadOnlyList<LoadedEvalDocument> SelectedDocuments(EvalQuestion q) =>
    Documents.Where(d => d.Metadata.NotebookId == q.NotebookId && (q.Scope switch
    {
        RetrievalScope.All => true,
        RetrievalScope.Selection s => s.SourceIds.Contains(d.Metadata.SourceId)
            || (d.Metadata.FolderId is long folder && s.FolderIds.Contains(folder)),
        _ => false
    })).ToArray();
```

- [ ] **Step 3: Implement envelope and semantic validation.** Use `JsonDocument` + explicit snake_case field reads (required keys, no missing-to-default conversion); parse scope using the existing codec. Walk all JSON string values with `GetString()` before decoding DTOs, rejecting unpaired surrogate escapes as `invalid_query`; do not let `EnumerateRunes()` replace malformed input. Parse arithmetic fields with `TryGetInt64` and raw token checks for `.`/`e`/`E`; convert offsets/occurrences to int with checked range. Swift load preflight must apply the same decimal-integer rule to these new asset fields; WP0's existing scope codec is not changed.

Validation order is concrete: check envelopes/versions/corpus identity and ASCII identifier syntax `[a-z0-9][a-z0-9-]*`, languages/case types; duplicate document/source/query identities; folder ownership and ordinal duplicate folder-relative paths; path grammar before reads; lowercase hash syntax; raw-byte hash; declared strict decode; canonical-text hash. Then validate query shape, selected IDs and overview coverage, resolve each gold. Error strings are exactly Task 1's table. A read failure becomes `missing_file`; JSON/type errors become `invalid_query`; an `EvalFailure` already raised is preserved, not recategorized. Do not catch exceptions and return an empty corpus. Gold phrase emptiness is deferred to `Occurrence` so its error is `invalid_gold`.

The gold loop is:

```csharp
var resolved = new List<EvalSpan>();
foreach (var g in q.Gold)
{
    if (!byId.TryGetValue(g.DocumentId, out var doc)) throw new EvalFailure("unknown_document");
    if (!IsHash(g.ContentHash)) throw new EvalFailure("invalid_hash");
    if (g.ContentHash != doc.Metadata.ContentHash) throw new EvalFailure("gold_hash_mismatch");
    if (!selectedIds.Contains(g.DocumentId)) throw new EvalFailure("gold_out_of_scope");
    var span = Occurrence(doc.Text, g.Phrase, g.Occurrence);
    resolved.Add(new(g.DocumentId, g.ContentHash, span.Start, span.End));
}
gold[q.QueryId] = resolved;
```

`IsHash` checks exactly 64 ASCII characters in `0..9` or `a..f`. Build dictionaries with `StringComparer.Ordinal`. Validate absence/empty/overview/search shapes exactly as described in Task 2 Step 3, using tests from the shared subcases; no locale operations or detector calls. Every `EvalSpan` stores canonical document/hash identity. No SqliteConnection is needed in this task.

- [ ] **Step 4: Green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalCorpusTests
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Eval/EvalCorpus.cs windows/tests/AINotebook.Core.Tests/Eval/EvalCorpusTests.cs windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj
git commit -m "feat(win-eval): validate multilingual corpus and exact scalar gold" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: 4 primary test methods green, exercising 27 cases/subcases, three shared window cases and every real query; all existing tests green. This content-only csproj edit adds no dependency and must not change existing package lockfiles.

### Task 4: [Swift] Expose branch candidates and implement honest recall/reporting

**Depends on:** 1, 2. **Parallel with:** 3, 5, 7. **Files:** Modify `Sources/AINotebookCore/Retriever.swift:114` (new method) and `:141` (stable SQL tie); create `Sources/AINotebookCore/RetrievalCandidates.swift`, `EvalMetrics.swift`, `EvalReportV1.swift`; create `Tests/AINotebookCoreTests/EvalRetrievalTests.swift`, `EvalMetricsTests.swift`, `EvalReportV1Tests.swift`. Existing `RetrievalEval.swift` and its tests remain unchanged.

**Interfaces — Consumes:** Actual APIs: `Retriever.init(store:NotebookStore,client:EmbeddingProducing,model:String,rrfK:Int=60)` (`Retriever.swift:26`); private `ftsTopK(store:notebookId:query:k:sourceIds:)` (`:117`); `NotebookStore.embeddings(notebookId:model:) throws -> [StoredEmbedding]` (`NotebookStore+Embeddings.swift:33`); `EmbeddingProducing.embed(model:inputs:) async throws -> [[Float]]` (`Embedder.swift:5`); Task 2 `EvalSpan/EvalQuestion`.

**Interfaces — Produces (both platform signatures):**

```swift
public struct RetrievalCandidates: Equatable, Sendable {
    public let lexical: [RetrievalHit]
    public let vector: [RetrievalHit]
    public let fused: [RetrievalHit]
    public init(lexical: [RetrievalHit], vector: [RetrievalHit], fused: [RetrievalHit]) {
        self.lexical = lexical; self.vector = vector; self.fused = fused
    }
}
// New actor method; existing search(sourceIds: []) keeps its legacy ALL behavior.
public func candidates(notebookId: Int64, query: String, fetchK: Int = 32,
    sourceIds: Set<Int64>? = nil, includeVectors: Bool = true) async throws -> RetrievalCandidates

public struct EvalEvidence: Sendable, Equatable {
    public let chunkId: Int64
    public let span: EvalSpan
    public let text: String
    public init(chunkId: Int64, span: EvalSpan, text: String) {
        self.chunkId = chunkId; self.span = span; self.text = text
    }
}
public typealias EvalPackHook = @Sendable (EvalQuestion, [EvalEvidence]) async throws -> [EvalSpan]
public struct EvalMetric: Codable, Equatable, Sendable {
    public let status: String
    public let found: Int?
    public let total: Int?
    public let recallBp: Int?
    public static let unavailable = EvalMetric(status: "not_available", found: nil, total: nil, recallBp: nil)
}
public enum EvalMetrics {
    public static func recall(gold: [EvalSpan], evidence: [EvalSpan]) -> EvalMetric
    public static func aggregate(_ metrics: [EvalMetric]) -> EvalMetric
    public static func measure(gold: [EvalSpan], lexical: [EvalSpan], fused: [EvalSpan],
        topK: Int, includeVectors: Bool, packed: [EvalSpan]?) throws -> [String: EvalMetric]
}
public struct EvalReportV1: Codable, Sendable {
    // Exact stored fields and nested types are specified in the report table below.
    public func jsonData() throws -> Data
    public func markdown() -> String
    public static func assemble(corpus: EvalCorpus, corpusHash: String, platform: String,
        mode: String, model: String?, dimensions: Int?, topK: Int, fetchK: Int,
        rows: [EvalQueryRow], hasPackingHook: Bool) -> EvalReportV1
}
```

Windows counterparts: `Task<RetrievalCandidates> Retriever.CandidatesAsync(long notebookId,string query,int fetchK=32,IReadOnlyCollection<long>? sourceIds=null,bool includeVectors=true,CancellationToken ct=default)`; `EvalEvidence(long ChunkId,EvalSpan Span,string Text)`; `delegate Task<IReadOnlyList<EvalSpan>> EvalPackHook(EvalQuestion question,IReadOnlyList<EvalEvidence> candidates,CancellationToken ct)`; `EvalMetrics.Recall(IReadOnlyList<EvalSpan>,IReadOnlyList<EvalSpan>) -> EvalMetric`; `Aggregate(IEnumerable<EvalMetric>) -> EvalMetric`; `Measure(IReadOnlyList<EvalSpan> gold,IReadOnlyList<EvalSpan> lexical,IReadOnlyList<EvalSpan> fused,int topK,bool includeVectors,IReadOnlyList<EvalSpan>? packed) -> IReadOnlyDictionary<string,EvalMetric>`; `EvalReportV1.JsonBytes() -> byte[]`, `.Markdown() -> string`.

Report assembly twin: `static EvalReportV1 Assemble(EvalCorpus corpus,string corpusHash,string platform,string mode,string? model,int? dimensions,int topK,int fetchK,IReadOnlyList<EvalQueryRow> rows,bool hasPackingHook)`. Define Swift `EvalQueryRow: Codable, Sendable` with public initializer `init(queryId:String,text:String,language:String,caseType:String,status:String,filesInScope:Int,candidatesWithChunks:Int,lexical:[EvalSpan],vector:[EvalSpan],fused:[EvalSpan],metrics:[String:EvalMetric])`; C# `record EvalQueryRow(string QueryId,string Text,string Language,string CaseType,string Status,int FilesInScope,int CandidatesWithChunks,IReadOnlyList<EvalSpan> Lexical,IReadOnlyList<EvalSpan> Vector,IReadOnlyList<EvalSpan> Fused,IReadOnlyDictionary<string,EvalMetric> Metrics)`. Allowed row statuses are exactly `measured` and `deferred_overview_wp8`. `assemble` groups rows, invokes `EvalMetrics.aggregate` by metric name and derives counts/capabilities; it has no dependency on the later `EvalOptions` type.

Report contract (same JSON keys, required even when null):

| Field | Exact value/type and meaning |
|---|---|
| `schema_version`, `corpus_id`, `corpus_hash`, `platform` | 1, manifest ID, SHA256(manifest bytes + single NUL byte + query bytes), `macos`/`windows` |
| `retrieval_version`, `chunker_version`, `mode`, `model`, `dimensions` | `legacy-fts-eval-rrf-v1`, `eval-scalars-v1`, `lexical`/`ollama`, nullable string, nullable positive integer |
| `top_k`, `fetch_k` | positive integers with fetch_k ≥ top_k; fetch_k caps **each** branch |
| `documents`, `queries_total`, `overview_queries`, `absent_queries`, `empty_selection_queries` | counts; all 144 queries have a report row |
| `metrics`, `by_language`, `by_case_type` | `[String:EvalMetric]` / `IReadOnlyDictionary<string,EvalMetric>`; both group fields `[String:[String:EvalMetric]]` / `IReadOnlyDictionary<string,IReadOnlyDictionary<string,EvalMetric>>`; aggregate only measured positive search rows |
| `queries` | array in authored order; each has `query_id`, `text`, `language`, `case_type`, `status`, `files_in_scope`, `candidates_with_chunks`, `lexical`/`vector`/`fused` arrays of EvalSpan, and `metrics` |
| `capabilities` | `{packed_evidence:"not_available",overview:"not_available"}` for default runner; packed becomes `measured` only if hook supplied |
| `timing` | `{warm_retrieval_ms:null,end_to_end_ms:null,cold_cache_ms:null}` until WP7 supplies correctly bounded measurements |

Metric names: `lexical_recall_at_top_k`, `lexical_recall_at_fetch_k`, `hybrid_recall_at_top_k`, `candidate_recall_at_fetch_k`, `packed_evidence_recall`. Each metric is `{status,found,total,recall_bp}`. `found/total` are pooled **gold evidence item counts** (micro recall), not queries or chunks. Basis points = floor(10000×found/total). Per-query empty gold → `{status:"not_applicable",found:0,total:0,recall_bp:null}`; omit these rows from aggregate denominators. Unavailable hybrid/packing → all numerical fields null, `status="not_available"`. Lexical mode still measures candidate recall over its only enabled branch, and reports hybrid unavailable. Overview metrics are all not_applicable, query `status="deferred_overview_wp8"`; never feed overview text to the ordinary search and call it an overview measurement.

`fused` is the **full union** (≤2×fetchK), not `prefix(fetchK)`. Hybrid topK is a diagnostic rank cut before WP8 diversity/packing. Never describe it as user-visible packed recall. For absent queries, record candidates but make no claim about answer abstention/citation correctness; WP1 generates no answers. Empty selection must have zero candidates/provider calls and `files_in_scope=0`. At this fixture baseline `candidates_with_chunks` is the count of selected documents with ≥1 scalar window, not the number of retrieved chunks. Future production Overview counts published-chunk documents here.

- [ ] **Step 1: Add the red branch test.**

```swift
import XCTest
@testable import AINotebookCore

private actor EvalQueryEmbedder: EmbeddingProducing {
    private(set) var calls = 0
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        calls += 1
        return inputs.map { _ in [1, 0] }
    }
}

@MainActor
final class EvalRetrievalTests: XCTestCase {
    func testFetchKRetainsFullUnionAndLexicalMakesNoEmbeddingCall() async throws {
        let store = try NotebookStore(path: .inMemory)
        let nb = try store.createNotebook(name: "Eval branches").id!
        let src = try store.createSource(notebookId: nb, type: .text, title: "doc", uri: nil, rawPath: nil).id!
        try store.replaceChunks(sourceId: src, chunks: [
            ChunkDraft(text: "fox on shelf", tokenCount: 3),
            ChunkDraft(text: "vector target", tokenCount: 2)])
        let chunks = try store.chunks(sourceId: src)
        try store.storeEmbedding(chunkId: chunks[0].id!, model: "m", vector: EmbeddingVector(values: [0, 1]))
        try store.storeEmbedding(chunkId: chunks[1].id!, model: "m", vector: EmbeddingVector(values: [1, 0]))
        let client = EvalQueryEmbedder()
        let r = Retriever(store: store, client: client, model: "m")
        let hits = try await r.candidates(notebookId: nb, query: "fox", fetchK: 1)
        XCTAssertEqual(hits.lexical.map(\.chunkId), [chunks[0].id!])
        XCTAssertEqual(hits.vector.map(\.chunkId), [chunks[1].id!])
        XCTAssertEqual(hits.fused.map(\.chunkId), chunks.map { $0.id! })
        let before = await client.calls
        let lexical = try await r.candidates(notebookId: nb, query: "fox", fetchK: 1, includeVectors: false)
        XCTAssertTrue(lexical.vector.isEmpty)
        XCTAssertEqual(lexical.fused.count, 1)
        let empty = try await r.candidates(notebookId: nb, query: "fox", sourceIds: [])
        XCTAssertTrue(empty.fused.isEmpty)
        let after = await client.calls
        XCTAssertEqual(before, after)
    }
}
```

Also write `testSharedRetrievalCases`: decode each of the 12 fixture inputs, create sources/chunks in fixture order, map fixture document/ordinal keys to allocated IDs, store supplied vectors, call `candidates` with resolved IDs, and compare each branch's mapped identities to the fixture arrays. Cases about metric-only spans execute in `EvalMetricsTests`, with an assertion that every fixture case was dispatched once. No live embedding service is used.

Run: `swift test --filter EvalRetrievalTests` → **FAIL: Retriever has no candidates**.

- [ ] **Step 2: Add diagnostics, reusing the existing locked/MainActor store APIs.** Leave `search`'s body and its legacy empty-array semantics intact. The new method uses this body; change only the private FTS helper's SQL order to `ORDER BY bm25(chunks_fts), sc.id ASC` for reproducible ties:

```swift
guard fetchK > 0, rrfK > 0 else { throw EvalFailure("invalid_fetch_k") }
if sourceIds?.isEmpty == true { return RetrievalCandidates(lexical: [], vector: [], fused: []) }
let key = modelKey() // snapshot once across await
let storeRef = store
var vector: [RetrievalHit] = []
if includeVectors {
    let values = try await client.embed(model: key, inputs: [query])
    guard values.count == 1, let qv = values.first, !qv.isEmpty,
          qv.allSatisfy(\.isFinite), qv.contains(where: { $0 != 0 })
    else { throw EvalFailure("invalid_embedding") }
    let stored = try await MainActor.run { try storeRef.embeddings(notebookId: notebookId, model: key) }
    let eligible = stored.filter { sourceIds == nil || sourceIds!.contains($0.sourceId) }
    guard eligible.allSatisfy({ $0.vector.values.count == qv.count
        && $0.vector.values.allSatisfy(\.isFinite) && $0.vector.values.contains(where: { $0 != 0 }) })
    else { throw EvalFailure("invalid_embedding") }
    vector = eligible.map {
        RetrievalHit(chunkId: $0.chunkId, sourceId: $0.sourceId,
            score: Cosine.similarity(qv, $0.vector.values), snippet: "")
    }.sorted { $0.score == $1.score ? $0.chunkId < $1.chunkId : $0.score > $1.score }
    vector = Array(vector.prefix(fetchK))
}
let scopedIds = sourceIds ?? []
let lexical: [RetrievalHit]
if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    lexical = []
} else {
    let raw = try await MainActor.run {
        try Self.ftsTopK(store: storeRef, notebookId: notebookId, query: query, k: fetchK, sourceIds: scopedIds)
    }
    lexical = raw.enumerated().map { rank, h in
        RetrievalHit(chunkId: h.chunkId, sourceId: h.sourceId,
            score: Float(1_000_000 / (rrfK + rank + 1)), snippet: h.snippet)
    }
}
var scores: [Int64: Int] = [:], rows: [Int64: RetrievalHit] = [:]
for branch in [vector, lexical] {
    for (rank, hit) in branch.enumerated() {
        scores[hit.chunkId, default: 0] += 1_000_000 / (rrfK + rank + 1)
        rows[hit.chunkId] = hit
    }
}
let fused = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
    .map { id, score in
        let h = rows[id]!
        return RetrievalHit(chunkId: id, sourceId: h.sourceId, score: Float(score), snippet: h.snippet)
    }
return RetrievalCandidates(lexical: lexical, vector: vector, fused: fused)
```

Integer micro-RRF follows `folder-rag-v1.md:125`; the score converted to Float is an exactly representable small integer. This diagnostic path does not change current production float search behavior; WP5 replaces that path. `rrfK` must be positive (validate for this method), and the report identifies current quoted-phrase FTS (`Retriever.swift:179`), not future WP5 OR-tokenized FTS. Empty vector-only snippets are acceptable here: eval scores full retained canonical spans, never snippets. Add tests for invalid query-vector count/nonfinite/dimension and fetchK=0, then run red/green for these new branches.

- [ ] **Step 3: Write red scorer tests, then implement the pure scorer.**

```swift
final class EvalMetricsTests: XCTestCase {
    func testOccurrenceIdentityOverlapAndTruncatedPack() throws {
        let hash = String(repeating: "a", count: 64)
        let first = EvalSpan(documentId: "d", contentHash: hash, start: 0, end: 3)
        let second = EvalSpan(documentId: "d", contentHash: hash, start: 4, end: 7)
        let full = EvalSpan(documentId: "d", contentHash: hash, start: 0, end: 8)
        XCTAssertEqual(EvalMetrics.recall(gold: [second], evidence: [first]).recallBp, 0)
        XCTAssertEqual(EvalMetrics.recall(gold: [second], evidence: [full, full]).found, 1)
        let scores = try EvalMetrics.measure(gold: [second], lexical: [first],
            fused: [first, full], topK: 1, includeVectors: true, packed: [first])
        XCTAssertEqual(scores["hybrid_recall_at_top_k"]?.recallBp, 0)
        XCTAssertEqual(scores["candidate_recall_at_fetch_k"]?.recallBp, 10000)
        XCTAssertEqual(scores["packed_evidence_recall"]?.recallBp, 0)
        let absent = EvalMetrics.recall(gold: [], evidence: [full])
        XCTAssertEqual(absent.status, "not_applicable")
        XCTAssertNil(absent.recallBp)
        XCTAssertEqual(EvalMetrics.aggregate([absent, scores["candidate_recall_at_fetch_k"]!]).total, 1)
    }
}
```

Run `swift test --filter EvalMetricsTests` → **FAIL: EvalMetrics missing**. Implement:

```swift
public static func recall(gold: [EvalSpan], evidence: [EvalSpan]) -> EvalMetric {
    guard !gold.isEmpty else { return EvalMetric(status: "not_applicable", found: 0, total: 0, recallBp: nil) }
    let found = gold.filter { g in
        evidence.contains { e in
            e.documentId == g.documentId && e.contentHash == g.contentHash
                && e.start <= g.start && e.end >= g.end
        }
    }.count
    return EvalMetric(status: "measured", found: found, total: gold.count,
                      recallBp: 10000 * found / gold.count)
}
public static func aggregate(_ metrics: [EvalMetric]) -> EvalMetric {
    let measured = metrics.filter { $0.status == "measured" }
    let found = measured.reduce(0) { $0 + ($1.found ?? 0) }
    let total = measured.reduce(0) { $0 + ($1.total ?? 0) }
    if total > 0 { return EvalMetric(status: "measured", found: found, total: total, recallBp: 10000 * found / total) }
    if metrics.contains(where: { $0.status == "not_available" }) { return .unavailable }
    return EvalMetric(status: "not_applicable", found: 0, total: 0, recallBp: nil)
}
public static func measure(gold: [EvalSpan], lexical: [EvalSpan], fused: [EvalSpan],
    topK: Int, includeVectors: Bool, packed: [EvalSpan]?) throws -> [String: EvalMetric] {
    guard topK > 0 else { throw EvalFailure("invalid_top_k") }
    return [
        "lexical_recall_at_top_k": recall(gold: gold, evidence: Array(lexical.prefix(topK))),
        "lexical_recall_at_fetch_k": recall(gold: gold, evidence: lexical),
        "hybrid_recall_at_top_k": includeVectors ? recall(gold: gold, evidence: Array(fused.prefix(topK))) : .unavailable,
        "candidate_recall_at_fetch_k": recall(gold: gold, evidence: fused),
        "packed_evidence_recall": packed.map { recall(gold: gold, evidence: $0) } ?? .unavailable
    ]
}
```

Add `testSharedMetricCases` using the span inputs and expected integer values from all metric cases in `eval-retrieval-v1.json`. Explicitly compare absent hook (nil) against measured empty pack (`[]`, found 0/positive total), wrong content hash, repeated occurrence, two overlapping retrieved chunks and sentence-truncated suffix. All pass using the exact same fixture values as C#.

- [ ] **Step 4: Write report golden tests first.** Add `EvalReportV1Tests.testSharedReports`, decode each `eval-report-v1.json` case's `input` as `EvalReportV1`, call `jsonData` and compare JSON structurally with `expected_json` using NSDictionary equality; compare `markdown()` to `expected_markdown` exactly including final LF. Run `swift test --filter EvalReportV1Tests` → missing report type/methods. Then implement the report DTO fields from the table and writer.

`jsonData()` uses sorted JSON keys and explicit null fields (custom Encodable `encode(optional,forKey:)`, not `encodeIfPresent`, for all optional metric/model/timing fields). `JSONDecoder`/`JSONEncoder` snake-case strategies must not rewrite metric dictionary keys. No Date/current working directory/provider host is serialized. Sort grouped language/case keys by ASCII; query rows retain input order. Build the Markdown header with this concrete Swift code (C# interpolates the identical fields with invariant integers):

```swift
var lines = [
    "# Multilingual retrieval eval v1", "",
    "Corpus: \(corpusId) (\(documents) documents, \(queriesTotal) queries)",
    "Backend: \(retrievalVersion); chunker: \(chunkerVersion); mode: \(mode)",
    "topK: \(topK); fetchK per branch: \(fetchK)",
    "Recall aggregation: micro (pooled gold evidence items).", "",
    "| metric | found | total | recall bp | status |",
    "|---|---:|---:|---:|---|"
]
```

Emit five metric rows in the metric-name order listed above; absent numeric values render `—`, never `0`. Follow with a blank line and `| query | text | status | lexical bp | hybrid bp | candidate bp | packed bp |`, separator `|---|---|---|---:|---:|---:|---:|`, then query rows. Escape backslash to `\\`, pipe to `\|`, CR/LF to space, in that order; preserve Unicode. Follow rows with a blank line and two footnote sentences verbatim, one per line: `Candidate recall uses the full union of the per-branch fetchK lists.` and `Unavailable packing/overview measurements are not scores; WP8 supplies those adapters.` Join lines with LF and append exactly one final LF. These fixed bytes are Task 1's Markdown gold, without process/platform-specific time.

- [ ] **Step 5: Verify and commit.**

```bash
swift test --filter 'EvalRetrievalTests|EvalMetricsTests|EvalReportV1Tests'
swift test
git add Sources/AINotebookCore/Retriever.swift Sources/AINotebookCore/RetrievalCandidates.swift Sources/AINotebookCore/EvalMetrics.swift Sources/AINotebookCore/EvalReportV1.swift Tests/AINotebookCoreTests/EvalRetrievalTests.swift Tests/AINotebookCoreTests/EvalMetricsTests.swift Tests/AINotebookCoreTests/EvalReportV1Tests.swift
git commit -m "feat(eval): expose retrieval branches and versioned evidence recall reports" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: branch union contains two candidates at fetchK=1; all shared metrics/report golds pass; legacy retrieval tests stay green. No claim that legacy natural-language BM25 recall is high: low recall is a valid baseline for WP5.

### Task 5: [Windows] Branch candidates, evidence recall and identical report format

**Depends on:** 1, 3. **Parallel with:** 2, 4, 6. **Files:** Modify `windows/src/AINotebook.Core/Rag/Retriever.cs:90` and `:119`; create `windows/src/AINotebook.Core/Models/RetrievalCandidates.cs`, `Eval/EvalMetrics.cs`, `Eval/EvalReportV1.cs`; create three tests `windows/tests/AINotebook.Core.Tests/Eval/{EvalRetrievalTests,EvalMetricsTests,EvalReportV1Tests}.cs`.

**Interfaces — Consumes:** `NotebookStore.Embeddings(long,string)` (`Storage/NotebookStore.Embeddings.cs:25`) returns a materialized list under `_gate`; `Retriever.FtsTopK`/`Snippets` lock `_store.Gate` (`Rag/Retriever.cs:96`, `:146`); `IEmbeddingProducing.EmbedAsync(string,IReadOnlyList<string>,CancellationToken)` (`Ollama/ChatTurn.cs:15`); `EvalCorpus`/`EvalSpan` from Task 3. No direct new connection access.

**Interfaces — Produces:** `public sealed record RetrievalCandidates(IReadOnlyList<RetrievalHit> Lexical,IReadOnlyList<RetrievalHit> Vector,IReadOnlyList<RetrievalHit> Fused)` under `Models`; exact `CandidatesAsync`, metric and hook signatures in Task 4's dual-platform interface block. `EvalMetric(string Status,int? Found,int? Total,int? RecallBp)` with static `Unavailable`; `EvalReportV1` has the complete fields/nested objects in the report table, `byte[] JsonBytes()` and `string Markdown()`. Swift consumers use the parallel `candidates(notebookId:query:fetchK:sourceIds:includeVectors:)`, `EvalMetrics.recall/aggregate/measure`, `EvalReportV1.jsonData/markdown`; no Swift implementation dependency.

- [ ] **Step 1: Add red branch tests with the existing mock.**

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.Core.Tests.Helpers;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalRetrievalTests
{
    [Fact]
    public async Task FetchKRetainsUnionAndLexicalMakesNoEmbeddingCall()
    {
        using var store = new NotebookStore(StorePath.InMemory);
        var nb = store.CreateNotebook("eval").Id!.Value;
        var src = store.CreateSource(nb, SourceType.Text, "doc", null, null).Id!.Value;
        store.ReplaceChunks(src, new[] { new ChunkDraft("fox on shelf", 3), new ChunkDraft("vector target", 2) });
        var chunks = store.Chunks(src);
        store.StoreEmbedding(chunks[0].Id!.Value, "m", new EmbeddingVector(new[] { 0f, 1f }));
        store.StoreEmbedding(chunks[1].Id!.Value, "m", new EmbeddingVector(new[] { 1f, 0f }));
        var client = new MockEmbeddingClient(_ => new[] { 1f, 0f });
        var retriever = new Retriever(store, client, "m");
        var hybrid = await retriever.CandidatesAsync(nb, "fox", fetchK: 1);
        Assert.Equal(chunks[0].Id!.Value, Assert.Single(hybrid.Lexical).ChunkId);
        Assert.Equal(chunks[1].Id!.Value, Assert.Single(hybrid.Vector).ChunkId);
        Assert.Equal(chunks.Select(c => c.Id!.Value), hybrid.Fused.Select(h => h.ChunkId));
        var calls = client.Calls.Count;
        var lexical = await retriever.CandidatesAsync(nb, "fox", fetchK: 1, includeVectors: false);
        Assert.Empty(lexical.Vector);
        Assert.Single(lexical.Fused);
        var empty = await retriever.CandidatesAsync(nb, "fox", sourceIds: Array.Empty<long>());
        Assert.Empty(empty.Fused);
        Assert.Equal(calls, client.Calls.Count);
    }
}
```

Add `SharedRetrievalCases` loading `SharedFixtures.Json("contracts/eval-retrieval-v1.json")`, ingesting explicit fixture documents/vectors and comparing branch document/ordinal identities. Validate restriction **before** fetch limit with the folder fixture (an out-of-scope best vector must not crowd out the in-scope second vector). Check another notebook is excluded, and no provider call happens with an empty scope. Track dispatch of all 12 cases across this class and the metric class.

Run: `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalRetrievalTests` → **FAIL: CandidatesAsync absent**.

- [ ] **Step 2: Implement the new method, keeping SearchAsync unchanged.** Add `using AINotebook.Core.Eval;`; append this complete method before existing SQL helpers and add `, sc.id ASC` to the FTS ORDER BY:

```csharp
public async Task<RetrievalCandidates> CandidatesAsync(long notebookId, string query,
    int fetchK = 32, IReadOnlyCollection<long>? sourceIds = null,
    bool includeVectors = true, CancellationToken ct = default)
{
    if (fetchK <= 0 || RrfK <= 0) throw new EvalFailure("invalid_fetch_k");
    ct.ThrowIfCancellationRequested();
    if (sourceIds is { Count: 0 }) return new([], [], []);
    var model = Model;
    var vector = new List<RetrievalHit>();
    if (includeVectors)
    {
        var embedded = await _client.EmbedAsync(model, new[] { query }, ct);
        if (embedded.Length != 1 || embedded[0].Length == 0 || embedded[0].Any(v => !float.IsFinite(v))
            || embedded[0].All(v => v == 0))
            throw new EvalFailure("invalid_embedding");
        var eligible = _store.Embeddings(notebookId, model)
            .Where(e => sourceIds is null || sourceIds.Contains(e.SourceId)).ToArray();
        if (eligible.Any(e => e.Vector.Values.Length != embedded[0].Length
            || e.Vector.Values.Any(v => !float.IsFinite(v)) || e.Vector.Values.All(v => v == 0)))
            throw new EvalFailure("invalid_embedding");
        vector = eligible.Select(e => new RetrievalHit(e.ChunkId, e.SourceId,
                Cosine.Similarity(embedded[0], e.Vector.Values), ""))
            .OrderByDescending(h => h.Score).ThenBy(h => h.ChunkId).Take(fetchK).ToList();
    }
    var lexical = string.IsNullOrWhiteSpace(query) ? new List<RetrievalHit>() :
        FtsTopK(notebookId, query, fetchK, sourceIds)
            .Select((h, rank) => new RetrievalHit(h.ChunkId, h.SourceId,
                1_000_000 / (RrfK + rank + 1), h.Snippet)).ToList();
    var scores = new Dictionary<long, int>();
    var rows = new Dictionary<long, RetrievalHit>();
    foreach (var branch in new[] { vector, lexical })
        for (var rank = 0; rank < branch.Count; rank++)
        {
            var h = branch[rank];
            scores[h.ChunkId] = scores.GetValueOrDefault(h.ChunkId) + 1_000_000 / (RrfK + rank + 1);
            rows[h.ChunkId] = h;
        }
    var fused = scores.OrderByDescending(p => p.Value).ThenBy(p => p.Key)
        .Select(p => rows[p.Key] with { Score = p.Value }).ToArray();
    return new(lexical, vector, fused);
}
```

Add and run red/green tests for invalid dimensions, nonfinite query values, missing/extra query vector and invalid fetchK. Snapshot `Model` once as above. Code must not hold `_gate` across embedding awaits. The existing helper handles SQL locking. New `sourceIds:null` means all in the specified notebook; `[]` means none. Report `legacy-fts-eval-rrf-v1`, since quoting/FTS tokenizer still precedes WP5 even though new diagnostic fusion uses the normative integer ranks.

- [ ] **Step 3: Write red metric tests and implement.**

```csharp
using AINotebook.Core.Eval;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalMetricsTests
{
    [Fact]
    public void OccurrenceIdentityOverlapAndTruncatedPack()
    {
        var hash = new string('a', 64);
        var first = new EvalSpan("d", hash, 0, 3);
        var second = new EvalSpan("d", hash, 4, 7);
        var full = new EvalSpan("d", hash, 0, 8);
        Assert.Equal(0, EvalMetrics.Recall([second], [first]).RecallBp);
        Assert.Equal(1, EvalMetrics.Recall([second], [full, full]).Found);
        var scores = EvalMetrics.Measure([second], [first], [first, full], 1, true, [first]);
        Assert.Equal(0, scores["hybrid_recall_at_top_k"].RecallBp);
        Assert.Equal(10000, scores["candidate_recall_at_fetch_k"].RecallBp);
        Assert.Equal(0, scores["packed_evidence_recall"].RecallBp);
        var absent = EvalMetrics.Recall([], [full]);
        Assert.Equal("not_applicable", absent.Status);
        Assert.Null(absent.RecallBp);
        Assert.Equal(1, EvalMetrics.Aggregate([absent, scores["candidate_recall_at_fetch_k"]]).Total);
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalMetricsTests` → **FAIL: EvalMetrics absent**. Then add this Core code, plus `SharedMetricCases` comparing every fixture status/count/basis-point field:

```csharp
public static EvalMetric Recall(IReadOnlyList<EvalSpan> gold, IReadOnlyList<EvalSpan> evidence)
{
    if (gold.Count == 0) return new("not_applicable", 0, 0, null);
    var found = gold.Count(g => evidence.Any(e => e.DocumentId == g.DocumentId
        && e.ContentHash == g.ContentHash && e.Start <= g.Start && e.End >= g.End));
    return new("measured", found, gold.Count, checked((int)(10000L * found / gold.Count)));
}
public static EvalMetric Aggregate(IEnumerable<EvalMetric> metrics)
{
    var all = metrics.ToArray();
    var measured = all.Where(m => m.Status == "measured").ToArray();
    var found = measured.Sum(m => m.Found ?? 0);
    var total = measured.Sum(m => m.Total ?? 0);
    if (total > 0) return new("measured", found, total, checked((int)(10000L * found / total)));
    return all.Any(m => m.Status == "not_available") ? EvalMetric.Unavailable : new("not_applicable", 0, 0, null);
}
public static IReadOnlyDictionary<string, EvalMetric> Measure(IReadOnlyList<EvalSpan> gold,
    IReadOnlyList<EvalSpan> lexical, IReadOnlyList<EvalSpan> fused, int topK,
    bool includeVectors, IReadOnlyList<EvalSpan>? packed)
{
    if (topK <= 0) throw new EvalFailure("invalid_top_k");
    return new Dictionary<string, EvalMetric>(StringComparer.Ordinal)
    {
        ["lexical_recall_at_top_k"] = Recall(gold, lexical.Take(topK).ToArray()),
        ["lexical_recall_at_fetch_k"] = Recall(gold, lexical),
        ["hybrid_recall_at_top_k"] = includeVectors ? Recall(gold, fused.Take(topK).ToArray()) : EvalMetric.Unavailable,
        ["candidate_recall_at_fetch_k"] = Recall(gold, fused),
        ["packed_evidence_recall"] = packed is null ? EvalMetric.Unavailable : Recall(gold, packed)
    };
}
```

Packed null means no adapter; packed empty means adapter returned no evidence and must score zero for positive gold. Separate spans must never be widened to their bounding interval, which would incorrectly fill a gap. A phrase split across disjoint packed spans is not fully present in any retained passage and earns no match.

- [ ] **Step 4: Add report gold tests, then implement JSON/Markdown.** `EvalReportV1Tests.SharedReports` reads both `eval-report-v1.json` cases through SharedFixtures, deserializes `input` with `PropertyNamingPolicy=JsonNamingPolicy.SnakeCaseLower`, runs `JsonBytes()`, compares `JsonElement.DeepEquals(actual, expected_json)`, and compares `Markdown()` with `expected_markdown` exactly. Run the filtered class red before adding the report type.

Implement all table fields, retaining explicit nulls with `DefaultIgnoreCondition=Never`; use `Encoder=JavaScriptEncoder.UnsafeRelaxedJsonEscaping` only for JSON serialization of this local data artifact, not HTML. Integer numbers and raw strings must compare structurally with Swift. Use `StringComparer.Ordinal` for grouping/order; preserve query order. Markdown emits the exact header/table/footnotes specified in Task 4 and the shared fixture, with `value?.ToString(CultureInfo.InvariantCulture) ?? "—"`, and text escaping `Replace("\\", "\\\\").Replace("|", "\\|").Replace("\r", " ").Replace("\n", " ")`. Append `\n`, not `Environment.NewLine`, so Windows output is LF too. Add a non-default culture test (cs-CZ) restoring culture in `finally`; expected Markdown bytes remain identical. No machine path, date or endpoint enters a report.

- [ ] **Step 5: Verify and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~EvalRetrievalTests|FullyQualifiedName~EvalMetricsTests|FullyQualifiedName~EvalReportV1Tests'
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Rag/Retriever.cs windows/src/AINotebook.Core/Models/RetrievalCandidates.cs windows/src/AINotebook.Core/Eval/EvalMetrics.cs windows/src/AINotebook.Core/Eval/EvalReportV1.cs windows/tests/AINotebook.Core.Tests/Eval/EvalRetrievalTests.cs windows/tests/AINotebook.Core.Tests/Eval/EvalMetricsTests.cs windows/tests/AINotebook.Core.Tests/Eval/EvalReportV1Tests.cs
git commit -m "feat(win-eval): expose branch candidates and parity evidence recall reports" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all shared cases/gold reports green; empty selection and lexical mode make zero provider calls; full Windows Core suite green. Full App builds are not required for this portable Core-only task.

### Task 6: [Swift] Run multilingual eval through the existing executable

**Depends on:** 1, 2, 4. **Parallel with:** 3, 5, 7. **Files:** Modify only `Sources/RetrievalEvalRunner/main.swift:234` (dispatch before legacy parsing, with help text at `:55`); create `Sources/AINotebookCore/EvalRunner.swift`, `Tests/AINotebookCoreTests/EvalRunnerTests.swift`. The new-mode options parser lives in the new Core file, not in the untestable top-level entry point. Keep the legacy `Options`, fixture decoder, embedders and English flow intact.

**Interfaces — Consumes:** Task 2 corpus loader; Task 4 candidates/metrics/report; current `NotebookStore(path:)`, `createNotebook(name:)`, `createSource(notebookId:type:title:uri:rawPath:)`, `replaceChunks(sourceId:chunks:)`, `chunks(sourceId:)` (grounding `NotebookStore.swift:26`, `:65`; `NotebookStore+Sources.swift:7`, `:81`, `:102`); `storeEmbedding(chunkId:model:vector:)` (`NotebookStore+Embeddings.swift:12`); existing `OllamaClient(baseURL:)` used by current runner at `main.swift:273`.

**Interfaces — Produces:**

```swift
public struct EvalOptions: Equatable, Sendable {
    public let root: String           // default eval/multilingual
    public let mode: String           // lexical | ollama, default lexical
    public let model: String?         // required for ollama, nil for lexical
    public let host: String           // default http://127.0.0.1:11434
    public let topK: Int              // default 16
    public let fetchK: Int            // default 32
    public let jsonPath: String?      // --json
    public let markdownPath: String?  // --out
    public let validateOnly: Bool
    public static func parse(_ args: [String]) throws -> EvalOptions
}
public enum EvalRunner {
    public static func load(root: URL) throws -> (corpus: EvalCorpus, hash: String)
    @MainActor public static func run(corpus: EvalCorpus, corpusHash: String,
        options: EvalOptions, embedder: (any EmbeddingProducing)? = nil,
        pack: EvalPackHook? = nil) async throws -> EvalReportV1
}
```

C# twin: `EvalOptions.Parse(IReadOnlyList<string> args) -> EvalOptions` with equivalent PascalCase fields, `EvalRunner.Load(string root) -> (EvalCorpus Corpus,string Hash)`, `Task<EvalReportV1> EvalRunner.RunAsync(EvalCorpus corpus,string corpusHash,EvalOptions options,IEmbeddingProducing? embedder=null,EvalPackHook? pack=null,CancellationToken ct=default)`. Both parsers accept exactly `--dataset multilingual`, `--root DIR`, `--mode lexical|ollama`, `--model NAME`, `--host URL`, `--top-k N`, `--fetch-k N`, `--json FILE`, `--out FILE`, `--validate-only`. `--help` is handled by the entry point and exits 0. Require `fetchK >= topK > 0`; reject unknown/repeated flags, missing values, empty paths/model, model in lexical mode, or missing model in ollama mode with `EvalFailure("usage")`. `--host` validates scheme/hostname/port/userinfo/control/whitespace with the binding WP0 API-root rules; it does not implement endpoint joining. `validateOnly` loads and validates without initializing a provider or store.

- [ ] **Step 1: Write red parser and integration tests.** `EvalRunnerTests` is `@MainActor`. `testSharedOptions` loops `eval-cli-v1.json`: call `parse(args)`, compare **each** expected property (root/mode/model/host/top_k/fetch_k/json_path/markdown_path/validate_only), or assert `EvalFailure.code == "usage"`. Add a real-corpus helper using `SharedFixtures.root` with the same repository-root calculation used in Task 2.

```swift
@MainActor
final class EvalRunnerTests: XCTestCase {
    private func corpusURL() -> URL {
        SharedFixtures.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("eval/multilingual")
    }

    func testOfflineRunHasAllRowsAndNoInventedHybridOrPackingScore() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try EvalOptions.parse(["--dataset", "multilingual", "--mode", "lexical"])
        let r = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash, options: options)
        XCTAssertEqual(r.documents, 44)
        XCTAssertEqual(r.queriesTotal, 144)
        XCTAssertEqual(r.queries.count, 144)
        XCTAssertEqual(r.metrics["hybrid_recall_at_top_k"]?.status, "not_available")
        XCTAssertEqual(r.metrics["packed_evidence_recall"]?.status, "not_available")
        for q in r.queries where q.caseType == "empty_selection" {
            XCTAssertEqual(q.filesInScope, 0)
            XCTAssertTrue(q.fused.isEmpty)
        }
        XCTAssertEqual(r.queries.filter { $0.status == "deferred_overview_wp8" }.count, 4)
    }

    func testInjectedEmptyPackIsMeasuredZero() async throws {
        let loaded = try EvalRunner.load(root: corpusURL())
        let options = try EvalOptions.parse(["--dataset", "multilingual"])
        let r = try await EvalRunner.run(corpus: loaded.corpus, corpusHash: loaded.hash,
            options: options, pack: { _, _ in [] })
        XCTAssertEqual(r.metrics["packed_evidence_recall"]?.status, "measured")
        XCTAssertEqual(r.metrics["packed_evidence_recall"]?.recallBp, 0)
        XCTAssertGreaterThan(r.metrics["packed_evidence_recall"]?.total ?? 0, 0)
    }
}
```

Run: `swift test --filter EvalRunnerTests` → **FAIL: EvalRunner/EvalOptions absent**. Add further tests before the corresponding implementation: scope-isolation report against the shared branch fixture; wrong batch size/nonfinite embedding fails `invalid_embedding`; two offline runs have identical JSON after removing only `platform`; for each measured metric, summing found/total over by_language and separately over by_case_type equals the global found/total. Parser loops visit all shared subcases. No expected recall threshold is invented for the current FTS query policy.

- [ ] **Step 2: Implement the loader/parser and ingestion adapter.** `load(root:)` reads manifest and queries once, computes `SHA256(manifest + Data([0]) + queries)`, and supplies a file reader to `EvalCorpus.load`. Before reading any document, walk each relative path component from the explicit root and reject symbolic-link components (`URLResourceValues.isSymbolicLink`) as `invalid_path`; the pure loader already rejects lexical escapes. A missing/unreadable file raises `missing_file`. Tests use a temporary symlink inside an owned temporary directory pointing outside that directory and verify it is rejected; no user filesystem traversal.

In `run`, create one store and one database notebook per distinct fixture notebook ID in ascending order. Insert documents in `documentId` ASCII order. Maintain `notebookMap: [Int64:Int64]`, `sourceMap: [Int64:Int64]`, and `evidenceByChunk: [Int64:EvalEvidence]`. Use this exact per-document ingest body:

```swift
let d = loaded.metadata
let source = try store.createSource(notebookId: notebookMap[d.notebookId]!,
    type: d.path.hasSuffix(".txt") ? .text : .markdown, title: d.documentId, uri: nil, rawPath: nil)
let sourceId = source.id!
sourceMap[d.sourceId] = sourceId
let windows = try EvalCorpus.windows(loaded.text)
try store.replaceChunks(sourceId: sourceId, chunks: windows.map {
    ChunkDraft(text: $0.text, tokenCount: max(1, ($0.end - $0.start + 3) / 4))
})
let persisted = try store.chunks(sourceId: sourceId)
guard persisted.count == windows.count else { throw EvalFailure("chunk_mapping") }
for (chunk, window) in zip(persisted, windows) {
    evidenceByChunk[chunk.id!] = EvalEvidence(chunkId: chunk.id!,
        span: EvalSpan(documentId: d.documentId, contentHash: d.contentHash,
            start: window.start, end: window.end), text: window.text)
}
```

Lexical mode stores no vectors and uses a private `NoEvalEmbedding` that throws `EvalFailure("unexpected_embedding")` if ever called. Do not pass `LexicalHashingEmbedder` into the multilingual lexical path. Ollama mode requires the injected `EmbeddingProducing` and nonempty model, batches evidence sorted by chunk ID in groups of 16, and calls the existing provider. Before storing any batch, require output count equals input count, positive consistent dimension, finite values and nonzero vector norm. Failure aborts the run; never silently truncate `zip(inputs, outputs)`. Store the exact same model key later given to the retriever. Declare dimensions null for lexical mode.

- [ ] **Step 3: Implement query execution and the packing boundary.** For every question compute `selected = corpus.selectedDocuments(for:q)`, translate source IDs, and use **explicit** selected IDs (including an empty Set) in `candidates`. This ensures both branches filter before fetch limits. All fixture revisions are immutable, and the per-chunk evidence map retains each hit's canonical identity. Use the following core sequence for every non-overview question:

```swift
let selected = corpus.selectedDocuments(for: q)
let sourceIds = Set(selected.compactMap { sourceMap[$0.metadata.sourceId] })
guard sourceIds.count == selected.count, let notebookId = notebookMap[q.notebookId] else {
    throw EvalFailure("source_mapping")
}
let hits = try await retriever.candidates(notebookId: notebookId,
    query: q.text, fetchK: options.fetchK, sourceIds: sourceIds, includeVectors: options.mode == "ollama")
func hydrate(_ list: [RetrievalHit]) throws -> [EvalEvidence] {
    try list.map { hit in
        guard let e = evidenceByChunk[hit.chunkId], sourceIds.contains(hit.sourceId) else {
            throw EvalFailure("evidence_mapping")
        }
        return e
    }
}
let lexical = try hydrate(hits.lexical)
let vector = try hydrate(hits.vector)
let fused = try hydrate(hits.fused)
let packed: [EvalSpan]?
if let pack {
    packed = sourceIds.isEmpty ? [] : try await pack(q, fused)
} else { packed = nil }
let metrics = try EvalMetrics.measure(gold: corpus.gold[q.queryId]!,
    lexical: lexical.map(\.span), fused: fused.map(\.span), topK: options.topK,
    includeVectors: options.mode == "ollama", packed: packed)
```

Validate hook output before scoring: each span has a selected document ID, that document's canonical hash, `0 <= start < end <= scalarCount`. Invalid output raises `invalid_packed_span`. Separate ranges remain separate; no bounding-box union. Store all three branch span arrays in the report row. Row `status="measured"` denotes that retrieval ran, even when gold recall is not_applicable. For empty selection the retriever returns immediately; for overview bypass retriever and hook, record all metrics not_applicable and `status="deferred_overview_wp8"`. Compute `files_in_scope=selected.count` and `candidates_with_chunks=selected.filter { !text.unicodeScalars.isEmpty }.count` independently.

After all rows, assemble aggregate maps by metric name over positive non-overview questions only; by_language and by_case_type use the same denominator policy and include groups with no positive gold as not_applicable/unavailable. Finish via the Task 4 report constructor. The pack closure captures WP8's concrete model/budget settings when wired later; the scorer is already ready for zero budget, sentence-prefix truncation and own-revision spans. No fake packed score is emitted by the default runner.

- [ ] **Step 4: Wire the executable, retaining the English entry path.** Before current `let opts = parseOptions()` (`main.swift:234`), dispatch when arguments contain `--dataset`. Parse new options; validate/load first; `--validate-only` prints `Validated 44 documents and 144 queries.` for the checked-in corpus and exits 0. Otherwise instantiate `OllamaClient(baseURL: URL(...))` only for explicit ollama mode, call `EvalRunner.run`, print `report.markdown()`, and atomically write requested JSON/Markdown paths. Catch `EvalFailure("usage")` → stderr with usage and exit 2; other corpus/provider/I/O failures → code/message on stderr and exit 1. No success output artifact should be written before the run succeeds. `--help` explains both paths without running either. Legacy calls without `--dataset` proceed through the existing code untouched.

- [ ] **Step 5: Green, offline CLI regression and commit.**

```bash
swift test --filter EvalRunnerTests
swift test
swift run ainotebook-eval --dataset multilingual --root eval/multilingual --validate-only
swift run ainotebook-eval --dataset multilingual --root eval/multilingual --mode lexical --json /tmp/wp1-swift.json --out /tmp/wp1-swift.md
swift run ainotebook-eval --corpus eval/corpus --queries eval/queries.json --embedder lexical --out /tmp/wp1-english.md
git add Sources/RetrievalEvalRunner/main.swift Sources/AINotebookCore/EvalRunner.swift Tests/AINotebookCoreTests/EvalRunnerTests.swift
git commit -m "feat(eval): add multilingual CLI mode while preserving English evaluation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: tests green; validator exits 0 with 44/144; new report has 144 rows, separate lexical/candidate metrics, null hybrid and packed fields, four explicit deferred overview rows; English smoke still ingests 12 documents/30 queries and prints its existing recall/cut-sweep report. CI Core tests already execute the deterministic loader/retrieval/scorer/runner tests; no live Ollama run is added to CI. Optional live manual run (only when a user has a running server/model) is `swift run ainotebook-eval --dataset multilingual --mode ollama --model nomic-embed-text-v2-moe --json /tmp/wp1-swift-live.json`; do not download a model as part of WP1.

### Task 7: [Windows] Add the portable net10.0 benchmark runner

**Depends on:** 1, 3, 5. **Parallel with:** 2, 4, 6. **Files:** Create `windows/src/AINotebook.Core/Eval/EvalRunner.cs`, `windows/tests/AINotebook.Core.Tests/Eval/EvalRunnerTests.cs`, `windows/tools/AINotebook.Eval/AINotebook.Eval.csproj`, `Program.cs`, `packages.lock.json`. No modifications to App/XAML, solution, existing csproj/lockfiles, or platform services.

**Interfaces — Consumes:** Task 3 loader and Task 5 diagnostics/reports; real store APIs `NotebookStore(StorePath.InMemory)`, `CreateNotebook(string,string="")`, `CreateSource(long,SourceType,string,string?,string?)`, `ReplaceChunks(long,IReadOnlyList<ChunkDraft>)`, `Chunks(long)`, `StoreEmbedding(long,string,EmbeddingVector)` (grounding `Storage/NotebookStore.cs:50`, `:145`, `NotebookStore.Sources.cs:20`, `:115`, `:137`, `NotebookStore.Embeddings.cs:8`). Network adapter: `new OllamaEmbeddingAdapter(new OllamaClient(baseUrl: uri))` (`Ollama/OllamaAdapters.cs:9`, `Ollama/OllamaClient.cs:15`). Do not create HttpClient in this runner.

**Interfaces — Produces:** public `EvalOptions` immutable record with Task 6's fields and `static EvalOptions Parse(IReadOnlyList<string> args)`; `static (EvalCorpus Corpus,string Hash) EvalRunner.Load(string root)`; `static Task<EvalReportV1> RunAsync(EvalCorpus corpus,string corpusHash,EvalOptions options,IEmbeddingProducing? embedder=null,EvalPackHook? pack=null,CancellationToken ct=default)`. Swift's exact twins are `EvalOptions.parse(_:)`, `EvalRunner.load(root:)`, `@MainActor EvalRunner.run(corpus:corpusHash:options:embedder:pack:)`. CLI returns 0 success/help, 2 invalid arguments, 1 invalid corpus/provider/I/O. New-mode flags, defaults and JSON/Markdown bytes are identical across platforms. Windows supports the multilingual dataset; existing English support remains in the Swift executable.

- [ ] **Step 1: Write red parser and full-corpus integration tests.** `SharedOptions` loops the six shared CLI cases and compares every option/error field. Use `Helpers.SharedFixtures.Json` for cases and the `EvalMultilingual` output directory for actual assets.

```csharp
using AINotebook.Core.Eval;
using Xunit;

namespace AINotebook.Core.Tests.Eval;

public sealed class EvalRunnerTests
{
    [Fact]
    public async Task OfflineRunHasEveryRowAndNoInventedHybridOrPackingScore()
    {
        var loaded = EvalRunner.Load(Path.Combine(AppContext.BaseDirectory, "EvalMultilingual"));
        var options = EvalOptions.Parse(["--dataset", "multilingual", "--mode", "lexical"]);
        var r = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, options);
        Assert.Equal(44, r.Documents);
        Assert.Equal(144, r.QueriesTotal);
        Assert.Equal(144, r.Queries.Count);
        Assert.Equal("not_available", r.Metrics["hybrid_recall_at_top_k"].Status);
        Assert.Equal("not_available", r.Metrics["packed_evidence_recall"].Status);
        foreach (var q in r.Queries.Where(q => q.CaseType == "empty_selection"))
        {
            Assert.Equal(0, q.FilesInScope);
            Assert.Empty(q.Fused);
        }
        Assert.Equal(4, r.Queries.Count(q => q.Status == "deferred_overview_wp8"));
    }

    [Fact]
    public async Task InjectedEmptyPackIsMeasuredZero()
    {
        var loaded = EvalRunner.Load(Path.Combine(AppContext.BaseDirectory, "EvalMultilingual"));
        var options = EvalOptions.Parse(["--dataset", "multilingual"]);
        var r = await EvalRunner.RunAsync(loaded.Corpus, loaded.Hash, options,
            pack: (_, _, _) => Task.FromResult<IReadOnlyList<EvalSpan>>(Array.Empty<EvalSpan>()));
        Assert.Equal("measured", r.Metrics["packed_evidence_recall"].Status);
        Assert.Equal(0, r.Metrics["packed_evidence_recall"].RecallBp);
        Assert.True(r.Metrics["packed_evidence_recall"].Total > 0);
    }
}
```

Run: `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalRunnerTests` → **FAIL: missing runner/options**. Also add red tests for shared scoped branch inputs, bad vector count/dimensions/nonfinite values, deterministic repeated output, and an internal reparse/symlink component rejected before reading. For each measured metric assert that by_language totals and by_case_type totals each equal global found/total. Parser loops visit all shared subcases. Windows CI may create a directory junction if unprivileged symlink creation is unavailable; the portable macOS Core run uses a symlink. Never skip the pure unsafe-path fixtures.

- [ ] **Step 2: Implement parser, file loader and store adapter in Core.** Explicitly enumerate the accepted flags/defaults from Task 6, reject duplicates/missing values, validate exact positive integer arguments invariantly, reject inconsistent model/mode. Load manifest/query bytes once; corpus hash is SHA256(manifest bytes + 0x00 + query bytes). Reject reparse/symlink components below the supplied root using `File.GetAttributes` and `FileAttributes.ReparsePoint` before document reads; use `Path.Combine(root, relative)` only after `SafeRelativePath` passes. Root may be explicitly selected by the caller; no application package storage APIs.

`RunAsync` owns `using var store = new NotebookStore(StorePath.InMemory)`. Make notebooks in fixture ID order, documents by ASCII document ID, and keep `Dictionary<long,long>` notebook/source maps plus `Dictionary<long,EvalEvidence>`. The full per-document ingestion operation is:

```csharp
var d = loaded.Metadata;
var source = store.CreateSource(notebookMap[d.NotebookId],
    d.Path.EndsWith(".txt", StringComparison.Ordinal) ? SourceType.Text : SourceType.Markdown,
    d.DocumentId, null, null);
var sourceId = source.Id!.Value;
sourceMap[d.SourceId] = sourceId;
var windows = EvalCorpus.Windows(loaded.Text);
store.ReplaceChunks(sourceId, windows.Select(w =>
    new ChunkDraft(w.Text, Math.Max(1, (w.End - w.Start + 3) / 4))).ToArray());
var persisted = store.Chunks(sourceId);
if (persisted.Count != windows.Count) throw new EvalFailure("chunk_mapping");
for (var i = 0; i < persisted.Count; i++)
{
    var chunkId = persisted[i].Id!.Value;
    var w = windows[i];
    evidenceByChunk[chunkId] = new EvalEvidence(chunkId,
        new EvalSpan(d.DocumentId, d.ContentHash, w.Start, w.End), w.Text);
}
```

The store APIs above own their locks; no raw connection is used. Lexical mode uses a private rejecting IEmbeddingProducing and stores no vectors. For explicit ollama mode use only the supplied embedder, group chunk-ID-sorted text into batches of 16, validate one finite nonzero vector per input with a single consistent positive dimension before storing. Use `ct.ThrowIfCancellationRequested()` between batches/questions. Model ID is immutable for the run; partial failed runs write no reports.

- [ ] **Step 3: Implement query execution and report assembly.** For each non-overview query use this sequence:

```csharp
var selected = corpus.SelectedDocuments(q);
var ids = selected.Select(d => sourceMap[d.Metadata.SourceId]).ToArray();
if (ids.Distinct().Count() != selected.Count || !notebookMap.TryGetValue(q.NotebookId, out var notebookId))
    throw new EvalFailure("source_mapping");
var hits = await retriever.CandidatesAsync(notebookId, q.Text,
    options.FetchK, ids, options.Mode == "ollama", ct);
IReadOnlyList<EvalEvidence> Hydrate(IReadOnlyList<RetrievalHit> list) => list.Select(h =>
{
    if (!evidenceByChunk.TryGetValue(h.ChunkId, out var e) || !ids.Contains(h.SourceId))
        throw new EvalFailure("evidence_mapping");
    return e;
}).ToArray();
var lexical = Hydrate(hits.Lexical);
var vector = Hydrate(hits.Vector);
var fused = Hydrate(hits.Fused);
IReadOnlyList<EvalSpan>? packed = pack is null ? null : ids.Length == 0
    ? Array.Empty<EvalSpan>() : await pack(q, fused, ct);
var metrics = EvalMetrics.Measure(corpus.Gold[q.QueryId], lexical.Select(e => e.Span).ToArray(),
    fused.Select(e => e.Span).ToArray(), options.TopK, options.Mode == "ollama", packed);
```

Before `Measure`, validate every returned packed span's selected document/hash and scalar bounds; raise `invalid_packed_span` on failure. Report the full branch arrays and measured retrieval status; absence has no recall denominator. Empty selection sends the explicit empty ID array and zero provider calls. Overview bypasses retrieval/pack and emits `deferred_overview_wp8` with not_applicable metrics. Compute files-in-scope and selected documents with nonempty windows separately. Aggregate each metric's positive non-overview gold counts globally and per query language/case type. Format with the Task 5 report writer and platform value `windows` (implementation identity even when this portable runner executes on macOS). No timing or detector results are fabricated.

- [ ] **Step 4: Add the thin console project and entry point.** Exact project:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>AINotebook.Eval</AssemblyName>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\..\src\AINotebook.Core\AINotebook.Core.csproj" />
  </ItemGroup>
</Project>
```

`Program.cs` imports `AINotebook.Core.Eval` and `.Ollama`, handles help, parses options, loads/validates, and returns early for `--validate-only`. For ollama create `new OllamaEmbeddingAdapter(new OllamaClient(baseUrl: new Uri(options.Host.TrimEnd('/') + "/")))`; for lexical pass null. The trailing slash preserves an API-root path prefix with the existing client's relative `api/embed` URI resolution (`OllamaClient.cs:19`); verify it with the shared prefixed-host case and a pure Uri test. Await `RunAsync`, write Markdown to stdout, and only then write requested UTF-8-without-BOM/LF JSON/Markdown outputs. Write a sibling temporary file then `File.Move(temp, destination, overwrite:true)` for each output. Catch `EvalFailure` with code `usage` → stderr + exit 2; corpus/provider/I/O exceptions → stderr + exit 1. Do not catch and continue with a partial report. Use no Windows-specific target/framework so this project can build/test on the development Mac.

Restore creates `packages.lock.json` because `windows/Directory.Build.props:12` enables lockfiles. Commit only the new project's generated lockfile. Verify locked restore; do not update existing dependency versions or existing locks.

- [ ] **Step 5: Verify and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~EvalRunnerTests
dotnet test windows/tests/AINotebook.Core.Tests
dotnet restore windows/tools/AINotebook.Eval
dotnet restore windows/tools/AINotebook.Eval --locked-mode
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --root eval/multilingual --validate-only
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --root eval/multilingual --mode lexical --json /tmp/wp1-windows.json --out /tmp/wp1-windows.md
git add windows/src/AINotebook.Core/Eval/EvalRunner.cs windows/tests/AINotebook.Core.Tests/Eval/EvalRunnerTests.cs windows/tools/AINotebook.Eval/AINotebook.Eval.csproj windows/tools/AINotebook.Eval/Program.cs windows/tools/AINotebook.Eval/packages.lock.json
git commit -m "feat(win-eval): add portable multilingual benchmark console runner" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all Core tests green; locked restore succeeds; validator prints 44/144 and exits 0; report schema matches Swift with separate lexical and candidate recall and explicit unavailable hybrid/pack. On a Windows shell use `$env:TEMP` output paths; the commands above target the current macOS development environment. Optional live Windows measurement, for WP7 preparation only: `dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --mode ollama --model nomic-embed-text-v2-moe --json /tmp/wp1-windows-live.json`. Real model ranking need not be bit-identical; schema, gold resolution, metric arithmetic and frozen-vector tests must be.

## WP gate

Run from the integration worktree after all eight task commits are merged. This is a verification/review gate, not another file-owning task; do not update the master plan or versions from a WP1 implementation worktree.

```bash
python3 -m unittest discover -s tools/eval -p 'test_eval_*.py' -v
python3 tools/eval/update_eval_hashes.py --check
python3 tools/eval/gen_eval_fixtures.py --check
swift test
dotnet test windows/tests/AINotebook.Core.Tests
dotnet restore windows/tools/AINotebook.Eval --locked-mode
swift run ainotebook-eval --dataset multilingual --validate-only
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --validate-only
swift run ainotebook-eval --dataset multilingual --mode lexical --json /tmp/wp1-swift.json --out /tmp/wp1-swift.md
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --mode lexical --json /tmp/wp1-windows.json --out /tmp/wp1-windows.md
python3 tools/eval/compare_reports.py /tmp/wp1-swift.json /tmp/wp1-windows.json --ignore-platform
cmp /tmp/wp1-swift.md /tmp/wp1-windows.md
swift run ainotebook-eval --corpus eval/corpus --queries eval/queries.json --embedder lexical --out /tmp/wp1-english.md
git diff --check
git status --short
```

Criteria:

- All 44 original documents and 144 questions exist, with 10 monolingual documents per required language, four mixed, actual cp1250 bytes, nested roots, equal relative paths across folders, loose source and other-notebook distractor. Provenance and human semantic review are complete; all gold references validate independently in Swift and C#.
- Shared 27 validator cases/subcases, 12 retrieval/scoring cases, two report golds and six CLI cases run on both platforms; no missing/ignored cases or skipped contract tests. The complete Swift and Windows suites stay green. Handoffs distinguish suite method counts from cases/queries visited.
- Full candidate-union recall, lexical topK/fetchK recall and hybrid topK recall have independent fields; no empty-gold denominator pollution, no snippets used as evidence, no language filter, and no score for an unavailable hook. Empty selection never invokes a provider. A supplied zero-evidence hook measures zero; truncation cannot count a removed suffix.
- Offline report JSON compares equal excluding only `platform`, Markdown bytes compare exactly, and the legacy English smoke succeeds. If SQLite builds produce a different legacy FTS order, investigate and document the actual tokenizer/build behavior before merging; do not delete assertions or relabel the run as parity. New SQL tie-breaks must make equal-score order deterministic.
- The net10.0 console builds on macOS and with the same command on Windows; no WinUI/App build is introduced. New dependency lockfile is committed and locked restore works. Deterministic Core tests execute in existing CI suite commands; live model/hardware measurements remain opt-in WP7 work.
- Only owned paths changed; no shipped migration, version file, training data, detector table, provider networking implementation or App/UI change. All task commits have the requested trailer and each worker's final worktree is clean.

Claude review decisions to record in the implementation handoff: approve MIT provenance/original text and all-language question quality; accept canonical UTF-8 SHA-256 plus one-based overlapping occurrence as the eval identity; confirm the explicitly reported temporary `eval-scalars-v1`/legacy-FTS baseline until production spans/FTS replace it in WP5/WP7; confirm micro-averaged evidence recall and unavailable Overview/packing reporting. WP8 owns real Overview selection, packed spans and citation correctness; WP4 owns detector metrics; WP7 owns model selection, performance timing, 100K/200K corpora and calibration. None of those unavailable measurements may be treated as passing a release gate.

Final worker report: list commit hashes, exact changed files, before/after full-suite counts for both platforms (or the unaffected platform's integration-gate result), fixture/query counts, and concrete remaining review questions. Do not claim a live benchmark was run unless it was.
