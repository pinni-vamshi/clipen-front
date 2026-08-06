import AppKit

/// A feature we teach the user with an independent lesson panel, one at a
/// time, the first time their usage crosses a threshold — but only if they
/// haven't already demonstrated they know it by using it natively. Unlike the
/// old design, the lesson panel is NOT anchored to or torn down with the ring
/// popup — it's a standalone, centered window that persists until the user
/// explicitly answers "Learned" or "Later", so a fluent user's fast paste
/// habit can no longer kill it before it's ever readable.
enum NudgeFeature: Int, CaseIterable {
    case multiPaste = 1
    case groups = 2
    case preview = 3
    case pinPreview = 4
    case transformPanel = 5
    // Deliberately NOT eligible for the automatic threshold-based nudge
    // (see `thresholdMet` below, which always returns false for these two) —
    // they only ever open from the Settings "Tips" cards, on click. They
    // still reuse the exact same lesson window and learned/not-learned
    // bookkeeping as the original 5, just scoped to their own "X of 2"
    // progress instead of folding into the main "X of 5" count (see
    // `learnedProgress(for:)`), so adding them can't silently change what
    // `nudgesLearnedCount`/the auto-nudge subtitle have always meant.
    case collections = 6
    case search = 7

    var demo: InteractionDemo {
        switch self {
        case .multiPaste:     return .multiPaste
        case .groups:         return .group
        case .preview:        return .spacePreview
        case .pinPreview:     return .pinPreview
        case .transformPanel: return .transform
        case .collections:    return .collections
        case .search:         return .search
        }
    }

    /// Short slug for telemetry event IDs (action.nudge-shown-<slug>, etc).
    var trackingID: String {
        switch self {
        case .multiPaste:     return "multi_paste"
        case .groups:         return "groups"
        case .preview:        return "preview"
        case .pinPreview:     return "pin_preview"
        case .transformPanel: return "transform_panel"
        case .collections:    return "collections"
        case .search:         return "search"
        }
    }

    fileprivate var usedKey: String {
        switch self {
        case .multiPaste:     return "clipen.nudge.used.multiPaste"
        case .groups:         return "clipen.nudge.used.groups"
        case .preview:        return "clipen.nudge.used.preview"
        case .pinPreview:     return "clipen.nudge.used.pinPreview"
        case .transformPanel: return "clipen.nudge.used.transformPanel"
        case .collections:    return "clipen.nudge.used.collections"
        case .search:         return "clipen.nudge.used.search"
        }
    }

    /// Retry counter (0...maxNudgeRetries) — how many times this lesson has
    /// been shown and answered "Later" (or, before it existed, was missed
    /// early). Once it hits the cap the feature stops being eligible for
    /// good, so a never-learned lesson can't camp at the front of the queue
    /// forever and starve later (higher rawValue) features from ever getting
    /// a turn. Unused by `.collections`/`.search` (never auto-shown, so
    /// never retried), but every case needs a key for the switch to compile.
    fileprivate var retryKey: String {
        switch self {
        case .multiPaste:     return "clipen.nudge.retry.multiPaste"
        case .groups:         return "clipen.nudge.retry.groups"
        case .preview:        return "clipen.nudge.retry.preview"
        case .pinPreview:     return "clipen.nudge.retry.pinPreview"
        case .transformPanel: return "clipen.nudge.retry.transformPanel"
        case .collections:    return "clipen.nudge.retry.collections"
        case .search:         return "clipen.nudge.retry.search"
        }
    }
}

/// Which kind of paste just happened, for nudge-counter purposes. `.single`
/// and `.group` only advance the base paste counter; `.multiMarked` is the
/// one genuine "user marked 2+ items and released" gesture that also counts
/// toward the Groups threshold and marks multi-paste as natively learned.
enum NudgePasteKind {
    case single
    case multiMarked
    case group
}

extension ClipboardManager {

    // MARK: Counters (persisted, lifetime — start at 0 for every install,
    // never backfilled from historical totals, so a returning user can never
    // have several thresholds crossed at once purely from a counter jump).

    private static let pasteCountKey = "clipen.nudge.pasteCount"
    private static let multiPasteCountKey = "clipen.nudge.multiPasteCount"
    private static let previewCountKey = "clipen.nudge.previewCount"

