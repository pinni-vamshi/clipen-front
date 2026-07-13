import AppKit
import Combine
import Foundation
import SwiftUI

final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    let transformsEnabled  = true
    let semanticSearch      = true
    let ocrEnabled          = true
    let pdfTextExtract      = true
    let ringLimit           = 500

    let maxDataBytes:           Int  = 500 * 1024 * 1024
    let sparkleAutomaticChecks: Bool = true
    let updateCheckEveryClicks: Int  = 50

    @Published var lastError: String? = nil
    func clearError() { lastError = nil }

    private let clickCountKey              = "backendFeatureFlagsClickCount"
    private let fastPasteCountKey          = "backendFastPasteCount"
    private let lastUpdateCheckClickKey    = "backendFeatureFlagsLastUpdateCheckClick"
    private let toolUsageTotalsKey         = "backendToolUsageTotals"
    private let toolLastUsedAtKey          = "backendToolLastUsedAt"
    private let toolBucketUsageKey         = "backendToolBucketUsage"
    private let globalBucketUsageKey       = "backendGlobalBucketUsage"
    private let dailyUsageKey              = "backendDailyUsageByDateTool"
    private static let cmdVBucketToolID    = "__cmdv__"
    private let lastDismissedMessageIDKey  = "lastDismissedRemoteMessageID"
    private let lastHeartbeatDateKey       = "lastHeartbeatDate"
    private let lifetimeActiveDaysKey       = "clipenLifetimeActiveDays"
    private static let lifetimeActiveDaysCap = 400
    private var todayMarkedActive = false

    private static let usageBaseURL = URL(string: "https://clipen-backend.onrender.com")!

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
        flushCompletedDailyUsage()
    }

    private var pendingDailyUsage: [String: Int] = [:]
    private var dailyUsageFlushScheduled = false

    private func incrementDailyUsage(toolID: String, count: Int = 1, date: String) {
        guard !toolID.isEmpty, count > 0 else { return }
        pendingDailyUsage["\(date)|\(toolID)", default: 0] += count
        noteActiveDayIfNeeded()
        scheduleDailyUsageFlush()
    }

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

    func flushPendingDailyUsage() {
        guard !pendingDailyUsage.isEmpty else { return }
        var counts = persistedDailyUsageRaw()
        for (k, v) in pendingDailyUsage { counts[k, default: 0] += v }
        pendingDailyUsage.removeAll(keepingCapacity: true)
        UserDefaults.standard.set(counts, forKey: dailyUsageKey)
    }

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

    private static func dateKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    private func flushCompletedDailyUsage() {
        let todayKey = Self.dateKey(for: Date())
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

    private var usageSendsInFlight: Set<String> = []

    static let isFirstSessionEver: Bool = {
        let d = UserDefaults.standard
        let alreadyStamped = d.object(forKey: "firstSessionStamp") != nil
        let isUpgradeInstall = d.bool(forKey: "hasLaunchedBefore")
        if !alreadyStamped {
            d.set(Date().timeIntervalSince1970, forKey: "firstSessionStamp")
        }
        return !alreadyStamped && !isUpgradeInstall
    }()

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

    private static let metricPrefixToGroup: [String: String] = [
        "popup.":   "popup",
        "capture.": "captures",
        "ref.":     "reference",
        "pidx.":    "paste_index_buckets",
        "page.":    "paste_age_buckets",
        "setting.": "settings_changes",
        "fail.":    "failures",
        "session.": "session",
    ]

    private static let metricKeyRenames: [String: String] = [
        "popup.open": "opens", "popup.abandon": "abandons",
        "popup.dur_ms": "duration_ms_sum", "popup.nav": "items_navigated_sum",
        "ref.pin": "pins", "ref.open": "opens", "ref.badge_click": "badge_clicks",
        "ref.auto_surface": "auto_surfaces", "ref.auto_collapse": "auto_collapses",
        "ref.note_edit": "note_edits", "ref.view_ms": "view_ms_sum",
        "session.open": "opens",
    ]

    private func sendDailyUsage(date: String, counts: [String: Int]) {
        guard !usageSendsInFlight.contains(date) else { return }
        usageSendsInFlight.insert(date)

        var toolCounts = counts
        let cmdVCount = toolCounts.removeValue(forKey: Self.cmdVBucketToolID) ?? 0

        var groups: [String: [String: Int]] = [:]
        for (id, value) in toolCounts {
            guard let prefix = Self.metricPrefixToGroup.keys.first(where: { id.hasPrefix($0) }),
                  let group = Self.metricPrefixToGroup[prefix] else { continue }
            toolCounts.removeValue(forKey: id)
            let key = Self.metricKeyRenames[id] ?? String(id.dropFirst(prefix.count))
            groups[group, default: [:]][key, default: 0] += value
        }
        if let searches = toolCounts["action.popup-search"] {
            groups["popup", default: [:]]["searches", default: 0] += searches
        }
        if let pins = toolCounts["action.reference-pin"] {
            groups["reference", default: [:]]["pins", default: 0] += pins
        }

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
        for (group, dict) in groups where !dict.isEmpty {
            body[group] = dict
        }
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
        body["value_profile"] = clipenValueProfile()
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

    func registerFastPasteAction() {
        let next = UserDefaults.standard.integer(forKey: fastPasteCountKey) + 1
        UserDefaults.standard.set(next, forKey: fastPasteCountKey)
    }

    var fastPasteCount: Int {
        UserDefaults.standard.integer(forKey: fastPasteCountKey)
    }

    func registerActionUsage(actionID: String, count: Int = 1) {
        guard !actionID.isEmpty, count > 0 else { return }
        incrementDailyUsage(toolID: actionID, count: count, date: Self.dateKey(for: Date()))
    }

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

    func toolImportanceScore(for toolID: String, now: Date = Date()) -> Double {
        let totals = toolUsageTotals()
        let totalCount = Double(totals[toolID, default: 0])
        guard totalCount > 0 else { return 0 }

        let frequency = min(log1p(totalCount) / 5.0, 1.0)

        let lastUsedEpoch = toolLastUsedAt()[toolID] ?? 0
        let recency: Double = {
            guard lastUsedEpoch > 0 else { return 0 }
            let ageHours = max(0, (now.timeIntervalSince1970 - lastUsedEpoch) / 3600.0)
            let tauHours = 24.0 * 7.0
            return exp(-ageHours / tauHours)
        }()

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

    static let valueProfileFormulaVersion = 1

    private static let dateKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func smoothedRatio(_ x: Double, _ n: Double, alpha: Double, beta: Double) -> Double {
        (x + alpha) / (n + alpha + beta)
    }

    private static func logNorm(_ x: Double, cap: Double) -> Double {
        guard x > 0, cap > 0 else { return 0 }
        return min(1, log1p(x) / log1p(cap))
    }

    func clipenValueProfile(now: Date = Date()) -> [String: Any] {
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

        let activeDates = Set(UserDefaults.standard.stringArray(forKey: lifetimeActiveDaysKey) ?? [])
        let activeDayCount = Double(activeDates.count)

        let firstStamp = UserDefaults.standard.object(forKey: "firstSessionStamp") as? Double
        let earliestAge = activeDates.map(ageDays).filter { $0.isFinite }.max() ?? 0
        let accountAgeDays = max(firstStamp.map { max(0, todayStart.timeIntervalSince1970 - $0) / 86_400 } ?? 0,
                                 earliestAge)

        let cmdVLifetime = Double(UserDefaults.standard.integer(forKey: clickCountKey))
        let fastPastes = Double(UserDefaults.standard.integer(forKey: fastPasteCountKey))

        let activeDayRate = Self.smoothedRatio(activeDayCount, max(1, accountAgeDays),
                                               alpha: 1, beta: 4)
        let habitLambda = log(2.0) / 14.0
        let weightedActive = activeDates.reduce(0.0) { $0 + exp(-habitLambda * ageDays($1)) }
        let habitDensity = Self.logNorm(weightedActive, cap: 14)
        let H = min(1, 0.5 * activeDayRate + 0.5 * habitDensity)

        let popupPastes = max(0, cmdVLifetime - fastPastes)
        let dependencyRatio = Self.smoothedRatio(popupPastes, max(1, cmdVLifetime), alpha: 1, beta: 6)
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

        let distinctSettings = Double(recentDistinct("setting."))
        let distinctActions = Double(recentDistinct("action."))
        let E = min(1, Self.logNorm(distinctSettings + distinctActions, cap: 18))

        let opens = recent("popup.open")
        let abandons = recent("popup.abandon")
        let abandonRate = Self.smoothedRatio(abandons, max(1, opens), alpha: 1, beta: 4)
        let failTotal = recentPrefix("fail.")
        let failDenom = max(1, recent(Self.cmdVBucketToolID) + recentPrefix("capture."))
        let failRate = Self.logNorm(failTotal / failDenom * 100, cap: 100)
        let navsPerOpen = opens > 0 ? recent("popup.nav") / opens : 0
        let oscillation = min(1, navsPerOpen / 25) * abandonRate
        let F = min(1, 0.55 * abandonRate + 0.30 * failRate + 0.15 * oscillation)

        let observations = cmdVLifetime + transformUses + activeDayCount
        let confidence = 1 - exp(-observations / 60.0)

        let wH = 0.30, wD = 0.30, wW = 0.25, wE = 0.05, wF = 0.20
        let rawInterest = max(0, min(1, wH * H + wD * D + wW * W + wE * E - wF * F))
        let neutralPrior = 0.35
        let interest = confidence * rawInterest + (1 - confidence) * neutralPrior

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
            ClipboardManager.shared.applyPlanLimits(ringLimit: ringLimit)
            AppDelegate.shared?.automaticallyChecksForUpdates = sparkleAutomaticChecks
        }
    }

    private struct RemoteMessage: Decodable {
        let enabled: Bool
        let id: String
        let title: String
        let body: String
        let buttonLabel: String
    }

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
