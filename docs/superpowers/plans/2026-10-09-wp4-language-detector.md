# WP4 — Language Detector Implementation Plan

**Goal:** Ship one offline cs/de/en/sk language detector, one Unicode 15.1.0 table resource, reproducible training and provenance, and Swift/C# implementations that agree on every fixture intermediate. Expose nullable detection and chunk-inheritance hooks for WP6 and document language metadata for WP8. A trained artifact is accepted only after the held-out release gate.

**Architecture:** Generate shared Unicode data under the Swift Core resource directory and link those exact files into the C# assembly. Both runtimes implement pinned NFC, scalar classification, full folding and integer scoring themselves. An offline Python reference/trainer consumes the same tables. Synthetic fixtures support implementation before production data is approved. Production loading verifies hashes and schemas; failure yields an unavailable detector and nullable results. Persistence, ingestion orchestration and prompt rendering remain with WP3/WP6/WP8.

**Tech Stack:** Swift 6, Foundation, CryptoKit, XCTest; .NET 10, System.Text.Json, System.Security.Cryptography, xUnit; Python 3.12 standard library (`fractions`, `hashlib`, `sqlite3`, `unittest`), Bash/curl for explicitly approved developer downloads. No new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-10-09-folder-chat-multilingual-rag-design.md` §5, §8.2, §9. **Binding appendix:** `docs/contracts/lang-detector-v1.md` §§1–10. **Master:** `docs/superpowers/plans/2026-10-09-folder-chat-master-plan.md`. **Format exemplar:** `docs/superpowers/plans/2026-10-09-wp0-contracts.md`; its obsolete skill invocation and division of ownership do not apply to this worktree execution model.

## Global Constraints

- Implement each numbered task in a separate worktree branched from the integrated commits listed under **Depends on**. Merge prerequisites before starting dependents. Only touch the task's listed files. A read-only input is not permission to edit that input. Every task records its red result, green result, full-suite totals and commit in its handoff.
- TDD: write tests, run and observe the specified failure, implement, rerun targeted tests and both full Core suites. No weakened assertions, skipped contract tests, production synthetic fallback, or network calls in runtime/tests. Compiler errors for a new API are a valid first red; later boundary tests must fail on behavior before fixing it.
- Baseline inspected at `087c1bff1639d38f86dfe0825ff57ab6f81acad0`: `swift test` **381 passed, 0 failures**; `dotnet test windows/tests/AINotebook.Core.Tests` **450 passed, 0 failed, 0 skipped**. Counts can increase after concurrent WP0 merges; capture the actual integration-base counts. Existing .NET restore reports NU1902 for AngleSharp 1.4.0; dependency changes are outside WP4.
- Scope is Core plus developer tooling/resources/tests. There are **no UI tasks**, XAML/view-model changes or localized strings in WP4. WP6 owns ingestion and UI; WP8 owns scope-header rendering. Never reuse UI `AppLanguage` for detector labels.
- Keep `lang-normalize-v1.json` (44 cases) and `lang-score-v1.json` (32: 23 text, 9 document) byte-identical. Add new, separately named fixture contracts for additional behavior. Every `contracts/*.json` needs `{contract,version,cases}` because `Tests/AINotebookCoreTests/SharedFixturesTests.swift:11` and `windows/tests/AINotebook.Core.Tests/SharedFixturesTests.cs:18` enforce this. Models, schemas and manifests belong outside that directory.
- `SharedFixtures.data(_:) throws -> Data` is at `Tests/AINotebookCoreTests/SharedFixtures.swift:16`; `SharedFixtures.Json(string) -> JsonElement` and `Path(string) -> string` are at `windows/tests/AINotebook.Core.Tests/Helpers/SharedFixtures.cs:8`. C# already copies all `Tests/fixtures/**` at `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj:36`. Do not edit either helper or test project.
- Unicode normalization/folding/category tests use committed pinned data, never Foundation normalization, ICU, `String.Normalize`, `Rune.ToLowerInvariant`, Python `unicodedata`, locale collation, or regex character classes. Scalar offsets are not UTF-16 or grapheme offsets. Glob consumes **simple lowercase**, not detector full folding; FTS consumes categories/NFC, not detector classification or folding.
- Signed arithmetic is Int64/`long`, with multiplication promoted before division; negative division is mathematical floor. Diagnostic scores are computed even when abstaining. Document shares include unknown-window letters. Only two or more confidently observed targets can produce `mixed` without dominance.
- Unavailable detection returns `nil`/`null`; a completed inconclusive run returns `und`. Neither path changes retrieval eligibility. A missing detector never prevents ingestion. No detection in migrations, no schema changes, no VERSION/constants version bump. WP3 owns v19 and published revisions. All future C# store writes belong under `lock (_gate)` in WP6.
- Respect all eleven binding WP0 corrections. WP4 directly supplies the shared pinned simple-lowercase API for decisions 2/11. Do not edit the concurrently owned `tools/contracts/gen_fixtures.py`, glob/FTS fixtures, citations, budget, scope, jobs or overview. Their updated rules remain: whole-payload invalid citations rejection; normalized glob components; strict authorities; zero evidence means none; actual-cost sentence-prefix truncation; capped map redistribution; published lexical revisions versus vector manifest revisions; attempt-start counting and lease fencing; folder-aware overview order; searchable/freshness coverage separation; deterministic fixture bytes without SQLite version. None is superseded by this plan.
- App networking remains restricted to `Providers/` and existing exceptions (`.github/workflows/core-ci.yml:33`). Approved Unicode/Tatoeba acquisition is developer tooling, never included in either runtime. No credentials are needed. Do not read forbidden home/repository agent directories or invoke installed skills.
- Python scripts with direct CLI entry points prepend the repository root to `sys.path` using `Path(__file__).resolve().parents[2]` before importing `tools.lang`/`tools.unicode`; tests include `subprocess.run([sys.executable,"-B",script,"--help"],check=True)` from the repo root. Use `python3 -B` everywhere, including shell wrappers, to keep untracked bytecode out of worktrees.
- Each commit ends with `Co-Authored-By: Codex <noreply@openai.com>`; stage exact paths, never `git add .`. Leave worktrees clean.

## File Structure

Paths marked **new** do not exist at the inspected revision; they are outputs, not claims about current code.

| Files | Owner task | Responsibility / current anchor |
|---|---|---|
| `tools/unicode/gen_tables.py`, `tools/unicode/tests/test_gen_tables.py` (new) | 1 | Pinned acquisition, extraction, table generation and reproducibility |
| `Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json`, `.sha256`, `unicode-sources-v1.json`, `UNICODE-LICENSE.txt` (new) | 1 | One shared table plus provenance/hash/license; `.sha256` means `unicode-15.1.0.json.sha256` |
| `Tests/fixtures/unicode/NormalizationTest-15.1.0.txt`, `.sha256` (new) | 1 | All normative conformance rows, exact source bytes |
| `Tests/fixtures/contracts/unicode-tables-v1.json`, `lang-artifact-validation-v1.json`, `lang-inheritance-v1.json`, `lang-runtime-v1.json`, `lang-loading-v1.json` (new) | 1 | Additional cross-platform behavior; no edits to frozen language fixtures |
| `Tests/fixtures/lang/loading-bundle-v1.json` (new) | 1 | Explicitly test-only complete resource map for positive/negative production-loader tests |
| `tools/lang/schemas/artifact-v1.schema.json`, `manifest-v1.schema.json` (new) | 1 | Exact JSON schemas extracted from appendix §§9/10 |
| `Package.swift` | 2 | Add Core resource declaration at lines 31–38; no dependencies/product changes |
| `Sources/AINotebookCore/UnicodeTables.swift`, `Tests/AINotebookCoreTests/UnicodeTablesTests.swift` (new) | 2 | Shared Swift Unicode component, complete NFC conformance |
| `windows/src/AINotebook.Core/AINotebook.Core.csproj` | 3 | Add linked embedded resources after line 28 |
| `windows/src/AINotebook.Core/Language/UnicodeTables.cs`, `windows/tests/AINotebook.Core.Tests/Language/UnicodeTablesTests.cs` (new) | 3 | Windows Unicode twin |
| `tools/lang/reference.py`, `tools/lang/tests/test_reference.py` (new) | 4 | Independent reference, exact export rounding, all synthetic diagnostics |
| `Sources/AINotebookCore/LanguageJSON.swift`, `LanguageModel.swift`, `LanguageNormalization.swift`; `Tests/AINotebookCoreTests/LanguageModelTests.swift`, `LanguageNormalizationTests.swift`, `LanguageFixtureAssert.swift` (new) | 5 | Strict JSON/model validation, normalization, structural test comparison |
| `windows/src/AINotebook.Core/Language/LanguageModel.cs`, `LanguageNormalization.cs`; `windows/tests/AINotebook.Core.Tests/Language/LanguageModelTests.cs`, `LanguageNormalizationTests.cs`, `LanguageFixtureAssert.cs` (new) | 6 | Windows model/normalization twin |
| `Sources/AINotebookCore/LanguageScorer.swift`, `Tests/AINotebookCoreTests/LanguageScorerTests.swift` (new) | 7 | Scalar feature counts, integer scores, abstention |
| `windows/src/AINotebook.Core/Language/LanguageScorer.cs`, `windows/tests/AINotebook.Core.Tests/Language/LanguageScorerTests.cs` (new) | 8 | Windows scoring twin |
| `Sources/AINotebookCore/LanguageDetector.swift`, `LanguageDocument.swift`, `ChunkLanguage.swift`; `Tests/AINotebookCoreTests/LanguageDetectorTests.swift`, `LanguageDocumentTests.swift` (new) | 9 | Swift bundled facade, document mode, nullable/inheritance hook |
| `windows/src/AINotebook.Core/Language/LanguageDetector.cs`, `LanguageDocument.cs`, `ChunkLanguage.cs`; `windows/tests/AINotebook.Core.Tests/Language/LanguageDetectorTests.cs`, `LanguageDocumentTests.cs` (new) | 10 | Windows document/facade twin |
| `tools/lang/prepare_corpus.py`, `tools/lang/tests/test_prepare_corpus.py` (new) | 11 | Offline TSV parsing, graph split, caps, augmentation, provenance |
| `tools/lang/train_detector.py`, `calibrate.py`, `fetch_tatoeba.sh`, `pin_tatoeba.py`, `training-v1.json`, `README.md`; `tools/lang/tests/test_training.py`, `test_fetch.py` (new) | 12 | Offline training/calibration and explicit acquisition tooling |
| `tools/lang/tatoeba-v1.lock.json`, `ATTRIBUTION.md` (new); `NOTICE` | 13, Claude only | Actual approved snapshot hashes/contributors; preserve current NOTICE lines 1–12 |
| `Sources/AINotebookCore/Resources/Language/lang-detector-v1.json`, `lang-detector-v1.manifest.json`, `NOTICE`, `ATTRIBUTION.md` (new) | 13, Claude only | Same production bytes embedded on both platforms |
| `tools/lang/evaluate_detector.py`, `tools/lang/tests/test_evaluation.py`; `Tests/fixtures/contracts/lang-release-v1.json`; `Tests/fixtures/lang/wp1-documents-v1.json`, `lang-release-v1.metrics.json`; `docs/eval/language-detector-v1.md` (new) | 14 | Held-out and WP1 evaluation, exact metrics, committed CI subset |
| `Tests/AINotebookCoreTests/LanguageReleaseTests.swift`, `windows/tests/AINotebook.Core.Tests/Language/LanguageReleaseTests.cs` (new) | 14 | Both real runtimes on the same release evaluation inputs |

`Sources/AINotebookCore/IngestionService.swift:164` and `windows/src/AINotebook.Core/Ingestion/IngestionService.cs:183` currently discard the extracted whole document and persist chunks. WP6 will retain canonical text and call the new APIs before publishing. Current source/chunk DTOs have no language fields (`Sources/AINotebookCore/Source.swift:4`, `SourceChunk.swift:4`; C# `Models/Source.cs:83`, `Models/SourceChunk.cs:3`); WP3/WP6 own these files. Current prompt composers only emit snippets (`Sources/AINotebookCore/SystemPrompt.swift:29`, `windows/src/AINotebook.Core/Rag/SystemPrompt.cs:32`); WP8 owns their replacement. They are **read-only context**, not WP4 edits.

Execution graph: **1 → (2 ∥ 3 ∥ 4); 2 → 5 → 7 → 9; 3 → 6 → 8 → 10; (4,WP1) → 11 → 12; (9,10,12,WP1) → 13 → 14**. Shared tasks finish and land their fixtures before either consuming platform starts. All files are disjoint between parallel tasks; Tasks 13/14 intentionally run after resource consumers are merged.

### Task 1: [Shared] Generate pinned Unicode data and freeze additional test inputs

**Depends on:** WP0 appendix and binding fixes merged. **Parallel with:** none within WP4; this is the initial shared-data barrier.

**Files:** Create only the Task 1 files in the table. Read existing `Tests/fixtures/contracts/lang-normalize-v1.json`, `lang-score-v1.json`, `constants-v1.json`, and appendix. Do not modify the older fixture generator (its generation registry at `tools/contracts/gen_fixtures.py:605` does not own language fixtures).

**Interfaces — Consumes:** appendix Unicode hashes and schemas. **Produces:**

- Python `verify_bytes(name: str, data: bytes) -> None`, `parse_unicode_data(text: str) -> dict`, `generate(ucd_dir: Path, output_dir: Path, fixture_dir: Path) -> None` and CLI below.
- Data consumed by Swift `UnicodeTables.init(data: Data, expectedSHA256: String) throws` / C# `UnicodeTables.Load(ReadOnlySpan<byte> data, string expectedSha256)`; full signatures are frozen in Tasks 2/3.
- UTF-8 compact JSON + LF, format `{"format":1,"unicodeVersion":"15.1.0","normalizationTablesVersion":"ucd-15.1.0-default-full-v1","categories":[[start,end,"Lu"]],"ccc":[[scalar,ccc]],"decomposition":[[scalar,[components]]],"compositionExclusions":[scalar],"composition":[[first,second,result]],"caseFold":[[scalar,[components]]],"simpleLower":[[scalar,result]]}`. Ranges are inclusive, sorted and coalesced by category, omit `Cn`; sparse arrays omit identities/zeroes. Include all General_Category values, not just letters/marks. Composition excludes the full exclusion property. Hangul remains algorithmic. All arrays sorted numerically by scalar/tuple, all numbers decimal integers, keys in the listed order, no timestamp/tool version in table bytes.
- Hash sidecars contain lowercase SHA-256 plus LF only. `unicode-sources-v1.json` records URL/hash of all four inputs, exact output hash, normalization row count, format/version; it is not the training manifest. No new field is added to the binding manifest schema.

- [ ] **Step 1 — write and run the failing generator tests.** Include these executable tests in `tools/unicode/tests/test_gen_tables.py`:

```python
import hashlib
import unittest
from tools.unicode.gen_tables import parse_unicode_data, verify_bytes

class GeneratorTests(unittest.TestCase):
    def test_rejects_changed_pinned_bytes(self):
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            verify_bytes("UnicodeData.txt", b"wrong\n")

    def test_simple_lower_is_not_full_fold(self):
        fields = [""] * 15
        fields[0:5] = ["0130", "LATIN CAPITAL LETTER I WITH DOT ABOVE", "Lu", "0", "L"]
        fields[5] = "0049 0307"
        fields[13] = "0069"
        table = parse_unicode_data(";".join(fields) + "\n")
        self.assertEqual(table["simpleLower"], [[304, 105]])
        self.assertEqual(table["decomposition"], [[304, [73, 775]]])

    def test_first_last_expands_inclusive_range(self):
        rows = []
        for cp, name in [(0x3400, "<CJK Ideograph Extension A, First>"),
                         (0x4DBF, "<CJK Ideograph Extension A, Last>")]:
            fields = [""] * 15
            fields[0:5] = [f"{cp:04X}", name, "Lo", "0", "L"]
            rows.append(";".join(fields))
        self.assertEqual(parse_unicode_data("\n".join(rows))["categories"],
                         [[0x3400, 0x4DBF, "Lo"]])
```

Run `python3 -B -m unittest discover -s tools/unicode/tests -p 'test_*.py' -v`. Expected red: `ModuleNotFoundError: tools.unicode.gen_tables`.

- [ ] **Step 2 — implement acquisition and deterministic generation.** Pin these exact input hashes; no first-use trust for UCD:

| Input | SHA-256 |
|---|---|
| `https://www.unicode.org/Public/zipped/15.1.0/UCD.zip` | `cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177` |
| `UnicodeData.txt` | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| `CaseFolding.txt` | `4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf` |
| `DerivedNormalizationProps.txt` | `8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1` |
| `NormalizationTest.txt` | `871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e` |

`--download` reads only that archive URL; verify archive before extracting named files to the local UCD directory. Reject path traversal/archive unexpected types. Verify all four uncompressed hashes before emitting anything. Preserve the archive's Unicode license text as `UNICODE-LICENSE.txt` (record member name/hash in `unicode-sources-v1.json`). Offline invocation never imports/calls acquisition. `--check` recomputes bytes and reports mismatches without writing. Use atomic writes. Hash code:

```python
def verify_bytes(name, data):
    actual = hashlib.sha256(data).hexdigest()
    if actual != PINNED_SHA256[name]:
        raise ValueError(f"SHA-256 mismatch for {name}: {actual}")
```

Read UnicodeData field 2 for category, 3 for CCC, 5 for canonical decomposition (skip strings beginning `<`), **13** for simple lowercase. Expand First/Last with matching category/CCC. Parse only C/F casefold rows once; reject duplicate/conflicting rows. Parse `Full_Composition_Exclusion`, including ranges, from DerivedNormalizationProps. Generate two-scalar canonical composition rows only when not excluded. Assert sortedness, uniqueness, valid ranges, no decomposition cycles, and that tables can reconstruct all source mappings. Keep NormalizationTest exact bytes and its sidecar under `Tests/fixtures/unicode/`.

- [ ] **Step 3 — create shared supplemental contracts before runtime work.** Each case has `name`, `operation`, `input`, `expected`; artifact cases instead have `name`, `rawArtifact` and `valid` (boolean). Keep these schemas explicit:

1. `unicode-tables-v1`: operations `nfc`, `fold`, `lower`, `category`; input and expected are scalar arrays except category expected is a string array. Include `lower([304,7838,66560])=[105,223,66600]`, `fold([304,7838])=[105,775,115,115]`, `nfc([97,789,768])=[224,789]`, `nfc([4352,4449,4520])=[44033]`, `nfc([0x0344])=[0x0308,0x0301]` (excluded from recomposition), stable equal-CCC blocking, leading marks, unassigned U+0378=`Cn`, Kawi U+11F02=`Lo`, U+0307=`Mn`, digit U+0663=`Nd`, private-use U+E000=`Co`. Expected NFC comes from pinned conformance rows, never the platform runtime.
2. `lang-artifact-validation-v1`: take an independent deep copy of the synthetic `model` for every mutation, serialize as UTF-8 LF `rawArtifact` string. Positive unchanged synthetic model. Negative mutations: duplicate `version`, escaped duplicate `\u0076ersion`, `version:1.0`, `version:1e0`, boolean alpha, unknown top-level/nested key, missing thresholds, surrogate in a feature, unsorted/duplicate feature, order/feature length mismatch, EOS in middle, duplicate BOS, `[-1,-2]`, digit-only feature, wrong profile order, bad weight count, weight 1/-1000001, wrong prior, duplicate target, changed fixed minLetters/orderWeights/dominance, zero cap, window larger than text cap, input cap >5000000, enabled zero margin, malformed escape, invalid JSON, missing final LF and BOM. Provide `rawBytesBase64` instead of `rawArtifact` for invalid UTF-8. Assert exactly one representation. Tests must check both the raw parser and semantic validation.
3. `lang-inheritance-v1`: input `{label,reason,documentLabel}`, nullable strings; expected `{lang,langInherited}`. Cases: `(null,null,"cs")→(null,false)`; `("und","minLetters","cs")→("cs",true)`; `("und","minWords","de")→("de",true)`; `("und","minMargin","cs")→("und",false)`; each of background/bucketDisabled/minWinningScore/minKnownCoverageBp cannot inherit; short plus mixed/und/null cannot inherit; accepted sk plus cs stays sk,false. No document result is inferred from chunks.
4. `lang-runtime-v1`: operations `normalize`, `windows`, `aggregate`, `score`. Normalization inputs use `utf16Units`, `inputCap`, `textCap` and `mode`; outputs include stream/scalars/counts. Include pair `[55297,56320,65]` with inputCap=1 → stream `[66600]`; `[55296,55296,56320,65]` → `[65533,65536,97]`; pre/post cap `ßßA`, cap 3 → `[115,115,115]`; text cap 1 on `İ` → `[105]` while document stream remains `[105,775]`. Windows cases `(N,C,S)=(0,8,512)→[]`, `(513,8,512)→[[0,256],[257,513]]`, `(4097,8,512)→[[0,512],[512,1024],[1024,1536],[1536,2048],[2048,2560],[2560,3072],[3072,3584],[3585,4097]]`. Aggregation inputs are targets plus `(label,letters)` rows: cs70/und30 dominant cs; cs69/und31 und; cs69/sk1/und30 mixed; zero-letter empty und. Store sampled/accepted/unknown letters, every separately floored share, coverage, label/reason.


For `score` supplemental rows, use the existing embedded synthetic model with explicit `modelOverrides` and `expected` full trees. Three `aaaa aaaa aaaa` rows set the bucket12 threshold triple to `[-8957,1,0]`, `[-20000,9096,0]`, `[-20000,1,10000]`, respectively, and expect the existing `accept-xa` tree unchanged (`accepted` on equality). Set the other two constraints loose so each equality is exercised independently. A fourth row sets `[minWinningScore=-20000,minMargin=1,minKnownCoverageBp=8888]` for `aaaa aaaa aaad`; use the complete `coverage-only` tree except label=`xa`, reason=`accepted`. Add text-cap rows using `inputCapScalars=9000,textCapScalars=8192`, input `"a"*8190 + " " + "a"` and the same string plus `"b"`; both slices must equal the first 8192 scalars. Their expected words are `["a"*8190,"a"]`, letterCount8191, wordCount2, reason minWords. Generate full expected counts directly from these two words by enumerating signed tuples and the already frozen integer weights; score sums use Python `//`. This small supplemental oracle is in `gen_tables.py`, separate from Task 4's reference, and is hand-checked against the existing xa worked example. No new reference import is needed to finish Task 1.

5. `lang-loading-v1`: every case has `{name,operation,input,expected:{isAvailable}}`. Positive operation=`unchanged`; negative operations=`removeResource`, `flipByte`, `setManifestValue`, `replaceArtifactWithSynthetic`, `addUnknownManifestKey`, `duplicateManifestKey`. Input identifies the fixed resource name plus JSON pointer/value or byte index. Cases cover missing artifact/manifest/table/sidecar/NOTICE/ATTRIBUTION; changed artifact/table/NOTICE/ATTRIBUTION bytes; correct artifact hash but synthetic kind; changed modelId, normalization version, each of four Unicode source hashes, manifest attribution hash/path traversal, unknown/duplicate manifest key, invalid date and duplicate count/support compound key. Metadata mutation cases reserialize the manifest; artifact semantic mutation cases update the artifact digest so they actually reach semantic validation. Require production parameters/targets, attribution equality and Unicode pins even in the test bundle. The unchanged row expects true; all others false.

`Tests/fixtures/lang/loading-bundle-v1.json` is `{contract:"lang-loading-bundle",version:1,testOnly:1,resources:{filename:base64ExactBytes}}`. It contains a structurally valid **production-shaped test model**, explicitly named `wp4-loader-test-only`, never a deployable trained detector: targets cs/de/en/sk, default production parameters, three empty vocabularies, five profiles with prior -1648 and zero unknown weight (the zero-count smoothing formula gives ln(1)=0), four disabled thresholds with minScore=-120000,minMargin=1,minCoverage=0. Supply a complete §10 manifest with source `wp4-loader-test-only`, zero source records, `https://example.invalid/wp4-loader-test-only` as the visibly invented fixture source URL, license `LicenseRef-WP4-Test-Only`, all ten admitted languages mapped, all required zero count/support/metric rows, all four buckets disabled for insufficientSupport, no document rows, exporter revision forty zeroes, explicit fixed dates/arguments, and the real four Unicode source pins. Attribution/NOTICE bytes say `Wholly invented WP4 loader fixture; not for distribution as a model.\n`; hash actual bytes and use the same repository-path allowlist as real production. Do not duplicate the Unicode table bytes in this fixture. Add `sharedUnicodeResources:["unicode-15.1.0.json","unicode-15.1.0.json.sha256","unicode-sources-v1.json","UNICODE-LICENSE.txt"]` to its envelope. Before applying case mutations, each test supplies those four resource bytes from its real bundled Unicode resources via the internal fixed-name accessor declared in Tasks 9/10; no arbitrary paths are read. All other model/manifest/notice/attribution resource bytes are base64 in `resources`. Tests assert the map's modelId is the test-only value before injection. This fixture tests integrity and schema behavior before training without making any quality or provenance claim about a real corpus. It is outside runtime resource targets and never copied into production bundle resources.

Create schema files by parsing the two JSON code blocks under appendix §9/§10. Preserve their structures exactly. A Python test compares extracted schemas structurally to committed schemas. Do not modify the appendix.

- [ ] **Step 4 — verify and commit.**

```bash
python3 -B tools/unicode/gen_tables.py --download --ucd-dir /tmp/ainotebook-ucd-15.1.0
python3 -B tools/unicode/gen_tables.py --ucd-dir /tmp/ainotebook-ucd-15.1.0 --check
python3 -B -m unittest discover -s tools/unicode/tests -p 'test_*.py' -v
swift test --filter SharedFixturesTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~SharedFixtures
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/unicode/gen_tables.py tools/unicode/tests/test_gen_tables.py tools/lang/schemas/artifact-v1.schema.json tools/lang/schemas/manifest-v1.schema.json Sources/AINotebookCore/Resources/Language Tests/fixtures/unicode Tests/fixtures/contracts/unicode-tables-v1.json Tests/fixtures/contracts/lang-artifact-validation-v1.json Tests/fixtures/contracts/lang-inheritance-v1.json Tests/fixtures/contracts/lang-runtime-v1.json Tests/fixtures/contracts/lang-loading-v1.json Tests/fixtures/lang/loading-bundle-v1.json
git commit -m "feat(shared): pin Unicode 15.1 tables and detector boundary fixtures" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: generator prints `Unicode 15.1.0 tables verified`, conformance row count and exact output SHA; check exits 0; Python tests OK; fixture tests 2 per platform; full suites green. Re-run generator into a temporary output directory and compare table bytes/hash; source ZIP is not committed. Every Python command uses `-B`, and shell download tooling invokes `python3 -B`, so no Python cache files are created or staged.

### Task 2: [Swift] Implement shared UnicodeTables and complete NFC conformance

**Depends on:** 1. **Parallel with:** 3, 4, 6, 8, 10, 11, 12 as their own prerequisites permit.

**Files:** Modify `Package.swift:31–38`; create `Sources/AINotebookCore/UnicodeTables.swift`, `Tests/AINotebookCoreTests/UnicodeTablesTests.swift`.

**Interfaces — Consumes:** Task 1 table/hash/conformance fixtures. **Produces (public, immutable, Sendable):**

```swift
public struct UnicodeTables: Sendable {
    public init(data: Data, expectedSHA256: String) throws
    public static func bundled() throws -> UnicodeTables
    public func generalCategory(_ scalar: UInt32) -> String
    public func combiningClass(_ scalar: UInt32) -> UInt8
    public func simpleLowercase(_ scalar: UInt32) -> UInt32
    public func fullCaseFold(_ scalars: [UInt32]) -> [UInt32]
    public func nfd(_ scalars: [UInt32]) -> [UInt32]
    public func nfc(_ scalars: [UInt32]) -> [UInt32]
}
```

C# consuming/producing peer contract: `UnicodeTables.Load(ReadOnlySpan<byte>, string)`, `LoadBundled()`, `string GeneralCategory(int)`, `byte CombiningClass(int)`, `int SimpleLowercase(int)`, `int[] FullCaseFold(IReadOnlyList<int>)`, `int[] Nfd(IReadOnlyList<int>)`, `int[] Nfc(IReadOnlyList<int>)`. Task 2 does not edit that implementation.

- [ ] **Step 1 — write failing tests.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore

final class UnicodeTablesTests: XCTestCase {
    func testSimpleLowerAndFullFoldAreDifferent() throws {
        let u = try UnicodeTables.bundled()
        XCTAssertEqual(u.simpleLowercase(0x0130), 0x0069)
        XCTAssertEqual(u.simpleLowercase(0x10400), 0x10428)
        XCTAssertEqual(u.fullCaseFold([0x0130, 0x1E9E]), [105, 775, 115, 115])
        XCTAssertEqual(u.generalCategory(0x11F02), "Lo")
    }
    func testAllNormalizationRows() throws {
        let u = try UnicodeTables.bundled()
        let raw = try SharedFixtures.data("unicode/NormalizationTest-15.1.0.txt")
        let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
        var rows = 0
        for line in text.components(separatedBy: .newlines) {
            let body = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body.hasPrefix("@") { continue }
            let columns = body.components(separatedBy: ";").prefix(5)
            XCTAssertEqual(columns.count, 5)
            let c = try columns.map { field in
                try field.split(whereSeparator: { $0 == " " || $0 == "\t" }).map {
                    try XCTUnwrap(UInt32($0, radix: 16))
                }
            }
            for i in 0..<3 { XCTAssertEqual(u.nfc(c[i]), c[1], "row \(rows), c\(i+1)") }
            for i in 3..<5 { XCTAssertEqual(u.nfc(c[i]), c[3], "row \(rows), c\(i+1)") }
            rows += 1
        }
        XCTAssertGreaterThan(rows, 19_000)
    }
    func testBadResourceHashThrows() {
        XCTAssertThrowsError(try UnicodeTables(data: Data("{}\n".utf8), expectedSHA256: String(repeating: "0", count: 64)))
    }
}
```

Run `swift test --filter UnicodeTablesTests`; expected red: missing `UnicodeTables`. Add a fourth test iterating all `unicode-tables-v1` cases by operation with exactly the array assertions above; also verify conformance file SHA equals its sidecar and Task 1 row count, so a truncated resource cannot pass the >19000 check alone.

- [ ] **Step 2 — implement table loading and NFC.** Add `resources: [.copy("Resources/Language")]` after Core dependencies, leaving other targets unchanged. `bundled()` reads `Bundle.module` subdirectory `Language`, verifies table SHA via CryptoKit, validates format/version/ranges/sorted unique keys and builds immutable maps. Throw a typed load error for absent, corrupt, incompatible or inconsistent table. Validate scalar API preconditions internally; every caller supplies decoded scalars, not surrogate code points. `generalCategory` uses binary search and defaults Cn. Sparse CCC defaults zero; missing lowercase/fold rows are identities.

NFD recursively expands canonical decompositions; Hangul syllable `s=cp-0xAC00` in 0..<11172 expands L=`0x1100+s/588`, V=`0x1161+(s%588)/28`, T=`0x11A7+s%28` only if remainder nonzero. Canonically reorder each nonstarter run by **stable** ascending CCC, retaining equal-CCC order. Use 256 counting buckets per segment, not insertion sorting a possible five-million-mark run. NFC then composes with blocking and algorithmic Hangul. The core composition loop must follow this code (helper lookup returns the table pair, L+V or LV+T):

```swift
func compose(_ ordered: [UInt32], ccc: (UInt32) -> UInt8,
             pair: (UInt32, UInt32) -> UInt32?) -> [UInt32] {
    var out: [UInt32] = []
    var starter: Int? = nil
    var last: UInt8 = 0
    for cp in ordered {
        let current = ccc(cp)
        if let index = starter, (last == 0 || last < current),
           let replacement = pair(out[index], cp) {
            out[index] = replacement
        } else {
            if current == 0 { starter = out.count }
            out.append(cp)
            last = current
        }
    }
    return out
}
```

Only successful composition leaves `last` unchanged. With no starter, leading marks cannot compose. For L+V require L in 0x1100..<0x1113 and V in 0x1161..<0x1176; result `0xAC00 + (L-0x1100)*588 + (V-0x1161)*28`. For LV+T require LV in Hangul range with `(LV-0xAC00)%28==0`, T in 0x11A8..<0x11C3; result `LV+T-0x11A7`. NFC is compose(NFD), never a host normalization call.

- [ ] **Step 3 — green and commit.**

```bash
swift test --filter UnicodeTablesTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Package.swift Sources/AINotebookCore/UnicodeTables.swift Tests/AINotebookCoreTests/UnicodeTablesTests.swift
git commit -m "feat(core): pinned Unicode tables and conformant NFC" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four Unicode tests pass, every normalization row executes five NFC assertions, all shared operation cases pass, full suites green. No corpus/model download is needed.

### Task 3: [Windows] Implement shared UnicodeTables and complete NFC conformance

**Depends on:** 1. **Parallel with:** 2, 4, 5, 7, 9, 11, 12 as their own prerequisites permit.

**Files:** Modify `windows/src/AINotebook.Core/AINotebook.Core.csproj:28`; create `windows/src/AINotebook.Core/Language/UnicodeTables.cs`, `windows/tests/AINotebook.Core.Tests/Language/UnicodeTablesTests.cs`.

**Interfaces — Consumes:** Task 1 resources. **Produces:** immutable `AINotebook.Core.Language.UnicodeTables` with `public static UnicodeTables Load(ReadOnlySpan<byte> data, string expectedSha256)`, `LoadBundled()`, `public string GeneralCategory(int scalar)`, `public byte CombiningClass(int scalar)`, `public int SimpleLowercase(int scalar)`, `public int[] FullCaseFold(IReadOnlyList<int> scalars)`, `Nfd(IReadOnlyList<int> scalars)`, `Nfc(IReadOnlyList<int> scalars)`.

Swift peer consumed by downstream work: `UnicodeTables.bundled() throws -> UnicodeTables`, `generalCategory(_ scalar: UInt32) -> String`, `combiningClass(_:) -> UInt8`, `simpleLowercase(_:) -> UInt32`, `fullCaseFold(_ scalars: [UInt32]) -> [UInt32]`, `nfd(_:) -> [UInt32]`, `nfc(_:) -> [UInt32]`.

- [ ] **Step 1 — write failing tests.**

```csharp
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Language;

public sealed class UnicodeTablesTests
{
    [Fact]
    public void SimpleLowerAndFullFoldAreDifferent()
    {
        var u = UnicodeTables.LoadBundled();
        Assert.Equal(105, u.SimpleLowercase(0x0130));
        Assert.Equal(0x10428, u.SimpleLowercase(0x10400));
        Assert.Equal(new[] { 105, 775, 115, 115 }, u.FullCaseFold(new[] { 0x0130, 0x1E9E }));
        Assert.Equal("Lo", u.GeneralCategory(0x11F02));
    }
    [Fact]
    public void AllNormalizationRows()
    {
        var u = UnicodeTables.LoadBundled();
        var path = SharedFixtures.Path("unicode/NormalizationTest-15.1.0.txt");
        Assert.Equal("871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e",
            Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path))));
        int rows = 0;
        foreach (var line in File.ReadLines(path))
        {
            var body = line.Split('#')[0].Trim();
            if (body.Length == 0 || body.StartsWith('@')) continue;
            var c = body.Split(';').Take(5).Select(field => field
                .Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(s => int.Parse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture)).ToArray()).ToArray();
            Assert.Equal(5, c.Length);
            for (int i = 0; i < 3; i++) Assert.Equal(c[1], u.Nfc(c[i]));
            for (int i = 3; i < 5; i++) Assert.Equal(c[3], u.Nfc(c[i]));
            rows++;
        }
        Assert.True(rows > 19000);
    }
    [Fact]
    public void BadResourceHashThrows() => Assert.Throws<InvalidDataException>(() =>
        UnicodeTables.Load("{}\n"u8, new string('0', 64)));
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~UnicodeTablesTests`; expected red: missing Language namespace/type. Add a fourth case-loop test for every operation in `unicode-tables-v1`; verify sidecar and provenance row count in addition to the source SHA above.

- [ ] **Step 2 — embed the same files and implement.** Add:

```xml
<ItemGroup>
  <EmbeddedResource Include="..\..\..\Sources\AINotebookCore\Resources\Language\*"
                    LogicalName="AINotebook.Core.Language.%(Filename)%(Extension)" />
</ItemGroup>
```

Load resources from `typeof(UnicodeTables).Assembly.GetManifestResourceStream`, never working directory or Windows package APIs. Validate SHA before JSON decoding; malformed data throws `InvalidDataException`. Use binary searched category ranges, immutable private maps with defensive copies, identity defaults. NFD uses canonical mappings and algorithmic Hangul with constants SBase=0xAC00, LBase=0x1100, VBase=0x1161, TBase=0x11A7, LCount=19,VCount=21,TCount=28. Stable-sort nonstarter runs by CCC using 256 buckets. NFC composition core:

```csharp
internal static int[] Compose(IReadOnlyList<int> ordered, Func<int, byte> ccc,
                              Func<int, int, int?> pair)
{
    var output = new List<int>(ordered.Count);
    int starter = -1;
    byte last = 0;
    foreach (int cp in ordered)
    {
        byte current = ccc(cp);
        int? combined = starter >= 0 && (last == 0 || last < current)
            ? pair(output[starter], cp) : null;
        if (combined is int replacement) output[starter] = replacement;
        else
        {
            if (current == 0) starter = output.Count;
            output.Add(cp);
            last = current;
        }
    }
    return output.ToArray();
}
```

Pair lookup first handles valid L+V and LV+T ranges, otherwise the generated composition map. Reject malformed table keys/order/ranges/cycles. `FullCaseFold` maps each original scalar exactly once using C/F rows; `SimpleLowercase` uses only field 13. Retain complete categories for WP5's L/N/Co token rule.

- [ ] **Step 3 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~UnicodeTablesTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/AINotebook.Core.csproj windows/src/AINotebook.Core/Language/UnicodeTables.cs windows/tests/AINotebook.Core.Tests/Language/UnicodeTablesTests.cs
git commit -m "feat(win-core): shared Unicode data and conformant NFC" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: four Unicode tests pass and all conformance rows execute; both full suites green. Windows App build remains delegated to existing Windows CI (`.github/workflows/windows-ci.yml:45`).

### Task 4: [Shared] Implement the independent reference and exact weight exporter

**Depends on:** 1. **Parallel with:** 2, 3, 5, 6, 7, 8, 9, 10.

**Files:** Create `tools/lang/reference.py`, `tools/lang/tests/test_reference.py` only.

**Interfaces — Consumes:** shared Unicode data; all existing language fixture contents, including synthetic `training`. **Produces (Python):** `UnicodeData.load(path: Path) -> UnicodeData`, `normalize(text: str, tables: UnicodeData, input_cap: int) -> list[int]`, `classify(scalars: list[int], tables: UnicodeData) -> dict`, `features(words: list[list[int]]) -> list[Counter]`, `round_log_weight(numerator: int, denominator: int, scale: int = 1024) -> int`, `export_profiles(training: dict, caps: list[int], tables: UnicodeData) -> dict`, `score_slice(scalars: list[int], model: dict, tables: UnicodeData) -> dict`, `detect_text(text: str, model: dict, tables: UnicodeData) -> dict`, `detect_document(text: str, model: dict, tables: UnicodeData) -> dict`.

These outputs are exactly the appendix §8 expected trees consumed by Swift `LanguageScorer.score(_ scalars: [UInt32]) -> LanguageTextResult` / C# `LanguageScorer.Score(IReadOnlyList<int> scalars) -> LanguageTextResult`, and Swift `LanguageDocument.detect(stream: [UInt32], scorer: LanguageScorer) -> LanguageDocumentResult` / C# `LanguageDocument.Detect(IReadOnlyList<int> stream, LanguageScorer scorer) -> LanguageDocumentResult`. No generated native source or foreign-function bridge.

- [ ] **Step 1 — write failing tests and run.**

```python
import json
import unittest
from pathlib import Path
from tools.lang.reference import UnicodeData, round_log_weight, export_profiles, detect_text, detect_document

ROOT = Path(__file__).resolve().parents[3]
class ReferenceTests(unittest.TestCase):
    def test_proven_rounding(self):
        self.assertEqual(round_log_weight(37, 72), -682)
        self.assertEqual(round_log_weight(1, 3), -1125)
        self.assertEqual(round_log_weight(1, 4), -1420)
        self.assertEqual(round_log_weight(1, 5), -1648)
        self.assertEqual(round_log_weight(1, 1), 0)

    def test_reconstructs_every_synthetic_weight(self):
        fixture = json.loads((ROOT / "Tests/fixtures/contracts/lang-score-v1.json").read_text())
        tables = UnicodeData.load(ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json")
        actual = export_profiles(fixture["training"], [3, 3, 3], tables)
        for field in ["vocabulary", "profiles"]:
            self.assertEqual(actual[field], fixture["model"][field], field)

    def test_every_intermediate(self):
        fixture = json.loads((ROOT / "Tests/fixtures/contracts/lang-score-v1.json").read_text())
        tables = UnicodeData.load(ROOT / "Sources/AINotebookCore/Resources/Language/unicode-15.1.0.json")
        self.assertEqual(len(fixture["cases"]), 32)
        for case in fixture["cases"]:
            with self.subTest(case=case["name"]):
                fn = detect_text if case["mode"] == "text" else detect_document
                self.assertEqual(fn(case["input"], fixture["model"], tables), case["expected"])
```

`python3 -B -m unittest discover -s tools/lang/tests -p test_reference.py -v` → red: missing module. Add tests for all 44 normalization cases, every NFC conformance row, and the new runtime fixture including UTF-16 replacement; this reference must earn independence from host Unicode too.

- [ ] **Step 2 — implement exact rounding using rational intervals.** This executable algorithm proves each rounded log weight, without relying on coincidentally matching doubles:

```python
from fractions import Fraction

def round_even(q):
    low, rem = divmod(q.numerator, q.denominator)
    twice = 2 * rem
    return low + int(twice > q.denominator or
                     (twice == q.denominator and low % 2 != 0))

def log_interval(x, terms):
    # For 1 <= x <= 2, 0 <= z <= 1/3. Positive tail has an explicit bound.
    z = (x - 1) / (x + 1)
    power = z
    total = Fraction(0)
    for j in range(terms):
        total += power / (2 * j + 1)
        power *= z * z
    lower = 2 * total
    upper = lower + 2 * power / ((2 * terms + 1) * (1 - z * z))
    return lower, upper

def round_log_weight(numerator, denominator, scale=1024):
    if numerator <= 0 or denominator <= 0 or numerator > denominator:
        raise ValueError("expected 0 < probability <= 1")
    if numerator == denominator:
        return 0
    x = Fraction(numerator, denominator)
    shifts = 0
    while x < 1:
        x *= 2
        shifts += 1
    terms = 8
    while True:
        lo, hi = log_interval(x, terms)
        lo2, hi2 = log_interval(Fraction(2), terms)
        low = scale * (lo - shifts * hi2)
        high = scale * (hi - shifts * lo2)
        a, b = round_even(low), round_even(high)
        if a == b:
            return a
        terms *= 2
```

Test `round_even(Fraction(-5,2))==-2` and `round_even(Fraction(-7,2))==-4`. Cache each `(numerator,denominator,scale)` result. No arbitrary precision cutoff accepts an unproven result.

- [ ] **Step 3 — implement reference normalization/features/export/scoring.** Use explicit surrogate decoding for fixture `utf16Units`. Read pinned category/decomposition/CCC/fold tables. Normalize NFC→fold→NFC before post-cap, classify letters plus attached marks. `features` uses `counts[n-1].update(tuple(padded[i:i+n]) for i in range(len(padded)-n+1))` over each `padded=[-1]+word+[-2]` for n=1,2,3 independently. Select per-profile features by `(-count,tuple)`, union across profiles, tuple-sort, retain original counts for all union members and pool everything outside into UNK. Compute weight with denominator `T+len(V)+1`; shared prior uses `1/profileCount`.

Python score implementation uses `sum(count*weight)//featureCount` with zero guard, `[1,2,3]` order weights, raw tuple-sorted diagnostic counts, and profiles in `background`+targets order. Rank with key `(-combinedScore, 0 if id=='background' else 1, id)`. Evaluate all seven abstention checks in appendix order. Document starts use integer formula and shares over all sampled letters. Return the exact JSON trees, not a lossy label-only result. Store no Unicode/SQLite/environment versions in fixture output; log environment separately.

- [ ] **Step 4 — green and commit.**

```bash
python3 -B -m unittest discover -s tools/lang/tests -p test_reference.py -v
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/lang/reference.py tools/lang/tests/test_reference.py
git commit -m "feat(lang): independent integer reference and proven log-weight export" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all synthetic exported weights and all 32 complete trees match, all normalization rows/cases pass; both existing Core suites remain green.

### Task 5: [Swift] Strict artifact model, scalar normalization and fixture assertions

**Depends on:** 1, 2. **Parallel with:** 3, 4, 6, 8, 10, 11, 12.

**Files:** Create `Sources/AINotebookCore/LanguageJSON.swift`, `LanguageModel.swift`, `LanguageNormalization.swift`; `Tests/AINotebookCoreTests/LanguageModelTests.swift`, `LanguageNormalizationTests.swift`, `LanguageFixtureAssert.swift`.

**Interfaces — Consumes:** `UnicodeTables` and shared validation/normalization/runtime fixtures. **Produces:**

```swift
// Internal APIs; only the facade added in Task 9 is a production model entry point.
enum LanguageJSON {
    static func validate(_ data: Data) throws
}
struct LanguageModel: Sendable {
    static func parse(_ data: Data, tables: UnicodeTables, allowSynthetic: Bool) throws -> LanguageModel
    let targets: [String]
    let parameters: LanguageParameters
    let vocabulary: [LanguageVocabulary]
    let profiles: [LanguageProfile]
    let thresholds: [LanguageThreshold]
}
struct LanguageWords: Codable, Equatable, Sendable {
    let words: [String]
    let wordScalars: [[UInt32]]
    let boundaryWords: [[Int32]]
    let letterCount: Int64
    let wordCount: Int64
}
enum LanguageNormalization {
    static func decode(_ units: [UInt16], cap: Int) -> [UInt32]
    static func stream(_ text: String, tables: UnicodeTables, cap: Int) -> [UInt32]
    static func stream(utf16Units: [UInt16], tables: UnicodeTables, cap: Int) -> [UInt32]
    static func classify(_ scalars: [UInt32], tables: UnicodeTables) -> LanguageWords
}
```

Model record fields exactly mirror appendix §9, including contract/version/kind/modelId/normalization version/alpha/attribution, without dropping them during validation. `LanguageParameters` fields are Int except `orderWeights:[Int64]`; feature tuples `[Int32]`, all learned weights/priors/threshold values Int64. C# peer: `LanguageModel.Parse(ReadOnlySpan<byte>, UnicodeTables, bool allowSynthetic)`, `LanguageNormalization.Decode(IReadOnlyList<ushort>, int) -> int[]`, `Stream(string, UnicodeTables, int) -> int[]`, `Stream(IReadOnlyList<ushort>, UnicodeTables, int) -> int[]`, `Classify(IReadOnlyList<int>, UnicodeTables) -> LanguageWords`; its record properties are PascalCase.

- [ ] **Step 1 — add a reusable full-tree assertion and failing tests.** Test helper has no knowledge of detector semantics:

```swift
import Foundation
import XCTest

func assertLanguageJSON<T: Encodable>(_ actual: T, equals expected: Any,
                                     _ name: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
    let encoded = try JSONEncoder().encode(actual)
    let object = try JSONSerialization.jsonObject(with: encoded)
    let a = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed])
    let b = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys, .fragmentsAllowed])
    XCTAssertEqual(a, b, name, file: file, line: line)
}
```

Normalization test:

```swift
import Foundation
import XCTest
@testable import AINotebookCore
final class LanguageNormalizationTests: XCTestCase {
    func testEveryNormalizationField() throws {
        let u = try UnicodeTables.bundled()
        let root = try SharedFixtures.json("contracts/lang-normalize-v1.json")
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 44)
        for c in cases {
            let scalars: [UInt32]
            if let text = c["input"] as? String {
                scalars = LanguageNormalization.stream(text, tables: u, cap: 5_000_000)
            } else {
                let units = try XCTUnwrap(c["utf16Units"] as? [UInt16])
                scalars = LanguageNormalization.stream(utf16Units: units, tables: u, cap: 5_000_000)
            }
            try assertLanguageJSON(LanguageNormalization.classify(scalars, tables: u),
                                   equals: c["expected"]!, c["name"] as! String)
        }
    }
}
```

Model tests load `lang-artifact-validation-v1`, convert `rawArtifact.utf8` or decode `rawBytesBase64`, then call `LanguageModel.parse(...allowSynthetic:true)`: valid succeeds; every invalid case throws. Separate test serializes the existing synthetic model and verifies `allowSynthetic:false` throws. Run `swift test --filter 'LanguageModelTests|LanguageNormalizationTests'`; expected red: missing types.

- [ ] **Step 2 — implement the raw JSON scanner and model checks.** Validate UTF-8, no BOM, final LF, one complete top-level object, max depth 64. Tokenize strings/escapes/objects/arrays/numbers yourself before Foundation decode. Numbers obey `-?(0|[1-9][0-9]*)`, must fit Int64, and cannot use fraction/exponent syntax anywhere. Maintain a per-object set of **decoded** key strings; reject duplicates including escaped spellings. Validate JSON escapes and paired surrogate escapes; reject an unpaired one. Boolean tokens stay boolean so the schema layer cannot mistake NSNumber booleans for 0/1. Check every object key set against the exact §9 schema, including nested parameters/orders/attribution. Decode to typed records only after lexical validation.

Enforce all appendix §6 semantics: production constants equal §1, synthetic differences restricted to the expressly allowed parameters, strict ordered profiles/vocabulary/thresholds, legal scalar symbols, vocabulary length/tuple order, BOS/EOS positioning and feature categories, cap relationships, all weights bounds, exact prior lookup `3:-1125,4:-1420,5:-1648`. Boundary-only unigrams are valid; mark-only interior tuples can represent attached marks, but BOS followed by a mark and boundary-only `[-1,-2]` are invalid. Validate synthetic empty attribution versus production nonempty attribution fields. No `try!`, forced unwrap on external data, inferred defaults or host floating point.

- [ ] **Step 3 — implement scalar decoding, normalization and classification.**

```swift
static func decode(_ units: [UInt16], cap: Int) -> [UInt32] {
    var result: [UInt32] = []
    var i = 0
    while i < units.count && result.count < cap {
        let a = UInt32(units[i])
        if (0xD800...0xDBFF).contains(a), i + 1 < units.count,
           (0xDC00...0xDFFF).contains(UInt32(units[i + 1])) {
            result.append(0x10000 + (a - 0xD800) * 1024 + UInt32(units[i + 1]) - 0xDC00)
            i += 2
        } else {
            result.append((0xD800...0xDFFF).contains(a) ? 0xFFFD : a)
            i += 1
        }
    }
    return result
}
```

For String stream, take `.unicodeScalars.prefix(cap).map(\.value)`, then `Array(tables.nfc(tables.fullCaseFold(tables.nfc(decoded))).prefix(cap))`. UTF16 stream uses the decoder then that same pipeline. Do not cap intermediate decompositions/folds before final NFC. Classification flushes on all non-L/M categories; leading M is discarded, attached M extends a word but contributes no letters. Produce boundaryWords independently from scalars using Int32 -1/-2. Text-mode cap belongs in scorer/facade, not in normalization fixture classification. Add a runtime-fixture test for every `normalize` operation, comparing stream before text cap and classification after the requested mode cap.

- [ ] **Step 4 — green and commit.**

```bash
swift test --filter 'LanguageModelTests|LanguageNormalizationTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/LanguageJSON.swift Sources/AINotebookCore/LanguageModel.swift Sources/AINotebookCore/LanguageNormalization.swift Tests/AINotebookCoreTests/LanguageModelTests.swift Tests/AINotebookCoreTests/LanguageNormalizationTests.swift Tests/AINotebookCoreTests/LanguageFixtureAssert.swift
git commit -m "feat(core): strict language model parsing and scalar normalization" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: 44 full normalization trees, every supplemental normalization case, all malformed artifact cases and production-rejects-synthetic pass; full suites green.

### Task 6: [Windows] Strict artifact model, scalar normalization and fixture assertions

**Depends on:** 1, 3. **Parallel with:** 2, 4, 5, 7, 9, 11, 12.

**Files:** Create `windows/src/AINotebook.Core/Language/LanguageModel.cs`, `LanguageNormalization.cs`; `windows/tests/AINotebook.Core.Tests/Language/LanguageModelTests.cs`, `LanguageNormalizationTests.cs`, `LanguageFixtureAssert.cs`.

**Interfaces — Consumes:** pinned `UnicodeTables`, shared artifact/normalization fixtures. **Produces:** internal immutable `LanguageModel.Parse(ReadOnlySpan<byte> data, UnicodeTables tables, bool allowSynthetic) -> LanguageModel`; internal `LanguageNormalization.Decode(IReadOnlyList<ushort> units, int cap) -> int[]`, `Stream(string text, UnicodeTables tables, int cap) -> int[]`, `Stream(IReadOnlyList<ushort> units, UnicodeTables tables, int cap) -> int[]`, `Classify(IReadOnlyList<int> scalars, UnicodeTables tables) -> LanguageWords`. `LanguageWords` has `Words:string[]`, `WordScalars:int[][]`, `BoundaryWords:int[][]`, `LetterCount:long`, `WordCount:long`; camelCase JSON.

Swift peer: `LanguageModel.parse(_:tables:allowSynthetic:) throws -> LanguageModel`; `LanguageNormalization.decode(_:cap:) -> [UInt32]`, `stream(_:tables:cap:) -> [UInt32]`, `stream(utf16Units:tables:cap:) -> [UInt32]`, `classify(_:tables:) -> LanguageWords` with the exact argument types declared in Task 5.

- [ ] **Step 1 — write failing tests with structural comparison.** Put this helper in `LanguageFixtureAssert.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Nodes;
using Xunit;
namespace AINotebook.Core.Tests.Language;
internal static class LanguageFixtureAssert
{
    internal static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.Never
    };
    internal static void Equal<T>(JsonElement expected, T actual, string name)
    {
        var a = JsonSerializer.SerializeToNode(actual, Json);
        var e = JsonNode.Parse(expected.GetRawText());
        Assert.True(JsonNode.DeepEquals(e, a), $"{name}\nexpected: {e}\nactual: {a}");
    }
}
```

```csharp
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Language;
public sealed class LanguageNormalizationTests
{
    [Fact]
    public void EveryNormalizationField()
    {
        var u = UnicodeTables.LoadBundled();
        var cases = SharedFixtures.Json("contracts/lang-normalize-v1.json").GetProperty("cases");
        Assert.Equal(44, cases.GetArrayLength());
        foreach (var c in cases.EnumerateArray())
        {
            int[] stream = c.TryGetProperty("input", out var text)
                ? LanguageNormalization.Stream(text.GetString()!, u, 5_000_000)
                : LanguageNormalization.Stream(c.GetProperty("utf16Units").EnumerateArray()
                    .Select(x => x.GetUInt16()).ToArray(), u, 5_000_000);
            LanguageFixtureAssert.Equal(c.GetProperty("expected"),
                LanguageNormalization.Classify(stream, u), c.GetProperty("name").GetString()!);
        }
    }
}
```

Artifact test loops every validation case, decodes its one raw representation, calls `LanguageModel.Parse(bytes,u,true)` and asserts success or `InvalidDataException`. A second Fact feeds synthetic model bytes with false and requires rejection. Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~LanguageModelTests|FullyQualifiedName~LanguageNormalizationTests'`; expected red: types absent.

- [ ] **Step 2 — implement strict parsing and model validation.** `Utf8JsonReader` with comments/trailing commas disabled and max depth 64; require LF and no BOM before reading. Track decoded key sets per object, reject duplicate keys and unpaired surrogate escapes in raw strings before `GetString`; reject every nondecimal-integer number token by scanning `ValueSpan`, then `TryGetInt64`. Strict UTF-8 decoder throws on invalid sequences. Validate schema key sets, JSON kinds, ranges and §6 semantic invariants before constructing immutable records. Use prior integer lookup 3→-1125,4→-1420,5→-1648. Validate all ordered arrays and copies; `allowSynthetic` is internal and cannot be selected by a production manifest. Never let `JsonSerializer`'s permissive unknown-key/default/null handling replace the validator. All external-data failure paths throw `InvalidDataException` for the facade to catch.

- [ ] **Step 3 — implement explicit UTF-16 decoding and pinned normalization.**

```csharp
internal static int[] Decode(IReadOnlyList<ushort> units, int cap)
{
    var result = new List<int>(Math.Min(units.Count, cap));
    int i = 0;
    while (i < units.Count && result.Count < cap)
    {
        int a = units[i];
        if (a is >= 0xD800 and <= 0xDBFF && i + 1 < units.Count &&
            units[i + 1] is >= 0xDC00 and <= 0xDFFF)
        {
            result.Add(0x10000 + (a - 0xD800) * 1024 + units[i + 1] - 0xDC00);
            i += 2;
        }
        else
        {
            result.Add(a is >= 0xD800 and <= 0xDFFF ? 0xFFFD : a);
            i++;
        }
    }
    return result.ToArray();
}
```

String overload iterates original char units through this exact rule; avoid materializing an unbounded whole-string ushort array when cap is smaller. Normalize entire decoded prefix as NFC→fold→NFC, then cap expansions. Classify through pinned categories: L increments letters and starts/appends; M only appends when active; otherwise flush. Count words on flush. Build strings with `char.ConvertFromUtf32` only from validated scalars. Add fixture loop for all `lang-runtime-v1` normalization rows and a C# string containing an actual isolated high surrogate to prove the String path matches units.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~LanguageModelTests|FullyQualifiedName~LanguageNormalizationTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Language/LanguageModel.cs windows/src/AINotebook.Core/Language/LanguageNormalization.cs windows/tests/AINotebook.Core.Tests/Language/LanguageModelTests.cs windows/tests/AINotebook.Core.Tests/Language/LanguageNormalizationTests.cs windows/tests/AINotebook.Core.Tests/Language/LanguageFixtureAssert.cs
git commit -m "feat(win-core): strict language model and pinned normalization" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all normalization fields/malformed artifacts pass, String and explicit UTF16 paths agree, full suites green.

### Task 7: [Swift] Feature extraction, integer scoring and abstention

**Depends on:** 5. **Parallel with:** 3, 4, 6, 8, 10, 11, 12.

**Files:** Create `Sources/AINotebookCore/LanguageScorer.swift`, `Tests/AINotebookCoreTests/LanguageScorerTests.swift`.

**Interfaces — Consumes:** validated `LanguageModel`, `UnicodeTables`, `LanguageNormalization.classify`. **Produces:** internal `LanguageScorer.init(model: LanguageModel, tables: UnicodeTables)`, `func score(_ scalars: [UInt32]) -> LanguageTextResult`, `static func floorDiv(_ a: Int64, _ b: Int64) -> Int64`; read-only internal `model`/`tables` for document/facade consumers. C# peer: `new LanguageScorer(LanguageModel model, UnicodeTables tables)`, `Score(IReadOnlyList<int>) -> LanguageTextResult`, `static long FloorDiv(long,long)`, internal `Model`/`Tables`.

Public immutable `LanguageTextResult: Codable, Equatable, Sendable` fields (camelCase JSON): `words:[String]`, `wordScalars:[[UInt32]]`, `letterCount:Int64`, `wordCount:Int64`, `bucketStart:Int?`, `features:[[LanguageFeatureCount]]` where `{symbols:[Int32],count:Int64}`, `featureCounts:[Int64]`, `knownCounts:[Int64]`, `unknownCounts:[Int64]`, `profiles:[String:LanguageProfileScore]` where `{weightedSums:[Int64],orderScores:[Int64],combinedScore:Int64}`, `winner:String`, `runnerUp:String`, `margin:Int64`, `coverageBp:Int64`, `label:String`, `reason:String`. Exclude `boundaryWords` from the text result, because the fixture does. Encode `bucketStart` explicitly as null when absent. C# twin uses the same fields with PascalCase and long, int[] scalar tuples.

- [ ] **Step 1 — write failing tests.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore
final class LanguageScorerTests: XCTestCase {
    func testEveryTextIntermediate() throws {
        let f = try SharedFixtures.json("contracts/lang-score-v1.json")
        let u = try UnicodeTables.bundled()
        let bytes = try JSONSerialization.data(withJSONObject: f["model"]!) + Data([10])
        let model = try LanguageModel.parse(bytes, tables: u, allowSynthetic: true)
        let scorer = LanguageScorer(model: model, tables: u)
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
            .filter { $0["mode"] as? String == "text" }
        XCTAssertEqual(cases.count, 23)
        for c in cases {
            let stream = LanguageNormalization.stream(c["input"] as! String, tables: u,
                                                      cap: model.parameters.inputCapScalars)
            let result = scorer.score(Array(stream.prefix(model.parameters.textCapScalars)))
            try assertLanguageJSON(result, equals: c["expected"]!, c["name"] as! String)
        }
    }
    func testSignedFloorDivision() {
        XCTAssertEqual(LanguageScorer.floorDiv(-7, 3), -3)
        XCTAssertEqual(LanguageScorer.floorDiv(-6, 3), -2)
        XCTAssertEqual(LanguageScorer.floorDiv(7, 3), 2)
    }
}
```

`swift test --filter LanguageScorerTests` → red: missing scorer. The synthetic fixture's `accept-xa` must specifically yield sums `[-19194,-19260,-16782]`, order scores `[-1067,-1284,-1399]`, total `-8957`; whole-tree equality already checks these values.

- [ ] **Step 2 — implement feature counting and score math.**

```swift
static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    precondition(b > 0)
    return a / b - ((a < 0 && a % b != 0) ? 1 : 0)
}
func countFeatures(_ words: [[UInt32]]) -> [[[Int32]: Int64]] {
    var orders = Array(repeating: [[Int32]: Int64](), count: 3)
    for word in words {
        let padded = [Int32(-1)] + word.map(Int32.init) + [Int32(-2)]
        for n in 1...3 where padded.count >= n {
            for i in 0...(padded.count - n) {
                orders[n - 1][Array(padded[i..<(i + n)]), default: 0] += 1
            }
        }
    }
    return orders
}
```

Build vocabulary dictionaries keyed by scalar tuples, and per-order raw features sorted with `.lexicographicallyPrecedes`. For each profile/order sum `count * knownWeight` or `count * unknownWeight` into Int64. Unknown raw tuples remain distinct diagnostics. `F=sum counts`, `K=sum counts with vocabulary membership`, `U=F-K`; orderScore is floorDiv(sum,F), or zero when F=0. Combined=`prior+order1+2*order2+3*order3`; coverage=`10000*sum(K)/sum(F)`, or zero. Rank all profiles score descending, background before targets at ties, target IDs ASCII ascending. Minima check order is letters, words, enabled bucket, background, winning score, margin, coverage. Equality passes. BucketStart is computed even if minWords fails; below 12 is null. Never replace short-input diagnostics with an empty result.

Add behavioral tests from supplemental fixtures at each threshold equality and the 8192 production text cap using a validated synthetic parameter variant (do not enable synthetic through public production loading). Do not change fixture expected outputs to match code.

- [ ] **Step 3 — green and commit.**

```bash
swift test --filter LanguageScorerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/LanguageScorer.swift Tests/AINotebookCoreTests/LanguageScorerTests.swift
git commit -m "feat(core): integer language scoring and abstention diagnostics" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all 23 complete text cases pass, including score/margin/coverage/background/disabled-bucket abstention, all full suites green.

### Task 8: [Windows] Feature extraction, integer scoring and abstention

**Depends on:** 6. **Parallel with:** 2, 4, 5, 7, 9, 11, 12.

**Files:** Create `windows/src/AINotebook.Core/Language/LanguageScorer.cs`, `windows/tests/AINotebook.Core.Tests/Language/LanguageScorerTests.cs`.

**Interfaces — Consumes:** validated model and pinned classification. **Produces:** internal `LanguageScorer(LanguageModel model, UnicodeTables tables)`, `LanguageTextResult Score(IReadOnlyList<int> scalars)`, `static long FloorDiv(long a,long b)`, internal `Model`/`Tables`. Public immutable `LanguageTextResult` carries `Words:string[]`, `WordScalars:int[][]`, `LetterCount:long`, `WordCount:long`, `BucketStart:int?`, `Features:LanguageFeatureCount[][]`, `FeatureCounts/KnownCounts/UnknownCounts:long[]`, `Profiles:IReadOnlyDictionary<string,LanguageProfileScore>`, `Winner/RunnerUp/Label/Reason:string`, `Margin/CoverageBp:long`. Feature count has `Symbols:int[]`, `Count:long`; profile score has `WeightedSums/OrderScores:long[]`, `CombinedScore:long`. Serialize camelCase, explicit null, and no extra fields. Do not expose mutable internal arrays from the model. Result-array fields are fresh per-call diagnostic snapshots; mutation cannot affect the scorer, another result or document aggregation. If immutable public collection types are required, wrap copied arrays with read-only collection interfaces before publication and preserve the same JSON tree.

Swift peer: `LanguageScorer(model:tables:)`, `score(_ scalars: [UInt32]) -> LanguageTextResult`, `static floorDiv(_ a:Int64,_ b:Int64) -> Int64` and equivalent immutable result declared in Task 7.

- [ ] **Step 1 — write failing tests.**

```csharp
using System.Text;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Language;
public sealed class LanguageScorerTests
{
    [Fact]
    public void EveryTextIntermediate()
    {
        var f = SharedFixtures.Json("contracts/lang-score-v1.json");
        var u = UnicodeTables.LoadBundled();
        var model = LanguageModel.Parse(Encoding.UTF8.GetBytes(f.GetProperty("model").GetRawText() + "\n"), u, true);
        var scorer = new LanguageScorer(model, u);
        var cases = f.GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("mode").GetString() == "text").ToArray();
        Assert.Equal(23, cases.Length);
        foreach (var c in cases)
        {
            var stream = LanguageNormalization.Stream(c.GetProperty("input").GetString()!, u, model.Parameters.InputCapScalars);
            var result = scorer.Score(stream.Take(model.Parameters.TextCapScalars).ToArray());
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
        }
    }
    [Theory]
    [InlineData(-7L, 3L, -3L)]
    [InlineData(-6L, 3L, -2L)]
    [InlineData(7L, 3L, 2L)]
    public void SignedFloorDivision(long a, long b, long expected) =>
        Assert.Equal(expected, LanguageScorer.FloorDiv(a, b));
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~LanguageScorerTests`; expected red: scorer missing.

- [ ] **Step 2 — implement integer math and tuple keys.**

```csharp
internal static long FloorDiv(long a, long b)
{
    if (b <= 0) throw new ArgumentOutOfRangeException(nameof(b));
    return a / b - (a < 0 && a % b != 0 ? 1 : 0);
}
internal readonly record struct Feature(int Length, int A, int B, int C)
{
    internal static Feature From(int[] p, int start, int length) =>
        new(length, p[start], length > 1 ? p[start + 1] : 0, length > 2 ? p[start + 2] : 0);
    internal int[] Symbols() => Length switch
    {
        1 => new[] { A }, 2 => new[] { A, B }, 3 => new[] { A, B, C },
        _ => throw new InvalidOperationException("invalid feature length")
    };
}
```

Dictionary keys use value equality, not array reference equality. For each word form `[-1]+scalars+[-2]`, enumerate all contiguous tuples of lengths 1,2,3 and increment long counts. Sort feature diagnostics signed by A/B/C within each order. Accumulate checked long products under validated caps/weight bounds, with one unknown bucket per order. Compute floor scores and unweighted occurrence coverage exactly as appendix equations. Rank with score descending, background tie priority then `StringComparer.Ordinal` target ID; minLetters→minWords→bucketDisabled→background→minWinningScore→minMargin→minKnownCoverageBp is the mandatory rejection order. All diagnostics remain populated on abstention. A cap never cuts UTF-16 pairs; scorer receives already normalized scalar slices.

Consume supplemental equality/text-cap cases in a separate Fact; verify profiles with no features score zero per order and retain prior. Avoid any float/double/decimal runtime scoring path.

- [ ] **Step 3 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~LanguageScorerTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Language/LanguageScorer.cs windows/tests/AINotebook.Core.Tests/Language/LanguageScorerTests.cs
git commit -m "feat(win-core): integer language scoring and abstention diagnostics" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all 23 text fixture trees and arithmetic boundary tests pass, full suites green.

### Task 9: [Swift] Document mode, verified bundle loading and WP6/WP8 hooks

**Depends on:** 7. **Parallel with:** 4, 6, 8, 10, 11, 12.

**Files:** Create `Sources/AINotebookCore/LanguageDetector.swift`, `LanguageDocument.swift`, `ChunkLanguage.swift`; `Tests/AINotebookCoreTests/LanguageDetectorTests.swift`, `LanguageDocumentTests.swift`.

**Interfaces — Consumes:** scorer/model/Unicode tables; shared document/runtime/inheritance/loading fixtures. **Produces:**

```swift
public struct LanguageDetector: Sendable {
    public static func bundled() -> LanguageDetector
    public static var unavailable: LanguageDetector { get }
    public var isAvailable: Bool { get }
    public func detectText(_ text: String) -> LanguageTextResult?
    public func detectText(utf16Units: [UInt16]) -> LanguageTextResult?
    public func detectDocument(_ text: String) -> LanguageDocumentResult?
    public func detectDocument(utf16Units: [UInt16]) -> LanguageDocumentResult?
    // Internal test seams; these are not public deployment bypasses.
    init(testModelData: Data, tables: UnicodeTables) throws
    static func load(readResource: (String) throws -> Data) -> LanguageDetector
    static func bundledResourceData(_ name: String) throws -> Data
}
public struct LanguageWindow: Codable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let expected: LanguageTextResult
}
public struct LanguageDocumentResult: Codable, Equatable, Sendable {
    public let normalizedScalarCount: Int
    public let windowCount: Int
    public let windowScalars: Int
    public let windows: [LanguageWindow]
    public let sampledLetters: Int64
    public let acceptedLetters: [String: Int64]
    public let unknownLetters: Int64
    public let sharesBp: [String: Int64]
    public let unknownShareBp: Int64
    public let langCoverageBp: Int64
    public let label: String
    public let reason: String
}
public struct ChunkLanguage: Codable, Equatable, Sendable {
    public let lang: String?
    public let langInherited: Bool
    public static func resolve(label: String?, reason: String?, documentLabel: String?) -> ChunkLanguage
}
enum LanguageDocument {
    static func ranges(length: Int, count: Int, size: Int) -> [Range<Int>]
    static func detect(stream: [UInt32], scorer: LanguageScorer) -> LanguageDocumentResult
    static func aggregate(targets: [String], labels: [String], letters: [Int64]) -> LanguageAggregate
}
```

`LanguageAggregate` has the eight aggregation fields from sampledLetters through reason in `LanguageDocumentResult`. Explicitly encode `ChunkLanguage.lang=nil` as JSON null. C# peer: `LanguageDetector.LoadBundled() -> LanguageDetector`, `Unavailable`, `IsAvailable`, `DetectText(string) -> LanguageTextResult?`, `DetectText(IReadOnlyList<ushort>) -> LanguageTextResult?`, `DetectDocument(string) -> LanguageDocumentResult?`, `DetectDocument(IReadOnlyList<ushort>) -> LanguageDocumentResult?`; internal `CreateForTests(byte[],UnicodeTables)` / `Load(Func<string,byte[]>)` / `ReadBundledResource(string) -> byte[]`; `ChunkLanguage.Resolve(string? label,string? reason,string? documentLabel) -> ChunkLanguage`; `LanguageDocument.Ranges(int,int,int) -> (int Start,int End)[]`, `Detect(IReadOnlyList<int>,LanguageScorer)`, `Aggregate(string[],string[],long[])`.

- [ ] **Step 1 — write failing document/facade tests.**

```swift
import Foundation
import XCTest
@testable import AINotebookCore
final class LanguageDocumentTests: XCTestCase {
    func testEveryDocumentIntermediate() throws {
        let f = try SharedFixtures.json("contracts/lang-score-v1.json")
        let data = try JSONSerialization.data(withJSONObject: f["model"]!) + Data([10])
        let detector = try LanguageDetector(testModelData: data, tables: UnicodeTables.bundled())
        let cases = try XCTUnwrap(f["cases"] as? [[String: Any]])
            .filter { $0["mode"] as? String == "document" }
        XCTAssertEqual(cases.count, 9)
        for c in cases {
            let result = try XCTUnwrap(detector.detectDocument(c["input"] as! String))
            try assertLanguageJSON(result, equals: c["expected"]!, c["name"] as! String)
        }
    }
}
final class LanguageDetectorTests: XCTestCase {
    func testUnavailablePreservesNull() {
        let detector = LanguageDetector.load { _ in throw CocoaError(.fileReadNoSuchFile) }
        XCTAssertFalse(detector.isAvailable)
        XCTAssertNil(detector.detectText("Toto je dostatečně dlouhý český text."))
        XCTAssertNil(detector.detectDocument("This is a complete document."))
        XCTAssertEqual(ChunkLanguage.resolve(label: nil, reason: nil, documentLabel: "cs"),
                       ChunkLanguage(lang: nil, langInherited: false))
    }
    func testEveryInheritanceCase() throws {
        let f = try SharedFixtures.json("contracts/lang-inheritance-v1.json")
        for c in try XCTUnwrap(f["cases"] as? [[String: Any]]) {
            let i = c["input"] as! [String: Any]
            let result = ChunkLanguage.resolve(label: i["label"] as? String,
                reason: i["reason"] as? String, documentLabel: i["documentLabel"] as? String)
            try assertLanguageJSON(result, equals: c["expected"]!, c["name"] as! String)
        }
    }
}
```

`swift test --filter 'LanguageDocumentTests|LanguageDetectorTests'` → red: missing APIs. Add fixture loops for supplemental `windows`/`aggregate` and bundle-failure cases before implementation. Include concurrent repeated calls on one detector and verify immutable identical results.

- [ ] **Step 2 — implement sampling/aggregation with concrete integer code.**

```swift
static func ranges(length n: Int, count c: Int, size s: Int) -> [Range<Int>] {
    guard n > 0 else { return [] }
    let k = min(c, (n + s - 1) / s)
    let w = min(s, n / k)
    return (0..<k).map { i in
        let start = k == 1 ? 0 : i * (n - w) / (k - 1)
        return start..<(start + w)
    }
}
```

Normalize once with the input cap; document mode never applies textCap to the whole stream. For each range, call scorer on the original normalized scalar slice, without another NFC/fold operation. Window DTO property `expected` contains its complete text score so it matches the fixture exactly. Empty stream returns zero windowCount/windowScalars. Aggregate using Int64:

```swift
let total = letters.reduce(0, +)
var accepted = Dictionary(uniqueKeysWithValues: targets.map { ($0, Int64(0)) })
var unknown: Int64 = 0
for (label, count) in zip(labels, letters) {
    if accepted[label] != nil { accepted[label, default: 0] += count }
    else { unknown += count }
}
let shares = accepted.mapValues { total == 0 ? 0 : 10_000 * $0 / total }
let unknownShare = total == 0 ? 0 : 10_000 * unknown / total
let coverage = total == 0 ? 0 : 10_000 * accepted.values.reduce(0, +) / total
let dominant = targets.first { accepted[$0, default: 0] > 0 &&
    10_000 * accepted[$0, default: 0] >= 7_000 * total }
let confidentTargets = accepted.values.filter { $0 > 0 }.count
let label = dominant ?? (confidentTargets >= 2 ? "mixed" : "und")
let reason = dominant != nil ? "dominant" : (confidentTargets >= 2 ? "mixed" : "insufficientEvidence")
```

Construct `LanguageAggregate` from these exact fields. Validate zip input lengths in internal fixture seam. Normalized offsets must never be used as canonical-text spans by callers.

- [ ] **Step 3 — implement verified resources and graceful failure.** `load` takes resource names, reads immutable bytes once, verifies Unicode table sidecar and pinned `unicode-sources-v1.json`, validates manifest lexical/schema semantics, compares its `environment.unicodeFiles` to all four pinned sources and normalization version, hashes exact artifact bytes against `artifactSha256`, verifies `modelId`, targets/production kind and shared attribution equality, checks embedded `NOTICE` and `ATTRIBUTION.md` hashes. Reject arbitrary path traversal: manifest artifactPath and attribution paths identify the committed repository paths, mapped by a fixed allowlist to bundle resource names; never read an arbitrary path supplied by the model. A changed normalization version or a source hash mismatch is unavailable, not fallback. Use the full manifest §10 shape, with exact unique compound keys, valid dates, support/count reconciliation and integer-only lexical validation; no new fields added to it.

Call throwing helpers in a `do/catch` and construct `.unavailable` on a missing resource, digest failure or validation failure. Cache the successful immutable bundle load through a static let, without holding mutable global dictionaries. Bundle contains no production model until Task 13, which is an expected unavailable state during this task. Do not make pre-artifact tests assume the bundle stays unavailable after Task 13. Production loading must reject the synthetic fixture even when its digest is valid. Internal test initializer loads only explicitly provided fixture bytes and is never called by `bundled()`.

- [ ] **Step 4 — implement inheritance and record handoff.**

```swift
public static func resolve(label: String?, reason: String?, documentLabel: String?) -> ChunkLanguage {
    guard let label else { return ChunkLanguage(lang: nil, langInherited: false) }
    if label == "und", reason == "minLetters" || reason == "minWords",
       let documentLabel, ["cs", "de", "en", "sk"].contains(documentLabel) {
        return ChunkLanguage(lang: documentLabel, langInherited: true)
    }
    return ChunkLanguage(lang: label, langInherited: false)
}
```

WP6's exact call sequence: `let document = detector.detectDocument(canonicalText)` once; for each chunk `let text = detector.detectText(chunk.text)` then `ChunkLanguage.resolve(label:text?.label, reason:text?.reason, documentLabel:document?.label)`. Persist document `.label` and integer coverage/shares with the revision publication, chunk `.lang/.langInherited` with its own revision. NULL detection does not erase an older published revision's language metadata. WP8 scope headers receive persisted per-source labels and `sharesBp/langCoverageBp`, include `und/mixed` as such, and omit/mark unavailable NULL; they never derive document language by adding overlapping chunk scores. No store, ingestion or prompt edits here.

- [ ] **Step 5 — green and commit.**

```bash
swift test --filter 'LanguageDocumentTests|LanguageDetectorTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add Sources/AINotebookCore/LanguageDetector.swift Sources/AINotebookCore/LanguageDocument.swift Sources/AINotebookCore/ChunkLanguage.swift Tests/AINotebookCoreTests/LanguageDetectorTests.swift Tests/AINotebookCoreTests/LanguageDocumentTests.swift
git commit -m "feat(core): document language and verified nullable detector hooks" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all nine complete document trees, exact dominance boundaries, no-overlap sampling, nullable load failures and inheritance rows pass; both suites green.

### Task 10: [Windows] Document mode, verified embedded loading and WP6/WP8 hooks

**Depends on:** 8. **Parallel with:** 4, 5, 7, 9, 11, 12.

**Files:** Create `windows/src/AINotebook.Core/Language/LanguageDetector.cs`, `LanguageDocument.cs`, `ChunkLanguage.cs`; `windows/tests/AINotebook.Core.Tests/Language/LanguageDetectorTests.cs`, `LanguageDocumentTests.cs`.

**Interfaces — Consumes:** Windows scorer/model and same shared fixtures. **Produces:** public `LanguageDetector.LoadBundled() -> LanguageDetector`, `static LanguageDetector Unavailable`, `bool IsAvailable`, `LanguageTextResult? DetectText(string text)`, `DetectText(IReadOnlyList<ushort> utf16Units)`, `LanguageDocumentResult? DetectDocument(string text)`, `DetectDocument(IReadOnlyList<ushort> utf16Units)`; internal `static LanguageDetector CreateForTests(byte[] modelData,UnicodeTables tables)`, `static LanguageDetector Load(Func<string,byte[]> readResource)`, `static byte[] ReadBundledResource(string name)`.

Public `LanguageWindow(int Start,int End,LanguageTextResult Expected)` and `LanguageDocumentResult` with `NormalizedScalarCount/WindowCount/WindowScalars:int`, `Windows:LanguageWindow[]`, `SampledLetters/UnknownLetters/UnknownShareBp/LangCoverageBp:long`, `AcceptedLetters/SharesBp:IReadOnlyDictionary<string,long>`, `Label/Reason:string`. Public `ChunkLanguage(string? Lang,bool LangInherited)` with `static Resolve(string? label,string? reason,string? documentLabel)`. Internal `LanguageDocument.Ranges(int length,int count,int size) -> (int Start,int End)[]`, `Detect(IReadOnlyList<int> stream,LanguageScorer scorer) -> LanguageDocumentResult`, `Aggregate(string[] targets,string[] labels,long[] letters) -> LanguageAggregate` (aggregation fields as Task 9).

Swift peer contract: `LanguageDetector.bundled() -> LanguageDetector`, `.unavailable`, `.isAvailable`, `detectText(_ text:String) -> LanguageTextResult?`, `detectText(utf16Units:[UInt16]) -> LanguageTextResult?`, `detectDocument(_ text:String) -> LanguageDocumentResult?`, `detectDocument(utf16Units:[UInt16]) -> LanguageDocumentResult?`; `ChunkLanguage.resolve(label:reason:documentLabel:) -> ChunkLanguage`.

- [ ] **Step 1 — write failing tests.**

```csharp
using System.Text;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Language;
public sealed class LanguageDocumentTests
{
    [Fact]
    public void EveryDocumentIntermediate()
    {
        var f = SharedFixtures.Json("contracts/lang-score-v1.json");
        var detector = LanguageDetector.CreateForTests(
            Encoding.UTF8.GetBytes(f.GetProperty("model").GetRawText() + "\n"), UnicodeTables.LoadBundled());
        var cases = f.GetProperty("cases").EnumerateArray()
            .Where(c => c.GetProperty("mode").GetString() == "document").ToArray();
        Assert.Equal(9, cases.Length);
        foreach (var c in cases)
        {
            var result = detector.DetectDocument(c.GetProperty("input").GetString()!);
            Assert.NotNull(result);
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
        }
    }
}
public sealed class LanguageDetectorTests
{
    [Fact]
    public void UnavailablePreservesNull()
    {
        var detector = LanguageDetector.Load(_ => throw new FileNotFoundException());
        Assert.False(detector.IsAvailable);
        Assert.Null(detector.DetectText("Toto je dostatečně dlouhý český text."));
        Assert.Null(detector.DetectDocument("This is a complete document."));
        Assert.Equal(new ChunkLanguage(null, false), ChunkLanguage.Resolve(null, null, "cs"));
    }
    [Fact]
    public void EveryInheritanceCase()
    {
        foreach (var c in SharedFixtures.Json("contracts/lang-inheritance-v1.json").GetProperty("cases").EnumerateArray())
        {
            var i = c.GetProperty("input");
            var result = ChunkLanguage.Resolve(i.GetProperty("label").GetString(),
                i.GetProperty("reason").GetString(), i.GetProperty("documentLabel").GetString());
            LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, c.GetProperty("name").GetString()!);
        }
    }
}
```

Run `dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~LanguageDocumentTests|FullyQualifiedName~LanguageDetectorTests'`; expected red: missing APIs. Add cases for every supplemental window/aggregate/loading fixture and parallel calls returning identical immutable snapshots.

- [ ] **Step 2 — implement document ranges and letter aggregation.**

```csharp
internal static (int Start, int End)[] Ranges(int length, int count, int size)
{
    if (length == 0) return Array.Empty<(int, int)>();
    int k = Math.Min(count, (length + size - 1) / size);
    int w = Math.Min(size, length / k);
    return Enumerable.Range(0, k).Select(i =>
    {
        int start = k == 1 ? 0 : (int)((long)i * (length - w) / (k - 1));
        return (start, start + w);
    }).ToArray();
}
```

Each slice is scored without renormalization. `T=letters.Sum()`, A starts at zero for every model target, and unknown sums all und-window letters. Shares use `T==0 ? 0 : 10000L*A/T`, independently. Dominance uses unrounded `10000L*A >= 7000L*T` with A>0; else at least two nonzero A gives mixed; otherwise und/insufficientEvidence. Return full windows and diagnostics exactly as fixture. The entire normalized stream is available to sampling before text cap; at most eight nonoverlapping equal-size windows.

- [ ] **Step 3 — load verified embedded resources and implement inheritance.** The reader maps fixed filenames to `AINotebook.Core.Language.` resource names. Parse and validate full manifest §10 with strict keys/kinds/calendar dates/compound-key uniqueness/provenance reconciliation, validate four Unicode pins plus table sidecar, exact artifact SHA, modelId/production model parameters, attribution equality and packaged NOTICE/ATTRIBUTION hashes. Raw parser rejects malformed UTF-8/surrogates/duplicate keys/exponent integers before DTO decode. Do not perform runtime logarithms. Compare digests with `CryptographicOperations.FixedTimeEquals` after hex validation, then load immutable scorer. Catch expected missing-resource, data/JSON/IO/format exceptions and return `Unavailable`; avoid `TypeInitializationException` by caching the already nonthrowing result with `Lazy<LanguageDetector>`. Never catch process-fatal exceptions to feign a successful detector. No Windows.Storage, Package.Current, registry or network access.

```csharp
public static ChunkLanguage Resolve(string? label, string? reason, string? documentLabel)
{
    if (label is null) return new(null, false);
    if (label == "und" && reason is "minLetters" or "minWords" &&
        documentLabel is "cs" or "de" or "en" or "sk")
        return new(documentLabel, true);
    return new(label, false);
}
```

WP6 consumes `document=detector.DetectDocument(canonicalText)` and `text=detector.DetectText(chunk.Text)`, then `ChunkLanguage.Resolve(text?.Label,text?.Reason,document?.Label)`. It persists with the revision under store locking. WP8 consumes stored labels and integer coverage, never filters evidence by language. Keep these callers outside this task's file ownership.

- [ ] **Step 4 — green and commit.**

```bash
dotnet test windows/tests/AINotebook.Core.Tests --filter 'FullyQualifiedName~LanguageDocumentTests|FullyQualifiedName~LanguageDetectorTests'
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add windows/src/AINotebook.Core/Language/LanguageDetector.cs windows/src/AINotebook.Core/Language/LanguageDocument.cs windows/src/AINotebook.Core/Language/ChunkLanguage.cs windows/tests/AINotebook.Core.Tests/Language/LanguageDetectorTests.cs windows/tests/AINotebook.Core.Tests/Language/LanguageDocumentTests.cs
git commit -m "feat(win-core): document language and verified nullable detector hooks" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all document/intermediate/load/inheritance fixture comparisons pass; both Core suites green. Windows build/test gates remain the existing CI commands, with no App code edits.

### Task 11: [Shared] Offline corpus preparation, translation groups and augmentation

**Depends on:** 4 and merged WP1 inventory. **Parallel with:** 2, 3, 5, 6, 7, 8, 9, 10.

**Files:** Create `tools/lang/prepare_corpus.py`, `tools/lang/tests/test_prepare_corpus.py`. No corpus acquisition in this task.

**Interfaces — Consumes:** pinned local TSVs + lock from future approved Task 13; pinned normalization from reference. **Produces:** Python `group_id(record_keys: list[str]) -> str`, `build_components(source_id: str, sentence_ids: list[int], links: list[tuple[int,int]]) -> list[dict]`, `split_group(group_id: str, seed: int, split_bp: tuple[int,int,int]) -> str`, `prepare(data_dir: Path, lock: dict, config: dict, output_dir: Path) -> dict`, `snapshot_wp1(root: Path) -> dict`; CLI commands specified in Task 13, with required `--data-dir`, `--lock`, `--config`, `--output-dir` arguments.

Canonical prepared examples are JSONL records `{sourceId,recordKey,originalGroupId,blockId,split,sourceLanguage,language,licenseId,contributor,text,normalizedScalars,rule,length}`; original rule=`original`, length=null; derived examples use rule IDs and scalar-prefix length. Sort by split order train/validation/test, language ASCII, recordKey UTF-8, rule order original/prefix/strip and length. `provenance.json` records every input hash, caps, exclusions, counts, oversized components, split assignments and actual augmentation counts. Future native consumers remain Swift `LanguageDetector.detectText(_:) -> LanguageTextResult?`, `detectDocument(_:) -> LanguageDocumentResult?` and C# `DetectText(string) -> LanguageTextResult?`, `DetectDocument(string) -> LanguageDocumentResult?`; prepared data is training/eval input, never a bundled runtime dependency.

- [ ] **Step 1 — write failing graph/split tests.**

```python
import unittest
from tools.lang.prepare_corpus import build_components, group_id, split_group

class CorpusTests(unittest.TestCase):
    def test_links_through_excluded_or_missing_text(self):
        groups = build_components("tatoeba", [1, 2], [(1, 99), (99, 2)])
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]["keys"], ["tatoeba:1", "tatoeba:2", "tatoeba:99"])
        expected = "a67d6874c78af1cb330d9c5c338cd56b034c75fa3fc06bbe2368884c7dde8a0e"
        self.assertEqual(groups[0]["groupId"], expected)
        self.assertEqual(group_id(groups[0]["keys"]), expected)
        self.assertEqual(split_group(expected, 1729, (8000, 1000, 1000)), "test")
        self.assertEqual(groups, build_components("tatoeba", [2, 1], [(99, 2), (1, 99)]))
```

`python3 -B -m unittest discover -s tools/lang/tests -p test_prepare_corpus.py -v` → red missing module. Add offline tests constructing tiny bz2/TSV files in `tempfile.TemporaryDirectory`: two translations linked via excluded language; dangling endpoint; oversized component whose blocks share original split; repeated text without links stays separate; duplicate ID with conflicting text fails; wrong hash fails before parsing; missing attribution exclusion; deterministic cap ordering; augmentation never crosses split and never inflates original-group support. Network functions are monkeypatched to raise in all preparation tests.

- [ ] **Step 2 — implement graph hashing/split before filtering.**

```python
import hashlib

def group_id(record_keys):
    keys = sorted(set(record_keys), key=lambda key: key.encode("utf-8"))
    return hashlib.sha256(("\n".join(keys) + "\n").encode("utf-8")).hexdigest()

def split_group(group, seed, split_bp):
    if any(x <= 0 for x in split_bp) or sum(split_bp) != 10000:
        raise ValueError("splitBp must be positive and sum to 10000")
    digest = hashlib.sha256(f"{seed}\n{group}\n".encode()).digest()
    slot = int.from_bytes(digest[:8], "big") % 10000
    return "train" if slot < split_bp[0] else (
        "validation" if slot < split_bp[0] + split_bp[1] else "test")
```

Build union-find from **all** global sentence IDs and every global link, adding missing endpoints. IDs are canonical nonnegative decimal, no leading zero except zero; links are undirected and duplicate/reverse links have no additional effect. Do not restrict the graph to ten selected language files. Store large graph arrays in disk-backed/compact integer structures or Python `array`, not millions of string-rich nested objects. Stream TSV files, preserving exact text; reject invalid UTF-8 rather than replacing it. Block large components by sorted UTF-8 key with cap 10000, recording original group ID/member count and block IDs; assign split once on original group.

After split, filter language/license, then select each language/split by `(sha256(seed+LF+recordKey+LF),recordKey UTF8)` and cap. No cross-source text deduplication in v1; record `none; translation links only` explicitly. Duplicate source IDs are validated, not silently deduplicated. Pool every selected negative example once into background without language weighting.

- [ ] **Step 3 — implement after-split augmentation and provenance.** Normalize each original to the capped stream first. Preserve original once. Prefix lengths `[24,64,160,400]` are ascending/unique and operate independently on the original normalized stream, retaining only shorter changed prefixes. Strip rule is pinned NFD→remove category-M→NFC, retaining changed output; it does not replace ł, and ß only becomes ss through prior normalization. Neither rule consumes another rule's outputs. Same text from two distinct rules remains two distinct examples. Rules apply to train, validation and test; raw held-out originals stay immutable and identities track all derived examples.

Compute count rows for all languages × train/validation/test × buckets 0/12/32/80/200, including zeroes. Group support uses distinct originalGroupId per bucket, not record, block or augmentation count. Every language mapping, file hash, filter/cap reason, number of records, original group and attribution contributor must reconcile. Emit deterministic UTF-8 LF bytes with sorted keys; no clock timestamps, Python hash order or host Unicode.


Before finishing this task, implement the WP1 adapter here, not in post-training evaluation. CLI `--snapshot-wp1 eval/multilingual --wp1-output /private/tmp/ainotebook-wp4-documents.json` identifies exactly one root-level JSON inventory with a `documents` array carrying the handoff fields `{documentId,path,sha256,encoding,goldLabel,sourceId,licenseId,translationGroupId}`. Inspect the actual merged WP1 inventory; if its schema differs, add an explicit adapter for its actual envelope here and test it against those real files. Unknown schema/ambiguous inventories/missing labels fail, never guess filenames or language from text. Validate relative containment, every original file SHA and strict UTF-8/windows-1250 decoding; export decoded text without detector normalization. Output `{contract:"wp1-detector-documents",version:1,sourceRevision,documents:[{documentId,sourceId,goldLabel,sha256,encoding,text,licenseId,translationGroupId,url}]}`. `sourceRevision` is the latest merged commit affecting the WP1 corpus; URLs are HTTPS raw source URLs pinned to that commit, derived from actual repository origin. SSH GitHub origin may be normalized to its equivalent HTTPS raw URL; an unknown host requires WP1's explicit HTTPS source URL, not a fabricated one. Record snapshot dates from that commit in UTC. Test a real WP1 cp1250 document, a modified-byte hash failure, a traversal path, a missing gold label, mixed/und labels and a repeat-snapshot byte comparison. All document-mode examples remain outside text train/validation/test support counts.

- [ ] **Step 4 — green and commit.**

```bash
python3 -B -m unittest discover -s tools/lang/tests -p test_prepare_corpus.py -v
python3 -B -m unittest discover -s tools/lang/tests -p test_reference.py -v
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/lang/prepare_corpus.py tools/lang/tests/test_prepare_corpus.py
git commit -m "feat(lang): offline translation-group split and corpus preparation" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: deterministic shuffled-input bytes, no translation leakage, no network, all fixture/reference tests and full Core suites green. Do not run the real corpus during this task.

### Task 12: [Shared] Calibration, offline training/export and separate download tooling

**Depends on:** 11. **Parallel with:** 2, 3, 5, 6, 7, 8, 9, 10.

**Files:** Create `tools/lang/train_detector.py`, `calibrate.py`, `fetch_tatoeba.sh`, `pin_tatoeba.py`, `training-v1.json`, `README.md`, `tools/lang/tests/test_training.py`, `test_fetch.py`. Do not create a real lock, production model, NOTICE changes or attribution in this task.

**Interfaces — Consumes:** reference, prepared examples/provenance, exact appendix schemas, local pinned corpus. **Produces:** Python `exact_gate(numerator:int,denominator:int,max_bp:int) -> bool`, `calibrate_bucket(rows:list[dict], candidates:dict, targets:list[str], negatives:list[str]) -> dict`, `train(data_dir:Path, lock_path:Path, config_path:Path, output_dir:Path, wp1_documents:Path, created_at:str, exporter_commit:str) -> dict`; the two CLIs below. Swift consumption remains `LanguageDetector.bundled() -> LanguageDetector`, `detectText(_:) -> LanguageTextResult?`, `detectDocument(_:) -> LanguageDocumentResult?`; C# consumption remains `LanguageDetector.LoadBundled()`, `DetectText(string) -> LanguageTextResult?`, `DetectDocument(string) -> LanguageDocumentResult?`. No dynamic training inside either application.

- [ ] **Step 1 — write failing calibration/training tests.**

```python
import unittest
from tools.lang.calibrate import exact_gate, calibrate_bucket

class TrainingTests(unittest.TestCase):
    def test_gate_uses_cross_products_not_rounded_rate(self):
        self.assertTrue(exact_gate(2, 100, 200))
        self.assertFalse(exact_gate(20001, 1000000, 200))
        self.assertFalse(exact_gate(0, 0, 200))

    def test_no_support_disables_bucket(self):
        result = calibrate_bucket([], {"bucketStart": 12,
            "minWinningScores": [-20000], "minMargins": [1],
            "minKnownCoverageBp": [0]}, ["cs", "de", "en", "sk"], ["fr"])
        self.assertEqual(result["threshold"], {"start": 12, "enabled": 0,
            "minWinningScore": -20000, "minMargin": 1, "minKnownCoverageBp": 0})
        self.assertEqual(result["reason"], "insufficientSupport")
```

`python3 -B -m unittest discover -s tools/lang/tests -p test_training.py -v` → red missing module. Add rows with 199 versus 200 distinct groups, 999/1000 total accepts, 99/100 accepted true-cs/sk, 200 exact negative groups per language; duplicates/augmentations cannot repair group minima. Add threshold tie tests: greatest score, then greatest margin, then greatest coverage. Train twice on an invented temporary local corpus with fixed timestamps/revision and compare exact artifact/manifest/attribution bytes. Mutating only test labels must leave vocabulary, weights and thresholds unchanged; final test report must change. Monkeypatch sockets and all URL openers to raise during training.

- [ ] **Step 2 — implement explicit config and calibration.** `training-v1.json` fixes these values, fully expanded in JSON (no environment defaults):

| Setting | v1 value |
|---|---|
| sourceId / modelId | `tatoeba` / `tatoeba-cs-de-en-sk-v1` |
| source-language mapping | ces→cs, deu→de, eng→en, slk→sk, fra→fr, hrv→hr, hun→hu, nld→nl, pol→pl, slv→sl |
| sorted negativeLanguages | `["fr","hr","hu","nl","pl","sl"]` |
| seed / splitBp | 1729 / train8000, validation1000, test1000 |
| maxComponentMembers | 10000 |
| cap per admitted language | train200000, validation40000, test40000 originals |
| augmentation | scalar-prefix-v1 lengths `[24,64,160,400]`; strip-marks-v1 lengths `[]`; both all three splits, each on originals only |
| model constants | exact appendix §1, including input5000000/text8192/windows8×512 |
| calibration score candidates | integers `range(-120000,1,2000)` |
| margin candidates | `[1,128,256,512,1024,2048,4096,8192]` |
| known coverage candidates | `[0,2500,5000,7500,9000,9500,10000]` |
| minimum support | groupsPerTarget200, groupsPerNegativeLanguage200, acceptedTotal1000, acceptedTrueCs100, acceptedTrueSk100 |
| license selection | CC0-1.0 or CC-BY-2.0-FR only; preserve source/contributor/license per sentence; exclude unknown license and missing owner when attribution is required |

Candidate arrays are identical for starts12/32/80/200; expand each into manifest. Calibration consumes only validation examples already scored once without threshold gating, preserving raw winner, score, margin, coverage, letters/words, truth and originalGroupId. Background/minLetters/minWords are always abstentions. Use integer histograms/preaggregation to evaluate the Cartesian grid without rescoring text. Each candidate must meet all support requirements and these exact metrics:

```python
def exact_gate(numerator, denominator, max_bp):
    return denominator > 0 and 10000 * numerator <= max_bp * denominator

def metric(numerator, denominator):
    return {"numerator": numerator, "denominator": denominator,
            "rateBp": None if denominator == 0 else 10000 * numerator // denominator}
```

Accepted error numerator counts **every** accepted wrong target, including negatives; denominator all accepted targets. cs/sk numerator counts true cs→sk and sk→cs; denominator all accepts with true cs/sk, including predictions de/en. Foreign acceptance numerator negative→any target; denominator all evaluated negatives. Max basis points 200/100/100. Coverage is accepted/all, separately by language and bucket. Select `max((accepted,minWinningScore,minMargin,minKnownCoverageBp))` among eligible grid candidates. If no eligible candidate, use enabled0 and record reason `insufficientSupport` or `noEligibleThreshold`; deterministic disabled triple is the smallest value from each candidate array. Test set is read only after thresholds are fixed and never changes them.

- [ ] **Step 3 — implement offline export and reproducible metadata.** Entry point accepts required `--data-dir`, `--lock`, `--config`, `--output-dir`, `--wp1-documents`, `--created-at`, `--exporter-commit`, optional `--verify-only`. It validates cached compressed/decompressed SHA hashes and all TSV schemas without fetching. Build vocabulary/weights only from train using Task 4's proven exporter. Run validation calibration, freeze thresholds, then report test with those thresholds. Insufficient test support is recorded and fails the release gate, never triggers disabling or retuning. Read the required hash-validated WP1 snapshot, score every owned document in document mode after thresholds freeze, and include its actual HTTPS source files/hashes/labels/group policy in a separate owned-document corpus record plus `documentMetrics`. Store its snapshot SHA in semantic `commandArguments` as `--wp1-snapshot-sha256` followed by the actual digest (a recorded provenance argument, also accepted/verified by the CLI). Owned corpus language codes are cs/de/en/sk/und and mul for gold mixed; document gold remains `mixed` in documentMetrics. These held-out documents never alter weights, thresholds, text counts or text support. Output artifact, manifest and candidate/support/metric diagnostics. Verify schemas with a small schema-specific validator using stdlib; reject unknown properties and numeric kinds, then verify cross-record semantics independently. Avoid introducing a dependency solely for schema validation.

All manifest fields in appendix §10 are populated with actual values: corpus files/URLs/dates/hashes/formats/records, mappings, licenses, policies; environment Python/dependencies/exporter revision/normalized command arguments/four Unicode pins; groups/blocks/split/caps/augmentations; every zero/nonzero count; every exclusion; minimum support/grid/tie-break/disabled reasons; per-language/all metrics and document confusion counts. `createdAt` is the fixed required CLI timestamp. Record semantic arguments, replacing local data/output directories with the stable strings `$DATA`/`$OUTPUT` in `commandArguments`; this is a documented manifest convention, not shell expansion. Preserve the actual semantic config/lock SHA in provenance output. Run test reproducibility from two directories with the same Python version and exporter revision.

Assemble final attribution and NOTICE **before** hashing the artifact. Attribution covers **every selected original sentence in all three splits**, with derived examples referring back to that original, and every WP1 document; future held-out replay subsets are already covered. Attribution groups contributing sentence IDs by source/contributor/license, supplies stable Tatoeba sentence links and export snapshot hashes, identifies generated weights as derived data, and includes the Unicode license. Preserve attribution for all text actually redistributed in evaluation fixtures as well as training contributions. Artifact references repository paths `tools/lang/ATTRIBUTION.md` and `NOTICE`; resource copies use identical bytes. Manifest hashes the exact LF-terminated artifact bytes and repeats the same attribution object. Do not include manifest hash in artifact or mutate NOTICE after export. Unknown licenses are never labeled MIT.

- [ ] **Step 4 — implement approved acquisition as a separate tool, with offline tests.** Official [Tatoeba download documentation](https://tatoeba.org/en/downloads/) specifies detailed TSV fields `id,language,text,username,created,modified` (six fields; **no license column**) and CC0 TSV fields `id,language,text,modified`. The [official export directory](https://downloads.tatoeba.org/exports/) provides mutable weekly exports, not immutable dated URLs or published SHA files. Preserve same-snapshot CC0 IDs as CC0-1.0; for other selected detailed rows apply the documented default CC-BY-2.0-FR and contributor attribution. Validate export consistency rather than inferring licenses from the six-field row.

`fetch_tatoeba.sh` uses `set -euo pipefail`, sets no HOME/CODEX_HOME variables and delegates metadata/lock handling to `pin_tatoeba.py`. It supports exactly:

```bash
bash tools/lang/fetch_tatoeba.sh --pin-current --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json
bash tools/lang/fetch_tatoeba.sh --locked --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json
```

`--pin-current` is Claude-only after explicit approval in Task 13. `--locked` requires a complete verified lock (the bootstrap lock is committed together with the artifact in Task 13) and never updates it. Fixed source URLs (expand each language into its own lock row):

```text
https://downloads.tatoeba.org/exports/sentences_base.tar.bz2
https://downloads.tatoeba.org/exports/links.tar.bz2
https://downloads.tatoeba.org/exports/sentences_CC0.tar.bz2
https://downloads.tatoeba.org/exports/per_language/ces/ces_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/deu/deu_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/eng/eng_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/slk/slk_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/fra/fra_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/hrv/hrv_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/hun/hun_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/nld/nld_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/pol/pol_sentences_detailed.tsv.bz2
https://downloads.tatoeba.org/exports/per_language/slv/slv_sentences_detailed.tsv.bz2
```

Lock schema: `{contract:"tatoeba-inputs",version:1,sourceId:"tatoeba",snapshotDate,files:[{role,url,localPath,sha256,uncompressedSha256,formatVersion,memberPath,byteCount,lastModified,etag}]}`. Roles distinguish global base IDs, links, CC0 attribution and language detailed sentences; manifest converts them to its allowed `sentences/links/attribution` roles. Store local filenames under the task data directory only; URLs must be those allowlisted HTTPS paths. `sha256` hashes downloaded compressed bytes; uncompressed hash is separately pinned. Record actual TAR member names, enforce a single expected regular TSV member, reject traversal/symlinks. Do not guess extension spelling from URL.

Bootstrap captures metadata before and after acquisition, verifies a consistent weekly snapshot and matching CC0/detail IDs/text, and fails if the export changed mid-run. Retain original downloaded bytes in the local directory, because later upstream replacements cannot satisfy old hashes. Locked mode verifies cached bytes first and returns without network when complete; missing bytes may be downloaded only from the recorded URL and must hash-match. Changed bytes cause a hard failure, never repinning. Stdlib parser owns SHA checks; curl must use `--fail --location --proto '=https' --retry 3`. Download logic is absent from `train_detector.py`/`prepare_corpus.py` imports.

`test_fetch.py` uses injected byte readers/metadata providers with temporary invented files, not live URLs: absent lock refuses locked mode; changed compressed/decompressed hashes fail; stable cache never invokes downloader; changed pre/post metadata fails; incomplete lock is not written; captured lock deterministically re-verifies; foreign host/path and TAR traversal fail. `README.md` documents the two-phase trust boundary, exact commands, disk/network estimate from HEAD metadata (not invented fixed size), cache retention, and no production corpus downloads in CI.

- [ ] **Step 5 — green and commit.**

```bash
python3 -B -m unittest discover -s tools/lang/tests -p 'test_*.py' -v
bash -n tools/lang/fetch_tatoeba.sh
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/lang/train_detector.py tools/lang/calibrate.py tools/lang/fetch_tatoeba.sh tools/lang/pin_tatoeba.py tools/lang/training-v1.json tools/lang/README.md tools/lang/tests/test_training.py tools/lang/tests/test_fetch.py
git commit -m "feat(lang): reproducible offline calibration and pinned acquisition tooling" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Expected: all Python tests OK, deterministic two-directory export, no test/trainer network use; both Core suites green. Real export hashes are intentionally not fabricated: only approved Task 13 creates them.

### Task 13: [Shared] Claude-only approved acquisition, training and artifact commit

**Executor:** **Claude only**, not a parallel Codex worker. **Depends on:** 9, 10, 12 and merged WP1 documents. **Parallel with:** none; pins, final provenance and resource bytes become one reviewed artifact commit after training.

**Files:** Create `tools/lang/tatoeba-v1.lock.json`, `tools/lang/ATTRIBUTION.md`, the four production resource files from the File Structure table. Modify `NOTICE:1–12` by appending Unicode/Tatoeba/license/derived-model attribution while preserving existing notices. No edits to runtime code, frozen fixtures or training configuration based on held-out results.

**Interfaces — Consumes:** approved acquisition/config and all merged runtime code. **Produces:** exact artifact/schema §9 and manifest/schema §10 bytes. Consumers: Swift `LanguageDetector.bundled().detectText(_:) -> LanguageTextResult?`, `.detectDocument(_:) -> LanguageDocumentResult?`; C# `LanguageDetector.LoadBundled().DetectText(string) -> LanguageTextResult?`, `.DetectDocument(string) -> LanguageDocumentResult?`. `bundled`/`LoadBundled` must now report available.

- [ ] **Step 1 — prepare concrete approval details without downloading corpus.** Run local unit tests/config validation first. Show the thirteen exact URLs above, selected ten languages, license policy, dataset sizes from metadata if available, local cache directory, fixed split/augmentation/grid, output paths and CPU/disk implications. Request explicit user approval for **downloading these exports and running training**. This pause is required by the task instruction, not a skill. Do not infer approval from the earlier approval of folder RAG design. Ordinary Codex tasks stop before this operation; they can complete all prior implementation/testing independently.

WP1's `eval/multilingual/` does not exist at the inspected revision; it is not the existing twelve-document English retrieval corpus (`eval/README.md:15`). Before training, inspect the merged WP1 inventory and require a UTF-8 manifest export with exact rows `{documentId,path,sha256,encoding,goldLabel,sourceId,licenseId,translationGroupId}`. Paths must be relative to `eval/multilingual/`, gold labels one of cs/de/en/sk/mixed/und, encoding UTF-8 or windows-1250 with strict decode, and SHA over original file bytes. No guessing languages from filenames. Task 11 implements the inspected schema adapter before training; Task 14 owns only the committed `Tests/fixtures/lang/wp1-documents-v1.json` copy of that same frozen snapshot; no WP1-owned files are changed. Missing labels/hashes are a WP1 handoff failure, not a reason to silently omit documents.

- [ ] **Step 2 — after approval, acquire and pin actual bytes.**

```bash
bash tools/lang/fetch_tatoeba.sh --pin-current --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json
bash tools/lang/fetch_tatoeba.sh --locked --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json
python3 -B tools/lang/prepare_corpus.py --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --output-dir /private/tmp/ainotebook-wp4-prepared
python3 -B tools/lang/prepare_corpus.py --snapshot-wp1 eval/multilingual --wp1-output /private/tmp/ainotebook-wp4-documents.json
```

Expected: lock contains thirteen nonempty verified SHA-256 rows, one audited snapshot date, exact formats/member names. Second command verifies cache without fetching. Preparation reports counts/exclusions/oversized groups; group partition intersection is empty across train/validation/test. If snapshot/license metadata cannot be reconciled, stop acquisition and report the exact inconsistency; do not record guessed dates/licenses/hashes.

- [ ] **Step 3 — run offline training with fixed provenance.** `--created-at` below is the reproducibility epoch for this model, not a claim about the eventual download date; actual snapshot date is in the lock. `--exporter-commit` captures the clean merged code/config revision before artifact generation.

```bash
git diff --exit-code
python3 -B tools/lang/train_detector.py --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --output-dir /private/tmp/ainotebook-wp4-model-a --wp1-documents /private/tmp/ainotebook-wp4-documents.json --created-at 2026-10-09T00:00:00Z --exporter-commit "$(git rev-parse HEAD)"
python3 -B tools/lang/train_detector.py --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --output-dir /private/tmp/ainotebook-wp4-model-b --wp1-documents /private/tmp/ainotebook-wp4-documents.json --created-at 2026-10-09T00:00:00Z --exporter-commit "$(git rev-parse HEAD)"
diff -r /private/tmp/ainotebook-wp4-model-a /private/tmp/ainotebook-wp4-model-b
```

Training builds final NOTICE by replacing one deterministic marked `BEGIN AI NOTEBOOK LANGUAGE DATA` / `END AI NOTEBOOK LANGUAGE DATA` section (or appending it once when absent) in checked-in NOTICE and emits `NOTICE`, `ATTRIBUTION.md`, artifact, manifest and support report. It must read the original repo NOTICE by path but only write output-directory files. Re-export after artifact commit is also idempotent: strip only that marked generated section before reconstructing it, preserving all unrelated notices. The second run starts from the same repository NOTICE and semantic arguments; physical output paths must not leak into model/manifest bytes. Expected: zero-byte diff, production targets `cs,de,en,sk`, all schema and weight/provenance checks pass, four calibrated/disabled bucket records with explicit reasons, all validation and untouched-test metrics reported. Do not hide all-disabled output as useful; Task 14 and Claude review decide readiness.

- [ ] **Step 4 — copy reviewed bytes, verify loading and commit.**

```bash
cp /private/tmp/ainotebook-wp4-model-a/NOTICE NOTICE
cp /private/tmp/ainotebook-wp4-model-a/ATTRIBUTION.md tools/lang/ATTRIBUTION.md
cp /private/tmp/ainotebook-wp4-model-a/lang-detector-v1.json Sources/AINotebookCore/Resources/Language/lang-detector-v1.json
cp /private/tmp/ainotebook-wp4-model-a/lang-detector-v1.manifest.json Sources/AINotebookCore/Resources/Language/lang-detector-v1.manifest.json
cp NOTICE Sources/AINotebookCore/Resources/Language/NOTICE
cp tools/lang/ATTRIBUTION.md Sources/AINotebookCore/Resources/Language/ATTRIBUTION.md
python3 -B tools/lang/train_detector.py --verify-only --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --output-dir Sources/AINotebookCore/Resources/Language --wp1-documents /private/tmp/ainotebook-wp4-documents.json --created-at 2026-10-09T00:00:00Z --exporter-commit "$(git rev-parse HEAD)"
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git add tools/lang/tatoeba-v1.lock.json tools/lang/ATTRIBUTION.md NOTICE Sources/AINotebookCore/Resources/Language/lang-detector-v1.json Sources/AINotebookCore/Resources/Language/lang-detector-v1.manifest.json Sources/AINotebookCore/Resources/Language/NOTICE Sources/AINotebookCore/Resources/Language/ATTRIBUTION.md
git commit -m "feat(lang): bundle approved trained detector with pinned provenance" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

`--verify-only` never regenerates or appends NOTICE. It checks exact bytes/source hashes, schema, semantic/attribution links and parameter provenance using the already recorded exporter revision. No downloaded TSVs, model-a/model-b directories or prepared sentence text are committed. Expected full suites green. Production-loading assertions are mandatory in Task 14 and cannot be replaced by synthetic tests.

### Task 14: [Shared] Held-out evaluation, native parity and release gate

**Depends on:** 13 and final merged WP1 inventory. **Parallel with:** none inside WP4; this is the integrated release check. Test/report tooling is one bounded session; full data runs use the approved local cache from Task 13.

**Files:** Create only Task 14 files in the File Structure table. Read production resources, lock/config, WP1 documents and inventory. Do not edit training thresholds/model or existing evaluator. The existing eval tool targets retrieval and may call Ollama; the detector gate is independently offline.

**Interfaces — Consumes:** frozen model/manifest plus untouched test split and WP1 document labels. **Produces:** Python `evaluate(rows:list[dict], predictions:list[dict], manifest:dict) -> dict`, `assert_release_gate(report:dict) -> None`, CLI below; `lang-release-v1.json` envelope with cases `{name,sourceId,originalGroupId,truth,mode,input,expected}`. `expected` is the complete reference text/document tree, not a substituted gold label. Native tests compare **all fields**, then Python calculates actual accuracy against `truth`. Output report includes raw denominators, basis points, support/coverage by language/bucket, disabled reasons, document confusion matrix and artifact SHA.

Both native APIs under evaluation are actual production `LanguageDetector.bundled().detectText(_:) / detectDocument(_:)` and `LanguageDetector.LoadBundled().DetectText(string) / DetectDocument(string)`; no test model initializer in release tests.

- [ ] **Step 1 — write and run failing metric and production-availability tests.**

```python
import unittest
from tools.lang.evaluate_detector import assert_release_gate
class EvaluationTests(unittest.TestCase):
    def test_test_support_cannot_be_retuned_away(self):
        report = {"enabledBuckets": [12], "gateRows": [
            {"split": "test", "bucketStart": 12, "supportPass": False,
             "acceptedError": {"numerator": 0, "denominator": 999},
             "csSkConfusion": {"numerator": 0, "denominator": 200},
             "foreignAcceptance": {"numerator": 0, "denominator": 1200}}]}
        with self.assertRaisesRegex(ValueError, "support"):
            assert_release_gate(report)
```

Swift release test (one test loops both committed CI fixture and, when explicitly supplied, the complete held-out replay):

```swift
import Foundation
import XCTest
@testable import AINotebookCore
final class LanguageReleaseTests: XCTestCase {
    func testProductionReleaseCases() throws {
        let detector = LanguageDetector.bundled()
        XCTAssertTrue(detector.isAvailable, "production artifact must load")
        var urls = [SharedFixtures.url("contracts/lang-release-v1.json")]
        if let path = ProcessInfo.processInfo.environment["AINOTEBOOK_LANG_RELEASE_INPUT"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            urls += try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            XCTAssertGreaterThan(urls.count, 1, "full replay must not be empty")
        }
        for url in urls {
            let bytes = try Data(contentsOf: url)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            for c in try XCTUnwrap(root["cases"] as? [[String: Any]]) {
                let name = c["name"] as! String
                let input = c["input"] as! String
                if c["mode"] as! String == "text" {
                    try assertLanguageJSON(try XCTUnwrap(detector.detectText(input)), equals: c["expected"]!, name)
                } else {
                    try assertLanguageJSON(try XCTUnwrap(detector.detectDocument(input)), equals: c["expected"]!, name)
                }
            }
        }
    }
}
```

C# release test:

```csharp
using System.Text.Json;
using AINotebook.Core.Language;
using AINotebook.Core.Tests.Helpers;
using Xunit;
namespace AINotebook.Core.Tests.Language;
public sealed class LanguageReleaseTests
{
    [Fact]
    public void ProductionReleaseCases()
    {
        var detector = LanguageDetector.LoadBundled();
        Assert.True(detector.IsAvailable, "production artifact must load");
        var paths = new List<string> { SharedFixtures.Path("contracts/lang-release-v1.json") };
        if (Environment.GetEnvironmentVariable("AINOTEBOOK_LANG_RELEASE_INPUT") is string directory)
        {
            paths.AddRange(Directory.GetFiles(directory, "*.json").Order(StringComparer.Ordinal));
            Assert.True(paths.Count > 1, "full replay must not be empty");
        }
        foreach (var file in paths)
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
            foreach (var c in doc.RootElement.GetProperty("cases").EnumerateArray())
            {
                string input = c.GetProperty("input").GetString()!;
                string name = c.GetProperty("name").GetString()!;
                if (c.GetProperty("mode").GetString() == "text")
                {
                    var result = detector.DetectText(input);
                    Assert.NotNull(result);
                    LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, name);
                }
                else
                {
                    var result = detector.DetectDocument(input);
                    Assert.NotNull(result);
                    LanguageFixtureAssert.Equal(c.GetProperty("expected"), result, name);
                }
            }
        }
    }
}
```

Run `python3 -B -m unittest discover -s tools/lang/tests -p test_evaluation.py -v`, `swift test --filter LanguageReleaseTests`, `dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~LanguageReleaseTests`. Expected red: evaluator missing and release fixture missing (production loading itself should already succeed). The existing Task 9/10 shared loading-fixture tests remain mandatory; the new release test adds actual production-bundle availability and parity without duplicating those mutation tests.

- [ ] **Step 2 — reproduce and verify the already trained WP1 snapshot.** Run the Task 11 adapter with the command below and commit its output as `Tests/fixtures/lang/wp1-documents-v1.json`. Its exact SHA must equal the snapshot digest recorded by Task 13's manifest `commandArguments`; its original-file hashes/HTTPS URLs/source IDs/licenses must reconcile with the manifest's owned-document corpus entry. Do not implement a second decoding/schema adapter here or silently accept a changed WP1 corpus. If WP1 changed after training, use the pinned WP1 revision for this model and schedule a fresh reviewed model run separately. The adapter preserves declared encodings and original hashes while providing strictly decoded text for both native runtimes.

Evaluate every WP1 document in **document mode**. Keep document gold/confusion counts separate from Tatoeba text metrics. Count mixed/und gold explicitly; list mistakes by documentId with letter shares/coverage/window decisions. Do not apply text accuracy denominators to documents. No appendix document accuracy target exists; report results for Claude review rather than inventing a numeric pass threshold.

- [ ] **Step 3 — evaluate final validation/test splits without recalibration.** Rebuild split/caps/augmentation deterministically from the lock/config and verify train/validation/test group sets are disjoint and match manifest counts. Freeze/check artifact digest before and after evaluation. Generate complete reference predictions, metric rows and native replay batches (at most 256 examples per JSON envelope to bound memory). Exact gate comparisons use integer cross-products with denominators nonzero. Require **both validation and test** per enabled bucket: ≥200 original groups per target and each negative language, ≥1000 accepts, ≥100 accepted true-cs and ≥100 true-sk; acceptedError≤200bp, csSkConfusion≤100bp, foreignAcceptance≤100bp. Report aggregate plus per-language bucket coverage and all disabled buckets. Test insufficiency fails; do not remove that bucket based on test observations.

For deterministic CI, select the first 16 evaluated test examples per language/bucket by `(sha256(recordKey+LF+rule+LF+length+LF),recordKey)` and all WP1 documents. Preserve all example identities/attribution and full expected diagnostics in committed `lang-release-v1.json`. This small replay proves production parity in ordinary Core CI; it is **not** a replacement for full held-out metric gates. `lang-release-v1.metrics.json` records full-run numerators/denominators/support, artifact/config/lock/WP1 hashes and evaluation command/environment, not raw uncommitted sentence contents. Verify Task 13 attribution covers every redistributed selected test sentence and every WP1 document; a missing attribution is an exporter defect and fails the gate, never permission to redistribute unattributed input.

The CLI `--native-parity` first builds both test targets once, then sets `AINOTEBOOK_LANG_RELEASE_INPUT` to the directory of zero-padded batch JSON filenames. Invoke `swift test --skip-build --filter LanguageReleaseTests` once and `dotnet test windows/tests/AINotebook.Core.Tests --no-build --no-restore --filter FullyQualifiedName~LanguageReleaseTests` once, passing argument arrays via subprocess (no shell interpolation). Each test process reads one envelope at a time; release batch contents are not accumulated into one giant JSON object. Retain failing batch names/output under the work directory and fail on any mismatch. Streaming batches cover **every** held-out example, not only the committed subset. Native acceptance/error metrics equal reference metrics only after full parity succeeds; record per-platform evaluated counts and zero mismatch count.

- [ ] **Step 4 — run exact gate commands and write report.**

```bash
python3 -B tools/lang/prepare_corpus.py --snapshot-wp1 eval/multilingual --wp1-output Tests/fixtures/lang/wp1-documents-v1.json
python3 -B tools/lang/evaluate_detector.py --data-dir /private/tmp/ainotebook-wp4-tatoeba --lock tools/lang/tatoeba-v1.lock.json --config tools/lang/training-v1.json --artifact Sources/AINotebookCore/Resources/Language/lang-detector-v1.json --manifest Sources/AINotebookCore/Resources/Language/lang-detector-v1.manifest.json --wp1-documents Tests/fixtures/lang/wp1-documents-v1.json --work-dir /private/tmp/ainotebook-wp4-eval --fixture-output Tests/fixtures/contracts/lang-release-v1.json --metrics-output Tests/fixtures/lang/lang-release-v1.metrics.json --report docs/eval/language-detector-v1.md --native-parity --gate
python3 -B -m unittest discover -s tools/lang/tests -p 'test_*.py' -v
swift test --filter LanguageReleaseTests
dotnet test windows/tests/AINotebook.Core.Tests --filter FullyQualifiedName~LanguageReleaseTests
swift test
dotnet test windows/tests/AINotebook.Core.Tests
```

Expected success: `native parity: Swift=0 mismatches, C#=0 mismatches`, all enabled-bucket validation/test support and error gates PASS, all corpus hashes reconcile, report contains coverage and document confusion counts. Expected failure: nonzero exit with exact bucket/language/support or numerator/denominator, report still written, **no threshold edits**. All-disabled artifact receives `NO_ENABLED_BUCKETS: usefulness review required` and a nonzero WP4 completion result; this is a product-readiness review condition, not an invented statistical threshold. A useful acceptance-coverage floor must be agreed with Claude/user if required; appendix v1 does not supply one.

If full evaluation discovers a genuine implementation defect, fix it in the owning runtime/tooling task with a new red test and cross-platform fixture, merge, and rerun affected gates. Do not edit gold labels to repair metrics. If data/support is inadequate, Claude reviews revised corpus/config as a new trained model/provenance run without using held-out examples for threshold selection.

- [ ] **Step 5 — commit evaluation evidence.**

```bash
git add tools/lang/evaluate_detector.py tools/lang/tests/test_evaluation.py Tests/fixtures/contracts/lang-release-v1.json Tests/fixtures/lang/wp1-documents-v1.json Tests/fixtures/lang/lang-release-v1.metrics.json Tests/AINotebookCoreTests/LanguageReleaseTests.swift windows/tests/AINotebook.Core.Tests/Language/LanguageReleaseTests.cs docs/eval/language-detector-v1.md
git commit -m "test(lang): held-out detector gates and native production parity" -m "Co-Authored-By: Codex <noreply@openai.com>"
```

Only mark the task green when the measured gates pass and Claude has reviewed document errors, disabled buckets and coverage. Committing a failing diagnostic report is allowed for review but does not complete WP4.

## WP gate

- [ ] Every task's exact file ownership and dependency order held; both platform implementations were cross-reviewed against the appendix and the other implementation.
- [ ] Run from the merged tree:

```bash
python3 -B tools/unicode/gen_tables.py --ucd-dir /tmp/ainotebook-ucd-15.1.0 --check
python3 -B -m unittest discover -s tools/unicode/tests -p 'test_*.py' -v
python3 -B -m unittest discover -s tools/lang/tests -p 'test_*.py' -v
python3 -B tools/contracts/gen_fixtures.py --check
swift test
dotnet test windows/tests/AINotebook.Core.Tests
git diff --check
git status --short
```

Expected: no modified/untracked files; no generated corpus/cache artifacts staged; table/conformance SHA checks pass; all 44 normalization, 23 text, 9 document and supplemental cases match every field; every pinned NormalizationTest row executes; both full suites green, no contract skips. `tools/contracts/gen_fixtures.py --check` is read-only and must run after concurrent WP0 determinism fixes land; WP4 does not patch it.

- [ ] Task 14 full evaluation command has passed against the committed artifact digest, with exact support/denominator evidence from validation/test and zero native mismatches. All WP1 documents are accounted for separately. Coverage/disabled buckets/document errors have Claude's recorded review. No fabricated performance/quality claim based on synthetic fixtures.
- [ ] Existing privacy-grep (`.github/workflows/core-ci.yml:26`) remains green; detector code has no networking. Windows CI runs `dotnet build windows/src/AINotebook.App/AINotebook.App.csproj -c Release -p:Platform=x64` and `dotnet test windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj -c Release -p:Platform=x64` (`.github/workflows/windows-ci.yml:45,63`). Do not run net10.0-windows projects on macOS.
- [ ] Claude checks packaged macOS app resources using existing `tools/macos/build-app.sh` bundle-copy loop at line 39 and verifies `AINotebookCore` Language resource files arrive in the signed app. No packaging-script edit is planned. Windows assembly resource test confirms identical artifact/table/NOTICE hashes. Runtime missing/corrupt resource probes return unavailable without crashing.
- [ ] WP6 receives exact detectText/detectDocument/ChunkLanguage APIs and NULL/inheritance policy; WP5/WP6 receive pinned category/NFC/simpleLowercase APIs; WP8 receives document labels/letter shares/coverage semantics. Language never becomes a retrieval filter; canonical spans never use normalized offsets.
- [ ] Final implementation report lists commits and files; Swift/.NET test counts before and after; all measured quality gates and document results; actual Tatoeba snapshot/lock/model hashes; disabled buckets/coverage decisions; no version bump. WP4 remains incomplete until Claude-only approval/training and the release gate actually occur.

**Decisions for Claude's review:** accept the proposed ten-language corpus/config and fixed calibration grid before data acquisition; reconcile the final WP1 inventory through the detector-owned adapter; review real download pins/licenses/attribution before artifact commit; decide usefulness from measured acceptance coverage and disabled buckets (no lower bound is specified by appendix v1). These are concrete execution gates, not permission to replace missing data with guessed constants or silently loosen a contract.
