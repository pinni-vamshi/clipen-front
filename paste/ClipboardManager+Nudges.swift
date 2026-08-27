import AppKit

enum NudgeFeature: Int, CaseIterable {
    case multiPaste = 1
    case groups = 2
    case preview = 3
    case pinPreview = 4
    case transformPanel = 5

    case collections = 6
    case search = 7
    case similar = 8

    var demo: InteractionDemo {
        switch self {
        case .multiPaste:     return .multiPaste
        case .groups:         return .group
        case .preview:        return .spacePreview
        case .pinPreview:     return .pinPreview
        case .transformPanel: return .transform
        case .collections:    return .collections
        case .search:         return .search
        case .similar:        return .similar
        }
    }

    var trackingID: String {
        switch self {
        case .multiPaste:     return "multi_paste"
        case .groups:         return "groups"
        case .preview:        return "preview"
        case .pinPreview:     return "pin_preview"
        case .transformPanel: return "transform_panel"
        case .collections:    return "collections"
        case .search:         return "search"
        case .similar:        return "similar"
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
        case .similar:        return "clipen.nudge.used.similar"
        }
    }

    fileprivate var retryKey: String {
        switch self {
        case .multiPaste:     return "clipen.nudge.retry.multiPaste"
        case .groups:         return "clipen.nudge.retry.groups"
        case .preview:        return "clipen.nudge.retry.preview"
        case .pinPreview:     return "clipen.nudge.retry.pinPreview"
        case .transformPanel: return "clipen.nudge.retry.transformPanel"
        case .collections:    return "clipen.nudge.retry.collections"
        case .search:         return "clipen.nudge.retry.search"
        case .similar:        return "clipen.nudge.retry.similar"
        }
    }
}

enum NudgePasteKind {
    case single
    case multiMarked
    case group
}

extension ClipboardManager {

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

    func markNudgeUsedNaturally(_ feature: NudgeFeature) {
        let key = feature.usedKey
        let alreadyKnew = UserDefaults.standard.bool(forKey: key)
        if !alreadyKnew {
            UserDefaults.standard.set(true, forKey: key)
            nudgeLearnedRevision += 1

            AuthManager.shared.registerActionUsage(
                actionID: "action.nudge-learned-naturally-\(feature.trackingID)")
        }

        if nudgeIsShowing, nudgeActiveFeature == feature {
            finishNudgeAsLearned()
        }
    }

    private func hasUsedNaturally(_ feature: NudgeFeature) -> Bool {
        UserDefaults.standard.bool(forKey: feature.usedKey)
    }

    func isNudgeLearned(_ feature: NudgeFeature) -> Bool { hasUsedNaturally(feature) }

    private static let autoTrackedFeatures: [NudgeFeature] =
        [.multiPaste, .groups, .preview, .pinPreview, .transformPanel]
    private static let manualOnlyFeatures: [NudgeFeature] = [.collections, .search, .similar]

    var nudgesLearnedCount: Int {
        Self.autoTrackedFeatures.filter(hasUsedNaturally).count
    }

    private func learnedProgress(for feature: NudgeFeature) -> (learned: Int, total: Int) {
        let siblings = Self.autoTrackedFeatures.contains(feature)
            ? Self.autoTrackedFeatures : Self.manualOnlyFeatures
        return (siblings.filter(hasUsedNaturally).count, siblings.count)
    }

    private static let maxNudgeRetries = 3

    private func nudgeRetryCount(_ feature: NudgeFeature) -> Int {
        UserDefaults.standard.integer(forKey: feature.retryKey)
    }

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

        case .collections, .search, .similar: return false
        }
    }

    private func isEligible(_ feature: NudgeFeature) -> Bool {
        !hasUsedNaturally(feature) && nudgeRetryCount(feature) < Self.maxNudgeRetries && thresholdMet(feature)
    }

    func recordNudgePaste(kind: NudgePasteKind) {
        nudgePasteCount += 1
        if kind == .multiMarked {
            nudgeMultiPasteCount += 1
            markNudgeUsedNaturally(.multiPaste)
        }
    }

    func recordNudgePreviewOpen() {
        nudgePreviewCount += 1
        markNudgeUsedNaturally(.preview)
    }

    private static let minSecondsBetweenNudges: TimeInterval = 45

    func scheduleNudgeEvaluation() {
        evaluateNudges()
    }

    private func evaluateNudges() {
        // Off by default — only the explicit onboarding alert or the Tips
        // heading toggle in Settings turns this on. presentTipManually
        // (clicking a tip directly in Settings) bypasses this function
        // entirely and is unaffected either way.
        guard autoTipsEnabled else { return }
        guard previewWindow.isVisible, !isInlineEditing, !inTransformStage,
              !popupPinnedOpen, !nudgeIsShowing else { return }
        if let last = lastNudgeShownAt,
           Date().timeIntervalSince(last) < Self.minSecondsBetweenNudges { return }

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

    func presentTipManually(_ feature: NudgeFeature) {
        guard !nudgeIsShowing else { return }
        presentNudge(feature, auto: false)
    }

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
