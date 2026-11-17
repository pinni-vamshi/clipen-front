import AppKit
import Combine
import FirebaseAnalytics
import Foundation
import SwiftUI

final class TrackingService {
    static let shared = TrackingService()

    static let schemaVersion = 3
    static let retentionDays = 150

    static let flushDelayDays = 0
    /// How often unsent usage goes to the backend. See AuthManager.init.
    static let flushInterval: TimeInterval = 3 * 60 * 60
    // Internal, not private: ProGate.swift's /clipen/entitlement call shares
    // this same backend host — previously a second copy-pasted URL literal.
    static let baseURL = URL(string: "https://clipen-backend.onrender.com")!

    struct DayData: Codable {
        var cmdVPastes = 0
        var fastPastes = 0
        var positions: [String: Int] = [:]
        var hours: [String: Int] = [:]
        var toolUses: [String: Int] = [:]
        var markedBatches: [String: [Int]] = [:]
        var captures: [String: Int] = [:]
        var popup: [String: Int] = [:]

        var popupDurationsMs: [Int] = []

        var popupOutcomes: [String: Int] = [:]
        var actions: [String: Int] = [:]
        var settingsChanged: [String: Int] = [:]

        var settingValues: [String: [Int]] = [:]
        var failures: [String: Int] = [:]

        var isEmpty: Bool {
            cmdVPastes == 0 && fastPastes == 0 && positions.isEmpty && hours.isEmpty
                && toolUses.isEmpty && markedBatches.isEmpty && captures.isEmpty
                && popup.isEmpty && popupDurationsMs.isEmpty && popupOutcomes.isEmpty
                && actions.isEmpty && settingsChanged.isEmpty && settingValues.isEmpty && failures.isEmpty
        }

        init() {}

        enum CodingKeys: String, CodingKey {
            case cmdVPastes, fastPastes, positions, hours, toolUses, markedBatches,
                 captures, popup, popupDurationsMs, popupOutcomes, actions,
                 settingsChanged, settingValues, failures
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
            popupDurationsMs = try c.decodeIfPresent([Int].self, forKey: .popupDurationsMs) ?? []
            popupOutcomes = try c.decodeIfPresent([String: Int].self, forKey: .popupOutcomes) ?? [:]
            actions = try c.decodeIfPresent([String: Int].self, forKey: .actions) ?? [:]
            settingsChanged = try c.decodeIfPresent([String: Int].self, forKey: .settingsChanged) ?? [:]
            settingValues = try c.decodeIfPresent([String: [Int]].self, forKey: .settingValues) ?? [:]
            failures = try c.decodeIfPresent([String: Int].self, forKey: .failures) ?? [:]
        }
    }

    struct Store: Codable {
        var firstSeen: String = ""
        var versions: [String: String] = [:]
        var days: [String: DayData] = [:]
        var toolTotals: [String: Int] = [:]
        var toolLastUsed: [String: Double] = [:]
        var toolBuckets: [String: Int] = [:]
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

    func recordCmdV(position: Int? = nil, markedCount: Int? = nil, markedPositions: [Int]? = nil) {
        mutateToday { day in
            day.cmdVPastes += 1
            day.hours["\(Calendar.current.component(.hour, from: Date()))", default: 0] += 1
            if let position, position >= 0 {
                day.positions["\(position)", default: 0] += 1
            }
        }
        lock.lock(); store.totalPastes += 1; let total = store.totalPastes; lock.unlock()
        maybeTriggerUpdateCheck(totalPastes: total)

        // Counted above and reported in `usage_summary`, not sent one
        // request per paste. See `isRealtime`.
        if let markedCount, markedCount > 1 {
            mutateToday { $0.actions["multi_paste", default: 0] += 1 }
        }
        _ = markedPositions
        persistSoon()
    }

    func recordFastPaste() {
        mutateToday { $0.fastPastes += 1 }
        lock.lock(); store.totalFastPastes += 1; lock.unlock()
        persistSoon()
    }

    func recordPastePosition(_ index: Int) {
        guard index >= 0 else { return }
        mutateToday { $0.positions["\(index)", default: 0] += 1 }
        persistSoon()
    }

    func recordPopupDuration(ms: Int) {
        guard ms >= 0 else { return }
        mutateToday { $0.popupDurationsMs.append(ms) }
        persistSoon()
    }

