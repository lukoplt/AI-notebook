# Language detector v1 — normative appendix

Status: WP0 Task 7 contract, ready for joint review. This appendix defines the
runtime consumed by WP4; it does not claim that a trained model has met the
release gates. MUST, MUST NOT and SHALL are requirements. Where the design
specification §5 is less precise, this appendix governs. In particular, document
shares include unknown windows, and a single weakly supported language never
produces `mixed`.

## 1. Versions and integer conventions

Production targets are `cs`, `de`, `en`, `sk` (ASCII ascending), plus the pooled
profile `background`. Output labels also include `und` and, in document mode
only, `mixed`. `NULL` means detection has not run; it is not a detector result.
The synthetic fixture substitutes targets `xa`, `xb` and expressly identified
test parameters. It is not a deployable artifact.

Production constants, from `Tests/fixtures/contracts/constants-v1.json`, are:

| Parameter | Value |
| --- | --- |
| Maximum selected features **per profile**, orders 1, 2, 3 | 256, 1024, 4096 |
| `orderWeights` | [1, 2, 3] |
| `scoreScale` | 1024 |
| `lengthBucketStarts` | [12, 32, 80, 200] |
| `minLetters`, `minWords` | 12, 3 |
| `mixedDominanceBp` | 7000 |
| `inputCapScalars` (before and after normalization) | 5000000 |
| `textCapScalars` (ordinary text mode) | 8192 |
| `windowCount`, `windowScalars` (document mode) | 8, 512 |
| Additive smoothing `alpha` | 1 |

All runtime arithmetic uses signed 64-bit integers, including multiplication
before division. `floorDiv(a,b)` for positive `b` is mathematical floor:
`floorDiv(-7,3) = -3`, `floorDiv(-6,3) = -2`. Swift and C# division truncate
toward zero: compute `q = a / b`, then subtract one if `a < 0` and `a % b != 0`.
Never use floating point in inference. Basis points are integers out of 10000.
Do not round intermediate quantities except at the explicitly stated steps.

## 2. Input and normalization

### 2.1 Pinned Unicode data and the explicit fold table

