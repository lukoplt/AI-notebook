# M7: Polish + Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v0.1.0 — package the Swift Package executable into a proper `.app` bundle, produce a DMG, clean up dead milestone-placeholder localization keys, harden error surfaces, add user-facing README + LICENSE + NOTICE, and wire a GitHub Actions release workflow.

**Architecture:** A `tools/macos/build-app.sh` script invokes `swift build -c release`, then assembles `dist/AINotebook.app/{Contents/{MacOS,Resources,Info.plist}}`. A second `tools/macos/build-dmg.sh` wraps the .app into a notarized-or-ad-hoc-signed DMG via `hdiutil`. A `.github/workflows/macos-release.yml` runs both on tag push. We mirror the AIGuard / AIExposureScanner pattern (SHA-pinned third-party actions, ad-hoc signing fallback if no Developer ID cert is available).

**Tech Stack:** bash + macOS toolchain (`swift`, `hdiutil`, `codesign`, optional `xcrun notarytool`), GitHub Actions.

---

## File Structure

**Create:**
- `tools/macos/build-app.sh` — SPM executable → `.app` bundle
- `tools/macos/build-dmg.sh` — `.app` → signed/unsigned DMG
- `tools/macos/Info.plist.template` — bundle metadata template
- `tools/macos/AppIcon.iconset/` — placeholder icon set (1024×1024 source PNG)
- `tools/macos/make-iconset.sh` — generate `.icns` from source PNG
- `.github/workflows/macos-release.yml` — release pipeline on `v*` tag
- `README.md` (user-facing — replaces stub if any)
- `LICENSE` (MIT)
- `NOTICE` (attribution — mirrors AIGuard pattern)
- `CHANGELOG.md`
- `VERSION` (single line: `0.1.0`)

**Modify:**
- `Sources/AINotebookCore/Localization.swift` — remove dead M-milestone keys
- `Sources/AINotebookCore/AINotebookVersion.swift` — bump to `0.1.0`
- `Sources/AINotebookApp/AINotebookApp.swift` — remove stale `comingSoon`/`*TabComingSoon` references if any remain

---

## Task 1: Branch off main

```bash
git checkout main
git checkout -b m7-polish-release
swift test --parallel 2>&1 | tail -5
```

Expected: 147/147 pass.

---

## Task 2: Clean up dead milestone-placeholder localization keys

`Sources/AINotebookCore/Localization.swift` still carries `comingSoon`, `sourcesTabComingSoon`, `chatTabComingSoon`, `notesTabComingSoon`, `transformationsTabComingSoon` from M0. All four tabs now ship real content, so these are dead.

**Files:** Modify `Sources/AINotebookCore/Localization.swift`, modify any references (most likely `Sources/AINotebookApp/NotebookDetailView.swift`).

- [ ] **Step 1: Confirm no references**

```bash
grep -rn "comingSoon\|sourcesTabComingSoon\|chatTabComingSoon\|notesTabComingSoon\|transformationsTabComingSoon" Sources/
```

If a reference appears in `NotebookDetailView.swift`, remove it (the dead `placeholder` / `comingSoonMessage` helpers may already be gone from M6; double-check).

- [ ] **Step 2: Remove enum cases + EN + CS dict arms**

In `Sources/AINotebookCore/Localization.swift`, remove the five keys from:
- the `case` declarations inside `AppText.Key`
- the English `switch self` arm
- the Czech `switch self` arm

- [ ] **Step 3: Build + test**

```bash
swift build 2>&1 | tail -10
swift test --parallel 2>&1 | tail -5
```

Expected: build clean (no `value of type 'AppText.Key' has no member` errors); test count unchanged (the keys had no dedicated tests, only the `allCases` sweep).

- [ ] **Step 4: Commit**

```bash
git add Sources/AINotebookCore/Localization.swift Sources/AINotebookApp/NotebookDetailView.swift
git commit -m "chore(core): remove dead milestone-placeholder localization keys"
```

---

## Task 3: Bump version to 0.1.0 + add `VERSION` + `CHANGELOG.md`

