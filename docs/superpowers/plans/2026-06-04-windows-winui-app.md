# AINotebook.App (WinUI 3) Implementation Plan

> Generated for the agentic-workers pipeline. Plan 2 of 3 (Foundation). This plan is written for autonomous execution on a Windows build machine. The macOS dev box used to author it **cannot** build or run WinUI 3, so every UI task ends with a "Build on a Windows machine and manually verify" step rather than an automated assertion. Pure-logic units are covered with xUnit where they do not depend on WinUI types.

**Goal:** Ship a Windows GUI for *AI Notebook* that consumes the already-built, 174-tests-green headless `AINotebook.Core` (under `windows/src/AINotebook.Core`) and reaches **full feature parity** with the macOS SwiftUI app — no new features (YAGNI), faithful port of the existing behaviours. This Plan 2 lays the **foundation**: project scaffold + DI composition root, localization, and the app shell (notebook sidebar + 4-tab detail). Plan 3 builds the per-tab views (Sources / Chat / Notes / Transformations), the WebView2 editor host, and the onboarding flow on top of this foundation.

**Architecture:** A single-window WinUI 3 desktop app, **unpackaged + self-contained** (xcopy/Inno-deployable like a `.app`). MVVM via `CommunityToolkit.Mvvm` (`[ObservableProperty]`/`[RelayCommand]`, partial properties to dodge `MVVMTK0045`). `Microsoft.Extensions.DependencyInjection` builds the Core service graph once at startup, exposed through `App.Current.Services`, mirroring the `init()` order of the SwiftUI composition root (`AINotebookApp.swift`). The Core library never touches a UI thread; the App layer marshals Core's fire-and-forget store callbacks (`OnNoteSaved`/`OnNoteDeleted`) and streaming token callbacks back to the UI via `DispatcherQueue.TryEnqueue`. The markdown editor (Plan 3) is hosted in a **WebView2** over a local bundle served from `https://appassets`. UI strings live in per-language `.resw` (EN + CS) ported verbatim from the mac `AppText` table (148 keys), with a runtime language switch via `ApplicationLanguages.PrimaryLanguageOverride`.

**Tech Stack:**
- **WinUI 3 / Windows App SDK 1.5+**, `net10.0-windows10.0.19041.0`, `TargetPlatformMinVersion 10.0.17763.0`, `RuntimeIdentifier win-x64`.
- `WindowsPackageType=None`, `WindowsAppSDKSelfContained=true`, `SelfContained=true`, `EnableMsixTooling=true`.
- NuGet: `Microsoft.WindowsAppSDK`, `Microsoft.Extensions.DependencyInjection`, `CommunityToolkit.Mvvm`.
- `ProjectReference` → `windows/src/AINotebook.Core/AINotebook.Core.csproj` (the green Core; **consumed, never modified**).
- xUnit test project `windows/tests/AINotebook.App.Tests` for WinUI-free logic (localization lookup, coordinators, settings, onboarding state machine — the last two in Plan 3).
- Persistence: Core's `NotebookStore` over `StorePath.Production()` (`%APPDATA%\AINotebook\db.sqlite`); App settings over `ApplicationData.LocalSettings`.

---

## File Structure

```
windows/
├── AINotebook.sln                                  # existing — add AINotebook.App (+ tests)
├── src/
│   ├── AINotebook.Core/                            # EXISTING green core (consumed, not modified)
│   └── AINotebook.App/                             # NEW — this plan
│       ├── AINotebook.App.csproj
│       ├── app.manifest                            # DPI awareness / longPathAware
│       ├── App.xaml
│       ├── App.xaml.cs                             # DI composition root (mirrors AINotebookApp.swift init)
│       ├── MainWindow.xaml
│       ├── MainWindow.xaml.cs                      # root router: onboarding-or-shell
│       ├── Views/
│       │   ├── ShellPage.xaml(.cs)                 # NavigationView sidebar + detail host
│       │   ├── NotebookDetailPage.xaml(.cs)        # header + 4-tab switcher (Plan 2 host)
│       │   ├── Dialogs/
│       │   │   ├── NewNotebookDialog.xaml(.cs)
│       │   │   └── RenameNotebookDialog.xaml(.cs)
│       │   ├── SourceListPage.xaml(.cs)            # Plan 3
│       │   ├── ChatPage.xaml(.cs)                  # Plan 3
│       │   ├── NotesPage.xaml(.cs)                 # Plan 3
│       │   └── TransformationsPage.xaml(.cs)       # Plan 3
│       ├── ViewModels/
│       │   ├── ShellViewModel.cs
│       │   ├── NotebookSidebarViewModel.cs
│       │   ├── NotebookDetailViewModel.cs
│       │   ├── NewNotebookViewModel.cs
│       │   └── RenameNotebookViewModel.cs
│       ├── Services/
│       │   ├── ISettingsService.cs / SettingsService.cs        # AppSettings port over LocalSettings
│       │   ├── IDialogService.cs / DialogService.cs            # ContentDialog helper
│       │   ├── ILocalizedStrings.cs / LocalizedStrings.cs      # .resw lookup + language switch
│       │   ├── NoteEditorCoordinator.cs                        # DI singleton (Plan 3 consumer)
│       │   ├── NoteJumpCoordinator.cs                          # DI singleton (Plan 3 consumer)
│       │   └── TabSwitchCoordinator.cs                         # DI singleton (wired in Plan 2)
│       ├── Editor/                                  # Plan 3 (WebView2 host + JS bridge)
│       │   ├── EditorWebViewHost.xaml(.cs)
│       │   └── EditorBridge.cs
│       ├── Onboarding/                              # Plan 3 (state machine ported here)
│       │   ├── OnboardingPage.xaml(.cs)
│       │   └── OnboardingViewModel.cs
│       ├── Strings/
│       │   ├── en-US/Resources.resw
│       │   └── cs-CZ/Resources.resw
│       ├── Assets/                                  # app icon, splash, logos
│       └── WebBundle/                               # copied editor.js/editor.html bundle (Plan 3)
└── tests/
    └── AINotebook.App.Tests/
        ├── AINotebook.App.Tests.csproj
        ├── LocalizedStringsTests.cs
        └── TabSwitchCoordinatorTests.cs
```

> Files marked *Plan 3* are listed for orientation; this Plan 2 creates only the foundation files (csproj, App, MainWindow, ShellPage, NotebookDetailPage, the two notebook dialogs, the Services listed, the `.resw` pair, and the test project). Plan 3 fills in `Editor/`, `Onboarding/`, `WebBundle/`, and the four tab pages.

---

## Milestone M0 — Project scaffold + DI composition root

Goal: an `AINotebook.App` project that compiles, is in the solution, references the Core, builds the full Core service graph at startup in the exact order of `AINotebookApp.swift`, and shows a blank `MainWindow` that routes to onboarding-or-shell based on `HasCompletedOnboarding`.

### Task M0.1 — Create the unpackaged self-contained WinUI 3 csproj and add it to the solution

**Files:**
- Create `windows/src/AINotebook.App/AINotebook.App.csproj`
- Create `windows/src/AINotebook.App/app.manifest`
- Modify `windows/AINotebook.sln`

**Steps:**

1. Create `windows/src/AINotebook.App/AINotebook.App.csproj`. The `RuntimeIdentifier`/`Platforms`/self-contained settings mirror the grounded WinUI reference exactly (unpackaged + WASDK self-contained + .NET self-contained, min build 17763, win-x64):

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows10.0.19041.0</TargetFramework>
    <TargetPlatformMinVersion>10.0.17763.0</TargetPlatformMinVersion>
    <RootNamespace>AINotebook.App</RootNamespace>
    <ApplicationManifest>app.manifest</ApplicationManifest>
    <Platforms>x64</Platforms>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <UseWinUI>true</UseWinUI>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <ImplicitUsings>enable</ImplicitUsings>

    <!-- Unpackaged + fully self-contained (no WASDK runtime install, no .NET install) -->
    <WindowsPackageType>None</WindowsPackageType>
    <WindowsAppSDKSelfContained>true</WindowsAppSDKSelfContained>
    <SelfContained>true</SelfContained>
    <EnableMsixTooling>true</EnableMsixTooling>

    <!-- WinUI/WinRT source generators emit best with partial properties -->
    <WindowsSdkPackageVersion>10.0.19041.57</WindowsSdkPackageVersion>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" />
    <PackageReference Include="Microsoft.Extensions.DependencyInjection" Version="9.0.*" />
    <PackageReference Include="CommunityToolkit.Mvvm" Version="8.3.*" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\AINotebook.Core\AINotebook.Core.csproj" />
  </ItemGroup>

  <!-- Per-language .resw (M1) -->
  <ItemGroup>
    <PRIResource Include="Strings\**\*.resw" />
  </ItemGroup>

</Project>
```

2. Create `windows/src/AINotebook.App/app.manifest` (DPI + long-path awareness; no admin requirement):

```xml
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <assemblyIdentity version="1.0.0.0" name="AINotebook.App"/>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/> <!-- Windows 10/11 -->
    </application>
  </compatibility>
</assembly>
```

3. Add the project to `windows/AINotebook.sln`. Prefer the CLI on the Windows machine (avoids hand-editing GUIDs); this places it under the existing `src` solution folder is not done by `dotnet sln`, but the project will build fine flat:

```console
dotnet sln windows/AINotebook.sln add windows/src/AINotebook.App/AINotebook.App.csproj
```

4. **Verification (Windows):** Run `dotnet restore windows/AINotebook.sln`. Manually verify: restore completes; the three NuGet packages resolve; `AINotebook.App` appears in `dotnet sln windows/AINotebook.sln list`. (Do not expect a successful *build* yet — App.xaml is added in M0.2.)

5. Commit:

```console
git add windows/src/AINotebook.App/AINotebook.App.csproj windows/src/AINotebook.App/app.manifest windows/AINotebook.sln
git commit -m "$(cat <<'EOF'
chore(win): scaffold AINotebook.App (unpackaged self-contained WinUI 3) csproj

net10.0-windows10.0.19041.0, min 17763, win-x64; references the green
AINotebook.Core. Added to AINotebook.sln.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M0.2 — App.xaml + App.xaml.cs DI composition root (mirror AINotebookApp.swift init)

**Files:**
- Create `windows/src/AINotebook.App/App.xaml`
- Create `windows/src/AINotebook.App/App.xaml.cs`
- Create `windows/src/AINotebook.App/Services/ISettingsService.cs` (interface stub for DI; full body in M1)

> The three coordinator classes (`TabSwitchCoordinator`, `NoteJumpCoordinator`, `NoteEditorCoordinator`) are **defined** in M3.4 — not here. M0.2 only **registers** them as DI singletons (see step 2 and the `ConfigureServices` block below). Defining them once, in M3.4, keeps a single class definition each.

**Steps:**

1. The composition root must reproduce the **exact** order and wiring of `AINotebookApp.swift`'s `init()` (read it: `Sources/AINotebookApp/AINotebookApp.swift`). The mac order is:
   1. `settings = AppSettings()` (LocalSettings-backed in WinUI — body in M1; here we register the interface).
   2. `store = NotebookStore(StorePath.Production(), settings.Language)` — on failure the mac app `fatalError`s; in WinUI catch, show a fatal dialog, and exit. (Passing `settings.Language` localizes the Core-seeded built-in transformations; the ctor's `language` arg is optional and defaults to English.)
   3. `client = OllamaClient()` — **one shared instance** reused by Embedder/Retriever/ChatEngine/TransformationEngine/Onboarding.
   4. `embedder = Embedder(store, OllamaEmbeddingAdapter(client), settings.SelectedEmbeddingModel)`; `worker = EmbeddingWorker(embedder)`. **Bind the adapter, not the raw client** (the raw `OllamaClient.EmbedAsync` returns `double[][]`; `IEmbeddingProducing`/the adapter returns `float[][]` — the Core notes this mismatch explicitly).
   5. `ingestion = IngestionService(store, onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; })`.
   6. `indexer = NoteIndexer(store, onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; })`; wire `store.OnNoteSaved = noteId => indexer.IndexAsync(noteId)` (mac wires `onNoteSaved`).
   7. `onboarding = OnboardingViewModel(client, settings)` — created in Plan 3; registered here as `AddTransient` so DI can resolve it once Plan 3 lands. **Plan 2 registers a placeholder** only if needed; to keep Plan 2 compiling without Plan 3 types, we do **not** register `OnboardingViewModel` here — M0.3's router checks `HasCompletedOnboarding` and shows a temporary placeholder until Plan 3 supplies the page. (Documented so Plan 3 wires it.)
   8. `retriever = Retriever(store, OllamaEmbeddingAdapter(client), settings.SelectedEmbeddingModel)`.
   9. `engine = ChatEngine(store, retriever, OllamaChatAdapter(client), settings.SelectedChatModel)`.
   10. `txEngine = TransformationEngine(store, OllamaChatAdapter(client), settings.SelectedChatModel)`.
   11. `attachments = AttachmentStore(store, AttachmentStore.DefaultRoot())`; wire `store.OnNoteDeleted = uuid => DispatcherQueue.TryEnqueue(() => attachments.DeleteFolder(uuid))`.

   > **Threading contract (from the Core binding notes):** `OnNoteSaved`/`OnNoteDeleted` fire **un-awaited off any guaranteed thread**; marshal anything that touches the store or UI through `DispatcherQueue.TryEnqueue`. `NotebookStore` is single-connection and **not thread-safe** — funnel store mutations through the UI thread. `EmbeddingWorker.Kick()` is safe to call from the UI thread (work runs on a pool thread).

2. The three coordinator singletons (`TabSwitchCoordinator`, `NoteJumpCoordinator`, `NoteEditorCoordinator`) are **defined in M3.4** (they port the mac `TabSwitchCoordinator`/`NoteJumpCoordinator`/`NoteEditorCoordinator` and have no Core dependency). M0.2 does **not** redefine them — it only registers them as DI singletons in `ConfigureServices` (below). This keeps exactly one class definition each (in M3.4). M2.3 consumes `TabSwitchCoordinator` via its mac-faithful nested `TabSwitchCoordinator.Tab` enum.

   > **Ordering note:** M3.4's coordinators are pure `CommunityToolkit.Mvvm.ObservableObject` types with no other dependency, so the M0.2 `AddSingleton<TabSwitchCoordinator>()` / `<NoteJumpCoordinator>()` / `<NoteEditorCoordinator>()` registrations resolve them once those files exist (M3.4). If you build M0–M2 before M3.4, temporarily stub the three classes or move M3.4 earlier; the final composition is unchanged.

3. `windows/src/AINotebook.App/Services/ISettingsService.cs` — interface only (body in M1; the composition root needs the type now to read `SelectedChatModel`/`SelectedEmbeddingModel`/`HasCompletedOnboarding`):
```csharp
using System.ComponentModel;
using AINotebook.Core;

namespace AINotebook.App.Services;

/// Port of the mac AppSettings (UserDefaults-backed) over ApplicationData.LocalSettings.
public interface ISettingsService : INotifyPropertyChanged
{
    AppLanguage Language { get; set; }
    bool HasCompletedOnboarding { get; set; }
    string SelectedChatModel { get; set; }      // default "llama3.2:3b"
    string SelectedEmbeddingModel { get; set; } // default "nomic-embed-text"
}
```

4. `windows/src/AINotebook.App/App.xaml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<Application
    x:Class="AINotebook.App.App"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Application.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <XamlControlsResources xmlns="using:Microsoft.UI.Xaml.Controls" />
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Application.Resources>
</Application>
```

5. `windows/src/AINotebook.App/App.xaml.cs` — the composition root. (`SettingsService`/`LocalizedStrings` are referenced here but their bodies land in M1; this file compiles only after M1 because of those two `AddSingleton` lines. To keep M0 independently buildable, M0.2 registers `SettingsService` and `LocalizedStrings` with **temporary inline minimal implementations** is avoided — instead, M0.2 references the interfaces and M1 supplies the implementations; the build-green checkpoint is the **end of M1**. M0.2's verification is restore + the file existing, M0.3 adds the window, and M1 makes the whole thing build.) Full file:

```csharp
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Extractors;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AINotebook.App;

public partial class App : Application
{
    public static App Current => (App)Application.Current;
    public IServiceProvider Services { get; }
    public static Window MainWindow { get; private set; } = null!;

    // Captured so background Core callbacks can marshal to the UI thread.
    public static DispatcherQueue Ui { get; private set; } = null!;

    public App()
    {
        InitializeComponent();
        Services = ConfigureServices();
    }

    private static IServiceProvider ConfigureServices()
    {
        var services = new ServiceCollection();

        // --- App-layer services (singletons) ---
        services.AddSingleton<ISettingsService, SettingsService>();          // M1
        services.AddSingleton<LocalizedStrings>();                           // M1 (concrete)
        services.AddSingleton<ILocalizedStrings>(sp => sp.GetRequiredService<LocalizedStrings>()); // same singleton via the interface
        services.AddSingleton<IDialogService, DialogService>();              // M2
        services.AddSingleton<TabSwitchCoordinator>();   // class defined in M3.4
        services.AddSingleton<NoteJumpCoordinator>();    // class defined in M3.4
        services.AddSingleton<NoteEditorCoordinator>();  // class defined in M3.4

        // --- Core service graph, in AINotebookApp.swift init() order ---

        // 2. Data store (fatal on failure, like the mac fatalError).
        //    Pass the persisted language so Core's BuiltinTransformations.SeedIfNeeded
        //    seeds the built-in transformations localized (NotebookStore's optional
        //    `language` ctor arg; defaults to English if omitted).
        services.AddSingleton<NotebookStore>(sp =>
        {
            try { return new NotebookStore(StorePath.Production(), sp.GetRequiredService<ISettingsService>().Language); }
            catch (Exception ex) { throw new StartupException("Failed to open AINotebook database.", ex); }
        });

        // 3. One shared OllamaClient reused by every consumer below.
        services.AddSingleton<OllamaClient>();

        // 4. Embedder + EmbeddingWorker (bind the ADAPTER, not the raw client).
        services.AddSingleton<Embedder>(sp => new Embedder(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaEmbeddingAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedEmbeddingModel));
        services.AddSingleton<EmbeddingWorker>(sp =>
            new EmbeddingWorker(sp.GetRequiredService<Embedder>()));

        // 5. Ingestion -> kick the worker after chunks are written.
        services.AddSingleton<IngestionService>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new IngestionService(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // 6. NoteIndexer -> kick worker; wire store.OnNoteSaved.
        services.AddSingleton<NoteIndexer>(sp =>
        {
            var worker = sp.GetRequiredService<EmbeddingWorker>();
            return new NoteIndexer(
                sp.GetRequiredService<NotebookStore>(),
                onChunksWritten: () => { worker.Kick(); return Task.CompletedTask; });
        });

        // 8. Retriever (adapter again).
        services.AddSingleton<Retriever>(sp => new Retriever(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaEmbeddingAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedEmbeddingModel));

        // 9. ChatEngine (chat adapter).
        services.AddSingleton<ChatEngine>(sp => new ChatEngine(
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<Retriever>(),
            new OllamaChatAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        // 10. TransformationEngine (chat adapter).
        services.AddSingleton<TransformationEngine>(sp => new TransformationEngine(
            sp.GetRequiredService<NotebookStore>(),
            new OllamaChatAdapter(sp.GetRequiredService<OllamaClient>()),
            sp.GetRequiredService<ISettingsService>().SelectedChatModel));

        // 11. AttachmentStore + OnNoteDeleted wiring.
        services.AddSingleton<AttachmentStore>(sp => new AttachmentStore(
            sp.GetRequiredService<NotebookStore>(), AttachmentStore.DefaultRoot()));

        // ViewModels (fresh per request).
        services.AddTransient<ShellViewModel>();
        services.AddTransient<NotebookSidebarViewModel>();
        services.AddTransient<NotebookDetailViewModel>();

        return services.BuildServiceProvider();
    }

    /// Resolve, then wire the cross-service store callbacks once
    /// (NoteIndexer/AttachmentStore depend on the store the callbacks reference).
    private void WireStoreCallbacks()
    {
        var store = Services.GetRequiredService<NotebookStore>();
        var indexer = Services.GetRequiredService<NoteIndexer>();
        var attachments = Services.GetRequiredService<AttachmentStore>();

        // Fired un-awaited off any thread; IndexAsync touches the store, so marshal.
        store.OnNoteSaved = noteId =>
        {
            Ui.TryEnqueue(async () =>
            {
                try { await indexer.IndexAsync(noteId); }
                catch (Exception ex) { System.Diagnostics.Debug.WriteLine($"NoteIndexer: {ex}"); }
            });
            return Task.CompletedTask;
        };
        store.OnNoteDeleted = uuid =>
        {
            Ui.TryEnqueue(() => { try { attachments.DeleteFolder(uuid); } catch { /* best effort */ } });
            return Task.CompletedTask;
        };

        // Touch the worker/ingestion graph so singletons are constructed eagerly.
        _ = Services.GetRequiredService<EmbeddingWorker>();
        _ = Services.GetRequiredService<IngestionService>();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Ui = DispatcherQueue.GetForCurrentThread();
        WireStoreCallbacks();
        MainWindow = new MainWindow();
        MainWindow.Activate();
    }
}

/// Wraps a fatal startup failure (the mac fatalError equivalent).
public sealed class StartupException : Exception
{
    public StartupException(string message, Exception inner) : base(message, inner) { }
}
```

> **Note on the `IndexAsync` method name:** the binding contract lists `NoteIndexer` with `onChunksWritten` and an indexing method; confirm the exact public method name on the built type (`grep -rn "public.*Task.*Index" windows/src/AINotebook.Core/Rag/NoteIndexer.cs`) and adjust the `store.OnNoteSaved` call to match (the mac calls `indexer.index(noteId:)`). Do not modify the Core — only call its public method.

6. **Verification (Windows):** `dotnet restore`. The project will not fully build until M1 supplies `SettingsService`/`LocalizedStrings`/`IDialogService` and M0.3 adds `MainWindow`. Manually verify: `App.xaml.cs` references resolve against `AINotebook.Core` (namespaces `AINotebook.Core`, `.Ollama`, `.Rag`, `.Storage`, `.Ingestion`, `.Extractors`) — i.e., the Core types `NotebookStore`, `StorePath`, `OllamaClient`, `OllamaEmbeddingAdapter`, `OllamaChatAdapter`, `Embedder`, `EmbeddingWorker`, `IngestionService`, `NoteIndexer`, `Retriever`, `ChatEngine`, `TransformationEngine`, `AttachmentStore` all exist with the constructor signatures used above. (Verify with `grep -rn "public .*ctor\|public NotebookStore\|public Retriever\|public ChatEngine" windows/src/AINotebook.Core` before/while writing.)

7. Commit:

```console
git add windows/src/AINotebook.App/App.xaml windows/src/AINotebook.App/App.xaml.cs windows/src/AINotebook.App/Services/
git commit -m "$(cat <<'EOF'
feat(win): DI composition root mirroring AINotebookApp.swift init

Builds the Core service graph (NotebookStore via StorePath.Production,
shared OllamaClient, Embedder+EmbeddingWorker via the embedding adapter,
IngestionService, NoteIndexer, Retriever, ChatEngine, TransformationEngine,
AttachmentStore) in the mac init order; marshals OnNoteSaved/OnNoteDeleted
to the UI thread. Registers the TabSwitch/NoteJump/NoteEditor coordinator
singletons (classes defined in M3.4) and the ISettingsService DI seam.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M0.3 — Blank MainWindow that routes onboarding-or-shell

**Files:**
- Create `windows/src/AINotebook.App/MainWindow.xaml`
- Create `windows/src/AINotebook.App/MainWindow.xaml.cs`

**Steps:**

1. `MainWindow` ports the mac `ContentView` router: if `HasCompletedOnboarding == false` show onboarding, else the shell. (Onboarding page lands in Plan 3; Plan 2 shows a labeled placeholder so the router is testable now.) The mac sets a minimum window size of 900×600.

`windows/src/AINotebook.App/MainWindow.xaml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<Window
    x:Class="AINotebook.App.MainWindow"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid x:Name="RootHost" />
</Window>
```

`windows/src/AINotebook.App/MainWindow.xaml.cs`:
```csharp
using AINotebook.App.Services;
using AINotebook.App.Views;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace AINotebook.App;

public sealed partial class MainWindow : Window
{
    private readonly ISettingsService _settings;

    public MainWindow()
    {
        InitializeComponent();
        _settings = App.Current.Services.GetRequiredService<ISettingsService>();

        Title = "AI Notebook";
        ApplyMinSize();

        _settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ISettingsService.HasCompletedOnboarding))
                App.Ui.TryEnqueue(Route);
        };

        Route();
    }

    private void ApplyMinSize()
    {
        // Mirror the mac .frame(minWidth: 900, minHeight: 600) initial size.
        AppWindow.Resize(new SizeInt32(1100, 760));
    }

    private void Route()
    {
        if (!_settings.HasCompletedOnboarding)
        {
            // Plan 3 swaps this placeholder for OnboardingPage.
            RootHost.Children.Clear();
            RootHost.Children.Add(new TextBlock
            {
                Text = "Onboarding (Plan 3)",
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            });
        }
        else
        {
            RootHost.Children.Clear();
            RootHost.Children.Add(new ShellPage());
        }
    }
}
```

> `ShellPage` is created in M2. Until then, in M0.3 the `else` branch can temporarily host a `TextBlock { Text = "Shell (M2)" }`; the M2 task replaces it with `new ShellPage()`. Use the placeholder for M0.3's build, then update in M2.1.

2. **Verification (Windows):** After M1 lands (which makes `SettingsService` real), `dotnet build windows/src/AINotebook.App`. Manually verify: app launches, a 1100×760 window titled "AI Notebook" appears. With a fresh profile (no `HasCompletedOnboarding` key) it shows "Onboarding (Plan 3)". Manually set the LocalSettings flag (or use the M1 settings) and relaunch → shows the shell placeholder. The window cannot be resized below a usable size.

3. Commit:

```console
git add windows/src/AINotebook.App/MainWindow.xaml windows/src/AINotebook.App/MainWindow.xaml.cs
git commit -m "$(cat <<'EOF'
feat(win): MainWindow root router (onboarding-or-shell) + 1100x760 default

Ports ContentView's top-level switch on HasCompletedOnboarding; re-routes
live when the flag changes. Placeholders stand in for OnboardingPage (Plan 3)
and ShellPage (M2).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Milestone M1 — Localization (.resw EN/CZ + runtime switch)

Goal: a `LocalizedStrings` service + a `SettingsService` over `LocalSettings`, two `.resw` files seeded verbatim from the mac `AppText` 148 keys, an initial language picked via `LocaleDetection.DetectInitialLanguage`, and a runtime switch via `ApplicationLanguages.PrimaryLanguageOverride`. After this milestone the project **builds green**.

### Task M1.1 — SettingsService over ApplicationData.LocalSettings

**Files:**
- Create `windows/src/AINotebook.App/Services/SettingsService.cs`

**Steps:**

1. Port the mac `AppSettings` (`Sources/AINotebookCore/AppSettings.swift`): `@Published` `language`, `hasCompletedOnboarding`, `selectedChatModel` (default `"llama3.2:3b"`), `selectedEmbeddingModel` (default `"nomic-embed-text"`), each persisting on set. The WinUI backing store is `ApplicationData.Current.LocalSettings`. Initial language = `LocaleDetection.DetectInitialLanguage(ApplicationLanguages.Languages)` if no stored value (the Core helper returns `Czech` when any preferred language starts with "cs", else `English`).

```csharp
using System.Runtime.CompilerServices;
using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;
using Windows.Globalization;
using Windows.Storage;

namespace AINotebook.App.Services;

public sealed partial class SettingsService : ObservableObject, ISettingsService
{
    private readonly ApplicationDataContainer _store = ApplicationData.Current.LocalSettings;

    private const string KeyLanguage = "language";
    private const string KeyOnboarding = "hasCompletedOnboarding";
    private const string KeyChatModel = "selectedChatModel";
    private const string KeyEmbeddingModel = "selectedEmbeddingModel";

    public SettingsService()
    {
        // Initial language: stored value, else Core locale detection over preferred langs.
        var stored = _store.Values[KeyLanguage] as string;
        _language = AppLanguageExtensions.FromRawValue(stored ?? "")
            ?? LocaleDetection.DetectInitialLanguage(ApplicationLanguages.Languages);

        _hasCompletedOnboarding = _store.Values[KeyOnboarding] as bool? ?? false;
        _selectedChatModel = _store.Values[KeyChatModel] as string ?? "llama3.2:3b";
        _selectedEmbeddingModel = _store.Values[KeyEmbeddingModel] as string ?? "nomic-embed-text";
    }

    private AppLanguage _language;
    public AppLanguage Language
    {
        get => _language;
        set { if (SetField(ref _language, value)) _store.Values[KeyLanguage] = value.RawValue(); }
    }

    private bool _hasCompletedOnboarding;
    public bool HasCompletedOnboarding
    {
        get => _hasCompletedOnboarding;
        set { if (SetField(ref _hasCompletedOnboarding, value)) _store.Values[KeyOnboarding] = value; }
    }

    private string _selectedChatModel;
    public string SelectedChatModel
    {
        get => _selectedChatModel;
        set { if (SetField(ref _selectedChatModel, value)) _store.Values[KeyChatModel] = value; }
    }

    private string _selectedEmbeddingModel;
    public string SelectedEmbeddingModel
    {
        get => _selectedEmbeddingModel;
        set { if (SetField(ref _selectedEmbeddingModel, value)) _store.Values[KeyEmbeddingModel] = value; }
    }

    private bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}
```

> `AppLanguageExtensions.RawValue` returns "en"/"cs"; `FromRawValue` returns `AppLanguage?` (null on unknown, never throws) — both are public Core API. `Language` stores the raw value so re-reads round-trip.

2. **Verification (Windows):** Covered by the M1.3 build + the M1.2 service. Manual: launching, toggling `HasCompletedOnboarding`, and relaunching persists across runs (LocalSettings is per-user roaming-local).

3. Commit:

```console
git add windows/src/AINotebook.App/Services/SettingsService.cs
git commit -m "$(cat <<'EOF'
feat(win): SettingsService over LocalSettings (AppSettings port)

language/hasCompletedOnboarding/selectedChatModel/selectedEmbeddingModel with
persistence; initial language via Core LocaleDetection.DetectInitialLanguage.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M1.2 — LocalizedStrings service + runtime language switch + DialogService

**Files:**
- Create `windows/src/AINotebook.App/Services/ILocalizedStrings.cs`
- Create `windows/src/AINotebook.App/Services/LocalizedStrings.cs`
- Create `windows/src/AINotebook.App/Services/IDialogService.cs`
- Create `windows/src/AINotebook.App/Services/DialogService.cs`

**Steps:**

1. `LocalizedStrings` is the `AppText` analogue: it looks up a key in the `.resw` and re-resolves when `Language` changes. We key resources by the **mac `AppText.Key` case names** (e.g. `noNotebookSelected`) so the call sites read identically to SwiftUI (`text.string(.noNotebookSelected)` → `L["noNotebookSelected"]`). Runtime switching uses `ApplicationLanguages.PrimaryLanguageOverride` + an explicit `ResourceContext` so lookups don't require an app restart. The service raises a property-change so bound XAML re-pulls.

`windows/src/AINotebook.App/Services/ILocalizedStrings.cs`:
```csharp
using System.ComponentModel;
using AINotebook.Core;

namespace AINotebook.App.Services;

public interface ILocalizedStrings : INotifyPropertyChanged
{
    /// Lookup by the mac AppText.Key case name (e.g. "noNotebookSelected").
    string this[string key] { get; }
    string Get(string key);
    /// Compile-time-checked lookup by the StringKey enum (PascalCase mirror of the
    /// mac AppText.Key cases). Used by the onboarding/sources/settings tasks (M3.5/
    /// M3.6/M4/M9). Maps StringKey -> the camelCase .resw key, then calls Get(string).
    string Get(StringKey key);
    void SetLanguage(AppLanguage language);
}
```

> **`StringKey` enum (merged from the original M3 draft).** A compile-time-checked mirror of the 148 mac `AppText.Key` cases in PascalCase, so call-sites can write `Get(StringKey.NoNotebookSelected)` instead of a stringly-typed `["noNotebookSelected"]`. It is a thin convenience over the same `.resw` source — `Get(StringKey)` lower-camel-cases the enum name and delegates to `Get(string)`. Create `windows/src/AINotebook.App/Services/StringKey.cs` with all 148 PascalCase names (one per `.resw` key). Both lookup forms resolve against the same `.resw`; no second copy of the strings exists.

```csharp
namespace AINotebook.App.Services;

/// <summary>PascalCase mirror of the mac AppText.Key cases (148). Convenience for
/// compile-time-checked lookups; resolves to the same .resw entry as the string key.</summary>
public enum StringKey
{
    AppName, Settings, Language, Version, Notebooks, Sources, Chat, Notes, Transformations,
    NoNotebookSelected, CreateNotebook, RenameNotebook, DeleteNotebook, NotebookName,
    NotebookDescription, /* … all 148 PascalCase names, 1:1 with the .resw keys … */
}
```

`windows/src/AINotebook.App/Services/LocalizedStrings.cs`:
```csharp
using System.ComponentModel;
using AINotebook.Core;
using Microsoft.Windows.ApplicationModel.Resources;
using Windows.Globalization;

namespace AINotebook.App.Services;

public sealed class LocalizedStrings : ILocalizedStrings
{
    private readonly ResourceManager _rm = new();
    private ResourceContext _ctx;
    private ResourceMap _map;

