# Windows App checks on macOS

The WinUI 3 App (`windows/src/AINotebook.App`, `net10.0-windows`) only builds on Windows, so a
change made on a Mac is otherwise unchecked until Windows CI runs. This tool catches most of what
that build would reject, locally, in about a minute:

| Check | What it does | Catches |
|---|---|---|
| `typecheck` | Compiles **every** App `.cs` file (code-behind included) against the real WinAppSDK 1.8 projection assemblies, plus one generated stub per `.xaml` (`typecheck/genstubs.py`): a field per `x:Name` typed by its element, `InitializeComponent()`, `Bindings.Update()`, every XAML event attribute subscribed to its handler, and the first path / function call of every `{x:Bind}` evaluated against the page or the template's `x:DataType`. | Wrong WinUI APIs, ambiguous types, missing `x:Name`, handler signature mismatches, `x:Bind` to members that do not exist, `StringKey` typos. |
| `apptests` | Runs `windows/tests/AINotebook.App.Tests` on .NET (not Windows): the App's view models and services compiled with a few stand-ins in `apptests/Stubs/` (`DispatcherQueue`, `Thickness`, `Launcher`, a `.resw`-backed `LocalizedStrings`). WinUI-bound helpers are excluded automatically (`apptests/prepare.py`). | View-model regressions, the XAML-contract and localization tests of App.Tests. |
| `lint` | `lint/xamllint.py`: well-formed XAML, every `{StaticResource}` / `{ThemeResource}` key defined (Tokens.xaml, Controls.xaml, App.xaml, the file itself, or a known WinUI resource), unique `x:Name` outside templates. | Missing resource keys (they compile but crash at page load). |

**Not covered — Windows CI and a manual run still decide:** the XAML compiler itself (`x:Bind`
type conversions, later path segments, property-element validity), XAML runtime parsing and
resource lookup order, visuals, the unpackaged startup smoke.

## Requirements

- .NET SDK 10 (`dotnet --version`), Python 3.
- Network once: restore downloads the WinAppSDK packages the App's `packages.lock.json` pins
  (`Microsoft.WindowsAppSDK.WinUI`, `.Foundation`, `.InteractiveExperiences`,
  `Microsoft.Web.WebView2`) and `Microsoft.Windows.SDK.NET.Ref` into the normal NuGet cache
  (`~/.nuget/packages`, or `$NUGET_PACKAGES`), about 700 MB. They are `PackageDownload` items:
  nothing Windows-only is referenced as a package, only their projection DLLs are passed to the
  compiler. Versions are read from the lock files on every run (`versions.py`), so they follow the
  App automatically.

## Commands

From the repository root:

```bash
tools/windows-typecheck/run.sh            # all three checks; exit 1 on any failure
tools/windows-typecheck/run.sh typecheck  # or: apptests | lint
WTC_RESTORE=0 tools/windows-typecheck/run.sh   # offline, packages already cached
tools/windows-typecheck/gates.sh          # full local gate: generators --check, UI string parity, swift build/test,
                                          # Core tests, then run.sh all
```

Output is a short summary; full logs, generated stubs and build output stay in
`tools/windows-typecheck/.work/` (git-ignored; delete it any time). The tool never writes into
`windows/` — builds use `--artifacts-path .work/artifacts`.

## When it fails

- `WinAppSDK projection missing …` — restore did not run or had no network; rerun without
  `WTC_RESTORE=0`.
- A compile error in `.work/typecheck-stubs/<Page>.g.cs` points at the `.xaml` of that page: an
  event handler or `x:Bind` path in it does not match the code-behind / view model.
- `x:Bind` to a non-string for `Text` is allowed here (the XAML compiler converts); bool targets
  (`IsChecked`, `IsOn`, `IsEnabled`, `IsActive`, `IsExpanded`) are type-checked.
- New pure types placed at the top of a code-behind file that tests need: add the file to
  `CODE_BEHIND_WITH_PURE_TYPES` in `apptests/prepare.py`.
