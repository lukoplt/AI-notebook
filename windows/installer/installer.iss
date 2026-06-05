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
