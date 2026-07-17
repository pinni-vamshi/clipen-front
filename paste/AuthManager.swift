import AppKit
import Combine
import Foundation
import SwiftUI

// ============================================================================
// TrackingService — the ONE place all telemetry is collected, stored, and sent.
// Every other file reports events here (via the AuthManager façade below, so
// existing call sites keep working). Schema v3: one user row keyed by the
// hardware UUID, all daily data date-keyed, 150-day retention, no derived
// psychology scores.
// ============================================================================

final class TrackingService {
    static let shared = TrackingService()

    static let schemaVersion = 3
    static let retentionDays = 150
    private static let baseURL = URL(string: "https://clipen-backend.onrender.com")!

    // MARK: - Store

    struct DayData: Codable {
        var cmdVPastes = 0
        var fastPastes = 0
        var positions: [String: Int] = [:]      // exact popup index -> paste count
        var hours: [String: Int] = [:]          // hour of day -> paste count
        var toolUses: [String: Int] = [:]       // tool id (incl. share.*, ai.translate.<lang>) -> count
        var markedBatches: [String: [Int]] = [:]// marked tool id -> batch sizes
        var captures: [String: Int] = [:]       // capture type -> count
        var popup: [String: Int] = [:]          // opens/abandons/searches/nav/ms
        /// Every popup-open session classified into exactly one mutually
        /// exclusive outcome: pasted / deleted / escaped / blank (silent
        /// auto-dismiss timeout). Sums to `popup.opens` for the same date.
        var popupOutcomes: [String: Int] = [:]
        var actions: [String: Int] = [:]        // marked/deleted/pinned/previews/shares/...
        var settingsChanged: [String: Int] = [:]
        var failures: [String: Int] = [:]

        var isEmpty: Bool {
            cmdVPastes == 0 && fastPastes == 0 && positions.isEmpty && hours.isEmpty
                && toolUses.isEmpty && markedBatches.isEmpty && captures.isEmpty
                && popup.isEmpty && popupOutcomes.isEmpty && actions.isEmpty
                && settingsChanged.isEmpty && failures.isEmpty
        }

        init() {}

        // Manual Decodable: the Swift-synthesized decoder throws on any
        // missing key, even for properties with a default value — so adding
        // a field here (like popupOutcomes) would make every ALREADY-SAVED
        // tracking.json on disk fail to decode and silently reset to an
        // empty Store, losing unflushed local data. decodeIfPresent + `??`
        // makes every field here, and any added the same way in future,
        // backward-compatible with files written before it existed.
        enum CodingKeys: String, CodingKey {
            case cmdVPastes, fastPastes, positions, hours, toolUses, markedBatches,
                 captures, popup, popupOutcomes, actions, settingsChanged, failures
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cmdVPastes = try c.decodeIfPresent(Int.self, forKey: .cmdVPastes) ?? 0
            fastPastes = try c.decodeIfPresent(Int.self, forKey: .fastPastes) ?? 0
            positions = try c.decodeIfPresent([String: Int].self, forKey: .positions) ?? [:]
            hours = try c.decodeIfPresent([String: Int].self, forKey: .hours) ?? [:]
            toolUses = try c.decodeIfPresent([String: Int].self, forKey: .toolUses) ?? [:]
            markedBatches = try c.decodeIfPresent([String: [Int]].self, forKey: .markedBatches) ?? [:]
            captures = try c.decodeIfPresent([String: Int].self, forKey: .captures) ?? [:]
            popup = try c.decodeIfPresent([String: Int].self, forKey: .popup) ?? [:]
            popupOutcomes = try c.decodeIfPresent([String: Int].self, forKey: .popupOutcomes) ?? [:]
            actions = try c.decodeIfPresent([String: Int].self, forKey: .actions) ?? [:]
            settingsChanged = try c.decodeIfPresent([String: Int].self, forKey: .settingsChanged) ?? [:]
            failures = try c.decodeIfPresent([String: Int].self, forKey: .failures) ?? [:]
        }
    }

