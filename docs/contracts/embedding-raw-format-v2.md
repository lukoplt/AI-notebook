# Raw embedding input format 2 — normative contract

*Status: 2026-10-11. Extends the raw formats of WP5/WP6 (`legacy`, `1`: text embedded verbatim), which stay supported unchanged; WP7 named profiles (`wp7:…`) are unaffected. Fixture: `Tests/fixtures/contracts/embedding-raw-format-v2.json`. Executable reference: `tools/contracts/gen_embedding_raw_format_fixtures.py` (`--check`). Swift `RawEmbeddingFormat` / C# `RawEmbeddingFormat`; tests `RawEmbeddingFormatTests` and `FolderEmbeddingSessionTests` on both platforms.*

## 1. Why

A raw provider selection (e.g. Ollama `nomic-embed-text`) embedded questions and chunks verbatim. nomic-embed-text is trained with task prefixes (`search_query: ` / `search_document: `) and its retrieval quality drops markedly without them; multilingual E5 models need `query: ` / `passage: ` likewise. Chunks of spreadsheets and offers also carry no hint of the file they come from, while the folder path (`Client/Year/Project/Offers/…`) is often the most informative text a chunk has.

## 2. Identity

Format `2` is a raw format: `EmbeddingQueryFormat` accepts `legacy`, `1`, `2`. A raw capture requires `queryFormatVersion == docFormatVersion`. New selections (`FolderEmbeddingSession.resolve` defaults) use `RawEmbeddingFormat.current = "2"`. A generation's stored formats decide how **its** queries are embedded (the router passes `identity.queryFormatVersion` to the session), so a format-1 generation keeps answering with verbatim queries.

## 3. Inputs

Model family: the model name with surrounding ASCII whitespace trimmed, ASCII-lowercased, the part after the last `/` and before the first `:`.

| family | query prefix | document prefix |
|---|---|---|
| starts with `nomic-embed-text` | `search_query: ` | `search_document: ` |
| `-`/`_`-separated part equal to `e5`, name without `instruct` | `query: ` | `passage: ` |
| anything else | none | none |

Query input (format 2) = query prefix + question. Document input = document prefix + header + chunk text, where header = the source's `rel_path` (or its title for a loose source) with every run of ASCII whitespace (space, TAB, LF, VT, FF, CR) replaced by one space, ends trimmed, cut to its first 200 Unicode scalars, followed by `"\n"` (empty header for an empty line). The indexer adds the header (it knows the source), the session adds the prefix.

Dedup interplay (`embedding-plan-v1` §5, unchanged): chunks with identical text still share one provider call and copy the first occurrence's vector, so a copied template sheet carries the first copy's path line. Exact path matching is the job of `retrieval-paths-v1`, not of the vectors.

## 4. Formats 1 and legacy

Unchanged: inputs are the chunk text and the question, verbatim.

## 5. Automatic upgrade

When the selected raw space equals the active generation's (provider, endpoint revision, model) but the active generation is at format `1` and the selection at `2`, and the notebook has no unfinished embed job, the runtime's index-build check requests one build of the selected format-2 space beside the active generation (nothing can be copied: the spaces differ). Partial-index rules keep the building generation invisible while the format-1 generation is active, so retrieval continues unchanged until the new generation activates; afterwards the check is false. Measured re-embed cost for the reference folder is that of a full build under the embedding plan's per-sheet cap.
