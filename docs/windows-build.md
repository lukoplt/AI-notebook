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
