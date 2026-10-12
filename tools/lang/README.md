# Offline language detector tooling

The binding algorithms and schemas are in
[`lang-detector-v1.md`](../../docs/contracts/lang-detector-v1.md). These Python
standard-library tools share the committed Unicode 15.1.0 tables and language
fixtures with Swift and C#. Use `python3 -B` to avoid writing bytecode into the
worktree. No package installation or host Unicode normalization is required.

## Trust boundary

There are two separate phases:

1. **Acquisition:** `fetch_tatoeba.sh` delegates to `pin_tatoeba.py`. Only these
   tools invoke curl. Initial `--pin-current` acquisition and real training are
   WP4 Task 13, reserved for Claude after explicit approval. Task 12 supplies
   tooling and invented offline tests; it creates no real lock or model.
2. **Offline preparation, training and verification:** `prepare_corpus.py`,
   `reference.py`, `calibrate.py` and `train_detector.py` read local files only.
   They never import acquisition code or fetch a missing input. Missing files,
   changed hashes or malformed TSVs fail the run. Cross-export snapshot skew
   follows the bounded exclusion policy below.

Tatoeba's official exports are mutable weekly URLs, without published immutable
snapshot digests. Initial pinning is therefore an explicit trust decision.
The tool records actual downloaded SHA-256 values, uncompressed member hashes,
byte counts, Last-Modified, ETag and TAR member names. An existing lock is never
overwritten by `--pin-current`, and `--locked` never updates one.

## Acquisition commands — Claude only after approval

Run from the repository root:

```bash
bash tools/lang/fetch_tatoeba.sh --pin-current \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json

bash tools/lang/fetch_tatoeba.sh --locked \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json
```

The first command reads HEAD metadata for all thirteen allowlisted HTTPS
exports, prints their total compressed byte count before downloading, then
checks metadata again afterward. Changed metadata, byte counts, incompatible
weekly dates, truncated compressed streams, unexpected TAR members, traversal
or symlinks abort before publishing a lock. Links may have missing endpoints,
which remain vertices in the translation graph.

Weekly exports are generated at slightly different times. Both pinning and
preparation exclude selected-language detailed sentences missing from base,
and sentences whose CC0 row disagrees with the detailed language, text or
modification time. Excluded IDs remain graph vertices, preserving translation
group splits, but never enter training, validation, test, attribution or
augmentation selection. A mismatched CC0 row cannot fall back to CC-BY.

The lock, preparation `provenance.json` and training manifest record:

```json
"snapshotSkew": {
  "missingFromBase": 1,
  "cc0DetailMismatch": 1,
  "excludedIdsSha256": "<SHA-256 of the excluded ID list>",
  "sampleIds": [9, 10]
}
```

IDs are deduplicated, sorted numerically, serialized as canonical decimal IDs
joined by LF **without a trailing LF**, and hashed as UTF-8. The sample contains
the first 20 numeric IDs; an empty list hashes zero bytes. Reason counts can
overlap, but each ID contributes only once to the excluded share and to the
per-split `snapshotSkew` exclusion count. The denominator is the number of
unique detailed IDs in the configured source-language mappings, before license
filters, caps and augmentation. The exact integer comparison rejects only
`excluded * 10000 > detailed * maxSnapshotSkewBp`; exactly 1% passes.
`training-v1.json` sets `maxSnapshotSkewBp: 100` (1%); valid overrides are
integers 0–10000. Pinning defaults to that config and accepts `--config PATH`;
use the same config for preparation/training. Legacy configs default to 100.
Over-limit errors include counts, hash and sample; no lock is published.

Metadata within a seven-day span and the bounded skew check are consistency checks, not
an upstream snapshot identifier. Claude must review the captured dates and
metadata before accepting the initial lock, particularly near export rollover.
The locked hashes then define the exact reproducible snapshot.

Completed downloads and their metadata/hash receipts stay in `<data-dir>/.cache/`,
including after validation or later download failures. A normal retry reuses
files only when Content-Length, ETag and Last-Modified all match fresh HEAD
metadata and local compressed/uncompressed hashes still verify. Changed or
corrupt entries are fetched again. Partial `.part` files remain for diagnosis
but are never accepted as completed downloads or resumed automatically. A
failed refresh leaves an earlier complete cached file intact.

To retry validation using the captured metadata without fresh HEAD requests
for already verified cache entries:

```bash
bash tools/lang/fetch_tatoeba.sh --pin-current --reuse-staging \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json
```

With a complete valid cache this makes no network requests. Missing or corrupt
entries still need normal acquisition. `--reuse-staging` explicitly trusts the
cached metadata; weekly date and skew checks still apply.

