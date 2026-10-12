# Pinned Unicode 15.1.0 resources

WP4 Task 1 generates one shared Unicode table, exact normalization conformance
bytes, supplemental detector contracts, and copies of the two binding JSON
schemas. It uses Python standard-library code and no host Unicode normalization,
classification or casing. Runtime implementations belong to later WP4 tasks.

## Pinned inputs and license

Claude supplied `UCD.zip` and its four extracted inputs locally under
`/private/tmp/ainotebook-ucd/`. All hashes are verified before generation writes
any output. Offline generation needs the four extracted files; if the ZIP is
present, its hash is checked too.

| Input URL | SHA-256 of exact bytes |
| --- | --- |
| https://www.unicode.org/Public/zipped/15.1.0/UCD.zip | `cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177` |
| https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| https://www.unicode.org/Public/15.1.0/ucd/CaseFolding.txt | `4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf` |
| https://www.unicode.org/Public/15.1.0/ucd/DerivedNormalizationProps.txt | `8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1` |
| https://www.unicode.org/Public/15.1.0/ucd/NormalizationTest.txt | `871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e` |
| https://www.unicode.org/license.txt | `e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96` |

The pinned ZIP contains no license member. The approved **separate source** is
Unicode License V3 (`Unicode-3.0`), retrieved **2026-10-09** from
`https://www.unicode.org/license.txt`. Claude supplied its exact bytes at
`/private/tmp/ainotebook-ucd/license.txt`. `--license-file` selects a local file,
which must match the pinned hash above; it never fetches the license. The
source URL, hash, retrieval date and license identifier are recorded in
`unicode-sources-v1.json`. This approved provenance replaces the plan's
archive-member license requirement without changing the training manifest schema.

Neither ZIP nor extracted acquisition cache is committed. The exact approved
license bytes are copied to `Resources/Language/UNICODE-LICENSE.txt`.

## Offline generation and verification

Run from the repository root; use `-B` on every Python command:

```sh
python3 -B tools/unicode/gen_tables.py --ucd-dir /private/tmp/ainotebook-ucd --license-file /private/tmp/ainotebook-ucd/license.txt
python3 -B tools/unicode/gen_tables.py --ucd-dir /private/tmp/ainotebook-ucd --license-file /private/tmp/ainotebook-ucd/license.txt --check
python3 -B -m unittest discover -s tools/unicode/tests -p 'test_*.py' -v
```

The three-argument `generate(ucd_dir, output_dir, fixture_dir)` API defaults the
license to `ucd_dir/license.txt`; keyword `license_file` overrides it.
`--output-dir`, `--fixture-dir`, and `--schema-dir` independently redirect the
resource, fixture and schema outputs. Specify **all three** when reproducing
into a temporary directory. `--check` recomputes every expected file and reports
missing or changed paths, without creating directories or changing any bytes or
modification times. Normal writes use a same-directory temporary file and atomic
replacement. All inputs and all output bytes are prepared before writing begins.

The optional developer `--download` mode is mutually exclusive with `--check`.
It opens only the pinned archive URL, rejects redirects, verifies the archive
before inspecting it, rejects traversal/duplicate/unsupported members, and
extracts only the four named, independently verified inputs. Acquisition imports
are local to this explicit mode. **No network acquisition was run for this task.**

## Generated formats and consumer seams

`unicode-15.1.0.json` is compact UTF-8 plus LF, with fixed key order, decimal
integers, sorted/coalesced inclusive category ranges (including `Cs`, omitting
`Cn`) and sparse nonidentity mappings. Simple lowercase uses UnicodeData field
13; full folding uses C/F rows exactly once. Canonical composition uses the full
exclusion property; Hangul stays algorithmic. The current table SHA-256 is
`407889e2ac750a0daca62b65c9a3b4e282d85c1aae978b5cc30d88e67acd7eb9`.

`unicode-sources-v1.json` has `format`, `unicodeVersion`,
`normalizationTablesVersion`, `archive:{url,sha256}`, `files:[{name,url,sha256}]`,
`license:{url,sha256,retrievedAt,licenseId}`, `tableSha256`, and
`normalizationRows` (**19074**). Sidecars contain lowercase SHA-256 plus LF only.
The normalization fixture is an exact copy of the pinned source bytes.

The six supplemental contracts have the standard `{contract,version,cases}`
envelope. Existing `lang-normalize-v1.json` and `lang-score-v1.json` stay
byte-identical. Runtime fixture inputs are explicit:

- `normalize`: `{utf16Units,inputCap,textCap,mode}`; expected includes `stream`
  before text cap, `scalars` for the requested mode, and all classification
  fields (`words,wordScalars,boundaryWords,letterCount,wordCount`).
