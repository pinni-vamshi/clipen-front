import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import NaturalLanguage
import ServiceManagement
@preconcurrency import PDFKit

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    lazy var historyDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    var imageBlobCache:   [UUID: (path: String, bytes: Int)] = [:]
    var payloadBlobCache: [UUID: String] = [:]
    var sidecarBlobCache: [UUID: String] = [:]
    var embeddingsDirty = false
    var blobPurgeNeeded = true

    var transformingMarkedSet = false

    let fastPasteHintShownKey = "hasShownFastPasteHint"
    var lastSearchQuery: String?
    var lastSearchResult: [ClipboardItem] = []
    var lastSearchItemsRev: Int = -1
    var lastSearchEmbedRev: Int = -1
    var embeddedItemCount: Int = 0

    static var maxDataBytes: Int { AuthManager.shared.maxDataBytes }

    var itemsRevision = 0

    @Published var items: [ClipboardItem] = [] {
        didSet {
            itemsRevision &+= 1
            _displayItems = nil
            _availableTags = nil
            updatePendingPasteID()
            if !markedItemIDs.isEmpty {
                let live = Set(items.map(\.id))
                let cleaned = markedItemIDs.filter { live.contains($0) }
                if cleaned.count != markedItemIDs.count { markedItemIDs = cleaned }
            }
        }
    }
    @Published var selectedIndex: Int = 0 {
        didSet { updatePendingPasteID() }
    }

    @Published var popupOpenGeneration: Int = 0

    @Published var popupHintV = false
    @Published var popupHintShiftV = false
    @Published var popupHintVMark = false
    @Published var popupHintX = false
    @Published var popupHintShiftX = false
    @Published var popupHintXHold = false
    @Published var popupHintC = false
    @Published var popupHintSpace = false
    @Published var popupHintSpaceDoubleTap = false
    @Published var popupHintCmd = false

    @Published var markedItemIDs: [UUID] = []

    var multiSelectAnchorIndex: Int? = nil

    @Published var popupTagFilter: ClipboardTag? = nil {
        didSet {
            _displayItems = nil
            selectedIndex = 0
            if previewWindow.isVisible { syncItemPreviewWithSelection() }
        }
    }

    @Published var popupSearchQuery: String = "" {
        didSet {
            _displayItems = nil
            selectedIndex = 0
        }
    }
    @Published var isSearchActive: Bool = false
    @Published var maxItems: Int = 10 {
        didSet {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let unpinned = self.items.indices.filter { !self.items[$0].isPinned }
                if unpinned.count > self.maxItems {
                    let toRemove = unpinned.suffix(from: self.maxItems)
                    for idx in toRemove.reversed() {
                        self.evictFileSnapshots(for: self.items[idx])
                        self.items.remove(at: idx)
                    }
                    self.markBlobPurgeNeeded()
                }
            }
        }
    }

    func setRingSize(_ size: Int) {
        let clamped = min(max(size, 1), AuthManager.shared.ringLimit)
        if clamped != maxItems { AuthManager.shared.registerActionUsage(actionID: "setting.ring_size") }
        maxItems = clamped
        UserDefaults.standard.set(clamped, forKey: "preferredRingSize")
    }

    @Published var captureRichText: Bool = UserDefaults.standard.object(forKey: "captureRichText") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(captureRichText, forKey: "captureRichText")
            if oldValue != captureRichText { AuthManager.shared.registerActionUsage(actionID: "setting.capture_rich") }
        }
    }

    @Published var captureFiles: Bool = UserDefaults.standard.object(forKey: "captureFiles") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(captureFiles, forKey: "captureFiles")
            if oldValue != captureFiles { AuthManager.shared.registerActionUsage(actionID: "setting.capture_files") }
        }
    }

    @Published var fetchURLTitles: Bool = UserDefaults.standard.object(forKey: "fetchURLTitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fetchURLTitles, forKey: "fetchURLTitles") }
    }

    @Published var showColorSwatches: Bool = UserDefaults.standard.object(forKey: "showColorSwatches") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showColorSwatches, forKey: "showColorSwatches") }
    }

    @Published var isCapturingPaused: Bool = false

    @Published var transientStatus: String? = nil

    @Published var highlightOpenDelaySlider: Bool = false

    func pulseOpenDelaySlider(duration: TimeInterval = 6.0) {
        DispatchQueue.main.async { [weak self] in self?.highlightOpenDelaySlider = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.highlightOpenDelaySlider = false
        }
    }

    func flashStatus(_ msg: String, duration: TimeInterval = 2.5) {
        DispatchQueue.main.async { [weak self] in self?.transientStatus = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.transientStatus == msg { self?.transientStatus = nil }
        }
    }

    var _displayItems: [ClipboardItem]? = nil
    var displayItems: [ClipboardItem] {
        if let cached = _displayItems { return cached }
        var result = popupTagFilter.map { tag in items.filter { $0.tags.contains(tag) } } ?? items
        if !popupSearchQuery.isEmpty {
            let trimmed = popupSearchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 {
                let rankedIDs = hybridSearch(query: popupSearchQuery)
                let allowed = Set(result.map(\.id))
                result = rankedIDs.filter { allowed.contains($0.id) }
            } else if !trimmed.isEmpty {
                let q = ClipboardItem.normalize(trimmed)
                result = result.filter { item in
                    item.searchPreviewNorm.contains(q)
                        || item.searchEmbedNorm.contains(q)
                        || item.searchMetaNorm.contains(q)
                        || (item.ocrText.map { ClipboardItem.normalize($0).contains(q) } ?? false)
                }
            }
        }
        result = applyPinOrdering(result)
        _displayItems = result
        return result
    }

    var _availableTags: [ClipboardTag]? = nil

    func updatePendingPasteID() {
        pendingPasteItemID = displayItems.indices.contains(selectedIndex)
            ? displayItems[selectedIndex].id : nil
    }

    var availableTags: [ClipboardTag] {
        if let cached = _availableTags { return cached }
        var present = Set<ClipboardTag>()
        for item in items {
            for tag in item.tags { present.insert(tag) }
        }
        let result = present.sorted { $0.priority < $1.priority }
        _availableTags = result
        return result
    }

    func itemCount(for tag: ClipboardTag) -> Int {
        items.reduce(0) { $0 + ($1.tags.contains(tag) ? 1 : 0) }
    }

    let previewWindow  = PreviewOverlayWindow()
    let transformPanel = TransformPanel()
    let itemPreviewPanel = ItemPreviewPanel()
    let sharePanel = SharePanel()
    let fastPasteHintPanel = FastPasteHintPanel()
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    var accessibilityPollTimer: Timer?
    var accessibilityActiveObserver: NSObjectProtocol?
    var pendingPasteItemID: UUID? = nil
    var cycleCount: Int = 0
    var transformCycleCount: Int = 0
    var capturedPasteTarget: NSRunningApplication?

    var lastSpaceKeyTime: Date = .distantPast
    var spaceKeyIsDown = false
    var quickClipPanels: [QuickClipPanel] = []
    weak var sharedCarouselPanel: QuickClipPanel?
    var hasVisibleQuickClipPanel: Bool { quickClipPanels.contains { $0.isVisible } }

    var hintKeyVDown = false
    var hintKeyXDown = false
    var hintKeyCDown = false
    var hintKeyBDown = false
    var hintKeySpaceDown = false
    var hintCmdHeld = false
    var hintShiftHeld = false
    var hintSyncScheduled = false

    @Published var reverseCycleUsesB: Bool = UserDefaults.standard.bool(forKey: "reverseCycleUsesB") {
        didSet {
            UserDefaults.standard.set(reverseCycleUsesB, forKey: "reverseCycleUsesB")
            if oldValue != reverseCycleUsesB { AuthManager.shared.registerActionUsage(actionID: "setting.reverse_key") }
        }
    }

    @Published var showFirstCycleHint: Bool = false

    @Published var launchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)

    func refreshLaunchAtLoginStatus() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let enabled = SMAppService.mainApp.status == .enabled
            DispatchQueue.main.async {
                guard let self, self.launchAtLoginEnabled != enabled else { return }
                self.launchAtLoginEnabled = enabled
            }
        }
    }

    var launchAtLogin: Bool {
        get { launchAtLoginEnabled }
        set {
            launchAtLoginEnabled = newValue
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                flashStatus("Couldn't update Launch at login — \(error.localizedDescription)")
                refreshLaunchAtLoginStatus()
            }
        }
    }

    let nlEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    @Published var firstOpenDelay: Double = {
        let stored = UserDefaults.standard.object(forKey: "firstOpenDelay") as? Double ?? 0.0
        return min(max(stored, 0.0), 1.0)
    }() {
        didSet {
            let clamped = min(max(firstOpenDelay, 0.0), 1.0)
            if firstOpenDelay != clamped {
                firstOpenDelay = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "firstOpenDelay")
            if oldValue != firstOpenDelay { AuthManager.shared.registerActionUsage(actionID: "setting.open_delay") }
        }
    }

    @Published var autoDismissEnabled: Bool = UserDefaults.standard.object(forKey: "autoDismissEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoDismissEnabled, forKey: "autoDismissEnabled")
            if oldValue != autoDismissEnabled { AuthManager.shared.registerActionUsage(actionID: "setting.auto_dismiss") }
        }
    }
    @Published var autoDismissSeconds: Double = {
        let stored = UserDefaults.standard.object(forKey: "autoDismissSeconds") as? Double ?? 180
        return min(max(stored, 10), 1800)
    }() {
        didSet {
            let clamped = min(max(autoDismissSeconds, 10), 1800)
            if autoDismissSeconds != clamped {
                autoDismissSeconds = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "autoDismissSeconds")
            if oldValue != autoDismissSeconds { AuthManager.shared.registerActionUsage(actionID: "setting.auto_dismiss_s") }
        }
    }
    var autoDismissTimer: Timer?

    @Published var referenceAppAffinityEnabled: Bool = UserDefaults.standard.object(forKey: "referenceAppAffinityEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(referenceAppAffinityEnabled, forKey: "referenceAppAffinityEnabled") }
    }
    @Published var advanceAfterMark: Bool = UserDefaults.standard.object(forKey: "advanceAfterMark") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(advanceAfterMark, forKey: "advanceAfterMark")
            if oldValue != advanceAfterMark { AuthManager.shared.registerActionUsage(actionID: "setting.advance_after_mark") }
        }
    }
    @Published var openOnSecondTap: Bool = UserDefaults.standard.object(forKey: "openOnSecondTap") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(openOnSecondTap, forKey: "openOnSecondTap")
            if oldValue != openOnSecondTap { AuthManager.shared.registerActionUsage(actionID: "setting.second_tap") }
        }
    }
    static let maxPinnedItems = 5
    @Published var pinStartPosition: Int =
        min(max(1, UserDefaults.standard.object(forKey: "pinStartPosition") as? Int ?? 1), ClipboardManager.maxPinnedItems) {
        didSet {
            UserDefaults.standard.set(pinStartPosition, forKey: "pinStartPosition")
            if oldValue != pinStartPosition { AuthManager.shared.registerActionUsage(actionID: "setting.pin_position") }
        }
    }
    @Published var autoPreviewTypes: Set<AutoPreviewContentType> = AutoPreviewContentType.loadSaved() {
        didSet {
            AutoPreviewContentType.save(autoPreviewTypes)
            if oldValue != autoPreviewTypes { AuthManager.shared.registerActionUsage(actionID: "setting.always_preview") }
            applyAlwaysShowItemPreviewPolicy()
        }
    }
    @Published var rememberLastSelection: Bool = UserDefaults.standard.object(forKey: "rememberLastSelection") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(rememberLastSelection, forKey: "rememberLastSelection")
            if oldValue != rememberLastSelection { AuthManager.shared.registerActionUsage(actionID: "setting.remember_last") }
        }
    }
    var rememberedIndex: Int = 0
    var rememberedItemID: UUID? = nil
    var rememberedSelectionSavedAt: Date? = nil
    @Published var rememberLastPositionTimeoutMinutes: Int =
        UserDefaults.standard.object(forKey: "rememberLastPositionTimeoutMinutes") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(rememberLastPositionTimeoutMinutes, forKey: "rememberLastPositionTimeoutMinutes")
            if oldValue != rememberLastPositionTimeoutMinutes {
                AuthManager.shared.registerActionUsage(actionID: "setting.remember_last_timeout")
            }
        }
    }

    var vTapHoldTimer: Timer?
    var bTapHoldTimer: Timer?
    var pTapHoldTimer: Timer?
    var sTapHoldTimer: Timer?
    @Published var markHoldSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "markHoldSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(markHoldSpeed.rawValue, forKey: "markHoldSpeed")
            if oldValue != markHoldSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.mark_hold_speed") }
        }
    }
    var vHoldThreshold: TimeInterval { markHoldSpeed.holdSeconds }

    @Published var pinHoldSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "pinHoldSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(pinHoldSpeed.rawValue, forKey: "pinHoldSpeed")
            if oldValue != pinHoldSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.pin_hold_speed") }
        }
    }
    var pinHoldThreshold: TimeInterval { pinHoldSpeed.holdSeconds }

    @Published var spaceDoubleTapSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "spaceDoubleTapSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(spaceDoubleTapSpeed.rawValue, forKey: "spaceDoubleTapSpeed")
            if oldValue != spaceDoubleTapSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.space_doubletap_speed") }
        }
    }
    var spaceDoubleTapWindow: TimeInterval { spaceDoubleTapSpeed.doubleTapSeconds }

    @Published var pinnedOpenHoldSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "pinnedOpenHoldSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(pinnedOpenHoldSpeed.rawValue, forKey: "pinnedOpenHoldSpeed")
            if oldValue != pinnedOpenHoldSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.pinned_open_hold_speed") }
        }
    }
    var pinnedOpenHoldThreshold: TimeInterval { pinnedOpenHoldSpeed.holdSeconds }

    var firstOpenHoldTimer: Timer?
    @Published var popupPinnedOpen: Bool = false

    var popupOpenedAt: Date? = nil
    var popupSessionPasted = false

    var historyLoadedCleanly = false

    var xTapHoldTimer: Timer?
    static let xHoldThreshold: TimeInterval = 0.35

    var escapeWillDismiss = false

    var pollTimer: Timer?
    var permissionRetryTimer: Timer?
    var permissionRetryBackoff: TimeInterval = 1.0
    var lastTransformCacheItemID: UUID? = nil
    var pendingFirstOpenTimer: Timer?
    var pendingFirstOpen: Bool = false
    var lastChangeCount: Int = NSPasteboard.general.changeCount
    var remoteClipboardRetryCount = 0
    static let maxRemoteClipboardRetries = 30
    static let maxDiffBadgeTextLength = 20_000
    var remoteClipboardLastFileSize: [String: Int] = [:]
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isSimulatingPaste = false

    private var pasteSimulationToken = 0

    @discardableResult
    func beginPasteSimulation() -> Int {
        pasteSimulationToken &+= 1
        isSimulatingPaste = true
        return pasteSimulationToken
    }

    func endPasteSimulation(token: Int) {
        guard token == pasteSimulationToken else { return }
        isSimulatingPaste = false
    }

    var userOpenedItemPreview = false

    var inTransformStage = false
    var transformIndex   = 0
    var transformDisplaysCache: [TransformDisplay] = []

    @Published var inShareStage = false
    @Published var shareIndex = 0
    var shareServices: [NSSharingService] = []
    var shareTargetItems: [ClipboardItem] = []
    var shareServicesCache: [UUID: [NSSharingService]] = [:]
    var shareSyncGeneration = 0

    var saveCancellable: AnyCancellable?

    @Published var popupCoachStep: Int = UserDefaults.standard.integer(forKey: "popupCoachStep") {
        didSet { UserDefaults.standard.set(popupCoachStep, forKey: "popupCoachStep") }
    }

    @Published var inPageRangeMode: Bool = false
    @Published var pageRangeQuery: String = ""
    @Published var pageRangeManualPages: Set<Int> = []
    @Published var pageRangePageCount: Int = 0
    var pageRangePDF: PDFDocument?
    enum PageRangeOutputMode { case combinedPDF; case perPageImages }
    @Published var pageRangeOutputMode: PageRangeOutputMode = .combinedPDF

    var pageRangeEffectiveSelection: Set<Int> {
        PageRangeParser.parse(pageRangeQuery, maxPage: pageRangePageCount)
            .union(pageRangeManualPages)
    }

    @Published var inLanguagePickerMode: Bool = false
    @Published var languagePickerQuery: String = ""
    @Published var languagePickerSelectedIndex: Int = 0
    var languagePickerSourceItem: ClipboardItem?

    var languagePickerFilteredLanguages: [(name: String, code: String)] {
        var candidates = TextTools.supportedTranslationLanguages
        if let item = languagePickerSourceItem,
           let text = TextTools.input(for: item),
           let detected = AIService.dominantLanguage(text) {
            candidates = candidates.filter { $0.code != detected }
        }
        let q = languagePickerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return candidates }
        return candidates.filter { $0.name.lowercased().contains(q) }
    }

    let saveQueue = DispatchQueue(label: "com.clipen.history-save", qos: .utility)

    private init() {
        UserDefaults.standard.removeObject(forKey: "maxItems")
        saveCancellable = $items
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let snapshot = self.items
                self.saveQueue.async {
                    self.saveHistory(snapshot: snapshot)
                }
            }
    }

    func startMonitoring() {
        loadHistory()
        recomputeEmbeddingsInBackground()
        startPolling()
        startAccessibilityWatcher()
        attemptEventTap()
        startAppAffinityObserver()
    }

    var appActivationObserver: NSObjectProtocol?

    let referenceContextQueue = DispatchQueue(label: "com.clipen.referenceContext")
    var pendingReferenceBundleID: String?

    func startAppAffinityObserver() {
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            self.surfaceReferencePanel(forActiveApp: bundleID)
        }
    }

    func surfaceReferencePanel(forActiveApp bundleID: String) {
        guard referenceAppAffinityEnabled,
              !quickClipPanels.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        let alreadyFetching = pendingReferenceBundleID != nil
        pendingReferenceBundleID = bundleID
        guard !alreadyFetching else { return }
        fetchReferenceContext(for: bundleID)
    }

    private func fetchReferenceContext(for bundleID: String) {
        referenceContextQueue.async { [weak self] in
            let liveContext = AppContextService.currentContext(for: bundleID)
            let tabTexts    = AppContextService.allTabTexts(for: bundleID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyReferenceSurface(bundleID: bundleID, liveContext: liveContext, tabTexts: tabTexts)
                if let latest = self.pendingReferenceBundleID, latest != bundleID {
                    self.fetchReferenceContext(for: latest)
                } else {
                    self.pendingReferenceBundleID = nil
                }
            }
        }
    }

    private func applyReferenceSurface(bundleID: String, liveContext: String?, tabTexts: [String]) {
        guard referenceAppAffinityEnabled,
              !quickClipPanels.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        var matched: QuickClipPanel?
        for panel in quickClipPanels where panel.carousel.jumpToPage(ownedBy: bundleID, context: liveContext) {
            matched = panel
            break
        }

        if matched == nil, let (panel, pageID) = semanticBestMatch(forBundleID: bundleID, in: quickClipPanels, tabTexts: tabTexts) {
            panel.carousel.jumpToPage(id: pageID)
            panel.carousel.linkCurrentPage(toApp: bundleID, context: liveContext)
            matched = panel
        }

        for panel in quickClipPanels {
            if panel === matched {
                AuthManager.shared.registerActionUsage(actionID: "ref.auto_surface")
                panel.restoreIfCollapsed()
                panel.orderFrontRegardless()
            } else {
                panel.collapseToCorner(activeApp: bundleID, activeContext: liveContext)
            }
        }
    }

    func startAccessibilityWatcher() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        let trusted = AXIsProcessTrusted()
        if hasAccessibilityPermission != trusted {
            hasAccessibilityPermission = trusted
        }

        if accessibilityActiveObserver == nil {
            accessibilityActiveObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                self?.refreshAccessibilityStatusOnActivate()
            }
        }

        if trusted && eventTap != nil { return }

        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if self.hasAccessibilityPermission != now {
                self.hasAccessibilityPermission = now
            }
            if now && self.eventTap != nil {
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                return
            }
            if now && self.eventTap == nil {
                self.attemptEventTap()
            }
        }
        RunLoop.main.add(accessibilityPollTimer!, forMode: .common)
    }

    func refreshAccessibilityStatusOnActivate() {
        let now = AXIsProcessTrusted()
        if hasAccessibilityPermission != now { hasAccessibilityPermission = now }
        if now && eventTap == nil { attemptEventTap() }
        if (!now || eventTap == nil) && accessibilityPollTimer == nil {
            startAccessibilityWatcher()
        }
    }

}