The reported compressed-byte total describes the full snapshot, not the bytes
remaining to download. Publishing uses hard links from the cache, avoiding a
second copy of compressed bytes. Decompressed TSVs, temporary SQLite databases,
graph assignments and prepared examples require additional space; their size
cannot be inferred from Content-Length. Locked replay verifies the pinned
hashes and archive structure without HEAD or current skew-policy checks, and
downloads only missing files. A complete valid set uses no network. Locks
without `snapshotSkew` remain readable; preparation always recomputes it.

Keep the original compressed files and the lock together. Once upstream
replaces an export, an old missing file may be unrecoverable: downloading new
bytes with an old lock fails rather than silently changing the snapshot.

All export rows are tab-separated, including the `.csv` TAR members:

| Export | TAR member | Fields in order |
| --- | --- | --- |
| `sentences_base.tar.bz2` | `sentences_base.csv` | `sentence_id, base_id` (2) |
| `links.tar.bz2` | `links.csv` | `id, id` (2) |
| `sentences_CC0.tar.bz2` | `sentences_CC0.csv` | `id, lang, text, modified` (4) |
| `per_language/<lang>/<lang>_sentences_detailed.tsv.bz2` | none (plain bz2) | `id, lang, text, username, created, modified` (6) |

Base rows contain no language or text. `sentence_id` is a canonical nonnegative
decimal ID; `base_id` is another such ID or the literal `\N` for an original
sentence. Both IDs must fit signed 64-bit storage. For example, the original
rows `2<TAB>\N` and `3<TAB>\N` each have two fields. Base references are validated
but do not add translation edges or vertices: the appendix defines grouping
through links only. Language/text selection uses detailed rows. Base IDs
without details remain graph vertices and are counted as `languageExcluded`
with `language: "und"` in exclusion provenance to mark language unavailable from
the selected detailed exports.

Detailed TSV rows have no license field. Matching same-snapshot CC0 IDs use CC0-1.0;
other admitted detailed rows use CC-BY-2.0-FR and require contributor
attribution. Missing owners for attributed sentences are excluded. Unknown
licenses are never relabeled MIT. Actual snapshot hashes and contributor
attribution are produced only during the approved run.

## Offline preparation and export

Snapshot the merged WP1 corpus through its explicit inventory adapter. It
checks commit-pinned original bytes and declared UTF-8/windows-1250 encodings,
preserves decoded text and gold labels, and derives HTTPS source URLs and the
UTC snapshot date from the corpus commit. Owned documents remain separate
from text training, calibration and text support.

```bash
python3 -B tools/lang/prepare_corpus.py \
  --snapshot-wp1 eval/multilingual \
  --wp1-output /private/tmp/ainotebook-wp4-documents.json

python3 -B tools/lang/prepare_corpus.py \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json \
  --config tools/lang/training-v1.json \
  --output-dir /private/tmp/ainotebook-wp4-prepared
```

Preparation groups the global translation graph before filtering and assigns
all blocks of a component to one deterministic split. It applies per-language
caps after splitting, then derives prefixes, stripped-mark examples and
`concat-v1` concatenations only from originals. Outputs are `examples.jsonl`,
`groups.jsonl`, `provenance.json` and `selected-sentences.tsv`; derived examples
preserve their original (anchor) group identities. The trainer performs
preparation itself, so the second command is optional for inspecting
preparation independently.

### Long-text examples (`concat-v1`)

Tatoeba sentences are short: prefixes of single sentences cannot reach the
32/80/200-letter buckets, so without long examples those buckets lack
validation support, stay disabled, and every 512-scalar document window would
be `und`. `concat-v1` (appendix §7) builds, per split × language, examples
from several selected originals of that same split and language, each from a
distinct original translation group, joined by one space and cut to exactly
`lengths` scalars. Companion order comes from seeded SHA-256 draws per anchor,
so the output is deterministic and independent of input order. Each anchor
yields at most one example per length; the example keeps the anchor's record
key and group (`memberRecordKeys` lists all members), so group minima count
real original groups, never augmented rows.

`training-v1.json` enables it for `validation` and `test` only, with lengths
`[64, 160, 512, 1024]` (512 matches document `windowScalars`) and
`maxOutputsPerLength: 1000` per split × language. Training is unchanged on
purpose: features never cross word boundaries (appendix §3), so concatenated
training text would only reweight existing sentence counts. Expected buckets:
64 scalars → 32–79 letters, 160 → 80–199, 512 and 1024 → 200+. With up to
1000 anchors per language and length, every language with at least ~200
distinct validation/test groups (the smallest real pool, `sl`, has roughly
300 validation originals) can meet the 200-group minimum in all four buckets,
and the bounded caps add at most 40 000 examples per evaluation split.
`provenance.json` records the manifest-shaped `augmentation` counts plus the
full configured `augmentationRules` (including caps).

For an approved real run, pin the timestamp and exporter commit once, then use
the same values for both exports:

