# Retrieval eval fixture (FR-D2 / W-4)

Fixture corpus and query set for the local retrieval eval. Results and the
resulting FR-D3 decision live in [`../docs/eval/README.md`](../docs/eval/README.md).

```bash
swift run ainotebook-eval                       # offline lexical embedder
swift run ainotebook-eval --embedder nl         # offline semantic (Apple NaturalLanguage)
swift run ainotebook-eval --embedder ollama     # the real pipeline; needs a local Ollama
```

Never run in CI — the `ollama` mode needs a model server, and this is a
deliberate local measurement rather than a per-commit gate.

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
