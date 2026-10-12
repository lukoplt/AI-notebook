# Retrieval eval fixture (FR-D2 / W-4)

Fixture corpus and query set for the local retrieval eval. Results and the
resulting FR-D3 decision live in [`../docs/eval/README.md`](../docs/eval/README.md).

```bash
swift run ainotebook-eval                       # offline lexical embedder
swift run ainotebook-eval --embedder nl         # offline semantic (Apple NaturalLanguage)
swift run ainotebook-eval --embedder ollama     # the real pipeline; needs a local Ollama
```

The original English path above keeps its hashing embedder and existing gold
policy. The [multilingual assets](multilingual/README.md) use exact scalar
occurrences and separate lexical, hybrid and candidate recall. WP1 Tasks 6/7
add the following commands (the shared asset stage alone does not add runners):

```bash
swift run ainotebook-eval --dataset multilingual --root eval/multilingual --validate-only
swift run ainotebook-eval --dataset multilingual --mode lexical --json /tmp/wp1-swift.json --out /tmp/wp1-swift.md
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --root eval/multilingual --validate-only
dotnet run --project windows/tools/AINotebook.Eval -- --dataset multilingual --mode lexical --json /tmp/wp1-windows.json --out /tmp/wp1-windows.md
```

Deterministic Core tests and shared fixture checks run in CI on both platforms.
Live Ollama runs and hardware measurements are opt-in; they require a running
local server and an already installed model. Multilingual `--mode lexical`
makes no embedding calls. An explicit live run uses `--mode ollama --model NAME`.
On Windows, use output paths under `$env:TEMP` instead of `/tmp`.

## Layout

- `corpus/*.md` — 12 documents, ~7 kB each, one topic per document. Ingested with
  the production `Chunker` at its default window, giving 48 chunks.
- `queries.json` — 30 queries. `cut` is the production topK; `pool` is the wider
  candidate window used to measure reranker headroom.

## How gold chunks are specified

A query names its gold chunk by quoting a phrase that appears verbatim inside
it, not by chunk index:

```json
{
  "text": "Why does espresso need a longer rest after roasting than brewed coffee?",
  "gold": [{ "doc": "coffee-roasting", "phrase": "espresso wants ten to twenty-one days" }]
}
```

The runner resolves each phrase to a chunk id after ingestion, so the fixture
survives re-chunking and re-wrapping of the corpus. Matching is
whitespace-insensitive.

**A phrase must resolve to exactly one chunk.** Zero matches or several is a
fixture error and the runner exits non-zero rather than scoring against the
wrong target. Several matches usually means the phrase landed in the chunker's
256-character overlap and appears in two adjacent chunks; pick a phrase further
from the boundary. Four of the original thirty needed exactly that fix.

## Writing new queries

- **Paraphrase.** The query should not reuse the gold phrase's wording, or the
  eval degenerates into a string search.
- **Target one passage, not one document.** Every document here has a single
  coherent topic, so finding the right document is easy; finding the right
  passage inside it is the task being measured. The distractors that matter are
  the sibling chunks of the same document.
- **Ask it the way a user would** — a real question, not a keyword bag.