struct ClipboardItem: Identifiable {
    let id:        UUID
    let timestamp: Date
    let content:   ClipboardContent
    let detectedType: ClipboardContentType
    let tags: [ClipboardTag]
    let primaryTag: ClipboardTag
    let detectedColor: NSColor?
    var isPinned:  Bool     = false
    var embedding: [Float]? = nil
    var urlTitle:  String?  = nil { didSet { rebuildSearchHaystacks() } }
    var diffBadge: String?  = nil
    var sourceAppName: String? = nil { didSet { rebuildSearchHaystacks() } }
    var sourceBundleID: String? = nil
    var userNote: String? = nil { didSet { rebuildSearchHaystacks() } }
    var ocrText: String? = nil { didSet { rebuildSearchHaystacks() } }
    var sidecarTypes: [String: Data]? = nil

    var pastedToAppName:  String? = nil
    var pastedToBundleID: String? = nil
    var lastPastedAt: Date? = nil

    var pasteCount: Int = 0
    var pasteCountByApp: [String: Int] = [:]
    var pastedToAppNames: [String: String] = [:]

    private(set) var searchPreviewNorm: String = ""
    private(set) var searchEmbedNorm:   String = ""
    private(set) var searchMetaNorm:    String = ""

    init(content: ClipboardContent, id: UUID = UUID(), timestamp: Date = Date(),
         urlTitle: String? = nil, sourceAppName: String? = nil,
         userNote: String? = nil, ocrText: String? = nil) {
        self.id        = id
        self.timestamp = timestamp
        self.content   = content
        self.urlTitle      = urlTitle
        self.sourceAppName = sourceAppName
        self.userNote  = userNote
        self.ocrText   = ocrText
        self.detectedColor = ContentDetector.detectedColor(for: content)
        self.detectedType  = ContentDetector.detectedType(for: content, color: self.detectedColor)
        self.tags         = TagDetector.tags(for: content, color: self.detectedColor)
        self.primaryTag   = TagDetector.primaryTag(from: self.tags)
        rebuildSearchHaystacks()
    }

