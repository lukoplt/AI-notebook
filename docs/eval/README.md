# W-4 retrieval eval (FR-D2) — results and the W-5 reranker decision

*Run 2026-08-24 against `main` at v0.13.0. Fixture: `eval/corpus` (12 documents,
48 chunks) + `eval/queries.json` (30 queries). Runner: `swift run ainotebook-eval`.*

**Decision: NO-GO on W-5 (FR-D3 cross-encoder reranker) for now.** The recall a
reranker would buy is obtainable by widening the retrieval cut, which costs
prompt tokens instead of two shipped ML runtimes. Reasoning below.

---

## How to reproduce

```bash
swift run ainotebook-eval --embedder nl --out docs/eval/retrieval-recall-nl.md
```

`--embedder` selects how chunks are vectorised:

| mode | what it is | why it exists |
|---|---|---|
| `lexical` (default) | hashed word + character 4-grams, offline | deterministic floor; no semantics at all |
| `nl` | Apple `NaturalLanguage` sentence embeddings, offline | genuinely semantic, ships with macOS, nothing to install |
| `ollama` | the real production embedder | the authoritative run — needs a local Ollama and a pulled model |

The eval never runs in CI: the `ollama` mode needs a model server, and the point
of the harness is a deliberate local measurement, not a per-commit gate.

## What was measured, and why not just recall@8

A reranker does not retrieve anything. It reorders a candidate window that
retrieval already produced, so it can never promote a chunk that was never
fetched. Plain recall@8 therefore cannot answer whether one would help. The
harness reports three numbers instead:

1. **recall@8, fetch 8** — the production pipeline as it ships today.
2. **recall@8, fetch 24** — a wider candidate window, same cut. Isolates what
   RRF re-ordering alone buys, for free.
3. **recall@24, fetch 24** — the candidate-pool ceiling: what a *perfect*
   reranker over that window could achieve at any cut.

`RetrievalEval.run` gained a `fetchK` parameter for this; production behaviour is
unchanged, because `fetchK` defaults to `k`.

## Results

| | lexical | NaturalLanguage |
|---|---|---|
| recall@8 (fetch 8) — production | **0.633** | **0.633** |
| recall@8 (fetch 24) | 0.633 | 0.633 |
| recall@24 (fetch 24) — ceiling | 0.800 | 0.933 |
| wide-fetch gain | 0.000 | 0.000 |
| reranker headroom | 0.167 | 0.300 |
| gold never retrieved | 6/30 | 2/30 |
| gold retrieved but below the cut | 5/30 | 9/30 |

Cut sweep, fetch 24 — what returning more chunks buys with no reranker at all:

| cut | lexical | NaturalLanguage |
|---|---|---|
| 4 | 0.500 | 0.433 |
| 8 | 0.633 | 0.633 |
| 12 | 0.700 | 0.800 |
| 16 | 0.700 | 0.867 |
| 20 | 0.800 | 0.900 |
| 24 | 0.800 | 0.933 |

Control run with the candidate window opened to the entire 48-chunk corpus:

```
recall@8  (fetch 48) = 0.633
recall@48 (fetch 48) = 1.000     gold below cut: 11/30, never retrieved: 0/30
```

## What the numbers say

**Retrieval is not the bottleneck. Ranking is.** With the window opened to the
whole corpus, recall reaches 1.000 — every gold chunk is reachable by the
existing hybrid cosine + BM25 union. Yet recall@8 stays at 0.633. Eleven of the
thirty gold chunks are found and then ranked below the cut, at positions 9
through 27.

**Widening the fetch window on its own changes nothing.** The wide-fetch gain is
0.000 under both embedders, and stays 0.000 even when the window is the entire
corpus. This is not a measurement artefact — the ceiling moves (0.800 → 0.933 →
1.000) and per-query ranks extend as the window grows, so the parameter is
plainly reaching the retriever. RRF simply does not reorder its top 8 when you
hand it more low-ranked candidates.

**Better embeddings did not move recall@8 at all.** Both embedders score exactly
0.633, on *different* query sets — the semantic model rescues four queries the
lexical one loses entirely, and loses four others to rank inflation. Improving
the vector branch moves chunks from "not found" to "found but ranked 9–21"; it
does not move them into the top 8.

**So a reranker does have a real job in principle** — 0.30 to 0.37 of recall sits
in pure reordering, exactly the layer a cross-encoder operates on.

## Why the decision is still no-go

The reranker's value is not extra recall. It is *the recall of a wide cut at the
context cost of a narrow one*. Set against that:

1. **Widening the cut gets most of it for free.** recall@16 = 0.867 versus
   recall@8 = 0.633, with no new component, no ONNX runtime on Windows, no
   CoreML model on macOS, and no second inference pass per query. The reranker
   only earns its cost once prompt context is the binding constraint, and
   nothing measured here shows that it is.
2. **The production seam does not exist yet.** `Retriever.search(topK:)` uses one
   number for both the fetch window and the returned cut; the split lives only
   in the eval harness. A reranker needs fetch ≫ cut, so W-5 is not a drop-in —
   it needs that refactor first, and once the refactor exists, the free option is
   a config change.
3. **The measurement does not yet cover the production embedder.** Both runs used
   stand-ins. They agree on the *structure* of the problem, which is what the
   decision turns on, but not on magnitude. Committing to shipping two ML
   runtimes on that basis would be premature.

**Recommended instead of W-5, in order:** split `fetchK` from `topK` in the
production `Retriever`; raise the returned cut (16 is the knee of the NL curve)
and re-measure; run this eval with `--embedder ollama` to confirm on the real
pipeline. Revisit the cross-encoder only if context budget then proves binding.

## Caveats worth keeping in view

- **The corpus is small** (48 chunks). Absolute recall would fall on a real
  notebook of thousands of chunks, so treat these as relative measurements.
- **The ceiling is generous by construction** — a 24-candidate window over 48
  chunks is half the corpus. Headroom is therefore an upper bound, which is the
  right direction for a no-go: even the optimistic bound does not justify the
  cost.
- **Queries are deliberately paraphrased** and target a specific passage within a
  topically coherent document, so the competition is sibling chunks of the same
  document rather than other documents. That is the realistic hard case for a
  notebook app, and it is why recall@8 is 0.633 rather than near 1.

Generated reports: [`retrieval-recall-lexical.md`](retrieval-recall-lexical.md),
[`retrieval-recall-nl.md`](retrieval-recall-nl.md).
