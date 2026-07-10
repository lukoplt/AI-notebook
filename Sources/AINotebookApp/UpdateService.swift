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
    /// Last known update, independent of `status`. `status` reflects the
    /// current/last check's transient outcome (.checking, .failed, etc.),
    /// so deriving `availableInfo` from it hides an already-known update
    /// while a new check is in flight or a manual check fails. This tracks
    /// the update separately so the banner stays visible through those
    /// transient states.
    @Published private(set) var available: UpdateInfo?

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/lukoplt/AI-notebook/releases?per_page=30")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private let settings: AppSettings
    private let session: URLSession

    init(settings: AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    var availableInfo: UpdateInfo? { available }

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
            if info.isUpdateAvailable {
                available = info
                // A newly-found update re-shows the banner even if the user
                // dismissed a prior one this session (they asked for a check).
                bannerDismissed = false
                status = .available(info)
            } else {
                available = nil
                status = .upToDate
            }
        } catch {
            // Leave `available` untouched — a transient failure or a new
            // in-flight check must not hide an already-known update.
            status = silent ? .idle : .failed
        }
    }
}
