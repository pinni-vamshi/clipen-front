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
    /// Upper bound for the user-adjustable ring size (matches the Stepper range).
    let ringLimit           = 500

    // ── All features hard-coded as enabled — no backend dependency.
    let maxDataBytes:           Int  = 500 * 1024 * 1024  // 500 MB
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
    /// Flat `"yyyy-MM-dd|toolID"` → count, mirroring the toolBucketUsageKey
    /// pattern above. A day's numbers are only sent once that day is over —
    /// sending "today" mid-day would always undercount, since the user could
    /// still use more tools before midnight. `__cmdv__` is the synthetic
    /// "toolID" used for the ⌘V/paste-action count.
    private let dailyUsageKey              = "backendDailyUsageByDateTool"
    private static let cmdVBucketToolID    = "__cmdv__"

    /// Anonymous usage-ping endpoint — the deployed clipen_backend on Render.
    /// (The old value, https://api.clipen.app, was a placeholder domain that
    /// never existed in DNS — every ping failed silently and retried forever.)
    private static let usageBaseURL = URL(string: "https://clipen-backend.onrender.com")!

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
        // One-time cleanup: this pending-counts dict was flushed by the old
        // account/refresh backend call, which no longer exists — it just
        // accumulated in UserDefaults forever, never sent, never cleared.
        UserDefaults.standard.removeObject(forKey: toolUsageCountsKey)
        flushCompletedDailyUsage()
        // Periodic flush, independent of user activity. Launch + per-⌘V
        // flushes alone had a real hole: a menu-bar session left running
        // with no pastes never noticed midnight roll over, so the previous
        // day's counts sat unsent until the NEXT paste or relaunch —
        // "yesterday's data isn't in the database" even though nothing had
        // failed. Every 30 minutes is a no-op unless a completed day is
        // actually pending, and doubles as the retry cadence after a failed
        // send (Render cold starts, offline stretches) without needing the
        // user to paste again.
        usageFlushTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.flushCompletedDailyUsage()
        }
    }

    private var usageFlushTimer: Timer?

    func registerCommandVAction() {
        let nextClickCount = UserDefaults.standard.integer(forKey: clickCountKey) + 1
        UserDefaults.standard.set(nextClickCount, forKey: clickCountKey)
        let lastUpdateCheck = UserDefaults.standard.integer(forKey: lastUpdateCheckClickKey)
        if nextClickCount - lastUpdateCheck >= updateCheckEveryClicks {
            UserDefaults.standard.set(nextClickCount, forKey: lastUpdateCheckClickKey)
            AppDelegate.shared?.checkForUpdatesInBackgroundIfAllowed()
        }
        incrementDailyUsage(toolID: Self.cmdVBucketToolID, date: Self.dateKey(for: Date()))
        // Cheap no-op most of the time (nothing to flush until a day rolls
        // over) — called here too, not just at launch, so a menu-bar session
        // left running for days still reports without needing a relaunch.
        flushCompletedDailyUsage()
    }

    // MARK: - Daily usage reporting (previous completed day only)

    /// Increments today's local count for `toolID` (or the synthetic ⌘V
    /// bucket). Never sent immediately — only once that calendar day is over,
    /// via flushCompletedDailyUsage(), so the number reported is always a
    /// FINAL count, never a still-growing one from partway through the day.
    private func incrementDailyUsage(toolID: String, count: Int = 1, date: String) {
        guard !toolID.isEmpty, count > 0 else { return }
        var counts = dailyUsageRaw()
        counts["\(date)|\(toolID)", default: 0] += count
        UserDefaults.standard.set(counts, forKey: dailyUsageKey)
    }

    private func dailyUsageRaw() -> [String: Int] {
        guard let raw = UserDefaults.standard.dictionary(forKey: dailyUsageKey) else { return [:] }
        var counts: [String: Int] = [:]
        for (k, v) in raw {
            let value: Int
            if let n = v as? Int { value = n }
            else if let n = v as? NSNumber { value = n.intValue }
            else { continue }
            if value > 0 { counts[k] = value }
        }
        return counts
    }

    /// The user's LOCAL calendar day, strictly — not UTC. "Yesterday's data
    /// shows up after midnight MY time" is the behavior a person expects;
    /// the old UTC bucketing meant an IST user's day didn't roll over until
    /// 5:30 AM local, so yesterday's counts looked missing all morning. The
    /// backend stores the string verbatim per install, so mixed-timezone
    /// installs don't collide — each install's days are its own local days.
    private static func dateKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Anonymous, account-free usage reporting: sends per-tool and ⌘V counts
    /// for every calendar day that's fully over but hasn't been sent yet —
    /// never for today, since today's total is still growing. Handles
    /// backlog (app not opened for several days) by flushing every completed
    /// date it finds, not just the most recent one. Each date's local entries
    /// are only cleared once the backend confirms the send succeeded — a
    /// failed send is retried the next time this runs, next launch or paste.
    private func flushCompletedDailyUsage() {
        let todayKey = Self.dateKey(for: Date())
        // Give up on dates older than this — if a day has been failing to
        // send for a month (server never confirming, machine offline
        // forever), it's stale telemetry, not something worth carrying in
        // UserDefaults for eternity. String comparison works because the
        // keys are zero-padded yyyy-MM-dd.
        let expiryKey = Self.dateKey(for: Date().addingTimeInterval(-30 * 24 * 3600))
        var byDate: [String: [String: Int]] = [:]
        var expired: [(date: String, toolIDs: [String])] = []
        for (compoundKey, value) in dailyUsageRaw() {
            guard let sep = compoundKey.firstIndex(of: "|") else { continue }
            let date = String(compoundKey[compoundKey.startIndex..<sep])
            let toolID = String(compoundKey[compoundKey.index(after: sep)...])
            if date < expiryKey {
                expired.append((date, [toolID]))
                continue
            }
            guard date < todayKey else { continue }
            byDate[date, default: [:]][toolID] = value
        }
        for entry in expired {
            removeSentDailyUsage(date: entry.date, toolIDs: entry.toolIDs)
        }
        for (date, counts) in byDate {
            sendDailyUsage(date: date, counts: counts)
        }
    }

    /// Dates with a POST currently in flight. flushCompletedDailyUsage runs
    /// at launch AND on every ⌘V — without this guard, a burst of pastes
    /// fired several identical requests for the same pending date at once.
    private var usageSendsInFlight: Set<String> = []

    // MARK: - First-ever-session paste record (sent once, backend write-once)

    /// True only for the very first app session on this machine. Evaluated
    /// once per process; the stamp persists so later sessions are never
    /// mislabelled. Installs that existed before this feature shipped
    /// (hasLaunchedBefore already true) are disqualified — their first
    /// session is long gone and unknowable.
    static let isFirstSessionEver: Bool = {
        let d = UserDefaults.standard
        let alreadyStamped = d.object(forKey: "firstSessionStamp") != nil
        let isUpgradeInstall = d.bool(forKey: "hasLaunchedBefore")
        if !alreadyStamped {
            d.set(Date().timeIntervalSince1970, forKey: "firstSessionStamp")
        }
        return !alreadyStamped && !isUpgradeInstall
    }()

    /// Record a history paste (row index) during the first session ever.
    /// Stored locally forever; included in every usage payload — the
    /// backend only writes it once and ignores subsequent copies.
    func noteFirstSessionHistoryPaste(index: Int) {
        guard Self.isFirstSessionEver else { return }
        var record = UserDefaults.standard.dictionary(forKey: "firstSessionPastes") ?? [:]
        var indices = record["indices"] as? [Int] ?? []
        var ts      = record["ts"] as? [Double] ?? []
        let pastes  = (record["pastes"] as? Int ?? 0) + 1
        if indices.count < 20 {
            indices.append(index)
            ts.append(Date().timeIntervalSince1970)
        }
        record = ["pastes": pastes, "indices": indices, "ts": ts]
        UserDefaults.standard.set(record, forKey: "firstSessionPastes")
    }

    // MARK: - v2 payload assembly

    /// Split the flat "prefix.name" counters accumulated all day into the
    /// deep groups the backend stores under daily_counts.<date>. Anything
    /// unprefixed (real tool IDs + legacy action.* IDs) stays in
    /// tool_usage_counts exactly as v1 clients send it.
    private static let metricPrefixToGroup: [String: String] = [
        "popup.":   "popup",
        "capture.": "captures",
        "ref.":     "reference",
        "pidx.":    "paste_index_buckets",
        "page.":    "paste_age_buckets",
        "setting.": "settings_changes",
        "fail.":    "failures",
    ]

    /// Nicer stored names for popup/reference counter suffixes (sums keep
    /// an explicit _sum so nobody mistakes them for averages).
    private static let metricKeyRenames: [String: String] = [
        "popup.open": "opens", "popup.abandon": "abandons",
        "popup.dur_ms": "duration_ms_sum", "popup.nav": "items_navigated_sum",
        "ref.pin": "pins", "ref.open": "opens", "ref.badge_click": "badge_clicks",
        "ref.auto_surface": "auto_surfaces", "ref.auto_collapse": "auto_collapses",
        "ref.note_edit": "note_edits", "ref.view_ms": "view_ms_sum",
    ]

    private func sendDailyUsage(date: String, counts: [String: Int]) {
        guard !usageSendsInFlight.contains(date) else { return }
        usageSendsInFlight.insert(date)

        var toolCounts = counts
        let cmdVCount = toolCounts.removeValue(forKey: Self.cmdVBucketToolID) ?? 0

        // Route the deep-metric counters out of the tools dict into their
        // groups. Unrecognized IDs stay in tools — same as always.
        var groups: [String: [String: Int]] = [:]
        for (id, value) in toolCounts {
            guard let prefix = Self.metricPrefixToGroup.keys.first(where: { id.hasPrefix($0) }),
                  let group = Self.metricPrefixToGroup[prefix] else { continue }
            toolCounts.removeValue(forKey: id)
            let key = Self.metricKeyRenames[id] ?? String(id.dropFirst(prefix.count))
            groups[group, default: [:]][key, default: 0] += value
        }
        // Fold selected pre-existing action counters into their natural
        // group as well — they ALSO stay in tools for dashboard continuity.
        if let searches = toolCounts["action.popup-search"] {
            groups["popup", default: [:]]["searches", default: 0] += searches
        }
        if let pins = toolCounts["action.reference-pin"] {
            groups["reference", default: [:]]["pins", default: 0] += pins
        }

        // 90s timeout, not 8: the backend runs on Render's free tier, which
        // spins the service down when idle — a cold start takes 30-60s before
        // the first response. 8s guaranteed the first ping after any idle
        // period timed out (though it still woke the service, so the NEXT
        // retry succeeded). This is a background call; nothing blocks on it.
        var request = URLRequest(url: Self.usageBaseURL.appendingPathComponent("clipen/usage"),
                                  timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "install_key": DeviceIdentity.installKey,
            "date": date,
            "cmd_v_count": cmdVCount,
            "tool_usage_counts": toolCounts,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "schema_version": 2,
        ]
        // Deep per-day groups (only the non-empty ones).
        for (group, dict) in groups where !dict.isEmpty {
            body[group] = dict
        }
        // Point-in-time state — the backend keeps the latest copy at the
        // document level (not per day).
        let m = ClipboardManager.shared
        body["snapshot"] = [
            "history_size":       m.items.count,
            "pinned_items":       m.items.filter(\.isPinned).count,
            "ring_size":          m.maxItems,
            "second_tap":         m.openOnSecondTap,
            "always_preview":     m.alwaysShowItemPreview,
            "advance_after_mark": m.advanceAfterMark,
            "remember_last":      m.rememberLastSelection,
            "auto_dismiss":       m.autoDismissEnabled,
            "auto_dismiss_s":     Int(m.autoDismissSeconds),
            "open_delay_ms":      Int(m.firstOpenDelay * 1000),
            "reverse_key":        m.reverseCycleUsesB ? "B" : "shiftV",
            "capture_rich":       m.captureRichText,
            "capture_files":      m.captureFiles,
        ] as [String: Any]
        // First-ever-session paste record, if this install has one — the
        // backend writes it once and ignores every later copy.
        if let firstSession = UserDefaults.standard.dictionary(forKey: "firstSessionPastes") {
            body["first_session"] = firstSession
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.usageSendsInFlight.remove(date)
                guard error == nil,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else { return }
                // The backend answers 200 with `"recorded": false` when its
                // database isn't configured — HTTP success alone is NOT
                // proof the counts were stored. Clearing local data on a
                // recorded:false response would permanently lose that day.
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["recorded"] as? Bool == true else { return }
                self.removeSentDailyUsage(date: date, toolIDs: Array(counts.keys))
            }
        }.resume()
    }

    private func removeSentDailyUsage(date: String, toolIDs: [String]) {
        var raw = dailyUsageRaw()
        for toolID in toolIDs { raw.removeValue(forKey: "\(date)|\(toolID)") }
        UserDefaults.standard.set(raw, forKey: dailyUsageKey)
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
        // Deliberately NOT calling registerCommandVAction() here: fastPasteFront
        // continues into commitPaste → simulatePaste, which registers the ⌘V —
        // registering here too counted every fast paste TWICE in the daily
        // cmd_v numbers (and double-ran the update-check throttle).
    }

    var fastPasteCount: Int {
        UserDefaults.standard.integer(forKey: fastPasteCountKey)
    }

    /// Count a UI action (mark, prev, move-to-front, search, reference pin,
    /// similar items…) in the daily usage ping. Deliberately does NOT feed
    /// the frequency/recency/bucket dictionaries — those drive
    /// toolImportanceScore for ranking real transform tools, and action
    /// counts in the shared bucket denominators would dilute that ranking.
    /// Sent to the backend inside the same tool_usage_counts dict, under
    /// "action."-prefixed IDs.
    func registerActionUsage(actionID: String, count: Int = 1) {
        guard !actionID.isEmpty, count > 0 else { return }
        incrementDailyUsage(toolID: actionID, count: count, date: Self.dateKey(for: Date()))
    }

    /// Track per-tool usage deltas locally; flushed on the next backend
    /// refresh call so we can attribute usage to a stable `install_key`.
    func registerToolUsage(toolID: String, count: Int = 1) {
        guard !toolID.isEmpty, count > 0 else { return }
        let now = Date()
        let bucket = currentTimeBucket(for: now)
        incrementDailyUsage(toolID: toolID, count: count, date: Self.dateKey(for: now))

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
        let sparkleAutomaticChecks = sparkleAutomaticChecks

        DispatchQueue.main.async {
            // This used to also force captureRichText / fetchURLTitles /
            // captureFiles to the hard-coded flag values — silently stomping
            // the user's own persisted preference toggles on every launch.
            // Those are user settings; the "backend flags" for them are gone.
            ClipboardManager.shared.applyPlanLimits(ringLimit: ringLimit)
            AppDelegate.shared?.automaticallyChecksForUpdates = sparkleAutomaticChecks
        }
    }

}
