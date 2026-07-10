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