    func recordPopupOutcome(_ outcome: String) {
        guard !outcome.isEmpty else { return }
        mutateToday { $0.popupOutcomes[outcome, default: 0] += 1 }
        persistSoon()
    }

    func recordToolUse(id: String, count: Int = 1, via: String? = nil) {
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
        _ = via   // the tool is counted per id; how it was reached isn't kept
        persistSoon()
    }

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

    func recordSettingValue(id: String, value: Int) {
        guard !id.isEmpty else { return }
        mutateToday { $0.settingValues[id, default: []].append(value) }
        Analytics.logEvent("setting_value_changed", parameters: ["setting": id, "last_value": value])
        PostHogTracking.capture("setting_value_changed", properties: ["setting": id, "last_value": value])
        persistSoon()
    }

    func recordEvent(id: String, count: Int = 1, value: CustomStringConvertible? = nil,
                     extraProperties: [String: Any] = [:]) {
        guard !id.isEmpty, count > 0 else { return }
        mutateToday { Self.route(id: id, count: count, into: &$0) }
        Self.logToFirebaseAnalytics(id: id, count: count, value: value, extraProperties: extraProperties)
        persistSoon()
    }

    /// Single source of truth for both analytics destinations — computes
    /// the (event name, properties) once, then fires Firebase and PostHog
    /// from the same result, so the two can never drift out of sync with
    /// each other the way two separately-maintained switch statements
    /// eventually would.
    ///
    /// app_version/os_version are stamped here, on every event this path
    /// sends — previously only `syncPersonPropertiesToPostHog` set those,
    /// as PERSON properties, meaning `person.properties.app_version` on an
    /// event reflects whatever that person's version was at the time of
    /// ingestion (a real but looser signal), while `properties.app_version`
    /// on the event itself was always absent. Stamping directly on the
    /// event lets PostHog filter/breakdown by version with no indirection.
    private static func logToFirebaseAnalytics(id: String, count: Int, value: CustomStringConvertible? = nil,
                                               extraProperties: [String: Any] = [:]) {
        guard isRealtime(id: id),
              var (event, properties) = analyticsEvent(for: id, count: count) else { return }
        if let value { properties["value"] = value.description }
        for (k, v) in extraProperties { properties[k] = v }
        properties["app_version"] = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        properties["os_version"] = ProcessInfo.processInfo.operatingSystemVersionString
        Analytics.logEvent(event, parameters: properties)
        PostHogTracking.capture(event, properties: properties)
    }

    /// Whether an event is sent the moment it happens. Only rare events that
    /// matter on their own are: a setting changed, a failure, onboarding,
    /// the paywall, an update, a collection or group made. Everything a
    /// user does many times a minute (copies, pastes, popup opens, every
    /// arrow, mark and preview, the Reference panel following app switches)
    /// was one PostHog request plus one Firebase event per keystroke. Those
    /// are counted in today's totals and reported in `usage_summary`, a
    /// handful of events a day instead of hundreds.
    static func isRealtime(id: String) -> Bool {
        if id.hasPrefix("setting.") || id.hasPrefix("fail.") { return true }
        let realtimeActions: Set<String> = [
            "action.paywall_shown", "action.paywall_subscribe_click", "action.trial_exhausted",
            "action.accessibility-granted", "action.accessibility-not-granted",
            "action.sparkle_update_confirmed", "action.sparkle_update_installed",
            "action.onboarding-started", "action.onboarding-completed-tips-on",
            "action.onboarding-completed-tips-off",
            "action.collection-create", "action.collection-delete", "action.collection-rename",
            "action.collection-share", "action.collection-move",
            "action.group", "action.ungroup",
            "action.ai-prompt-edited", "action.ai-prompt-reset", "action.regenerate-all",
            "action.details-routed-to-ai-settings",
        ]
        if realtimeActions.contains(id) { return true }
        return id.hasPrefix("action.onboarding-abandoned-page-") || id.hasPrefix("action.onboarding-demo-")
    }