    public event PropertyChangedEventHandler? PropertyChanged;

    public LocalizedStrings(ISettingsService settings)
    {
        _ctx = _rm.CreateResourceContext();
        _map = _rm.MainResourceMap.GetSubtree("Resources");
        SetLanguage(settings.Language);

        // Live-switch when the user changes language in Settings.
        settings.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ISettingsService.Language))
                SetLanguage(settings.Language);
        };
    }

    public void SetLanguage(AppLanguage language)
    {
        var bcp47 = language == AppLanguage.Czech ? "cs-CZ" : "en-US";
        ApplicationLanguages.PrimaryLanguageOverride = bcp47;
        _ctx = _rm.CreateResourceContext();
        _ctx.QualifierValues["Language"] = bcp47;
        // Notify all bindings on the indexer to re-pull every visible string.
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs("Item[]"));
    }

    public string this[string key] => Get(key);

    public string Get(string key)
    {
        try { return _map.GetValue(key, _ctx).ValueAsString; }
        catch { return key; } // fall back to the key name if missing (dev-visible)
    }

    // Convenience: StringKey (PascalCase) -> camelCase .resw key -> Get(string).
    public string Get(StringKey key)
    {
        var name = key.ToString();
        var camel = char.ToLowerInvariant(name[0]) + name[1..];
        return Get(camel);
    }
}
```

> WinUI binding to `string this[string]` uses `{Binding Path=[noNotebookSelected]}`; raising `PropertyChanged("Item[]")` re-evaluates all indexer bindings on language change.

2. `IDialogService`/`DialogService` is the shared `ContentDialog` helper used by M2's notebook dialogs (and Plan 3's confirmations). `ContentDialog` needs a `XamlRoot`, so the caller passes the page's `XamlRoot`.

`windows/src/AINotebook.App/Services/IDialogService.cs`:
```csharp
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Services;

public interface IDialogService
{
    Task<bool> ConfirmAsync(XamlRoot root, string title, string message,
                            string primaryText, string cancelText, bool destructive = false);
    Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot root);
}
```

`windows/src/AINotebook.App/Services/DialogService.cs`:
```csharp
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Services;

public sealed class DialogService : IDialogService
{
    public async Task<bool> ConfirmAsync(XamlRoot root, string title, string message,
                                         string primaryText, string cancelText, bool destructive = false)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = root,
            Title = title,
            Content = message,
            PrimaryButtonText = primaryText,
            CloseButtonText = cancelText,
            DefaultButton = ContentDialogButton.Close
        };
        if (destructive)
            dialog.PrimaryButtonStyle = (Style)Application.Current.Resources["AccentButtonStyle"];
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    public async Task<ContentDialogResult> ShowAsync(ContentDialog dialog, XamlRoot root)
    {
        dialog.XamlRoot = root;
        return await dialog.ShowAsync();
    }
}
```

3. **Verification (Windows):** Build-green checkpoint is M1.3. Manual: in M2, switching language updates every visible label live (no restart).

4. Commit:

```console
git add windows/src/AINotebook.App/Services/ILocalizedStrings.cs windows/src/AINotebook.App/Services/LocalizedStrings.cs windows/src/AINotebook.App/Services/IDialogService.cs windows/src/AINotebook.App/Services/DialogService.cs
git commit -m "$(cat <<'EOF'
feat(win): LocalizedStrings (AppText port) + DialogService

Keyed by mac AppText.Key case names; runtime language switch via
PrimaryLanguageOverride + ResourceContext, raising Item[] so bound XAML
re-pulls without restart. DialogService wraps ContentDialog (XamlRoot).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M1.3 — Seed Strings/en-US + cs-CZ Resources.resw from the mac AppText (148 keys) + xUnit test project

**Files:**
- Create `windows/src/AINotebook.App/Strings/en-US/Resources.resw`
- Create `windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw`
- Create `windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj`
- Create `windows/tests/AINotebook.App.Tests/LocalizedStringsTests.cs`
- Modify `windows/AINotebook.sln`

**Steps:**

1. **Source of truth:** `Sources/AINotebookCore/Localization.swift`. It defines `enum AppText.Key` with **148 unique cases** (lines 1–158), an English table `private func english(_:)` (lines 168–320), and a Czech table `private func czech(_:)` (lines 321–472). Each `.resw` entry's `name` = the Swift case name (camelCase, e.g. `noNotebookSelected`); the EN value = the English table string; the CS value = the Czech table string. Port **all 148** verbatim — do not invent or paraphrase copy.

2. **Mechanical port (do this on the Windows machine, or any machine with the repo).** A `.resw` is an XML `.resx`-format file. Generate both files from `Localization.swift` rather than hand-typing 296 strings. A throwaway script (run once; not committed) extracts the case→string mapping per table and emits the two `.resw`. Pseudocode of the extraction (keys come from the `Key` enum order; EN/CS from each `switch` body):

```
for each `case .<name>: "<value>"` line in english(...): emit <data name="<name>"><value><value></data> to en-US/Resources.resw
for each `case .<name>: "<value>"` line in czech(...):   emit <data name="<name>"><value><value></data> to cs-CZ/Resources.resw
```

   `.resw` skeleton each generated file must follow (standard ResX header, then one `<data>` per key):

```xml
<?xml version="1.0" encoding="utf-8"?>
<root>
  <resheader name="resmimetype"><value>text/microsoft-resx</value></resheader>
  <resheader name="version"><value>2.0</value></resheader>
  <resheader name="reader"><value>System.Resources.ResXResourceReader, System.Windows.Forms, ...</value></resheader>
  <resheader name="writer"><value>System.Resources.ResXResourceWriter, System.Windows.Forms, ...</value></resheader>

  <data name="appName" xml:space="preserve"><value>AI Notebook</value></data>
  <data name="settings" xml:space="preserve"><value>Settings</value></data>
  <data name="noNotebookSelected" xml:space="preserve"><value>No notebook selected</value></data>
  <!-- ... all 148 keys ... -->
</root>
```

3. **Representative mapping table** (the first 15 keys, verbatim from `Localization.swift`; the script ports the remaining 133 identically). EN values are the `english(...)` strings, CS values the `czech(...)` strings:

| `.resw` name (= Swift case) | en-US value | cs-CZ value |
|---|---|---|
| `appName` | AI Notebook | AI Notebook |
| `settings` | Settings | Nastavení |
| `language` | Language | Jazyk |
| `version` | Version | Verze |
| `notebooks` | Notebooks | Poznámkové bloky |
| `sources` | Sources | Zdroje |
| `chat` | Chat | Chat |
| `notes` | Notes | Poznámky |
| `transformations` | Transformations | Transformace |
| `noNotebookSelected` | No notebook selected | Žádný blok není vybrán |
| `createNotebook` | Create notebook | Vytvořit blok |
| `renameNotebook` | Rename notebook | Přejmenovat blok |
| `deleteNotebook` | Delete notebook | Smazat blok |
| `notebookName` | Notebook name | Název bloku |
| `notebookDescription` | Description (optional) | Popis (volitelný) |

   Remaining keys to port from the same file (the full 148 includes, in order, the onboarding strings `welcome`, `welcomeBody`, `continueLabel`, `onboardingDetectTitle`…`startUsingApp`; the sources strings `sourcesSectionTitle`, `addSourceButton`, `addSourceSheetTitle`, `addSourceFromFile`/`URL`/`Text`, status strings, etc.; chat, notes, transformations, and settings strings). **Port every `case` in both `english(...)` and `czech(...)`** — the case list is authoritative; a key present in the enum but missing from a `.resw` must be treated as a port bug.

4. **Port-completeness guard:** after generating, assert both files contain exactly 148 `<data>` entries and the same set of names:

```console
# On any machine with the repo:
grep -c "<data name=" windows/src/AINotebook.App/Strings/en-US/Resources.resw   # expect 148
grep -c "<data name=" windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw   # expect 148
diff <(grep -o 'name="[^"]*"' windows/src/AINotebook.App/Strings/en-US/Resources.resw | sort) \
     <(grep -o 'name="[^"]*"' windows/src/AINotebook.App/Strings/cs-CZ/Resources.resw | sort)   # expect no diff
# Cross-check against the Swift enum case count:
grep -c "^        case " <(sed -n '1,158p' Sources/AINotebookCore/Localization.swift)            # expect 148
```

5. **xUnit test project** for the WinUI-free localization invariant. The `LocalizedStrings` lookup itself needs WASDK `ResourceManager` (a WinUI type), so the unit test instead validates the **port-completeness contract** against the raw `.resw` XML and the Swift source — pure file/XML logic, no WinUI types.

`windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj`:
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.*" />
    <PackageReference Include="xunit" Version="2.*" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.*" />
  </ItemGroup>
  <ItemGroup>
    <!-- Resolve the .resw + Swift source by repo-relative path at test time. -->
    <None Include="..\..\src\AINotebook.App\Strings\en-US\Resources.resw" CopyToOutputDirectory="PreserveNewest" Link="en.resw" />
    <None Include="..\..\src\AINotebook.App\Strings\cs-CZ\Resources.resw" CopyToOutputDirectory="PreserveNewest" Link="cs.resw" />
  </ItemGroup>
</Project>
```

`windows/tests/AINotebook.App.Tests/LocalizedStringsTests.cs`:
```csharp
using System.Xml.Linq;
using Xunit;

namespace AINotebook.App.Tests;

public class LocalizedStringsTests
{
    private static HashSet<string> Names(string reswPath) =>
        XDocument.Load(reswPath).Root!
            .Elements("data")
            .Select(d => (string)d.Attribute("name")!)
            .ToHashSet();

    // NOTE: requires WinUI? No — pure XML. Runs anywhere with .NET (incl. Windows CI).
    [Fact]
    public void Both_languages_have_the_same_148_keys()
    {
        var en = Names("en.resw");
        var cs = Names("cs.resw");

        Assert.Equal(148, en.Count);
        Assert.Equal(148, cs.Count);
        Assert.True(en.SetEquals(cs), "en-US and cs-CZ must define the identical key set");
    }

    [Fact]
    public void No_value_is_empty()
    {
        foreach (var path in new[] { "en.resw", "cs.resw" })
            foreach (var d in XDocument.Load(path).Root!.Elements("data"))
                Assert.False(string.IsNullOrWhiteSpace((string?)d.Element("value")),
                    $"{path}: '{(string?)d.Attribute("name")}' has no value");
    }
}
```

> Per the plan rules: this xUnit test is pure XML/`System.Xml.Linq` and does **not** reference WinUI types, so it is genuinely runnable (on the Windows CI / build machine). Do **not** claim it runs on the macOS authoring box — run it on Windows.

6. Add the test project to the solution:
```console
dotnet sln windows/AINotebook.sln add windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj
```

7. **Verification (Windows):**
   - `dotnet build windows/src/AINotebook.App` — **first green build** of the App (App.xaml.cs's `SettingsService`/`LocalizedStrings`/`DialogService` now exist; `.resw` compile into the PRI).
   - `dotnet test windows/tests/AINotebook.App.Tests` — both facts pass (148 keys each, identical key sets, no empty values).
   - `dotnet run --project windows/src/AINotebook.App` — launches; the onboarding/shell placeholder text renders (M2 will make real text localized). Set the system display language / `PrimaryLanguageOverride` and confirm a localized lookup (e.g. wire a temporary `TextBlock Text="{Binding [notebooks]}"` against `LocalizedStrings`, observe "Notebooks" vs "Poznámkové bloky").

8. Commit:

```console
git add windows/src/AINotebook.App/Strings windows/tests/AINotebook.App.Tests windows/AINotebook.sln
git commit -m "$(cat <<'EOF'
feat(win): seed en-US/cs-CZ Resources.resw from mac AppText (148 keys) + tests

Ported every AppText.Key case from Localization.swift into per-language .resw
(EN + CS verbatim). xUnit guards key-set parity (148==148, identical names,
no empty values). Build-green checkpoint for AINotebook.App.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Milestone M2 — App shell (sidebar + 4-tab detail)

Goal: `MainWindow` → `ShellPage` with a `NavigationView` notebook sidebar (list/new/rename/delete via Core `Notebooks()`/`CreateNotebook`/`RenameNotebook`/`DeleteNotebook` + `ContentDialog`s) and a detail area hosting `NotebookDetailPage` (header + 4-tab switcher) bound to the selected notebook, with `TabSwitchCoordinator` wired. Mirrors `ContentView.swift` + `SidebarView.swift` + `NotebookDetailView.swift`.

### Task M2.1 — NotebookSidebarViewModel + ShellViewModel + ShellPage (NavigationView master/detail)

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/NotebookSidebarViewModel.cs`
- Create `windows/src/AINotebook.App/ViewModels/ShellViewModel.cs`
- Create `windows/src/AINotebook.App/Views/ShellPage.xaml`
- Create `windows/src/AINotebook.App/Views/ShellPage.xaml.cs`
- Modify `windows/src/AINotebook.App/MainWindow.xaml.cs` (swap shell placeholder for `new ShellPage()`)

**Steps:**

1. `NotebookSidebarViewModel` ports `SidebarView`: an `ObservableCollection<Notebook>` loaded from `store.Notebooks()` (ordered updated_at DESC), a `SelectedNotebookId` (the mac `selection: Int64?`), and create/rename/delete intents. The store is **single-threaded** — all calls happen on the UI thread (the VM lives on it). Auto-select a newly created notebook (mac `NewNotebookSheet` callback sets `selection = created.id`). On delete, if the deleted id was selected, clear selection (mac `performDelete`).

```csharp
using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class NotebookSidebarViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _l;

    public ObservableCollection<Notebook> Notebooks { get; } = new();

    [ObservableProperty]
    public partial long? SelectedNotebookId { get; set; }

    public NotebookSidebarViewModel(NotebookStore store, ILocalizedStrings l)
    {
        _store = store;
        _l = l;
        Reload();
    }

    public void Reload()
    {
        var current = SelectedNotebookId;
        Notebooks.Clear();
        foreach (var nb in _store.Notebooks()) Notebooks.Add(nb);
        // Keep selection if it still exists, else clear.
        if (current is long id && Notebooks.All(n => n.Id != id))
            SelectedNotebookId = null;
    }

    /// Called by the New dialog on success: insert + select.
    public void OnCreated(Notebook created)
    {
        Reload();
        SelectedNotebookId = created.Id;
    }

    public void OnRenamed() => Reload();

    [RelayCommand]
    private void Delete(long id)
    {
        try
        {
            _store.DeleteNotebook(id);
            if (SelectedNotebookId == id) SelectedNotebookId = null;
            Reload();
        }
        catch (StoreException)
        {
            // mac sets deleteError but does not render it (non-blocking); mirror: ignore.
        }
    }
}
```

> `Notebook.Id` is `long?` (the record is `Notebook(long? Id, ...)`); the sidebar only lists notebooks with non-null id (mac filters `id != nil`). Guard `n.Id` in the XAML/command path.

2. `ShellViewModel` holds the sidebar VM and exposes the currently selected `Notebook` (re-resolved from the live collection each time selection changes, mirroring the mac detail re-lookup so renames reflect live):

```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class ShellViewModel : ObservableObject
{
    public NotebookSidebarViewModel Sidebar { get; }
    private readonly ILocalizedStrings _l;

    [ObservableProperty]
    public partial Notebook? SelectedNotebook { get; private set; }

    public string NoNotebookSelectedText => _l["noNotebookSelected"];

    public ShellViewModel(NotebookSidebarViewModel sidebar, ILocalizedStrings l)
    {
        Sidebar = sidebar;
        _l = l;
        Sidebar.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookSidebarViewModel.SelectedNotebookId))
                ResolveSelected();
        };
        _l.PropertyChanged += (_, _) => OnPropertyChanged(nameof(NoNotebookSelectedText));
        ResolveSelected();
    }

    private void ResolveSelected()
    {
        var id = Sidebar.SelectedNotebookId;
        SelectedNotebook = id is null ? null : Sidebar.Notebooks.FirstOrDefault(n => n.Id == id);
    }
}
```

3. `ShellPage.xaml` — a `NavigationView` (PaneDisplayMode Left) whose pane is the notebook list (`ListView` two-way bound to `SelectedNotebookId`), a "+" pane footer button to create, a per-item `MenuFlyout` (Rename / Delete), and a content area that hosts `NotebookDetailPage` or the localized empty state (mac `doc.text.magnifyingglass` + `.noNotebookSelected`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<Page
    x:Class="AINotebook.App.Views.ShellPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:muxc="using:Microsoft.UI.Xaml.Controls"
    xmlns:core="using:AINotebook.Core"
    mc:Ignorable="d"
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006">

    <muxc:NavigationView x:Name="Nav"
        PaneDisplayMode="Left"
        IsBackButtonVisible="Collapsed"
        IsSettingsVisible="False"
        OpenPaneLength="260">

        <muxc:NavigationView.PaneHeader>
            <TextBlock Text="{Binding [notebooks]}" Style="{StaticResource BodyStrongTextBlockStyle}"
                       Margin="12,8" />
        </muxc:NavigationView.PaneHeader>

        <muxc:NavigationView.PaneCustomContent>
            <ListView x:Name="NotebookList"
                      ItemsSource="{x:Bind ViewModel.Sidebar.Notebooks}"
                      SelectionMode="Single"
                      SelectionChanged="NotebookList_SelectionChanged">
                <ListView.ItemTemplate>
                    <DataTemplate x:DataType="core:Notebook">
                        <Grid Padding="4,2" RightTapped="NotebookItem_RightTapped">
                            <TextBlock Text="{x:Bind Name}" />
                            <FlyoutBase.AttachedFlyout>
                                <MenuFlyout>
                                    <MenuFlyoutItem Text="{Binding DataContext.RenameText, ElementName=Nav}"
                                                    Click="Rename_Click" />
                                    <MenuFlyoutItem Text="{Binding DataContext.DeleteText, ElementName=Nav}"
                                                    Click="Delete_Click" />
                                </MenuFlyout>
                            </FlyoutBase.AttachedFlyout>
                        </Grid>
                    </DataTemplate>
                </ListView.ItemTemplate>
            </ListView>
        </muxc:NavigationView.PaneCustomContent>

        <muxc:NavigationView.PaneFooter>
            <Button x:Name="NewButton" Click="New_Click" Margin="12,4"
                    ToolTipService.ToolTip="{Binding [createNotebook]}">
                <StackPanel Orientation="Horizontal" Spacing="8">
                    <FontIcon Glyph="&#xE710;" FontSize="14" />
                    <TextBlock Text="{Binding [createNotebook]}" />
                </StackPanel>
            </Button>
        </muxc:NavigationView.PaneFooter>

        <!-- Detail content -->
        <Grid x:Name="DetailHost" Padding="0">
            <StackPanel x:Name="EmptyState"
                        HorizontalAlignment="Center" VerticalAlignment="Center" Spacing="12">
                <FontIcon Glyph="&#xE721;" FontSize="48" Opacity="0.5" />
                <TextBlock Text="{Binding [noNotebookSelected]}" Opacity="0.7"
                           HorizontalAlignment="Center" />
            </StackPanel>
        </Grid>
    </muxc:NavigationView>
</Page>
```

> `{Binding [notebooks]}` etc. resolve against `LocalizedStrings` set as the page's `DataContext` (so language switches live-update). The `DataContext` of the page is the `LocalizedStrings` instance; the `ViewModel` field is bound via `x:Bind`. To keep both available, set `this.DataContext = L` and reference the VM through `x:Bind ViewModel.*`. The MenuFlyout text uses a small `RenameText`/`DeleteText` shim on the page (below) since `x:Bind` inside a `DataTemplate` for a localized indexer is awkward.

4. `ShellPage.xaml.cs` — resolves the VM + `LocalizedStrings`, drives selection both directions, opens the three `ContentDialog`s, and swaps the empty state for `NotebookDetailPage`:

```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Views.Dialogs;
using AINotebook.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;

namespace AINotebook.App.Views;

public sealed partial class ShellPage : Page
{
    public ShellViewModel ViewModel { get; }
    private readonly ILocalizedStrings _l;

    public string RenameText => _l["renameNotebook"];
    public string DeleteText => _l["deleteNotebook"];

    public ShellPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<ShellViewModel>();
        _l = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = _l; // enables {Binding [key]} localized lookups
        Nav.DataContext = this; // RenameText/DeleteText for the MenuFlyout

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ShellViewModel.SelectedNotebook))
                ShowDetail(ViewModel.SelectedNotebook);
        };
        ShowDetail(ViewModel.SelectedNotebook);
    }

    private void ShowDetail(Notebook? nb)
    {
        EmptyState.Visibility = nb is null ? Visibility.Visible : Visibility.Collapsed;
        // Remove a previous detail page if present.
        for (int i = DetailHost.Children.Count - 1; i >= 0; i--)
            if (DetailHost.Children[i] is NotebookDetailPage) DetailHost.Children.RemoveAt(i);
        if (nb is not null)
            DetailHost.Children.Add(new NotebookDetailPage(nb));
    }

    private void NotebookList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        ViewModel.Sidebar.SelectedNotebookId = (NotebookList.SelectedItem as Notebook)?.Id;
    }

    private void NotebookItem_RightTapped(object sender, RightTappedRoutedEventArgs e)
    {
        if (sender is FrameworkElement fe) FlyoutBase.ShowAttachedFlyout(fe);
    }

    private Notebook? ContextNotebook(object sender) =>
        (sender as FrameworkElement)?.DataContext as Notebook
        ?? ((sender as FrameworkElement)?.Parent as FrameworkElement)?.DataContext as Notebook
        ?? NotebookList.SelectedItem as Notebook;

    private async void New_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new NewNotebookDialog { XamlRoot = this.XamlRoot };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary && dialog.Created is { } created)
            ViewModel.Sidebar.OnCreated(created);
    }

    private async void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (ContextNotebook(sender) is not { Id: long } nb) return;
        var dialog = new RenameNotebookDialog(nb) { XamlRoot = this.XamlRoot };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
            ViewModel.Sidebar.OnRenamed();
    }

    private async void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (ContextNotebook(sender) is not { Id: long id }) return;
        var ok = await new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _l["deleteNotebook"],
            Content = _l["confirmDeleteNotebook"],
            PrimaryButtonText = _l["delete"],
            CloseButtonText = _l["cancel"],
            DefaultButton = ContentDialogButton.Close
        }.ShowAsync() == ContentDialogResult.Primary;
        if (ok) ViewModel.Sidebar.DeleteCommand.Execute(id);
    }
}
```

5. Update `MainWindow.xaml.cs` `Route()` `else` branch to `RootHost.Children.Add(new ShellPage());` (replacing the M0.3 placeholder).

6. **Verification (Windows):** `dotnet build`/`dotnet run`. Manually verify: the left pane lists notebooks (ordered most-recently-updated first); selecting one shows the detail (M2.2); with none selected the centered empty state shows the localized "No notebook selected" + magnifier glyph; the "+" footer opens the New dialog and a created notebook auto-selects; right-click a notebook → Rename/Delete; Delete shows the localized confirm and removes it (clearing selection if it was selected); switching language live-updates the pane header, "+" tooltip, empty state, and menu items.

7. Commit:

```console
git add windows/src/AINotebook.App/ViewModels/NotebookSidebarViewModel.cs windows/src/AINotebook.App/ViewModels/ShellViewModel.cs windows/src/AINotebook.App/Views/ShellPage.xaml windows/src/AINotebook.App/Views/ShellPage.xaml.cs windows/src/AINotebook.App/MainWindow.xaml.cs
git commit -m "$(cat <<'EOF'
feat(win): ShellPage NavigationView master/detail (ports ContentView+SidebarView)

Notebook list via NotebookStore.Notebooks(); single-select two-way bound;
+ footer creates and auto-selects; per-item MenuFlyout Rename/Delete with a
localized delete confirm; empty state when nothing selected; detail re-resolves
the Notebook from the live collection so renames reflect live.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M2.2 — NewNotebookDialog + RenameNotebookDialog (ContentDialogs over Core)

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/NewNotebookViewModel.cs`
- Create `windows/src/AINotebook.App/ViewModels/RenameNotebookViewModel.cs`
- Create `windows/src/AINotebook.App/Views/Dialogs/NewNotebookDialog.xaml`
- Create `windows/src/AINotebook.App/Views/Dialogs/NewNotebookDialog.xaml.cs`
- Create `windows/src/AINotebook.App/Views/Dialogs/RenameNotebookDialog.xaml`
- Create `windows/src/AINotebook.App/Views/Dialogs/RenameNotebookDialog.xaml.cs`

**Steps:**

1. **New** ports `NewNotebookSheet`: name + optional description; Create disabled when trimmed name empty; on submit `store.CreateNotebook(name, description)`; on `InvalidNotebookName` show the localized "Name cannot be empty." (`cannotBeEmpty`). **Rename** ports `RenameNotebookSheet`: single name field pre-filled; Save disabled when trimmed name empty **or** unchanged; on submit `store.RenameNotebook(id, newName)`.

`windows/src/AINotebook.App/ViewModels/NewNotebookViewModel.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class NewNotebookViewModel : ObservableObject
{
    private readonly NotebookStore _store;

    [ObservableProperty] public partial string Name { get; set; } = "";
    [ObservableProperty] public partial string Description { get; set; } = "";
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public bool CanCreate => !string.IsNullOrWhiteSpace(Name);
    public Notebook? Created { get; private set; }

    public NewNotebookViewModel(NotebookStore store) => _store = store;

    partial void OnNameChanged(string value) => OnPropertyChanged(nameof(CanCreate));

    /// Returns true on success (dialog should close). Sets ErrorMessage otherwise.
    public bool TrySubmit(string emptyNameMessage)
    {
        try
        {
            Created = _store.CreateNotebook(Name.Trim(), Description.Trim());
            return true;
        }
        catch (StoreException.InvalidNotebookName) { ErrorMessage = emptyNameMessage; return false; }
        catch (StoreException ex) { ErrorMessage = ex.Message; return false; }
    }
}
```

`windows/src/AINotebook.App/ViewModels/RenameNotebookViewModel.cs`:
```csharp
using AINotebook.Core;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class RenameNotebookViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly long _id;
    private readonly string _original;

    [ObservableProperty] public partial string Name { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public bool CanSave => !string.IsNullOrWhiteSpace(Name) && Name.Trim() != _original;

    public RenameNotebookViewModel(NotebookStore store, Notebook nb)
    {
        _store = store;
        _id = nb.Id!.Value;
        _original = nb.Name;
        _name = nb.Name;
    }

    partial void OnNameChanged(string value) => OnPropertyChanged(nameof(CanSave));

    public bool TrySubmit(string emptyNameMessage)
    {
        try { _store.RenameNotebook(_id, Name.Trim()); return true; }
        catch (StoreException.InvalidNotebookName) { ErrorMessage = emptyNameMessage; return false; }
        catch (StoreException ex) { ErrorMessage = ex.Message; return false; }
    }
}
```

2. `NewNotebookDialog.xaml` (a `ContentDialog`; Primary = Create disabled until name non-empty; Close = Cancel; the mac sheet is 420 wide):

```xml
<?xml version="1.0" encoding="utf-8"?>
<ContentDialog
    x:Class="AINotebook.App.Views.Dialogs.NewNotebookDialog"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="{Binding L[createNotebook]}"
    PrimaryButtonText="{Binding L[create]}"
    CloseButtonText="{Binding L[cancel]}"
    DefaultButton="Primary"
    IsPrimaryButtonEnabled="{x:Bind ViewModel.CanCreate, Mode=OneWay}"
    PrimaryButtonClick="OnPrimary">
    <StackPanel Width="420" Spacing="12">
        <TextBox Header="{Binding L[notebookName]}"
                 Text="{x:Bind ViewModel.Name, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" />
        <TextBox Header="{Binding L[notebookDescription]}"
                 AcceptsReturn="True" TextWrapping="Wrap" Height="80"
                 Text="{x:Bind ViewModel.Description, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" />
        <TextBlock Foreground="{ThemeResource SystemFillColorCriticalBrush}"
                   Text="{x:Bind ViewModel.ErrorMessage, Mode=OneWay}"
                   Visibility="{x:Bind ViewModel.ErrorMessage, Mode=OneWay, Converter={StaticResource NullToCollapsed}}" />
    </StackPanel>
</ContentDialog>
```

`NewNotebookDialog.xaml.cs`:
```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views.Dialogs;

public sealed partial class NewNotebookDialog : ContentDialog
{
    public NewNotebookViewModel ViewModel { get; }
    public ILocalizedStrings L { get; }
    public Notebook? Created => ViewModel.Created;

    public NewNotebookDialog()
    {
        ViewModel = ActivatorUtilities.CreateInstance<NewNotebookViewModel>(App.Current.Services);
        L = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = this; // exposes L for {Binding L[..]}
    }

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Keep the dialog open if validation fails (mac shows inline error).
        if (!ViewModel.TrySubmit(L["cannotBeEmpty"])) args.Cancel = true;
    }
}
```

3. `RenameNotebookDialog.xaml` (Save disabled until name non-empty **and** changed; mac sheet 380 wide):

```xml
<?xml version="1.0" encoding="utf-8"?>
<ContentDialog
    x:Class="AINotebook.App.Views.Dialogs.RenameNotebookDialog"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="{Binding L[renameNotebook]}"
    PrimaryButtonText="{Binding L[save]}"
    CloseButtonText="{Binding L[cancel]}"
    DefaultButton="Primary"
    IsPrimaryButtonEnabled="{x:Bind ViewModel.CanSave, Mode=OneWay}"
    PrimaryButtonClick="OnPrimary">
    <StackPanel Width="380" Spacing="12">
        <TextBox Header="{Binding L[notebookName]}"
                 Text="{x:Bind ViewModel.Name, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" />
        <TextBlock Foreground="{ThemeResource SystemFillColorCriticalBrush}"
                   Text="{x:Bind ViewModel.ErrorMessage, Mode=OneWay}" />
    </StackPanel>
</ContentDialog>
```

`RenameNotebookDialog.xaml.cs`:
```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views.Dialogs;

public sealed partial class RenameNotebookDialog : ContentDialog
{
    public RenameNotebookViewModel ViewModel { get; }
    public ILocalizedStrings L { get; }

    public RenameNotebookDialog(Notebook nb)
    {
        var store = App.Current.Services.GetRequiredService<NotebookStore>();
        ViewModel = new RenameNotebookViewModel(store, nb);
        L = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        DataContext = this;
    }

    private void OnPrimary(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        if (!ViewModel.TrySubmit(L["cannotBeEmpty"])) args.Cancel = true;
    }
}
```

> Register a tiny `NullToCollapsed` `IValueConverter` in `App.xaml` resources (returns `Visibility.Collapsed` for null/empty, else `Visible`) for the New dialog's error line, or drop the converter and bind `Visibility` via a code-behind handler. Add it to `App.xaml`'s `ResourceDictionary` as `<local:NullOrEmptyToCollapsedConverter x:Key="NullToCollapsed"/>` and create `Services/Converters/NullOrEmptyToCollapsedConverter.cs` implementing `IValueConverter`.

4. **Verification (Windows):** `dotnet build`/`dotnet run`. Manually verify: New dialog — Create stays disabled with an empty/whitespace name, creates on Enter, auto-selects; submitting a name that the store rejects keeps the dialog open and shows the localized "Name cannot be empty." inline. Rename dialog — pre-fills the current name, Save disabled until the name is both non-empty and changed, persists and reflects live in the sidebar. Both dialogs are localized and respond to a language switch.

5. Commit:

```console
git add windows/src/AINotebook.App/ViewModels/NewNotebookViewModel.cs windows/src/AINotebook.App/ViewModels/RenameNotebookViewModel.cs windows/src/AINotebook.App/Views/Dialogs/
git commit -m "$(cat <<'EOF'
feat(win): New/Rename notebook ContentDialogs over Core

NewNotebookDialog (CreateNotebook; Create disabled until name non-empty;
inline InvalidNotebookName -> localized cannotBeEmpty) and RenameNotebookDialog
(RenameNotebook; Save disabled until non-empty AND changed). Ports
NewNotebookSheet/RenameNotebookSheet.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task M2.3 — NotebookDetailPage (header + 4-tab switcher) + NotebookDetailViewModel + TabSwitchCoordinator wiring + coordinator test

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/NotebookDetailViewModel.cs`
- Create `windows/src/AINotebook.App/Views/NotebookDetailPage.xaml`
- Create `windows/src/AINotebook.App/Views/NotebookDetailPage.xaml.cs`
- Create `windows/tests/AINotebook.App.Tests/TabSwitchCoordinatorTests.cs`

**Steps:**

1. `NotebookDetailPage` ports `NotebookDetailView`: a header (name bold; description if non-empty; created date `.abbreviated`/`.shortened`) + a segmented 4-tab switcher (Sources / Chat / Notes / Transformations) hosting the active sub-view, all filling the available space. WinUI's segmented analogue is a `Pivot` (or a `SelectorBar` + content host). Use a `Pivot` for the tab semantics, bound to a `SelectedTab` enum. Subscribe to `TabSwitchCoordinator.Target`: when another view requests a tab, switch and `Clear()` (the mac `.onReceive(tabSwitch.$target...)` glue). The four tab pages are Plan 3; Plan 2 hosts labeled placeholders so the switcher and coordinator are exercisable now.