    struct Store: Codable {
        var firstSeen: String = ""
        var versions: [String: String] = [:]    // version -> first-seen date
        var days: [String: DayData] = [:]       // date -> data
        var toolTotals: [String: Int] = [:]
        var toolLastUsed: [String: Double] = [:]
        var toolBuckets: [String: Int] = [:]    // "toolID|weekday_morning" -> count (powers ranking)
        var globalBuckets: [String: Int] = [:]
        var totalPastes = 0
        var totalFastPastes = 0
        var activeDays: [String] = []
        var lastLivenessSent: String? = nil
    }

    private var store: Store
    private let lock = NSLock()
    private var persistScheduled = false
    private var sendInFlight = false

    private static var storeFileURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tracking.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.storeFileURL),
           let loaded = try? JSONDecoder().decode(Store.self, from: data) {
            store = loaded
        } else {
            store = Store()
            Self.importLegacyDefaults(into: &store)
        }
        let today = Self.dateKey(Date())
        if store.firstSeen.isEmpty { store.firstSeen = today }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        if store.versions[version] == nil { store.versions[version] = today }
        pruneOldDays()
        persistSoon()
    }

    // MARK: - Recording API

    func recordCmdV() {
        mutateToday { day in
            day.cmdVPastes += 1
            day.hours["\(Calendar.current.component(.hour, from: Date()))", default: 0] += 1
        }
        lock.lock(); store.totalPastes += 1; let total = store.totalPastes; lock.unlock()
        maybeTriggerUpdateCheck(totalPastes: total)
        persistSoon()
    }

    func recordFastPaste() {
        mutateToday { $0.fastPastes += 1 }
        lock.lock(); store.totalFastPastes += 1; lock.unlock()
        persistSoon()
    }

    /// Exact popup position the user pasted from (index 0 = front).
    func recordPastePosition(_ index: Int) {
        guard index >= 0 else { return }
        mutateToday { $0.positions["\(index)", default: 0] += 1 }
        persistSoon()
    }

    /// One call per popup session, at close time — `outcome` is one of
    /// "pasted", "deleted", "escaped", "blank" (see ClipboardManager+Search
    /// .dismissPreview, the single place this is called from).
    func recordPopupOutcome(_ outcome: String) {
        guard !outcome.isEmpty else { return }
        mutateToday { $0.popupOutcomes[outcome, default: 0] += 1 }
        persistSoon()
    }

    func recordToolUse(id: String, count: Int = 1) {
        guard !id.isEmpty, count > 0 else { return }
        let now = Date()
        let bucket = Self.timeBucket(for: now)
        mutateToday { $0.toolUses[id, default: 0] += count }
        lock.lock()
        store.toolTotals[id, default: 0] += count
        store.toolLastUsed[id] = now.timeIntervalSince1970
        store.toolBuckets["\(id)|\(bucket)", default: 0] += count
        store.globalBuckets[bucket, default: 0] += count
        lock.unlock()
        persistSoon()
    }

    /// Day-level variant counter that must NOT affect ranking totals
    /// (e.g. ai.translate.<lang> alongside the ranked ai.translate).
    func recordToolVariant(id: String) {
        guard !id.isEmpty else { return }
        mutateToday { $0.toolUses[id, default: 0] += 1 }
        persistSoon()
    }

    func recordMarkedBatch(id: String, size: Int) {
        guard !id.isEmpty, size > 0 else { return }
        mutateToday { $0.markedBatches[id, default: []].append(size) }
        persistSoon()
    }

    /// Router for the legacy string event IDs used across the codebase.
    func recordEvent(id: String, count: Int = 1) {
        guard !id.isEmpty, count > 0 else { return }
        mutateToday { Self.route(id: id, count: count, into: &$0) }
        persistSoon()
    }

    private static func route(id: String, count: Int, into day: inout DayData) {
        func suffix(_ prefix: String) -> String {
            String(id.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "_")
        }
        switch true {
        case id == "popup.open":            day.popup["opens", default: 0] += count
        case id == "popup.abandon":         day.popup["abandons", default: 0] += count
        case id == "popup.nav":             day.popup["nav", default: 0] += count
        case id == "popup.dur_ms":          day.popup["ms", default: 0] += count
        case id == "action.popup-search":   day.popup["searches", default: 0] += count
        case id == "action.mark":           day.actions["marked", default: 0] += count
        case id == "action.delete":         day.actions["deleted", default: 0] += count
        case id == "action.pin":            day.actions["pinned", default: 0] += count
        case id == "action.preview":        day.actions["previews", default: 0] += count
        case id == "action.share":          day.actions["shares", default: 0] += count
        case id == "action.front":          day.actions["move_front", default: 0] += count
        case id == "action.reference-pin":  day.actions["quickclip_pins", default: 0] += count
        case id.hasPrefix("action."):       day.actions[suffix("action."), default: 0] += count
        case id.hasPrefix("ref."):          day.actions["quickclip_" + suffix("ref."), default: 0] += count
        case id == "session.open":          day.actions["session_opens", default: 0] += count
        case id.hasPrefix("capture."):      day.captures[suffix("capture."), default: 0] += count
        case id.hasPrefix("setting."):      day.settingsChanged[suffix("setting."), default: 0] += count
        case id.hasPrefix("fail."):         day.failures[suffix("fail."), default: 0] += count
        case id.hasPrefix("pidx."):         day.positions[legacyPositionKey(suffix("pidx.")), default: 0] += count
        case id.hasPrefix("page."):         break // paste-age buckets: dropped in v3
        default:                            day.actions[id.replacingOccurrences(of: ".", with: "_"), default: 0] += count
        }
    }

    private static func legacyPositionKey(_ bucket: String) -> String {
        switch bucket {
        case "5_10":  return "5"
        case "11_50": return "11"
        case "50p":   return "50"
        default:      return bucket
        }
    }

    // MARK: - Ranking inputs (read by AuthManager.toolImportanceScore)

    func rankingInputs() -> (totals: [String: Int], lastUsed: [String: Double],
                             toolBuckets: [String: Int], globalBuckets: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (store.toolTotals, store.toolLastUsed, store.toolBuckets, store.globalBuckets)
    }

    var totalFastPastes: Int {
        lock.lock(); defer { lock.unlock() }
        return store.totalFastPastes
    }

    // MARK: - Day bookkeeping

    private func mutateToday(_ change: (inout DayData) -> Void) {
        let today = Self.dateKey(Date())
        lock.lock()
        var day = store.days[today] ?? DayData()
        change(&day)
        store.days[today] = day
        if store.activeDays.last != today, !store.activeDays.contains(today) {
            store.activeDays.append(today)
            if store.activeDays.count > 400 {
                store.activeDays.removeFirst(store.activeDays.count - 400)
            }
        }
        lock.unlock()
    }

    private func pruneOldDays() {
        let cutoff = Self.dateKey(Date().addingTimeInterval(-Double(Self.retentionDays) * 86_400))
        lock.lock()
        store.days = store.days.filter { $0.key >= cutoff }
        lock.unlock()
    }

    // MARK: - Persistence

    func persistNow() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.storeFileURL, options: .atomic)
    }

    private func persistSoon() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            DispatchQueue.global(qos: .utility).async { self.persistNow() }
        }
    }

    // MARK: - Sending (schema v3: whole-user payload, completed days only)

    func flushToBackend() {
        guard !sendInFlight else { return }
        pruneOldDays()
        let today = Self.dateKey(Date())

        lock.lock()
        let pendingDays = store.days.filter { $0.key < today && !$0.value.isEmpty }
        let liveness = store.lastLivenessSent
        lock.unlock()

        if pendingDays.isEmpty && liveness == today { return }

        var daysJSON: [String: Any] = [:]
        for (date, day) in pendingDays {
            var d: [String: Any] = [:]
            if day.cmdVPastes > 0 { d["cmd_v"] = day.cmdVPastes }
            if day.fastPastes > 0 { d["fast"] = day.fastPastes }
            if !day.positions.isEmpty { d["positions"] = day.positions }
            if !day.hours.isEmpty { d["hours"] = day.hours }
            if !day.toolUses.isEmpty { d["tool_uses"] = day.toolUses }
            if !day.markedBatches.isEmpty { d["marked_batches"] = day.markedBatches }
            if !day.captures.isEmpty { d["captures"] = day.captures }
            if !day.popup.isEmpty { d["popup"] = day.popup }
            if !day.popupOutcomes.isEmpty { d["popup_outcomes"] = day.popupOutcomes }
            if !day.actions.isEmpty { d["actions"] = day.actions }
            if !day.settingsChanged.isEmpty { d["settings_changed"] = day.settingsChanged }
            if !day.failures.isEmpty { d["failures"] = day.failures }
            daysJSON[date] = d
        }

        lock.lock()
        let body: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "uuid": DeviceIdentity.installKey,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "first_seen": store.firstSeen,
            "versions": store.versions,
            "settings": Self.settingsSnapshot(),
            "lifetime": [
                "total_pastes": store.totalPastes,
                "total_fast_pastes": store.totalFastPastes,
                "active_days": store.activeDays.count,
                "history_size": ClipboardManager.shared.items.count,
                "pinned_now": ClipboardManager.shared.items.filter(\.isPinned).count,
                "tool_totals": store.toolTotals,
                "tool_last_used": store.toolLastUsed.mapValues { Self.dateKey(Date(timeIntervalSince1970: $0)) },
            ] as [String: Any],
            "days": daysJSON,
        ]
        lock.unlock()

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("clipen/usage"),
                                 timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        sendInFlight = true
        let sentDates = Array(pendingDays.keys)
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                self.sendInFlight = false
                guard error == nil,
                      let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["recorded"] as? Bool == true else { return }
                self.lock.lock()
                for date in sentDates { self.store.days.removeValue(forKey: date) }
                self.store.lastLivenessSent = today
                self.lock.unlock()
                DispatchQueue.global(qos: .utility).async { self.persistNow() }
            }
        }.resume()
    }

    /// Current value of every user-facing setting, one key per setting.
    /// Must be called on the main thread (reads live UI state).
    private static func settingsSnapshot() -> [String: Any] {
        let m = ClipboardManager.shared
        return [
            "open_delay_ms":           Int(m.firstOpenDelay * 1000),
            "advance_after_mark":      m.advanceAfterMark,
            "pure_paste_default":      m.pastePlainTextByDefault,
            "always_preview_types":    m.autoPreviewTypes.map(\.rawValue).sorted(),
            "auto_dismiss":            m.autoDismissEnabled,
            "auto_dismiss_seconds":    Int(m.autoDismissSeconds),
            "ring_length":             m.maxItems,
            "reverse_key":             m.reverseCycleUsesB ? "B" : "shiftV",
            "open_on_second_tap":      m.openOnSecondTap,
            "capture_rich_text":       m.captureRichText,
            "capture_files":           m.captureFiles,
            "fetch_url_titles":        m.fetchURLTitles,
            "show_color_swatches":     m.showColorSwatches,
            "reference_app_affinity":  m.referenceAppAffinityEnabled,
            "remember_last_position":  m.rememberLastSelection,
            "remember_last_timeout_min": m.rememberLastPositionTimeoutMinutes,
            "pin_start_position":      m.pinStartPosition,
            "mark_hold_speed":         m.markHoldSpeed.rawValue,
            "pin_hold_speed":          m.pinHoldSpeed.rawValue,
            "space_double_tap_speed":  m.spaceDoubleTapSpeed.rawValue,
            "pinned_open_hold_speed":  m.pinnedOpenHoldSpeed.rawValue,
            "launch_at_login":         m.launchAtLoginEnabled,
            "auto_update_check":       AppDelegate.shared?.automaticallyChecksForUpdates ?? true,
            "auto_update_download":    AppDelegate.shared?.automaticallyDownloadsUpdates ?? false,
            "onboarding_step":         UserDefaults.standard.integer(forKey: "popupCoachStep"),
        ]
    }

    // MARK: - Remote message (the one non-telemetry backend call, kept here
    // so this file remains the only network surface)

    private struct RemoteMessage: Decodable {
        let enabled: Bool
        let id: String
        let title: String
        let body: String
        let buttonLabel: String
    }

    func checkForRemoteMessage() {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("clipen/message"),
                                 timeoutInterval: 20)
        request.httpMethod = "GET"
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data,
                  let message = try? JSONDecoder().decode(RemoteMessage.self, from: data),
                  message.enabled, !message.id.isEmpty,
                  UserDefaults.standard.string(forKey: "lastDismissedRemoteMessageID") != message.id
            else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = message.title
                alert.informativeText = message.body
                alert.addButton(withTitle: message.buttonLabel.isEmpty ? "OK" : message.buttonLabel)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                UserDefaults.standard.set(message.id, forKey: "lastDismissedRemoteMessageID")
            }
        }.resume()
    }

    // MARK: - Update-check cadence (every N pastes, unchanged behaviour)

    private func maybeTriggerUpdateCheck(totalPastes: Int) {
        let d = UserDefaults.standard
        let last = d.integer(forKey: "lastUpdateCheckAtPasteCount")
        if totalPastes - last >= AuthManager.shared.updateCheckEveryClicks {
            d.set(totalPastes, forKey: "lastUpdateCheckAtPasteCount")
            AppDelegate.shared?.checkForUpdatesInBackgroundIfAllowed()
        }
    }

    // MARK: - One-time migration from the old scattered UserDefaults keys

    private static func importLegacyDefaults(into store: inout Store) {
        let d = UserDefaults.standard

        store.totalPastes = d.integer(forKey: "backendFeatureFlagsClickCount")
        store.totalFastPastes = d.integer(forKey: "backendFastPasteCount")
        store.activeDays = d.stringArray(forKey: "clipenLifetimeActiveDays") ?? []
        if let stamp = d.object(forKey: "firstSessionStamp") as? Double {
            store.firstSeen = dateKey(Date(timeIntervalSince1970: stamp))
        } else if let earliest = store.activeDays.first {
            store.firstSeen = earliest
        }

        if let totals = d.dictionary(forKey: "backendToolUsageTotals") {
            for (k, v) in totals { if let n = v as? NSNumber, n.intValue > 0 { store.toolTotals[k] = n.intValue } }
        }
        if let lastUsed = d.dictionary(forKey: "backendToolLastUsedAt") {
            for (k, v) in lastUsed { if let n = v as? NSNumber, n.doubleValue > 0 { store.toolLastUsed[k] = n.doubleValue } }
        }
        if let buckets = d.dictionary(forKey: "backendToolBucketUsage") {
            for (k, v) in buckets { if let n = v as? NSNumber, n.intValue > 0 { store.toolBuckets[k] = n.intValue } }
        }
        if let global = d.dictionary(forKey: "backendGlobalBucketUsage") {
            for (k, v) in global { if let n = v as? NSNumber, n.intValue > 0 { store.globalBuckets[k] = n.intValue } }
        }

        // Unsent old-format day data: "date|eventID" -> count
        if let raw = d.dictionary(forKey: "backendDailyUsageByDateTool") {
            for (compound, v) in raw {
                guard let n = v as? NSNumber, n.intValue > 0,
                      let sep = compound.firstIndex(of: "|") else { continue }
                let date = String(compound[compound.startIndex..<sep])
                let id = String(compound[compound.index(after: sep)...])
                var day = store.days[date] ?? DayData()
                if id == "__cmdv__" {
                    day.cmdVPastes += n.intValue
                } else if id.hasPrefix("text.") || id.hasPrefix("image.") || id.hasPrefix("pdf.")
                            || id.hasPrefix("file.") || id.hasPrefix("media.") || id.hasPrefix("video.")
                            || id.hasPrefix("ai.") || id.hasPrefix("marked.") || id.hasPrefix("share.") {
                    day.toolUses[id, default: 0] += n.intValue
                } else {
                    route(id: id, count: n.intValue, into: &day)
                }
                store.days[date] = day
            }
        }

        for key in ["backendFeatureFlagsClickCount", "backendFastPasteCount",
                    "backendFeatureFlagsLastUpdateCheckClick", "backendToolUsageTotals",
                    "backendToolLastUsedAt", "backendToolBucketUsage",
                    "backendGlobalBucketUsage", "backendDailyUsageByDateTool",
                    "lastHeartbeatDate", "firstSessionPastes"] {
            d.removeObject(forKey: key)
        }
    }

    // MARK: - Helpers

    static func dateKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func timeBucket(for date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let weekday = calendar.component(.weekday, from: date)
        let dayType = (weekday == 1 || weekday == 7) ? "weekend" : "weekday"
        let part: String
        switch hour {
        case 0..<6:   part = "night"
        case 6..<12:  part = "morning"
        case 12..<18: part = "afternoon"
        default:      part = "evening"
        }
        return "\(dayType)_\(part)"
    }
}

