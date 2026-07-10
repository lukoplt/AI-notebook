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