`windows/src/AINotebook.App/ViewModels/NotebookDetailViewModel.cs`:
```csharp
using AINotebook.App.Services;
using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public partial class NotebookDetailViewModel : ObservableObject
{
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _l;

    [ObservableProperty] public partial Notebook Notebook { get; set; }
    [ObservableProperty] public partial TabSwitchCoordinator.Tab SelectedTab { get; set; } = TabSwitchCoordinator.Tab.Sources;

    public string SourcesText => _l["sources"];
    public string ChatText => _l["chat"];
    public string NotesText => _l["notes"];
    public string TransformationsText => _l["transformations"];

    public NotebookDetailViewModel(Notebook notebook, TabSwitchCoordinator tabSwitch, ILocalizedStrings l)
    {
        Notebook = notebook;
        _tabSwitch = tabSwitch;
        _l = l;

        _tabSwitch.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(TabSwitchCoordinator.Target) && _tabSwitch.Target is { } target)
            {
                SelectedTab = target;       // jump
                _tabSwitch.Clear();         // reset, like the mac clear()
            }
        };
        _l.PropertyChanged += (_, _) =>
        {
            OnPropertyChanged(nameof(SourcesText)); OnPropertyChanged(nameof(ChatText));
            OnPropertyChanged(nameof(NotesText)); OnPropertyChanged(nameof(TransformationsText));
        };
    }
}
```

`windows/src/AINotebook.App/Views/NotebookDetailPage.xaml`:
```xml
<?xml version="1.0" encoding="utf-8"?>
<Page
    x:Class="AINotebook.App.Views.NotebookDetailPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:muxc="using:Microsoft.UI.Xaml.Controls">
    <Grid RowSpacing="0">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Padding="24,24,24,16" Spacing="4">
            <TextBlock Text="{x:Bind ViewModel.Notebook.Name, Mode=OneWay}"
                       Style="{StaticResource TitleTextBlockStyle}" />
            <TextBlock Text="{x:Bind ViewModel.Notebook.Description, Mode=OneWay}"
                       Opacity="0.8"
                       Visibility="{x:Bind ViewModel.Notebook.Description, Mode=OneWay, Converter={StaticResource NullToCollapsed}}" />
            <TextBlock Text="{x:Bind ViewModel.Notebook.CreatedAt, Mode=OneWay}"
                       Opacity="0.6" Style="{StaticResource CaptionTextBlockStyle}" />
        </StackPanel>

        <!-- 4-tab switcher fills remaining space -->
        <Pivot Grid.Row="1" x:Name="Tabs"
               SelectedIndex="{x:Bind TabIndex, Mode=TwoWay}"
               Margin="16,0,16,16">
            <PivotItem Header="{x:Bind ViewModel.SourcesText, Mode=OneWay}">
                <Grid x:Name="SourcesHost"><TextBlock Text="Sources (Plan 3)" Opacity="0.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
            </PivotItem>
            <PivotItem Header="{x:Bind ViewModel.ChatText, Mode=OneWay}">
                <Grid x:Name="ChatHost"><TextBlock Text="Chat (Plan 3)" Opacity="0.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
            </PivotItem>
            <PivotItem Header="{x:Bind ViewModel.NotesText, Mode=OneWay}">
                <Grid x:Name="NotesHost"><TextBlock Text="Notes (Plan 3)" Opacity="0.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
            </PivotItem>
            <PivotItem Header="{x:Bind ViewModel.TransformationsText, Mode=OneWay}">
                <Grid x:Name="TransformationsHost"><TextBlock Text="Transformations (Plan 3)" Opacity="0.5"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/></Grid>
            </PivotItem>
        </Pivot>
    </Grid>
</Page>
```

`windows/src/AINotebook.App/Views/NotebookDetailPage.xaml.cs`:
```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class NotebookDetailPage : Page
{
    public NotebookDetailViewModel ViewModel { get; }

    /// Bridge TabSwitchCoordinator.Tab <-> Pivot SelectedIndex (Sources=0..Transformations=3).
    public int TabIndex
    {
        get => (int)ViewModel.SelectedTab;
        set => ViewModel.SelectedTab = (TabSwitchCoordinator.Tab)value;
    }

    public NotebookDetailPage(Notebook notebook)
    {
        var tabSwitch = App.Current.Services.GetRequiredService<TabSwitchCoordinator>();
        var l = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        ViewModel = new NotebookDetailViewModel(notebook, tabSwitch, l);
        InitializeComponent();

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(NotebookDetailViewModel.SelectedTab))
                Bindings.Update(); // refresh TabIndex two-way target after a coordinator jump
        };
    }
}
```

> `TabSwitchCoordinator.Tab` ordinals are `Sources=0, Chat=1, Notes=2, Transformations=3`, matching the `Pivot` item order, so the `(int)`/`(TabSwitchCoordinator.Tab)` cast is the tab map (mac `mapTab`). When `TabSwitchCoordinator.Target` jumps `SelectedTab`, `Bindings.Update()` pushes the new index into the `Pivot`.

2. **xUnit test** for the coordinator — pure logic, **no WinUI types** (`TabSwitchCoordinator` only depends on `CommunityToolkit.Mvvm.ObservableObject`, which is netstandard). Add a project reference from the test project to `AINotebook.App` and run on Windows.

`windows/tests/AINotebook.App.Tests/TabSwitchCoordinatorTests.cs`:
```csharp
using AINotebook.App.Services;
using Xunit;

namespace AINotebook.App.Tests;

public class TabSwitchCoordinatorTests
{
    [Fact]
    public void Request_sets_target()
    {
        var c = new TabSwitchCoordinator();
        Assert.Null(c.Target);
        c.Request(TabSwitchCoordinator.Tab.Notes);
        Assert.Equal(TabSwitchCoordinator.Tab.Notes, c.Target);
    }

    [Fact]
    public void Clear_resets_target()
    {
        var c = new TabSwitchCoordinator();
        c.Request(TabSwitchCoordinator.Tab.Chat);
        c.Clear();
        Assert.Null(c.Target);
    }

    [Fact]
    public void Request_raises_property_changed()
    {
        var c = new TabSwitchCoordinator();
        string? changed = null;
        c.PropertyChanged += (_, e) => changed = e.PropertyName;
        c.Request(TabSwitchCoordinator.Tab.Transformations);
        Assert.Equal(nameof(TabSwitchCoordinator.Target), changed);
    }
}
```

   Add to `AINotebook.App.Tests.csproj` (note: this pulls a `net10.0-windows` reference into the test project; the test methods above don't touch WinUI types, but referencing `AINotebook.App` makes the test project Windows-only — run it on the Windows build machine, not macOS):
```xml
  <ItemGroup>
    <ProjectReference Include="..\..\src\AINotebook.App\AINotebook.App.csproj" />
  </ItemGroup>
```
   Since `AINotebook.App` targets `net10.0-windows10.0.19041.0`, change the test project's `TargetFramework` to `net10.0-windows10.0.19041.0` so the project reference is compatible. (The `LocalizedStringsTests` from M1.3 remains pure-XML and is unaffected.)

3. **Verification (Windows):**
   - `dotnet build`/`dotnet run`: selecting a notebook shows the header (name/description/created date) and a 4-tab `Pivot` filling the pane; the four placeholders render; switching tabs works; a language switch re-labels the tab headers live.
   - Simulate a coordinator jump (temporarily call `TabSwitchCoordinator.Request(TabSwitchCoordinator.Tab.Notes)` from a debug button) and confirm the `Pivot` jumps to the Notes tab and `Target` resets to null.
   - `dotnet test windows/tests/AINotebook.App.Tests`: all `TabSwitchCoordinatorTests` + the M1.3 localization facts pass.

4. Commit:

```console
git add windows/src/AINotebook.App/ViewModels/NotebookDetailViewModel.cs windows/src/AINotebook.App/Views/NotebookDetailPage.xaml windows/src/AINotebook.App/Views/NotebookDetailPage.xaml.cs windows/tests/AINotebook.App.Tests/TabSwitchCoordinatorTests.cs windows/tests/AINotebook.App.Tests/AINotebook.App.Tests.csproj
git commit -m "$(cat <<'EOF'
feat(win): NotebookDetailPage (header + 4-tab Pivot) + TabSwitchCoordinator wiring

Ports NotebookDetailView: header (name/description/created) + Sources/Chat/Notes/
Transformations switcher. Subscribes to TabSwitchCoordinator.Target to
programmatically jump tabs then clear (the citation/transformation -> Notes glue).
xUnit covers the coordinator (request/clear/notify). Tab pages are Plan 3
placeholders.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

**End of Plan 2 (Foundation).** Plan 3 builds on this: the four tab pages (`SourceListPage`, `ChatPage`, `NotesPage`, `TransformationsPage`), the WebView2 editor host + JS bridge (`Editor/`), the attachment virtual-host scheme, the onboarding state machine (`Onboarding/`, wiring `OnboardingViewModel` into DI and the `MainWindow` router's onboarding branch), the Settings surface, and `NoteJumpCoordinator`/`NoteEditorCoordinator` consumers — all reusing the DI graph, `LocalizedStrings`, coordinators, dialogs, and shell established here.

---

> **Milestone M3 — Onboarding.** Project scaffold, the settings service, and localization are already established in Milestones M0–M1 (Writer A). M3 builds the onboarding flow on top: coordinators (M3.4), the onboarding state machine (M3.5), and the onboarding UI (M3.6). Foundation is NOT re-created here.

---

### Task M3.4 — Coordinators: NoteEditorCoordinator, NoteJumpCoordinator, TabSwitchCoordinator (DI singletons)

**Files:**
- Create `windows/src/AINotebook.App/Services/NoteEditorCoordinator.cs`
- Create `windows/src/AINotebook.App/Services/NoteJumpCoordinator.cs`
- Create `windows/src/AINotebook.App/Services/TabSwitchCoordinator.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/Services/NoteEditorCoordinator.cs`. Port of the mac `NoteEditorCoordinator`: observable `HasUnsavedChanges` + a `FlushPendingSave` delegate the active editor registers (calling it triggers a synchronous manual save). `Reset()` clears both.

```csharp
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac NoteEditorCoordinator. The active note editor registers a
/// FlushPendingSave delegate on appear and clears it on disappear; the notes
/// list checks HasUnsavedChanges before switching notes and may call
/// FlushPendingSave to force a synchronous manual save.
/// </summary>
public sealed partial class NoteEditorCoordinator : ObservableObject
{
    [ObservableProperty]
    public partial bool HasUnsavedChanges { get; set; }

    /// <summary>Set by the active editor; invoking it triggers a manual save.</summary>
    public Action? FlushPendingSave { get; set; }

    public void Reset()
    {
        HasUnsavedChanges = false;
        FlushPendingSave = null;
    }
}
```

2. Create `windows/src/AINotebook.App/Services/NoteJumpCoordinator.cs`. Port of the mac `NoteJumpCoordinator`: observable nullable `Target` note id; `Request(noteId)` sets it, `Clear()` resets. Consumed by the citation flyout's "Open note" and by NotesView.

```csharp
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac NoteJumpCoordinator. CitationPopover "Open note" calls
/// Request(noteId); NotesView reacts (selects/scrolls to the note) then Clear().
/// </summary>
public sealed partial class NoteJumpCoordinator : ObservableObject
{
    [ObservableProperty]
    public partial long? Target { get; set; }

    public void Request(long noteId) => Target = noteId;
    public void Clear() => Target = null;
}
```

3. Create `windows/src/AINotebook.App/Services/TabSwitchCoordinator.cs`. Port of the mac `TabSwitchCoordinator` (which lives in AINotebookCore on mac, but is an App-layer concern in WinUI): a **nested `Tab` enum** (matching the mac `TabSwitchCoordinator.Tab`), observable nullable `Target`; `Request(tab)` / `Clear()`. `NotebookDetailPage` subscribes, switches the active tab, then clears. Pairs with `NoteJumpCoordinator` so "open note from citation" both switches to the Notes tab and selects the note. (Consumers reference `TabSwitchCoordinator.Tab.Notes` — see M2.3 and M8.)

```csharp
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// <summary>
/// Port of the mac TabSwitchCoordinator. The detail page subscribes to Target,
/// switches its segmented tab, then Clear()s. Pairs with NoteJumpCoordinator.
/// </summary>
public sealed partial class TabSwitchCoordinator : ObservableObject
{
    /// Mirrors the mac nested `TabSwitchCoordinator.Tab` cases (Sources=0..Transformations=3).
    public enum Tab { Sources, Chat, Notes, Transformations }

    [ObservableProperty]
    public partial Tab? Target { get; set; }

    public void Request(Tab tab) => Target = tab;
    public void Clear() => Target = null;
}
```

**Verification:** Build on a Windows machine (`dotnet build`) and manually verify: the three coordinators compile as `ObservableObject` partials (no MVVMTK0045 warnings — partial properties used); they are resolvable from DI (`App.Current.Services.GetRequiredService<TabSwitchCoordinator>()` returns the singleton). Behavioral verification happens when consuming milestones wire them.

3. Commit:

```bash
git add windows/src/AINotebook.App/Services/NoteEditorCoordinator.cs windows/src/AINotebook.App/Services/NoteJumpCoordinator.cs windows/src/AINotebook.App/Services/TabSwitchCoordinator.cs
git commit -m "feat(app): port NoteEditor/NoteJump/TabSwitch coordinators as DI singletons

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task M3.5 — OnboardingViewModel (exact state machine) + xUnit test with fake IOllama

**Files:**
- Create `windows/src/AINotebook.App/Onboarding/OnboardingStep.cs`
- Create `windows/src/AINotebook.App/Onboarding/IOllamaOnboarding.cs`
- Create `windows/src/AINotebook.App/Onboarding/OnboardingViewModel.cs`
- Create `windows/tests/AINotebook.App.Tests/OnboardingViewModelTests.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/Onboarding/OnboardingStep.cs` — port of the mac `OnboardingStep` enum, with explicit int values matching the SHARED state machine (`welcome(0)→detectOllama(1)→pickModels(2)→pullModels(3)→done(4)`):

```csharp
namespace AINotebook.App.Onboarding;

public enum OnboardingStep
{
    Welcome = 0,
    DetectOllama = 1,
    PickModels = 2,
    PullModels = 3,
    Done = 4
}
```

2. Create `windows/src/AINotebook.App/Onboarding/IOllamaOnboarding.cs` — a thin abstraction over the two `OllamaClient` members onboarding uses, so the VM is testable with a fake. The real `OllamaClient` satisfies it directly (adapter below) without changing Core:

```csharp
using AINotebook.Core.Ollama;

namespace AINotebook.App.Onboarding;

/// <summary>
/// Onboarding-only seam over OllamaClient (DetectAsync + PullModelAsync) so the
/// view model is unit-testable with a fake. OllamaClient is wrapped by
/// OllamaOnboardingAdapter; Core is unchanged.
/// </summary>
public interface IOllamaOnboarding
{
    Task<bool> DetectAsync(CancellationToken ct = default);
    IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default);
}

public sealed class OllamaOnboardingAdapter : IOllamaOnboarding
{
    private readonly OllamaClient _client;
    public OllamaOnboardingAdapter(OllamaClient client) => _client = client;

    public Task<bool> DetectAsync(CancellationToken ct = default) => _client.DetectAsync(ct: ct);

    public IAsyncEnumerable<OllamaPullEvent> PullModelAsync(string name, CancellationToken ct = default)
        => _client.PullModelAsync(name, ct);
}
```

3. Create `windows/src/AINotebook.App/Onboarding/OnboardingViewModel.cs`. This ports the mac `OnboardingViewModel.swift` state machine **exactly**:
- `Advance()` moves to `step + 1` (clamped at `Done`).
- `StartDetectionPolling()` polls `DetectAsync()` every 2s until reachable, marshalling `IsOllamaReachable` to the UI via `DispatcherQueue.TryEnqueue`; breaks the loop when up.
- `OpenOllamaDownload()` launches `https://ollama.com/download`.
- `RunModelPullsAsync()` sequentially pulls the chat model then the embedding model via `PullModelAsync` (an `IAsyncEnumerable<OllamaPullEvent>`), updating two fractions/status strings, forcing `1.0` on `IsTerminalSuccess`; on both success calls `Advance()` → `Done`; on error sets `PullError`.
- `MarkCompleted()` sets `settings.HasCompletedOnboarding = true`.

The ctor takes the concrete `OllamaClient` (wrapping it in the adapter) for production DI, plus an internal ctor taking `IOllamaOnboarding` for tests. A nullable `DispatcherQueue` lets tests run without a UI thread (when null, invoke synchronously).

```csharp
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.Onboarding;

public sealed partial class OnboardingViewModel : ObservableObject
{
    private readonly IOllamaOnboarding _client;
    private readonly ISettingsService _settings;
    private readonly DispatcherQueue? _dispatcher;
    private CancellationTokenSource? _pollCts;

    [ObservableProperty]
    public partial OnboardingStep Step { get; set; } = OnboardingStep.Welcome;

    [ObservableProperty]
    public partial bool IsOllamaReachable { get; set; }

    [ObservableProperty]
    public partial double ChatPullFraction { get; set; }

    [ObservableProperty]
    public partial string ChatPullStatus { get; set; } = "";

    [ObservableProperty]
    public partial double EmbeddingPullFraction { get; set; }

    [ObservableProperty]
    public partial string EmbeddingPullStatus { get; set; } = "";

    [ObservableProperty]
    public partial string? PullError { get; set; }

    // Production DI ctor: wraps the shared OllamaClient.
    public OnboardingViewModel(OllamaClient client, ISettingsService settings)
        : this(new OllamaOnboardingAdapter(client), settings, DispatcherQueue.GetForCurrentThread())
    {
    }

    // Test ctor: inject a fake transport + optional dispatcher (null = run inline).
    internal OnboardingViewModel(IOllamaOnboarding client, ISettingsService settings, DispatcherQueue? dispatcher)
    {
        _client = client;
        _settings = settings;
        _dispatcher = dispatcher;
    }

    private void OnUi(Action action)
    {
        if (_dispatcher is null) action();
        else _dispatcher.TryEnqueue(() => action());
    }

    public void Advance()
    {
        if (Step < OnboardingStep.Done)
            Step = (OnboardingStep)((int)Step + 1);
    }

    // MARK: Step 2 — detect Ollama (poll every 2s until reachable).
    public void StartDetectionPolling()
    {
        _pollCts?.Cancel();
        _pollCts = new CancellationTokenSource();
        var ct = _pollCts.Token;
        _ = Task.Run(async () =>
        {
            while (!ct.IsCancellationRequested)
            {
                var up = await _client.DetectAsync(ct).ConfigureAwait(false);
                OnUi(() => IsOllamaReachable = up);
                if (up) break;
                try { await Task.Delay(TimeSpan.FromSeconds(2), ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }, ct);
    }

    public void StopDetectionPolling()
    {
        _pollCts?.Cancel();
        _pollCts = null;
    }

    [RelayCommand]
    public async Task OpenOllamaDownloadAsync()
    {
        await Windows.System.Launcher.LaunchUriAsync(new Uri("https://ollama.com/download"));
    }

    // MARK: Step 4 — pull models sequentially (chat then embedding).
    public async Task RunModelPullsAsync(CancellationToken ct = default)
    {
        PullError = null;
        var chatModel = _settings.SelectedChatModel;
        var embedModel = _settings.SelectedEmbeddingModel;

        try
        {
            ChatPullStatus = "Starting…";
            await foreach (var ev in _client.PullModelAsync(chatModel, ct).ConfigureAwait(false))
            {
                ChatPullStatus = ev.Status;
                ChatPullFraction = ev.FractionComplete ?? ChatPullFraction;
                if (ev.IsTerminalSuccess) ChatPullFraction = 1.0;
            }

            EmbeddingPullStatus = "Starting…";
            await foreach (var ev in _client.PullModelAsync(embedModel, ct).ConfigureAwait(false))
            {
                EmbeddingPullStatus = ev.Status;
                EmbeddingPullFraction = ev.FractionComplete ?? EmbeddingPullFraction;
                if (ev.IsTerminalSuccess) EmbeddingPullFraction = 1.0;
            }

            Advance(); // → Done
        }
        catch (Exception ex)
        {
            PullError = ex.Message;
        }
    }

    public void MarkCompleted()
    {
        _settings.HasCompletedOnboarding = true;
    }
}
```

> The mac `chatPullFraction`/`embeddingPullFraction` are `Double?` (nil before progress); the WinUI `ProgressBar.Value` binds to a `double`, so the ported props are non-nullable doubles defaulting to 0 (a 0-valued determinate bar), matching the mac `ProgressView(value: fraction ?? 0)`. When `FractionComplete` is null the previous fraction is retained.

4. Create `windows/tests/AINotebook.App.Tests/OnboardingViewModelTests.cs`. Uses a fake `IOllamaOnboarding` and a null dispatcher (inline marshalling) plus a fake `ISettingsService`. Covers the three behaviors from SHARED: detect false→true flips reachable; pull stream updates fractions and forces 1.0 on terminal success; both-success advances to Done; error sets PullError without advancing.

```csharp
using System.ComponentModel;
using System.Runtime.CompilerServices;
using AINotebook.App.Onboarding;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using Xunit;

namespace AINotebook.App.Tests;

internal sealed class OnbFakeSettings : ISettingsService
{
    public event PropertyChangedEventHandler? PropertyChanged;
    public AppLanguage Language { get; set; } = AppLanguage.English;
    public bool HasCompletedOnboarding { get; set; }
    public string SelectedChatModel { get; set; } = "llama3.2:3b";
    public string SelectedEmbeddingModel { get; set; } = "nomic-embed-text";
}

internal sealed class FakeOllama : IOllamaOnboarding
{
    private int _detectCalls;
    public int DetectTrueAfter { get; set; } = 1; // becomes reachable on the Nth probe
    public Func<string, IEnumerable<OllamaPullEvent>>? PullScript { get; set; }
    public Exception? PullThrows { get; set; }

    public Task<bool> DetectAsync(CancellationToken ct = default)
    {
        _detectCalls++;
        return Task.FromResult(_detectCalls >= DetectTrueAfter);
    }

    public async IAsyncEnumerable<OllamaPullEvent> PullModelAsync(
        string name, [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (PullThrows is not null) throw PullThrows;
        foreach (var ev in PullScript?.Invoke(name) ?? Array.Empty<OllamaPullEvent>())
        {
            yield return ev;
            await Task.Yield();
        }
    }
}

public class OnboardingViewModelTests
{
    private static OnboardingViewModel Make(FakeOllama ollama, OnbFakeSettings? settings = null)
        => new(ollama, settings ?? new OnbFakeSettings(), dispatcher: null);

    [Fact]
    public void Advance_walks_the_state_machine_and_clamps_at_done()
    {
        var vm = Make(new FakeOllama());
        Assert.Equal(OnboardingStep.Welcome, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.DetectOllama, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.PickModels, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.PullModels, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.Done, vm.Step);
        vm.Advance(); Assert.Equal(OnboardingStep.Done, vm.Step); // clamps
    }

    [Fact]
    public async Task Detection_flips_reachable_when_ollama_comes_up()
    {
        var ollama = new FakeOllama { DetectTrueAfter = 1 };
        var vm = Make(ollama);
        Assert.False(vm.IsOllamaReachable);
        vm.StartDetectionPolling();
        // Poll runs on a Task; wait briefly for the first probe.
        for (int i = 0; i < 50 && !vm.IsOllamaReachable; i++) await Task.Delay(20);
        vm.StopDetectionPolling();
        Assert.True(vm.IsOllamaReachable);
    }

    [Fact]
    public async Task Pull_updates_fractions_and_forces_one_on_terminal_success()
    {
        var ollama = new FakeOllama
        {
            PullScript = name => new[]
            {
                new OllamaPullEvent("pulling", Total: 100, Completed: 50),   // 0.5
                new OllamaPullEvent("success")                              // terminal
            }
        };
        var vm = Make(ollama);
        await vm.RunModelPullsAsync();
        Assert.Equal(1.0, vm.ChatPullFraction);
        Assert.Equal(1.0, vm.EmbeddingPullFraction);
        Assert.Equal("success", vm.ChatPullStatus);
        Assert.Equal("success", vm.EmbeddingPullStatus);
        Assert.Equal(OnboardingStep.Done, vm.Step); // both succeeded → advance
        Assert.Null(vm.PullError);
    }

    [Fact]
    public async Task Pull_error_sets_PullError_and_does_not_advance()
    {
        var ollama = new FakeOllama { PullThrows = new InvalidOperationException("boom") };
        var vm = Make(ollama);
        vm.Step = OnboardingStep.PullModels;
        await vm.RunModelPullsAsync();
        Assert.Equal("boom", vm.PullError);
        Assert.Equal(OnboardingStep.PullModels, vm.Step); // no advance on error
    }

    [Fact]
    public void MarkCompleted_persists_flag()
    {
        var settings = new OnbFakeSettings();
        var vm = Make(new FakeOllama(), settings);
        vm.MarkCompleted();
        Assert.True(settings.HasCompletedOnboarding);
    }
}
```

> The `OllamaPullEvent` ctor used in the test is `OllamaPullEvent(string Status, string? Digest = null, long? Total = null, long? Completed = null)` with computed `FractionComplete` (`Completed/Total`) and `IsTerminalSuccess` (`Status == "success"`) — exactly as in the Core API. Confirm `FractionComplete` returns `0.5` for `(Total:100, Completed:50)` against the real Core implementation when verifying on Windows.

**Verification:** Build on a Windows machine and run `dotnet test windows/tests/AINotebook.App.Tests` and manually verify: all `OnboardingViewModelTests` pass; the detection test confirms `IsOllamaReachable` flips to true; the pull test confirms fractions reach 1.0 and the VM advances to `Done`; the error test confirms `PullError` is set and the step does not advance. Requires the Windows TFM.

5. Commit:

```bash
git add windows/src/AINotebook.App/Onboarding windows/tests/AINotebook.App.Tests/OnboardingViewModelTests.cs
git commit -m "feat(onboarding): OnboardingViewModel state machine + fake-IOllama tests

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task M3.6 — OnboardingPage router + 5 step UserControls (Welcome, DetectOllama, PickModels, PullModels, Done)

**Files:**
- Create `windows/src/AINotebook.App/Onboarding/OnboardingPage.xaml`
- Create `windows/src/AINotebook.App/Onboarding/OnboardingPage.xaml.cs`
- Create `windows/src/AINotebook.App/Onboarding/WelcomeStep.xaml` (+ `.xaml.cs`)
- Create `windows/src/AINotebook.App/Onboarding/DetectOllamaStep.xaml` (+ `.xaml.cs`)
- Create `windows/src/AINotebook.App/Onboarding/PickModelsStep.xaml` (+ `.xaml.cs`)
- Create `windows/src/AINotebook.App/Onboarding/PullModelsStep.xaml` (+ `.xaml.cs`)
- Create `windows/src/AINotebook.App/Onboarding/DoneStep.xaml` (+ `.xaml.cs`)

**Steps:**

1. Create `windows/src/AINotebook.App/Onboarding/OnboardingPage.xaml` — the router that swaps the step UserControl based on `OnboardingViewModel.Step` (mirrors the mac `OnboardingView` `switch viewModel.step`). It resolves the singleton VM and `LocalizedStrings` from DI, and on `Done` (`HasCompletedOnboarding == true`) the host frame navigates to the main shell (signalled here via an event the MainWindow listens to in the shell milestone).

```xml
<Page
    x:Class="AINotebook.App.Onboarding.OnboardingPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid Padding="24" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
        <ContentControl x:Name="StepHost"
                        HorizontalAlignment="Stretch"
                        VerticalAlignment="Stretch"
                        HorizontalContentAlignment="Stretch"
                        VerticalContentAlignment="Stretch" />
    </Grid>
</Page>
```

2. Create `windows/src/AINotebook.App/Onboarding/OnboardingPage.xaml.cs`. It listens to `ViewModel.Step` changes, sets the right step control, and raises `CompletedRequested` when the flag flips (the shell milestone subscribes to swap the frame to the main UI).

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class OnboardingPage : Page
{
    public OnboardingViewModel ViewModel { get; }
    private readonly ISettingsService _settings;
    private readonly LocalizedStrings _strings;

    public event EventHandler? CompletedRequested;

    public OnboardingPage()
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        ViewModel = sp.GetRequiredService<OnboardingViewModel>();
        _settings = sp.GetRequiredService<ISettingsService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();

        ViewModel.PropertyChanged += OnVmChanged;
        _settings.PropertyChanged += OnSettingsChanged;
        ShowStep(ViewModel.Step);
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingViewModel.Step))
            ShowStep(ViewModel.Step);
    }

    private void OnSettingsChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ISettingsService.HasCompletedOnboarding)
            && _settings.HasCompletedOnboarding)
        {
            CompletedRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    private void ShowStep(OnboardingStep step)
    {
        StepHost.Content = step switch
        {
            OnboardingStep.Welcome => new WelcomeStep(ViewModel, _strings),
            OnboardingStep.DetectOllama => new DetectOllamaStep(ViewModel, _strings),
            OnboardingStep.PickModels => new PickModelsStep(ViewModel, _settings, _strings),
            OnboardingStep.PullModels => new PullModelsStep(ViewModel, _strings),
            OnboardingStep.Done => new DoneStep(ViewModel, _strings),
            _ => new WelcomeStep(ViewModel, _strings)
        };
    }
}
```

3. Create `windows/src/AINotebook.App/Onboarding/WelcomeStep.xaml` — centered sparkle glyph + title + body + Continue (default button). Mirrors `WelcomeStepView.swift`.

```xml
<UserControl
    x:Class="AINotebook.App.Onboarding.WelcomeStep"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Spacing="24" Padding="40" MaxWidth="520">
        <FontIcon Glyph="&#xE945;" FontSize="56" HorizontalAlignment="Center"
                  Foreground="{ThemeResource AccentTextFillColorPrimaryBrush}" />
        <TextBlock x:Name="TitleText" FontSize="34" FontWeight="Bold" HorizontalAlignment="Center" />
        <TextBlock x:Name="BodyText" TextWrapping="Wrap" TextAlignment="Center"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
        <Button x:Name="ContinueButton" HorizontalAlignment="Center" Style="{ThemeResource AccentButtonStyle}"
                Click="OnContinue">
            <Button.KeyboardAccelerators>
                <KeyboardAccelerator Key="Enter" />
            </Button.KeyboardAccelerators>
        </Button>
    </StackPanel>
</UserControl>
```

4. Create `windows/src/AINotebook.App/Onboarding/WelcomeStep.xaml.cs`:

```csharp
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class WelcomeStep : UserControl
{
    private readonly OnboardingViewModel _vm;

    public WelcomeStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.Welcome);
        BodyText.Text = strings.Get(StringKey.WelcomeBody);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);
    }

    private void OnContinue(object sender, RoutedEventArgs e) => _vm.Advance();
}
```

5. Create `windows/src/AINotebook.App/Onboarding/DetectOllamaStep.xaml`. Mirrors `DetectOllamaStepView.swift`: a status glyph (check when reachable, cloud otherwise), title/body; when reachable shows the "found" text + Continue; otherwise a `ProgressRing` + waiting text + "Open download page". Starts polling on load, stops on unload.

```xml
<UserControl
    x:Class="AINotebook.App.Onboarding.DetectOllamaStep"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Loaded="OnLoaded" Unloaded="OnUnloaded">
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Spacing="20" Padding="40" MaxWidth="520">
        <FontIcon x:Name="StatusIcon" FontSize="48" HorizontalAlignment="Center" Glyph="&#xE9A9;" />
        <TextBlock x:Name="TitleText" FontSize="28" FontWeight="Bold" HorizontalAlignment="Center" />
        <TextBlock x:Name="BodyText" TextWrapping="Wrap" TextAlignment="Center"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" />

        <StackPanel x:Name="FoundPanel" Spacing="12" HorizontalAlignment="Center" Visibility="Collapsed">
            <TextBlock x:Name="FoundText" HorizontalAlignment="Center"
                       Foreground="{ThemeResource SystemFillColorSuccessBrush}" />
            <Button x:Name="ContinueButton" HorizontalAlignment="Center"
                    Style="{ThemeResource AccentButtonStyle}" Click="OnContinue">
                <Button.KeyboardAccelerators>
                    <KeyboardAccelerator Key="Enter" />
                </Button.KeyboardAccelerators>
            </Button>
        </StackPanel>

        <StackPanel x:Name="WaitingPanel" Spacing="12" HorizontalAlignment="Center">
            <ProgressRing IsActive="True" Width="28" Height="28" HorizontalAlignment="Center" />
            <TextBlock x:Name="WaitingText" HorizontalAlignment="Center"
                       Foreground="{ThemeResource TextFillColorTertiaryBrush}" />
            <Button x:Name="DownloadButton" HorizontalAlignment="Center" Click="OnOpenDownload" />
        </StackPanel>
    </StackPanel>
</UserControl>
```

6. Create `windows/src/AINotebook.App/Onboarding/DetectOllamaStep.xaml.cs`. Subscribes to `IsOllamaReachable`, toggles the two panels and the status glyph, starts/stops polling on load/unload.

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI;
using Windows.UI;

namespace AINotebook.App.Onboarding;

public sealed partial class DetectOllamaStep : UserControl
{
    private readonly OnboardingViewModel _vm;
    private readonly LocalizedStrings _strings;

    public DetectOllamaStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        _strings = strings;
        TitleText.Text = strings.Get(StringKey.OnboardingDetectTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingDetectBody);
        FoundText.Text = strings.Get(StringKey.OnboardingDetectFound);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);
        WaitingText.Text = strings.Get(StringKey.OnboardingDetectWaiting);
        DownloadButton.Content = strings.Get(StringKey.OpenOllamaDownload);
        _vm.PropertyChanged += OnVmChanged;
        Apply();
    }

    private void OnLoaded(object sender, RoutedEventArgs e) => _vm.StartDetectionPolling();
    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _vm.StopDetectionPolling();
        _vm.PropertyChanged -= OnVmChanged;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(OnboardingViewModel.IsOllamaReachable)) Apply();
    }

    private void Apply()
    {
        var up = _vm.IsOllamaReachable;
        FoundPanel.Visibility = up ? Visibility.Visible : Visibility.Collapsed;
        WaitingPanel.Visibility = up ? Visibility.Collapsed : Visibility.Visible;
        StatusIcon.Glyph = up ? "\uE73E" : "\uE9A9"; // check vs cloud
        StatusIcon.Foreground = up
            ? new SolidColorBrush(Color.FromArgb(255, 16, 124, 16))
            : (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
    }

    private void OnContinue(object sender, RoutedEventArgs e)
    {
        _vm.StopDetectionPolling();
        _vm.Advance();
    }

    private async void OnOpenDownload(object sender, RoutedEventArgs e)
        => await _vm.OpenOllamaDownloadAsync();
}
```

7. Create `windows/src/AINotebook.App/Onboarding/PickModelsStep.xaml`. Two `ComboBox`es bound to `SelectedChatModel`/`SelectedEmbeddingModel`, choices `[llama3.2:3b, llama3.1:8b, mistral:7b]` and `[nomic-embed-text, mxbai-embed-large]` (per SHARED). Mirrors `PickModelsStepView.swift`.

```xml
<UserControl
    x:Class="AINotebook.App.Onboarding.PickModelsStep"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Grid Padding="40">
        <StackPanel Spacing="20" VerticalAlignment="Top" HorizontalAlignment="Stretch">
            <TextBlock x:Name="TitleText" FontSize="28" FontWeight="Bold" />
            <TextBlock x:Name="BodyText" TextWrapping="Wrap"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" />

            <ComboBox x:Name="ChatCombo" HorizontalAlignment="Stretch"
                      SelectionChanged="OnChatChanged" />
            <ComboBox x:Name="EmbedCombo" HorizontalAlignment="Stretch"
                      SelectionChanged="OnEmbedChanged" />

            <Button x:Name="ContinueButton" HorizontalAlignment="Right"
                    Style="{ThemeResource AccentButtonStyle}" Click="OnContinue">
                <Button.KeyboardAccelerators>
                    <KeyboardAccelerator Key="Enter" />
                </Button.KeyboardAccelerators>
            </Button>
        </StackPanel>
    </Grid>