// ============================================================================
// AuthManager — slim façade. Feature flags + the legacy tracking API surface,
// all forwarding into TrackingService so no call site elsewhere changes.
// ============================================================================

final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    let transformsEnabled  = true
    let semanticSearch     = true
    let ocrEnabled         = true
    let pdfTextExtract     = true
    let ringLimit          = 500

    let maxDataBytes: Int            = 500 * 1024 * 1024
    let sparkleAutomaticChecks: Bool = true
    let updateCheckEveryClicks: Int  = 50

    @Published var lastError: String? = nil
    func clearError() { lastError = nil }

    private var flushTimer: Timer?

    private init() {
        DispatchQueue.main.async {
            ClipboardManager.shared.applyPlanLimits(ringLimit: self.ringLimit)
            AppDelegate.shared?.automaticallyChecksForUpdates = self.sparkleAutomaticChecks
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { _ in
            DispatchQueue.main.async {
                TrackingService.shared.flushToBackend()
                TrackingService.shared.checkForRemoteMessage()
            }
        }
        DispatchQueue.main.async {
            TrackingService.shared.flushToBackend()
            TrackingService.shared.checkForRemoteMessage()
        }
    }

    static let isFirstSessionEver: Bool = {
        let d = UserDefaults.standard
        let alreadyStamped = d.object(forKey: "firstSessionStamp") != nil
        let isUpgradeInstall = d.bool(forKey: "hasLaunchedBefore")
        if !alreadyStamped {
            d.set(Date().timeIntervalSince1970, forKey: "firstSessionStamp")
        }
        return !alreadyStamped && !isUpgradeInstall
    }()

    // MARK: Legacy API surface — forwards into TrackingService

    func registerCommandVAction() {
        TrackingService.shared.recordCmdV()
    }

    func registerFastPasteAction() {
        TrackingService.shared.recordFastPaste()
    }

    func registerActionUsage(actionID: String, count: Int = 1) {
        TrackingService.shared.recordEvent(id: actionID, count: count)
    }

    func registerToolUsage(toolID: String, count: Int = 1) {
        TrackingService.shared.recordToolUse(id: toolID, count: count)
    }

    var fastPasteCount: Int {
        TrackingService.shared.totalFastPastes
    }

    func flushPendingDailyUsage() {
        TrackingService.shared.persistNow()
    }

    // MARK: Tool ranking (in-app feature, not telemetry — reads the same store)

    func toolImportanceScore(for toolID: String, now: Date = Date()) -> Double {
        let inputs = TrackingService.shared.rankingInputs()
        let totalCount = Double(inputs.totals[toolID, default: 0])
        guard totalCount > 0 else { return 0 }

        let frequency = min(log1p(totalCount) / 5.0, 1.0)

        let lastUsedEpoch = inputs.lastUsed[toolID] ?? 0
        let recency: Double = {
            guard lastUsedEpoch > 0 else { return 0 }
            let ageHours = max(0, (now.timeIntervalSince1970 - lastUsedEpoch) / 3600.0)
            let tauHours = 24.0 * 7.0
            return exp(-ageHours / tauHours)
        }()

        let bucket = TrackingService.timeBucket(for: now)
        let toolBucketCount = Double(inputs.toolBuckets["\(toolID)|\(bucket)", default: 0])
        let bucketTotal = Double(inputs.globalBuckets[bucket, default: 0])
        let distinctTools = Double(max(1, inputs.totals.count))
        let alpha = 1.0
        let timeAffinity = (toolBucketCount + alpha) / (bucketTotal + alpha * distinctTools)

        return (0.45 * frequency) + (0.35 * recency) + (0.20 * timeAffinity)
    }
}
