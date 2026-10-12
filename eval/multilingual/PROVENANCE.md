# Original multilingual evaluation source

Created: 2026-10-09. Source ID: `multilingual-v1`.

These 44 documents and 144 questions were written for AI Notebook with
Codex-assisted original authorship. All organizations, named people, projects,
amounts and operational arrangements are fictional. No external sources,
web material, customer documents or copied contract wording were used.
The text is distributed under this repository's MIT license. It is not
Tatoeba material and is not designated CC0.

`manifest.json` records each source's stable document ID, numeric source ID,
authored language label, raw-file SHA-256 and decoded-text SHA-256. Language
labels describe the authored content; they are not detector predictions.
`queries.json` records stable question IDs and exact occurrence gold bound to
the decoded-text hash. The files themselves are the original source record.

Keep this named source entirely held out from detector training, feature
selection, calibration, threshold tuning and model selection. The same
exclusion applies to the questions and any excerpts or derived examples.
For translation-group accounting, each document ID is an independent authored
group. Parallel document roles contain different facts and independently
written prose, not translated copies. Each mixed document's two sections form
one group. Its questions and all derived excerpts inherit that group; never
split them into independent training or validation examples.

Czech and Slovak drafts were checked for natural phrasing and diacritics;
English and German drafts and every question/gold pair were reviewed during
authoring. Automated checks establish encoding, lengths, scope, occurrences
and hashes, not semantic correctness. Claude's final review of provenance and
all-language question quality remains part of the implementation handoff.