**Files:** Modify `Sources/AINotebookCore/AINotebookVersion.swift`, create `VERSION`, create `CHANGELOG.md`.

- [ ] **Step 1: Read existing version constant**

```bash
cat Sources/AINotebookCore/AINotebookVersion.swift
```

- [ ] **Step 2: Bump to `0.1.0`**

Whatever the current literal is, change to `"0.1.0"`. Keep the existing const name and visibility.

- [ ] **Step 3: Write top-level `VERSION` file**

```bash
echo "0.1.0" > VERSION
```

- [ ] **Step 4: Write `CHANGELOG.md`**

```markdown
# Changelog

## [0.1.0] — 2026-05-24

First public release. Native macOS desktop app cloning the open-notebook
research workflow, with Ollama (local) as the only AI provider.

### Features
- Multi-notebook organisation
- Source ingestion: PDF, plain text, Markdown, web URL, Office (docx / pptx / xlsx)
- Background chunking + embedding via Ollama `nomic-embed-text`
- Hybrid retrieval (vector cosine + FTS5 BM25 → Reciprocal Rank Fusion)
- RAG chat with streaming tokens and clickable inline `[N]` citations
- Markdown notes editor (manual + AI-generated from chat / transformations)
- Built-in transformation templates: Summary, Key points, Entities
- First-launch onboarding wizard: detect Ollama, guide install, auto-pull
  preset models (`llama3.2:3b`, `nomic-embed-text`)
- Bilingual UI (English + Czech) with system-locale auto-detect

### Architecture
- Swift Package — `AINotebookCore` library + `AINotebookApp` executable
- Single SQLite file at `~/Library/Application Support/AINotebook/db.sqlite`
- 147 unit tests covering migrations, storage, ingestion, embedding,
  retrieval, chat engine, and transformations

### Known limitations
- Single chat session per notebook (multi-session UI deferred)
- Transformation engine doesn't stream tokens (collects then renders)
- No audio / video ingestion (whisper integration deferred)
- No podcast generation (deferred)
- macOS only; Windows WPF port planned post-v1
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/AINotebookVersion.swift VERSION CHANGELOG.md
git commit -m "chore: bump version to 0.1.0 + CHANGELOG"
```

---

## Task 4: `LICENSE` + `NOTICE` + user-facing `README.md`

**Files:** Create `LICENSE`, `NOTICE`, `README.md` (or overwrite stub).

- [ ] **Step 1: Write `LICENSE` (MIT)**

```
MIT License

Copyright (c) 2026 Lukáš Oplt

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write `NOTICE`**

```
AI Notebook
Copyright 2026 Lukáš Oplt