</UserControl>
```

8. Create `windows/src/AINotebook.App/Onboarding/PickModelsStep.xaml.cs`. Populates the combos, sets the header (via `ComboBox.Header`), preselects the persisted value, and persists on change.

```csharp
using AINotebook.App.Services;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;

namespace AINotebook.App.Onboarding;

public sealed partial class PickModelsStep : UserControl
{
    private static readonly string[] ChatChoices = { "llama3.2:3b", "llama3.1:8b", "mistral:7b" };
    private static readonly string[] EmbedChoices = { "nomic-embed-text", "mxbai-embed-large" };

    private readonly OnboardingViewModel _vm;
    private readonly ISettingsService _settings;

    public PickModelsStep(OnboardingViewModel vm, ISettingsService settings, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        _settings = settings;

        TitleText.Text = strings.Get(StringKey.OnboardingPickModelsTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingPickModelsBody);
        ChatCombo.Header = strings.Get(StringKey.ChatModel);
        EmbedCombo.Header = strings.Get(StringKey.EmbeddingModel);
        ContinueButton.Content = strings.Get(StringKey.ContinueLabel);

        ChatCombo.ItemsSource = ChatChoices;
        EmbedCombo.ItemsSource = EmbedChoices;
        ChatCombo.SelectedItem = ChatChoices.Contains(settings.SelectedChatModel)
            ? settings.SelectedChatModel : ChatChoices[0];
        EmbedCombo.SelectedItem = EmbedChoices.Contains(settings.SelectedEmbeddingModel)
            ? settings.SelectedEmbeddingModel : EmbedChoices[0];
    }

    private void OnChatChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ChatCombo.SelectedItem is string s) _settings.SelectedChatModel = s;
    }

    private void OnEmbedChanged(object sender, SelectionChangedEventArgs e)
    {
        if (EmbedCombo.SelectedItem is string s) _settings.SelectedEmbeddingModel = s;
    }

    private void OnContinue(object sender, RoutedEventArgs e) => _vm.Advance();
}
```

9. Create `windows/src/AINotebook.App/Onboarding/PullModelsStep.xaml`. Two determinate `ProgressBar`s + status captions + an optional error block. Mirrors `PullModelsStepView.swift`; the pull starts on load.

```xml
<UserControl
    x:Class="AINotebook.App.Onboarding.PullModelsStep"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Loaded="OnLoaded">
    <Grid Padding="40">
        <StackPanel Spacing="24" VerticalAlignment="Top">
            <TextBlock x:Name="TitleText" FontSize="28" FontWeight="Bold" />
            <TextBlock x:Name="BodyText" TextWrapping="Wrap"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" />

            <StackPanel Spacing="4">
                <TextBlock x:Name="ChatTitle" FontWeight="SemiBold" />
                <ProgressBar x:Name="ChatBar" Minimum="0" Maximum="1" />
                <TextBlock x:Name="ChatStatus" FontSize="12"
                           Foreground="{ThemeResource TextFillColorTertiaryBrush}" />
            </StackPanel>

            <StackPanel Spacing="4">
                <TextBlock x:Name="EmbedTitle" FontWeight="SemiBold" />
                <ProgressBar x:Name="EmbedBar" Minimum="0" Maximum="1" />
                <TextBlock x:Name="EmbedStatus" FontSize="12"
                           Foreground="{ThemeResource TextFillColorTertiaryBrush}" />
            </StackPanel>

            <TextBlock x:Name="ErrorText" Visibility="Collapsed" TextWrapping="Wrap"
                       Foreground="{ThemeResource SystemFillColorCriticalBrush}" />
        </StackPanel>
    </Grid>
</UserControl>
```

10. Create `windows/src/AINotebook.App/Onboarding/PullModelsStep.xaml.cs`. Binds the two bars/status to the VM via `PropertyChanged`, kicks off `RunModelPullsAsync()` on load (the `.task` analogue).

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class PullModelsStep : UserControl
{
    private readonly OnboardingViewModel _vm;
    private bool _started;

    public PullModelsStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.OnboardingPullTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingPullBody);
        ChatTitle.Text = strings.Get(StringKey.OnboardingPullingChat);
        EmbedTitle.Text = strings.Get(StringKey.OnboardingPullingEmbedding);
        _vm.PropertyChanged += OnVmChanged;
        Apply();
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        if (_started) return;
        _started = true;
        await _vm.RunModelPullsAsync();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e) => Apply();

    private void Apply()
    {
        ChatBar.Value = _vm.ChatPullFraction;
        ChatStatus.Text = _vm.ChatPullStatus;
        EmbedBar.Value = _vm.EmbeddingPullFraction;
        EmbedStatus.Text = _vm.EmbeddingPullStatus;
        if (string.IsNullOrEmpty(_vm.PullError))
        {
            ErrorText.Visibility = Visibility.Collapsed;
        }
        else
        {
            ErrorText.Text = _vm.PullError;
            ErrorText.Visibility = Visibility.Visible;
        }
    }
}
```

11. Create `windows/src/AINotebook.App/Onboarding/DoneStep.xaml` — seal glyph + title + body + "Start using the app" (default). Mirrors `DoneStepView.swift`.

```xml
<UserControl
    x:Class="AINotebook.App.Onboarding.DoneStep"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center" Spacing="24" Padding="40" MaxWidth="520">
        <FontIcon Glyph="&#xE73E;" FontSize="56" HorizontalAlignment="Center"
                  Foreground="{ThemeResource SystemFillColorSuccessBrush}" />
        <TextBlock x:Name="TitleText" FontSize="34" FontWeight="Bold" HorizontalAlignment="Center" />
        <TextBlock x:Name="BodyText" TextWrapping="Wrap" TextAlignment="Center"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
        <Button x:Name="StartButton" HorizontalAlignment="Center"
                Style="{ThemeResource AccentButtonStyle}" Click="OnStart">
            <Button.KeyboardAccelerators>
                <KeyboardAccelerator Key="Enter" />
            </Button.KeyboardAccelerators>
        </Button>
    </StackPanel>
</UserControl>
```

12. Create `windows/src/AINotebook.App/Onboarding/DoneStep.xaml.cs`:

```csharp
using AINotebook.App.Services;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Onboarding;

public sealed partial class DoneStep : UserControl
{
    private readonly OnboardingViewModel _vm;

    public DoneStep(OnboardingViewModel vm, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _vm = vm;
        TitleText.Text = strings.Get(StringKey.OnboardingDoneTitle);
        BodyText.Text = strings.Get(StringKey.OnboardingDoneBody);
        StartButton.Content = strings.Get(StringKey.StartUsingApp);
    }

    private void OnStart(object sender, RoutedEventArgs e) => _vm.MarkCompleted();
}
```

**Verification:** Build on a Windows machine and run (`dotnet run --project windows/src/AINotebook.App`) on a clean profile (clear LocalSettings) and manually verify: (1) Welcome shows sparkle + localized title/body; Continue advances. (2) DetectOllama shows a spinning ProgressRing + "Waiting for Ollama to start…" + "Open download page"; with Ollama stopped it stays waiting; clicking download opens `https://ollama.com/download`; starting Ollama flips to the green check + "Ollama is running." + Continue within ~2s. (3) PickModels shows two combos defaulting to `llama3.2:3b` / `nomic-embed-text`; changing them persists. (4) PullModels auto-starts and the two ProgressBars fill to 100% as the chat then embedding model download (or shows an error if Ollama is unreachable); on success it advances. (5) Done shows the seal + "Start using the app"; clicking it sets `HasCompletedOnboarding` and raises `CompletedRequested` (frame swaps in the shell milestone). Switching the system display language to Czech shows Czech copy throughout.

**Commit:**

```bash
git add windows/src/AINotebook.App/Onboarding
git commit -m "feat(onboarding): OnboardingPage router + 5 step UserControls (Welcome/Detect/Pick/Pull/Done)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone M4 — Sources tab (SourceListView, AddSource dialog, IndexingStatusBadge)

> M4 ports `SourceListView.swift` + `AddSourceSheet.swift` + `IndexingStatusBadge.swift`. The list shows `NotebookStore.Sources(notebookId)` (already excludes the note shadow source), each row with a per-source status text. AddSource ingests via `IngestionService` (file/url/text); ingestion's `onChunksWritten` callback (wired in App.xaml.cs) kicks the `EmbeddingWorker`. The badge polls `UnembeddedCount(model)` every 1s.

### Task M4.1 — SourcesViewModel (list/load/delete, status mapping, async marshalling)

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/SourceItem.cs`
- Create `windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/ViewModels/SourceItem.cs` — a small observable row wrapper around the Core `Source` record, exposing the localized status text. Status changes asynchronously (ingestion → embedding), so this is observable for refresh.

```csharp
using AINotebook.App.Services;
using AINotebook.Core.Models;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public sealed partial class SourceItem : ObservableObject
{
    private readonly LocalizedStrings _strings;

    public long Id { get; }
    public string Title { get; }

    [ObservableProperty]
    public partial SourceStatus Status { get; set; }

    public SourceItem(Source source, LocalizedStrings strings)
    {
        _strings = strings;
        Id = source.Id!.Value;
        Title = source.Title;
        Status = source.Status;
    }

    public string StatusText => Status switch
    {
        SourceStatus.Pending => _strings.Get(StringKey.SourceStatusPending),
        SourceStatus.Chunking => _strings.Get(StringKey.SourceStatusChunking),
        SourceStatus.Ready => _strings.Get(StringKey.SourceStatusReady),
        SourceStatus.Error => _strings.Get(StringKey.SourceStatusError),
        _ => _strings.Get(StringKey.SourceStatusPending)
    };

    partial void OnStatusChanged(SourceStatus value) => OnPropertyChanged(nameof(StatusText));
}
```

2. Create `windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs`. Mirrors `SourceListView` lifecycle: `LoadAsync()` reads `store.Sources(notebookId)` (note: the store call is synchronous but funneled off the UI thread to keep the UI responsive, then results are marshalled back via `DispatcherQueue`); `DeleteAsync(id)` calls `store.DeleteSource(id)` then reloads. `ErrorMessage` surfaces failures inline (the mac sets `errorMessage` but it is rendered as a red caption — we keep it). The notebook id is set by the page.

```csharp
using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public sealed partial class SourcesViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly LocalizedStrings _strings;
    private readonly DispatcherQueue _dispatcher;

    public long NotebookId { get; set; }

    public ObservableCollection<SourceItem> Sources { get; } = new();

    [ObservableProperty]
    public partial bool IsEmpty { get; set; } = true;

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    public SourcesViewModel(NotebookStore store, LocalizedStrings strings)
    {
        _store = store;
        _strings = strings;
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    public async Task LoadAsync()
    {
        try
        {
            // Store access is synchronous + single-connection; run off the UI thread.
            var rows = await Task.Run(() => _store.Sources(NotebookId));
            void Apply()
            {
                Sources.Clear();
                foreach (var s in rows) Sources.Add(new SourceItem(s, _strings));
                IsEmpty = Sources.Count == 0;
                ErrorMessage = null;
            }
            if (!_dispatcher.HasThreadAccess) _dispatcher.TryEnqueue(Apply); else Apply();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
    }

    [RelayCommand]
    public async Task DeleteAsync(long id)
    {
        try
        {
            await Task.Run(() => _store.DeleteSource(id));
            await LoadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
    }
}
```

> Threading note (from the Core binding notes): `NotebookStore` is single-connection and not thread-safe; do not call store mutators concurrently with an active `EmbeddingWorker` drain. Reads here are short and tolerated; if a later milestone funnels all store access through a serial queue, swap `Task.Run` for that queue. For parity with the mac (which calls the store directly on the MainActor) the simple `Task.Run` is acceptable.

**Verification:** Build on a Windows machine (`dotnet build`). Behavioral verification in M4.3 (the page). Confirm `Sources`/`IsEmpty`/`ErrorMessage` update and that `DeleteSourceCommand` is generated.

**Commit** (combined with M4.2):

---

### Task M4.2 — AddSourceDialog (ContentDialog: file via FileOpenPicker+HWND, URL, raw text → IngestionService)

**Files:**
- Create `windows/src/AINotebook.App/Views/AddSourceDialog.xaml`
- Create `windows/src/AINotebook.App/Views/AddSourceDialog.xaml.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/Views/AddSourceDialog.xaml`. A `ContentDialog` with a 3-segment selector (file/url/text) via a `Pivot`-like `SelectorBar` (use a `ComboBox`-free segmented control: WinUI's `Microsoft.UI.Xaml.Controls.SelectorBar`). Confirm is the primary button (Enter), Cancel is the close button. A busy `ProgressRing` and an inline error `InfoBar` mirror `working`/`errorMessage`. Mirrors `AddSourceSheet.swift`.

```xml
<ContentDialog
    x:Class="AINotebook.App.Views.AddSourceDialog"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    PrimaryButtonClick="OnPrimaryClick"
    CloseButtonClick="OnCloseClick"
    DefaultButton="Primary">
    <Grid Width="480" MinHeight="320" RowSpacing="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <SelectorBar x:Name="ModeBar" Grid.Row="0" SelectionChanged="OnModeChanged">
            <SelectorBarItem x:Name="FileTab" />
            <SelectorBarItem x:Name="UrlTab" />
            <SelectorBarItem x:Name="TextTab" />
        </SelectorBar>

        <Grid Grid.Row="1">
            <!-- File -->
            <StackPanel x:Name="FilePanel" Spacing="8" VerticalAlignment="Top">
                <Button x:Name="ChooseFileButton" Click="OnChooseFile" />
                <TextBlock x:Name="ChosenFileText" Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
            </StackPanel>
            <!-- URL -->
            <StackPanel x:Name="UrlPanel" Spacing="8" VerticalAlignment="Top" Visibility="Collapsed">
                <TextBox x:Name="UrlBox" TextChanged="OnInputChanged" />
            </StackPanel>
            <!-- Text -->
            <StackPanel x:Name="TextPanel" Spacing="8" VerticalAlignment="Top" Visibility="Collapsed">
                <TextBox x:Name="RawTitleBox" TextChanged="OnInputChanged" />
                <TextBox x:Name="RawTextBox" AcceptsReturn="True" TextWrapping="Wrap"
                         MinHeight="120" TextChanged="OnInputChanged"
                         ScrollViewer.VerticalScrollBarVisibility="Auto" />
            </StackPanel>
        </Grid>

        <ProgressRing x:Name="Busy" Grid.Row="2" IsActive="False" Width="22" Height="22"
                      HorizontalAlignment="Left" />
        <InfoBar x:Name="ErrorBar" Grid.Row="3" Severity="Error" IsOpen="False" IsClosable="True" />
    </Grid>
</ContentDialog>
```

2. Create `windows/src/AINotebook.App/Views/AddSourceDialog.xaml.cs`. Implements `canSubmit` per tab exactly (file: a file chosen; url: parses and scheme starts with "http"; text: title and text non-empty trimmed); the file picker uses `FileOpenPicker` + `WindowNative.GetWindowHandle(App.MainWindow)` + `InitializeWithWindow.Initialize` with the six filters (`.pdf .txt .md .docx .pptx .xlsx`); `submit()` dispatches to `IngestFileAsync`/`IngestUrlAsync`/`IngestRawTextAsync`. Because `ContentDialog.PrimaryButtonClick` closes the dialog by default, we defer the close and cancel it when validation fails or on error (keep the dialog open, like the mac sheet). Returns success so the caller reloads.

```csharp
using AINotebook.App.Services;
using AINotebook.Core.Ingestion;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;
using WinRT.Interop;

namespace AINotebook.App.Views;

public sealed partial class AddSourceDialog : ContentDialog
{
    private enum Mode { File, Url, Text }

    private readonly IngestionService _ingestion;
    private readonly long _notebookId;
    private Mode _mode = Mode.File;
    private StorageFile? _file;
    private bool _working;

    public bool DidIngest { get; private set; }

    public AddSourceDialog(IngestionService ingestion, long notebookId, LocalizedStrings strings)
    {
        this.InitializeComponent();
        _ingestion = ingestion;
        _notebookId = notebookId;

        Title = strings.Get(StringKey.AddSourceSheetTitle);
        PrimaryButtonText = strings.Get(StringKey.AddSourceConfirm);
        CloseButtonText = strings.Get(StringKey.CancelButton);

        FileTab.Text = strings.Get(StringKey.AddSourceFromFile);
        UrlTab.Text = strings.Get(StringKey.AddSourceFromURL);
        TextTab.Text = strings.Get(StringKey.AddSourceFromText);
        ChooseFileButton.Content = strings.Get(StringKey.AddSourceFromFile);
        UrlBox.PlaceholderText = strings.Get(StringKey.AddSourceURLPlaceholder);
        RawTitleBox.PlaceholderText = strings.Get(StringKey.AddSourceTitlePlaceholder);
        RawTextBox.PlaceholderText = strings.Get(StringKey.AddSourceTextPlaceholder);

        ModeBar.SelectedItem = FileTab;
        UpdateCanSubmit();
    }

    private void OnModeChanged(SelectorBar sender, SelectorBarSelectionChangedEventArgs args)
    {
        _mode = ModeBar.SelectedItem == UrlTab ? Mode.Url
              : ModeBar.SelectedItem == TextTab ? Mode.Text
              : Mode.File;
        FilePanel.Visibility = _mode == Mode.File ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        UrlPanel.Visibility = _mode == Mode.Url ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        TextPanel.Visibility = _mode == Mode.Text ? Microsoft.UI.Xaml.Visibility.Visible : Microsoft.UI.Xaml.Visibility.Collapsed;
        UpdateCanSubmit();
    }

    private void OnInputChanged(object sender, TextChangedEventArgs e) => UpdateCanSubmit();

    private bool CanSubmit() => _mode switch
    {
        Mode.File => _file is not null,
        Mode.Url => Uri.TryCreate(UrlBox.Text, UriKind.Absolute, out var u)
                    && (u.Scheme.StartsWith("http", StringComparison.OrdinalIgnoreCase)),
        Mode.Text => !string.IsNullOrWhiteSpace(RawTitleBox.Text)
                     && !string.IsNullOrWhiteSpace(RawTextBox.Text),
        _ => false
    };

    private void UpdateCanSubmit() => IsPrimaryButtonEnabled = !_working && CanSubmit();

    private async void OnChooseFile(object sender, Microsoft.UI.Xaml.RoutedEventArgs e)
    {
        var picker = new FileOpenPicker
        {
            ViewMode = PickerViewMode.List,
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary
        };
        foreach (var ext in new[] { ".pdf", ".txt", ".md", ".docx", ".pptx", ".xlsx" })
            picker.FileTypeFilter.Add(ext);

        var hwnd = WindowNative.GetWindowHandle(App.MainWindow);
        InitializeWithWindow.Initialize(picker, hwnd);

        var picked = await picker.PickSingleFileAsync();
        if (picked is not null)
        {
            _file = picked;
            ChosenFileText.Text = picked.Name;
            UpdateCanSubmit();
        }
    }

    private async void OnPrimaryClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        var deferral = args.GetDeferral();
        args.Cancel = true; // keep open unless ingestion succeeds

        if (!CanSubmit() || _working) { deferral.Complete(); return; }

        _working = true;
        ErrorBar.IsOpen = false;
        Busy.IsActive = true;
        IsPrimaryButtonEnabled = false;
        IsSecondaryButtonEnabled = false;

        try
        {
            switch (_mode)
            {
                case Mode.File:
                    await _ingestion.IngestFileAsync(new Uri(_file!.Path), _notebookId);
                    break;
                case Mode.Url:
                    await _ingestion.IngestUrlAsync(new Uri(UrlBox.Text), _notebookId);
                    break;
                case Mode.Text:
                    await _ingestion.IngestRawTextAsync(RawTitleBox.Text, RawTextBox.Text, _notebookId);
                    break;
            }
            DidIngest = true;
            args.Cancel = false; // allow close
        }
        catch (Exception ex)
        {
            ErrorBar.Message = ex.ToString();
            ErrorBar.IsOpen = true;
        }
        finally
        {
            _working = false;
            Busy.IsActive = false;
            IsSecondaryButtonEnabled = true;
            UpdateCanSubmit();
            deferral.Complete();
        }
    }

    private void OnCloseClick(ContentDialog sender, ContentDialogButtonClickEventArgs args)
    {
        // Cancel button: just dismiss (mirrors the mac Cancel).
    }
}
```

> The mac picks a `file://` URL via `NSOpenPanel`; here `FileOpenPicker` returns a `StorageFile` and `IngestFileAsync` takes a `Uri`, so we pass `new Uri(file.Path)`. `IngestFileAsync` throws `IngestionException.UnsupportedExtension` before creating a row for unknown extensions — the filters prevent that, but the catch still surfaces it. After a successful ingest the wired `onChunksWritten` callback (App.xaml.cs) kicks the worker automatically.

**Verification:** Build on a Windows machine and verify (in M4.3 page context): the dialog shows three segments; File opens the picker filtered to the six extensions and shows the chosen file name; URL enables Add only for `http(s)` URLs; Text enables Add only when both title and body are non-empty; Add shows the busy ring and disables buttons; on success the dialog closes and `DidIngest` is true; on error it stays open with the red InfoBar.

**Commit** (M4.1 + M4.2 together):

```bash
git add windows/src/AINotebook.App/ViewModels/SourceItem.cs windows/src/AINotebook.App/ViewModels/SourcesViewModel.cs windows/src/AINotebook.App/Views/AddSourceDialog.xaml windows/src/AINotebook.App/Views/AddSourceDialog.xaml.cs
git commit -m "feat(sources): SourcesViewModel + AddSourceDialog (file/url/text -> IngestionService)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task M4.3 — IndexingStatusBadge (1s poll of UnembeddedCount) + SourceListPage

**Files:**
- Create `windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml`
- Create `windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml.cs`
- Create `windows/src/AINotebook.App/Views/SourceListPage.xaml`
- Create `windows/src/AINotebook.App/Views/SourceListPage.xaml.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml`. Mirrors `IndexingStatusBadge.swift`: green check + "Indexed" when 0 pending, else a small `ProgressRing` + "Indexing N…".

```xml
<UserControl
    x:Class="AINotebook.App.Views.IndexingStatusBadge"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Loaded="OnLoaded" Unloaded="OnUnloaded">
    <StackPanel Orientation="Horizontal" Spacing="6" VerticalAlignment="Center">
        <FontIcon x:Name="CheckIcon" Glyph="&#xE73E;" FontSize="14"
                  Foreground="{ThemeResource SystemFillColorSuccessBrush}" />
        <ProgressRing x:Name="Spinner" Width="14" Height="14" IsActive="False" Visibility="Collapsed" />
        <TextBlock x:Name="BadgeText" FontSize="12"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
    </StackPanel>
</UserControl>
```

2. Create `windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml.cs`. Uses a `DispatcherQueueTimer` (1s) calling `store.UnembeddedCount(model)`; toggles check vs spinner; formats `IndexingInProgress` with the count. Starts on load, stops on unload.

```csharp
using AINotebook.App.Services;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class IndexingStatusBadge : UserControl
{
    private readonly NotebookStore _store;
    private readonly ISettingsService _settings;
    private readonly LocalizedStrings _strings;
    private DispatcherQueueTimer? _timer;

    public IndexingStatusBadge()
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _store = sp.GetRequiredService<NotebookStore>();
        _settings = sp.GetRequiredService<ISettingsService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        Apply(0);
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        var dq = DispatcherQueue.GetForCurrentThread();
        _timer = dq.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        Tick();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        _timer?.Stop();
        _timer = null;
    }

    private void Tick()
    {
        int pending;
        try { pending = _store.UnembeddedCount(_settings.SelectedEmbeddingModel); }
        catch { pending = 0; }
        Apply(pending);
    }

    private void Apply(int pending)
    {
        if (pending == 0)
        {
            CheckIcon.Visibility = Visibility.Visible;
            Spinner.Visibility = Visibility.Collapsed;
            Spinner.IsActive = false;
            BadgeText.Text = _strings.Get(StringKey.IndexingComplete);
        }
        else
        {
            CheckIcon.Visibility = Visibility.Collapsed;
            Spinner.Visibility = Visibility.Visible;
            Spinner.IsActive = true;
            BadgeText.Text = string.Format(_strings.Get(StringKey.IndexingInProgress), pending);
        }
    }
}
```

3. Create `windows/src/AINotebook.App/Views/SourceListPage.xaml`. Mirrors `SourceListView.swift`: header (title + `IndexingStatusBadge` + Add button); empty-state (tray glyph + text + prominent Add); else a `ListView` of sources with title + status caption + per-row trash button; trailing error caption.

```xml
<UserControl
    x:Class="AINotebook.App.Views.SourceListPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:vm="using:AINotebook.App.ViewModels"
    xmlns:views="using:AINotebook.App.Views">
    <Grid Padding="20" RowSpacing="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <Grid Grid.Row="0" ColumnSpacing="12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="HeaderTitle" Grid.Column="0" FontSize="20" FontWeight="Bold"
                       VerticalAlignment="Center" />
            <views:IndexingStatusBadge Grid.Column="1" VerticalAlignment="Center" />
            <Button x:Name="AddButton" Grid.Column="2" Click="OnAdd" />
        </Grid>

        <!-- Empty state -->
        <StackPanel x:Name="EmptyPanel" Grid.Row="1" Spacing="12"
                    HorizontalAlignment="Center" VerticalAlignment="Center"
                    Visibility="{x:Bind ViewModel.IsEmpty, Mode=OneWay}">
            <FontIcon Glyph="&#xE8F1;" FontSize="40" HorizontalAlignment="Center"
                      Foreground="{ThemeResource TextFillColorTertiaryBrush}" />
            <TextBlock x:Name="EmptyText" TextAlignment="Center" TextWrapping="Wrap"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
            <Button x:Name="EmptyAddButton" HorizontalAlignment="Center"
                    Style="{ThemeResource AccentButtonStyle}" Click="OnAdd" />
        </StackPanel>

        <!-- List -->
        <ListView x:Name="SourceList" Grid.Row="1"
                  ItemsSource="{x:Bind ViewModel.Sources, Mode=OneWay}"
                  SelectionMode="None">
            <ListView.ItemTemplate>
                <DataTemplate x:DataType="vm:SourceItem">
                    <Grid ColumnSpacing="8" Padding="0,4">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock Text="{x:Bind Title}" FontWeight="SemiBold" />
                            <TextBlock Text="{x:Bind StatusText, Mode=OneWay}" FontSize="12"
                                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                        </StackPanel>
                        <Button Grid.Column="1" Background="Transparent" BorderThickness="0"
                                Click="OnDeleteRow" Tag="{x:Bind Id}">
                            <FontIcon Glyph="&#xE74D;" FontSize="16" />
                        </Button>
                    </Grid>
                </DataTemplate>
            </ListView.ItemTemplate>
        </ListView>

        <InfoBar x:Name="ErrorBar" Grid.Row="2" Severity="Error" IsClosable="True"
                 IsOpen="{x:Bind ViewModel.HasError, Mode=OneWay}"
                 Message="{x:Bind ViewModel.ErrorMessage, Mode=OneWay}" />
    </Grid>
</UserControl>
```

> The empty panel and the list both sit in row 1; toggle the list's visibility opposite to `IsEmpty` in code-behind (a converter is avoided to keep the file count down). Add a small `HasError` computed bool to `SourcesViewModel` (`=> !string.IsNullOrEmpty(ErrorMessage)`), notified from `OnErrorMessageChanged`.

4. Create `windows/src/AINotebook.App/Views/SourceListPage.xaml.cs`. Resolves the VM (constructed with the notebook id), loads on load, wires the Add button to show `AddSourceDialog` and reload on dismiss (mirrors `.sheet(onDismiss:)`), and the per-row trash button to `DeleteSourceCommand`.

```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ingestion;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class SourceListPage : UserControl
{
    public SourcesViewModel ViewModel { get; }

    private readonly IngestionService _ingestion;
    private readonly LocalizedStrings _strings;

    public SourceListPage(Notebook notebook)
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        _ingestion = sp.GetRequiredService<IngestionService>();
        _strings = sp.GetRequiredService<LocalizedStrings>();
        var store = sp.GetRequiredService<NotebookStore>();
        ViewModel = new SourcesViewModel(store, _strings) { NotebookId = notebook.Id!.Value };

        HeaderTitle.Text = _strings.Get(StringKey.SourcesSectionTitle);
        AddButton.Content = _strings.Get(StringKey.AddSourceButton);
        EmptyText.Text = _strings.Get(StringKey.NoSourcesEmptyState);
        EmptyAddButton.Content = _strings.Get(StringKey.AddSourceButton);

        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(SourcesViewModel.IsEmpty)) ApplyEmptyState();
        };
        Loaded += async (_, _) => { await ViewModel.LoadAsync(); ApplyEmptyState(); };
    }

    private void ApplyEmptyState()
        => SourceList.Visibility = ViewModel.IsEmpty ? Visibility.Collapsed : Visibility.Visible;

    private async void OnAdd(object sender, RoutedEventArgs e)
    {
        var dialog = new AddSourceDialog(_ingestion, ViewModel.NotebookId, _strings)
        {
            XamlRoot = this.XamlRoot
        };
        await dialog.ShowAsync();
        // Always reload on dismiss (mirrors .sheet onDismiss: reload).
        await ViewModel.LoadAsync();
        ApplyEmptyState();
    }

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: long id })
            await ViewModel.DeleteAsync(id);
    }
}
```

> Add the `HasError` member to `SourcesViewModel` (M4.1) to satisfy the `x:Bind`:
>
> ```csharp
> public bool HasError => !string.IsNullOrEmpty(ErrorMessage);
> partial void OnErrorMessageChanged(string? value) => OnPropertyChanged(nameof(HasError));
> ```

**Verification:** Build on a Windows machine and (within the notebook detail shell, or a temporary test harness page) manually verify: the Sources tab header shows "Sources" + the indexing badge + "Add source"; with no sources the tray empty-state appears with a prominent Add; adding a file/URL/text source ingests it, the list refreshes on dialog dismiss, and a new row appears with a status that progresses Pending → Processing → Ready; the indexing badge flips from "Indexing N…" to "Indexed" within ~1s of the embedding worker draining; the per-row trash deletes the source and the list refreshes; switching language re-localizes the header, badge, and status text. (The shadow note source is never listed because `store.Sources` excludes it.)

**Commit:**

```bash
git add windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml windows/src/AINotebook.App/Views/IndexingStatusBadge.xaml.cs windows/src/AINotebook.App/Views/SourceListPage.xaml windows/src/AINotebook.App/Views/SourceListPage.xaml.cs
git commit -m "feat(sources): IndexingStatusBadge (1s poll) + SourceListPage (list/empty/add/delete)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Milestone M9 — Settings + Model management

> M9 ports `SettingsView.swift` + `ModelManagementSheet.swift`. Settings: language switch (→ `PrimaryLanguageOverride` + persist + live re-localize), chat/embedding model pickers populated from `OllamaClient.ListModelsAsync` (keeping the current value selectable even if not listed), a re-embed destructive confirm (`DeleteAllEmbeddings(model)` + `worker.Kick()`), and the version row. ModelManagement: list via `ListModelsAsync`, pull via `PullModelAsync` (streaming progress), delete via `DeleteModelAsync`, refresh.