    private var nudgePasteCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.pasteCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pasteCountKey) }
    }
    private var nudgeMultiPasteCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.multiPasteCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.multiPasteCountKey) }
    }
    private var nudgePreviewCount: Int {
        get { UserDefaults.standard.integer(forKey: Self.previewCountKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.previewCountKey) }
    }

    // MARK: "Already knows this" — set the instant the real gesture fires,
    // independent of any counter, so a lesson for a feature the user just
    // demonstrated never shows up later. Also doubles as the "you actually
    // did it while the lesson was open" signal — see the auto-close below.

    func markNudgeUsedNaturally(_ feature: NudgeFeature) {
        let key = feature.usedKey
        let alreadyKnew = UserDefaults.standard.bool(forKey: key)
        if !alreadyKnew {
            UserDefaults.standard.set(true, forKey: key)
            nudgeLearnedRevision += 1
            // Distinct from "action.nudge-learned-<feature>" (explicit
            // "Learned" click) — this fires when the real gesture is
            // detected, whether or not any lesson was ever shown for it.
            AuthManager.shared.registerActionUsage(
                actionID: "action.nudge-learned-naturally-\(feature.trackingID)")
        }
        // The user just performed the real gesture. If this happens to be the
        // lesson currently on screen, finish it automatically — no need to
        // make them click "Learned" for something they just visibly did. It
        // does NOT close instantly: the confirmation plays first, so the
        // lesson is visibly credited rather than vanishing mid-gesture.
        if nudgeIsShowing, nudgeActiveFeature == feature {
            finishNudgeAsLearned()
        }
    }

    private func hasUsedNaturally(_ feature: NudgeFeature) -> Bool {
        UserDefaults.standard.bool(forKey: feature.usedKey)
    }

    /// Whether a tip's learned state should show on its Settings card —
    /// public because SettingsView reads it directly per card.
    func isNudgeLearned(_ feature: NudgeFeature) -> Bool { hasUsedNaturally(feature) }

    /// The original 5 auto-triggered lessons — kept as an explicit list
    /// (not `NudgeFeature.allCases`) so adding `.collections`/`.search`
    /// can never silently change what "X of 5 learned" has always meant,
    /// here or in the AuthManager telemetry that reads this same count.
    private static let autoTrackedFeatures: [NudgeFeature] =
        [.multiPaste, .groups, .preview, .pinPreview, .transformPanel]
    private static let manualOnlyFeatures: [NudgeFeature] = [.collections, .search]

    /// "X of 5 learned" — read by the lesson panel's progress line.
    var nudgesLearnedCount: Int {
        Self.autoTrackedFeatures.filter(hasUsedNaturally).count
    }

    /// Progress line for whichever lesson is currently open — the original
    /// 5 always read against each other ("X of 5"), and the click-only
    /// Settings extras read against each other too ("X of 2"), so opening
    /// a Tips card can never perturb the main count above.
    private func learnedProgress(for feature: NudgeFeature) -> (learned: Int, total: Int) {
        let siblings = Self.autoTrackedFeatures.contains(feature)
            ? Self.autoTrackedFeatures : Self.manualOnlyFeatures
        return (siblings.filter(hasUsedNaturally).count, siblings.count)
    }

    private static let maxNudgeRetries = 3

    private func nudgeRetryCount(_ feature: NudgeFeature) -> Int {
        UserDefaults.standard.integer(forKey: feature.retryKey)
    }

    /// Called only when the user answers "Later" on a shown lesson.
    private func incrementNudgeRetry(_ feature: NudgeFeature) {
        UserDefaults.standard.set(nudgeRetryCount(feature) + 1, forKey: feature.retryKey)
    }

    private func thresholdMet(_ feature: NudgeFeature) -> Bool {
        switch feature {
        case .multiPaste:     return nudgePasteCount >= 5
        case .groups:         return nudgeMultiPasteCount >= 3
        case .preview:        return nudgePasteCount >= 2
        case .pinPreview:     return nudgePreviewCount >= 3
        case .transformPanel: return nudgePasteCount >= 8
        // Never met — these two are click-only from the Settings Tips
        // cards and must never enter the automatic candidate pool below.
        case .collections, .search: return false
        }
    }

    private func isEligible(_ feature: NudgeFeature) -> Bool {
        !hasUsedNaturally(feature) && nudgeRetryCount(feature) < Self.maxNudgeRetries && thresholdMet(feature)
    }

    // MARK: Recording usage — call these from the real action call sites.

    /// One choke point for every completed paste (single item, group expand,
    /// or a marked multi-paste). Only the genuine multi-marked gesture
    /// advances the Groups counter and marks multi-paste as natively known.
    ///
    /// Deliberately does NOT evaluate/show a lesson here — every paste path
    /// closes the popup right before this runs. Counters/flags just
    /// accumulate; the actual check happens the next time the popup opens
    /// (`openPopupNow()`).
    func recordNudgePaste(kind: NudgePasteKind) {
        nudgePasteCount += 1
        if kind == .multiMarked {
            nudgeMultiPasteCount += 1
            markNudgeUsedNaturally(.multiPaste)
        }
    }

    /// Call when the user opens the item preview panel (Space). The popup
    /// stays open here, but we still defer to the next popup-open check
    /// (below) rather than firing mid-interaction — keeps all lesson timing
    /// on one predictable, non-interrupting trigger point.
    func recordNudgePreviewOpen() {
        nudgePreviewCount += 1
        markNudgeUsedNaturally(.preview)
    }

    // MARK: Firing — checked once per popup open (see openPopupNow()), using
    // whatever counters/flags accumulated since the last check. At most one
    // lesson at a time, lowest-ladder-step first, never back-to-back with the
    // last one shown. Once presented, the lesson panel is fully independent
    // of the ring popup — it has no fixed visible-duration timer AND is no
    // longer torn down when the popup closes. It only ever closes because the
    // user answered "Learned" / "Later", or because they performed the real
    // gesture naturally (see markNudgeUsedNaturally above).

    private static let minSecondsBetweenNudges: TimeInterval = 45

    /// Evaluated immediately on popup open — no artificial delay. The old
    /// 0.6s delay (to avoid fighting the popup's open animation) meant a
    /// fluent user's whole popup session could end before a lesson even had
    /// a chance to appear. Since the lesson panel no longer lives or dies
    /// with the popup, there's no reason to wait at all.
    func scheduleNudgeEvaluation() {
        evaluateNudges()
    }

    private func evaluateNudges() {
        guard previewWindow.isVisible, !isInlineEditing, !inTransformStage,
              !popupPinnedOpen, !nudgeIsShowing else { return }
        if let last = lastNudgeShownAt,
           Date().timeIntervalSince(last) < Self.minSecondsBetweenNudges { return }
        // Explicitly scoped to the auto-tracked 5 — `.collections`/`.search`
        // would never pass `isEligible` anyway (their threshold is always
        // false), but this keeps that guarantee visible right where the
        // candidate pool is built, not just implied by a threshold two
        // functions away.
        guard let next = Self.autoTrackedFeatures.filter(isEligible).min(by: { $0.rawValue < $1.rawValue })
        else { return }
        presentNudge(next, auto: true)
    }

    private func presentNudge(_ feature: NudgeFeature, auto: Bool) {
        nudgeIsShowing = true
        nudgeActiveFeature = feature
        lastNudgeShownAt = Date()
        AuthManager.shared.registerActionUsage(
            actionID: "action.nudge-shown-\(feature.trackingID)-\(auto ? "auto" : "manual")")
        let progress = learnedProgress(for: feature)
        nudgeLessonPanel.show(
            feature: feature,
            learnedCount: progress.learned,
            total: progress.total,
            onLearned: { [weak self] in self?.answerNudgeLesson(learned: true) },
            onLater:   { [weak self] in self?.answerNudgeLesson(learned: false) }
        )
    }

    /// Opens a lesson window on demand, from the Settings "Tips" cards —
    /// the click-only entry point for every feature, and the ONLY way
    /// `.collections`/`.search` ever get shown (see `thresholdMet` above).
    /// Reuses the exact same window/state machine as an automatic nudge,
    /// so "Learned"/"Later" behave identically either way.
    func presentTipManually(_ feature: NudgeFeature) {
        guard !nudgeIsShowing else { return }
        presentNudge(feature, auto: false)
    }

    /// The two explicit answers on the lesson panel. "Learned" marks the
    /// gesture as permanently known (same bookkeeping as performing it for
    /// real) and advances the "X of 5" count. "Later" doesn't advance
    /// anything — it counts as a miss (up to the retry cap) and the same
    /// lesson tries again on a future popup open.
    private func answerNudgeLesson(learned: Bool) {
        guard let feature = nudgeActiveFeature else { return }
        AuthManager.shared.registerActionUsage(
            actionID: "action.nudge-\(learned ? "learned" : "later")-\(feature.trackingID)")
        if learned {
            UserDefaults.standard.set(true, forKey: feature.usedKey)
            nudgeLearnedRevision += 1
            finishNudgeAsLearned()
        } else {
            incrementNudgeRetry(feature)
            hideNudgeLesson()
        }
    }

    /// Play the "Learned!" confirmation over the lesson, with the progress
    /// count already advanced, and only close once it has been seen. Guarded
    /// so a burst of gesture events can't stack several confirmations or cut
    /// the first one short.
    private func finishNudgeAsLearned() {
        guard !nudgeIsFinishing, let feature = nudgeActiveFeature else { return }
        nudgeIsFinishing = true
        let progress = learnedProgress(for: feature)
        nudgeLessonPanel.flashLearnedThenHide(learnedCount: progress.learned) { [weak self] in
            guard let self else { return }
            self.nudgeIsFinishing = false
            self.hideNudgeLesson()
        }
    }

    private func hideNudgeLesson() {
        nudgeLessonPanel.hide()
        nudgeIsShowing = false
        nudgeActiveFeature = nil
    }
}