Use **Unicode 15.1.0**, NFC as specified by
[UAX #15 revision 54](https://www.unicode.org/reports/tr15/tr15-54.html), including
algorithmic Hangul decomposition/composition and canonical ordering/blocking.
The fixed [Unicode 15.1 components](https://www.unicode.org/versions/components-15.1.0.html)
identify this version. Data source is
[UCD.zip](https://www.unicode.org/Public/zipped/15.1.0/UCD.zip), SHA-256
`cb1c663d053926500cd501229736045752713a066bd75802098598b7a7056177`.
The following hashes are over the uncompressed file bytes:

| File under `https://www.unicode.org/Public/15.1.0/ucd/` | SHA-256 |
| --- | --- |
| `UnicodeData.txt` | `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86` |
| `CaseFolding.txt` | `4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf` |
| `DerivedNormalizationProps.txt` | `8875dccee2bc1a7c1fe568a3b502a9e78c9e0495afd96b6568b4294d0ed1f7e1` |
| `NormalizationTest.txt` (conformance test) | `871238e37e3be0696ec2bd0891119a041b052da1a84485eda05a5438724b223e` |

`normalizationTablesVersion` is exactly `ucd-15.1.0-default-full-v1`.
The **complete explicit case-fold table** is the `C` and `F` rows of this exact
[CaseFolding.txt](https://www.unicode.org/Public/15.1.0/ucd/CaseFolding.txt), mapping
the first column's scalar to the third column's ordered scalar sequence. Ignore
`S` and `T` rows and comments. Every scalar absent from those rows maps to itself.
Apply the table once, independently to each input scalar; no context rules,
recursive substitution, locale rules or host-library lowercasing. These are
selected required rows (hexadecimal scalar notation here only):

| Input | Output |
| --- | --- |
| U+0041…U+005A | U+0061…U+007A, respectively |
| U+00DF `ß`, U+1E9E `ẞ` | U+0073 U+0073 (`ss`) |
| U+0049 `I` | U+0069 (`i`) |
| U+0130 `İ` | U+0069 U+0307 (`i` + combining dot) |
| U+0131 `ı`, U+0069 `i` | identity |
| U+010C `Č`, U+013D `Ľ`, U+0139 `Ĺ`, U+0154 `Ŕ` | U+010D, U+013E, U+013A, U+0155 |
| U+00D4 `Ô`, U+00C4 `Ä`, U+00D6 `Ö`, U+00DC `Ü` | U+00F4, U+00E4, U+00F6, U+00FC |
| U+03A3 `Σ`, U+03C2 `ς` | U+03C3 `σ` |
| U+0410…U+042F | U+0430…U+044F, respectively |

Final-sigma *position* is irrelevant: both sigma forms fold to U+03C3 everywhere.
The full source table, not just these example rows, is normative. Implementations
MUST bundle tables generated from these pinned bytes. An OS NFC/folding/category
API is conforming only if it implements these exact data for every scalar;
an OS version's current Unicode data is not a substitute.

Canonical decomposition, canonical combining class and General_Category come
from `UnicodeData.txt`; expand its `First`/`Last` ranges. Canonical composition
uses the canonical two-scalar decompositions except members of
`Full_Composition_Exclusion` in `DerivedNormalizationProps.txt`. Unlisted
scalars have category `Cn` and combining class zero. Compatibility decomposition
is not used. Validate NFC against the pinned `NormalizationTest.txt`.

### 2.2 Decode, cap, normalize, classify

1. Accept exactly one input representation: a well-formed Unicode string, or
   `utf16Units`, an array of integers 0…65535. For UTF-16, a high surrogate
   U+D800…U+DBFF immediately followed by a low surrogate U+DC00…U+DFFF becomes
   `65536 + (high-55296)*1024 + low-56320`. Each otherwise unpaired unit becomes
   **one U+FFFD**. Do not swallow an adjacent nonmatching unit. C# strings pass
   through these same decoding rules; a Swift `String` is already well formed
   and receives invalid UTF-16 only through the explicit `utf16Units` path.
   Ill-formed surrogate escapes in JSON string input are invalid fixture data,
   never a way of exercising this rule.
2. Retain the first `inputCapScalars` decoded scalars. The cap is after decoding
   surrogate pairs, not a UTF-16-unit, byte or grapheme count. Discard the suffix.
3. Apply **NFC → full table case-fold → NFC**, to the entire retained sequence.
   Retain its first `inputCapScalars` scalars again, bounding expansions. This
   result is the *normalized stream*, still containing boundary characters.
4. Text mode takes the first `textCapScalars` scalars of that stream. Document
   mode slices the stream as in §5. Normalization fixtures classify the entire
   normalized stream using the production input cap, without the text-mode cap.
5. For each slice, start with no active word. Categories `Lu`, `Ll`, `Lt`, `Lm`,
   `Lo` append to/start the active word and increment its letter count.
   Categories `Mn`, `Mc`, `Me` append **only if a word is active**; otherwise
   discard the mark. A sequence of marks may attach to the preceding letter
   through other attached marks. Marks contribute scalar features but zero
   letters. Every other category ends the word and is discarded.
6. Flush an active word at the slice end. No empty words are emitted. Each
   emitted word contains at least one letter. `wordCount` is the number emitted;
   `letterCount` counts category-L scalars in the normalized words. Expansions
   count after folding (`ß` counts as two letters), not by original characters.

Digits of every script, apostrophes including U+0027/U+2019, hyphens/dashes,
underscore, punctuation, symbols, emoji, ZWJ/ZWNJ, controls, U+FFFD, unassigned
scalars and all separators are boundaries. Whitespace gets no separate runtime
predicate: space, NBSP, tab, CR and LF are boundaries by the same category rule.
An unattached mark never bridges a boundary. Diacritics are preserved. A
modifier letter such as U+02BC **is a letter**, even if it looks like punctuation.
No script change creates a boundary. Slices and caps need not align with words
or combining sequences: edge word fragments are ordinary words, a leading
detached mark is discarded, and discarded text supplies no boundary feature.

## 3. Features, training counts and export

For each normalized word, create `[-1] + wordScalars + [-2]`. Here `-1` is BOS
and `-2` EOS; they are integers outside Unicode, not literal `^`, `$` or text.
For each order `n = 1,2,3`, emit every contiguous length-n tuple, starting at
each index `0…length-n`, once. Include boundary-only unigrams. There is exactly
one BOS and one EOS, with no repeated padding. Never emit a tuple crossing a
word boundary. A one-letter word therefore emits 3, 2, 1 features by order.
Counts are **occurrences**, including repeats within and across words.

Tuple order is lexicographic by signed integer value (shorter prefix first).
Feature serialization is an array of scalar/BOS/EOS integers. No string encoding,
locale collation, UTF-16 ordering or hash iteration order decides a tie.

For each profile and order, count all features in the training partition after
normalization/augmentation. Each training example uses the text-mode caps and
classification independently; never concatenate examples into a word. Select
at most that order's per-profile cap, ordered
by decreasing count, ties by tuple order; do not select zero-count features.
The shared `V[n]` is the **union** of those selections across targets **and
background**, sorted by tuple order. Its size can exceed the per-profile cap.
The negative-language sentences form one pooled background corpus, with each
selected/augmented sentence counted once, without per-language reweighting.
Validation/test text MUST NOT contribute features or counts.

For each profile `p`, `c[p,n,f]` is its original training occurrence count for
every `f in V[n]` (including features selected only by another profile).
`c[p,n,UNK]` is the sum of all its counts outside `V[n]`. There is exactly one
separate unknown bucket per order; it is **not** part of the exported vocabulary
or its size limit. Let `T[p,n]` be all training occurrences, including unknown:

```text
P[p,n,f] = (c[p,n,f] + 1) / (T[p,n] + |V[n]| + 1)
w[p,n,f] = roundTiesToEven(ln(P[p,n,f]) * scoreScale)
```

This formula also applies to UNK. `ln` is the natural logarithm. Export rounding
is nearest integer, with exact halfway values going to the even integer:
`-2.5 → -2`, `-3.5 → -4`. Compute the exact rational probability before logarithm;
use arbitrary precision/interval refinement sufficient to prove the rounded
integer, rather than accepting host `double` differences. Runtime consumes the
exported integers and never recomputes logarithms. A zero-count profile remains
defined by smoothing, although production training must meet §7 support rules.

Every profile, **including background**, has prior probability `1/profileCount`.
Export `priorWeight = roundTiesToEven(ln(1/profileCount)*scoreScale)` identically
for all profiles. There are no learned target priors, length priors, or extra
background penalties. For the three-profile fixture this weight is `-1125`.

## 4. Integer scoring and abstention

Map each observed tuple to its vocabulary index or the corresponding UNK. Let
`h[n,f]` be occurrence counts, `F[n] = sum_f h[n,f]`, and `K[n]` be the number of
occurrences whose raw tuple is in `V[n]`. For each profile:

```text
orderScore[p,n] = floorDiv(sum_f(h[n,f] * w[p,n,f]), F[n])
combinedScore[p] = priorWeight[p] + sum_n(orderWeights[n] * orderScore[p,n])
coverageBp = floorDiv(10000 * sum_n K[n], sum_n F[n])
```

If `F[n] = 0`, that order's score is zero. With zero total features coverage is
zero. There is **no division by the sum of order weights**, no unique-feature
average, and no length multiplier on the prior. All orders contribute equally
to the coverage denominator by occurrence (coverage itself is not weighted).
Unknown features still contribute their unknown weights and occurrence counts.

Rank **all** profiles by decreasing combined score. A tie ranks background
first, then target IDs in ASCII ascending order. `winner` is the first profile,
`runnerUp` the second, and `margin` is their nonnegative score difference.
Return diagnostic scores even if the text is too short. Evaluate these checks
in order, returning `und` and the first listed reason on failure:

1. `letterCount < minLetters`: `minLetters`.
2. `wordCount < minWords`: `minWords`.
3. Select the greatest bucket start ≤ letterCount; if its `enabled` is zero:
   `bucketDisabled`. Buckets are [12,32), [32,80), [80,200), [200,infinity).
4. Winner is background: `background`.
5. Winning combined score < bucket `minWinningScore`: `minWinningScore`.
6. Margin < bucket `minMargin`: `minMargin`.
7. Coverage < bucket `minKnownCoverageBp`: `minKnownCoverageBp`.

Otherwise output the winning target and reason `accepted`. Equality at every
minimum passes. Ties still obey the margin threshold. Production enabled
buckets require `minMargin >= 1`. Below the first bucket, diagnostic
`bucketStart` is `null`. Thresholds are exported calibrated **integers**, with
one triple shared by all profiles for each bucket. WP0 freezes their semantics,
not unmeasured production values. Insufficient support forces `enabled = 0`.

## 5. Document sampling and aggregation

Use the normalized stream from §2, **before** the text-mode cap or word
classification. Let its scalar length be `N`, `C = windowCount`, `S =
windowScalars`. If `N = 0`, sample no windows. Otherwise:

```text
k = min(C, ceilDiv(N,S))           # ceilDiv(a,b) = floorDiv(a+b-1,b)
w = min(S, floorDiv(N,k))
start[i] = 0                      # k = 1, i = 0
start[i] = floorDiv(i*(N-w), k-1)  # k > 1, i = 0…k-1
end[i] = start[i] + w
```

Offsets are zero-based normalized-stream scalar offsets, `[start,end)`.
Windows have equal size, are ordered and never overlap; the first starts at
zero and the last ends at N. They may omit intervening text. Classify and score
each slice independently using §2–4 and the same buckets/minima, without
renormalizing and without inheriting any neighboring language. `S <=
textCapScalars` is required. Do not sample overlapping chunks or weight a
window by confidence, word count, window count or margin.

Let `L[i]` be each window's letter count. `T = sum_i L[i]` includes **every**
sampled window, even those labeled `und`. For each target `p`, let `A[p]` be the
sum of `L[i]` only from windows confidently labeled `p`. Let `U` sum the letters
in `und` windows. Then `T = U + sum_p A[p]`.

```text
shareBp[p] = T == 0 ? 0 : floorDiv(10000*A[p], T)
unknownShareBp = T == 0 ? 0 : floorDiv(10000*U, T)
langCoverageBp = T == 0 ? 0 : floorDiv(10000*sum_p A[p], T)
```

Round each reported share separately; shares need not sum to 10000. Dominance
uses the **unrounded** comparison `10000*A[p] >= mixedDominanceBp*T`, with
`A[p] > 0`. If such a target exists, return it (`dominant`). With the frozen
7000 threshold there can be at most one. Otherwise, return `mixed` (`mixed`)
only if at least two distinct targets have `A[p] > 0`; else return `und`
(`insufficientEvidence`). This includes zero-letter documents and one accepted
window diluted below dominance by unknown windows. Exactly 7000 bp qualifies
as dominant. An arbitrarily small minority is still evidence for `mixed` when
two targets are confident and neither dominates; there is no extra hidden
document threshold. `sources.lang_coverage` represents `langCoverageBp/10000`;
the contract/API exchange uses the integer basis-point field. Scoring never
changes a stored `NULL` except as the result of an actual detection run.

## 6. Artifact schema and integrity

The JSON Schema in §9 defines `lang-detector-v1.json`. JSON is UTF-8 without BOM,
LF terminated. Number tokens MUST be decimal integers (no fraction or exponent,
including `1.0`/`1e0`); booleans are not integers. Reject duplicate object keys,
missing/unknown keys, invalid ranges, incompatible versions and failed semantic
checks; do not silently substitute a model or thresholds. An invalid artifact
is a load error, not evidence for any language.

Additional semantic checks, beyond JSON Schema:

- Production parameters equal §1, targets equal [`cs`,`de`,`en`,`sk`], `alpha`
  equals 1 and normalization version equals §2. Synthetic parameters may differ
  only in targets, feature caps, input/text caps and window count/size. The four
  bucket starts, minima, order weights, scale and dominance remain frozen.
- Input/text caps are positive, `windowScalars <= textCapScalars <=
  inputCapScalars <= 5000000`, windowCount ≤ 8. Weights lie in [-1000000,0];
  these bounds and input caps keep all stated sums/products within Int64.
- Vocabulary orders are exactly 1,2,3; features have their order's length and
  are unique and tuple-sorted. Allowed symbols are Unicode scalars or -1/-2;
  surrogate values are invalid. BOS occurs only first and EOS only last, never
  twice. Except boundary-only unigrams, each tuple contains a letter/attached
  mark; `[-1,-2]` is invalid. Size per order ≤ profileCount × per-profile cap.
- Profiles appear in [`background`] + targets order, exactly once each. Every
  profile has three order records in order 1,2,3. Its `weights` array is aligned
  index-for-index with that vocabulary; `unknownWeight` is separate. All priors
  equal the export formula, not a JSON default. Targets are sorted and unique.
- Thresholds have exactly four records at starts 12,32,80,200, ordered. Enabled
  records have positive minimum margin. Exporters must verify all weights by
  §3 and record training provenance; runtimes need not reproduce training.
- Normalization tables are bundled in each platform's runtime from the pinned
  sources, identified by the artifact's table version. The artifact cannot
  override folding or categories. The manifest pins source-file hashes as well
  as the exact artifact bytes, preventing a changed table under the same name.
- `attribution` lists the actual contributing source IDs and license identifiers,
  an attribution-file path and SHA-256, and a NOTICE path and SHA-256. Production
  files must ship beside the artifact/package; the fixture uses `kind=synthetic`,
  empty source/license lists and empty attribution/NOTICE paths and hashes,
  denoting wholly invented training text. Unicode table licensing must also be
  carried by the production package's NOTICE. Because every production bundle
  redistributes the pinned Unicode tables, a production manifest's
  `attribution.sourceIds` set must equal the `corpus` IDs and its
  `attribution.licenseIds` set must equal the union of all `corpus[].licenseIds`
  plus `Unicode-3.0` (the Unicode License V3 identifier); a production
  attribution without `Unicode-3.0` is rejected. Do not label unknown corpus
  licenses as MIT. `artifactSha256` in the manifest hashes exact file bytes,
  excluding nothing; the artifact has no self-referential checksum field.

## 7. Training manifest schema and release gates

The schema in §10 defines `lang-detector-v1.manifest.json`. It is a production
training record, not required for the intentionally tiny scoring fixture.
All IDs, counts, decisions and hashes must be reproducible. SHA-256 strings are
lowercase hexadecimal. Dates are UTC `YYYY-MM-DD`; timestamps use RFC 3339 UTC.

Each `corpus` entry records source ID, sentence/link/attribution export URLs,
snapshot date, downloaded-byte SHA-256, format/version, exact license IDs,
selection policy and actual record counts. Each input file has its own hash.
`languageMappings` maps every admitted source language code to its detector
language ID (for example Tatoeba `ces` to `cs`); codes absent from this mapping
are excluded. A detector ID may have multiple source codes, but each source
code maps to exactly one ID. Group construction still includes excluded IDs.
For Tatoeba, preserve sentence IDs, contributor attribution and per-sentence
license IDs from the chosen export; license inclusion policy is explicit.
`negativeLanguages` is the exact sorted list of admitted language IDs, disjoint
from targets; `pl, sl, hr, nl, fr, hu` are suggestions, not an implicit whitelist.
The manifest records the exporter revision, command arguments, dependency
versions, Unicode sources/hashes, seed and parameter search/tie rules.

The v1 split algorithm is `translation-components-sha256-v1`:

1. Canonical record keys are `sourceId:sentenceId` (ASCII source IDs and decimal
   nonnegative IDs without leading zeroes except zero). In each source, build
   undirected connected components over **all** sentence IDs and translation
   links in the snapshot, including languages later filtered out. Missing link
   endpoints are vertices without text; no link is silently discarded.
2. A group is that entire connected component. Sort its keys by UTF-8 bytes.
   Its ID is the lowercase SHA-256 of their UTF-8 strings joined with LF,
   **with a final LF**. Identical text without a link is not a translation
   group; explicitly record cross-source deduplication/exclusion policy.
3. Components above `maxComponentMembers` are deterministically split for
   processing into consecutive sorted-key blocks of that size. Record each
   original group ID, member count and every block's ID (same hashing rule).
   **All blocks inherit the original group's split**, so translations never
   leak across train/validation/test. Count these as one independent validation
   group, regardless of how many blocks/augmentations they yield.
4. Compute SHA-256 of UTF-8 `decimalSeed + LF + originalGroupId + LF`. Interpret
   the first 8 digest bytes as an unsigned big-endian integer and reduce modulo
   10000. Assign by cumulative half-open ranges from `splitBp` in train,
   validation, test order; all are positive and sum to 10000. No runtime PRNG,
   shuffled iteration order or process hash is used.
5. Filter licenses/languages and enforce recorded caps **after** assigning groups.
   For each language/split, sort eligible records by SHA-256 of UTF-8
   `decimalSeed + LF + recordKey + LF`, ties by record-key bytes, then take its
   declared cap. Background receives each selected negative sentence once.
   Never move records between splits to meet counts.

Augmentation occurs only after split assignment, preserves the original group
ID, and cannot create an independent validation group. Each enabled rule records
its name/version, applicable splits, order, input/output counts, parameter
values and an unambiguous algorithm. V1 allowed algorithms are:

- `scalar-prefix-v1`: from the already normalized stream, independently emit
  prefixes at each ascending unique `lengths` scalar count, excluding a prefix
  identical to the full stream. Classify each prefix as its own sample. No
  random offset; preserve source identity and `(rule,length)` identity.
- `strip-marks-v1`: pinned canonical NFD, remove category-M scalars, then NFC.
  Keep only changed output. This strips decomposable accents, not `ł` or `ß`.
- `concat-v1`: multi-sentence text for the long buckets. For each applicable
  split × language, the pool is that split/language's selected originals'
  normalized streams in cap order (step 5). For each ascending unique `lengths`
  value `L`, each pool record in order is an anchor yielding at most one example:
  draw companion `k = 1, 2, ...` at pool index
  `uint64be(SHA-256(UTF-8 decimalSeed + LF + "concat-v1" + LF + L + LF +
  anchorRecordKey + LF + k + LF)[0..7]) mod poolSize`, skipping any record whose
  original group is already present; append it after one U+0020 until the
  joined stream has at least `L` scalars, then keep exactly its first `L`.
  Members therefore share one split and language and come from distinct
  original groups. An anchor that alone has `L` or more scalars, or that does
  not reach `L` within `4*L` draws, yields nothing. Stop after the
  training-config output cap for that split × language (per length). The
  example keeps the anchor's record key and original group ID, so it adds at
  most one group and never more than one example per original and length.
- `none-v1`: no derived examples. Rules operate on originals, never on outputs
  of other rules. If different rules yield equal text, retain separate example
  identities and count them separately. The original is retained once.

Record actual original/augmented counts by split × language × length bucket
(use start 0 for <12 letters) and all filter/cap/drop reasons. Owned technical
and document examples belong to a separate named held-out source; their source
IDs, hashes, labels and translation-group policy must be recorded too.

Each enabled bucket must have validation support from at least **200 distinct
original groups per target**, **200 per negative language**, and **1000 total
accepted predictions**; augmented examples cannot inflate the group minima.
Additionally require 100 accepted true-cs and 100 accepted true-sk examples.
If any minimum is unmet, disable that bucket (`enabled=0`) even if a reported
error rate is zero. Calibrate only on validation; report untouched test results
separately. Disabled-bucket predictions are `und` in final metrics. Counts for
candidate thresholds may be recorded separately to explain disabling.

Metric records carry raw numerators and denominators plus
`rateBp = floorDiv(10000*numerator,denominator)` (zero denominator gives `null`,
never success). Gate comparisons use exact integer cross-products, not the
rounded rate. For each enabled bucket, on validation **and** held-out test:

| Metric | Numerator | Denominator | Gate |
| --- | --- | --- | --- |
| `acceptedError` | Accepted target predictions unequal to truth, including accepted negatives | All accepted target predictions on targets and negatives | ≤ 200 bp |
| `csSkConfusion` | True cs predicted sk plus true sk predicted cs | Accepted predictions whose true label is cs or sk, including predictions of other targets | ≤ 100 bp |
| `foreignAcceptance` | Negative-language examples accepted as any target | All evaluated negative-language examples, including `und` | ≤ 100 bp |

Each augmented/ordinary example is one evaluated example; group support is a
separate distinct-original-group count. Text metrics exclude document-mode
examples, whose confusion counts are reported separately against document gold
labels. Report acceptance coverage as accepted/all evaluated, also by language
and bucket, so abstention cannot hide recall loss. Test support uses the same
minima; insufficient test support fails the release gate rather than silently
retuning/disabling a bucket from test observations. Model selection objective,
integer candidate grid and tie-break order are recorded in `calibration`.

`grid-max-accepted-v1` enumerates the Cartesian product of the three candidate
arrays for each bucket. First discard candidates failing support or any exact
validation gate. Choose the candidate accepting the most validation examples;
ties choose the greatest `minWinningScore`, then greatest `minMargin`, then
greatest `minKnownCoverageBp`. No eligible candidate disables that bucket.
Candidate arrays are sorted ascending, unique and nonempty; their bucket
records appear in start order. The synthetic fixture's thresholds are invented
test values and are exempt from production calibration/support requirements.

Manifest record arrays must have unique compound keys. `caps` covers every
admitted language × split; `counts` covers every language × split × bucket,
including zero counts. `support` covers every language × validation/test ×
nonzero bucket; a group spanning several buckets counts once in each bucket.
`metrics` uses the true language ID or `all` for aggregation; gate rows use
`all`. Report all four metric names per bucket/split, with impossible or empty
denominators recorded as zero and rates null. Numerators never exceed
denominators; counts refer to examples after filtering, caps and augmentation.
Document examples contribute only to `documentMetrics`, not text counts/support.
Every source file and corpus ID, language mapping, split assignment and
attribution reference must reconcile. `unicodeFiles` lists exactly the four
§2 files with their hashes. Production attribution fields are nonempty and
equal between manifest and artifact. Dates must also be valid calendar dates.
Augmentation array order is rule order; algorithm IDs cannot repeat;
`none-v1` must stand alone. Only `scalar-prefix-v1` and `concat-v1` have
nonempty `lengths`.
All other augmentation records use `lengths: []`.

## 8. Shared fixture shape and worked checks

`lang-normalize-v1.json` has `{contract:"lang-normalize",version:1,cases:[...]}`.
Each uniquely named case contains exactly one of `input`/`utf16Units` and
`expected:{words,wordScalars,boundaryWords,letterCount,wordCount}`. `words` and
`wordScalars` are the same normalized words as strings and scalar arrays;
`boundaryWords` adds -1/-2. No detached marks or boundary text remains.

`lang-score-v1.json` has `{contract:"lang-score",version:1,model,training,cases}`.
`model` conforms to §9 with `kind:"synthetic"`. `training` gives per-profile
`{word,count}` rows; expand each word `count` times into separate training words.
It reproduces feature selection, smoothing, priors and every exported weight.
This small model has 5/9/9 known features plus one UNK per order, within the
fixture's ≤10-known-features-per-order limit.

Cases have unique `name`, `mode` (`text`/`document`), `input` and `expected`.
Text expectations carry normalized `words`, `wordScalars`, counts, bucket start,
`features` (three arrays of `{symbols,count}`, **raw tuples**, tuple-sorted),
`featureCounts`, `knownCounts`, `unknownCounts`, `profiles` (each ID maps to
`weightedSums`, `orderScores`, `combinedScore`), winner, runner-up, margin,
coverage, label and reason. Unknown raw tuples remain distinct in `features`;
their counts share one unknown weight during scoring.

Document expectations carry normalized-stream `normalizedScalarCount`, actual
`windowCount`/`windowScalars` (both zero when empty), ordered windows
`{start,end,expected}` with the complete text expectation for each slice, plus
`sampledLetters`, `acceptedLetters` per target, `unknownLetters`, `sharesBp`,
`unknownShareBp`, `langCoverageBp`, label and reason. There is no fictitious
whole-document winner/margin: those are defined per window, while the final
document decision uses letter shares.

Hand checks for the synthetic training corpus:

- Profile xa has 11 four-letter training words. Its unigram total is 66;
  vocabulary size is 5, so the smoothed denominator is 72. Count of `a` is 36,
  hence `roundEven(1024*ln(37/72)) = -682`; each boundary has count 11, hence
  weight -1835; the unknown count is zero, hence weight -4379.
- `aaaa aaaa aaaa` has feature counts [18,15,12]. For xa, weighted sums are
  [-19194,-19260,-16782]; floor division gives [-1067,-1284,-1399]. Combined
  score is `-1125 -1067 + 2*(-1284) + 3*(-1399) = -8957`.
- `aaaa aaaa aaad` has 40 known occurrences out of 45: coverage is 8888 bp,
  failing the fixture's 9000 bp minimum despite a strong winning score.
- Three 12-letter windows labeled xa, xb, und yield shares 3333/3333, unknown
  share 3333, coverage 6666, and `mixed`. xa, und, und yields `und`, not mixed.

The fixtures exercise short input, too few words, each threshold, disabled
buckets, background and target ties, unknown features, signed floor division,
caps, exact bucket transitions, normalization and document sampling. A fixture
envelope test alone cannot validate scoring: consumers must compare every
intermediate field and validate the embedded model against its training counts.

## 9. JSON Schema: artifact

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:ainotebook:lang-detector:1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "contract",
    "version",
    "kind",
    "modelId",
    "targets",
    "normalizationTablesVersion",
    "alpha",
    "parameters",
    "vocabulary",
    "profiles",
    "thresholds",
    "attribution"
  ],
  "properties": {
    "contract": {"const": "lang-detector"},
    "version": {"const": 1},
    "kind": {"enum": ["production", "synthetic"]},
    "modelId": {"type": "string", "pattern": "^[A-Za-z0-9._-]+$"},
    "targets": {
      "type": "array",
      "items": {"type": "string", "pattern": "^[a-z]{2,3}$"},
      "minItems": 2,
      "maxItems": 4
    },
    "normalizationTablesVersion": {"const": "ucd-15.1.0-default-full-v1"},
    "alpha": {"const": 1},
    "parameters": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "maxFeaturesPerProfile",
        "orderWeights",
        "scoreScale",
        "lengthBucketStarts",
        "minLetters",
        "minWords",
        "mixedDominanceBp",
        "inputCapScalars",
        "textCapScalars",
        "windowCount",
        "windowScalars"
      ],
      "properties": {
        "maxFeaturesPerProfile": {
          "type": "array",
          "items": {"type": "integer", "minimum": 1, "maximum": 4096},
          "minItems": 3,
          "maxItems": 3
        },
        "orderWeights": {"const": [1, 2, 3]},
        "scoreScale": {"const": 1024},
        "lengthBucketStarts": {"const": [12, 32, 80, 200]},
        "minLetters": {"const": 12},
        "minWords": {"const": 3},
        "mixedDominanceBp": {"const": 7000},
        "inputCapScalars": {"type": "integer", "minimum": 1, "maximum": 5000000},
        "textCapScalars": {"type": "integer", "minimum": 1, "maximum": 5000000},
        "windowCount": {"type": "integer", "minimum": 1, "maximum": 8},
        "windowScalars": {"type": "integer", "minimum": 1, "maximum": 5000000}
      }
    },
    "vocabulary": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["order", "features"],
        "properties": {
          "order": {"type": "integer", "minimum": 1, "maximum": 3},
          "features": {
            "type": "array",
            "items": {
              "type": "array",
              "items": {
                "anyOf": [
                  {"enum": [-2, -1]},
                  {
                    "anyOf": [
                      {"type": "integer", "minimum": 0, "maximum": 55295},
                      {"type": "integer", "minimum": 57344, "maximum": 1114111}
                    ]
                  }
                ]
              },
              "minItems": 1,
              "maxItems": 3
            },
            "minItems": 0,
            "maxItems": 20480
          }
        }
      },
      "minItems": 3,
      "maxItems": 3
    },
    "profiles": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["id", "priorWeight", "orders"],
        "properties": {
          "id": {"type": "string", "pattern": "^([a-z]{2,3}|background)$"},
          "priorWeight": {"type": "integer", "minimum": -1000000, "maximum": 0},
          "orders": {
            "type": "array",
            "items": {
              "type": "object",
              "additionalProperties": false,
              "required": ["order", "weights", "unknownWeight"],
              "properties": {
                "order": {"type": "integer", "minimum": 1, "maximum": 3},
                "weights": {
                  "type": "array",
                  "items": {"type": "integer", "minimum": -1000000, "maximum": 0},
                  "minItems": 0,
                  "maxItems": 20480
                },
                "unknownWeight": {"type": "integer", "minimum": -1000000, "maximum": 0}
              }
            },
            "minItems": 3,
            "maxItems": 3
          }
        }
      },
      "minItems": 3,
      "maxItems": 5
    },
    "thresholds": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["start", "enabled", "minWinningScore", "minMargin", "minKnownCoverageBp"],
        "properties": {
          "start": {"enum": [12, 32, 80, 200]},
          "enabled": {"enum": [0, 1]},
          "minWinningScore": {"type": "integer", "minimum": -7000000, "maximum": 0},
          "minMargin": {"type": "integer", "minimum": 0, "maximum": 7000000},
          "minKnownCoverageBp": {"type": "integer", "minimum": 0, "maximum": 10000}
        }
      },
      "minItems": 4,
      "maxItems": 4
    },
    "attribution": {
      "type": "object",
      "additionalProperties": false,
      "required": ["sourceIds", "licenseIds", "attributionPath", "attributionSha256", "noticePath", "noticeSha256"],
      "properties": {
        "sourceIds": {"type": "array", "items": {"type": "string", "pattern": "^[A-Za-z0-9_-]+$"}, "minItems": 0},
        "licenseIds": {"type": "array", "items": {"type": "string"}, "minItems": 0},
        "attributionPath": {"type": "string"},
        "attributionSha256": {"type": "string", "pattern": "^([0-9a-f]{64})?$"},
        "noticePath": {"type": "string"},
        "noticeSha256": {"type": "string", "pattern": "^([0-9a-f]{64})?$"}
      }
    }
  }
}
```

## 10. JSON Schema: training manifest

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "urn:ainotebook:lang-detector-manifest:1",
  "type": "object",
  "additionalProperties": false,
  "required": [
    "contract",
    "version",
    "modelId",
    "artifactPath",
    "artifactSha256",
    "createdAt",
    "corpus",
    "negativeLanguages",
    "environment",
    "split",
    "caps",
    "augmentation",
    "counts",
    "exclusions",
    "minimumSupport",
    "calibration",
    "support",
    "metrics",
    "documentMetrics",
    "attribution"
  ],
  "properties": {
    "contract": {"const": "lang-detector-manifest"},
    "version": {"const": 1},
    "modelId": {"type": "string", "pattern": "^[A-Za-z0-9._-]+$"},
    "artifactPath": {"type": "string"},
    "artifactSha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
    "createdAt": {"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"},
    "corpus": {"type": "array", "items": {"$ref": "#/$defs/corpus"}, "minItems": 1},
    "negativeLanguages": {"type": "array", "items": {"type": "string", "pattern": "^[a-z]{2,3}$"}, "minItems": 1},
    "environment": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "exporterGitCommit",
        "commandArguments",
        "pythonVersion",
        "dependencies",
        "normalizationTablesVersion",
        "unicodeFiles"
      ],
      "properties": {
        "exporterGitCommit": {"type": "string", "pattern": "^[0-9a-f]{40,64}$"},
        "commandArguments": {"type": "array", "items": {"type": "string"}, "minItems": 1},
        "pythonVersion": {"type": "string"},
        "dependencies": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["name", "version"],
            "properties": {"name": {"type": "string"}, "version": {"type": "string"}}
          },
          "minItems": 0
        },
        "normalizationTablesVersion": {"const": "ucd-15.1.0-default-full-v1"},
        "unicodeFiles": {"type": "array", "items": {"$ref": "#/$defs/file"}, "minItems": 4, "maxItems": 4}
      }
    },
    "split": {
      "type": "object",
      "additionalProperties": false,
      "required": ["algorithm", "seed", "splitBp", "maxComponentMembers", "oversizedComponents"],
      "properties": {
        "algorithm": {"const": "translation-components-sha256-v1"},
        "seed": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "splitBp": {
          "type": "object",
          "additionalProperties": false,
          "required": ["train", "validation", "test"],
          "properties": {
            "train": {"type": "integer", "minimum": 1, "maximum": 9998},
            "validation": {"type": "integer", "minimum": 1, "maximum": 9998},
            "test": {"type": "integer", "minimum": 1, "maximum": 9998}
          }
        },
        "maxComponentMembers": {"type": "integer", "minimum": 1, "maximum": 9007199254740991},
        "oversizedComponents": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["groupId", "memberCount", "blocks"],
            "properties": {
              "groupId": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
              "memberCount": {"type": "integer", "minimum": 1, "maximum": 9007199254740991},
              "blocks": {
                "type": "array",
                "items": {
                  "type": "object",
                  "additionalProperties": false,
                  "required": ["groupId", "memberCount"],
                  "properties": {
                    "groupId": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
                    "memberCount": {"type": "integer", "minimum": 1, "maximum": 9007199254740991}
                  }
                },
                "minItems": 1
              }
            }
          },
          "minItems": 0
        }
      }
    },
    "caps": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["split", "language", "maxOriginalRecords"],
        "properties": {
          "split": {"enum": ["train", "validation", "test"]},
          "language": {"type": "string"},
          "maxOriginalRecords": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
        }
      },
      "minItems": 1
    },
    "augmentation": {"type": "array", "items": {"$ref": "#/$defs/augmentation"}, "minItems": 1},
    "counts": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["split", "language", "bucketStart", "originals", "augmented", "originalGroups"],
        "properties": {
          "split": {"enum": ["train", "validation", "test"]},
          "language": {"type": "string"},
          "bucketStart": {"enum": [0, 12, 32, 80, 200]},
          "originals": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
          "augmented": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
          "originalGroups": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
        }
      },
      "minItems": 1
    },
    "exclusions": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["sourceId", "split", "language", "reason", "count"],
        "properties": {
          "sourceId": {"type": "string"},
          "split": {"enum": ["train", "validation", "test"]},
          "language": {"type": "string"},
          "reason": {"type": "string"},
          "count": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
        }
      },
      "minItems": 0
    },
    "minimumSupport": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "groupsPerTarget",
        "groupsPerNegativeLanguage",
        "acceptedTotal",
        "acceptedTrueCs",
        "acceptedTrueSk"
      ],
      "properties": {
        "groupsPerTarget": {"const": 200},
        "groupsPerNegativeLanguage": {"const": 200},
        "acceptedTotal": {"const": 1000},
        "acceptedTrueCs": {"const": 100},
        "acceptedTrueSk": {"const": 100}
      }
    },
    "calibration": {
      "type": "object",
      "additionalProperties": false,
      "required": ["algorithm", "candidates", "tieBreak", "disabledBuckets"],
      "properties": {
        "algorithm": {"const": "grid-max-accepted-v1"},
        "candidates": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["bucketStart", "minWinningScores", "minMargins", "minKnownCoverageBp"],
            "properties": {
              "bucketStart": {"enum": [12, 32, 80, 200]},
              "minWinningScores": {
                "type": "array",
                "items": {"type": "integer", "minimum": -7000000, "maximum": 0},
                "minItems": 1
              },
              "minMargins": {
                "type": "array",
                "items": {"type": "integer", "minimum": 1, "maximum": 7000000},
                "minItems": 1
              },
              "minKnownCoverageBp": {
                "type": "array",
                "items": {"type": "integer", "minimum": 0, "maximum": 10000},
                "minItems": 1
              }
            }
          },
          "minItems": 4,
          "maxItems": 4
        },
        "tieBreak": {"const": ["minWinningScoreDescending", "minMarginDescending", "minKnownCoverageBpDescending"]},
        "disabledBuckets": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["bucketStart", "reason"],
            "properties": {"bucketStart": {"enum": [12, 32, 80, 200]}, "reason": {"type": "string"}}
          },
          "minItems": 0
        }
      }
    },
    "support": {"type": "array", "items": {"$ref": "#/$defs/support"}, "minItems": 1},
    "metrics": {"type": "array", "items": {"$ref": "#/$defs/metric"}, "minItems": 1},
    "documentMetrics": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["sourceId", "goldLabel", "predictedLabel", "count"],
        "properties": {
          "sourceId": {"type": "string"},
          "goldLabel": {"enum": ["cs", "de", "en", "sk", "mixed", "und"]},
          "predictedLabel": {"enum": ["cs", "de", "en", "sk", "mixed", "und"]},
          "count": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
        }
      },
      "minItems": 0
    },
    "attribution": {
      "type": "object",
      "additionalProperties": false,
      "required": ["sourceIds", "licenseIds", "attributionPath", "attributionSha256", "noticePath", "noticeSha256"],
      "properties": {
        "sourceIds": {"type": "array", "items": {"type": "string", "pattern": "^[A-Za-z0-9_-]+$"}, "minItems": 0},
        "licenseIds": {"type": "array", "items": {"type": "string"}, "minItems": 0},
        "attributionPath": {"type": "string"},
        "attributionSha256": {"type": "string", "pattern": "^([0-9a-f]{64})?$"},
        "noticePath": {"type": "string"},
        "noticeSha256": {"type": "string", "pattern": "^([0-9a-f]{64})?$"}
      }
    }
  },
  "$defs": {
    "file": {
      "type": "object",
      "additionalProperties": false,
      "required": ["role", "url", "snapshotDate", "sha256", "formatVersion", "records"],
      "properties": {
        "role": {
          "enum": ["sentences", "links", "attribution", "ownedExamples", "unicodeData", "normalizationTest"]
        },
        "url": {"type": "string", "pattern": "^https://"},
        "snapshotDate": {"type": "string", "pattern": "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"},
        "sha256": {"type": "string", "pattern": "^[0-9a-f]{64}$"},
        "formatVersion": {"type": "string"},
        "records": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
      }
    },
    "corpus": {
      "type": "object",
      "additionalProperties": false,
      "required": [
        "id",
        "files",
        "licenseIds",
        "licenseSelectionPolicy",
        "languageSelectionPolicy",
        "deduplicationPolicy",
        "translationGroupPolicy",
        "originalRecords",
        "languageMappings"
      ],
      "properties": {
        "id": {"type": "string", "pattern": "^[A-Za-z0-9_-]+$"},
        "files": {"type": "array", "items": {"$ref": "#/$defs/file"}, "minItems": 1},
        "licenseIds": {"type": "array", "items": {"type": "string"}, "minItems": 1},
        "licenseSelectionPolicy": {"type": "string"},
        "languageSelectionPolicy": {"type": "string"},
        "deduplicationPolicy": {"type": "string"},
        "translationGroupPolicy": {"type": "string"},
        "originalRecords": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "languageMappings": {
          "type": "array",
          "minItems": 1,
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["sourceLanguage", "detectorLanguage"],
            "properties": {
              "sourceLanguage": {"type": "string", "minLength": 1},
              "detectorLanguage": {"type": "string", "pattern": "^[a-z]{2,3}$"}
            }
          }
        }
      }
    },
    "augmentation": {
      "type": "object",
      "additionalProperties": false,
      "required": ["algorithm", "splits", "lengths", "inputCount", "outputCount"],
      "properties": {
        "algorithm": {"enum": ["none-v1", "scalar-prefix-v1", "strip-marks-v1", "concat-v1"]},
        "splits": {
          "type": "array",
          "items": {"enum": ["train", "validation", "test"]},
          "minItems": 1,
          "maxItems": 3
        },
        "lengths": {"type": "array", "items": {"type": "integer", "minimum": 1, "maximum": 5000000}, "minItems": 0},
        "inputCount": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "outputCount": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
      }
    },
    "support": {
      "type": "object",
      "additionalProperties": false,
      "required": ["split", "bucketStart", "language", "originalGroups", "evaluated", "accepted"],
      "properties": {
        "split": {"enum": ["validation", "test"]},
        "bucketStart": {"enum": [12, 32, 80, 200]},
        "language": {"type": "string"},
        "originalGroups": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "evaluated": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "accepted": {"type": "integer", "minimum": 0, "maximum": 9007199254740991}
      }
    },
    "metric": {
      "type": "object",
      "additionalProperties": false,
      "required": ["split", "bucketStart", "language", "name", "numerator", "denominator", "rateBp"],
      "properties": {
        "split": {"enum": ["validation", "test"]},
        "bucketStart": {"enum": [0, 12, 32, 80, 200]},
        "language": {"type": "string"},
        "name": {"enum": ["acceptedError", "csSkConfusion", "foreignAcceptance", "acceptanceCoverage"]},
        "numerator": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "denominator": {"type": "integer", "minimum": 0, "maximum": 9007199254740991},
        "rateBp": {"anyOf": [{"type": "integer", "minimum": 0, "maximum": 10000}, {"type": "null"}]}
      }
    }
  }
}
```