    private static func analyticsEvent(for id: String, count: Int) -> (String, [String: Any])? {
        func suffix(_ prefix: String) -> String {
            String(id.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "_")
        }
        switch true {
        case id == "popup.open":
            return ("popup_opened", ["count": count])
        case id == "popup.abandon", id == "popup.nav":
            return nil
        case id == "action.popup-search":
            return ("popup_search", ["count": count])
        case id == "action.mark":
            return ("action", ["action": "marked", "count": count])
        case id == "action.delete":
            return ("action", ["action": "deleted", "count": count])
        case id == "action.pin":
            return ("action", ["action": "pinned", "count": count])
        case id == "action.preview":
            return ("action", ["action": "previews", "count": count])
        case id == "action.share":
            return ("action", ["action": "shares", "count": count])
        case id == "action.front":
            return ("action", ["action": "move_front", "count": count])
        case id == "action.reference-pin":
            return ("action", ["action": "quickclip_pins", "count": count])
        case id.hasPrefix("action."):
            return ("action", ["action": suffix("action."), "count": count])
        case id.hasPrefix("ref."):
            return ("action", ["action": "quickclip_" + suffix("ref."), "count": count])
        case id == "session.open":
            return ("action", ["action": "session_opens", "count": count])
        case id.hasPrefix("capture."):
            return ("capture", ["content_type": suffix("capture."), "count": count])
        case id.hasPrefix("setting."):
            return ("setting_changed", ["setting": suffix("setting."), "count": count])
        case id.hasPrefix("fail."):
            let kind = suffix("fail.")
            guard kind != "sparkle_check" else { return nil }
            return ("failure", ["kind": kind, "count": count])
        case id.hasPrefix("pidx."), id.hasPrefix("page."):
            return nil
        default:
            return ("action", ["action": id.replacingOccurrences(of: ".", with: "_"), "count": count])
        }
    }

    private static func route(id: String, count: Int, into day: inout DayData) {
        func suffix(_ prefix: String) -> String {
            String(id.dropFirst(prefix.count)).replacingOccurrences(of: "-", with: "_")
        }
        switch true {
        case id == "popup.open":            day.popup["opens", default: 0] += count
        case id == "popup.abandon":         day.popup["abandons", default: 0] += count
        case id == "popup.nav":             day.popup["nav", default: 0] += count
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
        case id.hasPrefix("page."):         break
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

    func rankingInputs() -> (totals: [String: Int], lastUsed: [String: Double],
                             toolBuckets: [String: Int], globalBuckets: [String: Int]) {
        lock.lock(); defer { lock.unlock() }
        return (store.toolTotals, store.toolLastUsed, store.toolBuckets, store.globalBuckets)
    }

    var totalFastPastes: Int {
        lock.lock(); defer { lock.unlock() }
        return store.totalFastPastes
    }

    var totalPastes: Int {
        lock.lock(); defer { lock.unlock() }
        return store.totalPastes
    }

    var firstSeen: String {
        lock.lock(); defer { lock.unlock() }
        return store.firstSeen
    }

    /// Every version this device has ever run, keyed to the date it was
    /// first seen — the full update history, not just the current version.
    var versionHistory: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return store.versions
    }

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

    func persistNow() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: Self.storeFileURL, options: .atomic)
    }

