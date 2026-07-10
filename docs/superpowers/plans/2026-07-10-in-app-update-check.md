# In-App Update Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Check GitHub Releases once per launch (and on demand) and show a dismissible "new version available" banner + Settings controls on both platforms — check + notify only, no download automation.

**Architecture:** Three layers per platform, per the approved spec: (1) pure release-picking logic in each Core (offline, unit-tested — pick the highest-semver non-prerelease release that carries this platform's installer asset); (2) a fetch layer (macOS: App-layer `UpdateService` with URLSession, because Core's grep gate confines networking; Windows: Core `UpdateChecker` with HttpClient, OllamaClient pattern); (3) UI — a top banner in the main content (macOS `ContentView`, Windows `ShellPage` InfoBar) plus Settings rows (auto-check toggle, current version, check-now with status). Prerequisite inside this plan: the in-code version constants are stale (`0.7.3` vs repo `VERSION` `0.9.2`) — bump them and convert both guard tests to read the repo-root `VERSION` file so drift fails CI forever after.

**Tech Stack:** Swift 6/SwiftUI + XCTest (all local), C# net10.0 Core + xUnit (local) / net10.0-windows App (CI-only), GitHub REST `GET /repos/lukoplt/AI-notebook/releases`.

**Spec:** `docs/superpowers/specs/2026-06-30-in-app-update-check-design.md` — with these codebase-drift corrections, which OVERRIDE the spec text where they conflict:
- Version constants bump to **`0.9.2`** (spec says 0.8.1 — stale).
- Windows settings are **file-backed JSON** (`SettingsService` → `%APPDATA%\AINotebook\settings.json`, 4-edit pattern) — NOT `ApplicationData.LocalSettings` (forbidden API in this unpackaged app).
- Windows `HttpClient` sends no default User-Agent and GitHub's API rejects UA-less requests (403) — the Windows fetcher MUST set a `User-Agent: AINotebook` header. macOS URLSession sends a default UA; nothing needed.

## Global Constraints

- macOS: everything builds/tests locally (`swift build`, `swift test --filter <Name>`). Windows: Core + Core.Tests are net10.0 → local (`dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`); App/App.Tests are net10.0-windows → CI-only (verify signatures by reading source; never fabricate output — reports are checked).
- TDD with REAL observed RED/GREEN for every Core change.
- Asset suffixes exactly: macOS `-macos.dmg`, Windows `-windows-setup.exe`. Tag prefixes stripped: `win-v` first, then `v`. Only `prerelease == false` releases count. Highest semver wins; strictly-greater than current ⇒ update available.
- Endpoint exactly: `https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30`, header `Accept: application/vnd.github+json`, ~5s timeout. JSON fields used: `tag_name`, `prerelease`, `html_url`, `assets[].name`, `assets[].browser_download_url`.
- Auto-check: on launch, only when the toggle is on AND ≥24h since last check AND onboarding is complete; failures silent. Manual check ignores the throttle; failures show "Couldn't check for updates." Banner dismiss = session-only ("Later").
- New settings keys — macOS `AppSettings` (UserDefaults): `autoCheckUpdates: Bool = true`, `lastUpdateCheck: Date?`. Windows `ISettingsService`/`SettingsService` (JSON file): `AutoCheckUpdates: bool = true`, `LastUpdateCheckUtc: DateTimeOffset?`.
- macOS Core CI grep gate: NO occurrence of the string `URLSession` in `Sources/AINotebookCore/` outside `OllamaClient.swift`, `WebExtractor.swift`, `Providers/` — the new `UpdateCheck.swift` is pure and must not mention it; the fetch lives in `Sources/AINotebookApp/UpdateService.swift`.
- Localization: every new UI string in BOTH languages — macOS `AppText.Key` + exhaustive `english(_:)`/`czech(_:)` switches; Windows both `Resources.resw` files + `StringKey` (resw parity test counts keys — update it if it pins a count).
- No new SPM/NuGet packages (locked-mode CI on Windows).
- Commits: conventional prefixes + trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. Branch `feat/update-check` from `main`.

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/lukasoplt/Documents/AI_Notebook
git checkout main && git pull
git checkout -b feat/update-check main
```

---

### Task 1: macOS version constant — bump to 0.9.2 + VERSION-file guard test

**Files:**
- Modify: `Sources/AINotebookCore/AINotebookVersion.swift`
- Modify: `Tests/AINotebookCoreTests/AINotebookVersionTests.swift`

**Interfaces:**
- Consumes: repo-root `VERSION` file (currently `0.9.2` + newline).
- Produces: `AINotebookVersion == "0.9.2"` (top-level `public let`, unchanged shape — Settings row and Task 6's `UpdateService` read it). Guard test locates the repo root by walking up from `#filePath` (no such pattern exists yet in this test suite — this introduces it; fixture tests use `Bundle.module`, which cannot see repo-root files).

- [ ] **Step 1: Replace the literal-pinned test with a VERSION-file guard**

Replace the body of `Tests/AINotebookCoreTests/AINotebookVersionTests.swift` with:

```swift
import XCTest
@testable import AINotebookCore

final class AINotebookVersionTests: XCTestCase {

    /// Repo root = three levels up from this file
    /// (Tests/AINotebookCoreTests/AINotebookVersionTests.swift).
    private func repoRootVersion() throws -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // AINotebookCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let versionURL = repoRoot.appendingPathComponent("VERSION")
        let raw = try String(contentsOf: versionURL, encoding: .utf8)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The in-code constant must always match the repo-root VERSION file —
    /// this is what makes a release bump that forgets the constant fail CI.
    func testVersionMatchesRepoVersionFile() throws {
        XCTAssertEqual(AINotebookVersion, try repoRootVersion())
    }

    func testVersionIsSemverShape() {
        let parts = AINotebookVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "Version must have three dot-separated parts")
        for part in parts {
            XCTAssertNotNil(Int(part), "Each part of version must be an integer")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AINotebookVersionTests`
Expected: FAIL — `XCTAssertEqual failed: ("0.7.3") is not equal to ("0.9.2")`.

- [ ] **Step 3: Bump the constant**

`Sources/AINotebookCore/AINotebookVersion.swift`:

```swift
// Non-isolated top-level constant so it can be read from any actor context.
// Must equal the repo-root VERSION file — AINotebookVersionTests enforces it.
// Surfaced in Settings and used by the update checker.
public let AINotebookVersion = "0.9.2"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AINotebookVersionTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/AINotebookCore/AINotebookVersion.swift Tests/AINotebookCoreTests/AINotebookVersionTests.swift
git commit -m "fix(mac): version constant 0.7.3 -> 0.9.2, guard test reads repo VERSION file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Windows version constant — bump to 0.9.2 + VERSION-file guard test

**Files:**
- Modify: `windows/src/AINotebook.Core/AINotebookVersion.cs`
- Modify: `windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs`
- Modify: `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj` (copy `VERSION` into test output — mirrors the existing Fixtures `<None Include=...CopyToOutputDirectory>` block)

**Interfaces:**
- Consumes: repo-root `VERSION` file.
- Produces: `AINotebookVersion.Current == "0.9.2"` (Windows Settings + Task 4/5 read it). Test reads `Path.Combine(AppContext.BaseDirectory, "VERSION")` (build-output copy — same resolution style as fixture tests).

- [ ] **Step 1: Add the VERSION copy item**

In `windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`, next to the existing Fixtures `ItemGroup` (read it first and mirror the shape):

```xml
  <ItemGroup>
    <None Include="..\..\..\VERSION">
      <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
      <Link>VERSION</Link>
    </None>
  </ItemGroup>