- `windows`: `{length,count,size}`; expected is an array of `[start,end]` pairs.
- `aggregate`: `{targets,labels,letters}` with parallel label/letter arrays;
  expected is the complete eight-field aggregation result.
- `score`: input is text; case-level `modelOverrides` recursively merges object
  fields into a fresh copy of the frozen synthetic model and replaces arrays
  in full. Expected is the complete text scoring tree. The small ASCII-word
  oracle checks the frozen xa worked example before generating text-cap trees.
- Inheritance uses `operation:"resolve"`; raw artifact cases have exactly one
  of `rawArtifact` or `rawBytesBase64` plus a boolean `valid`.

`supplemental-cases.json` preserves the 63 shared parity regressions added in
`496bc0d`: two artifact schema-key cases, 43 loading cases, and the 18-case
`lang-json-validation-v1.json` contract. Generation appends these reviewed cases
in their original order, checking envelope identity and rejecting duplicate
case names. The raw JSON strings and expected results are source data; they are
never read back from generated fixtures. Add future parity cases here or to the
generator's case lists. The Python suite regenerates all language fixture outputs
in a temporary directory and compares them byte-for-byte with committed files;
the existing `--check` mode also includes the appended and raw-JSON cases.

NFC Hangul, exclusion, equal-CCC blocking and leading-mark expectations use
exact pinned conformance columns. The required minimal `[97,789,768]` example
uses the already frozen canonical-reordering expectation `[224,789]`; that
minimal input is not an exact source row. No platform normalization supplies
any expectation.

`lang/loading-bundle-v1.json` is **test-only**, with modelId
`wp4-loader-test-only`, invented zero-record source, production parameters,
empty vocabularies and disabled buckets. Its four base64 resources are artifact,
manifest, NOTICE and ATTRIBUTION. `sharedUnicodeResources` names the four real
bundled Unicode resources to inject separately. It is never a production model.

Loading operations use fixed `input.resource` names. `setManifestValue` and
`addUnknownManifestKey` apply `input.pointer`/`value` then reserialize as UTF-8
plus LF. `duplicateManifestKey` inserts a second key at the pointer without
round-tripping through a dictionary. `flipByte` XORs `input.byteIndex` with 1.
`replaceArtifactWithSynthetic` uses the frozen scoring model and updates the
manifest artifact digest to the exact replacement bytes. The positive bundle
has 30 caps, 150 counts, 80 support and 440 metric records, including zero rows.
Both JSON schemas are extracted structurally unchanged from appendix §§9–10.

## TDD and validation record

Commit `6541257` recorded Step 1's missing-module red and nine passing parser
tests, then stopped at the license blocker. On resumption, Step 2 first failed
for missing generator APIs and CLI flags; its 16 tests then passed. Step 3
first failed on missing supplemental files and on the missing loading builder;
the completed tests validate the generated cases, schemas and loader metadata.

The saved WIP was restored and reviewed before completion. The resumed baseline
passed **30 Python tests, Swift 381, .NET 459**, with no failures/skips. Review
found that complete source reconstruction assertions covered UnicodeData but
not folding/exclusions. Two new mutation tests first failed with five
`ValueError not raised` assertions (missing/changed/extra folding mappings and
missing/extra exclusions). Independent source reconstruction checks then made
all **32 Python tests pass**, without changing generated bytes.

Two clean temporary generations reproduced all **14 generated outputs** exactly,
including comparison against the worktree. `--check` and the existing contract
generator's `--check` passed. Independent review reproduced all 8 Unicode and
19 runtime fixture cases from pinned tables and checked NFC/NFD against all
19,074 conformance rows (190,740 assertions), without host Unicode APIs.
The positive loader bundle and all supplemental cases/schemas were reviewed
against the appendix. Runtime implementations and their native conformance
tests remain with later numbered tasks.

The targeted shared-fixture checks pass **2 tests per platform**. Both full
pre-commit suites pass: **Swift 381 → 381; .NET 459 → 459**, with zero failures
or skipped tests. No later WP4 task, runtime source, migration or version file
was changed.

Verification uses cached dependencies: Swift `swift test --skip-update` and
.NET `dotnet test windows/tests/AINotebook.Core.Tests --no-restore`. The initial
sandbox attempts hit Swift compiler-cache access restrictions and the .NET
test-runner loopback socket restriction; unrestricted reruns need no source or
test changes. The initial .NET restore reported NU1900 because its vulnerability
feed was unreachable; subsequent runs use `--no-restore`. No dependency changes
or Unicode acquisition were needed.
