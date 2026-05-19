import Combine
import Foundation
import SwiftUI

/// What used to be the full user-account system (Sign in with Apple,
/// Firestore-backed plan, click-counter refresh, install tracking).
/// All of that has been removed — Clipen is now a local-only app with
/// zero backend coupling for accounts.
///
/// This class stays as an ObservableObject because hundreds of existing
/// @ObservedObject / @StateObject bindings in views read `auth.ringLimit`,
/// `auth.transformsEnabled`, etc. Rather than rewire every view, we keep
/// the shape and serve hardcoded "everyone unlocked" defaults.
///
/// To re-introduce accounts later (e.g. when shipping iCloud sync or a
/// real Pro tier): restore the full implementation from git history at
/// commit ~`932a1a8…` and switch the relevant @Published vars to be
/// server-driven again.
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    // ── Feature flags — every capability on for everyone ─────────────────
    @Published var ringLimit:           Int  = 200   // max selectable in Settings stepper
    @Published var transformsEnabled:   Bool = true
    @Published var pinEnabled:          Bool = true
    @Published var semanticSearch:      Bool = true
    @Published var urlTitles:           Bool = true
    @Published var richTextCapture:     Bool = true
    @Published var fileCapture:         Bool = true
    @Published var timeScrub:           Bool = true
    @Published var ocrEnabled:          Bool = true
    @Published var pdfTextExtract:      Bool = true
    @Published var refreshEveryClicks:  Int  = 100
    @Published var updateCheckEveryClicks: Int = 100
    @Published var sparkleAutomaticChecks: Bool = true

    // ── Compatibility shims for the few views that still ask "is the user X?"
    // Everyone has every feature; nobody has a backend account. Returning
    // these constants lets the existing UI-gating logic keep working without
    // a rewrite.
    var isPro:      Bool { true }
    var isSignedIn: Bool { false }

    /// Last user-facing error message, if any. The clipboard-side code path
    /// still surfaces errors (e.g. "Couldn't update Launch at login"), so
    /// the alert plumbing in the main window keeps this around.
    @Published var lastError: String? = nil
    func clearError() { lastError = nil }

    private let cacheKey = "backendFeatureFlagsCache"
    private let clickCountKey = "backendFeatureFlagsClickCount"
    private let lastRefreshClickKey = "backendFeatureFlagsLastRefreshClick"
    private let lastUpdateCheckClickKey = "backendFeatureFlagsLastUpdateCheckClick"
    private let deviceIDKey = "backendFeatureFlagsDeviceID"
    private let backendURLKey = "backendFeatureFlagsURL"

    private var refreshInFlight = false

    private init() {
        loadCachedFeatureFlags()
        // Make sure ClipboardManager's maxItems trim kicks in on launch.
        // Deferring to next runloop tick avoids "modifying @Published state
        // during view init" undefined-behaviour warnings.
        DispatchQueue.main.async {
            ClipboardManager.shared.applyPlanLimits(ringLimit: self.ringLimit)
            self.applyFeatureFlagsToRuntime()
            self.refreshFeatureFlags(force: true)
        }
    }

    func registerCommandVAction() {
        let nextClickCount = UserDefaults.standard.integer(forKey: clickCountKey) + 1
        UserDefaults.standard.set(nextClickCount, forKey: clickCountKey)

        let lastRefresh = UserDefaults.standard.integer(forKey: lastRefreshClickKey)
        if nextClickCount - lastRefresh >= max(refreshEveryClicks, 1) {
            refreshFeatureFlags(force: true, clickCount: nextClickCount)
        }

        let lastUpdateCheck = UserDefaults.standard.integer(forKey: lastUpdateCheckClickKey)
        if nextClickCount - lastUpdateCheck >= max(updateCheckEveryClicks, 1) {
            UserDefaults.standard.set(nextClickCount, forKey: lastUpdateCheckClickKey)
            AppDelegate.shared?.checkForUpdatesInBackgroundIfAllowed()
        }
    }

    func refreshFeatureFlags(force: Bool = false, clickCount: Int? = nil) {
        guard !refreshInFlight else { return }
        let currentClickCount = clickCount ?? UserDefaults.standard.integer(forKey: clickCountKey)
        let lastRefresh = UserDefaults.standard.integer(forKey: lastRefreshClickKey)
        guard force || currentClickCount - lastRefresh >= max(refreshEveryClicks, 1) else { return }

        guard let url = URL(string: backendRefreshURL) else { return }
        refreshInFlight = true

        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshFlagsRequest(
            deviceID: deviceID,
            clickCount: currentClickCount
        ))

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshInFlight = false
                guard let data else { return }

                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                guard let response = try? decoder.decode(FeatureFlagsResponse.self, from: data),
                      response.success else { return }

                self.apply(response)
                UserDefaults.standard.set(currentClickCount, forKey: self.lastRefreshClickKey)
                if let encoded = try? JSONEncoder().encode(response) {
                    UserDefaults.standard.set(encoded, forKey: self.cacheKey)
                }
            }
        }.resume()
    }

    private var backendRefreshURL: String {
        let base = UserDefaults.standard.string(forKey: backendURLKey)
            ?? "https://clipen-backend.onrender.com"
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/clipen/refresh-flags"
    }

    private var deviceID: String {
        if let existing = UserDefaults.standard.string(forKey: deviceIDKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: deviceIDKey)
        return fresh
    }

    private func loadCachedFeatureFlags() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode(FeatureFlagsResponse.self, from: data),
              cached.success else { return }
        apply(cached)
    }

    private func apply(_ flags: FeatureFlagsResponse) {
        ringLimit = flags.ringLimit
        transformsEnabled = flags.transformsEnabled
        pinEnabled = flags.pinEnabled
        semanticSearch = flags.semanticSearch
        urlTitles = flags.urlTitles
        richTextCapture = flags.richTextCapture
        fileCapture = flags.fileCapture
        timeScrub = flags.timeScrub
        ocrEnabled = flags.ocr
        pdfTextExtract = flags.pdfTextExtract
        refreshEveryClicks = max(flags.refreshEveryClicks, 1)
        updateCheckEveryClicks = max(flags.updateCheckEveryClicks, 1)
        sparkleAutomaticChecks = flags.sparkleAutomaticChecks
        applyFeatureFlagsToRuntime()
    }

    private func applyFeatureFlagsToRuntime() {
        let manager = ClipboardManager.shared
        manager.applyPlanLimits(ringLimit: ringLimit)
        manager.captureRichText = richTextCapture
        manager.fetchURLTitles = urlTitles
        manager.captureFiles = fileCapture
        AppDelegate.shared?.automaticallyChecksForUpdates = sparkleAutomaticChecks
    }
}

private struct RefreshFlagsRequest: Encodable {
    let deviceID: String
    let clickCount: Int

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case clickCount = "click_count"
    }
}

private struct FeatureFlagsResponse: Codable {
    let success: Bool
    let plan: String?
    let ringLimit: Int
    let transformsEnabled: Bool
    let pinEnabled: Bool
    let semanticSearch: Bool
    let urlTitles: Bool
    let richTextCapture: Bool
    let fileCapture: Bool
    let timeScrub: Bool
    let ocr: Bool
    let pdfTextExtract: Bool
    let refreshEveryClicks: Int
    let updateCheckEveryClicks: Int
    let sparkleAutomaticChecks: Bool
}
