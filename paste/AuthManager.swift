import Combine
import Foundation
import SwiftUI

/// Runtime feature-flag model for Clipen.
///
/// All feature flags are hard-coded as enabled — no backend dependency.
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    // ── Capabilities — Clipen is a fully free app. Every feature is always
    // available; there is no Pro tier or plan gating. These were once
    // backend-gated feature flags; they are now constants so the gating
    // logic throughout the app resolves to "always on".
    let transformsEnabled  = true
    let semanticSearch      = true
    let ocrEnabled          = true
    let pdfTextExtract      = true
    let timeScrub           = true
    /// Upper bound for the user-adjustable ring size (matches the Stepper range).
    let ringLimit           = 200

    // ── All features hard-coded as enabled — no backend dependency.
    let maxDataBytes:           Int  = 200 * 1024 * 1024  // 200 MB
    let pinEnabled:             Bool = true
    let urlTitles:              Bool = true
    let richTextCapture:        Bool = true
    let fileCapture:            Bool = true
    let sparkleAutomaticChecks: Bool = true
    let updateCheckEveryClicks: Int  = 50

    /// Last user-facing error message, if any. The clipboard-side code path
    /// still surfaces errors (e.g. "Couldn't update Launch at login"), so
    /// the alert plumbing in the main window keeps this around.
    @Published var lastError: String? = nil
    func clearError() { lastError = nil }

    private let clickCountKey              = "backendFeatureFlagsClickCount"
    private let fastPasteCountKey          = "backendFastPasteCount"
    private let lastUpdateCheckClickKey    = "backendFeatureFlagsLastUpdateCheckClick"
    private let toolUsageCountsKey         = "backendToolUsageCounts"
    private let toolUsageTotalsKey         = "backendToolUsageTotals"
    private let toolLastUsedAtKey          = "backendToolLastUsedAt"
    private let toolBucketUsageKey         = "backendToolBucketUsage"
    private let globalBucketUsageKey       = "backendGlobalBucketUsage"

    // In-memory caches for UserDefaults tool-usage dictionaries so
    // toolImportanceScore() doesn't do 4 full dict deserializations per tool per show.
    private var _toolUsageTotalsCache: [String: Int]? = nil
    private var _toolLastUsedAtCache: [String: Double]? = nil
    private var _toolBucketUsageCache: [String: Int]? = nil
    private var _globalBucketUsageCache: [String: Int]? = nil

    private init() {
        DispatchQueue.main.async {
            ClipboardManager.shared.applyPlanLimits(ringLimit: self.ringLimit)
            self.applyFeatureFlagsToRuntime()
        }
    }

    func registerCommandVAction() {
        let nextClickCount = UserDefaults.standard.integer(forKey: clickCountKey) + 1
        UserDefaults.standard.set(nextClickCount, forKey: clickCountKey)
        let lastUpdateCheck = UserDefaults.standard.integer(forKey: lastUpdateCheckClickKey)
        if nextClickCount - lastUpdateCheck >= updateCheckEveryClicks {
            UserDefaults.standard.set(nextClickCount, forKey: lastUpdateCheckClickKey)
            AppDelegate.shared?.checkForUpdatesInBackgroundIfAllowed()
        }
    }

    /// Increment the lifetime fast-paste counter (⌘V tapped + released inside
    /// the first-open-delay window — popup never appeared, normal system-paste
    /// behaviour kicked in).  Persisted locally and also reported to the
    /// backend on the next refresh via `fastPasteCount` in RefreshFlagsRequest,
    /// so we can see how often users land on the implicit "fast paste" path
    /// vs the cycle popup.
    func registerFastPasteAction() {
        let next = UserDefaults.standard.integer(forKey: fastPasteCountKey) + 1
        UserDefaults.standard.set(next, forKey: fastPasteCountKey)
        // A fast paste is functionally a ⌘V — let the standard pipeline run
        // (refresh-throttle + update check) so it isn't a second-class action.
        registerCommandVAction()
    }

    var fastPasteCount: Int {
        UserDefaults.standard.integer(forKey: fastPasteCountKey)
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
        _toolUsageTotalsCache = totals
        UserDefaults.standard.set(totals, forKey: toolUsageTotalsKey)

        var lastUsed = toolLastUsedAt()
        lastUsed[toolID] = now.timeIntervalSince1970
        _toolLastUsedAtCache = lastUsed
        UserDefaults.standard.set(lastUsed, forKey: toolLastUsedAtKey)

        var perToolBucket = toolBucketUsage()
        perToolBucket["\(toolID)|\(bucket)", default: 0] += count
        _toolBucketUsageCache = perToolBucket
        UserDefaults.standard.set(perToolBucket, forKey: toolBucketUsageKey)

        var globalBucket = globalBucketUsage()
        globalBucket[bucket, default: 0] += count
        _globalBucketUsageCache = globalBucket
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

    private func toolUsageTotals() -> [String: Int] {
        if let cached = _toolUsageTotalsCache { return cached }
        guard let raw = UserDefaults.standard.dictionary(forKey: toolUsageTotalsKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int { value = n }
            else if let n = v as? NSNumber { value = n.intValue }
            else { continue }
            if value > 0 { counts[k] = value }
        }
        _toolUsageTotalsCache = counts
        return counts
    }

    private func toolLastUsedAt() -> [String: Double] {
        if let cached = _toolLastUsedAtCache { return cached }
        guard let raw = UserDefaults.standard.dictionary(forKey: toolLastUsedAtKey) else { return [:] }
        var values: [String: Double] = [:]
        for (k, v) in raw {
            let value: Double
            if let n = v as? Double { value = n }
            else if let n = v as? NSNumber { value = n.doubleValue }
            else { continue }
            if value > 0 { values[k] = value }
        }
        _toolLastUsedAtCache = values
        return values
    }

    private func toolBucketUsage() -> [String: Int] {
        if let cached = _toolBucketUsageCache { return cached }
        guard let raw = UserDefaults.standard.dictionary(forKey: toolBucketUsageKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int { value = n }
            else if let n = v as? NSNumber { value = n.intValue }
            else { continue }
            if value > 0 { counts[k] = value }
        }
        _toolBucketUsageCache = counts
        return counts
    }

    private func globalBucketUsage() -> [String: Int] {
        if let cached = _globalBucketUsageCache { return cached }
        guard let raw = UserDefaults.standard.dictionary(forKey: globalBucketUsageKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int { value = n }
            else if let n = v as? NSNumber { value = n.intValue }
            else { continue }
            if value > 0 { counts[k] = value }
        }
        _globalBucketUsageCache = counts
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

}