```

- [ ] **Step 2: Replace the literal-pinned test**

`windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs`:

```csharp
using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class AINotebookVersionTests
{
    private static string RepoVersion()
        => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "VERSION")).Trim();

    /// The in-code constant must always match the repo-root VERSION file —
    /// a release bump that forgets the constant fails CI here.
    [Fact]
    public void VersionMatchesRepoVersionFile()
        => Assert.Equal(RepoVersion(), AINotebookVersion.Current);

    [Fact]
    public void VersionIsSemverShape()
    {
        var parts = AINotebookVersion.Current.Split('.');
        Assert.Equal(3, parts.Length);
        Assert.All(parts, p => Assert.True(int.TryParse(p, out _)));
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter AINotebookVersionTests`
Expected: FAIL — `Assert.Equal() Failure ... Expected: 0.9.2 / Actual: 0.7.3`.

- [ ] **Step 4: Bump the constant**

`windows/src/AINotebook.Core/AINotebookVersion.cs`:

```csharp
namespace AINotebook.Core;

/// Must equal the repo-root VERSION file — AINotebookVersionTests reads that
/// file (copied into the test output) and enforces the match on every build.
public static class AINotebookVersion
{
    public const string Current = "0.9.2";
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter AINotebookVersionTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add windows/src/AINotebook.Core/AINotebookVersion.cs \
        windows/tests/AINotebook.Core.Tests/AINotebookVersionTests.cs \
        windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj
git commit -m "fix(win): version constant 0.7.3 -> 0.9.2, guard test reads repo VERSION file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: macOS pure release picker (`UpdateCheck.swift`)

**Files:**
- Create: `Sources/AINotebookCore/UpdateCheck.swift` (pure — the string `URLSession` must NOT appear; CI grep gate)
- Test: `Tests/AINotebookCoreTests/UpdateCheckTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces (Task 6 relies on these exact symbols):
  - `public struct UpdateReleaseAsset: Codable, Equatable, Sendable { public let name: String; public let browserDownloadUrl: String }` (CodingKeys map `browser_download_url`)
  - `public struct UpdateRelease: Codable, Equatable, Sendable { public let tagName: String; public let prerelease: Bool; public let htmlUrl: String; public let assets: [UpdateReleaseAsset] }` (CodingKeys map `tag_name`, `html_url`)
  - `public struct UpdateInfo: Equatable, Sendable { public let isUpdateAvailable: Bool; public let latestVersion: String; public let downloadURL: String; public let releaseNotesURL: String }` + `public static let none = UpdateInfo(isUpdateAvailable: false, latestVersion: "", downloadURL: "", releaseNotesURL: "")`
  - `public enum UpdateCheck { public static let macAssetSuffix = "-macos.dmg"; public static func evaluate(releases: [UpdateRelease], currentVersion: String, assetSuffix: String) -> UpdateInfo; static func semverComponents(of tag: String) -> [Int]?; static func isGreater(_ a: [Int], than b: [Int]) -> Bool }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/AINotebookCoreTests/UpdateCheckTests.swift`:

```swift
import XCTest
@testable import AINotebookCore

final class UpdateCheckTests: XCTestCase {

    private func release(
        tag: String,
        prerelease: Bool = false,
        assets: [String],
        html: String = "https://github.com/lukoplt/AI-notebook/releases/tag/x"
    ) -> UpdateRelease {
        UpdateRelease(
            tagName: tag,
            prerelease: prerelease,
            htmlUrl: html,
            assets: assets.map {
                UpdateReleaseAsset(name: $0, browserDownloadUrl: "https://dl/\($0)")
            }
        )
    }

    func testNewerReleaseAvailable() {
        let releases = [
            release(tag: "v0.9.2", assets: ["AINotebook-v0.9.2-macos.dmg", "AINotebook-v0.9.2-windows-setup.exe"]),
            release(tag: "v0.9.1", assets: ["AINotebook-v0.9.1-macos.dmg"])
        ]
        let info = UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.1", assetSuffix: UpdateCheck.macAssetSuffix)
        XCTAssertTrue(info.isUpdateAvailable)
        XCTAssertEqual(info.latestVersion, "0.9.2")
        XCTAssertEqual(info.downloadURL, "https://dl/AINotebook-v0.9.2-macos.dmg")
    }

    func testEqualVersionIsNotAnUpdate() {
        let releases = [release(tag: "v0.9.2", assets: ["A-macos.dmg"])]
        XCTAssertFalse(UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.2", assetSuffix: "-macos.dmg").isUpdateAvailable)
    }

    func testOlderLatestIsNotAnUpdate() {
        let releases = [release(tag: "v0.9.0", assets: ["A-macos.dmg"])]
        XCTAssertFalse(UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.2", assetSuffix: "-macos.dmg").isUpdateAvailable)
    }

    func testPrereleaseIsIgnored() {
        let releases = [
            release(tag: "v1.0.0", prerelease: true, assets: ["A-macos.dmg"]),
            release(tag: "v0.9.2", assets: ["B-macos.dmg"])
        ]
        let info = UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.1", assetSuffix: "-macos.dmg")
        XCTAssertTrue(info.isUpdateAvailable)
        XCTAssertEqual(info.latestVersion, "0.9.2")
    }

    func testNewestWithoutOurAssetFallsBackToNewestThatHasOne() {
        // Covers the historical win-v* Windows-only releases.
        let releases = [
            release(tag: "win-v1.0.0", assets: ["A-windows-setup.exe"]),
            release(tag: "v0.9.2", assets: ["B-macos.dmg", "B-windows-setup.exe"])
        ]
        let info = UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.0", assetSuffix: "-macos.dmg")
        XCTAssertTrue(info.isUpdateAvailable)
        XCTAssertEqual(info.latestVersion, "0.9.2")
        XCTAssertEqual(info.downloadURL, "https://dl/B-macos.dmg")
    }

    func testEmptyListMeansNoUpdate() {
        XCTAssertEqual(UpdateCheck.evaluate(releases: [], currentVersion: "0.9.2", assetSuffix: "-macos.dmg"), .none)
    }

    func testMalformedTagIsSkippedWithoutCrash() {
        let releases = [
            release(tag: "nightly-build", assets: ["A-macos.dmg"]),
            release(tag: "v0.9.3", assets: ["B-macos.dmg"])
        ]
        let info = UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.2", assetSuffix: "-macos.dmg")
        XCTAssertTrue(info.isUpdateAvailable)
        XCTAssertEqual(info.latestVersion, "0.9.3")
    }

    func testSemverCompareNotLexicographic() {
        // 0.8.10 > 0.8.9 numerically even though "10" < "9" lexicographically.
        let releases = [release(tag: "v0.8.10", assets: ["A-macos.dmg"])]
        XCTAssertTrue(UpdateCheck.evaluate(releases: releases, currentVersion: "0.8.9", assetSuffix: "-macos.dmg").isUpdateAvailable)
        XCTAssertFalse(UpdateCheck.evaluate(releases: releases, currentVersion: "0.8.10", assetSuffix: "-macos.dmg").isUpdateAvailable)
    }

    func testPrefixStripping() {
        XCTAssertEqual(UpdateCheck.semverComponents(of: "v0.9.2"), [0, 9, 2])
        XCTAssertEqual(UpdateCheck.semverComponents(of: "win-v0.8.0"), [0, 8, 0])
        XCTAssertEqual(UpdateCheck.semverComponents(of: "0.9.2"), [0, 9, 2])
        XCTAssertNil(UpdateCheck.semverComponents(of: "nightly"))
        XCTAssertNil(UpdateCheck.semverComponents(of: "v1.2"))
    }

    func testReleaseNotesURLComesFromHtmlUrl() {
        let releases = [release(tag: "v0.9.3", assets: ["A-macos.dmg"], html: "https://gh/rel/v0.9.3")]
        let info = UpdateCheck.evaluate(releases: releases, currentVersion: "0.9.2", assetSuffix: "-macos.dmg")
        XCTAssertEqual(info.releaseNotesURL, "https://gh/rel/v0.9.3")
    }

    func testGitHubJSONDecodes() throws {
        let json = """
        [
          {
            "tag_name": "v0.9.2",
            "prerelease": false,
            "html_url": "https://github.com/lukoplt/AI-notebook/releases/tag/v0.9.2",
            "assets": [
              {"name": "AINotebook-v0.9.2-macos.dmg",
               "browser_download_url": "https://github.com/lukoplt/AI-notebook/releases/download/v0.9.2/AINotebook-v0.9.2-macos.dmg"}
            ]
          }
        ]
        """
        let releases = try JSONDecoder().decode([UpdateRelease].self, from: Data(json.utf8))
        XCTAssertEqual(releases.count, 1)
        XCTAssertEqual(releases[0].tagName, "v0.9.2")
        XCTAssertEqual(releases[0].assets[0].browserDownloadUrl,
                       "https://github.com/lukoplt/AI-notebook/releases/download/v0.9.2/AINotebook-v0.9.2-macos.dmg")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter UpdateCheckTests`
Expected: FAIL — `cannot find 'UpdateCheck' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/AINotebookCore/UpdateCheck.swift`:

```swift
import Foundation

/// One GitHub release asset (decoded from the REST API shape).
public struct UpdateReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let browserDownloadUrl: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
    }

    public init(name: String, browserDownloadUrl: String) {
        self.name = name
        self.browserDownloadUrl = browserDownloadUrl
    }
}

/// One GitHub release (only the fields the update check needs).
public struct UpdateRelease: Codable, Equatable, Sendable {
    public let tagName: String
    public let prerelease: Bool
    public let htmlUrl: String
    public let assets: [UpdateReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case htmlUrl = "html_url"
        case assets
    }

    public init(tagName: String, prerelease: Bool, htmlUrl: String, assets: [UpdateReleaseAsset]) {
        self.tagName = tagName
        self.prerelease = prerelease
        self.htmlUrl = htmlUrl
        self.assets = assets
    }
}

/// Result of an update evaluation.
public struct UpdateInfo: Equatable, Sendable {
    public let isUpdateAvailable: Bool
    public let latestVersion: String
    public let downloadURL: String
    public let releaseNotesURL: String

    public init(isUpdateAvailable: Bool, latestVersion: String, downloadURL: String, releaseNotesURL: String) {
        self.isUpdateAvailable = isUpdateAvailable
        self.latestVersion = latestVersion
        self.downloadURL = downloadURL
        self.releaseNotesURL = releaseNotesURL
    }

    public static let none = UpdateInfo(
        isUpdateAvailable: false, latestVersion: "", downloadURL: "", releaseNotesURL: ""
    )
}

/// Pure release-picking logic — no networking in this file (CI grep gate).
/// The fetch layer lives in the App target (`UpdateService`).
public enum UpdateCheck {
    public static let macAssetSuffix = "-macos.dmg"

    /// Picks the highest-semver non-prerelease release that carries an asset
    /// with `assetSuffix`; available iff strictly newer than `currentVersion`.
    public static func evaluate(
        releases: [UpdateRelease],
        currentVersion: String,
        assetSuffix: String
    ) -> UpdateInfo {
        guard let current = semverComponents(of: currentVersion) else { return .none }

        var best: (version: [Int], display: String, asset: UpdateReleaseAsset, notes: String)?
        for release in releases where !release.prerelease {
            guard let version = semverComponents(of: release.tagName),
                  let asset = release.assets.first(where: { $0.name.hasSuffix(assetSuffix) })
            else { continue }
            if best == nil || isGreater(version, than: best!.version) {
                best = (version, version.map(String.init).joined(separator: "."), asset, release.htmlUrl)
            }
        }

        guard let best, isGreater(best.version, than: current) else { return .none }
        return UpdateInfo(
            isUpdateAvailable: true,
            latestVersion: best.display,
            downloadURL: best.asset.browserDownloadUrl,
            releaseNotesURL: best.notes
        )
    }

    /// "v0.9.2" / "win-v0.8.0" / "0.9.2" → [major, minor, patch]; nil otherwise.
    static func semverComponents(of tag: String) -> [Int]? {
        var s = tag
        if s.hasPrefix("win-v") { s.removeFirst("win-v".count) }
        else if s.hasPrefix("v") { s.removeFirst(1) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let n = Int(part), n >= 0 else { return nil }
            numbers.append(n)
        }
        return numbers
    }

    static func isGreater(_ a: [Int], than b: [Int]) -> Bool {
        for (x, y) in zip(a, b) {
            if x != y { return x > y }
        }
        return false
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter UpdateCheckTests`
Expected: PASS (11 tests).

- [ ] **Step 5: Verify the gate + full suite**

```bash
grep -c "URLSession" Sources/AINotebookCore/UpdateCheck.swift || echo "GATE-CLEAN"
swift test
```
Expected: `GATE-CLEAN` (grep finds nothing, exits non-zero) and all tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/AINotebookCore/UpdateCheck.swift Tests/AINotebookCoreTests/UpdateCheckTests.swift
git commit -m "feat(mac): pure update-check release picker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Windows pure release picker (`UpdateCheck.cs`)

**Files:**
- Create: `windows/src/AINotebook.Core/UpdateCheck.cs`
- Test: `windows/tests/AINotebook.Core.Tests/UpdateCheckTests.cs`

**Interfaces:**
- Consumes: nothing.
- Produces (Tasks 5/7 rely on these exact symbols):
  - `public sealed record UpdateReleaseAsset(string Name, string BrowserDownloadUrl)`
  - `public sealed record UpdateRelease(string TagName, bool Prerelease, string HtmlUrl, IReadOnlyList<UpdateReleaseAsset> Assets)`
  - `public sealed record UpdateInfo(bool IsUpdateAvailable, string LatestVersion, string DownloadUrl, string ReleaseNotesUrl)` with `public static readonly UpdateInfo None`
  - `public static class UpdateCheck { public const string WindowsAssetSuffix = "-windows-setup.exe"; public static UpdateInfo Evaluate(IReadOnlyList<UpdateRelease> releases, string currentVersion, string assetSuffix); internal static int[]? SemverComponents(string tag); internal static bool IsGreater(int[] a, int[] b); }`

- [ ] **Step 1: Write the failing tests**

Create `windows/tests/AINotebook.Core.Tests/UpdateCheckTests.cs` — mirror the Task 3 Swift cases 1:1 in xUnit (same 11 scenarios, same inputs/outcomes; write them out in full):

```csharp
using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class UpdateCheckTests
{
    private static UpdateRelease Release(
        string tag, bool prerelease = false, string[]? assets = null,
        string html = "https://github.com/lukoplt/AI-notebook/releases/tag/x")
        => new(tag, prerelease, html,
            (assets ?? []).Select(a => new UpdateReleaseAsset(a, $"https://dl/{a}")).ToList());

    [Fact]
    public void NewerReleaseAvailable()
    {
        var releases = new[]
        {
            Release("v0.9.2", assets: ["AINotebook-v0.9.2-macos.dmg", "AINotebook-v0.9.2-windows-setup.exe"]),
            Release("v0.9.1", assets: ["AINotebook-v0.9.1-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.1", UpdateCheck.WindowsAssetSuffix);
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
        Assert.Equal("https://dl/AINotebook-v0.9.2-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public void EqualVersionIsNotAnUpdate()
        => Assert.False(UpdateCheck.Evaluate([Release("v0.9.2", assets: ["A-windows-setup.exe"])], "0.9.2", "-windows-setup.exe").IsUpdateAvailable);

    [Fact]
    public void OlderLatestIsNotAnUpdate()
        => Assert.False(UpdateCheck.Evaluate([Release("v0.9.0", assets: ["A-windows-setup.exe"])], "0.9.2", "-windows-setup.exe").IsUpdateAvailable);

    [Fact]
    public void PrereleaseIsIgnored()
    {
        var releases = new[]
        {
            Release("v1.0.0", prerelease: true, assets: ["A-windows-setup.exe"]),
            Release("v0.9.2", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.1", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
    }

    [Fact]
    public void NewestWithoutOurAssetFallsBackToNewestThatHasOne()
    {
        var releases = new[]
        {
            Release("v1.0.0", assets: ["A-macos.dmg"]),
            Release("win-v0.9.2", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.0", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.2", info.LatestVersion);
        Assert.Equal("https://dl/B-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public void EmptyListMeansNoUpdate()
        => Assert.Equal(UpdateInfo.None, UpdateCheck.Evaluate([], "0.9.2", "-windows-setup.exe"));

    [Fact]
    public void MalformedTagIsSkippedWithoutCrash()
    {
        var releases = new[]
        {
            Release("nightly-build", assets: ["A-windows-setup.exe"]),
            Release("v0.9.3", assets: ["B-windows-setup.exe"])
        };
        var info = UpdateCheck.Evaluate(releases, "0.9.2", "-windows-setup.exe");
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("0.9.3", info.LatestVersion);
    }

    [Fact]
    public void SemverCompareNotLexicographic()
    {
        var releases = new[] { Release("v0.8.10", assets: ["A-windows-setup.exe"]) };
        Assert.True(UpdateCheck.Evaluate(releases, "0.8.9", "-windows-setup.exe").IsUpdateAvailable);
        Assert.False(UpdateCheck.Evaluate(releases, "0.8.10", "-windows-setup.exe").IsUpdateAvailable);
    }

    [Theory]
    [InlineData("v0.9.2", new[] { 0, 9, 2 })]
    [InlineData("win-v0.8.0", new[] { 0, 8, 0 })]
    [InlineData("0.9.2", new[] { 0, 9, 2 })]
    public void PrefixStripping(string tag, int[] expected)
        => Assert.Equal(expected, UpdateCheck.SemverComponents(tag));

    [Theory]
    [InlineData("nightly")]
    [InlineData("v1.2")]
    public void MalformedTagsYieldNull(string tag)
        => Assert.Null(UpdateCheck.SemverComponents(tag));

    [Fact]
    public void ReleaseNotesUrlComesFromHtmlUrl()
    {
        var releases = new[] { Release("v0.9.3", assets: ["A-windows-setup.exe"], html: "https://gh/rel/v0.9.3") };
        Assert.Equal("https://gh/rel/v0.9.3", UpdateCheck.Evaluate(releases, "0.9.2", "-windows-setup.exe").ReleaseNotesUrl);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter UpdateCheckTests`
Expected: FAIL — compile error, `UpdateCheck` not found.

- [ ] **Step 3: Implement**

Create `windows/src/AINotebook.Core/UpdateCheck.cs` (mirror the Task 3 Swift semantics exactly):

```csharp
namespace AINotebook.Core;

/// One GitHub release asset (REST API shape; JSON mapping lives in UpdateChecker).
public sealed record UpdateReleaseAsset(string Name, string BrowserDownloadUrl);

/// One GitHub release — only the fields the update check needs.
public sealed record UpdateRelease(
    string TagName, bool Prerelease, string HtmlUrl, IReadOnlyList<UpdateReleaseAsset> Assets);

/// Result of an update evaluation.
public sealed record UpdateInfo(
    bool IsUpdateAvailable, string LatestVersion, string DownloadUrl, string ReleaseNotesUrl)
{
    public static readonly UpdateInfo None = new(false, "", "", "");
}

/// Pure release-picking logic; the fetch layer is UpdateChecker.
public static class UpdateCheck
{
    public const string WindowsAssetSuffix = "-windows-setup.exe";

    /// Picks the highest-semver non-prerelease release carrying an asset with
    /// `assetSuffix`; available iff strictly newer than `currentVersion`.
    public static UpdateInfo Evaluate(
        IReadOnlyList<UpdateRelease> releases, string currentVersion, string assetSuffix)
    {
        var current = SemverComponents(currentVersion);
        if (current is null) return UpdateInfo.None;

        int[]? bestVersion = null;
        UpdateReleaseAsset? bestAsset = null;
        string bestNotes = "";
        foreach (var release in releases)
        {
            if (release.Prerelease) continue;
            var version = SemverComponents(release.TagName);
            if (version is null) continue;
            UpdateReleaseAsset? asset = null;
            foreach (var a in release.Assets)
            {
                if (a.Name.EndsWith(assetSuffix, StringComparison.Ordinal)) { asset = a; break; }
            }
            if (asset is null) continue;
            if (bestVersion is null || IsGreater(version, bestVersion))
            {
                bestVersion = version;
                bestAsset = asset;
                bestNotes = release.HtmlUrl;
            }
        }

        if (bestVersion is null || bestAsset is null || !IsGreater(bestVersion, current))
            return UpdateInfo.None;

        return new UpdateInfo(
            true, string.Join('.', bestVersion), bestAsset.BrowserDownloadUrl, bestNotes);
    }

    /// "v0.9.2" / "win-v0.8.0" / "0.9.2" → [major, minor, patch]; null otherwise.
    internal static int[]? SemverComponents(string tag)
    {
        var s = tag;
        if (s.StartsWith("win-v", StringComparison.Ordinal)) s = s["win-v".Length..];
        else if (s.StartsWith('v')) s = s[1..];
        var parts = s.Split('.');
        if (parts.Length != 3) return null;
        var numbers = new int[3];
        for (var i = 0; i < 3; i++)
        {
            if (!int.TryParse(parts[i], out var n) || n < 0) return null;
            numbers[i] = n;
        }
        return numbers;
    }

    internal static bool IsGreater(int[] a, int[] b)
    {
        for (var i = 0; i < Math.Min(a.Length, b.Length); i++)
        {
            if (a[i] != b[i]) return a[i] > b[i];
        }
        return false;
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter UpdateCheckTests`
Expected: PASS (14 test cases).

- [ ] **Step 5: Commit**

```bash
git add windows/src/AINotebook.Core/UpdateCheck.cs windows/tests/AINotebook.Core.Tests/UpdateCheckTests.cs
git commit -m "feat(win): pure update-check release picker

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Windows fetch layer (`UpdateChecker.cs`)

**Files:**
- Create: `windows/src/AINotebook.Core/UpdateChecker.cs`
- Test: `windows/tests/AINotebook.Core.Tests/UpdateCheckerTests.cs`

**Interfaces:**
- Consumes: `UpdateCheck.Evaluate`, `UpdateRelease`/`UpdateReleaseAsset`/`UpdateInfo` (Task 4), `AINotebookVersion.Current` (Task 2).
- Produces (Task 7 relies on): `public sealed class UpdateChecker { public UpdateChecker(HttpClient http); public Task<UpdateInfo> CheckAsync(CancellationToken ct = default); }` — THROWS on network/HTTP/parse failure (callers decide silent-vs-message); returns `UpdateInfo` otherwise. Sets `User-Agent: AINotebook` (GitHub rejects UA-less requests) and `Accept: application/vnd.github+json`; 5-second per-request timeout via linked CTS (the shared HttpClient's own timeout is 120s).

- [ ] **Step 1: Write the failing tests**

Create `windows/tests/AINotebook.Core.Tests/UpdateCheckerTests.cs` (stub-handler pattern — mirror the handler idiom used by the provider adapter tests in `Providers/OpenAiSseTests.cs`, but a plain JSON body):

```csharp
using System.Net;
using System.Text;
using AINotebook.Core;
using Xunit;

namespace AINotebook.Core.Tests;

public class UpdateCheckerTests
{
    private sealed class StubHandler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        public HttpRequestMessage? LastRequest;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            LastRequest = request;
            return Task.FromResult(new HttpResponseMessage(status)
            {
                Content = new StringContent(body, Encoding.UTF8, "application/json")
            });
        }
    }

    private sealed class ThrowingHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            => throw new HttpRequestException("connection refused");
    }

    private const string ReleasesJson = """
    [
      {
        "tag_name": "v99.0.0",
        "prerelease": false,
        "html_url": "https://github.com/lukoplt/AI-notebook/releases/tag/v99.0.0",
        "assets": [
          {"name": "AINotebook-v99.0.0-windows-setup.exe",
           "browser_download_url": "https://dl/AINotebook-v99.0.0-windows-setup.exe"},
          {"name": "AINotebook-v99.0.0-macos.dmg",
           "browser_download_url": "https://dl/AINotebook-v99.0.0-macos.dmg"}
        ]
      }
    ]
    """;

    [Fact]
    public async Task FetchesParsesAndEvaluates()
    {
        var handler = new StubHandler(HttpStatusCode.OK, ReleasesJson);
        var checker = new UpdateChecker(new HttpClient(handler));
        var info = await checker.CheckAsync();
        Assert.True(info.IsUpdateAvailable);
        Assert.Equal("99.0.0", info.LatestVersion);
        Assert.Equal("https://dl/AINotebook-v99.0.0-windows-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public async Task SendsRequiredHeadersToTheReleasesEndpoint()
    {
        var handler = new StubHandler(HttpStatusCode.OK, "[]");
        var checker = new UpdateChecker(new HttpClient(handler));
        _ = await checker.CheckAsync();
        var req = handler.LastRequest!;
        Assert.Equal("https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30",
                     req.RequestUri!.ToString());
        Assert.Contains(req.Headers.UserAgent, p => p.Product?.Name == "AINotebook");
        Assert.Contains(req.Headers.Accept, a => a.MediaType == "application/vnd.github+json");
    }

    [Fact]
    public async Task NoNewerReleaseMeansNotAvailable()
    {
        // v0.0.1 is older than any real current version.
        var json = """[{"tag_name":"v0.0.1","prerelease":false,"html_url":"https://x","assets":[{"name":"A-windows-setup.exe","browser_download_url":"https://dl/A"}]}]""";
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.OK, json)));
        Assert.False((await checker.CheckAsync()).IsUpdateAvailable);
    }

    [Fact]
    public async Task HttpErrorThrows()
    {
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.Forbidden, "")));
        await Assert.ThrowsAnyAsync<Exception>(() => checker.CheckAsync());
    }

    [Fact]
    public async Task NetworkErrorPropagates()
    {
        var checker = new UpdateChecker(new HttpClient(new ThrowingHandler()));
        await Assert.ThrowsAsync<HttpRequestException>(() => checker.CheckAsync());
    }

    [Fact]
    public async Task MalformedJsonThrows()
    {
        var checker = new UpdateChecker(new HttpClient(new StubHandler(HttpStatusCode.OK, "not-json")));
        await Assert.ThrowsAnyAsync<Exception>(() => checker.CheckAsync());
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter UpdateCheckerTests`
Expected: FAIL — `UpdateChecker` not found.

- [ ] **Step 3: Implement**

Create `windows/src/AINotebook.Core/UpdateChecker.cs`:

```csharp
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AINotebook.Core;

/// Fetches the GitHub releases list and evaluates it against the running
/// version. Throws on any failure — the auto-check path swallows, the
/// manual "Check now" path shows a localized message.
public sealed class UpdateChecker
{
    private const string ReleasesUrl =
        "https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30";
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(5);

    private readonly HttpClient _http;

    public UpdateChecker(HttpClient http) => _http = http;

    private sealed record WireAsset(
        [property: JsonPropertyName("name")] string Name,
        [property: JsonPropertyName("browser_download_url")] string BrowserDownloadUrl);

    private sealed record WireRelease(
        [property: JsonPropertyName("tag_name")] string TagName,
        [property: JsonPropertyName("prerelease")] bool Prerelease,
        [property: JsonPropertyName("html_url")] string HtmlUrl,
        [property: JsonPropertyName("assets")] IReadOnlyList<WireAsset> Assets);

    public async Task<UpdateInfo> CheckAsync(CancellationToken ct = default)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeoutCts.CancelAfter(Timeout);

        using var req = new HttpRequestMessage(HttpMethod.Get, ReleasesUrl);
        // GitHub's API rejects requests without a User-Agent (403).
        req.Headers.UserAgent.Add(new ProductInfoHeaderValue("AINotebook", AINotebookVersion.Current));
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));

        using var resp = await _http.SendAsync(req, timeoutCts.Token);
        resp.EnsureSuccessStatusCode();
        var json = await resp.Content.ReadAsStringAsync(timeoutCts.Token);
        var wire = JsonSerializer.Deserialize<List<WireRelease>>(json)
            ?? throw new JsonException("null releases payload");

        var releases = wire
            .Select(w => new UpdateRelease(
                w.TagName, w.Prerelease, w.HtmlUrl,
                w.Assets.Select(a => new UpdateReleaseAsset(a.Name, a.BrowserDownloadUrl)).ToList()))
            .ToList();

        return UpdateCheck.Evaluate(releases, AINotebookVersion.Current, UpdateCheck.WindowsAssetSuffix);
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj --filter UpdateCheckerTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Full Windows Core suite**

Run: `dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
git add windows/src/AINotebook.Core/UpdateChecker.cs windows/tests/AINotebook.Core.Tests/UpdateCheckerTests.cs
git commit -m "feat(win): GitHub releases update checker (UA header, 5s timeout)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: macOS — AppSettings keys, `UpdateService`, banner, Settings rows, localization

**Files:**
- Modify: `Sources/AINotebookCore/AppSettings.swift` (two new keys)
- Modify: `Sources/AINotebookCore/Localization.swift` (9 new keys, EN+CZ)
- Create: `Sources/AINotebookApp/UpdateService.swift`
- Create: `Sources/AINotebookApp/UpdateBanner.swift`
- Modify: `Sources/AINotebookApp/ContentView.swift` (banner above the split view + launch `.task`)
- Modify: `Sources/AINotebookApp/AINotebookApp.swift` (construct + inject `UpdateService`)
- Modify: `Sources/AINotebookApp/SettingsView.swift` (rows after the version row)
- Test: extend `Tests/AINotebookCoreTests/AppSettingsTests.swift` + `LocalizationTests.swift`

**Interfaces:**
- Consumes: `UpdateCheck`/`UpdateRelease`/`UpdateInfo` + `UpdateCheck.macAssetSuffix` (Task 3), `AINotebookVersion` (Task 1), `AppSettings` UserDefaults pattern.
- Produces: `AppSettings.autoCheckUpdates: Bool` (default true, key `"autoCheckUpdates"`), `AppSettings.lastUpdateCheck: Date?` (key `"lastUpdateCheck"`, stored as `timeIntervalSince1970` Double); `@MainActor final class UpdateService: ObservableObject` with `enum Status { case idle, checking, upToDate, available(UpdateInfo), failed }`, `@Published var status: Status`, `@Published var bannerDismissed: Bool`, `func checkNow() async`, `func autoCheckIfDue() async`, `var availableInfo: UpdateInfo?` (convenience). URLSession lives ONLY here in the App target.

- [ ] **Step 1: Write the failing AppSettings tests**

Append to `Tests/AINotebookCoreTests/AppSettingsTests.swift` (reuse its `makeSuite` helper):

```swift
    func testAutoCheckUpdatesDefaultsOnAndPersists() {
        let name = "test.updates.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertTrue(settings.autoCheckUpdates)
        settings.autoCheckUpdates = false
        let reloaded = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertFalse(reloaded.autoCheckUpdates)
    }

    func testLastUpdateCheckDefaultsNilAndPersists() {
        let name = "test.updates.last.\(UUID().uuidString)"
        let defaults = makeSuite(name)
        let settings = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertNil(settings.lastUpdateCheck)
        let stamp = Date(timeIntervalSince1970: 1_750_000_000)
        settings.lastUpdateCheck = stamp
        let reloaded = AppSettings(defaults: defaults, preferredLanguages: ["en"])
        XCTAssertEqual(reloaded.lastUpdateCheck?.timeIntervalSince1970 ?? 0,
                       stamp.timeIntervalSince1970, accuracy: 0.001)
    }
```

- [ ] **Step 2: Run to verify RED, implement AppSettings, verify GREEN**

Run: `swift test --filter AppSettingsTests` → FAIL (no member `autoCheckUpdates`).

In `Sources/AINotebookCore/AppSettings.swift` add to the private `Keys` enum:

```swift
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
```

Add the published properties (below the provider ids):

```swift
    @Published public var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }

    /// Stored as a unix timestamp; nil until the first successful check.
    @Published public var lastUpdateCheck: Date? {
        didSet {
            if let lastUpdateCheck {
                defaults.set(lastUpdateCheck.timeIntervalSince1970, forKey: Keys.lastUpdateCheck)
            } else {
                defaults.removeObject(forKey: Keys.lastUpdateCheck)
            }
        }
    }
```

Initialize in `init` (after the provider ids; note `bool(forKey:)` returns false for missing keys — use `object(forKey:)` to honor the true default):

```swift
        if defaults.object(forKey: Keys.autoCheckUpdates) == nil {
            self.autoCheckUpdates = true
        } else {
            self.autoCheckUpdates = defaults.bool(forKey: Keys.autoCheckUpdates)
        }
        if let stamp = defaults.object(forKey: Keys.lastUpdateCheck) as? Double {
            self.lastUpdateCheck = Date(timeIntervalSince1970: stamp)
        } else {
            self.lastUpdateCheck = nil
        }
```

Run: `swift test --filter AppSettingsTests` → PASS.

- [ ] **Step 3: Localization keys (RED via extended bilingual test, then GREEN)**

Append to the bilingual provider test block in `Tests/AINotebookCoreTests/LocalizationTests.swift`:

```swift
    func testUpdateKeysAreBilingual() {
        let en = AppText(language: .english)
        let cs = AppText(language: .czech)
        XCTAssertEqual(en.string(.updateBannerTitle), "A new version (%@) is available.")
        XCTAssertEqual(cs.string(.updateBannerTitle), "Je k dispozici nová verze (%@).")
        XCTAssertEqual(en.string(.updateDownloadButton), "Download")
        XCTAssertEqual(cs.string(.updateDownloadButton), "Stáhnout")
        XCTAssertEqual(en.string(.updateLaterButton), "Later")
        XCTAssertEqual(cs.string(.updateLaterButton), "Později")
        XCTAssertEqual(en.string(.updateStatusFailed), "Couldn't check for updates.")
        XCTAssertEqual(cs.string(.updateStatusFailed), "Kontrola aktualizací se nezdařila.")
    }
```

Add to `Sources/AINotebookCore/Localization.swift` — `enum Key` cases (after the provider block):

```swift
        case updateBannerTitle
        case updateDownloadButton
        case updateLaterButton
        case updateAutoCheckToggle
        case updateCheckNowButton
        case updateStatusChecking
        case updateStatusUpToDate
        case updateStatusAvailable
        case updateStatusFailed
```

`english(_:)` rows:

```swift
        case .updateBannerTitle:      "A new version (%@) is available."
        case .updateDownloadButton:   "Download"
        case .updateLaterButton:      "Later"
        case .updateAutoCheckToggle:  "Automatically check for updates"
        case .updateCheckNowButton:   "Check for updates now"
        case .updateStatusChecking:   "Checking…"
        case .updateStatusUpToDate:   "You're up to date"
        case .updateStatusAvailable:  "Update available (%@)"
        case .updateStatusFailed:     "Couldn't check for updates."
```

`czech(_:)` rows:

```swift
        case .updateBannerTitle:      "Je k dispozici nová verze (%@)."
        case .updateDownloadButton:   "Stáhnout"
        case .updateLaterButton:      "Později"
        case .updateAutoCheckToggle:  "Automaticky kontrolovat aktualizace"
        case .updateCheckNowButton:   "Zkontrolovat aktualizace"
        case .updateStatusChecking:   "Kontroluji…"
        case .updateStatusUpToDate:   "Máte aktuální verzi"
        case .updateStatusAvailable:  "Dostupná aktualizace (%@)"
        case .updateStatusFailed:     "Kontrola aktualizací se nezdařila."
```

Run: `swift test --filter LocalizationTests` → PASS.

- [ ] **Step 4: Create `UpdateService`**

Create `Sources/AINotebookApp/UpdateService.swift`:

```swift
import Foundation
import AINotebookCore

/// Fetches GitHub releases and evaluates them against the running version.
/// Owns all update-check networking for the mac app (Core stays offline).
@MainActor
final class UpdateService: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case failed
    }

    @Published var status: Status = .idle
    @Published var bannerDismissed = false

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let settings: AppSettings
    private let session: URLSession

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    var availableInfo: UpdateInfo? {
        if case .available(let info) = status { return info }
        return nil
    }

    /// Launch-time check: toggle on, ≥24h since last, silent on failure.
    func autoCheckIfDue() async {
        guard settings.autoCheckUpdates else { return }
        if let last = settings.lastUpdateCheck,
           Date().timeIntervalSince(last) < Self.checkInterval { return }
        await performCheck(silent: true)
    }

    /// Manual check: ignores the throttle; failures surface as .failed.
    func checkNow() async {
        await performCheck(silent: false)
    }

    private func performCheck(silent: Bool) async {
        status = .checking
        do {
            var request = URLRequest(url: Self.releasesURL)
            request.timeoutInterval = 5
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let releases = try JSONDecoder().decode([UpdateRelease].self, from: data)
            let info = UpdateCheck.evaluate(
                releases: releases,
                currentVersion: AINotebookVersion,
                assetSuffix: UpdateCheck.macAssetSuffix
            )
            settings.lastUpdateCheck = Date()
            status = info.isUpdateAvailable ? .available(info) : .upToDate
        } catch {
            status = silent ? .idle : .failed
        }
    }
}
```

- [ ] **Step 5: Create the banner view**

Create `Sources/AINotebookApp/UpdateBanner.swift`:

```swift
import SwiftUI
import AINotebookCore

/// Non-modal top bar shown in the main window when an update is available.
struct UpdateBanner: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updates: UpdateService

    let info: UpdateInfo

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
            Text(String(format: settings.text.string(.updateBannerTitle), info.latestVersion))
            Spacer()
            Button(settings.text.string(.updateDownloadButton)) {
                if let url = URL(string: info.downloadURL) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Button(settings.text.string(.updateLaterButton)) {
                updates.bannerDismissed = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary)
    }
}
```

- [ ] **Step 6: Wire ContentView + composition root**

`Sources/AINotebookApp/ContentView.swift` — add `@EnvironmentObject private var updates: UpdateService`, wrap the `mainUI` branch:

```swift
        VStack(spacing: 0) {
            if let info = updates.availableInfo, !updates.bannerDismissed {
                UpdateBanner(info: info)
            }
            NavigationSplitView { ... existing content unchanged ... }
        }
        .task {
            if settings.hasCompletedOnboarding {
                await updates.autoCheckIfDue()
            }
        }
```

(Read the real file first; only the wrapping VStack, the banner `if`, and the `.task` are new — the split view body stays byte-identical. The `.task` goes on the `mainUI` branch so onboarding never triggers it; when onboarding completes the view re-renders into `mainUI` and the task runs then.)

`Sources/AINotebookApp/AINotebookApp.swift` — in `init()` after `_settings`:

```swift
    let updates = UpdateService(settings: settings)
    _updates = StateObject(wrappedValue: updates)
```

declare `@StateObject private var updates: UpdateService` with the other holders and add `.environmentObject(updates)` to the WindowGroup injection list.

- [ ] **Step 7: Settings rows**

`Sources/AINotebookApp/SettingsView.swift` — add `@EnvironmentObject private var updates: UpdateService`. Insert directly AFTER the existing version `HStack` (the one rendering `AINotebookVersion`) and before the author footer:

```swift
            Toggle(settings.text.string(.updateAutoCheckToggle), isOn: $settings.autoCheckUpdates)
            HStack {
                Button(settings.text.string(.updateCheckNowButton)) {
                    Task { await updates.checkNow() }
                }
                .disabled(updates.status == .checking)
                Text(updateStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

and a computed helper (near the other private helpers):

```swift
    private var updateStatusText: String {
        switch updates.status {
        case .idle: ""
        case .checking: settings.text.string(.updateStatusChecking)
        case .upToDate: settings.text.string(.updateStatusUpToDate)
        case .available(let info):
            String(format: settings.text.string(.updateStatusAvailable), info.latestVersion)
        case .failed: settings.text.string(.updateStatusFailed)
        }
    }
```

- [ ] **Step 8: Build, full suite, launch smoke**

```bash
swift build && swift test
swift run AINotebookApp &  # ~10s, confirm alive, no crash, then kill — report honestly
```

- [ ] **Step 9: Commit**

```bash
git add Sources/AINotebookCore/AppSettings.swift Sources/AINotebookCore/Localization.swift \
        Sources/AINotebookApp/UpdateService.swift Sources/AINotebookApp/UpdateBanner.swift \
        Sources/AINotebookApp/ContentView.swift Sources/AINotebookApp/AINotebookApp.swift \
        Sources/AINotebookApp/SettingsView.swift \
        Tests/AINotebookCoreTests/AppSettingsTests.swift Tests/AINotebookCoreTests/LocalizationTests.swift
git commit -m "feat(mac): in-app update check — service, banner, settings rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Windows — settings keys, DI, ShellPage InfoBar, Settings rows, launch hook

**Files:**
- Modify: `windows/src/AINotebook.App/Services/ISettingsService.cs` + `SettingsService.cs` (two keys, 4-edit pattern each)
- Create: `windows/src/AINotebook.App/Services/UpdateState.cs`
- Modify: `windows/src/AINotebook.App/App.xaml.cs` (DI registrations + launch hook)
- Modify: `windows/src/AINotebook.App/Views/ShellPage.xaml` + `.xaml.cs` (top InfoBar)
- Modify: `windows/src/AINotebook.App/Views/SettingsDialog.xaml` + `.xaml.cs` (toggle + check-now + status)
- Modify: `windows/src/AINotebook.App/ViewModels/SettingsViewModel.cs`
- Modify: `windows/src/AINotebook.App/Services/StringKey.cs` + both `Strings/*/Resources.resw`
- Test: `windows/tests/AINotebook.App.Tests/` — SettingsService key persistence + SettingsViewModel check-now (CI-run; blind-write with signature verification)

**Interfaces:**
- Consumes: `UpdateChecker` (Task 5), `UpdateInfo` (Task 4), `AINotebookVersion.Current` (Task 2), SettingsService 4-edit pattern, ShellPage/SettingsDialog structures.
- Produces: `ISettingsService.AutoCheckUpdates: bool` (default true) + `LastUpdateCheckUtc: DateTimeOffset?` (DTO stores ISO-8601 `string?`); `UpdateState : ObservableObject` singleton (`UpdateInfo? Available`, `bool BannerDismissed`) bridging the launch check → ShellPage InfoBar; DI: `services.AddSingleton<UpdateChecker>()` (uses the shared `HttpClient`), `services.AddSingleton<UpdateState>()`.

- [ ] **Step 1: Settings keys (4-edit pattern ×2, read `SettingsService.cs` first)**

`ISettingsService.cs` — add:

```csharp
    bool AutoCheckUpdates { get; set; }
    DateTimeOffset? LastUpdateCheckUtc { get; set; }
```

`SettingsService.cs` — DTO gains `public bool? AutoCheckUpdates { get; set; }` and `public string? LastUpdateCheckUtc { get; set; }`; ctor init `_autoCheckUpdates = _file.AutoCheckUpdates ?? true;` and `_lastUpdateCheckUtc = DateTimeOffset.TryParse(_file.LastUpdateCheckUtc, null, System.Globalization.DateTimeStyles.RoundtripKind, out var t) ? t : null;`; properties following the existing `HasCompletedOnboarding` shape verbatim, with the setter writing `_file.LastUpdateCheckUtc = value?.ToString("o");`.

- [ ] **Step 2: `UpdateState`**

Create `windows/src/AINotebook.App/Services/UpdateState.cs`:

```csharp
using AINotebook.Core;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AINotebook.App.Services;

/// Bridges the launch-time update check to the ShellPage banner.
/// UI-thread only (mutated via App.Ui.TryEnqueue).
public sealed partial class UpdateState : ObservableObject
{
    [ObservableProperty]
    public partial UpdateInfo? Available { get; set; }

    [ObservableProperty]
    public partial bool BannerDismissed { get; set; }
}
```

- [ ] **Step 3: DI + launch hook**

`App.xaml.cs` `ConfigureServices` — after the shared `HttpClient` registration:

```csharp
        services.AddSingleton(sp => new UpdateChecker(sp.GetRequiredService<HttpClient>()));
        services.AddSingleton<UpdateState>();
```

`OnLaunched` — after `MainWindow.Activate();`:

```csharp
        _ = RunStartupUpdateCheckAsync();
```

and the method (same class):

```csharp
    /// Launch-time update check: toggle on, ≥24h since last, onboarding done.
    /// Fully best-effort — failures are silent (spec).
    private async Task RunStartupUpdateCheckAsync()
    {
        try
        {
            var settings = Services.GetRequiredService<ISettingsService>();
            if (!settings.HasCompletedOnboarding || !settings.AutoCheckUpdates) return;
            var last = settings.LastUpdateCheckUtc;
            if (last is not null && DateTimeOffset.UtcNow - last < TimeSpan.FromHours(24)) return;

            var checker = Services.GetRequiredService<UpdateChecker>();
            var info = await checker.CheckAsync();
            settings.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            if (!info.IsUpdateAvailable) return;
            Ui?.TryEnqueue(() =>
            {
                Services.GetRequiredService<UpdateState>().Available = info;
            });
        }
        catch
        {
            // silent by design
        }
    }
```

(Verify `Services`, `Ui`, and the using list against the real file; mirror the class's existing style.)

- [ ] **Step 4: ShellPage InfoBar**

`ShellPage.xaml` — wrap the existing `NavigationView` in a root `Grid` with two rows; row 0 = the InfoBar (mirror SettingsDialog's existing `ErrorBar` InfoBar syntax):

```xml
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <InfoBar x:Name="UpdateBar" Grid.Row="0" Severity="Informational"
                 IsClosable="True" IsOpen="False">
            <InfoBar.ActionButton>
                <Button x:Name="UpdateDownloadButton" Click="OnUpdateDownload"/>
            </InfoBar.ActionButton>
        </InfoBar>
        <muxc:NavigationView Grid.Row="1" ...existing attributes unchanged... >
            ...existing content unchanged...
        </muxc:NavigationView>
    </Grid>
```

`ShellPage.xaml.cs` — in the ctor resolve `UpdateState` + `ISettingsService` (existing DI-resolve style), subscribe:

```csharp
        _updateState = App.Current.Services.GetRequiredService<UpdateState>();
        _updateState.PropertyChanged += (_, __) => SyncUpdateBar();
        SyncUpdateBar();
```

and add:

```csharp
    private void SyncUpdateBar()
    {
        var info = _updateState.Available;
        if (info is null || _updateState.BannerDismissed) { UpdateBar.IsOpen = false; return; }
        UpdateBar.Message = string.Format(_strings.Get(StringKey.UpdateBannerTitle), info.LatestVersion);
        UpdateDownloadButton.Content = _strings.Get(StringKey.UpdateDownloadButton);
        UpdateBar.IsOpen = true;
        UpdateBar.CloseButtonClick += (_, __) => _updateState.BannerDismissed = true;
    }

    private async void OnUpdateDownload(object sender, RoutedEventArgs e)
    {
        var info = _updateState.Available;
        if (info is null) return;
        _ = await Windows.System.Launcher.LaunchUriAsync(new Uri(info.DownloadUrl));
    }
```

(Subscribe `CloseButtonClick` ONCE in the ctor, not inside SyncUpdateBar — adjust when writing; the snippet marks intent, the implementer must avoid duplicate subscriptions.)

- [ ] **Step 5: Settings rows + VM**

`SettingsViewModel.cs` — add (mirror existing property/relay-command style; deps: it already gets `ProviderRouter`; add `UpdateChecker` + `ISettingsService` is already there):

```csharp
    public bool AutoCheckUpdates
    {
        get => _settings.AutoCheckUpdates;
        set { if (_settings.AutoCheckUpdates != value) { _settings.AutoCheckUpdates = value; OnPropertyChanged(); } }
    }

    [ObservableProperty]
    public partial string UpdateStatus { get; set; } = "";

    [RelayCommand]
    public async Task CheckForUpdatesAsync()
    {
        UpdateStatus = _strings.Get(StringKey.UpdateStatusChecking);
        try
        {
            var info = await _checker.CheckAsync();
            _settings.LastUpdateCheckUtc = DateTimeOffset.UtcNow;
            UpdateStatus = info.IsUpdateAvailable
                ? string.Format(_strings.Get(StringKey.UpdateStatusAvailable), info.LatestVersion)
                : _strings.Get(StringKey.UpdateStatusUpToDate);
        }
        catch
        {
            UpdateStatus = _strings.Get(StringKey.UpdateStatusFailed);
        }
    }
```

(Check how the VM currently accesses localized strings — if it doesn't hold `ILocalizedStrings`, thread status through the dialog code-behind instead, mirroring how other VM status text is localized today; document the choice. The VM ctor gains an `UpdateChecker` dependency — grep `new SettingsViewModel(` and update every construction site.)

`SettingsDialog.xaml` — after the version Grid, before the author footer:

```xml
        <ToggleSwitch x:Name="AutoUpdateToggle" Toggled="OnAutoUpdateToggled"/>
        <StackPanel Orientation="Horizontal" Spacing="12">
            <Button x:Name="CheckUpdatesButton" Click="OnCheckUpdates"/>
            <TextBlock x:Name="UpdateStatusText" VerticalAlignment="Center"
                       Foreground="{ThemeResource TextFillColorSecondaryBrush}"/>
        </StackPanel>
```

`SettingsDialog.xaml.cs` — set header/labels from `StringKey`, wire `OnAutoUpdateToggled` → VM property, `OnCheckUpdates` → `await ViewModel.CheckForUpdatesAsync()` then `UpdateStatusText.Text = ViewModel.UpdateStatus` (or bind via PropertyChanged like other fields — mirror the file's existing wiring idiom).

- [ ] **Step 6: Localization (resw ×2 + StringKey)**

Add to BOTH resw files + `StringKey.cs` (camelCase resw keys, PascalCase enum — existing convention): `updateBannerTitle` EN `A new version ({0}) is available.` / CZ `Je k dispozici nová verze ({0}).`; `updateDownloadButton` `Download`/`Stáhnout`; `updateLaterButton` `Later`/`Později`; `updateAutoCheckToggle` `Automatically check for updates`/`Automaticky kontrolovat aktualizace`; `updateCheckNowButton` `Check for updates now`/`Zkontrolovat aktualizace`; `updateStatusChecking` `Checking…`/`Kontroluji…`; `updateStatusUpToDate` `You're up to date`/`Máte aktuální verzi`; `updateStatusAvailable` `Update available ({0})`/`Dostupná aktualizace ({0})`; `updateStatusFailed` `Couldn't check for updates.`/`Kontrola aktualizací se nezdařila.` If `LocalizedStringsTests` pins a key count, update it (+9).

- [ ] **Step 7: App tests (blind-write, signature-verified)**

Extend `windows/tests/AINotebook.App.Tests/SettingsServiceTests.cs` (mirror its temp-file fixture): `AutoCheckUpdates` defaults true + roundtrips false; `LastUpdateCheckUtc` defaults null + roundtrips a value through save/reload (ISO-8601). Add `UpdateStateTests.cs`: property-changed fires for `Available`.

- [ ] **Step 8: Local verification + commit**

```bash
dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj   # full Core still green
git add windows/src/AINotebook.App windows/tests/AINotebook.App.Tests
git commit -m "feat(win): in-app update check — settings keys, launch hook, InfoBar, settings rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

(App compile/tests deferred to windows-ci in Task 8.)

---

### Task 8: Finalize — README, CHANGELOG, CI, PR

**Files:**
- Modify: `README.md` (privacy bullet: note the update-check toggle)
- Modify: `CHANGELOG.md` (`[Unreleased]` section)

- [ ] **Step 1: README**

In the Privacy section, the outbound-calls bullet already mentions "an optional update check" — extend it: `an optional once-a-day update check against api.github.com (toggleable in Settings)`. Read the surrounding text and keep its voice.

- [ ] **Step 2: CHANGELOG**

Add at the top:

```markdown
## [Unreleased]

### Added
- Both platforms: in-app update check — once a day (toggleable in Settings)
  the app asks GitHub Releases whether a newer version exists and shows a
  dismissible banner with a Download button; a "Check for updates now"
  button lives in Settings. Check + notify only, no auto-download.

### Fixed
- The in-app version constants were stale (0.7.3); they now match the repo
  VERSION file and a guard test on each platform fails CI on any future drift.
```

- [ ] **Step 3: Full local verification**

```bash
swift test --parallel > /dev/null 2>&1 && echo "MAC OK"
dotnet test windows/tests/AINotebook.Core.Tests/AINotebook.Core.Tests.csproj -c Release 2>&1 | grep "Passed!"
OFFENDERS=$(grep -rl --include='*.swift' 'URLSession' Sources/AINotebookCore/ | grep -v -e '/OllamaClient.swift$' -e '/WebExtractor.swift$' -e '/Providers/' || true); [ -z "$OFFENDERS" ] && echo "GATE OK"
```

- [ ] **Step 4: Commit docs, push, PR, CI**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: changelog + README for in-app update check

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
git push -u origin feat/update-check
gh pr create --base main --head feat/update-check --draft \
  --title "feat: in-app update check (both platforms)" \
  --body "Check + notify per docs/superpowers/specs/2026-06-30-in-app-update-check-design.md. Version constants fixed to 0.9.2 with VERSION-file guard tests."
gh workflow run windows-ci.yml --ref feat/update-check
sleep 15
gh run watch $(gh run list --branch feat/update-check --workflow core-ci.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
gh run watch $(gh run list --branch feat/update-check --workflow windows-ci.yml --limit 1 --json databaseId --jq '.[0].databaseId') --exit-status
```

Expected: both green (core-ci runs via the PR's pull_request trigger; windows-ci via dispatch — its push trigger covers main/feat/** so the push may also fire it; either is fine).

- [ ] **Step 5: Manual acceptance (user)**

macOS: launch with an artificially low current version? Not needed — Settings → "Check for updates now" should report "You're up to date" (current 0.9.2 == latest). To see the banner end-to-end before a real newer release exists, temporarily set `AINotebookVersion` to `0.9.1` in a local build, launch, verify banner + Download opens the browser, then revert. Windows: same via `AINotebookVersion.Current`. Toggle off → relaunch → no auto-check (verify via no banner + unchanged "last checked"). Report results before merging.

## Out of scope

Auto-download/install, skip-version lists, background polling (spec non-goals). Release (version bump/tag) after merge is a separate user decision.
