import AppKit
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
    /// Last remote-message `id` this install has dismissed — a message
    /// stays hidden once seen, even if the backend leaves it `enabled`,
    /// but a NEW `id` (a different message) shows again regardless.
    private let lastDismissedMessageIDKey  = "lastDismissedRemoteMessageID"
    /// The last LOCAL calendar day a heartbeat was successfully sent — so the
    /// unconditional daily "still alive" ping fires at most once per day even
    /// though its trigger (launch + the 30-min timer) runs far more often.
    private let lastHeartbeatDateKey       = "lastHeartbeatDate"
    /// Bounded lifetime set of LOCAL active days (yyyy-MM-dd), for the Habit /
    /// churn dimensions of the value profile. The daily-usage store can't serve
    /// this: it's an outbox pruned once a day is confirmed sent, so it only
    /// holds the recent unsent window. This is append-only, deduped, and capped
    /// so it can't grow without bound; one guarded write per NEW day, never per
    /// event (see noteActiveDayIfNeeded).
    private let lifetimeActiveDaysKey       = "clipenLifetimeActiveDays"
    private static let lifetimeActiveDaysCap = 400
    /// Process-lifetime guard so the once-per-day active-day write is attempted
    /// at most once per launch after it's confirmed present.
    private var todayMarkedActive = false

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
            self?.checkForRemoteMessage()
            self?.sendHeartbeatIfNeeded()
        }
        checkForRemoteMessage()
        sendHeartbeatIfNeeded()
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
    /// In-memory accumulator for daily-usage increments, flushed to
    /// UserDefaults on a coalesced schedule. The navigation path fires
    /// `registerActionUsage("popup.nav")` on every ⌘-held V press; the old
    /// implementation read the ENTIRE daily-usage dictionary out of
    /// UserDefaults, type-cast every entry, mutated one key, and serialized
    /// the whole dictionary back — an O(n) read + O(n) copy + full plist
    /// encode on the main thread, once (twice for ⇧V) per keystroke, in the
    /// latency-critical selection path. Increments now land here in O(1) and
    /// the expensive read-modify-write happens at most once every couple of
    /// seconds (plus on every ⌘V and on quit), off the keystroke path.
    private var pendingDailyUsage: [String: Int] = [:]
    private var dailyUsageFlushScheduled = false

    private func incrementDailyUsage(toolID: String, count: Int = 1, date: String) {
        guard !toolID.isEmpty, count > 0 else { return }
        pendingDailyUsage["\(date)|\(toolID)", default: 0] += count
        noteActiveDayIfNeeded()
        scheduleDailyUsageFlush()
    }

    /// Record today (local) in the bounded lifetime active-days set. O(1) after
    /// the first call of the day thanks to the in-memory guard; touches
    /// UserDefaults at most once per calendar day, never on the keystroke path
    /// after that. Every activity funnels through incrementDailyUsage, so this
    /// captures every day the app was actually used.
    private func noteActiveDayIfNeeded() {
        guard !todayMarkedActive else { return }
        let today = Self.dateKey(for: Date())
        var days = UserDefaults.standard.stringArray(forKey: lifetimeActiveDaysKey) ?? []
        if days.last == today { todayMarkedActive = true; return }
        if !days.contains(today) {
            days.append(today)
            if days.count > Self.lifetimeActiveDaysCap {
                days.removeFirst(days.count - Self.lifetimeActiveDaysCap)
            }
            UserDefaults.standard.set(days, forKey: lifetimeActiveDaysKey)
        }
        todayMarkedActive = true
    }

    private func scheduleDailyUsageFlush() {
        guard !dailyUsageFlushScheduled else { return }
        dailyUsageFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.dailyUsageFlushScheduled = false
            self?.flushPendingDailyUsage()
        }
    }

    /// Merge the in-memory increment buffer into the persisted dictionary in a
    /// single read-modify-write. Called on a short debounce, before any read
    /// of the authoritative daily-usage data (see `dailyUsageRaw`), and on app
    /// termination so a session ending mid-navigation doesn't drop counts.
    /// All callers are on the main thread, so `pendingDailyUsage` needs no
    /// locking.
    func flushPendingDailyUsage() {
        guard !pendingDailyUsage.isEmpty else { return }
        var counts = persistedDailyUsageRaw()
        for (k, v) in pendingDailyUsage { counts[k, default: 0] += v }
        pendingDailyUsage.removeAll(keepingCapacity: true)
        UserDefaults.standard.set(counts, forKey: dailyUsageKey)
    }

    /// Authoritative view of accumulated daily usage: flush the in-memory
    /// buffer first so senders and removers see every increment, then return
    /// the persisted store as the single source of truth.
    private func dailyUsageRaw() -> [String: Int] {
        flushPendingDailyUsage()
        return persistedDailyUsageRaw()
    }

    private func persistedDailyUsageRaw() -> [String: Int] {
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
        // Active-day/session marker — see registerActionUsage("session.open")
        // in pasteApp.swift. Its own group so "was the app used at all today"
        // is never confused with a specific in-app action.
        "session.": "session",
    ]

    /// Nicer stored names for popup/reference counter suffixes (sums keep
    /// an explicit _sum so nobody mistakes them for averages).
    private static let metricKeyRenames: [String: String] = [
        "popup.open": "opens", "popup.abandon": "abandons",
        "popup.dur_ms": "duration_ms_sum", "popup.nav": "items_navigated_sum",
        "ref.pin": "pins", "ref.open": "opens", "ref.badge_click": "badge_clicks",
        "ref.auto_surface": "auto_surfaces", "ref.auto_collapse": "auto_collapses",
        "ref.note_edit": "note_edits", "ref.view_ms": "view_ms_sum",
        // "opens" here means launches, i.e. sessions — this is what makes
        // active-days/sessions-per-day/retention computable server-side.
        "session.open": "opens",
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
            "always_preview":     !m.autoPreviewTypes.isEmpty,
            "advance_after_mark": m.advanceAfterMark,
            "remember_last":      m.rememberLastSelection,
            "auto_dismiss":       m.autoDismissEnabled,
            "auto_dismiss_s":     Int(m.autoDismissSeconds),
            "open_delay_ms":      Int(m.firstOpenDelay * 1000),
            "reverse_key":        m.reverseCycleUsesB ? "B" : "shiftV",
            "capture_rich":       m.captureRichText,
            "capture_files":      m.captureFiles,
        ] as [String: Any]
        // Mathematically-grounded behavioural profile (Habit/Dependency/
        // Workflow/Exploration/Friction + confidence/churn/interest), derived
        // on-device from already-collected local counters — a meaningful value
        // signal instead of leaving the backend to guess from raw event totals.
        body["value_profile"] = clipenValueProfile()
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

    // MARK: - Clipen Value Profile (behavioural dimensions, computed on-device)
    //
    // Raw event counts are a poor proxy for genuine product value: a user
    // pressing V twenty times can mean deep history reliance OR difficulty
    // finding an item (friction). This computes six orthogonal, bounded
    // behavioural dimensions from the counters already collected locally, so
    // the backend receives a mathematically defensible signal instead of
    // uninterpretable raw totals. It is a PURE function of already-persisted
    // data — no new information is gathered — and is versioned so a future
    // change to the math can be told apart server-side from old payloads.
    //
    //   P = [H, D, W, E, F]  (each in [0, 1])
    //     H  Habit        — recency-weighted repeated temporal return
    //     D  Dependency   — reliance on history depth beyond the front item
    //     W  Workflow     — breadth + intensity of advanced-feature use
    //     E  Exploration  — feature/settings discovery (deliberately small weight)
    //     F  Friction     — abandonment + failure signals
    //   plus confidence, churn risk, and (only because a scalar is sometimes
    //   wanted) a single shrunk Interest value.
    static let valueProfileFormulaVersion = 1

    /// yyyy-MM-dd → Date (local midnight). Cached formatter; keys are the ones
    /// `dateKey(for:)` writes, so parsing always succeeds.
    private static let dateKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Bayesian-smoothed proportion: (x + α) / (n + α + β). Pulls small-sample
    /// ratios toward the prior mean α/(α+β) instead of letting one event read
    /// as 0% or 100%.
    private static func smoothedRatio(_ x: Double, _ n: Double, alpha: Double, beta: Double) -> Double {
        (x + alpha) / (n + alpha + beta)
    }

    /// Heavy-tailed count → [0, 1] via log compression, so a power user with
    /// 10× the counts of a regular user doesn't score 10× (diminishing returns).
    private static func logNorm(_ x: Double, cap: Double) -> Double {
        guard x > 0, cap > 0 else { return 0 }
        return min(1, log1p(x) / log1p(cap))
    }

    /// The full behavioural profile, ready to embed in the usage snapshot.
    ///
    /// Dimensions are computed from the most STABLE source available for each,
    /// because the day|tool store is a pruned outbox (see dailyUsageRaw):
    ///   • Habit / churn / cohort   ← the lifetime active-days set (never pruned)
    ///   • ⌘V + fast-paste          ← lifetime counters (clickCountKey, fastPasteCountKey)
    ///   • Transform breadth        ← toolUsageTotals (lifetime)
    ///   • Friction / exploration   ← the recent unsent window (inherently recent signals)
    func clipenValueProfile(now: Date = Date()) -> [String: Any] {
        // Recent (unsent-window) counters — used only for signals that are
        // inherently about the present: friction, exploration, in-session depth.
        let raw = dailyUsageRaw()
        var recentByTool: [String: Int] = [:]
        for (compound, value) in raw where value > 0 {
            guard let sep = compound.firstIndex(of: "|") else { continue }
            recentByTool[String(compound[compound.index(after: sep)...]), default: 0] += value
        }
        func recent(_ id: String) -> Double { Double(recentByTool[id, default: 0]) }
        func recentPrefix(_ p: String) -> Double {
            recentByTool.reduce(0.0) { $0 + ($1.key.hasPrefix(p) ? Double($1.value) : 0) }
        }
        func recentDistinct(_ p: String) -> Int {
            recentByTool.reduce(0) { $0 + ($1.key.hasPrefix(p) && $1.value > 0 ? 1 : 0) }
        }

        let todayStart = Calendar.current.startOfDay(for: now)
        func ageDays(_ key: String) -> Double {
            guard let d = Self.dateKeyParser.date(from: key) else { return .infinity }
            return max(0, todayStart.timeIntervalSince(Calendar.current.startOfDay(for: d)) / 86_400)
        }

        // Lifetime active days (deduped, bounded) — the real basis for habit.
        let activeDates = Set(UserDefaults.standard.stringArray(forKey: lifetimeActiveDaysKey) ?? [])
        let activeDayCount = Double(activeDates.count)

        // Cohort age: the true first-session stamp, else the earliest active
        // day. A six-hour-old install cannot have 7-day retention — every rate
        // below is normalised against this so young cohorts aren't punished.
        let firstStamp = UserDefaults.standard.object(forKey: "firstSessionStamp") as? Double
        let earliestAge = activeDates.map(ageDays).filter { $0.isFinite }.max() ?? 0
        let accountAgeDays = max(firstStamp.map { max(0, todayStart.timeIntervalSince1970 - $0) / 86_400 } ?? 0,
                                 earliestAge)

        // Lifetime paste counters.
        let cmdVLifetime = Double(UserDefaults.standard.integer(forKey: clickCountKey))
        let fastPastes = Double(UserDefaults.standard.integer(forKey: fastPasteCountKey))

        // ── H — Habit ────────────────────────────────────────────────────
        // Smoothed active-day rate over the install's life (prior ≈ 0.2/day)…
        let activeDayRate = Self.smoothedRatio(activeDayCount, max(1, accountAgeDays),
                                               alpha: 1, beta: 4)
        // …plus a recency-weighted return density (14-day half-life): coming
        // back this week counts far more than a burst two months ago.
        let habitLambda = log(2.0) / 14.0
        let weightedActive = activeDates.reduce(0.0) { $0 + exp(-habitLambda * ageDays($1)) }
        let habitDensity = Self.logNorm(weightedActive, cap: 14)
        let H = min(1, 0.5 * activeDayRate + 0.5 * habitDensity)

        // ── D — History Dependency ───────────────────────────────────────
        // A fast paste is the front item with no popup; every other ⌘V went
        // through the ring deliberately. The popup-paste fraction is therefore
        // a clean LIFETIME reliance signal, smoothed toward a 0.15 prior.
        let popupPastes = max(0, cmdVLifetime - fastPastes)
        let dependencyRatio = Self.smoothedRatio(popupPastes, max(1, cmdVLifetime), alpha: 1, beta: 6)
        // Robust p90 selected depth from the recent paste-index buckets (pidx.*
        // is logged once per history paste, bucketed) — a weighted percentile,
        // never a raw max one outlier could spike.
        let depthBuckets: [(id: String, depth: Double)] = [
            ("pidx.0", 0), ("pidx.1", 1), ("pidx.2", 2), ("pidx.3", 3), ("pidx.4", 4),
            ("pidx.5_10", 7), ("pidx.11_50", 30), ("pidx.50p", 60),
        ]
        let pidxTotal = recentPrefix("pidx.")
        let p90Depth: Double = {
            guard pidxTotal > 0 else { return 0 }
            let threshold = 0.9 * pidxTotal
            var cumulative = 0.0
            for b in depthBuckets {
                cumulative += recent(b.id)
                if cumulative >= threshold { return b.depth }
            }
            return depthBuckets.last?.depth ?? 0
        }()
        let D = min(1, 0.7 * dependencyRatio + 0.3 * Self.logNorm(p90Depth, cap: 50))

        // ── W — Workflow Depth ───────────────────────────────────────────
        // Transform breadth/intensity is lifetime (toolUsageTotals); the other
        // advanced-feature families come from the recent window (they aren't
        // mirrored into lifetime totals). Breadth = how many families touched.
        let transformUses = Double(toolUsageTotals().values.reduce(0, +))
        let workflowFamilies: [Double] = [
            recent("action.preview"),
            recent("action.reference-pin") + recentPrefix("ref."),
            recent("action.mark"),
            transformUses,
            recent("action.popup-search") + recent("action.window-search"),
            recent("action.similar-items"),
            recent("action.share"),
        ]
        let familiesUsed = Double(workflowFamilies.filter { $0 > 0 }.count)
        let workflowBreadth = familiesUsed / Double(workflowFamilies.count)
        let workflowIntensity = Self.logNorm(workflowFamilies.reduce(0, +), cap: 120)
        let W = min(1, 0.6 * workflowBreadth + 0.4 * workflowIntensity)

        // ── E — Exploration ──────────────────────────────────────────────
        // Distinct settings touched + distinct action kinds tried. Capped and
        // given a SMALL Interest weight so novelty never poses as durable value.
        let distinctSettings = Double(recentDistinct("setting."))
        let distinctActions = Double(recentDistinct("action."))
        let E = min(1, Self.logNorm(distinctSettings + distinctActions, cap: 18))

        // ── F — Friction ─────────────────────────────────────────────────
        let opens = recent("popup.open")
        let abandons = recent("popup.abandon")
        let abandonRate = Self.smoothedRatio(abandons, max(1, opens), alpha: 1, beta: 4)
        let failTotal = recentPrefix("fail.")
        let failDenom = max(1, recent(Self.cmdVBucketToolID) + recentPrefix("capture."))
        let failRate = Self.logNorm(failTotal / failDenom * 100, cap: 100)
        // Oscillation: lots of navigation per open that ends in abandonment
        // reads as "couldn't find it"; only counts alongside abandonment.
        let navsPerOpen = opens > 0 ? recent("popup.nav") / opens : 0
        let oscillation = min(1, navsPerOpen / 25) * abandonRate
        let F = min(1, 0.55 * abandonRate + 0.30 * failRate + 0.15 * oscillation)

        // ── Confidence ───────────────────────────────────────────────────
        // Grows with lifetime observation volume; a handful of events can't
        // yield a confident verdict. τ = 60 reaches ~0.63.
        let observations = cmdVLifetime + transformUses + activeDayCount
        let confidence = 1 - exp(-observations / 60.0)

        // ── Interest (single shrunk scalar, only because one is sometimes
        // wanted) ─────────────────────────────────────────────────────────
        let wH = 0.30, wD = 0.30, wW = 0.25, wE = 0.05, wF = 0.20
        let rawInterest = max(0, min(1, wH * H + wD * D + wW * W + wE * E - wF * F))
        // Shrink toward a slightly-below-neutral prior at low confidence, so a
        // brand-new install reads as neither a power user nor a reject.
        let neutralPrior = 0.35
        let interest = confidence * rawInterest + (1 - confidence) * neutralPrior

        // ── Churn risk ───────────────────────────────────────────────────
        // Staleness of the most recent return (7-day half-life) dominates,
        // tempered by weak habit and active friction.
        let daysSinceActive = activeDates.map(ageDays).filter { $0.isFinite }.min() ?? accountAgeDays
        let recencyDecay = 1 - exp(-daysSinceActive / 7.0)
        let churn = max(0, min(1, 0.5 * recencyDecay + 0.3 * (1 - H) + 0.2 * F))

        func rnd(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        return [
            "formula_version": Self.valueProfileFormulaVersion,
            "habit": rnd(H),
            "dependency": rnd(D),
            "workflow": rnd(W),
            "exploration": rnd(E),
            "friction": rnd(F),
            "confidence": rnd(confidence),
            "interest": rnd(interest),
            "churn_risk": rnd(churn),
            "cohort_age_days": Int(accountAgeDays.rounded()),
            "active_days": Int(activeDayCount),
        ]
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

    // MARK: - Remote message (server-controlled, reaches installs without a new release)

    /// A message the backend can turn on for already-installed apps without
    /// shipping a new version — "please update," "payment now required,"
    /// or any one-off announcement. `enabled: false` is the off state;
    /// nothing is ever shown unless the backend explicitly turns a message
    /// on. Each unique `id` is shown at most once per install: dismissing
    /// it (the single button) hides that id forever, even if the backend
    /// leaves `enabled` true — sending a NEW message later just means
    /// picking a new `id`.
    private struct RemoteMessage: Decodable {
        let enabled: Bool
        let id: String
        let title: String
        let body: String
        let buttonLabel: String
    }

    /// Polled on the same cadence as the daily usage flush (once at launch,
    /// then every 30 minutes) — a PULL, not a push: no APNs, no extra
    /// infrastructure, just piggybacking on the check-in the app already
    /// makes. A message can therefore take up to that long to reach any
    /// given install after being enabled, not instantly.
    ///
    /// Expected backend contract — GET clipen/message, 200 with JSON body:
    ///   { "enabled": true, "id": "msg-2026-07-15",
    ///     "title": "...", "body": "...", "buttonLabel": "OK" }
    /// Any non-200, unparsable body, `enabled: false`, or already-dismissed
    /// `id` is treated as "nothing to show" and fails silently — this must
    /// never surface an error to the user; it's a best-effort announcement
    /// channel, not a critical path.
    func checkForRemoteMessage() {
        var request = URLRequest(url: Self.usageBaseURL.appendingPathComponent("clipen/message"),
                                  timeoutInterval: 20)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self,
                  error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let message = try? JSONDecoder().decode(RemoteMessage.self, from: data),
                  message.enabled, !message.id.isEmpty,
                  UserDefaults.standard.string(forKey: self.lastDismissedMessageIDKey) != message.id
            else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = message.title
                alert.informativeText = message.body
                alert.addButton(withTitle: message.buttonLabel.isEmpty ? "OK" : message.buttonLabel)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                UserDefaults.standard.set(message.id, forKey: self.lastDismissedMessageIDKey)
            }
        }.resume()
    }

    // MARK: - Daily liveness heartbeat ("still installed on this machine")

    /// An UNCONDITIONAL once-per-day "still alive" ping — the piece pure usage
    /// reporting can't give us. Usage counts only arrive when the user
    /// actually does something, so a silent day is ambiguous: installed-but-
    /// idle and uninstalled look identical. This ping fires every calendar
    /// day the app runs, regardless of activity, so the backend can tell
    /// "alive but not used today" (heartbeat present, zero usage) apart from
    /// "gone" (no heartbeat for a stretch of days).
    ///
    /// Deletion is never a POSITIVE signal — a removed app can't phone home,
    /// and macOS gives no uninstall callback — so the backend INFERS it from a
    /// trailing gap of missing heartbeats ("last seen alive on <date>"), never
    /// receives a delete event. Absence can also mean the Mac was off or
    /// offline that day; only sustained absence is a meaningful "gone" signal.
    ///
    /// Fires at launch and on the same 30-min timer as the usage flush, but
    /// dedupes to one send per LOCAL day via `lastHeartbeatDateKey`. Best-
    /// effort and silent, exactly like the usage flush and remote-message
    /// poll — it must never surface anything to the user.
    ///
    /// Expected backend contract — POST clipen/heartbeat, JSON body:
    ///   { "install_key": "...", "date": "yyyy-MM-dd", "alive": true,
    ///     "app_version": "...", "os_version": "..." }
    /// The local day-stamp is only advanced once the backend confirms
    /// `recorded: true` (same rule as the usage flush), so a failed/again-
    /// cold-started send is retried on the next tick instead of being lost.
    func sendHeartbeatIfNeeded() {
        let today = Self.dateKey(for: Date())
        guard UserDefaults.standard.string(forKey: lastHeartbeatDateKey) != today else { return }

        var request = URLRequest(url: Self.usageBaseURL.appendingPathComponent("clipen/heartbeat"),
                                  timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "install_key": DeviceIdentity.installKey,
            "date": today,
            "alive": true,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "schema_version": 1,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["recorded"] as? Bool == true
                else { return }
                UserDefaults.standard.set(today, forKey: self.lastHeartbeatDateKey)
            }
        }.resume()
    }

}
