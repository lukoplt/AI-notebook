# Windows Packaging & Release Implementation Plan

> **Agentic note for the executing agent:** This is Plan 3 of the AI Notebook WinUI port. It is the **last** plan to run — it depends on `windows/src/AINotebook.App/` existing and building (produced by Plan 2). Do **not** start these tasks until `dotnet build windows/AINotebook.sln -c Release` succeeds on a Windows machine. Every task here ships build/CI artefacts only; none of it can be compiled, run, or verified on the macOS dev box. Where a task says "Verify (Windows only)", that step is for the human (or a Windows CI runner) — write the files exactly as given, commit, and move on; do not attempt to run `dotnet publish`, `ISCC`, or the installer on macOS. The headless `AINotebook.Core` library (174 tests green) is frozen — this plan never touches it. The single source of truth for the version string is the repo-root `VERSION` file (currently `0.7.3`), already consumed by the mac build; we reuse it verbatim so a tag bumps both platforms identically.

## Goal

Produce, from a tagged commit, an **unsigned** Windows installer for `AINotebook.App`:

1. A **self-contained** `dotnet publish` of `AINotebook.App` (win-x64) — runs on a clean Windows 10/11 box with no .NET runtime, no Windows App SDK runtime, and no MSIX packaging (unpackaged + `WindowsAppSDKSelfContained`).
2. An **Inno Setup** installer (`AINotebook-vX.Y.Z-windows-setup.exe`) that drops the publish folder under `Program Files`, **chains the Microsoft Edge WebView2 Evergreen runtime** (the only external OS dependency the editor host needs) only when it is missing, adds a Start-Menu icon, and offers a post-install launch.
3. A **tag-triggered GitHub Actions release** (`on: push: tags: v*`, `runs-on: windows-latest`) that publishes, downloads the WebView2 bootstrapper, compiles the installer with ISCC (passing the version from the `VERSION` file), and uploads the `.exe` to the GitHub Release — mirroring the existing `macos-release.yml` (same SHA-pinned actions, same `v*` trigger, same `softprops/action-gh-release`).

v1 ships **unsigned** — exactly like the current macOS DMG. Windows SmartScreen will show a "Windows protected your PC" warning on first run; this is documented and accepted for v1. A commented-out Authenticode `signtool` step is left in place (gated on `SIGN_CERT` / `SIGN_PASS` secrets) so signing can be enabled later without restructuring the pipeline.

## Architecture

```
                          ┌──────────────────────────────────────────────┐
   git tag vX.Y.Z ───────▶│ .github/workflows/windows-release.yml         │
                          │  (runs-on: windows-latest)                    │
                          │                                               │
                          │  1. checkout                                  │
                          │  2. setup-dotnet 10.x                         │
                          │  3. dotnet publish  ──▶ publish/  (self-cont.) │
                          │  4. curl WebView2 bootstrapper ──▶ redist/    │
                          │  5. choco install innosetup                   │
                          │  6. ISCC /DMyAppVersion=$(cat VERSION) \      │
                          │           windows/installer/installer.iss     │
                          │       ──▶ windows/installer/Output/           │
                          │           AINotebook-vX.Y.Z-windows-setup.exe │
                          │  7. (commented) signtool sign …               │
                          │  8. softprops/action-gh-release  ──▶ Release  │
                          └──────────────────────────────────────────────┘

   VERSION (repo root, "0.7.3") ── single source of truth ──┐
                                                            ├─▶ Inno AppVersion (/DMyAppVersion)
   mac build also reads VERSION ────────────────────────────┘   asset name AINotebook-v{VERSION}-windows-setup.exe
```

