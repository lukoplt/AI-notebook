# Multilingual retrieval assets v1

This original held-out corpus contains 44 documents: ten each in Czech,
Slovak, English and German, plus four mixed documents. Its 144 questions
comprise three per document and four each for absent answers, empty selection
and Overview. See [PROVENANCE.md](PROVENANCE.md) for authorship, MIT licensing
and detector-training exclusions.

The manifest is `eval-corpus` v1; questions are `eval-queries` v1. Both use
`corpus_id: multilingual-v1`. Stable corpus/document/query IDs match
`[a-z0-9][a-z0-9-]*`. Numeric IDs are positive decimal JSON integers no larger
than 2^53−1. They identify fixture entities and must be translated to allocated
database IDs at ingestion. Sources 101–410 belong to notebook 1; mixed source
504 belongs to notebook 2. Source 503 is a loose source with no folder.

`path` is relative to this directory. `rel_path` is relative to a fixture
folder, so customer and supplier folders intentionally contain equal relative
paths. Folder membership comes from the manifest. Selection is the union of
source and folder IDs intersected with the question's notebook; an empty
selection selects nothing. The all-scope wire object is `{"kind":"all"}`;
selection retains WP0's `sourceIds` and `folderIds` spelling.

Decode the declared `utf-8` or `windows-1250` strictly. The Czech legacy
terminal is actual cp1250 bytes. Preserve the decoded text exactly: no BOM
removal, whitespace folding, newline conversion or Unicode normalization.
Corpus documents contain no BOM and use LF with a final LF. `raw_sha256`
hashes file bytes; `content_hash` hashes UTF-8 of the exact decoded text.

Gold identifies a document, its canonical hash, an exact phrase and a
one-based occurrence among all matching scalar starts, including overlaps.
Resolve to half-open Unicode scalar spans. Several chunks may cover the same
gold occurrence; that occurrence earns credit once. Czech invoice cs-03
deliberately repeats its evidence sentence and labels occurrence 2. English
runbook en-08 retains a supplementary symbol and decomposed accent before
evidence. Eight long technical/contract documents exceed 4096 scalars and
place evidence inside a 256-scalar chunk overlap. They use substantial prose,
not repeated padding.

Six case types are supported: `answer`, `exact_identifier`, `scope`, `absent`,
`empty_selection`, `overview`. Tags are orthogonal: `mixed`, `cross_language`,
`cp1250`, `repeated_phrase`, `overlap`. Sixteen monolingual-source paraphrases
ask in another language (four questions in each target language); mixed-source
questions also use only cs/sk/en/de. Scope controls include source-only,
folder-only, source-plus-folder union, loose sources and notebook isolation.

Overview labels cover ten documents in the two selected language folders,
using one first-window gold per document. Their order follows folder-aware
directory round-robin: null folder first, then numeric folder, scalar directory
and relative path order, source ID last. This is a coverage target; WP8 owns
the actual budgeted selection and packing. Absence questions have no positive
gold and are excluded from recall denominators.

Authoring checks (offline, Python standard library):

```bash
python3 -m unittest discover -s tools/eval -p 'test_eval_assets.py' -v
python3 tools/eval/update_eval_hashes.py --check
```

An intentional text edit requires semantic review and the explicit
`python3 tools/eval/update_eval_hashes.py --write` action. Default and `--check`
never rewrite assets. Canonical JSON uses sorted keys, literal Unicode, two
space indentation and a final LF. Stable IDs survive text edits; hashes do not.

WP1 Tasks 2–7 consume these assets through both Core suites and add the runner
commands documented in [the parent README](../README.md). Their temporary
baseline is `eval-scalars-v1` with `legacy-fts-eval-rrf-v1`; this asset stage
does not claim production ingestion, detector, packing, citation or performance
gates have passed. Live model runs remain opt-in.
