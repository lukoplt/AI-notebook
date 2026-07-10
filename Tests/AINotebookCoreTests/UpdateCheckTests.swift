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