    mutating func rebuildSearchHaystacks() {
        metadataSummary  = Self.computeMetadataSummary(for: content)
        textForEmbedding = Self.computeTextForEmbedding(content: content,
                                                       urlTitle: urlTitle,
                                                       sourceAppName: sourceAppName)
        searchPreviewNorm = Self.normalize(previewText)
        searchEmbedNorm   = Self.normalize(textForEmbedding ?? "")
        searchMetaNorm    = Self.normalize(metadataSummary ?? "")
        if let ocr = ocrText, !ocr.isEmpty {
            searchEmbedNorm += " " + Self.normalize(ocr)
        }
        if let note = userNote, !note.isEmpty {
            searchEmbedNorm += " " + Self.normalize(note)
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
    }

    var richEmbeddingText: String? {
        var parts: [String] = []
        if let base = textForEmbedding { parts.append(base) }
        if let ocr = ocrText, !ocr.isEmpty { parts.append(String(ocr.prefix(800))) }
        if let note = userNote, !note.isEmpty { parts.append(note) }
        if let title = urlTitle, !title.isEmpty, textForEmbedding?.contains(title) != true {
            parts.append(title)
        }
        let destinations = pastedToAppNames.values.sorted()
        if !destinations.isEmpty { parts.append("pasted into \(destinations.joined(separator: " "))") }
        guard !parts.isEmpty else { return nil }
        return String(parts.joined(separator: " ").prefix(1_500))
    }

    var previewText: String {
        switch content {
        case .text(let s):               return String(s.prefix(200))
        case .image:                     return "[Image]"
        case .richText(_, plain: let s): return String(s.prefix(200))
        case .html(_, plain: let s):     return String(s.prefix(200))
        case .rtfd(_, plain: let s):     return String(s.prefix(200))
        case .file(let url):             return url.lastPathComponent
        case .files(let urls):           return "\(urls.count) files"
        case .svg:                       return "[SVG]"
        case .blob(let d):               return "[\(d.count) private types]"
        }
    }

    var iconName: String {
        switch content {
        case .text:     return "doc.text"
        case .image:    return "photo"
        case .richText: return "doc.richtext"
        case .html:     return "globe"
        case .rtfd:     return "tablecells"
        case .file:     return "doc"
        case .files:    return "doc.on.doc"
        case .svg:      return "square.on.circle"
        case .blob:     return "lock.doc"
        }
    }

    var typeLabel: String {
        switch content {
        case .text:             return detectedType.badgeLabel ?? "Text"
        case .image(_, _, let dataType):
            if dataType.rawValue.contains("gif") { return "GIF" }
            if dataType.rawValue.contains("pdf") { return "PDF" }
            return "Image"
        case .richText:         return "Rich Text"
        case .html:             return "HTML"
        case .rtfd:             return "Table"
        case .file(let url):
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "File" : ext
        case .files(let urls):
            return "\(urls.count) Files"
        case .svg:              return "SVG"
        case .blob:             return "Private"
        }
    }

    var typeIcon: String {
        switch content {
        case .text:             return detectedType.sfIcon
        case .image:            return "photo"
        case .richText:         return "doc.richtext"
        case .html:             return "globe"
        case .rtfd:             return "tablecells"
        case .file(let url):
            return Self.iconName(for: url)
        case .files:            return "doc.on.doc"
        case .svg:              return "square.on.circle"
        case .blob:             return "lock.doc"
        }
    }

    private(set) var metadataSummary: String?

    static func computeMetadataSummary(for content: ClipboardContent) -> String? {
        switch content {
        case .image(let img, let data, let dataType):
            let dims = "\(Int(img.size.width))×\(Int(img.size.height))"
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return "\(dims) · \(size) · \(dataType.rawValue)"
        case .file(let url):
            return fileMetadataSummary(for: url)
        case .files(let urls):
            let total = urls.compactMap { fileSize($0) }.reduce(0, +)
            let size = total > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file) : ""
            return "\(urls.count) files\(size)"
        default:
            return nil
        }
    }