**Installer runtime flow (on the user's machine):**

```
AINotebook-vX.Y.Z-windows-setup.exe (admin/UAC)
  │
  ├─ [Files]  publish\*  ──▶  C:\Program Files\AI Notebook\   (recursesubdirs, ignoreversion)
  ├─ [Files]  redist\MicrosoftEdgeWebview2Setup.exe ──▶ {tmp}\ (deleteafterinstall)
  │
  ├─ [Run]  IF WebView2Missing()  ──▶  MicrosoftEdgeWebview2Setup.exe /silent /install   (waituntilterminated)
  ├─ [Icons]  Start-Menu shortcut ──▶ {app}\AINotebook.App.exe
  └─ [Run]  postinstall (optional, skipifsilent) ──▶ launch AINotebook.App.exe
                                                          │
                                                          ▼  first run → onboarding state machine (Plan 2)
```

WebView2 presence is detected via the EdgeUpdate client GUID `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` (`pv` value under HKLM `WOW6432Node` or HKCU). The Windows App SDK runtime itself is **not** chained — it is bundled inside the publish folder by `WindowsAppSDKSelfContained=true`. WebView2 is the only thing that must be ensured separately.

## Tech Stack

- **Publish:** `dotnet publish -c Release -r win-x64 --self-contained true` (no `PublishSingleFile`; WinUI 3 unpackaged self-contained does not require/support single-file here). `WindowsAppSDKSelfContained=true`, `SelfContained=true`, `WindowsPackageType=None` are already in `AINotebook.App.csproj` (Plan 1/2).
- **Installer:** Inno Setup 6 (`ISCC.exe`), Pascal `[Code]` section for the WebView2 registry check, `/D` command-line define for the version.
- **WebView2 runtime:** Evergreen Bootstrapper (`MicrosoftEdgeWebview2Setup.exe`, ~2 MB) from `https://go.microsoft.com/fwlink/p/?LinkId=2124703` — silent `/silent /install`.
- **CI:** GitHub Actions, `windows-latest`, `actions/setup-dotnet`, Chocolatey (`choco install innosetup`), `softprops/action-gh-release`. Actions are **SHA-pinned** reusing the exact pins already vetted in `macos-release.yml`.
- **Versioning:** repo-root `VERSION` file (plain text, e.g. `0.7.3`), read by both `cat VERSION` (CI) and `/DMyAppVersion=` (ISCC).
- **Signing (deferred):** `signtool sign /fd SHA256 /tr <RFC3161 TSA> /td SHA256 …` gated on `secrets.SIGN_CERT` + `secrets.SIGN_PASS` — left commented for v1.

## File Structure

```
AI_Notebook/
├── VERSION                                  # existing — single source of truth (0.7.3)
├── .github/
│   └── workflows/
│       ├── core-ci.yml                       # existing
│       ├── macos-release.yml                 # existing — mirrored by the new file
│       └── windows-release.yml               # NEW (Task P1.4)
├── windows/
│   ├── AINotebook.sln                        # existing
│   ├── src/
│   │   ├── AINotebook.Core/                   # existing, frozen
│   │   └── AINotebook.App/                    # produced by Plan 2
│   │       └── Properties/
│   │           └── PublishProfiles/
│   │               └── win-x64.pubxml         # NEW (Task P1.1)
│   └── installer/
│       ├── installer.iss                      # NEW (Task P1.2)
│       ├── assets/
│       │   └── app.ico                         # NEW (Task P1.3)
│       ├── redist/
│       │   └── .gitkeep                         # NEW (Task P1.2) — bootstrapper downloaded at build time
│       ├── publish/                             # build output (gitignored)
│       └── Output/                              # ISCC output (gitignored)
└── docs/
    └── windows-build.md                         # NEW (Task P1.5) — manual build + smoke checklist
```

Add to `windows/.gitignore` (Task P1.2): `installer/publish/`, `installer/Output/`, `installer/redist/MicrosoftEdgeWebview2Setup.exe`.

---

## Milestone P1 — Windows installer & release pipeline

### Task P1.1 — Self-contained publish profile + documented publish command

**Files:**
- Create: `windows/src/AINotebook.App/Properties/PublishProfiles/win-x64.pubxml`

`AINotebook.App.csproj` (from Plan 1/2) already declares the self-contained switches. We do **not** edit the csproj here — this task only adds an MSBuild publish profile so both the human and CI can publish with one stable command, and documents the exact output shape.

**Step 1 — Add the publish profile.**

Create `windows/src/AINotebook.App/Properties/PublishProfiles/win-x64.pubxml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<!--
  Self-contained, unpackaged WinUI 3 publish profile for AINotebook.App.
  Produces a runnable folder (no single-file): the .exe plus the .NET runtime,
  the Windows App SDK runtime (WindowsAppSDKSelfContained), the WebView2 SDK
  loader, the bundled editor assets, and all managed DLLs.

  Publish with:
    dotnet publish windows/src/AINotebook.App/AINotebook.App.csproj `
      -c Release -r win-x64 --self-contained true `
      -p:PublishProfile=win-x64

  (The -p:PublishProfile flag is optional; the explicit -c/-r/--self-contained
  flags below mirror the profile so a bare `dotnet publish ... -r win-x64
  --self-contained true` is equivalent. CI uses the explicit-flags form.)
-->
<Project>
  <PropertyGroup>
    <Configuration>Release</Configuration>
    <Platform>x64</Platform>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>
    <WindowsPackageType>None</WindowsPackageType>
    <PublishSingleFile>false</PublishSingleFile>
    <PublishReadyToRun>false</PublishReadyToRun>
    <PublishDir>bin\$(Configuration)\$(TargetFramework)\$(RuntimeIdentifier)\publish\</PublishDir>
  </PropertyGroup>
</Project>
```

**Step 2 — Document the canonical publish command.**

The canonical command (used by CI in Task P1.4 and the manual doc in Task P1.5), from the repo root, is:

```powershell
dotnet publish windows/src/AINotebook.App/AINotebook.App.csproj `
  -c Release -r win-x64 --self-contained true `
  -o windows/installer/publish
```

`-o windows/installer/publish` redirects the output to the folder the Inno script consumes (`Source: "publish\*"`), so the installer build and the publish share one location. The explicit `-c/-r/--self-contained` flags make the command self-describing and independent of whether the profile is picked up.

**Step 3 — Document the expected output shape** (record this in the commit message and in `docs/windows-build.md`, Task P1.5):

- `AINotebook.App.exe` — the launch target (referenced by `[Icons]` and the post-install `[Run]` in the Inno script).
- `AINotebook.App.dll`, `AINotebook.Core.dll`, plus CommunityToolkit.Mvvm and Microsoft.Extensions.DependencyInjection DLLs.
- The self-contained .NET runtime DLLs (`coreclr.dll`, `clrjit.dll`, `System.*.dll`, …).
- The Windows App SDK runtime (`Microsoft.WindowsAppRuntime.Bootstrap.dll`, `Microsoft.ui.xaml.dll`, the `Microsoft.WindowsAppSDK` native components) — present because `WindowsAppSDKSelfContained=true`.
- `Microsoft.Web.WebView2.Core.dll` + `WebView2Loader.dll` (the SDK loader; the **runtime** is chained separately by the installer).
- The bundled editor assets folder (e.g. `Assets\editor\` containing `editor.html`, `editor.js`, `editor.css`) that `MainWindow` maps via `SetVirtualHostNameToFolderMapping("appassets", …)`.
- Localization satellite folders `en-US\` and `cs-CZ\` with the `.resw`-compiled resources (from Plan 2).

There is **no** single-file output and **no** requirement for one; the installer ships the whole folder.

**Verify (Windows only):**

> Build on a Windows machine and manually verify:
> - `dotnet publish windows/src/AINotebook.App/AINotebook.App.csproj -c Release -r win-x64 --self-contained true -o windows/installer/publish` exits 0.
> - `windows/installer/publish/AINotebook.App.exe` exists and double-clicking it launches the app **on a box that has WebView2 installed** (most dev boxes do, via Edge).
> - The folder contains `Microsoft.WindowsAppRuntime.Bootstrap.dll` and `coreclr.dll` (proves self-contained + WASDK-self-contained).
> - Copying the entire `publish` folder to a machine **with no .NET 10 SDK/runtime** still launches (self-contained proven).

**Commit:**

```bash
git add windows/src/AINotebook.App/Properties/PublishProfiles/win-x64.pubxml
git commit -m "build(win): add self-contained win-x64 publish profile for AINotebook.App

Self-contained + WindowsAppSDKSelfContained + unpackaged publish profile.
Output -o windows/installer/publish feeds the Inno Setup script (P1.2).
No single-file; the installer ships the whole folder.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task P1.2 — Inno Setup script (`installer.iss`) with WebView2 chaining

**Files:**
- Create: `windows/installer/installer.iss`
- Create: `windows/installer/redist/.gitkeep`
- Modify: `windows/.gitignore`

This reproduces the grounded reference in the gather file (`…/w44hwgaxd.output`, section 10 — "Packaging an unpackaged self-contained app with Inno Setup + chaining the WebView2 bootstrapper"), adapted to: real app name **AI Notebook**, version injected via `/DMyAppVersion`, x64-only, admin (per-machine WebView2), and the exact EdgeUpdate `{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}` registry check.

**Step 1 — Create `windows/installer/installer.iss`:**

```ini
; ============================================================================
;  AI Notebook — Inno Setup script (unsigned v1)
;  Wraps the self-contained dotnet-publish output (P1.1) and chains the
;  Microsoft Edge WebView2 Evergreen runtime when it is missing.
;
;  Build (from repo root, after `dotnet publish ... -o windows/installer/publish`
;  and after downloading the bootstrapper into windows/installer/redist/):
;
;    ISCC.exe /DMyAppVersion=0.7.3 windows\installer\installer.iss
;
;  CI passes /DMyAppVersion=$(cat VERSION). The default below is only a
;  fallback for ad-hoc local runs that forget the /D flag.
; ============================================================================

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#define MyAppName       "AI Notebook"
#define MyAppExeName    "AINotebook.App.exe"
#define MyAppPublisher  "Lukas Oplt"
#define MyAppURL        "https://github.com/lukasoplt/AI_Notebook"

[Setup]
AppId={{8B2F7E1A-3C4D-4E5F-9A0B-1C2D3E4F5A6B}}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\AI Notebook
DefaultGroupName=AI Notebook
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
; Per-machine WebView2 install + Program Files requires elevation.
PrivilegesRequired=admin
; x64 only — matches -r win-x64.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=Output
OutputBaseFilename=AINotebook-v{#MyAppVersion}-windows-setup
SetupIconFile=assets\app.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; Self-contained publish output (P1.1). recursesubdirs picks up the editor
; assets folder + en-US/cs-CZ localization satellites; ignoreversion lets us
; overwrite framework DLLs on upgrade regardless of file version.
Source: "publish\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion createallsubdirs
; WebView2 Evergreen bootstrapper (downloaded into redist\ before build, ~2 MB).
Source: "redist\MicrosoftEdgeWebview2Setup.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
; Install the WebView2 runtime silently, only when the EdgeUpdate client key is
; absent/empty. Elevated install => per-machine. waituntilterminated so the app
; is not launched before the runtime is in place.
Filename: "{tmp}\MicrosoftEdgeWebview2Setup.exe"; Parameters: "/silent /install"; \
    StatusMsg: "Installing Microsoft Edge WebView2 Runtime..."; \
    Check: WebView2Missing; Flags: waituntilterminated
; Optional post-install launch (skipped during /SILENT installs, e.g. winget/CI).
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; \
    Flags: nowait postinstall skipifsilent

[Code]
function WebView2Missing(): Boolean;
var
  v: string;
begin
  // Present if the EdgeUpdate client key has a non-empty, non-zero 'pv'
  // (product version). Check the 64-bit-OS HKLM WOW6432Node location and the
  // HKCU per-user location.
  Result := not (
    (RegQueryStringValue(HKLM,
      'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
      'pv', v) and (v <> '') and (v <> '0.0.0.0'))
    or
    (RegQueryStringValue(HKCU,
      'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
      'pv', v) and (v <> '') and (v <> '0.0.0.0'))
  );
end;
```

Notes on the deltas from the reference snippet:
- `AppId` is a fixed GUID (required for clean upgrades/uninstall registration; generated once, never changed across releases).
- `OutputBaseFilename=AINotebook-v{#MyAppVersion}-windows-setup` produces exactly the asset name the release workflow uploads (`AINotebook-v0.7.3-windows-setup.exe`).
- `ArchitecturesAllowed=x64compatible` / `…InstallIn64BitMode=x64compatible` (Inno 6.3+ token; on ARM64 Windows the x64 build runs under emulation, which WinUI self-contained x64 supports).
- `SetupIconFile=assets\app.ico` references the icon added in Task P1.3.
- The `[Code]` `WebView2Missing` check is copied verbatim from the grounded reference.

**Step 2 — Create the redist placeholder so the folder is tracked but the binary is not.**

Create `windows/installer/redist/.gitkeep` (empty file). The `MicrosoftEdgeWebview2Setup.exe` is fetched at build time (CI: Task P1.4; locally: Task P1.5) and is gitignored.

**Step 3 — Update `windows/.gitignore`.**

Current content is `bin/`, `obj/`, `*.user`. Append the installer build artefacts:

```gitignore
bin/
obj/
*.user
installer/publish/
installer/Output/
installer/redist/MicrosoftEdgeWebview2Setup.exe
```

**Verify (Windows only):**

> Build on a Windows machine and manually verify:
> - After `dotnet publish ... -o windows/installer/publish` and downloading the bootstrapper to `windows/installer/redist/MicrosoftEdgeWebview2Setup.exe`, run from `windows/installer/`:
>   `ISCC.exe /DMyAppVersion=0.7.3 installer.iss`
>   and confirm it exits 0 and writes `windows/installer/Output/AINotebook-v0.7.3-windows-setup.exe`.
> - Run the resulting installer on a **clean** Win10/11 VM **without** WebView2 (uninstall the Evergreen runtime first): the "Installing Microsoft Edge WebView2 Runtime..." status appears, the runtime installs, then the app launches.
> - Run the installer again on a box **with** WebView2 already present: the WebView2 step is skipped (no status message), install is fast.
> - Start-Menu group "AI Notebook" has both the app and uninstall shortcuts; uninstall removes `{app}`.

**Commit:**

```bash
git add windows/installer/installer.iss windows/installer/redist/.gitkeep windows/.gitignore
git commit -m "build(win): Inno Setup installer with WebView2 evergreen chaining

installer.iss wraps the self-contained publish folder, chains the WebView2
Evergreen bootstrapper only when the EdgeUpdate {F3017226-...} pv key is
missing, adds Start-Menu icons, and offers post-install launch. AppVersion
injected via /DMyAppVersion; OutputBaseFilename yields the release asset name.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task P1.3 — App icon asset + VERSION-derived AppName/version wiring

**Files:**
- Create: `windows/installer/assets/app.ico`
- (No new code; this task wires the existing root `VERSION` into the installer and documents the icon source.)

**Step 1 — Produce `app.ico`.**

The mac app already ships an app icon (`Sources/AINotebookApp/Assets.xcassets/AppIcon.appiconset` or the equivalent asset used by the SwiftUI build). Use the **same artwork** so the Windows app is visually identical. A multi-resolution `.ico` (16, 32, 48, 64, 128, 256 px) is required by both Inno (`SetupIconFile`) and the WinUI app window/taskbar icon.

On a machine with ImageMagick:

```bash
# From the largest available PNG source (>= 256x256) of the mac app icon:
magick convert AppIcon-1024.png -define icon:auto-resize=256,128,64,48,32,16 \
  windows/installer/assets/app.ico
```

If ImageMagick is unavailable, generate the `.ico` with any icon tool (e.g. https://icoconvert.com) from the 1024×1024 mac icon PNG, ensuring it contains the 16→256 px sizes. Commit the binary `app.ico` to the repo (it is a build input, not a build output, so it is **not** gitignored).

> The WinUI app's own window/taskbar icon is set in Plan 2 (`AINotebook.App.csproj` `<ApplicationIcon>` or `MainWindow.AppWindow.SetIcon`). This task only provides the installer icon; if Plan 2 already added an `ApplicationIcon`, point both at the same `app.ico` (copy it to wherever Plan 2 expects, or reference `..\..\installer\assets\app.ico`). Keep a single source `.ico`.

**Step 2 — Confirm the VERSION single-source wiring.**

No code is written here — this step records the contract so later tasks rely on it:
- The root `VERSION` file (`0.7.3`) is the **only** place the version is edited.
- `AINotebookVersion.Current` in Core is `"0.7.3"` (kept in sync by the existing release process — out of scope for this plan).
- The Inno `AppVersion` comes from `/DMyAppVersion=$(cat VERSION)` (CI) — never hard-coded in `installer.iss` (the `#define MyAppVersion "0.0.0"` fallback only guards forgetful local runs).
- The release asset name `AINotebook-v{VERSION}-windows-setup.exe` is derived from the same `OutputBaseFilename` token, so a single `VERSION` bump renames the installer, sets its `AppVersion`, and (via the git tag) names the GitHub Release — exactly as the mac DMG does.

**Step 3 — `AppName` is a constant** (`"AI Notebook"`) defined once as `#define MyAppName` in `installer.iss` and matching the mac product name; it is **not** read from a file (only the version varies per release).

**Verify (Windows only):**

> Build on a Windows machine and manually verify:
> - `windows/installer/assets/app.ico` opens in an image viewer and shows the AI Notebook icon at multiple sizes.
> - After `ISCC.exe /DMyAppVersion=0.7.3 installer.iss`, the produced `setup.exe` shows the app icon in Explorer, and the installed Start-Menu shortcut + Apps & Features entry show the same icon.
> - "Apps & Features" lists "AI Notebook" version `0.7.3`.

**Commit:**

```bash
git add windows/installer/assets/app.ico
git commit -m "build(win): add installer app icon (shared mac artwork) + VERSION wiring

Multi-resolution app.ico (16-256px) reused from the mac app icon, consumed by
Inno SetupIconFile and the installed shortcut. Documents that AppVersion is
derived solely from the root VERSION file (single source shared with the mac
build); AppName is the constant 'AI Notebook'.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task P1.4 — Tag-triggered GitHub Actions release workflow

**Files:**
- Create: `.github/workflows/windows-release.yml`

Mirrors `.github/workflows/macos-release.yml`: same `on: push: tags: v*`, same `permissions: contents: write`, the **same SHA-pinned** `actions/checkout` and `softprops/action-gh-release` pins already vetted in the mac workflow.

**Step 1 — Create `.github/workflows/windows-release.yml`:**

```yaml
name: Windows Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  build-installer:
    runs-on: windows-latest
    timeout-minutes: 40
    steps:
      - name: Checkout
        uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5  # actions/checkout@v4

      - name: Setup .NET 10
        uses: actions/setup-dotnet@3e891b0cb619bf60e2c25674b222b8940e2c1c25  # actions/setup-dotnet@v4
        with:
          dotnet-version: '10.0.x'

      - name: Read version from VERSION file
        id: ver
        shell: bash
        run: echo "version=$(cat VERSION)" >> "$GITHUB_OUTPUT"

      - name: Restore
        run: dotnet restore windows/AINotebook.sln

      - name: Publish self-contained (win-x64)
        run: >
          dotnet publish windows/src/AINotebook.App/AINotebook.App.csproj
          -c Release -r win-x64 --self-contained true
          -o windows/installer/publish

      - name: Download WebView2 Evergreen bootstrapper
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force -Path windows/installer/redist | Out-Null
          Invoke-WebRequest `
            -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' `
            -OutFile windows/installer/redist/MicrosoftEdgeWebview2Setup.exe
          if (-not (Test-Path windows/installer/redist/MicrosoftEdgeWebview2Setup.exe)) {
            throw 'WebView2 bootstrapper download failed'
          }

      - name: Install Inno Setup
        shell: pwsh
        run: choco install innosetup --no-progress -y

      - name: Compile installer (ISCC)
        shell: pwsh
        working-directory: windows/installer
        run: |
          $iscc = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
          & $iscc "/DMyAppVersion=${{ steps.ver.outputs.version }}" installer.iss
          if ($LASTEXITCODE -ne 0) { throw "ISCC failed with $LASTEXITCODE" }

      # ---------------------------------------------------------------------
      # OPTIONAL Authenticode signing (v1 ships UNSIGNED -> SmartScreen warning,
      # same as the unsigned mac DMG). To enable: add repo secrets SIGN_CERT
      # (base64 .pfx) and SIGN_PASS, then uncomment this block. Place it BEFORE
      # the upload step so the signed .exe is what gets released.
      # ---------------------------------------------------------------------
      # - name: Sign installer (Authenticode)
      #   if: ${{ secrets.SIGN_CERT != '' }}
      #   shell: pwsh
      #   env:
      #     SIGN_CERT: ${{ secrets.SIGN_CERT }}
      #     SIGN_PASS: ${{ secrets.SIGN_PASS }}
      #   run: |
      #     [IO.File]::WriteAllBytes("$env:RUNNER_TEMP\cert.pfx",
      #       [Convert]::FromBase64String($env:SIGN_CERT))
      #     $signtool = (Get-ChildItem `
      #       "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" |
      #       Sort-Object FullName -Descending | Select-Object -First 1).FullName
      #     & $signtool sign /f "$env:RUNNER_TEMP\cert.pfx" /p $env:SIGN_PASS `
      #       /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
      #       "windows/installer/Output/AINotebook-v${{ steps.ver.outputs.version }}-windows-setup.exe"

      - name: Upload installer to GitHub Release
        uses: softprops/action-gh-release@3bb12739c298aeb8a4eeaf626c5b8d85266b0e65  # softprops/action-gh-release@v2
        with:
          files: windows/installer/Output/AINotebook-v${{ steps.ver.outputs.version }}-windows-setup.exe
          generate_release_notes: true
          fail_on_unmatched_files: true
```

Notes:
- `actions/checkout` and `softprops/action-gh-release` reuse the **exact** SHA pins from `macos-release.yml` (`34e1148…` and `3bb1273…`). `actions/setup-dotnet@v4` is pinned to its published v4 SHA (`3e891b0…`); if the executing agent cannot confirm that SHA on the Windows box, resolve the current `v4` tag SHA with `gh api repos/actions/setup-dotnet/git/ref/tags/v4` and pin that — never use a floating `@v4` tag, to match the repo's pinning convention.
- The WebView2 bootstrapper URL `https://go.microsoft.com/fwlink/p/?LinkId=2124703` is Microsoft's canonical Evergreen Bootstrapper fwlink (from the WebView2 distribution docs referenced in the gather file). `Invoke-WebRequest` follows the redirect to the real `.exe`.
- `working-directory: windows/installer` makes the Inno `OutputDir=Output` and `Source: "publish\*"` / `redist\…` relative paths resolve, matching the local build.
- `fail_on_unmatched_files: true` makes the job fail loudly if the asset name drifts from the `OutputBaseFilename` token — guarding the VERSION single-source contract.
- The version is read **once** via `cat VERSION` into `steps.ver.outputs.version` and reused for `/DMyAppVersion`, the asset path, and (commented) signing — so nothing is hard-coded.

**Step 2 — Sanity-check the asset-name contract.** With `VERSION=0.7.3`, ISCC writes `windows/installer/Output/AINotebook-v0.7.3-windows-setup.exe`, and the upload glob targets that exact path. The git tag is independent (`v0.7.3`) but conventionally equals `v$(cat VERSION)`.

**Verify (Windows only / via CI):**

> This runs on `windows-latest` in CI; it cannot run on macOS. Validate by:
> - Locally lint the YAML (`actionlint .github/workflows/windows-release.yml` if available) — must pass.
> - Push a throwaway pre-release tag from a branch (e.g. `git tag v0.7.3-rc1 && git push origin v0.7.3-rc1`) and watch the **Windows Release** workflow on `windows-latest`: all steps green, and the Release for `v0.7.3-rc1` has `AINotebook-v0.7.3-windows-setup.exe` attached.
> - Download that asset on a clean Win10/11 VM and run the smoke checklist from Task P1.5.
> - Delete the throwaway tag/release afterward.

**Commit:**

```bash
git add .github/workflows/windows-release.yml
git commit -m "ci(win): tag-triggered Windows installer release on windows-latest

Mirrors macos-release.yml: on push tag v*, setup-dotnet 10.x, self-contained
publish, download WebView2 evergreen bootstrapper, choco install innosetup,
ISCC /DMyAppVersion=\$(cat VERSION), upload AINotebook-vX.Y.Z-windows-setup.exe
via softprops/action-gh-release (SHA-pinned, reusing the mac workflow pins).
Authenticode signtool step left commented (SIGN_CERT/SIGN_PASS) for later;
v1 ships unsigned to match the mac DMG.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task P1.5 — Manual local build doc + clean-machine smoke checklist

**Files:**
- Create: `docs/windows-build.md`

**Step 1 — Create `docs/windows-build.md`:**

````markdown
# Building the AI Notebook Windows installer

The Windows installer is normally produced automatically by the
**Windows Release** GitHub Action on every `v*` tag (see
`.github/workflows/windows-release.yml`). This document explains how to
produce the same `AINotebook-vX.Y.Z-windows-setup.exe` by hand on a Windows
dev box, and the smoke checklist to run before shipping.

> v1 installers are **unsigned**. On first run Windows SmartScreen shows
> "Windows protected your PC" — click **More info → Run anyway**. This matches
> the unsigned macOS DMG (Gatekeeper warning). Authenticode signing is a
> commented, secret-gated step in the release workflow for when a certificate
> is available.

## Prerequisites (Windows 10/11 x64 dev box)

- **.NET 10 SDK** — https://dotnet.microsoft.com/download (verify: `dotnet --version` ≥ 10).
- **Inno Setup 6** — https://jrsoftware.org/isdl.php (provides `ISCC.exe`, by default at
  `C:\Program Files (x86)\Inno Setup 6\ISCC.exe`). Or `choco install innosetup`.
- **Git** with the repo cloned. All commands below run from the **repo root**
  in PowerShell.

## Step 1 — Self-contained publish

```powershell
dotnet publish windows/src/AINotebook.App/AINotebook.App.csproj `
  -c Release -r win-x64 --self-contained true `
  -o windows/installer/publish
```

This yields `windows/installer/publish/` containing `AINotebook.App.exe`, the
.NET runtime, the Windows App SDK runtime (self-contained), the WebView2 SDK
loader, the bundled editor assets, and the `en-US` / `cs-CZ` localization
satellites. No .NET runtime needs to be present on the target machine.

## Step 2 — Fetch the WebView2 Evergreen bootstrapper

```powershell
New-Item -ItemType Directory -Force -Path windows/installer/redist | Out-Null
Invoke-WebRequest `
  -Uri 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' `
  -OutFile windows/installer/redist/MicrosoftEdgeWebview2Setup.exe
```

(~2 MB; auto-detects architecture and downloads the matching runtime at
install time. The file is gitignored — it is fetched per build.)

## Step 3 — Compile the installer

```powershell
cd windows/installer
$version = Get-Content ../../VERSION   # single source of truth, e.g. 0.7.3
& "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" "/DMyAppVersion=$version" installer.iss
```

Output: `windows/installer/Output/AINotebook-v<version>-windows-setup.exe`.

## Step 4 — (Optional) sign

If you have a code-signing certificate (`.pfx`):

```powershell
& signtool sign /f cert.pfx /p <password> `
  /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 `
  "Output/AINotebook-v$version-windows-setup.exe"
```

Signing removes the SmartScreen warning (after the cert builds reputation).
Skipped for unsigned v1.

## Smoke checklist (run on a clean Windows 10 AND Windows 11 VM)

Use a **fresh** VM (or one with the WebView2 Evergreen runtime uninstalled) so
the WebView2 chaining path is actually exercised.

- [ ] Copy `AINotebook-vX.Y.Z-windows-setup.exe` to the clean VM and run it.
- [ ] UAC prompt appears (admin / per-machine install); accept it.
- [ ] On a box **without** WebView2: the wizard shows
      "Installing Microsoft Edge WebView2 Runtime..." and completes without error.
- [ ] On a box **with** WebView2 already present: that step is skipped.
- [ ] Files land under `C:\Program Files\AI Notebook\` including `AINotebook.App.exe`.
- [ ] Start-Menu group "AI Notebook" contains the app + uninstall shortcuts,
      both showing the app icon.
- [ ] "Apps & Features" lists **AI Notebook**, version `X.Y.Z`, correct publisher/icon.
- [ ] Post-install "Launch AI Notebook" launches the app.
- [ ] **First run shows onboarding** (welcome → detect Ollama → pick models →
      pull models → done). The WebView2-hosted editor renders (proves the
      WebView2 runtime + bundled editor assets work end-to-end).
- [ ] Quit and relaunch from the Start-Menu shortcut: onboarding does **not**
      reappear (`hasCompletedOnboarding` persisted in LocalSettings).
- [ ] Uninstall via Apps & Features removes `C:\Program Files\AI Notebook\`
      and the Start-Menu shortcuts. (WebView2, being a shared OS runtime, is
      intentionally left installed.)

If every box is checked on both Win10 and Win11, the installer is
ship-ready (unsigned).
````

**Step 2 — Cross-reference.** Ensure `docs/windows-build.md` references the workflow (`.github/workflows/windows-release.yml`) and the installer script (`windows/installer/installer.iss`) so a maintainer can navigate between the automated and manual paths.

**Verify (Windows only):**

> Build on a Windows machine and manually verify:
> - Following `docs/windows-build.md` Steps 1–3 verbatim on a fresh dev box produces `windows/installer/Output/AINotebook-v0.7.3-windows-setup.exe` with no undocumented prerequisites.
> - The smoke checklist runs to completion on a clean Win10 VM and a clean Win11 VM (WebView2 chained on first, skipped on a pre-provisioned one), app launches, onboarding appears, editor renders.

**Commit:**

```bash
git add docs/windows-build.md
git commit -m "docs(win): manual installer build guide + clean-machine smoke checklist

Step-by-step local build (publish -> fetch WebView2 bootstrapper -> ISCC with
VERSION) plus a Win10/Win11 clean-VM smoke checklist (WebView2 chained, app
launches, onboarding shows, editor renders). Documents the unsigned-v1
SmartScreen behaviour, matching the mac DMG.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone P1 — Done criteria

- `dotnet publish … -r win-x64 --self-contained true -o windows/installer/publish` produces a runnable folder on a machine with no .NET/WASDK runtime (P1.1).
- `ISCC /DMyAppVersion=$(cat VERSION) installer.iss` produces `AINotebook-v{VERSION}-windows-setup.exe` that installs under Program Files, chains WebView2 only when missing, adds Start-Menu icons, and launches the app (P1.2, P1.3).
- Pushing a `v*` tag triggers **Windows Release** on `windows-latest`, which builds and attaches the installer to the GitHub Release using SHA-pinned actions (P1.4).
- A maintainer can reproduce the installer by hand and validate it against a clean-machine smoke checklist (P1.5).
- v1 is unsigned (documented SmartScreen warning); a secret-gated `signtool` step is staged for future signing without pipeline changes.
- The root `VERSION` file remains the single source of truth shared with the mac build — one bump renames/versions the installer, the asset, and (via tag) the Release.