Inspired by open-notebook (https://github.com/lfnovo/open-notebook), MIT.

Dependencies:
- GRDB.swift — MIT — https://github.com/groue/GRDB.swift
- SwiftSoup — MIT — https://github.com/scinfu/SwiftSoup
- ZIPFoundation — MIT — https://github.com/weichsel/ZIPFoundation

Bundled at runtime via the user's local installation:
- Ollama (https://ollama.com) — MIT
```

- [ ] **Step 3: Write `README.md`**

```markdown
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
[Releases](https://github.com/USER/REPO/releases). Open the DMG, drag
**AI Notebook** to Applications, launch.

The first run walks you through Ollama detection and model download.

## Build from source

```bash
git clone https://github.com/USER/REPO
cd REPO
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
```

- [ ] **Step 4: Commit**

```bash
git add LICENSE NOTICE README.md
git commit -m "docs: LICENSE + NOTICE + user-facing README"
```

---

## Task 5: `Info.plist.template` + bundle metadata

**Files:** Create `tools/macos/Info.plist.template`.

- [ ] **Step 1: Create the template**

```bash
mkdir -p tools/macos
```

`tools/macos/Info.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>          <string>en</string>
  <key>CFBundleDisplayName</key>                <string>AI Notebook</string>
  <key>CFBundleExecutable</key>                 <string>AINotebookApp</string>
  <key>CFBundleIconFile</key>                   <string>AppIcon</string>
  <key>CFBundleIdentifier</key>                 <string>com.aino.AINotebook</string>
  <key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
  <key>CFBundleName</key>                       <string>AI Notebook</string>
  <key>CFBundlePackageType</key>                <string>APPL</string>
  <key>CFBundleShortVersionString</key>         <string>__VERSION__</string>
  <key>CFBundleVersion</key>                    <string>__VERSION__</string>
  <key>LSApplicationCategoryType</key>          <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>             <string>14.0</string>
  <key>NSHighResolutionCapable</key>            <true/>
  <key>NSHumanReadableCopyright</key>           <string>Copyright © 2026 Lukáš Oplt. MIT licence.</string>
  <key>NSPrincipalClass</key>                   <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>     <true/>
  <key>NSSupportsSuddenTermination</key>        <true/>
</dict>
</plist>
```

`__VERSION__` gets replaced by the build script with the contents of `VERSION`.

- [ ] **Step 2: Commit**

```bash
git add tools/macos/Info.plist.template
git commit -m "build: Info.plist template for the app bundle"
```

---

## Task 6: App icon (placeholder)

**Files:** Create `tools/macos/AppIcon.iconset/` source, `tools/macos/make-iconset.sh`.

- [ ] **Step 1: Generate a placeholder PNG**

Use ImageMagick if available (`brew install imagemagick`), otherwise generate via Swift:

```bash
mkdir -p tools/macos/AppIcon.iconset
cat > /tmp/make-icon.swift <<'SWIFT'
import AppKit
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let gradient = NSGradient(starting: NSColor(red: 0.27, green: 0.45, blue: 0.86, alpha: 1),
                          ending:   NSColor(red: 0.45, green: 0.27, blue: 0.86, alpha: 1))!
gradient.draw(in: NSBezierPath(roundedRect: NSRect(origin: .zero, size: size),
                                xRadius: 220, yRadius: 220),
              angle: 90)
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 640, weight: .black),
    .foregroundColor: NSColor.white
]
let txt = NSAttributedString(string: "AI", attributes: attrs)
let txtSize = txt.size()
txt.draw(at: NSPoint(x: (size.width - txtSize.width) / 2,
                     y: (size.height - txtSize.height) / 2 - 20))
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
SWIFT
swift /tmp/make-icon.swift tools/macos/AppIcon.iconset/icon_512x512@2x.png
```

- [ ] **Step 2: Generate the full iconset from the 1024×1024 source**

```bash
cat > tools/macos/make-iconset.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
SRC="tools/macos/AppIcon.iconset/icon_512x512@2x.png"
SET="tools/macos/AppIcon.iconset"
ICNS="tools/macos/AppIcon.icns"

for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
            "32:icon_32x32.png" "64:icon_32x32@2x.png" \
            "128:icon_128x128.png" "256:icon_128x128@2x.png" \
            "256:icon_256x256.png" "512:icon_256x256@2x.png" \
            "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    px="${spec%%:*}"; name="${spec#*:}"
    sips -z "$px" "$px" "$SRC" --out "$SET/$name" >/dev/null
done

iconutil -c icns "$SET" -o "$ICNS"
BASH
chmod +x tools/macos/make-iconset.sh
./tools/macos/make-iconset.sh
```

- [ ] **Step 3: Verify .icns generated**

```bash
file tools/macos/AppIcon.icns
```

Expected: `Mac OS X icon`.

- [ ] **Step 4: Commit**

```bash
git add tools/macos/AppIcon.iconset/ tools/macos/AppIcon.icns tools/macos/make-iconset.sh
git commit -m "build: placeholder AppIcon (1024 gradient + 'AI' text)"
```

---

## Task 7: `build-app.sh` — Swift Package executable → `.app` bundle

**Files:** Create `tools/macos/build-app.sh`.

- [ ] **Step 1: Write the script**

```bash
cat > tools/macos/build-app.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(cat VERSION)"
APP_NAME="AI Notebook"
EXEC_NAME="AINotebookApp"
BUNDLE_ID="com.aino.AINotebook"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Cleaning $DIST"
rm -rf "$DIST"
mkdir -p "$MACOS" "$RESOURCES"

echo "→ swift build -c release (universal)"
swift build -c release \
    --arch arm64 --arch x86_64 \
    --disable-sandbox

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXEC_NAME"
if [ ! -f "$BIN" ]; then
    echo "Build output not found at $BIN"
    exit 1
fi

echo "→ Copying executable into bundle"
cp "$BIN" "$MACOS/$EXEC_NAME"

echo "→ Copying icon"
cp tools/macos/AppIcon.icns "$RESOURCES/AppIcon.icns"

echo "→ Rendering Info.plist (version=$VERSION)"
sed "s/__VERSION__/$VERSION/g" tools/macos/Info.plist.template \
    > "$CONTENTS/Info.plist"

echo "→ Ad-hoc signing the bundle (no Developer ID required)"
# If CODESIGN_IDENTITY is set in the environment, use that instead.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"

echo "→ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "✓ Built: $APP"
BASH
chmod +x tools/macos/build-app.sh
```

- [ ] **Step 2: Run it locally**

```bash
./tools/macos/build-app.sh
```

Expected: produces `dist/AI Notebook.app` and prints `✓ Built`. The `swift build --arch arm64 --arch x86_64` flags produce a universal binary; if they fail (e.g. one of the deps is single-arch), drop the second `--arch` and document as a known limitation in the script comment.

- [ ] **Step 3: Smoke launch**

```bash
open "dist/AI Notebook.app"
```

Expected: the app window appears (same UI as `swift run AINotebookApp`).

- [ ] **Step 4: Commit**

```bash
git add tools/macos/build-app.sh
git commit -m "build: tools/macos/build-app.sh — SPM exec → .app bundle"
```

---

## Task 8: `build-dmg.sh` — `.app` → DMG

**Files:** Create `tools/macos/build-dmg.sh`.

- [ ] **Step 1: Write the script**

```bash
cat > tools/macos/build-dmg.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(cat VERSION)"
APP_NAME="AI Notebook"
APP_PATH="dist/$APP_NAME.app"
DMG_NAME="AINotebook-v$VERSION-macos.dmg"
DMG_PATH="dist/$DMG_NAME"
STAGING="dist/dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found at $APP_PATH — run build-app.sh first." >&2
    exit 1
fi

echo "→ Staging DMG layout"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating compressed DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "→ Ad-hoc signing the DMG"
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$DMG_PATH"

echo "✓ Built: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
BASH
chmod +x tools/macos/build-dmg.sh
```

- [ ] **Step 2: Run it**

```bash
./tools/macos/build-dmg.sh
```

Expected: `dist/AINotebook-v0.1.0-macos.dmg` exists; printed size is in the 5–30 MB range (depends on deps).

- [ ] **Step 3: Manually verify the DMG**

```bash
open dist/AINotebook-v0.1.0-macos.dmg
```

Expected: a Finder window mounts showing the .app and an `Applications` symlink. Quit the volume (`hdiutil detach /Volumes/AI\ Notebook`).

- [ ] **Step 4: Commit**

```bash
git add tools/macos/build-dmg.sh
git commit -m "build: tools/macos/build-dmg.sh — .app → notarisable DMG"
```

---

## Task 9: GitHub Actions release workflow

**File:** Create `.github/workflows/macos-release.yml`.

- [ ] **Step 1: Look up SHAs for SHA-pinning**

(The implementer can use `gh api repos/<owner>/<repo>/commits/<branch>` or just lift the SHAs from the existing AIGuard `macos-release.yml`. The action versions to pin: `actions/checkout@v4` (any recent SHA), `softprops/action-gh-release@v2` (any recent SHA). Use whatever SHAs the implementer can confirm from `git ls-remote https://github.com/<owner>/<repo>.git refs/tags/v4` or similar.)

Replace the `__SHA__` placeholders below with real commit SHAs before committing.

- [ ] **Step 2: Write the workflow**

```yaml
# .github/workflows/macos-release.yml
name: macOS Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build-dmg:
    runs-on: macos-14
    timeout-minutes: 30
    steps:
      - name: Checkout
        uses: actions/checkout@__SHA__  # actions/checkout@v4

      - name: Select Xcode 16
        run: sudo xcode-select -s /Applications/Xcode_16.0.app/Contents/Developer

      - name: Cache SwiftPM build
        uses: actions/cache@__SHA__  # actions/cache@v4
        with:
          path: .build
          key: spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}

      - name: Run tests
        run: swift test --parallel

      - name: Build .app + DMG
        run: |
          ./tools/macos/build-app.sh
          ./tools/macos/build-dmg.sh
          ls -lh dist/

      - name: Upload DMG to GitHub Release
        uses: softprops/action-gh-release@__SHA__  # softprops/action-gh-release@v2
        with:
          files: dist/AINotebook-v*-macos.dmg
          generate_release_notes: true
```

- [ ] **Step 3: Validate locally with `yamllint`**

```bash
yamllint .github/workflows/macos-release.yml || true
```

(Optional; will print warnings on missing SHAs — fine.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/macos-release.yml
git commit -m "ci: macos-release.yml — tagged DMG builds via GitHub Actions"
```

If real SHAs aren't available at this stage, document `__SHA__` placeholders in the commit message and treat them as a TODO for the first actual release.

---

## Task 10: Final verification + tag + cut release

- [ ] **Step 1: Re-run the full pipeline locally**

```bash
swift package clean
swift test --parallel
./tools/macos/build-app.sh
./tools/macos/build-dmg.sh
ls -lh dist/
```

Expected:
- 147/147 tests pass.
- `dist/AI Notebook.app` exists, launches.
- `dist/AINotebook-v0.1.0-macos.dmg` exists.

- [ ] **Step 2: Merge to main**

```bash
git checkout main
git merge --ff-only m7-polish-release
```

- [ ] **Step 3: Tag v0.1.0**

```bash
git tag -a v0.1.0 -m "v0.1.0 — first public release"
git log --oneline | head -10
```

- [ ] **Step 4: Push (if remote configured)**

```bash
git push origin main
git push origin v0.1.0
```

The push of the `v0.1.0` tag will fire `.github/workflows/macos-release.yml` (once SHAs are filled in).

---

## Acceptance criteria (M7 done when ALL true)

- `swift test --parallel` 147 tests pass, 0 failures.
- Dead `comingSoon` / `*TabComingSoon` keys removed.
- `VERSION` = `0.1.0`; `AINotebookVersion` constant matches.
- `LICENSE`, `NOTICE`, `README.md`, `CHANGELOG.md` exist at repo root.
- `tools/macos/build-app.sh` produces a launchable `dist/AI Notebook.app`.
- `tools/macos/build-dmg.sh` produces `dist/AINotebook-v0.1.0-macos.dmg` that mounts and shows the app + `Applications` symlink.
- `.github/workflows/macos-release.yml` exists with SHA-pinned actions (placeholders OK at first commit, replaced before first real release).
- Local git tag `v0.1.0` exists; `main` is fast-forwarded.

---

## Notes for the implementer

- **No Developer ID signing in v0.1.0:** Ad-hoc signing (`codesign --sign -`) is enough for the app to launch with the user's explicit "Open Anyway" override in System Settings → Privacy & Security. Real Developer ID + notarisation lands in a follow-up once the user obtains a $99 Apple Developer account.
- **Universal binary:** SwiftPM supports `--arch arm64 --arch x86_64` from Swift 5.9+. If any dependency lacks a slice for one of the arches, fall back to building per-arch and `lipo`-ing the results, or ship arm64-only and document it.
- **DMG size:** Expect 5–10 MB for the executable + ~15 MB for resources / deps. If the resulting DMG exceeds 100 MB something is bundled that shouldn't be — strip and re-investigate.
- **Workflow SHA placeholders:** Don't fire the release workflow with `__SHA__` literals — the run will fail immediately. Resolve real SHAs before the first tag push.
- **Future work (not in M7):** Auto-updater binary (mirror AIGuard's `AIExposureUpdater` pattern), localised release notes, App Store submission path.
