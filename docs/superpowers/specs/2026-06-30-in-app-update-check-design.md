# In-App Update Check — Design

*Date: 2026-06-30. Status: approved, pending implementation plan.*

## Purpose

Let AI Notebook tell users when a newer release is available and give them a
one-click way to download it. **Check + notify only** — no download automation,
no silent install. Cross-platform: macOS (Swift/SwiftUI) and Windows
(.NET/WinUI 3), implemented as two parallel native versions sharing the same
logic shape.

This was hinted at already: `README.md` lists "an optional update check" as an
expected outbound network call, and `AINotebookVersion.swift` references an
"updater" that was never built.

## Non-goals (YAGNI)

- No auto-download or auto-install (revisit after code signing).
- No "skip this version" list — a daily throttle + per-session dismiss is enough.
- No background polling beyond the once-per-launch check.

## Prerequisite fix (in scope, required)

The in-code version constants are **stale** and must be accurate for a
current-vs-latest comparison to work:

- `Sources/AINotebookCore/AINotebookVersion.swift`: `AINotebookVersion = "0.7.3"` → `"0.8.1"`
- `windows/src/AINotebook.Core/AINotebookVersion.cs`: `AINotebookVersion.Current = "0.7.3"` → `"0.8.1"`

Note: Windows *has* a guard test (`AINotebookVersionTests.VersionMatchesExpected`),
but it pins a **hardcoded literal** (`Assert.Equal("0.7.3", AINotebookVersion.Current)`)
— it does not read the `VERSION` file, which is exactly why the drift went
unnoticed. Fix both guards to read the **repo-root `VERSION` file** and assert the
constant equals it, so a future `VERSION` bump that forgets the constant fails CI:
- Update the existing C# test to load `VERSION` (relative path from the test
  working dir) instead of the literal.
- Add an equivalent **Swift guard test** that loads `VERSION` and asserts
  `AINotebookVersion` matches.

## Architecture

Three layers per platform:

### 1. Pure logic (in each Core, offline, unit-tested)

A pure function that takes the decoded releases list + current version + this
platform's asset suffix, and returns an `UpdateInfo`:

```
UpdateInfo {
  isUpdateAvailable: Bool
  latestVersion:     String          // e.g. "0.9.0"
  downloadURL:       URL/string      // the matching asset's browser_download_url
  releaseNotesURL:   URL/string      // the release's html_url
}
```

Rules:
- Consider only **non-prerelease** releases.
- Consider only releases that contain an asset matching this platform's suffix:
  - macOS: asset name ends with `-macos.dmg`
  - Windows: asset name ends with `-windows-setup.exe`
- Pick the one with the **highest semantic version** (parsed from `tag_name`,
  stripping a leading `v` or `win-v`).
- `isUpdateAvailable` = that version is strictly greater than the current
  version (numeric major.minor.patch compare).
- If no compatible release is found, `isUpdateAvailable = false`.

This sidesteps the repo's split tag scheme (`v*` unified vs `win-v*`
Windows-only) and guarantees the download URL always points at an installer for
the running platform.

Locations:
- Swift: new file in `Sources/AINotebookCore/` (e.g. `UpdateCheck.swift`) — pure,
  no `URLSession` (respects the Core offline CI grep gate).
- C#: new file in `windows/src/AINotebook.Core/` (e.g. `UpdateCheck.cs`).

### 2. Fetch layer

GETs `https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30`
(public repo, no auth, ~5s timeout, `Accept: application/vnd.github+json`),
decodes the JSON, and calls the pure logic above.

- **Windows:** `UpdateChecker` in `AINotebook.Core` using `HttpClient` (same
  pattern as `OllamaClient`).
- **macOS:** lives in the **App** layer (`Sources/AINotebookApp/`), e.g.
  `UpdateService.swift`, because `AINotebookCore` forbids `URLSession` outside
  `OllamaClient.swift` / `WebExtractor.swift` (enforced by `core-ci.yml`'s grep
  gate). The pure compare logic stays in Core and is called from the App.

JSON fields used: `tag_name`, `prerelease`, `html_url`, `assets[].name`,
`assets[].browser_download_url`.

### 3. UI

**Update banner** (main window only, not during onboarding): a non-modal bar at
the top of the primary content when an update is available:

> A new version (X) is available.  **[Download]**  **[Later]**

- **Download** opens the matching asset's `browser_download_url` (starts the
  browser download). macOS: `NSWorkspace.shared.open`; Windows:
  `Launcher.LaunchUriAsync`.
- **Later** dismisses the banner for the current session.
- Placement: macOS in the main content view (`ContentView` / notebook detail
  area); Windows in `ShellPage` (top of the shell, e.g. a WinUI `InfoBar`).

**Settings rows** (both platforms already have a Settings surface —
`SettingsView.swift` / `SettingsDialog.xaml`):
- `☑ Automatically check for updates` — toggle, default **on**.
- `Current version: 0.8.1`.
- **Check for updates now** button with inline status text:
  *Checking… / You're up to date / Update available (X) / Couldn't check for updates.*

## Behavior & persistence

- On launch, if the toggle is on and it has been **≥ ~24h** since the last
  check, run one silent check in the background. Skip during onboarding.
- Manual "Check now" always runs regardless of throttle.
- New settings keys:
  - macOS (`AppSettings`, UserDefaults-backed): `autoCheckUpdates: Bool = true`,
    `lastUpdateCheck: Date?`.
  - Windows (`ISettingsService` / `SettingsService`, LocalSettings-backed):
    `AutoCheckUpdates: bool = true`, `LastUpdateCheck: DateTimeOffset?`.

## Error handling

- **Auto-check** failures (offline, timeout, non-200, rate-limited, malformed
  JSON) are silent — simply no banner.
- **Manual check** failures show "Couldn't check for updates." in the status
  text. Never block app startup; the check is fully asynchronous and
  best-effort.

## Privacy

The only outbound call is to `api.github.com`; it carries no personal data.
Users can disable the automatic check via the Settings toggle. The README's
network-calls list already covers "an optional update check"; update it to note
the toggle.

## Testing

Core unit tests for the pure picker (both platforms):
- Newer release available → `isUpdateAvailable = true`, correct version + URL.
- Equal / older latest → `false`.
- Prerelease-only newer release → ignored.
- Newest release lacks this platform's asset → falls back to the newest that has
  one (covers `win-v*` vs `v*`).
- Empty list / malformed entries → `false`, no crash.
- Semver compare: `0.8.1` vs `0.8.10`, `0.9.0` vs `0.8.1`, prefix stripping
  (`v0.9.0`, `win-v0.9.0`).

Version-constant guard tests on both platforms, each loading the repo-root
`VERSION` file (Swift: new; C#: convert the existing literal-pinned test to read
`VERSION`).

UI/service wiring is verified by the existing build + smoke flow; no live
network test in CI.

## Affected files (indicative)

- `Sources/AINotebookCore/AINotebookVersion.swift` (bump), new `UpdateCheck.swift`
- `Sources/AINotebookApp/`: new `UpdateService.swift`, banner view, Settings rows,
  launch hook
- `Sources/AINotebookCore/AppSettings.swift` (new keys)
- `Tests/`: Swift version-guard + picker tests
- `windows/src/AINotebook.Core/AINotebookVersion.cs` (bump), new `UpdateCheck.cs`,
  new `UpdateChecker.cs`
- `windows/src/AINotebook.App/`: `ShellPage` InfoBar, `SettingsDialog` rows + VM,
  `ISettingsService`/`SettingsService` keys, launch hook
- `windows/tests/`: picker tests (version-guard test already exists)
- `README.md`: note the update-check toggle