```bash
task_exporter_commit="$(git rev-parse HEAD)"
python3 -B tools/lang/train_detector.py \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json \
  --config tools/lang/training-v1.json \
  --output-dir /private/tmp/ainotebook-wp4-model-a \
  --wp1-documents /private/tmp/ainotebook-wp4-documents.json \
  --created-at 2026-10-09T00:00:00Z \
  --exporter-commit "$task_exporter_commit"
```

Repeat with `--output-dir /private/tmp/ainotebook-wp4-model-b` and compare all
output bytes. Use the same Python version, inputs, timestamp, exporter revision
and unrelated repository NOTICE text. The output directory contains:

- `lang-detector-v1.json` and `lang-detector-v1.manifest.json`.
- `ATTRIBUTION.md` and `NOTICE`, assembled before artifact hashing. Attribution
  is compact (well under 1 MB): it credits Tatoeba and both licenses, lists the
  pinned snapshot date with every export URL and SHA-256, aggregates contributor
  usernames with selected-sentence counts per license, and represents the full
  per-sentence list by the count and SHA-256 of `selected-sentences.tsv`
  (`sentenceId<TAB>language<TAB>licenseId<TAB>username`, numeric ID order),
  which `prepare_corpus.py` regenerates offline from the pinned exports. WP1
  documents and Unicode licensing follow.
- `support-report.json`, including preparation hashes, calibration diagnostics,
  validation/test support and metrics, readiness and full document predictions.
- `groups.jsonl`, the hash-referenced original-group split assignments.

The trainer only writes its output directory. NOTICE preserves unrelated
repository text and replaces or appends one marked generated section. Re-export
after copying that section into repository NOTICE remains idempotent. Nothing
is copied into runtime resources by this command.

The manifest records semantic arguments using literal `$DATA`, `$LOCK`,
`$CONFIG`, `$OUTPUT` and `$WP1` placeholders rather than local filesystem paths.
It records exact input digests as `--lock-sha256`, `--config-sha256` and
`--wp1-snapshot-sha256`; the CLI also accepts these optional arguments and
checks them against local bytes. The four Unicode source pins and actual Python
version are recorded separately. There are no third-party Python dependencies.

## Read-only verification and release evidence

```bash
python3 -B tools/lang/train_detector.py --verify-only \
  --data-dir /private/tmp/ainotebook-wp4-tatoeba \
  --lock tools/lang/tatoeba-v1.lock.json \
  --config tools/lang/training-v1.json \
  --output-dir /private/tmp/ainotebook-wp4-model-a \
  --wp1-documents /private/tmp/ainotebook-wp4-documents.json \
  --created-at 2026-10-09T00:00:00Z \
  --exporter-commit "$task_exporter_commit"
```

Verification rebuilds preparation, weights, validation calibration and reported
metrics from pinned local inputs, without modifying exported files or
regenerating NOTICE. It uses the manifest's recorded exporter revision, allowing
verification after an artifact commit has changed HEAD. Packaged artifact
directories may omit the developer report and group assignments; an existing
report must reconcile with its referenced assignments and reproduced results.

Only training examples contribute feature counts. Validation chooses thresholds
through integer histograms and exact support/error gates; test and document
predictions are reported after thresholds freeze. Insufficient validation
support disables a bucket. Insufficient held-out support is reported as a
release failure and never retunes or disables a threshold. Disabled buckets
produce `und` in final metrics. All-disabled output says
`NO_ENABLED_BUCKETS: usefulness review required`.

Successful export or verification is not the WP4 release gate. Task 14 must
evaluate the held-out corpus, run full Swift/C# production parity, and obtain
Claude's review of coverage, disabled buckets and document errors. Task 13's
real acquisition/training and Task 14 are outside this Python lane's work.

## Offline tests

```bash
python3 -B -m unittest discover -s tools/lang/tests -p 'test_*.py' -v
bash -n tools/lang/fetch_tatoeba.sh
swift test
dotnet test windows/tests/AINotebook.Core.Tests
```

Python tests use temporary invented TSV/bz2/TAR payloads and injected download
and metadata readers. Network openers are patched to fail. CI must never run
real acquisition or download training data. Reference tests exercise all 44
normalization cases, all 32 complete scoring trees, supplementary runtime
fixtures and all 19,074 pinned NFC conformance rows. Calibration tests cover
group/acceptance boundaries, exact metric denominators and grid tie-breaks;
training tests compare two-directory exports and isolate held-out labels.
Skew tests cover newer-than-base rows, CC0 language/text/time changes, overlapping
reasons, exact limits, deterministic hashes and graph preservation. Acquisition
tests exercise retries and metadata/cache corruption using injected readers.

The tools' manifest schema now accepts `snapshotSkew`; current exports always
include it. Before packaging a new model, Claude must update the strict Swift
and C# manifest validators and their shared fixtures to accept this additive
field. Those runtime and contract-document changes are outside this tools-only
task. Legacy zero-skew manifests remain verifiable by the Python tools.