    static func iconName(for url: URL) -> String {
        if FileKindDetector.isVideoFile(url) { return "film" }
        if FileKindDetector.isAudioFile(url) { return "music.note" }
        if FileKindDetector.isArchiveFile(url) { return "archivebox" }
        if FileKindDetector.isFontFile(url) { return "textformat" }
        if FileKindDetector.isDesignFile(url) { return "paintbrush" }
        if FileKindDetector.is3DModelFile(url) { return "cube" }
        if FileKindDetector.isDataFile(url) { return "externaldrive" }
        if FileKindDetector.isInstallerFile(url) { return "shippingbox" }
        switch url.pathExtension.lowercased() {
        case "pdf":                              return "doc.richtext"
        case "ppt", "pptx", "pps", "ppsx":       return "chart.bar.doc.horizontal"
        case "xls", "xlsx", "xlsm", "numbers":   return "tablecells"
        case "doc", "docx", "pages":             return "doc.text"
        case "key":                              return "play.rectangle"
        case "png","jpg","jpeg","heic","gif",
             "raw","cr2","cr3","nef","arw",
             "dng":                              return "photo"
        case "swift":                            return "swift"
        case "py":                               return "terminal"
        case "js","ts","jsx","tsx":              return "chevron.left.forwardslash.chevron.right"
        case "html","htm","webarchive":          return "globe"
        case "md","markdown":                    return "doc.plaintext"
        case "csv","tsv":                        return "tablecells"
        case "epub","mobi","azw3":               return "book"
        case "ics":                              return "calendar"
        case "vcf":                              return "person.crop.square"
        case "srt","vtt":                        return "captions.bubble"
        default:                                 return "doc"
        }
    }

    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    static func fileMetadataSummary(for url: URL) -> String? {
        var parts: [String] = []
        if let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            parts.append(type)
        }
        if let size = fileSize(url) {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
            parts.append(Self.relativeDateFormatter.localizedString(for: modified, relativeTo: Date()))
        }

        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "gif", "tiff"].contains(ext),
           let img = NSImage(contentsOf: url) {
            parts.insert("\(Int(img.size.width))×\(Int(img.size.height))", at: 0)
        } else if ext == "pdf", let pdf = PDFDocument(url: url) {
            let pages = pdf.pageCount == 1 ? "1 page" : "\(pdf.pageCount) pages"
            parts.insert(pages, at: 0)
            if let title = pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty {
                parts.insert(title, at: 0)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var relativeTimestamp: String {
        Self.relativeDateFormatter.localizedString(for: timestamp, relativeTo: Date())
    }

    var image: NSImage? {
        if case .image(let img, _, _) = content { return img }
        return nil
    }

    private(set) var textForEmbedding: String?

    static func computeTextForEmbedding(content: ClipboardContent,
                                                urlTitle: String?,
                                                sourceAppName: String?) -> String? {
        switch content {
        case .text(let s):               return s.isEmpty ? nil : s
        case .richText(_, plain: let s): return s.isEmpty ? nil : s
        case .html(_, plain: let s):     return s.isEmpty ? nil : s
        case .rtfd(_, plain: let s):     return s.isEmpty ? nil : s
        case .image(let img, let data, let dataType):
            var parts: [String] = ["image"]
            let raw = dataType.rawValue.lowercased()
            if raw.contains("png")       { parts.append("PNG") }
            else if raw.contains("gif")  { parts.append("GIF animation") }
            else if raw.contains("heic") { parts.append("HEIC photo") }
            else if raw.contains("pdf")  { parts.append("PDF document") }
            else if raw.contains("webp") { parts.append("WebP") }
            else                         { parts.append("JPEG photo") }
            parts.append("\(Int(img.size.width))×\(Int(img.size.height)) pixels")
            let kb = data.count / 1_024
            parts.append(kb > 1_024 ? "\(kb / 1_024) MB" : "\(kb) KB")
            if let title = urlTitle     { parts.append(title) }
            if let app   = sourceAppName { parts.append("from \(app)") }
            return parts.joined(separator: " ")
        case .file(let url):
            var s = fileMetadataEmbeddingText(for: url)
            if let app = sourceAppName { s += " from \(app)" }
            return s
        case .files(let urls):
            let parts = urls.prefix(5).map { fileMetadataEmbeddingText(for: $0) }
            if parts.isEmpty { return nil }
            let prefix = urls.count > 1 ? "\(urls.count) files " : ""
            var s = prefix + parts.joined(separator: " | ")
            if let app = sourceAppName { s += " from \(app)" }
            return s
        case .svg(let src):
            return src.isEmpty ? nil : String(src.prefix(500))
        case .blob(let d):
            return d.isEmpty ? nil : "private data \(d.keys.sorted().joined(separator: " "))"
        }
    }

    static func fileMetadataEmbeddingText(for url: URL) -> String {
        var parts: [String] = []
        let filename = url.lastPathComponent
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext      = url.pathExtension.lowercased()
        let readableName = baseName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        parts.append(filename)
        if readableName != baseName { parts.append(readableName) }
        if FileKindDetector.isImageFile(url)           { parts.append("image photo picture \(ext)") }
        else if FileKindDetector.isVideoFile(url)      { parts.append("video movie clip \(ext)") }
        else if FileKindDetector.isAudioFile(url)      { parts.append("audio music sound recording \(ext)") }
        else if ext == "pdf"                           { parts.append("PDF document") }
        else if FileKindDetector.isTextFile(url)       { parts.append("text code \(ext) document") }
        else if FileKindDetector.isDocumentFile(url)   { parts.append("document file \(ext)") }
        else if FileKindDetector.isArchiveFile(url)    { parts.append("archive zip compressed \(ext)") }
        else if FileKindDetector.isDesignFile(url)     { parts.append("design file \(ext)") }
        else if !ext.isEmpty                           { parts.append(ext) }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = (attrs[.size] as? NSNumber)?.intValue {
            let kb = bytes / 1_024
            parts.append(kb > 1_024 ? "\(kb / 1_024) MB" : "\(kb) KB")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    func isDuplicate(of other: ClipboardItem) -> Bool {
        switch (content, other.content) {
        case (.text(let a),                     .text(let b)):                     return a == b
        case (.richText(_, plain: let a),       .richText(_, plain: let b)):       return a == b
        case (.html(let a, _),                  .html(let b, _)):                  return a == b
        case (.file(let a),                     .file(let b)):                     return a == b
        case (.files(let a),                    .files(let b)):                    return a == b
        default:                                                                   return false
        }
    }
}

enum AutoPreviewContentType: String, CaseIterable, Identifiable, Codable {
    case text, code, link, json, markdown, email, phone, color
    case richText, html, table, image, pdf, file, files, svg, blob

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:     return "Text"
        case .code:     return "Code"
        case .link:     return "Link"
        case .json:     return "JSON"
        case .markdown: return "Markdown"
        case .email:    return "Email"
        case .phone:    return "Phone"
        case .color:    return "Color"
        case .richText: return "Rich Text"
        case .html:     return "HTML"
        case .table:    return "Table"
        case .image:    return "Image"
        case .pdf:      return "PDF"
        case .file:     return "File"
        case .files:    return "Files"
        case .svg:      return "SVG"
        case .blob:     return "Private"
        }
    }

    var sfIcon: String {
        switch self {
        case .text:     return "doc.text"
        case .code:     return "chevron.left.forwardslash.chevron.right"
        case .link:     return "link"
        case .json:     return "curlybraces"
        case .markdown: return "doc.plaintext"
        case .email:    return "envelope"
        case .phone:    return "phone"
        case .color:    return "paintpalette"
        case .richText: return "doc.richtext"
        case .html:     return "globe"
        case .table:    return "tablecells"
        case .image:    return "photo"
        case .pdf:      return "doc.richtext.fill"
        case .file:     return "doc"
        case .files:    return "doc.on.doc"
        case .svg:      return "square.on.circle"
        case .blob:     return "lock.doc"
        }
    }

    static func from(_ item: ClipboardItem) -> AutoPreviewContentType {
        switch item.content {
        case .text:
            switch item.detectedType {
            case .code:     return .code
            case .url:      return .link
            case .json:     return .json
            case .markdown, .latex: return .markdown
            case .email:    return .email
            case .phone:    return .phone
            case .hexColor: return .color
            case .table:    return .table
            case .plain, .address: return .text
            }
        case .richText: return .richText
        case .html:     return .html
        case .rtfd:     return .table
        case .image(_, _, let dataType):
            return dataType.rawValue.contains("pdf") ? .pdf : .image
        case .file(let url):
            return url.pathExtension.lowercased() == "pdf" ? .pdf : .file
        case .files:    return .files
        case .svg:      return .svg
        case .blob:     return .blob
        }
    }

    private static let defaultsKey = "autoPreviewTypes"

    static func loadSaved() -> Set<AutoPreviewContentType> {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [String] else { return [] }
        return Set(raw.compactMap(AutoPreviewContentType.init(rawValue:)))
    }

    static func save(_ types: Set<AutoPreviewContentType>) {
        UserDefaults.standard.set(types.map(\.rawValue), forKey: defaultsKey)
    }
}

enum ClipboardContent {
    case text(String)
    case image(NSImage, rawData: Data, dataType: NSPasteboard.PasteboardType)
    case richText(NSAttributedString, plain: String)
    case html(String, plain: String)
    case rtfd(Data, plain: String)
    case file(URL)
    case files([URL])
    case svg(String)
    case blob([String: Data])

    var plainText: String? {
        switch self {
        case .text(let s):               return s
        case .richText(_, plain: let s): return s
        case .html(_, plain: let s):     return s
        case .rtfd(_, plain: let s):     return s
        case .svg(let s):                return s
        default:                         return nil
        }
    }

    static func imageContent(rawData: Data, dataType: NSPasteboard.PasteboardType,
                             fallback: @autoclosure () -> NSImage?) -> ClipboardContent? {
        if !dataType.rawValue.lowercased().contains("pdf"),
           let thumb = NSImage.ringThumbnail(from: rawData) {
            return .image(thumb, rawData: rawData, dataType: dataType)
        }
        guard let fallback = fallback() else { return nil }
        return .image(fallback, rawData: rawData, dataType: dataType)
    }
}

enum GestureSpeed: String, CaseIterable, Identifiable {
    case fast, medium, slow
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fast:   return "Fast"
        case .medium: return "Medium"
        case .slow:   return "Slow"
        }
    }
    var holdSeconds: TimeInterval {
        switch self {
        case .fast:   return 0.15
        case .medium: return 0.2
        case .slow:   return 0.35
        }
    }
    var doubleTapSeconds: TimeInterval {
        switch self {
        case .fast:   return 0.25
        case .medium: return 0.35
        case .slow:   return 0.5
        }
    }
}