### Task M9.1 — SettingsViewModel (model refresh, language switch, re-embed)

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs`. Mirrors `SettingsView.swift` logic: `RefreshModelsAsync()` = `ollama.ListModelsAsync()` → `AvailableModels = models.Select(m => m.Name).OrderBy(...)`; on error → empty. `ReembedAllAsync()` = `store.DeleteAllEmbeddings(settings.SelectedEmbeddingModel)` then `worker.Kick()`; on error → `SettingsError`. Language and model selections delegate to `ISettingsService` (which persists); the language setter also sets `PrimaryLanguageOverride`. Exposes `AppLanguage` choices and `Version`.

```csharp
using System.Collections.ObjectModel;
using AINotebook.App.Services;
using AINotebook.Core;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class SettingsViewModel : ObservableObject
{
    private readonly ISettingsService _settings;
    private readonly NotebookStore _store;
    private readonly OllamaClient _ollama;
    private readonly EmbeddingWorker _worker;

    public ObservableCollection<string> AvailableModels { get; } = new();

    [ObservableProperty]
    public partial bool ModelsAvailable { get; set; }

    [ObservableProperty]
    public partial string? SettingsError { get; set; }

    public string Version => AINotebookVersion.Current;

    public AppLanguage[] Languages { get; } = { AppLanguage.English, AppLanguage.Czech };

    public SettingsViewModel(
        ISettingsService settings, NotebookStore store, OllamaClient ollama, EmbeddingWorker worker)
    {
        _settings = settings;
        _store = store;
        _ollama = ollama;
        _worker = worker;
    }

    // --- Two-way passthroughs to the persisted settings service ---

    public AppLanguage Language
    {
        get => _settings.Language;
        set
        {
            if (_settings.Language == value) return;
            _settings.Language = value;
            Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride =
                value.RawValue() == "cs" ? "cs-CZ" : "en-US";
            OnPropertyChanged();
        }
    }

    public string SelectedChatModel
    {
        get => _settings.SelectedChatModel;
        set { if (_settings.SelectedChatModel != value) { _settings.SelectedChatModel = value; OnPropertyChanged(); } }
    }

    public string SelectedEmbeddingModel
    {
        get => _settings.SelectedEmbeddingModel;
        set
        {
            if (_settings.SelectedEmbeddingModel != value)
            {
                _settings.SelectedEmbeddingModel = value;
                OnPropertyChanged();
                OnPropertyChanged(nameof(SelectedEmbeddingModel));
            }
        }
    }

    public async Task RefreshModelsAsync()
    {
        try
        {
            var models = await _ollama.ListModelsAsync();
            var names = models.Select(m => m.Name).OrderBy(n => n, StringComparer.Ordinal).ToList();
            AvailableModels.Clear();
            foreach (var n in names) AvailableModels.Add(n);
            ModelsAvailable = AvailableModels.Count > 0;
        }
        catch
        {
            AvailableModels.Clear();
            ModelsAvailable = false;
        }
    }

    [RelayCommand]
    public async Task ReembedAllAsync()
    {
        try
        {
            await Task.Run(() => _store.DeleteAllEmbeddings(_settings.SelectedEmbeddingModel));
            _worker.Kick();
            SettingsError = null;
        }
        catch (Exception ex)
        {
            SettingsError = ex.ToString();
        }
    }
}
```

> Re-embed mirrors the mac exactly: clear embeddings for the current embedding model, then `Kick()` the worker to re-embed all chunks. Engines captured the model at startup, so re-selecting an embedding model in Settings does not rebuild the `Embedder`/`Retriever` (parity with the mac; the re-embed flow is the user's path to switch model coverage). Keep that behavior — no invented "rebuild engines" feature.

**Verification:** Build on a Windows machine. Behavioral verification in M9.3.

**Commit** (combined with M9.2):

---

### Task M9.2 — ModelManagementViewModel (list, pull with progress, delete, refresh)

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/OllamaModelItem.cs`
- Create `windows/src/AINotebook.App/ViewModels/ModelManagementViewModel.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/ViewModels/OllamaModelItem.cs` — a row wrapper exposing the model name and a binary byte-size string (mirrors the mac `ByteCountFormatter(.binary)`).

```csharp
using AINotebook.Core.Ollama;

namespace AINotebook.App.ViewModels;

public sealed class OllamaModelItem
{
    public string Name { get; }
    public string SizeText { get; }

    public OllamaModelItem(OllamaModel model)
    {
        Name = model.Name;
        SizeText = FormatBinary(model.Size);
    }

    private static string FormatBinary(long bytes)
    {
        string[] units = { "bytes", "KiB", "MiB", "GiB", "TiB" };
        double size = bytes;
        int u = 0;
        while (size >= 1024 && u < units.Length - 1) { size /= 1024; u++; }
        return u == 0 ? $"{bytes} {units[0]}" : $"{size:0.##} {units[u]}";
    }
}
```

2. Create `windows/src/AINotebook.App/ViewModels/ModelManagementViewModel.cs`. Mirrors `ModelManagementSheet.swift`: `ReloadAsync()` = `ListModelsAsync` → `Models`; `DeleteAsync(name)` = `DeleteModelAsync` then reload (sets `Working`); `PullAsync()` = trims `PullName`, iterates `PullModelAsync` updating `PullProgress = event.Status`, then clears the name and reloads; `Working` disables controls; `ErrorMessage` surfaces failures.

```csharp
using System.Collections.ObjectModel;
using AINotebook.Core.Ollama;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public sealed partial class ModelManagementViewModel : ObservableObject
{
    private readonly OllamaClient _ollama;

    public ObservableCollection<OllamaModelItem> Models { get; } = new();

    [ObservableProperty]
    public partial string PullName { get; set; } = "";

    [ObservableProperty]
    public partial bool Working { get; set; }

    [ObservableProperty]
    public partial string PullProgress { get; set; } = "";

    [ObservableProperty]
    public partial string? ErrorMessage { get; set; }

    public ModelManagementViewModel(OllamaClient ollama) => _ollama = ollama;

    public async Task ReloadAsync()
    {
        try
        {
            var models = await _ollama.ListModelsAsync();
            Models.Clear();
            foreach (var m in models) Models.Add(new OllamaModelItem(m));
            ErrorMessage = null;
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
    }

    [RelayCommand]
    public async Task DeleteAsync(string name)
    {
        Working = true;
        try
        {
            await _ollama.DeleteModelAsync(name);
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
        finally { Working = false; }
    }

    [RelayCommand]
    public async Task PullAsync()
    {
        var name = PullName.Trim();
        if (name.Length == 0) return;
        Working = true;
        PullProgress = "Starting…";
        try
        {
            await foreach (var ev in _ollama.PullModelAsync(name))
                PullProgress = ev.Status;
            PullName = "";
            await ReloadAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
        }
        finally
        {
            Working = false;
            PullProgress = "";
        }
    }
}
```

**Verification:** Build on a Windows machine. Behavioral verification in M9.3.

**Commit** (M9.1 + M9.2 together):

```bash
git add windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs windows/src/AINotebook.App/ViewModels/OllamaModelItem.cs windows/src/AINotebook.App/ViewModels/ModelManagementViewModel.cs
git commit -m "feat(settings): SettingsViewModel + ModelManagementViewModel (list/pull/delete/refresh)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task M9.3 — SettingsDialog + ModelManagementDialog (XAML)

**Files:**
- Create `windows/src/AINotebook.App/Views/ModelManagementDialog.xaml`
- Create `windows/src/AINotebook.App/Views/ModelManagementDialog.xaml.cs`
- Create `windows/src/AINotebook.App/Views/SettingsDialog.xaml`
- Create `windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs`

**Steps:**

1. Create `windows/src/AINotebook.App/Views/ModelManagementDialog.xaml`. Mirrors `ModelManagementSheet.swift`: a `ListView` of installed models (name + size + per-row trash, disabled while working), a pull row (TextBox + Pull button), a pull-progress `ProgressBar`/text, an error `InfoBar`, and a Refresh + Cancel footer.

```xml
<ContentDialog
    x:Class="AINotebook.App.Views.ModelManagementDialog"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:vm="using:AINotebook.App.ViewModels"
    CloseButtonClick="OnClose">
    <Grid Width="520" MinHeight="360" RowSpacing="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
        </Grid.RowDefinitions>

        <TextBlock x:Name="TitleText" Grid.Row="0" FontSize="20" FontWeight="Bold" />

        <ListView x:Name="ModelList" Grid.Row="1" MinHeight="200"
                  ItemsSource="{x:Bind ViewModel.Models, Mode=OneWay}" SelectionMode="None">
            <ListView.ItemTemplate>
                <DataTemplate x:DataType="vm:OllamaModelItem">
                    <Grid ColumnSpacing="8" Padding="0,4">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <StackPanel Grid.Column="0">
                            <TextBlock Text="{x:Bind Name}" FontWeight="SemiBold" />
                            <TextBlock Text="{x:Bind SizeText}" FontSize="12"
                                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                        </StackPanel>
                        <Button Grid.Column="1" Background="Transparent" BorderThickness="0"
                                Click="OnDeleteRow" Tag="{x:Bind Name}">
                            <FontIcon Glyph="&#xE74D;" FontSize="16" />
                        </Button>
                    </Grid>
                </DataTemplate>
            </ListView.ItemTemplate>
        </ListView>

        <Grid Grid.Row="2" ColumnSpacing="8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <TextBox x:Name="PullBox" Grid.Column="0"
                     Text="{x:Bind ViewModel.PullName, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" />
            <Button x:Name="PullButton" Grid.Column="1" Click="OnPull" />
        </Grid>

        <ProgressBar x:Name="PullBar" Grid.Row="3" IsIndeterminate="True" Visibility="Collapsed" />
        <TextBlock x:Name="PullProgressText" Grid.Row="3" Margin="0,16,0,0" FontSize="12"
                   Foreground="{ThemeResource TextFillColorSecondaryBrush}" />

        <InfoBar x:Name="ErrorBar" Grid.Row="4" Severity="Error" IsClosable="True" IsOpen="False" />

        <Button x:Name="RefreshButton" Grid.Row="5" HorizontalAlignment="Left" Click="OnRefresh" />
    </Grid>
</ContentDialog>
```

2. Create `windows/src/AINotebook.App/Views/ModelManagementDialog.xaml.cs`. Resolves the VM from DI, sets localized text, loads on open, wires buttons, and reflects `Working`/`PullProgress`/`ErrorMessage`.

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Ollama;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class ModelManagementDialog : ContentDialog
{
    public ModelManagementViewModel ViewModel { get; }

    public ModelManagementDialog(LocalizedStrings strings)
    {
        this.InitializeComponent();
        var sp = App.Current.Services;
        ViewModel = new ModelManagementViewModel(sp.GetRequiredService<OllamaClient>());

        TitleText.Text = strings.Get(StringKey.ManageModelsTitle);
        PullBox.PlaceholderText = strings.Get(StringKey.ManageModelsPullPlaceholder);
        PullButton.Content = strings.Get(StringKey.ManageModelsPullButton);
        RefreshButton.Content = strings.Get(StringKey.ManageModelsRefreshButton);
        CloseButtonText = strings.Get(StringKey.CancelButton);

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) => await ViewModel.ReloadAsync();
        ApplyState();
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e) => ApplyState();

    private void ApplyState()
    {
        var pulling = ViewModel.Working && !string.IsNullOrEmpty(ViewModel.PullProgress);
        PullBar.Visibility = pulling ? Visibility.Visible : Visibility.Collapsed;
        PullProgressText.Text = ViewModel.PullProgress;
        PullButton.IsEnabled = !ViewModel.Working
            && !string.IsNullOrWhiteSpace(ViewModel.PullName);
        RefreshButton.IsEnabled = !ViewModel.Working;
        if (string.IsNullOrEmpty(ViewModel.ErrorMessage))
        {
            ErrorBar.IsOpen = false;
        }
        else
        {
            ErrorBar.Message = ViewModel.ErrorMessage;
            ErrorBar.IsOpen = true;
        }
    }

    private async void OnPull(object sender, RoutedEventArgs e) => await ViewModel.PullAsync();
    private async void OnRefresh(object sender, RoutedEventArgs e) => await ViewModel.ReloadAsync();

    private async void OnDeleteRow(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string name }) await ViewModel.DeleteAsync(name);
    }

    private void OnClose(ContentDialog sender, ContentDialogButtonClickEventArgs args) { }
}
```

3. Create `windows/src/AINotebook.App/Views/SettingsDialog.xaml`. Mirrors `SettingsView.swift` top-to-bottom: title; a language segmented control (`RadioButtons` horizontal, or a `ComboBox` — use `ComboBox` bound to the two languages for simplicity); divider; two model `ComboBox`es (or an "unavailable" note); "Manage models…" button; divider; embedding section (current model row + destructive "Re-embed all sources"); error InfoBar; version row; Done close button. Fixed-ish 460×540.

```xml
<ContentDialog
    x:Class="AINotebook.App.Views.SettingsDialog"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <ScrollViewer Width="460" Height="540">
        <StackPanel Spacing="20" Padding="4">
            <TextBlock x:Name="TitleText" FontSize="20" FontWeight="Bold" />

            <ComboBox x:Name="LanguageCombo" HorizontalAlignment="Stretch"
                      SelectionChanged="OnLanguageChanged" />

            <Border Height="1" Background="{ThemeResource DividerStrokeColorDefaultBrush}" />

            <StackPanel Spacing="8">
                <ComboBox x:Name="ChatModelCombo" HorizontalAlignment="Stretch"
                          SelectionChanged="OnChatModelChanged" />
                <ComboBox x:Name="EmbedModelCombo" HorizontalAlignment="Stretch"
                          SelectionChanged="OnEmbedModelChanged" />
                <TextBlock x:Name="ModelsUnavailableText" Visibility="Collapsed" FontSize="12"
                           TextWrapping="Wrap" Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                <Button x:Name="ManageModelsButton" Click="OnManageModels" />
            </StackPanel>

            <Border Height="1" Background="{ThemeResource DividerStrokeColorDefaultBrush}" />

            <StackPanel Spacing="8">
                <TextBlock x:Name="EmbeddingSectionTitle" FontWeight="SemiBold" />
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto" />
                        <ColumnDefinition Width="*" />
                    </Grid.ColumnDefinitions>
                    <TextBlock x:Name="CurrentModelLabel" Grid.Column="0" />
                    <TextBlock x:Name="CurrentModelValue" Grid.Column="1" HorizontalAlignment="Right"
                               FontFamily="Consolas"
                               Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                </Grid>
                <Button x:Name="ReembedButton" Click="OnReembed"
                        Style="{ThemeResource AccentButtonStyle}" />
            </StackPanel>

            <InfoBar x:Name="ErrorBar" Severity="Error" IsClosable="True" IsOpen="False" />

            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto" />
                    <ColumnDefinition Width="*" />
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="VersionLabel" Grid.Column="0"
                           Foreground="{ThemeResource TextFillColorSecondaryBrush}" />
                <TextBlock x:Name="VersionValue" Grid.Column="1" HorizontalAlignment="Right"
                           FontFamily="Consolas" />
            </Grid>
        </StackPanel>
    </ScrollViewer>
</ContentDialog>
```

4. Create `windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs`. Resolves the VM from DI, sets localized text, populates the language combo, populates the model combos from `RefreshModelsAsync()` keeping the current selection selectable even if Ollama does not list it (mirrors the mac extra-tag behavior), wires the re-embed confirm (a nested `ContentDialog` confirm) + `Manage models…` (opens `ModelManagementDialog`, then refreshes), and the version row. The Done button is the dialog's primary/close button.

```csharp
using System.ComponentModel;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using AINotebook.Core.Ollama;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;

namespace AINotebook.App.Views;

public sealed partial class SettingsDialog : ContentDialog
{
    public SettingsViewModel ViewModel { get; }
    private readonly LocalizedStrings _strings;
    private bool _suppress;

    public SettingsDialog(LocalizedStrings strings)
    {
        this.InitializeComponent();
        _strings = strings;
        var sp = App.Current.Services;
        ViewModel = new SettingsViewModel(
            sp.GetRequiredService<ISettingsService>(),
            sp.GetRequiredService<NotebookStore>(),
            sp.GetRequiredService<OllamaClient>(),
            sp.GetRequiredService<EmbeddingWorker>());

        CloseButtonText = "Done";
        ApplyLocalizedText();

        // Language combo: the two AppLanguage display names.
        LanguageCombo.ItemsSource = ViewModel.Languages.Select(l => l.DisplayName()).ToList();
        LanguageCombo.SelectedIndex = ViewModel.Language == AppLanguage.Czech ? 1 : 0;

        VersionValue.Text = ViewModel.Version;
        CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;

        ViewModel.PropertyChanged += OnVmChanged;
        Opened += async (_, _) => await LoadModelsAsync();
    }

    private void ApplyLocalizedText()
    {
        Title = _strings.Get(StringKey.Settings);
        TitleText.Text = _strings.Get(StringKey.Settings);
        ChatModelCombo.Header = _strings.Get(StringKey.ChatModelPickerLabel);
        EmbedModelCombo.Header = _strings.Get(StringKey.EmbeddingModelPickerLabel);
        ModelsUnavailableText.Text = "Models unavailable — start Ollama or refresh in Manage models.";
        ManageModelsButton.Content = _strings.Get(StringKey.ManageModelsButton);
        EmbeddingSectionTitle.Text = _strings.Get(StringKey.EmbeddingSectionTitle);
        CurrentModelLabel.Text = _strings.Get(StringKey.CurrentModelLabel);
        ReembedButton.Content = _strings.Get(StringKey.ReembedButton);
        VersionLabel.Text = _strings.Get(StringKey.Version);
    }

    private async Task LoadModelsAsync()
    {
        await ViewModel.RefreshModelsAsync();
        PopulateModelCombos();
    }

    private void PopulateModelCombos()
    {
        _suppress = true;

        // Keep the current selection selectable even if Ollama doesn't list it.
        var chatItems = ViewModel.AvailableModels.ToList();
        if (!chatItems.Contains(ViewModel.SelectedChatModel)) chatItems.Add(ViewModel.SelectedChatModel);
        var embedItems = ViewModel.AvailableModels.ToList();
        if (!embedItems.Contains(ViewModel.SelectedEmbeddingModel)) embedItems.Add(ViewModel.SelectedEmbeddingModel);

        var any = ViewModel.AvailableModels.Count > 0;
        ChatModelCombo.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        EmbedModelCombo.Visibility = any ? Visibility.Visible : Visibility.Collapsed;
        ModelsUnavailableText.Visibility = any ? Visibility.Collapsed : Visibility.Visible;

        ChatModelCombo.ItemsSource = chatItems;
        EmbedModelCombo.ItemsSource = embedItems;
        ChatModelCombo.SelectedItem = ViewModel.SelectedChatModel;
        EmbedModelCombo.SelectedItem = ViewModel.SelectedEmbeddingModel;

        _suppress = false;
    }

    private void OnVmChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SettingsViewModel.SelectedEmbeddingModel))
            CurrentModelValue.Text = ViewModel.SelectedEmbeddingModel;
        if (e.PropertyName == nameof(SettingsViewModel.SettingsError))
        {
            if (string.IsNullOrEmpty(ViewModel.SettingsError)) ErrorBar.IsOpen = false;
            else { ErrorBar.Message = ViewModel.SettingsError; ErrorBar.IsOpen = true; }
        }
    }

    private void OnLanguageChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        ViewModel.Language = LanguageCombo.SelectedIndex == 1 ? AppLanguage.Czech : AppLanguage.English;
        // Re-localize this dialog live.
        ApplyLocalizedText();
    }

    private void OnChatModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (ChatModelCombo.SelectedItem is string s) ViewModel.SelectedChatModel = s;
    }

    private void OnEmbedModelChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppress) return;
        if (EmbedModelCombo.SelectedItem is string s) ViewModel.SelectedEmbeddingModel = s;
    }

    private async void OnManageModels(object sender, RoutedEventArgs e)
    {
        var dialog = new ModelManagementDialog(_strings) { XamlRoot = this.XamlRoot };
        // ContentDialogs are one-per-thread; hide this one while the child is open.
        this.Hide();
        await dialog.ShowAsync();
        await this.ShowAsync();        // re-open settings
        await LoadModelsAsync();       // refresh on return (mirrors .sheet onDismiss)
    }

    private async void OnReembed(object sender, RoutedEventArgs e)
    {
        var confirm = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _strings.Get(StringKey.ReembedConfirm),
            PrimaryButtonText = _strings.Get(StringKey.ReembedConfirmYes),
            CloseButtonText = _strings.Get(StringKey.CancelButton),
            DefaultButton = ContentDialogButton.Close
        };
        this.Hide();
        var result = await confirm.ShowAsync();
        if (result == ContentDialogResult.Primary)
            await ViewModel.ReembedAllAsync();
        await this.ShowAsync();
    }
}
```

> ContentDialog allows only one open per thread/window. Because Settings opens child dialogs (Manage models, Re-embed confirm), the pattern above `Hide()`s Settings, shows the child, then re-`ShowAsync()`s Settings. This mirrors the mac sheet-over-sheet flow and the "refresh model list on return" behavior. The language combo re-localizes the open Settings dialog immediately (via `ApplyLocalizedText`); the rest of the app re-localizes through the `LocalizedStrings` `Item[]` change notification.

**Verification:** Build on a Windows machine and (from the in-window toolbar Settings button wired by the shell milestone, or a temporary launcher) manually verify: Settings opens at ~460×540; the language combo switches EN/CS and the dialog text + app text re-localize live; with Ollama running the two model combos list installed models sorted, defaulting to the persisted chat/embedding selections, and a non-listed current value stays selectable; with Ollama stopped the "Models unavailable…" note shows; "Manage models…" opens the model dialog (list installed models with binary sizes; Pull a model shows streaming progress then the new model appears; Delete removes a model; Refresh reloads) and on return Settings refreshes; the embedding section shows the current model monospaced; "Re-embed all sources" prompts a destructive confirm, and on Yes clears embeddings for the current model and the indexing badge starts counting up as the worker re-embeds; the version row shows `AINotebookVersion.Current` (0.7.3). Errors surface in the red InfoBar.

**Commit:**

```bash
git add windows/src/AINotebook.App/Views/ModelManagementDialog.xaml windows/src/AINotebook.App/Views/ModelManagementDialog.xaml.cs windows/src/AINotebook.App/Views/SettingsDialog.xaml windows/src/AINotebook.App/Views/SettingsDialog.xaml.cs
git commit -m "feat(settings): SettingsDialog (language/models/re-embed/version) + ModelManagementDialog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task M5.1 — ChatViewModel + session/message logic

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/ChatViewModel.cs`
- Create `windows/src/AINotebook.App/ViewModels/CitationViewModel.cs`
- Create `windows/tests/AINotebook.App.Tests/ChatViewModelTests.cs` (only if the App.Tests project already exists from Plan 1; otherwise skip the test file and note it)

**Steps:**

1. Create `CitationViewModel.cs` — a small UI projection of `Core.Models.Citation` plus the resolved popover fields (`ChatView.showCitation` computes these from `store.source` / `store.chunks` / `store.notes`):

```csharp
using AINotebook.Core.Models;

namespace AINotebook.App.ViewModels;

public sealed class CitationViewModel
{
    public required Citation Citation { get; init; }
    public required string SourceTitle { get; init; }
    public int? PageHint { get; init; }
    public string? PdfFilePath { get; init; }   // absolute path when source is a PDF with rawPath
    public long? NoteIdToOpen { get; init; }     // owning note id when source.type == note

    public string Marker => $"[{Citation.Marker}]";
    public string Snippet => Citation.Snippet;
}
```

2. Create `MessageViewModel.cs` content inside `ChatViewModel.cs` (or its own file) — wraps a `ChatMessage` for binding:

```csharp
using System.Collections.Generic;
using System.Linq;
using AINotebook.Core.Models;

namespace AINotebook.App.ViewModels;

public sealed class MessageViewModel
{
    public required ChatMessage Message { get; init; }
    public bool IsUser => Message.Role == ChatRole.User;
    public bool IsAssistant => Message.Role == ChatRole.Assistant;
    public string Content => Message.Content;
    public IReadOnlyList<Citation> Citations => Message.Citations;
    public bool HasCitations => Message.Citations.Count > 0;
    // streaming placeholder bubbles have no real id -> no "save as note"
    public bool CanSaveAsNote => IsAssistant && Message.Id is not null;
}
```

