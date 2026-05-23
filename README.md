# AI Notebook

Native macOS desktop app for AI-assisted research, restricted to a local
[Ollama](https://ollama.com) provider. Inspired by
[open-notebook](https://github.com/lfnovo/open-notebook).

## Status

v0.1.0 — early scaffold. See `docs/superpowers/specs/` for the design spec
and `docs/superpowers/plans/` for milestone plans.

## Requirements

- macOS 14 or later
- Xcode 16 or Swift 6.0 toolchain
- [Ollama](https://ollama.com/download) (detected and pulled by the app
  during onboarding — no manual setup required for end users)

## Build

```bash
swift build
swift run AINotebookApp
```

## Test

```bash
swift test
```

## License

TBD (to be added before v1 release).