extension String {
    var displayTrimmedLeading: String {
        String(drop(while: \.isWhitespace))
    }

    func displayCapped(_ maxLength: Int = 300_000) -> (text: String, isTruncated: Bool) {
        guard count > maxLength else { return (self, false) }
        return (String(prefix(maxLength)), true)
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    static func ringThumbnail(from data: Data, maxPixel: CGFloat = 1024) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = (props?[kCGImagePropertyPixelWidth]  as? NSNumber)?.doubleValue ?? Double(cg.width)
        let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? Double(cg.height)
        return NSImage(cgImage: cg, size: NSSize(width: w, height: h))
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        let h = hexString.trimmingCharacters(in: .init(charactersIn: "#"))
        var val: UInt64 = 0
        guard Scanner(string: h).scanHexInt64(&val) else { return nil }
        if h.count == 6 {
            self.init(red: CGFloat((val >> 16) & 0xFF) / 255,
                      green: CGFloat((val >> 8)  & 0xFF) / 255,
                      blue:  CGFloat( val        & 0xFF) / 255, alpha: 1)
        } else if h.count == 3 {
            let r = (val >> 8) & 0xF; let g = (val >> 4) & 0xF; let b = val & 0xF
            self.init(red: CGFloat(r | (r << 4)) / 255, green: CGFloat(g | (g << 4)) / 255,
                      blue: CGFloat(b | (b << 4)) / 255, alpha: 1)
        } else { return nil }
    }
}