    private func persistSoon() {
        // Callers include background-queue call sites (e.g. tool-use tracking
        // fired from Tools/*.swift's off-main closures), so this flag needs
        // the same lock guarding `store` — it was previously a plain Bool
        // read/written from multiple threads with no synchronization.
        lock.lock()
        guard !persistScheduled else { lock.unlock(); return }
        persistScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.persistScheduled = false
            self.lock.unlock()
            DispatchQueue.global(qos: .utility).async { self.persistNow() }
        }
    }

    func flushToBackend() {
        guard !sendInFlight else { return }
        pruneOldDays()
        let today = Self.dateKey(Date())

        let cutoff = Self.dateKey(Date().addingTimeInterval(-Double(Self.flushDelayDays) * 86_400))

        lock.lock()
        let pendingDays = store.days.filter { $0.key <= cutoff && !$0.value.isEmpty }
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
            if !day.popupDurationsMs.isEmpty { d["popup_durations"] = day.popupDurationsMs }
            if !day.popupOutcomes.isEmpty { d["popup_outcomes"] = day.popupOutcomes }
            if !day.actions.isEmpty { d["actions"] = day.actions }
            if !day.settingsChanged.isEmpty { d["settings_changed"] = day.settingsChanged }
            if !day.settingValues.isEmpty { d["setting_values"] = day.settingValues }
            if !day.failures.isEmpty { d["failures"] = day.failures }
            daysJSON[date] = d
        }

        lock.lock()
        let body: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "hardware_uuid": DeviceIdentity.installKey,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,

            "locale": Bundle.main.preferredLocalizations.first ?? Locale.current.identifier,
            "first_seen": store.firstSeen,
            "versions": store.versions,
            "settings": Self.settingsSnapshot(),

            "lifetime": Self.stateSnapshot(),
            "days": daysJSON,

            "client_today": Self.dateKey(Date()),
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
                Self.sendUsageSummaries(pendingDays, today: today)
                self.lock.lock()
                for date in sentDates { self.store.days.removeValue(forKey: date) }
                self.store.lastLivenessSent = today
                self.lock.unlock()
                DispatchQueue.global(qos: .utility).async { self.persistNow() }
            }
        }.resume()
    }

    /// One `usage_summary` event per day just accepted by the backend: the
    /// counts that used to arrive as one event per paste, copy, popup and
    /// keystroke. Sent only after the backend accepts the same days, the
    /// moment they leave the local store, so a day is summarised exactly
    /// once. Today goes out in parts (one per upload); counts add up.
    private static func sendUsageSummaries(_ days: [String: DayData], today: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        for (date, day) in days where !day.isEmpty {
            var p: [String: Any] = [
                "date": date,
                "pastes": day.cmdVPastes,
                "fast_pastes": day.fastPastes,
                "popup_opens": day.popup["opens", default: 0],
                "popup_searches": day.popup["searches", default: 0],
                "copies": day.captures.values.reduce(0, +),
                "actions": day.actions.values.reduce(0, +),
                "tool_uses": day.toolUses.values.reduce(0, +),
                "failures": day.failures.values.reduce(0, +),
                "app_version": version,
            ]
            // Firebase takes at most 25 flat parameters, so it gets the
            // totals above; PostHog also gets the breakdowns.
            let firebase = p
            for (k, v) in day.captures      { p["copy_\(k)"] = v }
            for (k, v) in day.actions       { p["action_\(k)"] = v }
            for (k, v) in day.toolUses      { p["tool_\(k)"] = v }
            for (k, v) in day.popupOutcomes { p["outcome_\(k)"] = v }
            for (k, v) in day.failures      { p["fail_\(k)"] = v }
            let at = date == today ? Date() : (noon(of: date) ?? Date())
            Analytics.logEvent("usage_summary", parameters: firebase)
            PostHogTracking.capture("usage_summary", properties: p, at: at)
        }
    }

    private static func noon(of dateKey: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: dateKey + " 12:00")
    }

    private static func stateSnapshot() -> [String: Any] {
        let m = ClipboardManager.shared
        let groupCount = m.items.filter {
            if case .group = $0.content { return true }
            return false
        }.count
        return [
            "history_size": m.items.count,
            "pinned_now": m.items.filter(\.isPinned).count,
            "groups_now": groupCount,
            "collections_count": m.collections.count,

            "collection_item_counts": m.collections.map { name in
                m.items.filter { $0.collections.contains(name) }.count
            },
        ]
    }

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
            "interaction_sounds":      m.interactionSoundsEnabled,
            "show_popup_hints":        m.showPopupInteractionHints,
            "beta_updates":            UserDefaults.standard.bool(forKey: "SUBetaUpdatesEnabled"),

            "app_language_override":   m.appLanguageCode.isEmpty ? "system" : m.appLanguageCode,

            "excluded_apps_count":     m.excludedCaptureBundleIDs.count,

            "nudges_learned_count":    m.nudgesLearnedCount,
        ]
    }

    private nonisolated struct RemoteMessage: Decodable {
        let enabled: Bool
        let id: String
        let title: String
        let body: String
        let buttonLabel: String
    }

    private static let remoteMessageInterval: TimeInterval = 6 * 60 * 60
    private var lastRemoteMessageCheck: Date?

    func checkForRemoteMessage(force: Bool = false) {
        if !force, let last = lastRemoteMessageCheck,
           Date().timeIntervalSince(last) < Self.remoteMessageInterval { return }
        lastRemoteMessageCheck = Date()
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

    enum FeedbackResult {
        case sent
        /// No connection, timeout, or the server is down — worth retrying.
        case offline
        /// Too many messages today (the server allows 20 a day).
        case rateLimited
        /// The server refused the message itself.
        case rejected
    }

    /// The server takes at most 2,000 characters per message
    /// (`MAX_FEEDBACK_MESSAGE_LEN`). Anything longer was refused with a 422,
    /// and the form reported every failure as "check your connection" — so
    /// a long, detailed bug report (exactly the kind worth having) could
    /// never be sent, and the sender was told their internet was the
    /// problem. Long messages now go as numbered parts that each fit.
    static let feedbackPartLimit = 1_900

    static func feedbackParts(_ text: String) -> [String] {
        guard text.count > feedbackPartLimit else { return [text] }
        var parts: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            if rest.count <= feedbackPartLimit { parts.append(String(rest)); break }
            let window = rest.prefix(feedbackPartLimit)
            // Break at a paragraph, then a line, then a space — never mid-word.
            let cut = window.range(of: "\n\n", options: .backwards)?.upperBound
                ?? window.range(of: "\n", options: .backwards)?.upperBound
                ?? window.range(of: " ", options: .backwards)?.upperBound
                ?? window.endIndex
            let piece = rest[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { parts.append(piece) }
            rest = rest[cut...]
        }
        guard parts.count > 1 else { return parts }
        return parts.enumerated().map { "(\($0.offset + 1)/\(parts.count)) \($0.element)" }
    }

    func sendFeedback(_ message: String, completion: @escaping (FeedbackResult) -> Void) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { DispatchQueue.main.async { completion(.rejected) }; return }
        sendFeedbackParts(Self.feedbackParts(trimmed), full: trimmed, completion: completion)
    }

    /// One part at a time, in order, stopping at the first failure.
    private func sendFeedbackParts(_ parts: [String], full: String,
                                   completion: @escaping (FeedbackResult) -> Void) {
        guard let part = parts.first else {
            PostHogTracking.capture("feedback_sent", properties: ["message": full])
            DispatchQueue.main.async { completion(.sent) }
            return
        }
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("clipen/feedback"),
                                 timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let now = Date()
        let body: [String: Any] = [
            "hardware_uuid": DeviceIdentity.installKey,
            "message": part,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "client_today": Self.dateKey(now),
            "client_time": Self.timeKey(now),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let result: FeedbackResult?
            switch (error, status) {
            case (nil, .some(200..<300)): result = nil   // this part went through
            case (nil, .some(429)):       result = .rateLimited
            case (nil, .some(400..<500)): result = .rejected
            default:                      result = .offline
            }
            if let result {
                DispatchQueue.main.async { completion(result) }
                return
            }
            self?.sendFeedbackParts(Array(parts.dropFirst()), full: full, completion: completion)
        }.resume()
    }

    private func maybeTriggerUpdateCheck(totalPastes: Int) {
        let d = UserDefaults.standard
        let last = d.integer(forKey: "lastUpdateCheckAtPasteCount")
        if totalPastes - last >= AuthManager.shared.updateCheckEveryClicks {
            d.set(totalPastes, forKey: "lastUpdateCheckAtPasteCount")
            AppDelegate.shared?.checkForUpdatesInBackgroundIfAllowed()
        }
    }

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

    static func dateKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func timeKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
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

        Analytics.setUserProperty(
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, forName: "app_version")
        Analytics.setUserProperty(ProcessInfo.processInfo.operatingSystemVersionString, forName: "os_version")

        DispatchQueue.main.async { AuthManager.shared.syncPersonPropertiesToPostHog(setFirstSeen: true) }
        // Every running copy used to call the backend three times every 30
        // minutes (usage, message, entitlement), each one a Firestore read
        // or write. Usage is kept on disk until it is accepted, so sending
        // it less often loses nothing; the message and the entitlement
        // throttle themselves to six hours (a locked gate still re-checks
        // quickly, see ProGate.refresh).
        flushTimer = Timer.scheduledTimer(withTimeInterval: TrackingService.flushInterval, repeats: true) { _ in
            DispatchQueue.main.async {
                TrackingService.shared.flushToBackend()
                TrackingService.shared.checkForRemoteMessage()
                ProGate.shared.refresh()
            }
        }
        flushTimer?.tolerance = 10 * 60
        DispatchQueue.main.async {
            TrackingService.shared.flushToBackend()
            TrackingService.shared.checkForRemoteMessage(force: true)
            ProGate.shared.refresh(maxAge: 0)
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

    func registerCommandVAction(position: Int? = nil, markedCount: Int? = nil, markedPositions: [Int]? = nil) {
        TrackingService.shared.recordCmdV(position: position, markedCount: markedCount, markedPositions: markedPositions)
    }

    func registerFastPasteAction() {
        TrackingService.shared.recordFastPaste()
    }

    func registerActionUsage(actionID: String, count: Int = 1, value: CustomStringConvertible? = nil,
                             extraProperties: [String: Any] = [:]) {
        TrackingService.shared.recordEvent(id: actionID, count: count, value: value, extraProperties: extraProperties)
    }

    private var livePersonPropertiesSyncWork: DispatchWorkItem?

    /// Coalesces a burst of state-changing activity — copy, delete, pin,
    /// unpin — into one PostHog `$set` a few seconds after things go quiet,
    /// instead of firing a network request on every single event.
    ///
    /// `history_size`, `pinned_now` and `groups_now` used to be current only
    /// immediately after launch or after an explicit group/collection
    /// action: copying, deleting and pinning never called
    /// `syncPersonPropertiesToPostHog` at all, so those three counts drifted
    /// out of sync with reality for the rest of the session. Hooked from
    /// `ClipboardManager.items`'s `didSet` — the one place that already
    /// fires on every capture, delete, pin toggle, group and ungroup (see
    /// its own comment on why it fires that broadly) — so this needed no
    /// new call sites at all, just one more subscriber to a hook that
    /// already existed.
    ///
    /// Debounced rather than called directly: `items` mutates on things far
    /// more frequent than these counts changing (a pasteCount increment, an
    /// OCR result landing, AI structured text being stored), and copying is
    /// itself often rapid-fire. Coalescing means a burst of ten copies in
    /// two seconds sends one `$set` shortly after the burst ends, not ten
    /// individual requests.
    /// The counts only need to be roughly current on PostHog, and this was
    /// called on every copy, delete and pin: one `$set` request per copy
    /// for anyone copying more than every few seconds apart. Now at most one
    /// every 30 minutes, always carrying the latest values; a change during
    /// the wait is folded into the one already scheduled.
    private static let livePersonSyncInterval: TimeInterval = 30 * 60
    private var lastPersonPropertiesSyncAt: Date?

    func scheduleLivePersonPropertiesSync() {
        guard livePersonPropertiesSyncWork == nil else { return }
        let sinceLast = lastPersonPropertiesSyncAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = max(3, Self.livePersonSyncInterval - sinceLast)
        let work = DispatchWorkItem { [weak self] in
            self?.syncPersonPropertiesToPostHog()
        }
        livePersonPropertiesSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Re-sends the current-state person properties (item/pin/group/
    /// collection counts, version, plan) to PostHog. Called once at
    /// launch, immediately after an explicit low-frequency action
    /// (group/ungroup, collection create/delete), and — debounced — from
    /// `scheduleLivePersonPropertiesSync` for everything else that changes
    /// these counts.
    func syncPersonPropertiesToPostHog(setFirstSeen: Bool = false) {
        // A call here already sends fresh values right now, so a debounced
        // resend still pending from `scheduleLivePersonPropertiesSync`
        // would only repeat the same $set a few seconds later.
        livePersonPropertiesSyncWork?.cancel()
        livePersonPropertiesSyncWork = nil
        lastPersonPropertiesSyncAt = Date()
        let m = ClipboardManager.shared
        let groupCount = m.items.filter {
            if case .group = $0.content { return true }
            return false
        }.count
        PostHogTracking.setPersonProperties(
            [
                "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
                "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
                "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
                "locale": Bundle.main.preferredLocalizations.first ?? Locale.current.identifier,
                "plan": ProGate.shared.isPro ? "pro" : "free",
                "history_size": m.items.count,
                "pinned_now": m.items.filter(\.isPinned).count,
                "groups_now": groupCount,
                "collections_count": m.collections.count,
                "app_version_history": TrackingService.shared.versionHistory,
            ],
            setOnce: setFirstSeen ? ["first_seen": TrackingService.shared.firstSeen] : [:]
        )
    }

    func registerToolUsage(toolID: String, count: Int = 1, via: String? = nil) {
        TrackingService.shared.recordToolUse(id: toolID, count: count, via: via)
    }

    func registerSettingValue(id: String, value: Int) {
        TrackingService.shared.recordSettingValue(id: id, value: value)
    }

    var fastPasteCount: Int {
        TrackingService.shared.totalFastPastes
    }

    func flushPendingDailyUsage() {
        TrackingService.shared.persistNow()
    }

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