3. Create `ChatViewModel.cs`. It mirrors the `@State` in `ChatView.swift`: `sessions`, `selectedSessionId`, `messages`, `input`, `streamingDraft`, `sending`, `errorMessage`. Use `CommunityToolkit.Mvvm`. The streaming token append marshals via the injected `DispatcherQueue`. The constructor takes the singletons resolved from `App.Current.Services` (the View resolves the VM from DI):

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using AINotebook.App.Services;          // ILocalizedStrings, ChatEngineHolder, coordinators (Plan 1)
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class ChatViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ChatEngineHolder _chatHolder;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;

    private long _notebookId;

    public ObservableCollection<ChatSession> Sessions { get; } = new();
    public ObservableCollection<MessageViewModel> Messages { get; } = new();

    [ObservableProperty] public partial ChatSession? SelectedSession { get; set; }
    [ObservableProperty] public partial string Input { get; set; } = "";
    [ObservableProperty] public partial string StreamingDraft { get; set; } = "";
    [ObservableProperty] public partial bool Sending { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool ShowEmptyState { get; set; } = true;

    public ChatViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _chatHolder = chatHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch;
        _t = t; _dispatcher = dispatcher;
    }

    // Bound to title text + send-enabled gating (mirrors `.disabled(sending || input.isEmpty)`).
    public bool CanSend => !Sending && !string.IsNullOrWhiteSpace(Input);
    partial void OnInputChanged(string value) => SendCommand.NotifyCanExecuteChanged();
    partial void OnSendingChanged(bool value) => SendCommand.NotifyCanExecuteChanged();

    partial void OnSelectedSessionChanged(ChatSession? value) => _ = ReloadMessagesAsync();
    partial void OnStreamingDraftChanged(string value) => RefreshEmptyState();
    private void RefreshEmptyState() =>
        ShowEmptyState = Messages.Count == 0 && string.IsNullOrEmpty(StreamingDraft);

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        await EnsureSessionsAsync();
    }

    // Mirrors ChatView.ensureSessions(): load sessions; if none, create one.
    private async Task EnsureSessionsAsync()
    {
        try
        {
            Sessions.Clear();
            foreach (var s in _store.ChatSessions(_notebookId)) Sessions.Add(s);
            if (Sessions.Count == 0)
            {
                var created = _store.CreateChatSession(_notebookId, _t.Get("chatNewSessionTitle"));
                Sessions.Add(created);
            }
            SelectedSession = Sessions.FirstOrDefault();
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private async Task NewSessionAsync()
    {
        try
        {
            var s = _store.CreateChatSession(_notebookId, _t.Get("chatNewSessionTitle"));
            Sessions.Insert(0, s);
            SelectedSession = s;
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private async Task DeleteSessionAsync(ChatSession? session)
    {
        if (session?.Id is not { } id) return;
        try
        {
            _store.DeleteChatSession(id);
            var existing = Sessions.FirstOrDefault(x => x.Id == id);
            if (existing is not null) Sessions.Remove(existing);
            SelectedSession = Sessions.FirstOrDefault();
            await ReloadMessagesAsync();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    private Task ReloadMessagesAsync()
    {
        Messages.Clear();
        if (SelectedSession?.Id is not { } sid) { RefreshEmptyState(); return Task.CompletedTask; }
        try
        {
            foreach (var m in _store.Messages(sid))
                Messages.Add(new MessageViewModel { Message = m });
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        RefreshEmptyState();
        return Task.CompletedTask;
    }

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task SendAsync()
    {
        if (SelectedSession?.Id is not { } sid) return;
        var text = Input.Trim();
        if (text.Length == 0) return;
        Input = "";
        Sending = true;
        ErrorMessage = null;
        StreamingDraft = "";
        try
        {
            await _chatHolder.Engine.SendAsync(
                sid, _notebookId, text,
                currentNoteContent: null,
                onToken: token => _dispatcher.TryEnqueue(() => StreamingDraft += token));
            await ReloadMessagesAsync();
        }
        catch (Exception ex)
        {
            ErrorMessage = ex.ToString();
            await ReloadMessagesAsync();
        }
        finally
        {
            Sending = false;
            StreamingDraft = "";
            RefreshEmptyState();
        }
    }

    // Mirrors MessageBubble "Save as note": title "Chat reply — <date>", origin=Chat, originRef=msg.id.
    [RelayCommand]
    private void SaveAsNote(MessageViewModel? vm)
    {
        if (vm?.Message is not { } msg) return;
        try
        {
            var when = msg.CreatedAt.ToLocalTime().ToString("d MMM yyyy, h:mm tt");
            _store.CreateNote(_notebookId, $"Chat reply — {when}", msg.Content,
                NoteOrigin.Chat, msg.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Mirrors ChatView.showCitation(): resolve source/page/note metadata for the Flyout.
    public CitationViewModel BuildCitationViewModel(Citation c)
    {
        var source = _store.Source(c.SourceId);
        var chunks = source is null ? Array.Empty<SourceChunk>() : _store.Chunks(c.SourceId).ToArray();
        int? hint = chunks.FirstOrDefault(ch => ch.Id == c.ChunkId)?.PageHint;
        var isPdf = source?.Type == SourceType.Pdf;
        var pdfPath = (isPdf && source?.RawPath is { Length: > 0 }) ? source.RawPath : null;

        long? noteId = null;
        if (source?.Type == SourceType.Note && source is not null)
        {
            var notes = _store.Notes(source.NotebookId);
            noteId = notes.FirstOrDefault(n => n.AutoSourceId == source.Id)?.Id;
        }
        return new CitationViewModel
        {
            Citation = c,
            SourceTitle = source?.Title ?? "",
            PageHint = hint,
            PdfFilePath = pdfPath,
            NoteIdToOpen = noteId
        };
    }

    public void RequestOpenNote(long noteId) => _noteJump.Request(noteId);
}
```

> Note on `MessageViewModel.Message.CreatedAt`: it is `ChatMessage.CreatedAt` (a `DateTime`). The streaming placeholder bubble is built in the View, not here.

4. (xUnit, only if `AINotebook.App.Tests` exists.) Pure-logic test of `BuildCitationViewModel` and the "save as note" title format using a real in-memory `NotebookStore` (no WinUI types needed — `ChatEngineHolder`/coordinators can be constructed without a window). Do **not** claim it runs on macOS.

```csharp
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Xunit;

public class ChatViewModelTests
{
    [Fact]
    public void BuildCitationViewModel_resolvesPdfPathAndPageHint()
    {
        // Arrange a temp store, a PDF source with a chunk + page hint, build a Citation.
        // Assert vm.PdfFilePath == source.RawPath and vm.PageHint == chunk.PageHint.
        // (Construct ChatViewModel with null DispatcherQueue is NOT possible — instead
        //  factor BuildCitationViewModel logic to a static helper if testing in isolation,
        //  OR test the equivalent CitationResolver. Document the DispatcherQueue caveat.)
    }
}
```

If the `DispatcherQueue` dependency makes direct construction awkward in tests, extract the citation resolution into a `static CitationViewModel Resolve(NotebookStore store, Citation c)` helper and unit-test that instead; the VM delegates to it.

5. Commit:

```
git add windows/src/AINotebook.App/ViewModels/ChatViewModel.cs windows/src/AINotebook.App/ViewModels/CitationViewModel.cs windows/tests/AINotebook.App.Tests/ChatViewModelTests.cs
git commit -m "feat(app): ChatViewModel + citation/message projections (M5.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine (`dotnet build windows/AINotebook.sln`) and manually verify: the App project compiles with the new VMs; if App.Tests exists, `dotnet test` passes the citation-resolution test.

---

## Task M5.2 — ChatPage XAML + MessageBubble + citation Flyout

**Files:**
- Create `windows/src/AINotebook.App/Views/ChatPage.xaml`
- Create `windows/src/AINotebook.App/Views/ChatPage.xaml.cs`
- Create `windows/src/AINotebook.App/Controls/MessageBubble.xaml`
- Create `windows/src/AINotebook.App/Controls/MessageBubble.xaml.cs`
- Create `windows/src/AINotebook.App/Converters/BoolToVisibilityConverter.cs` (only if Plan 1 hasn't already created a shared one; otherwise reuse)

**Steps:**

1. `MessageBubble.xaml` — mirrors `MessageBubble.swift`: a bubble aligned right (user) / left (assistant), selectable text, citation chips that open the Flyout, and an assistant-only "Save as note" button. Citation chips are an `ItemsRepeater` of `[N]` buttons; each chip's `Click` raises an event the page handles (the chip needs the `Citation` + a `Flyout` anchored to itself).

```xml
<UserControl
    x:Class="AINotebook.App.Controls.MessageBubble"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:vm="using:AINotebook.App.ViewModels"
    xmlns:models="using:AINotebook.Core.Models"
    mc:Ignorable="d"
    xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
    xmlns:d="http://schemas.microsoft.com/expression/blend/2008">
    <Grid Padding="0,4">
        <StackPanel x:Name="Bubble" Spacing="6" MaxWidth="640"
                    HorizontalAlignment="{x:Bind UserAlignment, Mode=OneWay}">
            <Border x:Name="BubbleBack" CornerRadius="10" Padding="10">
                <TextBlock Text="{x:Bind ViewModel.Content, Mode=OneWay}"
                           TextWrapping="Wrap" IsTextSelectionEnabled="True"/>
            </Border>

            <ItemsRepeater ItemsSource="{x:Bind ViewModel.Citations, Mode=OneWay}"
                           Visibility="{x:Bind ViewModel.HasCitations, Mode=OneWay}">
                <ItemsRepeater.Layout>
                    <StackLayout Orientation="Horizontal" Spacing="6"/>
                </ItemsRepeater.Layout>
                <ItemsRepeater.ItemTemplate>
                    <DataTemplate x:DataType="models:Citation">
                        <Button Click="OnCitationClick" Tag="{x:Bind}"
                                Padding="6,2" CornerRadius="12"
                                FontFamily="Consolas" FontSize="12"
                                Background="{ThemeResource AccentFillColorSecondaryBrush}">
                            <TextBlock Text="{x:Bind Marker, Mode=OneWay}"/>
                        </Button>
                    </DataTemplate>
                </ItemsRepeater.ItemTemplate>
            </ItemsRepeater>

            <Button x:Name="SaveAsNoteButton" Click="OnSaveAsNoteClick"
                    Visibility="{x:Bind ViewModel.CanSaveAsNote, Mode=OneWay}"
                    FontSize="12"/>
        </StackPanel>
    </Grid>
</UserControl>
```

> `models:Citation` has no `Marker` *string* property — `Citation.Marker` is an `int`. Add a tiny binding helper: bind the `TextBlock.Text` to `Marker` via `x:Bind ConvertedMarker`. Simplest: in `MessageBubble.xaml.cs`, expose the citations as a small wrapper, OR bind `Text="{x:Bind Marker}"` against a `CitationChip` record with a `string Marker => $"[{Citation.Marker}]"`. Implement the chip wrapper in code-behind (step 2) to avoid an int→string converter.

2. `MessageBubble.xaml.cs` — exposes `ViewModel` (a `MessageViewModel`), styles the bubble background by role, raises events for citation-tap and save-as-note. Citation chips bind to a `CitationChip` wrapper list:

```csharp
using System;
using System.Collections.Generic;
using System.Linq;
using AINotebook.App.ViewModels;
using AINotebook.Core.Models;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace AINotebook.App.Controls;

public sealed record CitationChip(Citation Citation)
{
    public string Marker => $"[{Citation.Marker}]";
}

public sealed partial class MessageBubble : UserControl
{
    public static readonly DependencyProperty ViewModelProperty =
        DependencyProperty.Register(nameof(ViewModel), typeof(MessageViewModel),
            typeof(MessageBubble), new PropertyMetadata(null, OnViewModelChanged));

    public MessageViewModel? ViewModel
    {
        get => (MessageViewModel?)GetValue(ViewModelProperty);
        set => SetValue(ViewModelProperty, value);
    }

    public HorizontalAlignment UserAlignment =>
        ViewModel?.IsUser == true ? HorizontalAlignment.Right : HorizontalAlignment.Left;

    public IReadOnlyList<CitationChip> Chips =>
        ViewModel?.Citations.Select(c => new CitationChip(c)).ToList() ?? new();

    public event EventHandler<Citation>? CitationTapped;
    public event EventHandler<MessageViewModel>? SaveAsNoteRequested;

    public MessageBubble()
    {
        InitializeComponent();
        Loaded += (_, _) => ApplyStyle();
        // Save-as-note button label is localized at page-load by the host; see ChatPage.
    }

    private static void OnViewModelChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
        => ((MessageBubble)d).ApplyStyle();

    private void ApplyStyle()
    {
        if (ViewModel is null) return;
        BubbleBack.Background = new SolidColorBrush(
            ViewModel.IsUser ? Color.FromArgb(46, 0, 120, 215)   // accent @ ~0.18
                             : Color.FromArgb(26, 128, 128, 128)); // secondary @ ~0.10
        Bubble.HorizontalAlignment = UserAlignment;
    }

    private void OnCitationClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement fe && fe.Tag is Citation c)
            CitationTapped?.Invoke(this, c);
    }

    private void OnSaveAsNoteClick(object sender, RoutedEventArgs e)
    {
        if (ViewModel is not null) SaveAsNoteRequested?.Invoke(this, ViewModel);
    }
}
```

> Because the `ItemTemplate` binds `models:Citation`, bind the chip `TextBlock` to a literal: replace the `DataTemplate x:DataType="models:Citation"` content with `Text="{x:Bind Marker, Mode=OneWay}"` only if `Citation` had a `Marker` string — it does not. To keep XAML simple, change the `ItemsRepeater.ItemsSource` to `{x:Bind Chips, Mode=OneWay}` with `x:DataType="ctrl:CitationChip"` (string `Marker`, and `Tag="{x:Bind Citation}"`). Update the XAML namespace `xmlns:ctrl="using:AINotebook.App.Controls"` accordingly. This is the load-bearing fix: chips display `[N]` and carry the `Citation` in `Tag`.

3. `ChatPage.xaml` — mirrors `ChatView` `HSplitView` (sessions sidebar + chat surface). WinUI has no `HSplitView`; use a `Grid` with two columns and a `GridSplitter` from `CommunityToolkit.WinUI.Controls.Sizers` (referenced by Plan 1) — or a fixed 240px sidebar column if the toolkit sizer is not yet referenced. Sessions list = `ListView`; chat surface = `ScrollViewer` of `MessageBubble`s + streaming bubble + error; input bar at bottom:

```xml
<Page
    x:Class="AINotebook.App.Views.ChatPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:ctrl="using:AINotebook.App.Controls"
    xmlns:vm="using:AINotebook.App.ViewModels"
    xmlns:models="using:AINotebook.Core.Models">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="240"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sessions sidebar -->
        <Grid Grid.Column="0" Padding="12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <TextBlock x:Name="SessionsLabel" Style="{ThemeResource SubtitleTextBlockStyle}"/>
                <Button HorizontalAlignment="Right" Command="{x:Bind ViewModel.NewSessionCommand}"
                        Content="&#xE710;" FontFamily="Segoe MDL2 Assets"/>
            </Grid>
            <ListView Grid.Row="1" ItemsSource="{x:Bind ViewModel.Sessions, Mode=OneWay}"
                      SelectedItem="{x:Bind ViewModel.SelectedSession, Mode=TwoWay}">
                <ListView.ItemTemplate>
                    <DataTemplate x:DataType="models:ChatSession">
                        <StackPanel Spacing="2">
                            <TextBlock Text="{x:Bind Title}" Style="{ThemeResource BodyStrongTextBlockStyle}"/>
                            <TextBlock Text="{x:Bind CreatedAt}" Style="{ThemeResource CaptionTextBlockStyle}"
                                       Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
                        </StackPanel>
                    </DataTemplate>
                </ListView.ItemTemplate>
            </ListView>
        </Grid>

        <!-- Chat surface -->
        <Grid Grid.Column="1" Padding="16">
            <Grid.RowDefinitions>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" x:Name="EmptyState"
                       Visibility="{x:Bind ViewModel.ShowEmptyState, Mode=OneWay}"
                       HorizontalAlignment="Center" VerticalAlignment="Center"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>

            <ScrollViewer Grid.Row="0" x:Name="MessagesScroller"
                          Visibility="{x:Bind ViewModel.ShowEmptyState, Mode=OneWay, Converter={StaticResource InvertBoolToVisibility}}">
                <StackPanel Spacing="6">
                    <ItemsControl ItemsSource="{x:Bind ViewModel.Messages, Mode=OneWay}">
                        <ItemsControl.ItemTemplate>
                            <DataTemplate x:DataType="vm:MessageViewModel">
                                <ctrl:MessageBubble ViewModel="{x:Bind}"
                                                    CitationTapped="OnCitationTapped"
                                                    SaveAsNoteRequested="OnSaveAsNote"/>
                            </DataTemplate>
                        </ItemsControl.ItemTemplate>
                    </ItemsControl>
                    <Border x:Name="StreamingBubble" CornerRadius="10" Padding="10"
                            Background="{ThemeResource SubtleFillColorSecondaryBrush}"
                            HorizontalAlignment="Left"
                            Visibility="{x:Bind ViewModel.StreamingDraft, Mode=OneWay, Converter={StaticResource StringToVisibility}}">
                        <TextBlock Text="{x:Bind ViewModel.StreamingDraft, Mode=OneWay}" TextWrapping="Wrap"/>
                    </Border>
                    <TextBlock x:Name="ErrorText" Foreground="Red" TextWrapping="Wrap"
                               Visibility="{x:Bind ViewModel.ErrorMessage, Mode=OneWay, Converter={StaticResource StringToVisibility}}"/>
                </StackPanel>
            </ScrollViewer>

            <TextBox Grid.Row="2" x:Name="InputBox" Margin="0,8,0,0"
                     Text="{x:Bind ViewModel.Input, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                     AcceptsReturn="True" TextWrapping="Wrap" MaxHeight="120"
                     IsEnabled="{x:Bind ViewModel.Sending, Mode=OneWay, Converter={StaticResource InvertBool}}">
                <TextBox.KeyboardAccelerators>
                    <KeyboardAccelerator Modifiers="Control" Key="Enter" Invoked="OnSendAccelerator"/>
                </TextBox.KeyboardAccelerators>
            </TextBox>
        </Grid>
    </Grid>
</Page>
```

> The converters `InvertBoolToVisibility`, `StringToVisibility`, `InvertBool` are tiny `IValueConverter`s. Plan 1 likely creates a shared converters file; if a needed converter is missing, add it under `windows/src/AINotebook.App/Converters/` and register in `App.xaml`'s `<Application.Resources>`. `StringToVisibility` = `Visible` when the string is non-empty.

4. `ChatPage.xaml.cs` — resolves the VM from DI, sets localized strings, wires the session context-menu (delete), the citation Flyout, and the send accelerator. The citation Flyout is built in code and shown anchored to the chip's parent bubble. Auto-scroll on new tokens:

```csharp
using System;
using AINotebook.App.ViewModels;
using AINotebook.App.Controls;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace AINotebook.App.Views;

public sealed partial class ChatPage : Page
{
    public ChatViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public ChatPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<ChatViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        SessionsLabel.Text = _t.Get("chatSessionsLabel");
        EmptyState.Text = _t.Get("chatEmptyState");
        InputBox.PlaceholderText = _t.Get("chatInputPlaceholder");
        ViewModel.Messages.VectorChanged += (_, _) => ScrollToBottom();
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(ChatViewModel.StreamingDraft)) ScrollToBottom();
            if (e.PropertyName == nameof(ChatViewModel.ErrorMessage))
                ErrorText.Text = (ViewModel.ErrorMessage is null) ? "" : _t.Get("chatErrorPrefix") + ViewModel.ErrorMessage;
        };
    }

    // Called by the shell when the notebook changes (mirrors .task(id: notebook.id)).
    public async void Load(long notebookId) => await ViewModel.LoadAsync(notebookId);

    private void ScrollToBottom() => MessagesScroller.ChangeView(null, MessagesScroller.ScrollableHeight, null);

    private void OnSendAccelerator(KeyboardAccelerator sender, KeyboardAcceleratorInvokedEventArgs args)
    {
        if (ViewModel.SendCommand.CanExecute(null)) ViewModel.SendCommand.Execute(null);
        args.Handled = true;
    }

    private void OnCitationTapped(object? sender, Citation c)
    {
        if (sender is not FrameworkElement anchor) return;
        var cvm = ViewModel.BuildCitationViewModel(c);
        ShowCitationFlyout(anchor, cvm);
    }

    private void OnSaveAsNote(object? sender, MessageViewModel vm) =>
        ViewModel.SaveAsNoteCommand.Execute(vm);

    private void ShowCitationFlyout(FrameworkElement anchor, CitationViewModel cvm)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        header.Children.Add(new FontIcon { Glyph = "\uE9D2" }); // quote-ish glyph
        header.Children.Add(new TextBlock { Text = cvm.SourceTitle, Style = (Style)Resources["BaseTextBlockStyle"] });

        // "Open page N" for a PDF source with a page hint.
        if (cvm.PageHint is int page && cvm.PdfFilePath is { } path)
        {
            var openBtn = new HyperlinkButton { Content = $"Open page {page}" };
            openBtn.Click += async (_, _) =>
                await Launcher.LaunchUriAsync(new Uri(new Uri("file://"), path));
            header.Children.Add(openBtn);
        }
        // "Open note" for a note source -> jump via coordinator.
        if (cvm.NoteIdToOpen is long nid)
        {
            var noteBtn = new HyperlinkButton { Content = _t.Get("openNoteFromCitation") };
            noteBtn.Click += (_, _) => ViewModel.RequestOpenNote(nid);
            header.Children.Add(noteBtn);
        }

        var snippet = new ScrollViewer
        {
            MaxHeight = 240,
            Content = new TextBlock { Text = cvm.Snippet, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true }
        };
        var panel = new StackPanel { Width = 380, Spacing = 8 };
        panel.Children.Add(header);
        panel.Children.Add(snippet);

        var flyout = new Flyout { Content = panel };
        flyout.ShowAt(anchor);
    }
}
```

> The PDF "Open page N" uses `Launcher.LaunchUriAsync` against the `file://` URL (mirrors mac `NSWorkspace.open(url)` — opens the PDF in the default viewer; WinUI cannot deep-link to a page, so it opens the file, matching the spec's "Launcher for source URLs/pages"). For session delete, add a `MenuFlyout` with one destructive item bound to `DeleteSessionCommand` on the `ListView.ItemTemplate` root via `ContextFlyout` (label `chatDeleteSessionButton`); the New-session button tooltip is `chatNewSessionButton`. Localize the per-bubble "Save as note" label (`chatSaveAsNoteButton`) by setting `SaveAsNoteButton.Content` in `MessageBubble`'s `Loaded` from `LocalizedStrings`.

5. Register `ChatViewModel` as **transient** in DI (Plan 1's `App.xaml.cs` `ConfigureServices`), since each notebook switch creates a page that resolves a fresh VM. Add the line: `services.AddTransient<ChatViewModel>();` (note this in the task so Writer A/B's `ConfigureServices` includes it — if Plan 1 already centralises VM registration, add it there).

6. Commit:

```
git add windows/src/AINotebook.App/Views/ChatPage.xaml windows/src/AINotebook.App/Views/ChatPage.xaml.cs windows/src/AINotebook.App/Controls/MessageBubble.xaml windows/src/AINotebook.App/Controls/MessageBubble.xaml.cs windows/src/AINotebook.App/Converters/
git commit -m "feat(app): Chat tab — ChatPage, MessageBubble, citation Flyout (M5.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine (`dotnet run` the App) and manually verify: opening a notebook's Chat tab auto-creates a session and shows the empty-state string; typing a question and pressing Ctrl+Enter streams tokens into the streaming bubble, then the finished assistant message replaces it; `[N]` chips appear and clicking one opens a Flyout with the source title + snippet; for a PDF citation an "Open page N" link opens the PDF; for a note citation "Open note" switches focus (verified fully after M6); the "+" creates a new session, right-click → delete removes it; "Save as note" on an assistant reply creates a note (verify in Notes tab after M6).

---

## Milestone M6 — Notes tab + WebView2 editor

Mirrors `NotesView.swift`, `NotesChatPanel.swift`, `NoteWYSIWYGEditor.swift`, `MarkdownHTMLBridge.swift`, `AttachmentURLSchemeHandler.swift`, `NoteHistorySheet.swift`, plus the `NoteEditorCoordinator` / `NoteJumpCoordinator` (Plan 1 singletons) and `AutoSaveController` semantics. Split into two tasks: the editor host control (M6.1) and the Notes view + chat panel + history (M6.2).

The bridge protocol (from `MarkdownHTMLBridge`/`editor.ts`):
- **JS → host** (`window.chrome.webview.postMessage(...)` after the M7 shim): `{kind:"ready"}`, `{kind:"change",markdown}`, `{kind:"save",markdown}`, `{kind:"attachment",requestId,filename,mime,base64}`.
- **host → JS** (`ExecuteScriptAsync`): `window.aino.setContent(\`<escaped>\`)` (escape order: backslash → backtick → dollar), `window.aino.attachmentSaved(requestId,url,mime)`, `window.aino.attachmentDenied(requestId)`.
- **Attachment URL scheme:** the editor builds `attachment://<noteUuid>/<filename>`. On WebView2 we serve it via a **second virtual-host mapping** is not possible for the `attachment://` scheme (virtual hosts are `https://`); instead use `AddWebResourceRequestedFilter("attachment://*", All)` + `WebResourceRequested` reading from `AttachmentStore.Read(noteUuid, filename)` (this keeps the editor's existing `attachment://` URLs unchanged, so the M7 editor.ts change is only the post-transport detection, not the attachment URL form). Document: chosen approach is `WebResourceRequested` (mirrors the mac `WKURLSchemeHandler`).

## Task M6.1 — EditorWebView control (WebView2 host + bridge + attachments + autosave)

**Files:**
- Create `windows/src/AINotebook.App/Editor/EditorMessage.cs`
- Create `windows/src/AINotebook.App/Editor/AutoSaveController.cs`
- Create `windows/src/AINotebook.App/Editor/EditorWebView.xaml`
- Create `windows/src/AINotebook.App/Editor/EditorWebView.xaml.cs`
- Create `windows/tests/AINotebook.App.Tests/EditorMessageTests.cs` (if App.Tests exists)

**Steps:**

1. `EditorMessage.cs` — port `MarkdownHTMLBridge.decode` to a `System.Text.Json` decoder over the `{kind:...}` payloads. The host receives the JSON via `CoreWebView2WebMessageReceivedEventArgs.WebMessageAsJson`:

```csharp
using System.Text.Json;

namespace AINotebook.App.Editor;

public abstract record EditorMessage
{
    public sealed record Ready : EditorMessage;
    public sealed record Change(string Markdown) : EditorMessage;
    public sealed record Save(string Markdown) : EditorMessage;
    public sealed record AttachmentRequest(string RequestId, string Filename, string Mime, string Base64) : EditorMessage;
}

public static class MarkdownHtmlBridge
{
    // Returns null on unknown/invalid payloads (mirrors Swift: unknown payloads ignored in v1).
    public static EditorMessage? Decode(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("kind", out var kindEl) || kindEl.ValueKind != JsonValueKind.String)
                return null;
            switch (kindEl.GetString())
            {
                case "ready": return new EditorMessage.Ready();
                case "change":
                    return root.TryGetProperty("markdown", out var cmd) && cmd.ValueKind == JsonValueKind.String
                        ? new EditorMessage.Change(cmd.GetString()!) : null;
                case "save":
                    return root.TryGetProperty("markdown", out var smd) && smd.ValueKind == JsonValueKind.String
                        ? new EditorMessage.Save(smd.GetString()!) : null;
                case "attachment":
                    if (root.TryGetProperty("requestId", out var r) && r.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("filename", out var f) && f.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("mime", out var m) && m.ValueKind == JsonValueKind.String &&
                        root.TryGetProperty("base64", out var b) && b.ValueKind == JsonValueKind.String)
                        return new EditorMessage.AttachmentRequest(r.GetString()!, f.GetString()!, m.GetString()!, b.GetString()!);
                    return null;
                default: return null;
            }
        }
        catch (JsonException) { return null; }
    }

    // Mirrors Swift escape order: backslash, then backtick, then dollar.
    public static string EscapeForTemplateLiteral(string md) =>
        md.Replace("\\", "\\\\").Replace("`", "\\`").Replace("$", "\\$");
}
```

2. `AutoSaveController.cs` — port `Core/AutoSaveController.swift` to a WinUI-thread-affine controller using a `DispatcherQueueTimer` for the debounce. The mac default is 2000ms (the Core `AutoSaveController` constructor defaults to `2_000`); the shared context says "50ms debounce" but the source-of-truth Core default is **2000ms**, and `NoteWYSIWYGEditor` uses the default — port **2000ms** with last-write-wins + manual flush. Statuses mirror `Status { saved, unsaved, saving, error(msg) }`:

```csharp
using System;
using CommunityToolkit.Mvvm.ComponentModel;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.Editor;

public enum SaveState { Saved, Unsaved, Saving, Error }

public partial class AutoSaveController : ObservableObject
{
    private readonly Action<string> _save;
    private readonly DispatcherQueueTimer _timer;
    private string? _pendingBody;

    [ObservableProperty] public partial SaveState Status { get; private set; } = SaveState.Saved;
    [ObservableProperty] public partial string? ErrorText { get; private set; }

    public AutoSaveController(DispatcherQueue dispatcher, Action<string> save, int debounceMillis = 2000)
    {
        _save = save;
        _timer = dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromMilliseconds(debounceMillis);
        _timer.IsRepeating = false;
        _timer.Tick += (_, _) => Flush();
    }

    public void NoteDidChange(string markdown)
    {
        _pendingBody = markdown;       // last-write-wins
        Status = SaveState.Unsaved;
        _timer.Stop();
        _timer.Start();
    }

    public void ManualSave()
    {
        _timer.Stop();
        Flush();
    }

    private void Flush()
    {
        if (_pendingBody is not { } body) return;
        Status = SaveState.Saving;
        try
        {
            _save(body);
            _pendingBody = null;
            Status = SaveState.Saved;
            ErrorText = null;
        }
        catch (Exception ex)
        {
            ErrorText = ex.Message;
            Status = SaveState.Error;
        }
    }

    public bool HasUnsavedChanges => Status is SaveState.Unsaved or SaveState.Saving;
}
```

3. `EditorWebView.xaml` — a `UserControl` wrapping a `WebView2` plus the status/save/history bottom bar and the title `TextBox` (mirrors `NoteWYSIWYGEditor`'s layout: title on top, web view fills, bottom bar). Keep the title `TextBox` here so the whole editor surface is one control:

```xml
<UserControl
    x:Class="AINotebook.App.Editor.EditorWebView"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:wv2="using:Microsoft.UI.Xaml.Controls">
    <Grid RowSpacing="6">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBox Grid.Row="0" x:Name="TitleBox"
                 Text="{x:Bind Title, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                 FontSize="18"/>

        <Grid Grid.Row="1">
            <wv2:WebView2 x:Name="Web" DefaultBackgroundColor="Transparent"/>
            <TextBlock x:Name="LoadFailed" Visibility="Collapsed" Foreground="Red"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Grid>

        <Grid Grid.Row="2">
            <StackPanel Orientation="Horizontal" Spacing="6" x:Name="StatusPanel">
                <FontIcon x:Name="StatusIcon" FontSize="14"/>
                <TextBlock x:Name="StatusText" Style="{ThemeResource CaptionTextBlockStyle}"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Spacing="8" HorizontalAlignment="Right">
                <Button x:Name="HistoryButton" Click="OnHistoryClick">
                    <Button.KeyboardAccelerators>
                        <KeyboardAccelerator Modifiers="Control,Shift" Key="H"/>
                    </Button.KeyboardAccelerators>
                </Button>
                <Button x:Name="SaveButton" Content="Save" Click="OnSaveClick">
                    <Button.KeyboardAccelerators>
                        <KeyboardAccelerator Modifiers="Control" Key="S"/>
                    </Button.KeyboardAccelerators>
                </Button>
            </StackPanel>
        </Grid>
    </Grid>
</UserControl>
```

4. `EditorWebView.xaml.cs` — the host. It mirrors `EditorWebView.Coordinator`: configure the virtual host for `appassets` (editor folder), `WebResourceRequested` for `attachment://*`, `WebMessageReceived` decoding messages, the `ready` → `setContent` flow, `change`/`save` → `OnChange` + autosave, and the attachment upload via `AttachmentStore.Save` → `attachmentSaved`. Dependency props: `Title`, `BodyMd`, `NoteId`, `NoteUuid`, plus injected `AttachmentStore`, `NoteEditorCoordinator`, `ILocalizedStrings`, and callbacks `OnSaveRequested(string)` and `OnShowHistory`:

```csharp
using System;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;

namespace AINotebook.App.Editor;

public sealed partial class EditorWebView : UserControl
{
    private AttachmentStore? _attachments;
    private AutoSaveController? _autoSave;
    private NoteEditorCoordinator? _coordinator;
    private ILocalizedStrings _t = null!;
    private DispatcherQueue _dispatcher = null!;
    private bool _initialized;
    private string _initialMarkdown = "";

    public Action<string>? OnSaveRequested { get; set; }   // -> NotesViewModel.Save(id, body)
    public Action? OnShowHistory { get; set; }
    public Action<string>? OnChange { get; set; }          // pushes md into NotesViewModel.DraftBody

    public string Title
    {
        get => (string)GetValue(TitleProperty);
        set => SetValue(TitleProperty, value);
    }
    public static readonly DependencyProperty TitleProperty =
        DependencyProperty.Register(nameof(Title), typeof(string), typeof(EditorWebView), new PropertyMetadata(""));

    public long NoteId { get; private set; }
    public string NoteUuid { get; private set; } = "";

    public EditorWebView()
    {
        InitializeComponent();
        _dispatcher = DispatcherQueue.GetForCurrentThread();
    }

    // Called once per note open. `initialMarkdown` seeds the editor; `onSave` is the autosave sink.
    public async void Configure(
        long noteId, string noteUuid, string initialMarkdown,
        AttachmentStore attachments, NoteEditorCoordinator coordinator,
        ILocalizedStrings t)
    {
        NoteId = noteId; NoteUuid = noteUuid; _initialMarkdown = initialMarkdown;
        _attachments = attachments; _coordinator = coordinator; _t = t;

        SaveButton.Content = "Save";
        HistoryButton.Content = _t.Get("historyButton");

        _autoSave = new AutoSaveController(_dispatcher, body =>
        {
            OnSaveRequested?.Invoke(body);
        });
        _autoSave.PropertyChanged += (_, _) => ApplyStatus();
        ApplyStatus();

        await InitWebAsync();
    }

    private async Task InitWebAsync()
    {
        try
        {
            await Web.EnsureCoreWebView2Async();
            var core = Web.CoreWebView2;

            // Editor assets served over https://appassets (folder copied at build, see M7).
            // AppContext.BaseDirectory + "Resources\editor".
            var editorFolder = System.IO.Path.Combine(AppContext.BaseDirectory, "Resources", "editor");
            if (!System.IO.File.Exists(System.IO.Path.Combine(editorFolder, "editor.html")))
            {
                ShowLoadFailed();
                return;
            }
            core.SetVirtualHostNameToFolderMapping(
                "appassets", editorFolder, CoreWebView2HostResourceAccessKind.Deny);

            // attachment://<noteUuid>/<filename> served from AttachmentStore (mirrors WKURLSchemeHandler).
            core.AddWebResourceRequestedFilter("attachment://*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += OnWebResourceRequested;

            core.WebMessageReceived += OnWebMessageReceived;

            // Block external navigation (mirrors mac decidePolicyFor: allow file/other, cancel else).
            core.NavigationStarting += (s, e) =>
            {
                if (!e.Uri.StartsWith("https://appassets/", StringComparison.OrdinalIgnoreCase) &&
                    !e.Uri.StartsWith("about:", StringComparison.OrdinalIgnoreCase))
                    e.Cancel = true;
            };

            _initialized = true;
            Web.Source = new Uri("https://appassets/editor.html");
        }
        catch (Exception)
        {
            ShowLoadFailed();
        }
    }

    private void ShowLoadFailed()
    {
        Web.Visibility = Visibility.Collapsed;
        LoadFailed.Visibility = Visibility.Visible;
        LoadFailed.Text = _t.Get("editorFailedToLoad");
    }

    private void OnWebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        var msg = MarkdownHtmlBridge.Decode(e.WebMessageAsJson);
        switch (msg)
        {
            case EditorMessage.Ready:
                var escaped = MarkdownHtmlBridge.EscapeForTemplateLiteral(_initialMarkdown);
                _ = Web.CoreWebView2.ExecuteScriptAsync(
                    $"window.aino && window.aino.setContent(`{escaped}`)");
                break;
            case EditorMessage.Change c:
                OnChange?.Invoke(c.Markdown);
                _autoSave?.NoteDidChange(c.Markdown);
                break;
            case EditorMessage.Save s:
                OnChange?.Invoke(s.Markdown);
                _autoSave?.NoteDidChange(s.Markdown);
                break;
            case EditorMessage.AttachmentRequest a:
                HandleAttachment(a);
                break;
        }
    }

    private void HandleAttachment(EditorMessage.AttachmentRequest a)
    {
        if (_attachments is null) { Deny(a.RequestId); return; }
        byte[] bytes;
        try { bytes = Convert.FromBase64String(a.Base64); }
        catch { Deny(a.RequestId); return; }

        try
        {
            var att = _attachments.Save(NoteId, NoteUuid, a.Filename, a.Mime, bytes);
            var url = $"attachment://{NoteUuid}/{att.Filename}";
            var js = $"window.aino && window.aino.attachmentSaved && window.aino.attachmentSaved('{a.RequestId}', '{JsEscape(url)}', '{JsEscape(a.Mime)}')";
            _ = Web.CoreWebView2.ExecuteScriptAsync(js);
        }
        catch
        {
            Deny(a.RequestId);
        }
    }

    private void Deny(string requestId) =>
        _ = Web.CoreWebView2.ExecuteScriptAsync(
            $"window.aino && window.aino.attachmentDenied && window.aino.attachmentDenied('{requestId}')");

    private static string JsEscape(string s) => s.Replace("\\", "\\\\").Replace("'", "\\'");

    private void OnWebResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs e)
    {
        try
        {
            var uri = new Uri(e.Request.Uri);
            if (uri.Scheme != "attachment") return;
            var host = uri.Host;                       // noteUuid
            var filename = Uri.UnescapeDataString(uri.AbsolutePath.TrimStart('/'));
            if (host.Length == 0 || filename.Length == 0) return;

            var bytes = _attachments!.Read(host, filename);
            var mime = GuessMime(System.IO.Path.GetExtension(filename));
            var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
            using (var writer = new Windows.Storage.Streams.DataWriter(stream))
            {
                writer.WriteBytes(bytes);
                writer.StoreAsync().AsTask().Wait();
                writer.FlushAsync().AsTask().Wait();
                writer.DetachStream();
            }
            stream.Seek(0);
            e.Response = sender.Environment.CreateWebResourceResponse(
                stream, 200, "OK",
                $"Content-Type: {mime}\r\nContent-Length: {bytes.Length}");
        }
        catch
        {
            // leave e.Response null -> WebView2 fails the request (mirrors didFailWithError).
        }
    }

    private static string GuessMime(string ext) => ext.ToLowerInvariant() switch
    {
        ".png" => "image/png",
        ".jpg" or ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".webp" => "image/webp",
        ".pdf" => "application/pdf",
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        _ => "application/octet-stream"
    };

    private void ApplyStatus()
    {
        if (_autoSave is null) return;
        (StatusIcon.Glyph, StatusText.Text) = _autoSave.Status switch
        {
            SaveState.Saved   => ("\uE73E", _t.Get("editorStatusSaved")),
            SaveState.Saving  => ("\uE895", _t.Get("editorStatusSaving")),
            SaveState.Unsaved => ("\uE70F", _t.Get("editorStatusUnsaved")),
            SaveState.Error   => ("\uE783", $"{_t.Get("editorStatusError")} — {_autoSave.ErrorText}"),
            _ => ("\uE73E", _t.Get("editorStatusSaved"))
        };
        // Drive the unsaved gate consumed by NotesViewModel (mirrors coordinator wiring).
        if (_coordinator is not null) _coordinator.HasUnsavedChanges = _autoSave.HasUnsavedChanges;
    }

    private void OnSaveClick(object sender, RoutedEventArgs e) => _autoSave?.ManualSave();
    private void OnHistoryClick(object sender, RoutedEventArgs e) => OnShowHistory?.Invoke();

    // Mirrors coordinator.flushPendingSave wiring: NotesViewModel calls this to flush before switching.
    public void FlushPendingSave() => _autoSave?.ManualSave();
}
```

> Key WebView2 facts used: `EnsureCoreWebView2Async` must run before setting `Source`; `SetVirtualHostNameToFolderMapping("appassets", folder, Deny)`; `AddWebResourceRequestedFilter` + `WebResourceRequested` for `attachment://`; `WebMessageReceived` gives JSON via `WebMessageAsJson`; `ExecuteScriptAsync` runs `window.aino.*`. The `OnChange` callback pushes markdown back into `NotesViewModel.DraftBody` (mirrors `bodyMd = md` in `NoteWYSIWYGEditor.onChange`). The editor host registers `coordinator.HasUnsavedChanges` exactly as the mac coordinator wiring (`onAppear`/`onChange`).

5. (xUnit, if App.Tests exists.) Test `MarkdownHtmlBridge.Decode` for all four kinds + invalid payloads, and `EscapeForTemplateLiteral` for backslash/backtick/dollar order (pure logic, no WinUI types). Do not claim it runs on macOS.

```csharp
using AINotebook.App.Editor;
using Xunit;

public class EditorMessageTests
{
    [Fact] public void Decode_ready() =>
        Assert.IsType<EditorMessage.Ready>(MarkdownHtmlBridge.Decode("{\"kind\":\"ready\"}"));
    [Fact] public void Decode_change_markdown() =>
        Assert.Equal("hi", Assert.IsType<EditorMessage.Change>(
            MarkdownHtmlBridge.Decode("{\"kind\":\"change\",\"markdown\":\"hi\"}")).Markdown);
    [Fact] public void Decode_attachment_allFields()
    {
        var a = Assert.IsType<EditorMessage.AttachmentRequest>(MarkdownHtmlBridge.Decode(
            "{\"kind\":\"attachment\",\"requestId\":\"r\",\"filename\":\"a.png\",\"mime\":\"image/png\",\"base64\":\"AA==\"}"));
        Assert.Equal("a.png", a.Filename);
    }
    [Fact] public void Decode_unknown_returnsNull() =>
        Assert.Null(MarkdownHtmlBridge.Decode("{\"kind\":\"nope\"}"));
    [Fact] public void Escape_order_backslash_backtick_dollar() =>
        Assert.Equal("\\\\ \\` \\$", MarkdownHtmlBridge.EscapeForTemplateLiteral("\\ ` $"));
}
```

6. Commit:

```
git add windows/src/AINotebook.App/Editor/ windows/tests/AINotebook.App.Tests/EditorMessageTests.cs
git commit -m "feat(app): WebView2 editor host — bridge decode, autosave, attachments (M6.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine and manually verify (after M7 copies `editor.html/css/js` into `Resources/editor`): the editor loads (TipTap toolbar visible); typing emits `change` messages and the status flips to "unsaved" then "saved" after the debounce; Ctrl+S flushes immediately; pasting/dropping an image inserts it and it renders via the `attachment://` `WebResourceRequested` path; an unknown post message is ignored; if `editor.html` is missing the "failed to load" message shows.

---

## Task M6.2 — NotesViewModel + NotesPage (3-column) + NotesChatPanel + history dialog

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/NotesViewModel.cs`
- Create `windows/src/AINotebook.App/ViewModels/NotesChatPanelViewModel.cs`
- Create `windows/src/AINotebook.App/ViewModels/NoteHistoryViewModel.cs`
- Create `windows/src/AINotebook.App/Views/NotesPage.xaml`
- Create `windows/src/AINotebook.App/Views/NotesPage.xaml.cs`
- Create `windows/src/AINotebook.App/Controls/NotesChatPanel.xaml`
- Create `windows/src/AINotebook.App/Controls/NotesChatPanel.xaml.cs`
- Create `windows/src/AINotebook.App/Dialogs/NoteHistoryDialog.xaml`
- Create `windows/src/AINotebook.App/Dialogs/NoteHistoryDialog.xaml.cs`

**Steps:**

1. `NotesViewModel.cs` — mirrors `NotesView` state: `notes`, `selection`, `draftTitle`, `draftBody`, `errorMessage`, plus the unsaved-changes gate (`pendingSelection` + `showUnsavedAlert`) and the `NoteJumpCoordinator` subscription. On note save it calls `store.UpdateNote`; the `NotebookStore.OnNoteSaved` callback (wired in Plan 1's DI to run `NoteIndexer.IndexAsync` + `EmbeddingWorker.Kick`) handles indexing — the VM does **not** re-implement indexing. The save path:

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class NotesViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly NoteEditorCoordinator _editorCoord;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;

    public ObservableCollection<Note> Notes { get; } = new();

    [ObservableProperty] public partial Note? SelectedNote { get; set; }
    [ObservableProperty] public partial string DraftTitle { get; set; } = "";
    [ObservableProperty] public partial string DraftBody { get; set; } = "";
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    // Unsaved-changes gate.
    private long? _pendingSelectionId;
    public event Action? UnsavedDialogRequested;      // page shows ContentDialog
    public event Action<long>? HistoryRequested;      // page shows history dialog
    public event Action<long>? JumpHandled;           // page re-selects the note

    public NoteEditorCoordinator EditorCoordinator => _editorCoord;

    public NotesViewModel(
        NotebookStore store, NoteJumpCoordinator noteJump,
        NoteEditorCoordinator editorCoord, ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _noteJump = noteJump; _editorCoord = editorCoord;
        _t = t; _dispatcher = dispatcher;
        _noteJump.TargetChanged += OnJumpTarget;     // Plan-1 coordinator exposes an event/INPC
    }

    public string CurrentNoteBody => SelectedNote?.BodyMd ?? "";
    public Note? CurrentNote => SelectedNote;

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        try
        {
            var current = SelectedNote?.Id;
            Notes.Clear();
            foreach (var n in _store.Notes(_notebookId)) Notes.Add(n);
            // keep selection by id; else pick first.
            SelectedNote = Notes.FirstOrDefault(n => n.Id == current) ?? Notes.FirstOrDefault();
            SyncDraftFromSelection();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    private void SyncDraftFromSelection()
    {
        DraftTitle = SelectedNote?.Title ?? "";
        DraftBody = SelectedNote?.BodyMd ?? "";
    }

    [RelayCommand]
    private async Task CreateBlankAsync()
    {
        try
        {
            var n = _store.CreateNote(_notebookId, _t.Get("noteUntitled"), "");
            await ReloadAsync();
            AttemptSelect(n.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Called by the editor host's autosave sink (OnSaveRequested) AND manual save.
    public void Save(long id, string body)
    {
        try
        {
            _store.UpdateNote(id, DraftTitle, body);  // OnNoteSaved fires indexing in Core/DI
            _dispatcher.TryEnqueue(async () => await ReloadAsync());
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    // Selection interception mirrors NotesView.attemptSelect.
    public void AttemptSelect(long? newId)
    {
        if (_editorCoord.HasUnsavedChanges && newId != SelectedNote?.Id)
        {
            _pendingSelectionId = newId;
            UnsavedDialogRequested?.Invoke();
            return;
        }
        ApplySelection(newId);
    }

    public void OnUnsavedSave()       // dialog "Save"
    {
        _editorCoord.FlushPendingSave?.Invoke();
        CommitPendingSelection();
    }
    public void OnUnsavedDiscard()    // dialog "Discard"
    {
        _editorCoord.HasUnsavedChanges = false;
        CommitPendingSelection();
    }
    public void OnUnsavedCancel() => _pendingSelectionId = null;   // dialog "Cancel"

    private void CommitPendingSelection()
    {
        var target = _pendingSelectionId;
        _pendingSelectionId = null;
        ApplySelection(target);
    }

    private void ApplySelection(long? id)
    {
        SelectedNote = Notes.FirstOrDefault(n => n.Id == id);
        SyncDraftFromSelection();
    }

    [RelayCommand]
    private void ShowHistory()
    {
        if (SelectedNote?.Id is { } id) HistoryRequested?.Invoke(id);
    }

    private void OnJumpTarget(long? target)
    {
        if (target is { } id && Notes.Any(n => n.Id == id))
        {
            AttemptSelect(id);
            _noteJump.Clear();
        }
    }

    public string OriginLabel(NoteOrigin o) => o switch
    {
        NoteOrigin.Manual => _t.Get("noteOriginManual"),
        NoteOrigin.Chat => _t.Get("noteOriginChat"),
        NoteOrigin.Transformation => _t.Get("noteOriginTransformation"),
        _ => ""
    };
}
```

> The `NoteJumpCoordinator` from Plan 1 must expose either a `TargetChanged` event or `INotifyPropertyChanged` on `Target`; I subscribe to it (mirrors `.onReceive(noteJump.$target...)`). If Plan 1 only exposes an `ObservableProperty Target`, subscribe via `PropertyChanged` instead — note this dependency in the task. `NoteEditorCoordinator` must expose `bool HasUnsavedChanges` and `Action? FlushPendingSave` (matches the mac `NoteEditorCoordinator`); confirm Plan 1's port matches.

2. `NotesChatPanelViewModel.cs` — mirrors `NotesChatPanel`: a single-session chat scoped to the notebook that passes `currentNoteContent` into `ChatEngine.SendAsync`. It reuses `MessageViewModel`/`CitationViewModel` from M5 and the same streaming+citation logic, differing only in (a) it auto-uses the first/created session and (b) it sends `currentNoteContent: currentNote?.BodyMd`:

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public partial class NotesChatPanelViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ChatEngineHolder _chatHolder;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;
    private long? _sessionId;

    public ObservableCollection<MessageViewModel> Messages { get; } = new();
    [ObservableProperty] public partial string Input { get; set; } = "";
    [ObservableProperty] public partial string StreamingDraft { get; set; } = "";
    [ObservableProperty] public partial bool Sending { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    [ObservableProperty] public partial bool ShowEmptyState { get; set; } = true;

    // Pushed live from NotesViewModel.SelectedNote so context tracks the open note.
    public Func<Note?>? CurrentNoteProvider { get; set; }
    public bool HasCurrentNote => CurrentNoteProvider?.Invoke() is not null;

    public NotesChatPanelViewModel(
        NotebookStore store, ChatEngineHolder chatHolder,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    { _store = store; _chatHolder = chatHolder; _t = t; _dispatcher = dispatcher; }

    public bool CanSend => !Sending && !string.IsNullOrWhiteSpace(Input);
    partial void OnInputChanged(string v) => SendCommand.NotifyCanExecuteChanged();
    partial void OnSendingChanged(bool v) => SendCommand.NotifyCanExecuteChanged();

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        try
        {
            var existing = _store.ChatSessions(notebookId);
            _sessionId = existing.FirstOrDefault()?.Id
                ?? _store.CreateChatSession(notebookId, _t.Get("chatNewSessionTitle")).Id;
            ReloadMessages();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    private void ReloadMessages()
    {
        Messages.Clear();
        if (_sessionId is not { } sid) { ShowEmptyState = true; return; }
        foreach (var m in _store.Messages(sid)) Messages.Add(new MessageViewModel { Message = m });
        ShowEmptyState = Messages.Count == 0 && string.IsNullOrEmpty(StreamingDraft);
    }

    [RelayCommand(CanExecute = nameof(CanSend))]
    private async Task SendAsync()
    {
        if (_sessionId is not { } sid) return;
        var text = Input.Trim();
        if (text.Length == 0) return;
        Input = ""; Sending = true; ErrorMessage = null; StreamingDraft = "";
        var noteCtx = CurrentNoteProvider?.Invoke()?.BodyMd;
        try
        {
            await _chatHolder.Engine.SendAsync(sid, _notebookId, text,
                currentNoteContent: noteCtx,
                onToken: tok => _dispatcher.TryEnqueue(() => StreamingDraft += tok));
            ReloadMessages();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); ReloadMessages(); }
        finally { Sending = false; StreamingDraft = ""; }
    }

    // Save-as-note + citation resolution identical to ChatViewModel (reuse CitationViewModel.Resolve).
    public CitationViewModel BuildCitationViewModel(Citation c) => CitationViewModel.Resolve(_store, c);

    [RelayCommand]
    private void SaveAsNote(MessageViewModel? vm)
    {
        if (vm?.Message is not { } msg) return;
        try
        {
            var when = msg.CreatedAt.ToLocalTime().ToString("d MMM yyyy, h:mm tt");
            _store.CreateNote(_notebookId, $"Chat reply — {when}", msg.Content, NoteOrigin.Chat, msg.Id);
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}
```

> Refactor the citation resolver into `static CitationViewModel CitationViewModel.Resolve(NotebookStore, Citation)` in M5.1 so both `ChatViewModel` and `NotesChatPanelViewModel` share it (no duplication).

3. `NoteHistoryViewModel.cs` — mirrors `NoteHistorySheet`: load `NoteVersions(noteId)`, preview the selected version's title + monospaced body, and `RestoreNoteVersion(versionId)` then close:

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class NoteHistoryViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _t;
    private long _noteId;

    public ObservableCollection<NoteVersion> Versions { get; } = new();  // newest-first
    [ObservableProperty] public partial NoteVersion? Selected { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    public event Action? RequestClose;

    public NoteHistoryViewModel(NotebookStore store, ILocalizedStrings t) { _store = store; _t = t; }

    public void Load(long noteId)
    {
        _noteId = noteId;
        try
        {
            Versions.Clear();
            foreach (var v in _store.NoteVersions(noteId).Reverse()) Versions.Add(v);  // mac shows reversed
            Selected = Versions.FirstOrDefault();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    public string ReasonLabel(NoteVersionReason r) => r switch
    {
        NoteVersionReason.Autosave => _t.Get("historyReasonAutosave"),
        NoteVersionReason.Manual => _t.Get("editorStatusSaved"),
        NoteVersionReason.Restore => _t.Get("historyReasonRestore"),
        _ => ""
    };

    [RelayCommand]
    private void Restore()
    {
        if (Selected?.Id is not { } id) return;
        try { _store.RestoreNoteVersion(id); RequestClose?.Invoke(); }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}
```

4. `NotesPage.xaml` — the 3-column layout (list | editor | chat panel), filling the full window (mirrors the v0.7.x "fills full window" fix). Use a `Grid` with three columns. The list shows title + origin label; "New" button at top; empty-state when no notes. The center hosts `EditorWebView`; the right hosts `NotesChatPanel`:

```xml
<Page
    x:Class="AINotebook.App.Views.NotesPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:editor="using:AINotebook.App.Editor"
    xmlns:ctrl="using:AINotebook.App.Controls"
    xmlns:models="using:AINotebook.Core.Models">
    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="260"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="360"/>
        </Grid.ColumnDefinitions>

        <!-- Notes list -->
        <Grid Grid.Column="0" Padding="12">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <Grid Grid.Row="0">
                <TextBlock x:Name="NotesTitle" Style="{ThemeResource SubtitleTextBlockStyle}"/>
                <Button x:Name="NewButtonTop" HorizontalAlignment="Right"
                        Command="{x:Bind ViewModel.CreateBlankCommand}"/>
            </Grid>
            <ListView Grid.Row="1" x:Name="NotesList"
                      ItemsSource="{x:Bind ViewModel.Notes, Mode=OneWay}"
                      SelectionChanged="OnNotesSelectionChanged">
                <ListView.ItemTemplate>
                    <DataTemplate x:DataType="models:Note">
                        <StackPanel Spacing="2">
                            <TextBlock Text="{x:Bind Title}" Style="{ThemeResource BodyStrongTextBlockStyle}"/>
                            <TextBlock Style="{ThemeResource CaptionTextBlockStyle}"
                                       Foreground="{ThemeResource TextFillColorSecondaryBrush}"
                                       Text="{x:Bind Origin}"/>
                        </StackPanel>
                    </DataTemplate>
                </ListView.ItemTemplate>
            </ListView>
            <StackPanel Grid.Row="1" x:Name="EmptyNotes" Visibility="Collapsed"
                        VerticalAlignment="Center" HorizontalAlignment="Center" Spacing="10">
                <FontIcon Glyph="&#xE70B;" FontSize="32"/>
                <TextBlock x:Name="EmptyNotesText" TextWrapping="Wrap" TextAlignment="Center"/>
                <Button x:Name="NewButtonEmpty" Command="{x:Bind ViewModel.CreateBlankCommand}"
                        Style="{ThemeResource AccentButtonStyle}"/>
            </StackPanel>
        </Grid>

        <!-- Editor -->
        <Grid Grid.Column="1" Padding="16">
            <editor:EditorWebView x:Name="Editor" Title="{x:Bind ViewModel.DraftTitle, Mode=TwoWay}"
                                  Visibility="Collapsed"/>
            <StackPanel x:Name="NoSelection" VerticalAlignment="Center" HorizontalAlignment="Center" Spacing="10">
                <FontIcon Glyph="&#xE7C3;" FontSize="32"/>
                <TextBlock x:Name="NoSelectionText"/>
            </StackPanel>
        </Grid>

        <!-- Chat panel -->
        <ctrl:NotesChatPanel Grid.Column="2" x:Name="ChatPanel"/>
    </Grid>
</Page>
```

> The `ListView.ItemTemplate` binds `Origin` (the enum) directly for brevity; to show the localized origin label instead, replace with a `TextBlock` whose `Text` is set in `OnContainerContentChanging` via `ViewModel.OriginLabel(note.Origin)`, or bind through a converter that calls the VM. The load-bearing behavior is the localized label; choose the converter approach in code-behind.

5. `NotesPage.xaml.cs` — resolves the VM, localizes strings, manages selection (calling `ViewModel.AttemptSelect` so the unsaved gate fires before switching), reconfigures the `EditorWebView` per note open, shows the unsaved-changes `ContentDialog`, shows the history dialog, and pushes the current note into the chat panel:

```csharp
using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Dialogs;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class NotesPage : Page
{
    public NotesViewModel ViewModel { get; }
    private readonly AttachmentStore _attachments;
    private readonly ILocalizedStrings _t;
    private bool _suppressSelection;

    public NotesPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<NotesViewModel>();
        _attachments = App.Current.Services.GetRequiredService<AttachmentStore>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();

        NotesTitle.Text = _t.Get("notesSectionTitle");
        NewButtonTop.Content = _t.Get("notesNewButton");
        NewButtonEmpty.Content = _t.Get("notesNewButton");
        EmptyNotesText.Text = _t.Get("notesEmptyState");
        NoSelectionText.Text = _t.Get("notesEmptyState");

        ViewModel.PropertyChanged += OnVmPropertyChanged;
        ViewModel.UnsavedDialogRequested += async () => await ShowUnsavedDialog();
        ViewModel.HistoryRequested += async id => await ShowHistoryDialog(id);
        ViewModel.Notes.VectorChanged += (_, _) => RefreshEmptyState();

        ChatPanel.SetCurrentNoteProvider(() => ViewModel.CurrentNote);
    }

    public async void Load(long notebookId)
    {
        await ViewModel.LoadAsync(notebookId);
        await ChatPanel.LoadAsync(notebookId);
        SyncSelectionToList();
        RefreshEmptyState();
        ReconfigureEditor();
    }

    private void OnVmPropertyChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NotesViewModel.SelectedNote))
        {
            SyncSelectionToList();
            ReconfigureEditor();
        }
    }

    private void OnNotesSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressSelection) return;
        var id = (NotesList.SelectedItem as Note)?.Id;
        // Route through the gate; if the gate cancels, snap back happens via ApplySelection.
        ViewModel.AttemptSelect(id);
        SyncSelectionToList();   // re-sync if the gate kept the old selection
    }

    private void SyncSelectionToList()
    {
        _suppressSelection = true;
        NotesList.SelectedItem = ViewModel.SelectedNote;
        _suppressSelection = false;
    }

    private void ReconfigureEditor()
    {
        if (ViewModel.SelectedNote is { } n && n.Id is { } id)
        {
            NoSelection.Visibility = Visibility.Collapsed;
            Editor.Visibility = Visibility.Visible;
            Editor.OnChange = md => ViewModel.DraftBody = md;
            Editor.OnSaveRequested = body => ViewModel.Save(id, body);
            Editor.OnShowHistory = () => ViewModel.ShowHistoryCommand.Execute(null);
            Editor.Configure(id, n.NoteUuid, n.BodyMd, _attachments, ViewModel.EditorCoordinator, _t);
        }
        else
        {
            Editor.Visibility = Visibility.Collapsed;
            NoSelection.Visibility = Visibility.Visible;
        }
    }

    private void RefreshEmptyState()
    {
        var empty = ViewModel.Notes.Count == 0;
        EmptyNotes.Visibility = empty ? Visibility.Visible : Visibility.Collapsed;
        NotesList.Visibility = empty ? Visibility.Collapsed : Visibility.Visible;
    }

    private async System.Threading.Tasks.Task ShowUnsavedDialog()
    {
        var dialog = new ContentDialog
        {
            XamlRoot = this.XamlRoot,
            Title = _t.Get("unsavedChangesTitle"),
            Content = _t.Get("unsavedChangesMessage"),
            PrimaryButtonText = _t.Get("unsavedSaveButton"),
            SecondaryButtonText = _t.Get("unsavedDiscardButton"),
            CloseButtonText = _t.Get("cancelButton"),
            DefaultButton = ContentDialogButton.Primary
        };
        var result = await dialog.ShowAsync();
        switch (result)
        {
            case ContentDialogResult.Primary: ViewModel.OnUnsavedSave(); break;
            case ContentDialogResult.Secondary: ViewModel.OnUnsavedDiscard(); break;
            default: ViewModel.OnUnsavedCancel(); break;
        }
        SyncSelectionToList();
    }

    private async System.Threading.Tasks.Task ShowHistoryDialog(long noteId)
    {
        var dialog = new NoteHistoryDialog(noteId) { XamlRoot = this.XamlRoot };
        await dialog.ShowAsync();
        await ViewModel.ReloadAsync();   // mirrors .sheet onDismiss reload (restore may have changed body)
        ReconfigureEditor();
    }
}
```

> `ContentDialog` requires `XamlRoot` (unpackaged). The three-button mapping (Primary=Save, Secondary=Discard, Close=Cancel) mirrors the mac alert. After a restore, reload + reconfigure the editor so it shows the restored body.

6. `NotesChatPanel.xaml` / `.xaml.cs` — a `UserControl` reusing the M5 `MessageBubble` + citation Flyout pattern, with a header (`notesChatPanelTitle`, plus `notesChatCurrentNoteHint` when a note is open), the message list, and the input bar (`chatInputPlaceholder` / send on Ctrl+Enter). It resolves `NotesChatPanelViewModel` from DI and exposes `LoadAsync(notebookId)` + `SetCurrentNoteProvider(Func<Note?>)`. The citation Flyout reuses the same builder as `ChatPage` (factor `ShowCitationFlyout` into a shared static helper `CitationFlyout.Show(anchor, cvm, t, onOpenNote)` to avoid duplication). Empty-state string = `notesChatPanelEmpty`.

7. `NoteHistoryDialog.xaml` / `.xaml.cs` — a `ContentDialog` (not a sheet) mirroring `NoteHistorySheet`: left list of versions (reason label + savedAt), right preview (title + monospaced body + Restore button). Title `historySheetTitle`; empty `historyEmpty`; restore `historyRestoreButton`; close `cancelButton`. Resolve `NoteHistoryViewModel` from DI, call `Load(noteId)` in the ctor, wire `RequestClose` to `Hide()`:

```csharp
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Dialogs;

public sealed partial class NoteHistoryDialog : ContentDialog
{
    public NoteHistoryViewModel ViewModel { get; }

    public NoteHistoryDialog(long noteId)
    {
        ViewModel = App.Current.Services.GetRequiredService<NoteHistoryViewModel>();
        var t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        Title = t.Get("historySheetTitle");
        CloseButtonText = t.Get("cancelButton");
        ViewModel.RequestClose += Hide;
        ViewModel.Load(noteId);
    }
}
```

> The XAML body uses two `Grid` columns (list + preview); the version list `DataTemplate` shows `ViewModel.ReasonLabel(v.Reason)` (via converter/code-behind) and `v.SavedAt`. The preview's Restore `Button` binds `ViewModel.RestoreCommand`.

8. Register VMs in DI: `services.AddTransient<NotesViewModel>(); services.AddTransient<NotesChatPanelViewModel>(); services.AddTransient<NoteHistoryViewModel>();` (note for Plan 1's `ConfigureServices`). `AttachmentStore` and the coordinators are Plan-1 singletons.

9. Commit:

```
git add windows/src/AINotebook.App/ViewModels/NotesViewModel.cs windows/src/AINotebook.App/ViewModels/NotesChatPanelViewModel.cs windows/src/AINotebook.App/ViewModels/NoteHistoryViewModel.cs windows/src/AINotebook.App/Views/NotesPage.xaml windows/src/AINotebook.App/Views/NotesPage.xaml.cs windows/src/AINotebook.App/Controls/NotesChatPanel.xaml windows/src/AINotebook.App/Controls/NotesChatPanel.xaml.cs windows/src/AINotebook.App/Dialogs/NoteHistoryDialog.xaml windows/src/AINotebook.App/Dialogs/NoteHistoryDialog.xaml.cs
git commit -m "feat(app): Notes tab — 3-column view, editor host wiring, chat panel, history (M6.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine and manually verify (after M7): the Notes tab shows the 3-column layout filling the window; "New" creates a note and selects it; typing in the editor autosaves (status flips), Ctrl+S flushes; the note list reflects updated titles after save; switching notes with unsaved changes shows the unsaved-changes `ContentDialog` (Save flushes then switches, Discard switches, Cancel keeps the current note and re-selects it in the list); History (Ctrl+Shift+H) opens the version dialog and Restore replaces the body; the right chat panel sends with the open note as context and shows citations; "Save as note" from the chat panel adds a note.

---

## Milestone M7 — editor.ts bridge shim + asset wiring

Applies the transport-detection shim to `tools/editor/src/editor.ts` (the single shared change that keeps mac on the WebKit branch), rebuilds `editor.js`, and wires the App build to copy `editor.html/css/js` from the mac `Resources/editor` into the App's output (`Resources/editor`). The `attachment://` URL form is unchanged (the editor already builds `attachment://<noteUuid>/<filename>` from the host-returned URL, served by `WebResourceRequested` in M6.1), so only the `postToSwift` transport changes.

## Task M7.1 — postToSwift transport shim + rebuild editor.js

**Files:**
- Modify `windows/.../` none — Modify `/Users/lukasoplt/Documents/AI_Notebook/tools/editor/src/editor.ts`
- Modify (regenerated artifact) `/Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookApp/Resources/editor/editor.js`

**Steps:**

1. Edit `editor.ts`. Extend the `Window` interface to declare the WebView2 transport, then change **only** `postToSwift` to detect the transport (WebView2 first, else WebKit). Everything else (the `window.aino.setContent`/`attachmentSaved`/`attachmentDenied` host→JS calls, the four JS→native message kinds, the attachment URL form) stays identical.

Replace the `declare global` block's `Window` interface to add `chrome`:

```ts
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        aino?: { postMessage: (m: unknown) => void }
      }
    }
    chrome?: {
      webview?: { postMessage: (m: unknown) => void }
    }
    aino?: {
      setContent: (md: string) => void
      requestSave: () => void
    }
  }
}
```

Replace `postToSwift`:

```ts
function postToSwift(payload: unknown) {
  // WebView2 (Windows) exposes window.chrome.webview.postMessage; prefer it when present.
  // Otherwise fall back to the WebKit message handler (macOS) — unchanged behavior.
  if (window.chrome?.webview?.postMessage) {
    window.chrome.webview.postMessage(payload)
  } else {
    window.webkit?.messageHandlers?.aino?.postMessage(payload)
  }
}
```

> The host→JS calls (`window.aino.setContent`, `attachmentSaved`, `attachmentDenied`) are invoked identically by WebView2's `ExecuteScriptAsync` and WebKit's `evaluateJavaScript`, so no change there. The four message kinds (`ready`/`change`/`save`/`attachment`) and the `attachment://<noteUuid>/<filename>` URL form are untouched. WebView2's `WebMessageAsJson` round-trips the same object literal, so `MarkdownHtmlBridge.Decode` (M6.1) reads the identical shape.

2. Rebuild the bundle via the existing esbuild pipeline (writes to `Sources/AINotebookApp/Resources/editor/editor.js`):

```
git -C /Users/lukasoplt/Documents/AI_Notebook checkout -b winui-editor-shim   # only if on main and user expects a branch
npm --prefix /Users/lukasoplt/Documents/AI_Notebook/tools/editor install
node /Users/lukasoplt/Documents/AI_Notebook/tools/editor/build.mjs
```

3. Verify the mac app still builds with the rebuilt bundle (the WebKit branch is untouched), and confirm the new bundle contains the transport detection:

```
grep -c "chrome" /Users/lukasoplt/Documents/AI_Notebook/Sources/AINotebookApp/Resources/editor/editor.js   # expect >= 1
swift build --package-path /Users/lukasoplt/Documents/AI_Notebook    # mac dev box: confirm green
```

4. Commit:

```
git -C /Users/lukasoplt/Documents/AI_Notebook add tools/editor/src/editor.ts Sources/AINotebookApp/Resources/editor/editor.js
git -C /Users/lukasoplt/Documents/AI_Notebook commit -m "feat(editor): postToSwift transport detection (WebView2 + WebKit), rebuild bundle (M7.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** On the mac dev box, `swift build` stays green and the mac editor still works (it falls through to the WebKit branch). On a Windows machine, after M7.2 copies the bundle, confirm the editor posts messages (the host's `WebMessageReceived` fires for `ready`/`change`).

---

## Task M7.2 — App build copies editor assets into the bundle

**Files:**
- Modify `windows/src/AINotebook.App/AINotebook.App.csproj`

**Steps:**

1. Add an MSBuild step to `AINotebook.App.csproj` that copies the three editor files from the mac `Resources/editor` into the App output under `Resources/editor` (read-only reuse; nothing duplicated in `windows/`). Use a `Content` glob with a link + `CopyToOutputDirectory`, pointing at the repo-relative source path. The App `.csproj` lives at `windows/src/AINotebook.App/`, so the editor folder is `..\..\..\Sources\AINotebookApp\Resources\editor\`:

```xml
<ItemGroup>
  <!-- Reuse the mac-built editor bundle (editor.ts shim makes it cross-platform). -->
  <Content Include="..\..\..\Sources\AINotebookApp\Resources\editor\editor.html">
    <Link>Resources\editor\editor.html</Link>
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
  <Content Include="..\..\..\Sources\AINotebookApp\Resources\editor\editor.css">
    <Link>Resources\editor\editor.css</Link>
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
  <Content Include="..\..\..\Sources\AINotebookApp\Resources\editor\editor.js">
    <Link>Resources\editor\editor.js</Link>
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
</ItemGroup>
```

> This matches the M6.1 host, which loads from `Path.Combine(AppContext.BaseDirectory, "Resources", "editor")` and maps it to `https://appassets`. `PreserveNewest` ensures a rebuilt bundle (from M7.1) is recopied. The files stay the single source of truth under `Sources/AINotebookApp/Resources/editor`; the design spec calls for exactly this build-time copy (no committed duplicate in `windows/`).

2. Commit:

```
git -C /Users/lukasoplt/Documents/AI_Notebook add windows/src/AINotebook.App/AINotebook.App.csproj
git -C /Users/lukasoplt/Documents/AI_Notebook commit -m "build(app): copy editor.html/css/js into output Resources/editor (M7.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine (`dotnet build`) and confirm `bin\...\Resources\editor\editor.html`, `editor.css`, `editor.js` exist in the output; `dotnet run` and open a note — the editor renders (proves the `appassets` virtual host serves the copied bundle).

---

## Milestone M8 — Transformations tab

Mirrors `TransformationsView.swift`, `TransformationEditorSheet.swift`, `TransformationHistorySheet.swift`, `TransformationPromptPreviewSheet.swift`. Consumes `NotebookStore` (`Transformations`, `Sources`, `SourcesIncludingShadow`, `Chunks`, `CreateTransformation`, `UpdateTransformation`, `UpdateTransformationScope`, `DeleteTransformation`, `TransformationRuns`, `Notes`, `Note`) and the resolved `TransformationEngine` (via `TransformationEngineHolder`, Plan 1) with `RunAsync(transformationId, sourceId, onToken)`, `RunNotebookScopeAsync(transformationId, notebookId, onToken)`, `RunOnAllSourcesAsync(transformationId, notebookId, onProgress)`. Uses `TabSwitchCoordinator` + `NoteJumpCoordinator` for "Open note".

## Task M8.1 — TransformationsViewModel

**Files:**
- Create `windows/src/AINotebook.App/ViewModels/TransformationsViewModel.cs`

**Steps:**

1. Create `TransformationsViewModel.cs`. Mirror `TransformationsView` state: `transformations`, `sources`, `selectedTransformationId`, `selectedSourceId`, `scope` (Source/Notebook/AllSources), `resultBody`, `resultNoteId`, `batchCompleted`, `batchTotal`, `batchSavedCount`, `running`, `errorMessage`. The `onToken`/`onProgress` callbacks marshal via `DispatcherQueue`. Scope auto-syncs to `.notebook` when the picked transformation's scope is `Notebook` (mirrors `onChange(of: selectedTransformationId)`). "Open note" requests the Notes tab then jumps after a short delay (mirrors the 50ms `Task.sleep`):

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Rag;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.UI.Dispatching;

namespace AINotebook.App.ViewModels;

public enum BatchScope { Source, Notebook, AllSources }

public partial class TransformationsViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly TransformationEngineHolder _engineHolder;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private readonly ILocalizedStrings _t;
    private readonly DispatcherQueue _dispatcher;
    private long _notebookId;

    public ObservableCollection<Transformation> Transformations { get; } = new();
    public ObservableCollection<Source> Sources { get; } = new();

    [ObservableProperty] public partial Transformation? SelectedTransformation { get; set; }
    [ObservableProperty] public partial Source? SelectedSource { get; set; }
    [ObservableProperty] public partial BatchScope Scope { get; set; } = BatchScope.Source;
    [ObservableProperty] public partial string ResultBody { get; set; } = "";
    [ObservableProperty] public partial long? ResultNoteId { get; set; }
    [ObservableProperty] public partial int BatchCompleted { get; set; }
    [ObservableProperty] public partial int BatchTotal { get; set; }
    [ObservableProperty] public partial int? BatchSavedCount { get; set; }
    [ObservableProperty] public partial bool Running { get; set; }
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public TransformationsViewModel(
        NotebookStore store, TransformationEngineHolder engineHolder,
        NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch,
        ILocalizedStrings t, DispatcherQueue dispatcher)
    {
        _store = store; _engineHolder = engineHolder;
        _noteJump = noteJump; _tabSwitch = tabSwitch; _t = t; _dispatcher = dispatcher;
    }

    public string? SelectedTransformationDescription =>
        string.IsNullOrEmpty(SelectedTransformation?.Description) ? null : SelectedTransformation!.Description;

    partial void OnSelectedTransformationChanged(Transformation? value)
    {
        if (value is { } tx) Scope = tx.Scope == TransformationScope.Notebook ? BatchScope.Notebook : BatchScope.Source;
        RunCommand.NotifyCanExecuteChanged();
    }
    partial void OnSelectedSourceChanged(Source? v) => RunCommand.NotifyCanExecuteChanged();
    partial void OnScopeChanged(BatchScope v) => RunCommand.NotifyCanExecuteChanged();
    partial void OnRunningChanged(bool v) => RunCommand.NotifyCanExecuteChanged();

    public async Task LoadAsync(long notebookId)
    {
        _notebookId = notebookId;
        await ReloadAsync();
    }

    public async Task ReloadAsync()
    {
        try
        {
            var prevTx = SelectedTransformation?.Id;
            var prevSrc = SelectedSource?.Id;
            Transformations.Clear();
            foreach (var tx in _store.Transformations()) Transformations.Add(tx);
            Sources.Clear();
            foreach (var s in _store.Sources(_notebookId)) Sources.Add(s);

            SelectedTransformation = Transformations.FirstOrDefault(x => x.Id == prevTx)
                ?? Transformations.FirstOrDefault();
            SelectedSource = Sources.FirstOrDefault(x => x.Id == prevSrc) ?? Sources.FirstOrDefault();
            if (SelectedTransformation?.Scope == TransformationScope.Notebook) Scope = BatchScope.Notebook;
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        await Task.CompletedTask;
    }

    private bool CanRun =>
        !Running
        && SelectedTransformation is not null
        && !(Scope == BatchScope.Source && SelectedSource is null)
        && !(Scope == BatchScope.AllSources && Sources.Count == 0);

    [RelayCommand(CanExecute = nameof(CanRun))]
    private async Task RunAsync()
    {
        if (SelectedTransformation?.Id is not { } tid) return;
        Running = true; ErrorMessage = null;
        ResultBody = ""; ResultNoteId = null;
        BatchSavedCount = null; BatchCompleted = 0; BatchTotal = 0;
        var engine = _engineHolder.Engine;
        try
        {
            switch (Scope)
            {
                case BatchScope.Source:
                    if (SelectedSource?.Id is not { } sid) return;
                    var note = await engine.RunAsync(tid, sid,
                        onToken: tok => _dispatcher.TryEnqueue(() => ResultBody += tok));
                    ResultNoteId = note.Id;
                    break;
                case BatchScope.Notebook:
                    var nbNote = await engine.RunNotebookScopeAsync(tid, _notebookId,
                        onToken: tok => _dispatcher.TryEnqueue(() => ResultBody += tok));
                    ResultNoteId = nbNote.Id;
                    break;
                case BatchScope.AllSources:
                    BatchTotal = Sources.Count;
                    var notes = await engine.RunOnAllSourcesAsync(tid, _notebookId,
                        onProgress: (done, total) => _dispatcher.TryEnqueue(() =>
                        {
                            BatchCompleted = done; BatchTotal = total;
                        }));
                    BatchSavedCount = notes.Count;
                    break;
            }
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
        finally { Running = false; }
    }

    // Open the resulting note: switch to Notes tab then jump (mirrors the 50ms delay).
    [RelayCommand]
    private async Task OpenResultNoteAsync()
    {
        _tabSwitch.Request(TabSwitchCoordinator.Tab.Notes);
        if (ResultNoteId is { } nid)
        {
            await Task.Delay(50);
            _noteJump.Request(nid);
        }
    }

    public string ResultSavedTitle()
    {
        if (ResultNoteId is { } nid)
        {
            var title = _store.Note(nid)?.Title ?? "";
            return string.Format(_t.Get("aiToolsResultSavedFormat"), title);
        }
        return "";
    }

    public string RunningFormat() => string.Format(_t.Get("aiToolsRunningFormat"), BatchCompleted, BatchTotal);
    public string BatchSavedFormat() => string.Format(_t.Get("aiToolsBatchSavedFormat"), BatchSavedCount ?? 0);
}
```

> `TransformationEngineHolder.Engine` mirrors `transformationHolder.engine`. The `aiToolsRunningFormat`/`aiToolsResultSavedFormat`/`aiToolsBatchSavedFormat` keys are `String.Format` patterns ported from `AppText` (so they keep `%d`/`%@` → `{0}`/`{1}` semantics; Writer B's `.resw` port must use `{0}`-style placeholders — note this for Plan 1).

2. Register: `services.AddTransient<TransformationsViewModel>();`.

3. Commit:

```
git add windows/src/AINotebook.App/ViewModels/TransformationsViewModel.cs
git commit -m "feat(app): TransformationsViewModel — single/notebook/batch run + open-note (M8.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine; if App.Tests exists, optionally unit-test the scope auto-sync (`OnSelectedTransformationChanged` flips to `Notebook` for a notebook-scoped transformation) using a constructed VM with a fake `DispatcherQueue` is not feasible — instead assert via the `CanRun` gating with an in-memory store; do not claim it runs on macOS.

---

## Task M8.2 — TransformationsPage + editor/history/preview dialogs

**Files:**
- Create `windows/src/AINotebook.App/Views/TransformationsPage.xaml`
- Create `windows/src/AINotebook.App/Views/TransformationsPage.xaml.cs`
- Create `windows/src/AINotebook.App/ViewModels/TransformationEditorViewModel.cs`
- Create `windows/src/AINotebook.App/Dialogs/TransformationEditorDialog.xaml`
- Create `windows/src/AINotebook.App/Dialogs/TransformationEditorDialog.xaml.cs`
- Create `windows/src/AINotebook.App/ViewModels/TransformationHistoryViewModel.cs`
- Create `windows/src/AINotebook.App/Dialogs/TransformationHistoryDialog.xaml`
- Create `windows/src/AINotebook.App/Dialogs/TransformationHistoryDialog.xaml.cs`
- Create `windows/src/AINotebook.App/Dialogs/TransformationPromptPreviewDialog.xaml`
- Create `windows/src/AINotebook.App/Dialogs/TransformationPromptPreviewDialog.xaml.cs`

**Steps:**

1. `TransformationsPage.xaml` — mirrors `TransformationsView`: header (title `aiToolsSectionTitle` + History button `aiToolsHistoryButton` + Edit button `transformationEditButton`); a template row (label `transformationPickerLabel`, Preview button `aiToolsPreviewButton`, a `ComboBox` of transformations, description); a scope row (a 3-segment selector Source/Notebook/AllSources via a `RadioButtons` or segmented `Selector`, hint `aiToolsScopeHint`, a source `ComboBox` when scope=Source, and the Run button `transformationRunButton` with Ctrl+Enter); and a content area switching between running (progress + streamed text), single-saved (open-note + result), batch-saved toast, and empty explainer (`aiToolsEmptyTitle`/`aiToolsEmptyBody`). Fill the full window:

```xml
<Page
    x:Class="AINotebook.App.Views.TransformationsPage"
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    xmlns:models="using:AINotebook.Core.Models">
    <Grid Padding="20" RowSpacing="14">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0">
            <TextBlock x:Name="HeaderTitle" Style="{ThemeResource TitleTextBlockStyle}"/>
            <StackPanel Orientation="Horizontal" Spacing="8" HorizontalAlignment="Right">
                <Button x:Name="HistoryBtn" Click="OnHistory"/>
                <Button x:Name="EditBtn" Click="OnEdit"/>
            </StackPanel>
        </Grid>

        <!-- Template row -->
        <StackPanel Grid.Row="1" Spacing="6">
            <Grid>
                <TextBlock x:Name="PickerLabel" Style="{ThemeResource CaptionTextBlockStyle}"
                           Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
                <HyperlinkButton x:Name="PreviewBtn" HorizontalAlignment="Right" Click="OnPreview"/>
            </Grid>
            <ComboBox x:Name="TemplateCombo" HorizontalAlignment="Stretch"
                      ItemsSource="{x:Bind ViewModel.Transformations, Mode=OneWay}"
                      SelectedItem="{x:Bind ViewModel.SelectedTransformation, Mode=TwoWay}"
                      DisplayMemberPath="Name"/>
            <TextBlock Text="{x:Bind ViewModel.SelectedTransformationDescription, Mode=OneWay}"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}" TextWrapping="Wrap"/>
        </StackPanel>

        <!-- Scope row -->
        <StackPanel Grid.Row="2" Spacing="6">
            <muxc:Segmented x:Name="ScopeSeg" xmlns:muxc="using:CommunityToolkit.WinUI.Controls"
                            SelectionChanged="OnScopeChanged">
                <muxc:SegmentedItem x:Name="ScopeSource" Content="Source"/>
                <muxc:SegmentedItem x:Name="ScopeNotebook" Content="Notebook"/>
                <muxc:SegmentedItem x:Name="ScopeAll"/>
            </muxc:Segmented>
            <TextBlock x:Name="ScopeHint" Style="{ThemeResource CaptionTextBlockStyle}"
                       Foreground="{ThemeResource TextFillColorTertiaryBrush}"/>
        </StackPanel>

        <!-- Source picker + Run -->
        <Grid Grid.Row="3" ColumnSpacing="8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ComboBox x:Name="SourceCombo" Grid.Column="0" MaxWidth="360" HorizontalAlignment="Left"
                      ItemsSource="{x:Bind ViewModel.Sources, Mode=OneWay}"
                      SelectedItem="{x:Bind ViewModel.SelectedSource, Mode=TwoWay}"
                      DisplayMemberPath="Title"/>
            <Button x:Name="RunBtn" Grid.Column="1" Command="{x:Bind ViewModel.RunCommand}"
                    Style="{ThemeResource AccentButtonStyle}">
                <Button.KeyboardAccelerators>
                    <KeyboardAccelerator Modifiers="Control" Key="Enter"/>
                </Button.KeyboardAccelerators>
            </Button>
        </Grid>

        <!-- Content (managed in code-behind via visibility) -->
        <Grid Grid.Row="4" x:Name="ContentHost"/>

        <TextBlock Grid.Row="5" x:Name="ErrorText" Foreground="Red" TextWrapping="Wrap"/>
    </Grid>
</Page>
```

> WinUI has no segmented control in-box; use `CommunityToolkit.WinUI.Controls.Segmented` (referenced by Plan 1) or a `RadioButtons` group as a fallback. The content states (running/single-saved/batch-toast/empty) are simpler to toggle in code-behind than via four nested `DataTemplate`s — build them in `.xaml.cs` and swap visibility on `ViewModel.PropertyChanged`.

2. `TransformationsPage.xaml.cs` — localize strings, manage scope segment selection (mirror `BatchScope`), show source combo only when scope=Source, build the four content states, and open the three dialogs:

```csharp
using System;
using AINotebook.App.Services;
using AINotebook.App.ViewModels;
using AINotebook.App.Dialogs;
using AINotebook.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace AINotebook.App.Views;

public sealed partial class TransformationsPage : Page
{
    public TransformationsViewModel ViewModel { get; }
    private readonly ILocalizedStrings _t;

    public TransformationsPage()
    {
        ViewModel = App.Current.Services.GetRequiredService<TransformationsViewModel>();
        _t = App.Current.Services.GetRequiredService<ILocalizedStrings>();
        InitializeComponent();
        HeaderTitle.Text = _t.Get("aiToolsSectionTitle");
        HistoryBtn.Content = _t.Get("aiToolsHistoryButton");
        EditBtn.Content = _t.Get("transformationEditButton");
        PickerLabel.Text = _t.Get("transformationPickerLabel");
        PreviewBtn.Content = _t.Get("aiToolsPreviewButton");
        ScopeAll.Content = _t.Get("aiToolsScopeAllSources");
        ScopeHint.Text = _t.Get("aiToolsScopeHint");
        SourceCombo.Header = _t.Get("transformationSourcePickerLabel");
        RunBtn.Content = _t.Get("transformationRunButton");
        ViewModel.PropertyChanged += OnVmChanged;
        SyncScopeSegment();
        RenderContent();
    }

    public async void Load(long notebookId)
    {
        await ViewModel.LoadAsync(notebookId);
        SyncScopeSegment();
        RenderContent();
    }

    private void OnVmChanged(object? s, System.ComponentModel.PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(TransformationsViewModel.Scope): SyncScopeSegment(); break;
            case nameof(TransformationsViewModel.ErrorMessage):
                ErrorText.Text = ViewModel.ErrorMessage ?? ""; break;
            case nameof(TransformationsViewModel.Running):
            case nameof(TransformationsViewModel.ResultNoteId):
            case nameof(TransformationsViewModel.BatchSavedCount):
            case nameof(TransformationsViewModel.ResultBody):
            case nameof(TransformationsViewModel.BatchCompleted):
                RenderContent(); break;
        }
    }

    private void SyncScopeSegment()
    {
        ScopeSeg.SelectedIndex = ViewModel.Scope switch
        {
            BatchScope.Source => 0, BatchScope.Notebook => 1, BatchScope.AllSources => 2, _ => 0
        };
        SourceCombo.Visibility = ViewModel.Scope == BatchScope.Source ? Visibility.Visible : Visibility.Collapsed;
    }

    private void OnScopeChanged(object sender, SelectionChangedEventArgs e)
    {
        ViewModel.Scope = ScopeSeg.SelectedIndex switch
        {
            1 => BatchScope.Notebook, 2 => BatchScope.AllSources, _ => BatchScope.Source
        };
        SourceCombo.Visibility = ViewModel.Scope == BatchScope.Source ? Visibility.Visible : Visibility.Collapsed;
    }

    // Build the four content states (running / single-saved / batch-toast / empty explainer).
    private void RenderContent()
    {
        ContentHost.Children.Clear();
        if (ViewModel.Running) ContentHost.Children.Add(BuildRunning());
        else if (ViewModel.BatchSavedCount is > 1) ContentHost.Children.Add(BuildBatchToast());
        else if (ViewModel.ResultNoteId is not null) ContentHost.Children.Add(BuildSingleSaved());
        else ContentHost.Children.Add(BuildEmpty());
    }

    private UIElement BuildRunning()
    {
        var panel = new StackPanel { Spacing = 10 };
        if (ViewModel.BatchTotal > 0)
            panel.Children.Add(new ProgressBar { Minimum = 0, Maximum = ViewModel.BatchTotal, Value = ViewModel.BatchCompleted });
        else
            panel.Children.Add(new ProgressRing { IsActive = true });
        panel.Children.Add(new TextBlock { Text = ViewModel.BatchTotal > 0 ? ViewModel.RunningFormat() : _t.Get("transformationRunningStatus") });
        if (!string.IsNullOrEmpty(ViewModel.ResultBody))
            panel.Children.Add(new ScrollViewer { Content = new TextBlock { Text = ViewModel.ResultBody, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } });
        return panel;
    }

    private UIElement BuildSingleSaved()
    {
        var panel = new StackPanel { Spacing = 10 };
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon { Glyph = "\uE73E", Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green) });
        row.Children.Add(new TextBlock { Text = ViewModel.ResultSavedTitle(), VerticalAlignment = VerticalAlignment.Center });
        var open = new Button { Content = _t.Get("aiToolsOpenNoteButton"), Style = (Style)Resources["AccentButtonStyle"], Command = ViewModel.OpenResultNoteCommand };
        row.Children.Add(open);
        panel.Children.Add(row);
        panel.Children.Add(new TextBlock { Text = _t.Get("transformationResultTitle"), Style = (Style)Resources["BodyStrongTextBlockStyle"] });
        panel.Children.Add(new ScrollViewer { Content = new TextBlock { Text = ViewModel.ResultBody, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } });
        return panel;
    }

    private UIElement BuildBatchToast()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        row.Children.Add(new FontIcon { Glyph = "\uE73E", Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Green) });
        row.Children.Add(new TextBlock { Text = ViewModel.BatchSavedFormat(), Style = (Style)Resources["BodyStrongTextBlockStyle"], VerticalAlignment = VerticalAlignment.Center });
        row.Children.Add(new Button { Content = _t.Get("aiToolsOpenNoteButton"), Style = (Style)Resources["AccentButtonStyle"], Command = ViewModel.OpenResultNoteCommand });
        return row;
    }

    private UIElement BuildEmpty()
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        row.Children.Add(new FontIcon { Glyph = "\uE945", FontSize = 28 });
        var col = new StackPanel { Spacing = 6 };
        col.Children.Add(new TextBlock { Text = _t.Get("aiToolsEmptyTitle"), Style = (Style)Resources["BodyStrongTextBlockStyle"] });
        col.Children.Add(new TextBlock { Text = _t.Get("aiToolsEmptyBody"), Foreground = (Microsoft.UI.Xaml.Media.Brush)Resources["TextFillColorSecondaryBrush"], TextWrapping = TextWrapping.Wrap });
        row.Children.Add(col);
        return row;
    }

    private async void OnHistory(object s, RoutedEventArgs e)
    {
        var dlg = new TransformationHistoryDialog(ViewModel.NotebookIdForHistory) { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
    }
    private async void OnEdit(object s, RoutedEventArgs e)
    {
        var dlg = new TransformationEditorDialog() { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
        await ViewModel.ReloadAsync();   // mirror sheet onDismiss reload
        RenderContent();
    }
    private async void OnPreview(object s, RoutedEventArgs e)
    {
        if (ViewModel.SelectedTransformation is not { } tx) return;
        var src = ViewModel.Scope == BatchScope.Source ? ViewModel.SelectedSource : null;
        var dlg = new TransformationPromptPreviewDialog(tx, src) { XamlRoot = XamlRoot };
        await dlg.ShowAsync();
    }
}
```

> Expose `NotebookIdForHistory` (a public getter on the VM returning `_notebookId`) so the page can pass it to the history dialog. The "open note" batch toast only shows when `BatchSavedCount > 1` (mirrors the mac `savedCount > 1`); a single saved note from a batch falls through to the single-saved section.

3. `TransformationEditorViewModel.cs` + `TransformationEditorDialog` — mirrors `TransformationEditorSheet`: a list of **non-builtin** transformations (`Transformations().Where(t => !t.IsBuiltin)`), New (`createTransformation("Untitled","{{source_text}}",Source,false)`), per-item draft editing (name `transformationEditorNamePlaceholder`, description `aiToolsDescriptionPlaceholder`, scope segmented Source/Notebook, template `TextBox` multiline with placeholder `transformationEditorTemplatePlaceholder`), Save (`updateTransformation` + `updateTransformationScope`), Delete. Title `transformationEditorTitle`; New button `transformationEditorNew`; close `cancelButton`. The VM:

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AINotebook.App.ViewModels;

public partial class TransformationEditorViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly ILocalizedStrings _t;
    public event Action? Changed;   // host reloads the parent list

    public ObservableCollection<Transformation> Customs { get; } = new();
    [ObservableProperty] public partial Transformation? Selected { get; set; }
    [ObservableProperty] public partial string DraftName { get; set; } = "";
    [ObservableProperty] public partial string DraftDescription { get; set; } = "";
    [ObservableProperty] public partial string DraftTemplate { get; set; } = "";
    [ObservableProperty] public partial TransformationScope DraftScope { get; set; } = TransformationScope.Source;
    [ObservableProperty] public partial string? ErrorMessage { get; set; }

    public TransformationEditorViewModel(NotebookStore store, ILocalizedStrings t) { _store = store; _t = t; }

    public void Reload()
    {
        try
        {
            var prev = Selected?.Id;
            Customs.Clear();
            foreach (var tx in _store.Transformations().Where(x => !x.IsBuiltin)) Customs.Add(tx);
            Selected = Customs.FirstOrDefault(x => x.Id == prev) ?? Customs.FirstOrDefault();
            SyncDraft();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    partial void OnSelectedChanged(Transformation? v) => SyncDraft();

    private void SyncDraft()
    {
        DraftName = Selected?.Name ?? "";
        DraftTemplate = Selected?.PromptTemplate ?? "";
        DraftScope = Selected?.Scope ?? TransformationScope.Source;
        DraftDescription = Selected?.Description ?? "";
    }

    [RelayCommand]
    private void CreateBlank()
    {
        try
        {
            var tx = _store.CreateTransformation("Untitled", "{{source_text}}", TransformationScope.Source, false);
            Reload();
            Selected = Customs.FirstOrDefault(x => x.Id == tx.Id);
            Changed?.Invoke();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private void Save()
    {
        if (Selected?.Id is not { } id) return;
        try
        {
            _store.UpdateTransformation(id, DraftName, DraftTemplate, DraftDescription);
            _store.UpdateTransformationScope(id, DraftScope);
            Reload();
            Changed?.Invoke();
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    [RelayCommand]
    private void Delete()
    {
        if (Selected?.Id is not { } id) return;
        try { _store.DeleteTransformation(id); Selected = null; Reload(); Changed?.Invoke(); }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }
}
```

The `TransformationEditorDialog.xaml` is a `ContentDialog` with a two-column body (list + draft editor); the template `TextBox` is multiline (`AcceptsReturn="True"`), monospaced, with a placeholder. `Save` has a Ctrl+S accelerator. The dialog ctor resolves the VM, calls `Reload()`, and wires `Changed` to nothing (parent reloads on dismiss).

4. `TransformationHistoryViewModel.cs` + `TransformationHistoryDialog` — mirrors `TransformationHistorySheet`: build rows by joining `TransformationRuns()` with `Transformations()`, `Notes(notebookId)`, and `SourcesIncludingShadow(notebookId)`, filtering to runs whose note or source belongs to the notebook, newest-first. A row click jumps to the note (switch tab + 50ms + jump); rows with no note are disabled and labeled `(deleted)`. Title `aiToolsHistoryTitle`; empty `aiToolsHistoryEmpty`; close `cancelButton`:

```csharp
using System;
using System.Collections.ObjectModel;
using System.Linq;
using AINotebook.App.Services;
using AINotebook.Core.Models;
using AINotebook.Core.Storage;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.ViewModels;

public sealed record TransformationRunRow(
    long Id, string TemplateName, string SourceTitle, long? NoteId, string NoteTitle, DateTime RanAt)
{
    public bool HasNote => NoteId is not null;
}

public partial class TransformationHistoryViewModel : ObservableObject
{
    private readonly NotebookStore _store;
    private readonly NoteJumpCoordinator _noteJump;
    private readonly TabSwitchCoordinator _tabSwitch;
    private long _notebookId;

    public ObservableCollection<TransformationRunRow> Rows { get; } = new();
    [ObservableProperty] public partial string? ErrorMessage { get; set; }
    public event Action? RequestClose;

    public TransformationHistoryViewModel(NotebookStore store, NoteJumpCoordinator noteJump, TabSwitchCoordinator tabSwitch)
    { _store = store; _noteJump = noteJump; _tabSwitch = tabSwitch; }

    public void Load(long notebookId)
    {
        _notebookId = notebookId;
        try
        {
            var runs = _store.TransformationRuns();
            var txById = _store.Transformations().Where(t => t.Id is not null).ToDictionary(t => t.Id!.Value);
            var notesById = _store.Notes(notebookId).Where(n => n.Id is not null).ToDictionary(n => n.Id!.Value);
            var srcById = _store.SourcesIncludingShadow(notebookId).Where(s => s.Id is not null).ToDictionary(s => s.Id!.Value);

            Rows.Clear();
            foreach (var run in runs)
            {
                if (run.Id is not { } runId) continue;
                Note? note = run.ResultNoteId is { } rid && notesById.TryGetValue(rid, out var nn) ? nn : null;
                Source? src = run.SourceId is { } sid && srcById.TryGetValue(sid, out var ss) ? ss : null;
                var belongs = note?.NotebookId == notebookId || src?.NotebookId == notebookId;
                if (!belongs) continue;
                var txName = txById.TryGetValue(run.TransformationId, out var tx) ? tx.Name : "(unknown)";
                var srcTitle = src?.Title ?? (run.SourceId is null ? "(notebook scope)" : "(deleted)");
                Rows.Add(new TransformationRunRow(runId, txName, srcTitle, note?.Id, note?.Title ?? "(deleted)", run.RanAt));
            }
            foreach (var r in Rows.OrderByDescending(r => r.RanAt).ToList())
            { Rows.Remove(r); Rows.Add(r); }   // stable newest-first
        }
        catch (Exception ex) { ErrorMessage = ex.ToString(); }
    }

    public async System.Threading.Tasks.Task JumpAsync(TransformationRunRow row)
    {
        if (row.NoteId is not { } nid) return;
        RequestClose?.Invoke();
        _tabSwitch.Request(TabSwitchCoordinator.Tab.Notes);
        await System.Threading.Tasks.Task.Delay(50);
        _noteJump.Request(nid);
    }
}
```

The `TransformationHistoryDialog` is a `ContentDialog` with a `ListView` of rows (template name, source title, ranAt; chevron or `(deleted)`); clicking a row calls `ViewModel.JumpAsync(row)`. Rows with `HasNote == false` are disabled.

5. `TransformationPromptPreviewDialog` — mirrors `TransformationPromptPreviewSheet`: render `promptTemplate` with `{{source_text}}` substituted from the selected source's joined chunk text (when scope=Source and a source is selected), else the raw template. Title `aiToolsPromptPreviewTitle`; close `cancelButton`. The substitution logic (no VM needed; do it in the dialog ctor or a tiny VM):

```csharp
// In the dialog: render = source is null
//   ? transformation.PromptTemplate
//   : transformation.PromptTemplate.Replace("{{source_text}}",
//       string.Join("\n\n", store.Chunks(source.Id!.Value).Select(c => c.Text)));
```

6. Register VMs: `services.AddTransient<TransformationEditorViewModel>(); services.AddTransient<TransformationHistoryViewModel>();`.

7. Commit:

```
git add windows/src/AINotebook.App/Views/TransformationsPage.xaml windows/src/AINotebook.App/Views/TransformationsPage.xaml.cs windows/src/AINotebook.App/ViewModels/TransformationEditorViewModel.cs windows/src/AINotebook.App/ViewModels/TransformationHistoryViewModel.cs windows/src/AINotebook.App/Dialogs/TransformationEditorDialog.xaml windows/src/AINotebook.App/Dialogs/TransformationEditorDialog.xaml.cs windows/src/AINotebook.App/Dialogs/TransformationHistoryDialog.xaml windows/src/AINotebook.App/Dialogs/TransformationHistoryDialog.xaml.cs windows/src/AINotebook.App/Dialogs/TransformationPromptPreviewDialog.xaml windows/src/AINotebook.App/Dialogs/TransformationPromptPreviewDialog.xaml.cs
git commit -m "feat(app): Transformations tab — run/preview/history/editor (M8.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine and manually verify: the Transformations tab lists built-in templates; selecting a notebook-scoped template flips the scope segment to Notebook; running a Source-scoped template streams tokens and then shows the single-saved section with "Open note" (which switches to Notes and selects the new note); running All Sources shows a determinate progress bar `done/total` and ends with a batch toast (when >1); Preview shows `{{source_text}}` substituted for the selected source; Edit dialog creates/edits/deletes a custom template (built-ins are excluded); History lists runs newest-first and a row click opens the resulting note.

---

## Milestone M10 — Final integration

Wires app-level keyboard accelerators and the menu equivalents, and provides the end-to-end smoke checklist. Plan 3 owns packaging (Inno Setup / self-contained publish) — out of scope here.

## Task M10.1 — App-level KeyboardAccelerators + menu equivalents

**Files:**
- Modify `windows/src/AINotebook.App/MainWindow.xaml`
- Modify `windows/src/AINotebook.App/MainWindow.xaml.cs`

**Steps:**

1. The editor already owns Ctrl+S (save) and Ctrl+Shift+H (history) as element-scoped `KeyboardAccelerator`s (M6.1), and Chat/Transformations own Ctrl+Enter. The mac app's `.commands` menu exposed these globally; in WinUI a single `MainWindow` routes them when the relevant tab is active. Add window-level accelerators that forward to the active tab's page so the shortcuts work even when focus is outside the editor, mirroring the mac global commands. In `MainWindow.xaml`, add a `MenuBar` (the `.commands` equivalent) with a "Note" menu (Save = Ctrl+S, History = Ctrl+Shift+H) and a "Chat" menu (Send = Ctrl+Enter), each item enabled only when its tab is active:

```xml
<MenuBar x:Name="AppMenuBar">
    <MenuBarItem x:Name="NoteMenu">
        <MenuFlyoutItem x:Name="MenuSave" Click="OnMenuSave">
            <MenuFlyoutItem.KeyboardAccelerators>
                <KeyboardAccelerator Modifiers="Control" Key="S"/>
            </MenuFlyoutItem.KeyboardAccelerators>
        </MenuFlyoutItem>
        <MenuFlyoutItem x:Name="MenuHistory" Click="OnMenuHistory">
            <MenuFlyoutItem.KeyboardAccelerators>
                <KeyboardAccelerator Modifiers="Control,Shift" Key="H"/>
            </MenuFlyoutItem.KeyboardAccelerators>
        </MenuFlyoutItem>
    </MenuBarItem>
</MenuBar>
```

2. In `MainWindow.xaml.cs`, route the menu/accelerator actions to the active tab's page (the shell already tracks the selected `TabView` tab from Plan 1). Localize the menu labels (reuse `historyButton`; "Save" is literal as in the mac app). Guard each action to no-op unless the Notes tab is active and a note is selected:

```csharp
private void OnMenuSave(object sender, RoutedEventArgs e)
{
    if (CurrentPage is NotesPage notes) notes.TriggerManualSave();   // calls Editor.FlushPendingSave()
}
private void OnMenuHistory(object sender, RoutedEventArgs e)
{
    if (CurrentPage is NotesPage notes) notes.TriggerHistory();      // calls ViewModel.ShowHistoryCommand
}
```

> Add `public void TriggerManualSave()` and `public void TriggerHistory()` to `NotesPage` (forwarding to `Editor.FlushPendingSave()` and `ViewModel.ShowHistoryCommand.Execute(null)`). Because the editor's own accelerators already cover focus-in-editor, these window-level ones cover focus-elsewhere. `CurrentPage` is the page currently hosted by the active `TabView` tab (Plan 1's shell exposes it; if not, add a small accessor). Keep this minimal — YAGNI: no new menus beyond Note (Save/History); Chat/Transformations send already works via in-page Ctrl+Enter.

3. Commit:

```
git add windows/src/AINotebook.App/MainWindow.xaml windows/src/AINotebook.App/MainWindow.xaml.cs
git commit -m "feat(app): app-level Ctrl+S / Ctrl+Shift+H accelerators + Note menu (M10.1)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** Build on a Windows machine and manually verify: with the Notes tab active and focus in the notes list (not the editor), Ctrl+S still saves the open note and Ctrl+Shift+H opens history; the Note menu items mirror these; the shortcuts are inert on other tabs.

## Task M10.2 — End-to-end smoke checklist

**Files:**
- Create `windows/docs/smoke-checklist.md`

**Steps:**

1. Create `windows/docs/smoke-checklist.md` documenting the fresh-Windows end-to-end manual smoke test that exercises every milestone in this plan (chat/notes/editor/transformations) plus the onboarding and localization hooks owned by Plans 1/3. This is documentation, not code; it is the acceptance gate for a Windows build:

```markdown
# AI Notebook (Windows) — end-to-end smoke checklist

Run on a clean Windows 10/11 x64 machine with the self-contained unpackaged build.

## Onboarding (Plan 1)
1. Launch the app first-run -> Welcome step shows.
2. Without Ollama running: DetectOllama keeps polling; "Open download" opens https://ollama.com/download.
3. Install + start Ollama; DetectOllama advances to PickModels within ~2s.
4. PickModels: defaults llama3.2:3b + nomic-embed-text preselected. Continue.
5. PullModels: two determinate progress bars fill to 100% (chat then embedding); reaching done marks
   hasCompletedOnboarding (subsequent launches skip onboarding).

## Notebook + sources (Plan 1/Writer B)
6. Create a notebook.
7. Add a PDF source (FileOpenPicker), a URL source, and a DOCX source. Each shows ingest status -> ready.

## Chat with citations (M5)
8. Open the Chat tab -> a session auto-creates; empty-state string shows.
9. Ask a question grounded in the PDF/URL; tokens stream into the streaming bubble; the final
   assistant message shows [N] citation chips.
10. Click a chip -> Flyout shows the source title + snippet; for the PDF citation "Open page N"
    opens the PDF; "Save as note" creates a note.

## Notes + WebView2 editor (M6 + M7)
11. Open the Notes tab -> 3-column layout fills the window.
12. New note -> the TipTap editor loads (proves editor.js shim + asset copy).
13. Type text; status flips unsaved -> saved after the debounce; Ctrl+S flushes immediately.
14. Paste an image -> it uploads via attachment:// and renders.
15. Switch to another note with unsaved changes -> unsaved-changes ContentDialog
    (Save flushes+switches / Discard switches / Cancel stays).
16. Ctrl+Shift+H -> history dialog; Restore an earlier version -> body reverts.
17. Right chat panel: ask a question -> answer uses the open note as context.

## Transformations (M8)
18. Open the Transformations tab -> built-in templates listed.
19. Run a Source-scoped template -> tokens stream, single-saved section + "Open note"
    (switches to Notes and selects the new note).
20. Run "All sources" -> determinate progress done/total -> batch toast.
21. Preview shows {{source_text}} substituted; Edit dialog creates/edits/deletes a custom template;
    History lists runs newest-first and a row opens its note.

## Localization (Plan 1)
22. Settings -> switch language to Czech -> UI strings (chat/notes/transformations labels,
    dialog buttons) re-render in Czech via PrimaryLanguageOverride.

## App shortcuts (M10)
23. With the Notes tab active and focus outside the editor, Ctrl+S saves and Ctrl+Shift+H opens history.
```

2. Commit:

```
git add windows/docs/smoke-checklist.md
git commit -m "docs(app): end-to-end Windows smoke checklist (M10.2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

**Verify:** A Windows tester runs the checklist top-to-bottom on a fresh machine; every numbered step passes. Packaging/installer is delivered by Plan 3.