extension String {
    var htmlDecoded: String {
        self.replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    var titleCased: String {
        components(separatedBy: .whitespaces)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    var toCamelCase: String {
        let words = components(separatedBy: .init(charactersIn: " _-")).filter { !$0.isEmpty }
        return words.enumerated().map { i, w in i == 0 ? w.lowercased() : w.capitalized }.joined()
    }

    var toSnakeCase: String {
        unicodeScalars.reduce("") { acc, char in
            if CharacterSet.uppercaseLetters.contains(char) && !acc.isEmpty {
                return acc + "_" + String(char).lowercased()
            }
            return acc + String(char)
        }
        .replacingOccurrences(of: " ", with: "_")
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
    }

    var toKebabCase: String {
        toSnakeCase.replacingOccurrences(of: "_", with: "-")
    }
}

extension ClipboardItem {
    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        switch content {
        case .text(let str):
            provider.registerObject(str as NSString, visibility: .all)
        case .richText(let attrStr, let plain):
            if let rtfData = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                provider.registerDataRepresentation(forTypeIdentifier: "public.rtf", visibility: .all) { completion in
                    completion(rtfData, nil)
                    return nil
                }
            }
            provider.registerObject(plain as NSString, visibility: .all)
        case .html(let html, let plain):
            if let htmlData = html.data(using: .utf8) {
                provider.registerDataRepresentation(forTypeIdentifier: "public.html", visibility: .all) { completion in
                    completion(htmlData, nil)
                    return nil
                }
            }
            provider.registerObject(plain as NSString, visibility: .all)
        case .rtfd(let rtfdData, let plain):
            provider.registerDataRepresentation(forTypeIdentifier: "com.apple.rtfd", visibility: .all) { completion in
                completion(rtfdData, nil)
                return nil
            }
            if let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil),
               let rtfData = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                provider.registerDataRepresentation(forTypeIdentifier: "public.rtf", visibility: .all) { completion in
                    completion(rtfData, nil)
                    return nil
                }
            }
            provider.registerObject(plain as NSString, visibility: .all)
        case .image(let img, let rawData, let dataType):
            provider.registerDataRepresentation(forTypeIdentifier: dataType.rawValue, visibility: .all) { completion in
                completion(rawData, nil)
                return nil
            }
            provider.registerObject(NSImage(data: rawData) ?? img, visibility: .all)
        case .file(let url):
            provider.registerObject(url as NSURL, visibility: .all)
        case .files(let urls):
            if let first = urls.first {
                provider.registerObject(first as NSURL, visibility: .all)
            }
        case .svg(let src):
            provider.registerObject(src as NSString, visibility: .all)
        case .blob(let dict):
            if let firstKey = dict.keys.first, let firstData = dict[firstKey] {
                provider.registerDataRepresentation(forTypeIdentifier: firstKey, visibility: .all) { completion in
                    completion(firstData, nil)
                    return nil
                }
            }
        }
        return provider
    }

    func makePasteboardWriter() -> NSPasteboardWriting {
        switch content {
        case .file(let url):
            return url as NSURL
        case .files(let urls):
            if let first = urls.first { return first as NSURL }
            return NSPasteboardItem()
        default:
            let pbItem = NSPasteboardItem()
            switch content {
            case .text(let str):
                pbItem.setString(str, forType: .string)
            case .richText(let attrStr, let plain):
                if let rtfData = try? attrStr.data(from: NSRange(location: 0, length: attrStr.length),
                                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    pbItem.setData(rtfData, forType: .rtf)
                }
                pbItem.setString(plain, forType: .string)
            case .html(let html, let plain):
                if let htmlData = html.data(using: .utf8) {
                    pbItem.setData(htmlData, forType: .html)
                }
                pbItem.setString(plain, forType: .string)
            case .rtfd(let rtfdData, let plain):
                pbItem.setData(rtfdData, forType: .rtfd)
                pbItem.setString(plain, forType: .string)
            case .image(_, let rawData, let dataType):
                pbItem.setData(rawData, forType: dataType)
            case .svg(let src):
                pbItem.setString(src, forType: .string)
            case .blob(let dict):
                if let firstKey = dict.keys.first, let firstData = dict[firstKey] {
                    pbItem.setData(firstData, forType: NSPasteboard.PasteboardType(firstKey))
                }
            case .file, .files:
                break
            }
            return pbItem
        }
    }

    static func makeCombinedItemProvider(for items: [ClipboardItem]) -> NSItemProvider {
        let provider = NSItemProvider()

        let fileURLs: [URL] = items.flatMap { item -> [URL] in
            switch item.content {
            case .file(let u):   return [u]
            case .files(let us): return us
            default:             return []
            }
        }
        for url in fileURLs {
            provider.registerObject(url as NSURL, visibility: .all)
        }

        let textParts: [String] = items.compactMap { item in
            switch item.content {
            case .text(let s):             return s.isEmpty ? nil : s
            case .richText(_, let s):      return s.isEmpty ? nil : s
            case .html(_, let s):          return s.isEmpty ? nil : s
            case .rtfd(_, let s):          return s.isEmpty ? nil : s
            case .svg(let s):              return s.isEmpty ? nil : s
            case .file(let url):           return url.lastPathComponent
            case .files(let urls):         return urls.map(\.lastPathComponent).joined(separator: "\n")
            case .image, .blob:            return nil
            }
        }
        if !textParts.isEmpty {
            let combined = textParts.joined(separator: "\n")
            provider.registerObject(combined as NSString, visibility: .all)
        }

        if let firstItem = items.first {
            switch firstItem.content {
            case .richText(let attrStr, _):
                let range = NSRange(location: 0, length: attrStr.length)
                if let rtfData = try? attrStr.data(from: range,
                                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    provider.registerDataRepresentation(forTypeIdentifier: "public.rtf", visibility: .all) { cb in
                        cb(rtfData, nil); return nil
                    }
                }
            case .html(let html, _):
                if let htmlData = html.data(using: .utf8) {
                    provider.registerDataRepresentation(forTypeIdentifier: "public.html", visibility: .all) { cb in
                        cb(htmlData, nil); return nil
                    }
                }
            default: break
            }
        }

        return provider
    }
}
