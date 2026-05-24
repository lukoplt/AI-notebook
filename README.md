# AI Notebook

Native macOS desktop research notebook with a local-only AI provider
(Ollama). A privacy-first take on Google NotebookLM and the open-source
[open-notebook](https://github.com/lfnovo/open-notebook) project.

## What you get

- **Notebooks** — organise research by project.
- **Sources** — drop in PDFs, text, Markdown, web URLs, Word / PowerPoint /
  Excel. Everything is chunked and embedded locally.
- **Chat with citations** — ask questions across your sources. Answers
  stream in with clickable `[N]` chips that pop the cited snippet.
- **Notes** — write Markdown manually or save AI output as a note.
- **Transformations** — built-in templates (Summary, Key points, Entities)
  that run any prompt over a source and store the result as a note.
- **English + Czech** — auto-detected from system locale, switchable in
  Settings.

Everything runs on your machine. No cloud calls — except the user-initiated
URL fetches for web sources and the optional update check.

## Requirements

- macOS 14 (Sonoma) or later
- [Ollama](https://ollama.com/download) installed (the app will guide you
  through this on first launch)
- ~5 GB free disk for the default models (`llama3.2:3b` +
  `nomic-embed-text`)

## Install

Download the latest `AINotebook-vX.Y.Z-macos.dmg` from
[Releases](https://github.com/lukoplt/ai-notebook/releases). Open the DMG,
drag **AI Notebook** to Applications, launch.

The first run walks you through Ollama detection and model download.

## Build from source

```bash
git clone https://github.com/lukoplt/ai-notebook
cd ai-notebook
swift run AINotebookApp
```

Requires Xcode 16+ (Swift 6).

## Architecture (brief)

- `AINotebookCore` — Swift Package library: storage (GRDB + SQLite), Ollama
  client, ingestion, embedder, retriever, chat engine, transformations.
- `AINotebookApp` — SwiftUI executable.
- Single SQLite file at `~/Library/Application Support/AINotebook/db.sqlite`.

See `docs/superpowers/specs/2026-05-24-ai-notebook-design.md` for the full
design spec.

## License

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE).