## Addendum A (2026-10-11): label-only runtime path for ingestion

No behaviour change. Ingestion needs only the decision of §4 per chunk and the
aggregate of §5 per document, so both runtimes add a label-only path next to the
diagnostic scorer: `LanguageScorer.fast` / `LanguageScorer.Fast`
(`LanguageFastScorer`), reached through `LanguageDetector.decideText` /
`DecideText` and `decideDocument` / `DecideDocument`. It evaluates the §4
formulas on n-gram **occurrences** while classifying the normalized stream —
`sum_f(h[n,f] * w[p,n,f])` equals the sum of `w[p,n,·]` over every occurrence,
unknown occurrences contribute `unknownWeight` each — so no word strings,
feature dictionaries, sorted feature lists or per-profile diagnostic records are
built. Model tables are flattened once per loaded model: one open-addressing
table per order keyed by the packed tuple (symbols `+2` in 21 bits each) and
feature-major weight rows. The document path decides the same §5 windows in
place and aggregates them exactly as §5.

Its label, reason, letter/word counts, winner, runner-up, margin, coverage and
every combined score MUST equal the diagnostic scorer's; the diagnostic API and
every fixture stay authoritative. `LanguageFastScorerTests` (Swift and C#) assert
this for every `lang-score`, `lang-runtime` score and `lang-release` input on the
synthetic and production models, and on a deterministic synthetic cs/sk/en/de/
mixed corpus with combining marks, case-fold expansions, Hangul, supplementary
letters, emoji and controls (300 texts by default; checked with 20 000 in release
builds via `AINOTEBOOK_LANG_FAST_CASES`).

Normalization (§2.2) is unchanged; both `UnicodeTables` implementations now read
combining classes and "has decomposition / fold / composes as second" flags for
BMP scalars from flat tables built at load (the dictionaries stay authoritative
for every lookup that can hit), pinned by `NormalizationTest-15.1.0.txt` and the
`lang-normalize` fixtures.

Measured (Apple Silicon, release builds, loaded machine; `AINOTEBOOK_CPU_BENCH=1`):

| | Swift before | Swift after | .NET before | .NET after |
|---|---|---|---|---|
| 2 000 chunks of ~1 800 scalars: normalize | 1.05 s | 0.14 s | 0.58 s | 0.15 s |
| … text decision (full scorer → fast path) | 2.55 s | 0.08 s | 0.63 s | 0.11 s |
| … document decision (full → fast) | 3.28 s | 0.09 s | 1.00 s | 0.11 s |
| 400-file corpus, one core: detect + chunk | 38.4 s | 5.3 s | 11.8 s | 5.1 s |
| 400-file corpus, one worker: extraction wall | 55.1 s | 22.0 s | 19.8 s | 12.2 s |
