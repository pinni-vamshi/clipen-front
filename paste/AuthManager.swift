import Combine
import Foundation
import SwiftUI

/// Runtime feature-flag model for Clipen.
///
/// Values are bootstrapped from the last known backend state (cached in
/// UserDefaults), then refreshed from `/clipen/refresh-flags`. This avoids
/// shipping opinionated hardcoded feature defaults in the client.
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var ringLimit:           Int  = AuthManager.intState(for: "featureState.ringLimit")
    @Published var transformsEnabled:   Bool = AuthManager.boolState(for: "featureState.transformsEnabled")
    @Published var pinEnabled:          Bool = AuthManager.boolState(for: "featureState.pinEnabled")
    @Published var semanticSearch:      Bool = AuthManager.boolState(for: "featureState.semanticSearch")
    @Published var urlTitles:           Bool = AuthManager.boolState(for: "featureState.urlTitles")
    @Published var richTextCapture:     Bool = AuthManager.boolState(for: "featureState.richTextCapture")
    @Published var fileCapture:         Bool = AuthManager.boolState(for: "featureState.fileCapture")
    @Published var timeScrub:           Bool = AuthManager.boolState(for: "featureState.timeScrub")
    @Published var ocrEnabled:          Bool = AuthManager.boolState(for: "featureState.ocr")
    @Published var pdfTextExtract:      Bool = AuthManager.boolState(for: "featureState.pdfTextExtract")
    @Published var refreshEveryClicks:  Int  = AuthManager.intState(for: "featureState.refreshEveryClicks")
    @Published var updateCheckEveryClicks: Int = AuthManager.intState(for: "featureState.updateCheckEveryClicks")
    @Published var sparkleAutomaticChecks: Bool = AuthManager.boolState(for: "featureState.sparkleAutomaticChecks")

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
    private let installKeyDefaultsKey = "backendFeatureFlagsInstallKey"
    private let backendURLKey = "backendFeatureFlagsURL"
    private let toolUsageCountsKey = "backendToolUsageCounts"
    private let toolUsageTotalsKey = "backendToolUsageTotals"
    private let toolLastUsedAtKey = "backendToolLastUsedAt"
    private let toolBucketUsageKey = "backendToolBucketUsage"
    private let globalBucketUsageKey = "backendGlobalBucketUsage"

    private var refreshInFlight = false

    private init() {
        let hasBootstrappedFlags = hasPersistedFeatureState() || UserDefaults.standard.data(forKey: cacheKey) != nil
        loadCachedFeatureFlags()
        DispatchQueue.main.async {
            if hasBootstrappedFlags {
                ClipboardManager.shared.applyPlanLimits(ringLimit: self.ringLimit)
                self.applyFeatureFlagsToRuntime()
            }
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

    /// Track per-tool usage deltas locally; flushed on the next backend
    /// refresh call so we can attribute usage to a stable `install_key`.
    func registerToolUsage(toolID: String, count: Int = 1) {
        guard !toolID.isEmpty, count > 0 else { return }
        let now = Date()
        let bucket = currentTimeBucket(for: now)

        var counters = pendingToolUsageCounts()
        counters[toolID, default: 0] += count
        UserDefaults.standard.set(counters, forKey: toolUsageCountsKey)

        var totals = toolUsageTotals()
        totals[toolID, default: 0] += count
        UserDefaults.standard.set(totals, forKey: toolUsageTotalsKey)

        var lastUsed = toolLastUsedAt()
        lastUsed[toolID] = now.timeIntervalSince1970
        UserDefaults.standard.set(lastUsed, forKey: toolLastUsedAtKey)

        var perToolBucket = toolBucketUsage()
        perToolBucket["\(toolID)|\(bucket)", default: 0] += count
        UserDefaults.standard.set(perToolBucket, forKey: toolBucketUsageKey)

        var globalBucket = globalBucketUsage()
        globalBucket[bucket, default: 0] += count
        UserDefaults.standard.set(globalBucket, forKey: globalBucketUsageKey)
    }

    /// Composite ranking signal (frequency + recency + time-context affinity)
    /// used by transform/tool panels to prioritize relevant tools.
    func toolImportanceScore(for toolID: String, now: Date = Date()) -> Double {
        let totals = toolUsageTotals()
        let totalCount = Double(totals[toolID, default: 0])
        guard totalCount > 0 else { return 0 }

        // 1) Frequency: saturating growth to avoid permanent lock-in.
        let frequency = min(log1p(totalCount) / 5.0, 1.0)

        // 2) Recency: exponential decay from last-use timestamp.
        let lastUsedEpoch = toolLastUsedAt()[toolID] ?? 0
        let recency: Double = {
            guard lastUsedEpoch > 0 else { return 0 }
            let ageHours = max(0, (now.timeIntervalSince1970 - lastUsedEpoch) / 3600.0)
            let tauHours = 24.0 * 7.0 // 7-day half-life-ish window
            return exp(-ageHours / tauHours)
        }()

        // 3) Time-context affinity: how often this tool is used in the
        // current day-part/weekend bucket, smoothed to avoid cold-start jumps.
        let bucket = currentTimeBucket(for: now)
        let toolBucketCount = Double(toolBucketUsage()["\(toolID)|\(bucket)", default: 0])
        let bucketTotal = Double(globalBucketUsage()[bucket, default: 0])
        let distinctTools = Double(max(1, totals.count))
        let alpha = 1.0
        let timeAffinity = (toolBucketCount + alpha) / (bucketTotal + alpha * distinctTools)

        let wFrequency = 0.45
        let wRecency = 0.35
        let wTimeAffinity = 0.20
        return (wFrequency * frequency) + (wRecency * recency) + (wTimeAffinity * timeAffinity)
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
            installKey: installKey,
            clickCount: currentClickCount,
            appVersion: appVersion,
            osVersion: osVersion,
            toolUsageCounts: pendingToolUsageCounts()
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
                self.clearPendingToolUsageCounts()
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

    /// A randomly-generated private UUID that identifies this install.
    /// It is NOT a hardware or system device identifier — it is generated
    /// once at first launch and stored in Keychain so it survives UserDefaults
    /// clears and reinstalls, giving the backend a stable key to associate
    /// feature flags and usage data with this installation.
    private var installKey: String {
        let keychainKey = "installKey"
        if let existing = Keychain.get(keychainKey) {
            return existing
        }
        // Migrate from previous Keychain key ("installID") or UserDefaults fallback,
        // then generate a fresh UUID for brand-new installs.
        let legacyKeychain = Keychain.get("installID")
        let legacyDefaults = UserDefaults.standard.string(forKey: installKeyDefaultsKey)
        let key = legacyKeychain ?? legacyDefaults ?? UUID().uuidString
        Keychain.set(key, forKey: keychainKey)
        return key
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    private var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    private func pendingToolUsageCounts() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: toolUsageCountsKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int {
                value = n
            } else if let n = v as? NSNumber {
                value = n.intValue
            } else {
                continue
            }
            if value > 0 { counts[k] = value }
        }
        return counts
    }

    private func clearPendingToolUsageCounts() {
        UserDefaults.standard.removeObject(forKey: toolUsageCountsKey)
    }

    private func toolUsageTotals() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: toolUsageTotalsKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int {
                value = n
            } else if let n = v as? NSNumber {
                value = n.intValue
            } else {
                continue
            }
            if value > 0 { counts[k] = value }
        }
        return counts
    }

    private func toolLastUsedAt() -> [String: Double] {
        guard let raw = UserDefaults.standard.dictionary(forKey: toolLastUsedAtKey) else { return [:] }
        var values: [String: Double] = [:]
        for (k, v) in raw {
            let value: Double
            if let n = v as? Double {
                value = n
            } else if let n = v as? NSNumber {
                value = n.doubleValue
            } else {
                continue
            }
            if value > 0 { values[k] = value }
        }
        return values
    }

    private func toolBucketUsage() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: toolBucketUsageKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int {
                value = n
            } else if let n = v as? NSNumber {
                value = n.intValue
            } else {
                continue
            }
            if value > 0 { counts[k] = value }
        }
        return counts
    }

    private func globalBucketUsage() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: globalBucketUsageKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int {
                value = n
            } else if let n = v as? NSNumber {
                value = n.intValue
            } else {
                continue
            }
            if value > 0 { counts[k] = value }
        }
        return counts
    }

    private func currentTimeBucket(for date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let dayType = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"
        let part: String
        switch hour {
        case 0..<6: part = "night"
        case 6..<12: part = "morning"
        case 12..<18: part = "afternoon"
        default: part = "evening"
        }
        return "\(dayType)_\(part)"
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
        persistFeatureState()
        applyFeatureFlagsToRuntime()
    }

    private func applyFeatureFlagsToRuntime() {
        let ringLimit = ringLimit
        let richTextCapture = richTextCapture
        let fileCapture = fileCapture
        let urlTitles = urlTitles
        let sparkleAutomaticChecks = sparkleAutomaticChecks

        DispatchQueue.main.async {
            let manager = ClipboardManager.shared
            manager.applyPlanLimits(ringLimit: ringLimit)
            if manager.captureRichText != richTextCapture {
                manager.captureRichText = richTextCapture
            }
            if manager.fetchURLTitles != urlTitles {
                manager.fetchURLTitles = urlTitles
            }
            if manager.captureFiles != fileCapture {
                manager.captureFiles = fileCapture
            }
            AppDelegate.shared?.automaticallyChecksForUpdates = sparkleAutomaticChecks
        }
    }

    private func hasPersistedFeatureState() -> Bool {
        UserDefaults.standard.object(forKey: "featureState.ringLimit") != nil
    }

    private func persistFeatureState() {
        let defaults = UserDefaults.standard
        defaults.set(ringLimit, forKey: "featureState.ringLimit")
        defaults.set(transformsEnabled, forKey: "featureState.transformsEnabled")
        defaults.set(pinEnabled, forKey: "featureState.pinEnabled")
        defaults.set(semanticSearch, forKey: "featureState.semanticSearch")
        defaults.set(urlTitles, forKey: "featureState.urlTitles")
        defaults.set(richTextCapture, forKey: "featureState.richTextCapture")
        defaults.set(fileCapture, forKey: "featureState.fileCapture")
        defaults.set(timeScrub, forKey: "featureState.timeScrub")
        defaults.set(ocrEnabled, forKey: "featureState.ocr")
        defaults.set(pdfTextExtract, forKey: "featureState.pdfTextExtract")
        defaults.set(refreshEveryClicks, forKey: "featureState.refreshEveryClicks")
        defaults.set(updateCheckEveryClicks, forKey: "featureState.updateCheckEveryClicks")
        defaults.set(sparkleAutomaticChecks, forKey: "featureState.sparkleAutomaticChecks")
    }

    private static func intState(for key: String) -> Int {
        UserDefaults.standard.object(forKey: key) as? Int ?? 0
    }

    private static func boolState(for key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? false
    }
}

private struct RefreshFlagsRequest: Encodable {
    let installKey: String
    let clickCount: Int
    let appVersion: String
    let osVersion: String
    let toolUsageCounts: [String: Int]

    enum CodingKeys: String, CodingKey {
        case installKey = "install_key"
        case clickCount = "click_count"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case toolUsageCounts = "tool_usage_counts"
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
