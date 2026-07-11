import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import NaturalLanguage
import ServiceManagement
@preconcurrency import PDFKit



class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    // MARK: - Stored properties belonging to logic split across
    // ClipboardManager+*.swift extension files. Swift extensions can't hold
    // stored properties, so these live here even though the code that reads
    // and writes them lives in the split-out files below.

    // — Persistence (ClipboardManager+Persistence.swift) —
    /// `Application Support/Clipen`.  `lazy` so the directory-create call runs
    /// exactly once per process — every other access is a stored-URL read.
    lazy var historyDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    /// Blob paths already written for an item's immutable payloads, so the
    /// debounced save doesn't AES-encrypt and rewrite every image/blob/sidecar
    /// file on EVERY save. Keyed by item ID.
    var imageBlobCache:   [UUID: (path: String, bytes: Int)] = [:]
    var payloadBlobCache: [UUID: String] = [:]   // .blob typeMap JSON
    var sidecarBlobCache: [UUID: String] = [:]
    /// Both flags live on saveQueue (set via saveQueue.async from mutating
    /// call sites, read/cleared inside saveHistory which runs on saveQueue)
    /// — same single-queue discipline as the blob caches above.
    ///
    /// True when any item's embedding changed since the last embeddings-file
    /// write — the id→vector dictionary file is only rewritten then, so the
    /// common save (a capture, a paste-counter bump) rewrites just the small
    /// manifest instead of ~6 KB of floats per item every time.
    var embeddingsDirty = false
    /// True when a save could possibly have orphaned a blob file: an item
    /// was removed/evicted, or content was replaced. Capture-only saves
    /// can't orphan anything, so they skip the full blobs-directory walk
    /// that used to run unconditionally after every single save. Starts
    /// true so the first save after launch sweeps anything a crash left.
    var blobPurgeNeeded = true

    // — Panels (ClipboardManager+Panels.swift) —
    /// True while the transform stage is showing MARKED-SET tools (2+ items
    /// in the mark queue when X was pressed) instead of the selected item's
    /// single-item tools.
    var transformingMarkedSet = false

    // — Search (ClipboardManager+Search.swift) —
    let fastPasteHintShownKey = "hasShownFastPasteHint"
    /// Hybrid-search result cache. Key is (query, items.count, embeddedItemCount).
    var lastSearchQuery: String?
    var lastSearchResult: [ClipboardItem] = []
    var lastSearchItemsRev: Int = -1
    var lastSearchEmbedRev: Int = -1
    var embeddedItemCount: Int = 0

    /// Single cap for all data handled by Clipen — backend-driven via features.py `max_data_bytes`.
    static var maxDataBytes: Int { AuthManager.shared.maxDataBytes }

    @Published var items: [ClipboardItem] = [] {
        didSet {
            _displayItems = nil
            _availableTags = nil
            updatePendingPasteID()
            // Deleting an item (⌫ in the popup, X in the main window, ring
            // eviction) must also drop it from the mark queue — stale IDs
            // made every later item's "n. marked" ordinal wrong, since
            // markOrder counts positions in this array.
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

    /// Bumped every time the popup transitions from hidden to shown
    /// (openPopupNow). The popup's ScrollView reuses the same hosting
    /// controller/view hierarchy across hide/show cycles (see
    /// PreviewOverlayWindow.showAnchored), so onAppear only fires once for
    /// its whole lifetime and a manual scroll offset otherwise survives
    /// collapse → reopen. Observing this generation forces a fresh
    /// scroll-to-selection on every real reopen, regardless of whether
    /// selectedIndex itself changed.
    @Published var popupOpenGeneration: Int = 0

    /// Popup header legend — blue while the matching key/modifier is held.
    @Published var popupHintV = false
    @Published var popupHintShiftV = false
    /// True only once a V-hold has actually crossed vHoldThreshold and fired
    /// the mark — NOT just "V is down". Lets "hold V · Mark" light up
    /// distinctly from "V · Next", instead of both flashing together the
    /// instant V is pressed (which made tap vs hold indistinguishable in
    /// the hints). Cleared on V key-up.
    @Published var popupHintVMark = false
    @Published var popupHintX = false
    @Published var popupHintShiftX = false
    /// Same idea as popupHintVMark, for "hold X · Close" — true only once
    /// the X-hold has crossed xHoldThreshold, not just "X is down".
    @Published var popupHintXHold = false
    @Published var popupHintC = false
    @Published var popupHintSpace = false
    /// Brief flash (see flashSpaceDoubleTapHint) when a real double-tap Space
    /// pins the selection — double-tap has no "held" state to react to like
    /// the other hints, so this is a timed pulse instead of a live key state.
    @Published var popupHintSpaceDoubleTap = false
    @Published var popupHintCmd = false

    /// Items marked for sequential multi-paste. Session-only — always
    /// cleared on paste or dismiss. Never persisted to disk. Populated either
    /// by holding V (mark order) or by ⌘/⇧-click in the popup row list
    /// (Finder-style multi-select) — paste order is always resolved from
    /// `displayItems` position at commit time, not this array's order.
    @Published var markedItemIDs: [UUID] = []

    /// Anchor row for Finder-style ⇧-click range selection in the popup —
    /// the "other end" of the range a ⇧-click extends from. Set on every
    /// plain click and ⌘-click; read (not written) by a ⇧-click.
    var multiSelectAnchorIndex: Int? = nil

    /// Popup-only tag filter. nil = Recents (no filter).
    /// Drives displayItems + popup chip strip. The main window has its own
    /// independent @State local filter — this property must never be touched from there.
    @Published var popupTagFilter: ClipboardTag? = nil {
        didSet {
            _displayItems = nil
            selectedIndex = 0
            if previewWindow.isVisible { syncItemPreviewWithSelection() }
        }
    }

    /// Live text typed by the user while the popup is open to filter items inline.
    /// Routed via the CGEventTap (not a focused TextField) so the popup stays
    /// non-activating. Session-only — cleared on dismiss.
    @Published var popupSearchQuery: String = "" {
        didSet {
            _displayItems = nil
            selectedIndex = 0
        }
    }
    /// True once the user has explicitly pressed F to enter search mode.
    /// While active: Space types a literal space instead of toggling preview,
    /// releasing ⌘ does NOT commit/dismiss (so the user can let go and type
    /// normally), and ↑/↓ move the selection without needing ⌘ held. Exited
    /// via Esc or by committing a paste (Enter, or the normal ⌘-release path
    /// once search is off).
    @Published var isSearchActive: Bool = false
    // Plan-driven ring cap. private(set) — external code must use setRingSize(_:).
    // Never persisted to UserDefaults so it cannot be overridden via `defaults write`.
    @Published var maxItems: Int = 10 {
        didSet {
            // Trim must happen on the next runloop tick to avoid mutating
            // @Published state while SwiftUI is mid-render (undefined behaviour warning).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let unpinned = self.items.indices.filter { !self.items[$0].isPinned }
                if unpinned.count > self.maxItems {
                    let toRemove = unpinned.suffix(from: self.maxItems)
                    for idx in toRemove.reversed() {
                        // Same cleanup every other removal path does — without
                        // it, shrinking the ring size stranded the evicted
                        // items' copied files in FileCopies/ forever.
                        self.evictFileSnapshots(for: self.items[idx])
                        self.items.remove(at: idx)
                    }
                    self.markBlobPurgeNeeded()
                }
            }
        }
    }

    /// Public setter for the ring size. Clamps to the plan's maximum so the UI
    /// cannot exceed what the plan allows even if the Stepper range is wrong.
    /// Also persists the user's chosen size so it survives app launches.
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

    /// User-controllable clipboard-capture pause. Lives only in memory —
    /// resumes capturing on app restart. Toggled via menu bar right-click.
    @Published var isCapturingPaused: Bool = false

    /// Short transient status string (shown ~2.5s) — used for things like
    /// "No text found in image" after a failed transform. Cleared automatically.
    @Published var transientStatus: String? = nil

    /// When true, the "Open delay" slider card in MainWindowView draws a
    /// pulsing accent-color glow + instructional caption.  Flipped on by
    /// `pulseOpenDelaySlider()` (called when the user clicks the "Open
    /// delay slider" button in the first-fast-paste alert) and auto-clears
    /// after a few seconds.  Pure UI affordance — no persistence.
    @Published var highlightOpenDelaySlider: Bool = false

    func pulseOpenDelaySlider(duration: TimeInterval = 6.0) {
        DispatchQueue.main.async { [weak self] in self?.highlightOpenDelaySlider = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            self?.highlightOpenDelaySlider = false
        }
    }

    /// Set `transientStatus` to a message, then clear it after a few seconds.
    func flashStatus(_ msg: String, duration: TimeInterval = 2.5) {
        DispatchQueue.main.async { [weak self] in self?.transientStatus = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            if self?.transientStatus == msg { self?.transientStatus = nil }
        }
    }

    /// Tag filtering: exactly the same logic as `mainFilteredItems` in
    /// MainWindowView. Search: the SAME hybridSearch() used by the main
    /// window's search bar and by similarItems() — this used to be a
    /// separate plain substring `.contains()` filter, the one surface of the
    /// three that wasn't using the shared lexical+semantic+recency scorer.
    var _displayItems: [ClipboardItem]? = nil
    var displayItems: [ClipboardItem] {
        if let cached = _displayItems { return cached }
        var result = popupTagFilter.map { tag in items.filter { $0.tags.contains(tag) } } ?? items
        if !popupSearchQuery.isEmpty {
            let trimmed = popupSearchQuery.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 2 {
                // hybridSearch ranks/filters over the FULL ring, so intersect its
                // result with the tag-filtered set (preserving hybridSearch's
                // relevance order) rather than re-scoring only the tag subset.
                let rankedIDs = hybridSearch(query: popupSearchQuery)
                let allowed = Set(result.map(\.id))
                result = rankedIDs.filter { allowed.contains($0.id) }
            } else if !trimmed.isEmpty {
                // hybridSearch requires ≥2 chars (1-char embeddings/scoring is
                // pure noise) — without this fallback, the FIRST character
                // typed showed an empty list until the second arrived. Plain
                // substring filtering is the right behavior for one character.
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

    /// Tags that appear on at least one item in the full ring. Drives both popup + main window chip strips.
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
    /// Mirrors `AXIsProcessTrusted()`. Initialized synchronously so the
    /// onboarding screen doesn't flash on launch for users who already
    /// granted permission in a previous run. Refreshed by a 1Hz timer in
    /// `startAccessibilityWatcher()` so the UI auto-advances the moment
    /// the user flips the toggle in System Settings — even if our event
    /// tap creation races with TCC propagation.
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    var accessibilityPollTimer: Timer?
    // ID of the item the user last explicitly selected. Resolved in
    // commitPaste() so a displayItems rebuild between selection and ⌘ release
    // never causes a stale-index paste (the root cause of the wrong-item bug).
    var pendingPasteItemID: UUID? = nil
    var cycleCount: Int = 0
    var transformCycleCount: Int = 0
    /// The frontmost app captured the moment the popup opens — BEFORE any of
    /// Clipen's own windows (including the ring popup's NSPopover) exist on
    /// screen, so this is trusted as the real paste destination even if
    /// showing our own UI later shifts which app macOS considers frontmost.
    /// commitPaste() reactivates this app before pasting instead of trusting
    /// a fresh `NSWorkspace.shared.frontmostApplication` query at release time.
    var capturedPasteTarget: NSRunningApplication?

    // MARK: - Double-space Quick Clip panel state
    /// Timestamp of the most recent Space keydown (outside popup). Used to
    /// detect a "double-tap" that opens a QuickClipPanel.
    var lastSpaceKeyTime: Date = .distantPast
    /// True for the whole duration the physical Space key is held down.
    /// Tracked independently of CGEvent's autorepeat flag — that flag isn't
    /// always reliable coming through an event tap, and when it misreports a
    /// held key as a stream of fresh presses, each one can land inside the
    /// 0.35s double-tap window and re-fire openQuickClipPanel over and over
    /// (a new pinned panel appearing continuously for as long as Space is
    /// held). This latch guarantees only the FIRST physical keyDown of a
    /// press is ever evaluated as a tap, no matter what autorepeat reports.
    var spaceKeyIsDown = false
    /// All currently-open QuickClip floating panels (max 5). Normally just
    /// one — new pins are added as pages to `sharedCarouselPanel` instead of
    /// opening a second window — plus however many the user has explicitly
    /// popped out into their own standalone panel.
    var quickClipPanels: [QuickClipPanel] = []
    /// The ONE panel new pins merge into by default (one panel, horizontal
    /// paging between references). nil once it's closed or nothing has ever
    /// been pinned yet — the next pin then creates a fresh one. Panels
    /// created via "pop out" are deliberately NOT assigned here, so they
    /// stay standalone and don't absorb later pins.
    weak var sharedCarouselPanel: QuickClipPanel?
    /// itemPreviewPanel is shared between two independent owners: the main
    /// ring popup's selection preview, and a QuickClipPanel's "similar items"
    /// hover preview. Used by ItemPreviewPanel's own orphan-check — see
    /// popoverDidShow there — to tell a legitimate QuickClip-owned preview
    /// apart from a genuine orphan with no owner left at all.
    var hasVisibleQuickClipPanel: Bool { quickClipPanels.contains { $0.isVisible } }

    var hintKeyVDown = false
    var hintKeyXDown = false
    var hintKeyCDown = false
    var hintKeyBDown = false
    var hintKeySpaceDown = false
    var hintCmdHeld = false
    var hintShiftHeld = false

    /// User-selected reverse-cycle key: false = ⇧V (default), true = B.
    /// With B selected, B acts as a context-aware "back" — it steps the
    /// ACTIVE panel backward (transform panel open → previous transform,
    /// otherwise → previous item). ⇧V/⇧X keep working in both modes.
    /// Editable from the Interactions list in Settings; the popup's hint
    /// legend and the Interaction Lab animation follow the selection.
    @Published var reverseCycleUsesB: Bool = UserDefaults.standard.bool(forKey: "reverseCycleUsesB") {
        didSet {
            UserDefaults.standard.set(reverseCycleUsesB, forKey: "reverseCycleUsesB")
            if oldValue != reverseCycleUsesB { AuthManager.shared.registerActionUsage(actionID: "setting.reverse_key") }
        }
    }

    /// Fires once on the user's first ⌘V cycle — preview overlay shows ⌘X transform tip.
    @Published var showFirstCycleHint: Bool = false


    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            // Failures are surfaced via flashStatus so the user knows the
            // toggle didn't stick — silent print() would leave them confused
            // when "Launch at login" stays off after they flipped it on.
            do {
                if newValue { try SMAppService.mainApp.register() }
                else        { try SMAppService.mainApp.unregister() }
            } catch {
                flashStatus("Couldn't update Launch at login — \(error.localizedDescription)")
            }
        }
    }

    let nlEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

    /// How long (in seconds) we wait after the user's first ⌘V tap of a
    /// session before actually opening the popup. If the user releases ⌘
    /// inside this window, we treat the tap as a normal "paste front item"
    /// and never show the popup — which makes a quick ⌘V feel identical to
    /// system paste. Hold ⌘ for longer than this and the popup opens, and
    /// the user enters cycling mode.
    ///
    /// Default 0.15 s (150 ms) — short enough that intentional cyclers don't
    /// notice the delay, long enough to absorb a relaxed "quick tap" of
    /// ~50–100 ms. User-tunable via the slider in the menu bar widget.
    @Published var firstOpenDelay: Double = {
        let stored = UserDefaults.standard.object(forKey: "firstOpenDelay") as? Double ?? 0.12
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

    /// When true, the popup auto-dismisses itself after `autoDismissSeconds`
    /// of inactivity. User-tunable in Settings; default on.
    @Published var autoDismissEnabled: Bool = UserDefaults.standard.object(forKey: "autoDismissEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoDismissEnabled, forKey: "autoDismissEnabled")
            if oldValue != autoDismissEnabled { AuthManager.shared.registerActionUsage(actionID: "setting.auto_dismiss") }
        }
    }
    /// Seconds of inactivity before the popup auto-dismisses (see
    /// `autoDismissEnabled`). Default 180s (3 min). Clamped to a sane range
    /// so a fat-fingered UserDefaults value can't produce an instant or
    /// effectively-infinite timer. The countdown restarts on every popup
    /// interaction (key press, mouse selection) — see `resetAutoDismissTimer`.
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
    /// Backing timer for the auto-dismiss countdown. Not @Published — it's
    /// plumbing, not UI state.
    var autoDismissTimer: Timer?

    /// When true, marking an item (hold V) automatically advances the
    /// selection to the next item — lets the user mark a run of items
    /// without a separate V-tap between each mark. Default off.
    /// App-affinity auto-surface for pinned reference panels (see
    /// surfaceReferencePanel) — a toggle right on the reference panel's own
    /// toolbar, not tucked in Settings, since it's specific to that panel.
    /// Active by default; persists across launches once the user turns it
    /// off.
    @Published var referenceAppAffinityEnabled: Bool = UserDefaults.standard.object(forKey: "referenceAppAffinityEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(referenceAppAffinityEnabled, forKey: "referenceAppAffinityEnabled") }
    }
    @Published var advanceAfterMark: Bool = UserDefaults.standard.object(forKey: "advanceAfterMark") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(advanceAfterMark, forKey: "advanceAfterMark")
            if oldValue != advanceAfterMark { AuthManager.shared.registerActionUsage(actionID: "setting.advance_after_mark") }
        }
    }
    /// When true, the popup NEVER opens from a single held ⌘V — the first
    /// tap always fast-pastes the front item on ⌘ release, and the popup
    /// appears only on a SECOND V tap while ⌘ is still held. Disambiguates
    /// paste-vs-popup by tap count instead of the firstOpenDelay timer, so
    /// the delay slider is ignored (and disabled in Settings) while this is
    /// on. Default off — the timer behavior stays the default.
    @Published var openOnSecondTap: Bool = UserDefaults.standard.object(forKey: "openOnSecondTap") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(openOnSecondTap, forKey: "openOnSecondTap")
            if oldValue != openOnSecondTap { AuthManager.shared.registerActionUsage(actionID: "setting.second_tap") }
        }
    }
    /// Hard cap on simultaneously-pinned items — pinning is a small
    /// "keep these handy" set, not a second unbounded list; a 6th pin
    /// attempt while 5 are already pinned is refused outright rather than
    /// silently bumping the oldest pin.
    static let maxPinnedItems = 5
    /// 1-based slot pinned items are inserted at, in both the popup and the
    /// main window — 1 (the default) means pinning sends an item straight
    /// to the very top; a higher value leaves that many of the most-recent
    /// UNPINNED items sitting above the pinned block instead. Clamped to
    /// maxPinnedItems since a start position beyond that can never actually
    /// be reached with at most 5 pins to fill it.
    @Published var pinStartPosition: Int =
        min(max(1, UserDefaults.standard.object(forKey: "pinStartPosition") as? Int ?? 1), ClipboardManager.maxPinnedItems) {
        didSet {
            UserDefaults.standard.set(pinStartPosition, forKey: "pinStartPosition")
            if oldValue != pinStartPosition { AuthManager.shared.registerActionUsage(actionID: "setting.pin_position") }
        }
    }
    /// Which content types auto-show the Space-style item preview panel as
    /// the highlighted row changes, instead of requiring an explicit Space
    /// press each time. Empty (the default) means auto-preview is off
    /// entirely — Space still toggles preview manually either way.
    @Published var autoPreviewTypes: Set<AutoPreviewContentType> = AutoPreviewContentType.loadSaved() {
        didSet {
            AutoPreviewContentType.save(autoPreviewTypes)
            if oldValue != autoPreviewTypes { AuthManager.shared.registerActionUsage(actionID: "setting.always_preview") }
            applyAlwaysShowItemPreviewPolicy()
        }
    }
    /// When true, reopening the popup restores the row the user was last on
    /// instead of resetting to the top. Off by default (classic "always start
    /// at the most-recent item" behavior).
    @Published var rememberLastSelection: Bool = UserDefaults.standard.object(forKey: "rememberLastSelection") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(rememberLastSelection, forKey: "rememberLastSelection")
            if oldValue != rememberLastSelection { AuthManager.shared.registerActionUsage(actionID: "setting.remember_last") }
        }
    }
    /// The row index to restore when `rememberLastSelection` is on. Captured
    /// whenever the popup closes (paste or dismiss) so the next open lands on
    /// the same item. Session-only — a fresh launch starts at the top.
    var rememberedIndex: Int = 0
    /// The actual ITEM the user was last on. The setting promises "returns to
    /// the item you were last on" — but a bare index drifts: every new copy
    /// between popup sessions shifts the whole list down, so index N lands on
    /// a different item than the one remembered. Restore resolves this ID
    /// first and only falls back to the clamped index when the item is gone.
    var rememberedItemID: UUID? = nil
    /// When the popup last closed with a position captured — restoring only
    /// makes sense for a SHORT gap (you tabbed away and came right back);
    /// after `rememberLastPositionTimeoutMinutes` of being closed, the ring
    /// has likely moved on enough that starting fresh at the top makes more
    /// sense than jumping back to a now-stale row. nil until the popup has
    /// closed at least once this session.
    var rememberedSelectionSavedAt: Date? = nil
    /// User-facing preset (minutes) for how long a remembered position stays
    /// valid — editable via the pill next to the "Remember last position"
    /// toggle, only enabled while that toggle is on. 0 is the special
    /// "Until turned off" preset — no expiry at all, matching the original
    /// behavior this timeout was layered on top of — so it's the default,
    /// not one of the timed presets (1/3/5/10/15/30/60 minutes).
    @Published var rememberLastPositionTimeoutMinutes: Int =
        UserDefaults.standard.object(forKey: "rememberLastPositionTimeoutMinutes") as? Int ?? 0 {
        didSet {
            UserDefaults.standard.set(rememberLastPositionTimeoutMinutes, forKey: "rememberLastPositionTimeoutMinutes")
            if oldValue != rememberLastPositionTimeoutMinutes {
                AuthManager.shared.registerActionUsage(actionID: "setting.remember_last_timeout")
            }
        }
    }

    /// Wait-then-decide disambiguation for a plain V press while the popup is
    /// already open — mirrors cycleNext()'s own pendingFirstOpen/
    /// pendingFirstOpenTimer pattern for ⌘V itself. Nothing happens on the
    /// initial keyDown; the timer either fires while V is still held (hold
    /// confirmed → mark the item, which never moved) or is cancelled by
    /// keyUp arriving first (tap confirmed → cycle to next). This replaces an
    /// earlier "cycle immediately, then undo-and-mark if it turns out to be a
    /// hold" approach that visibly flickered (row stepped forward, then
    /// snapped back, then got marked) because it acted before knowing which
    /// gesture it was.
    var vTapHoldTimer: Timer?
    /// Same tap-vs-hold decision timer as `vTapHoldTimer`, for the B key
    /// when it's the chosen reverse key: tap = step backward, hold = mark
    /// (and auto-move BACKWARD when advance-after-marking is on).
    var bTapHoldTimer: Timer?
    /// User-facing Fast/Medium/Slow presets for the two hold/double-tap
    /// timing windows below — hides raw millisecond numbers behind a
    /// feel-based choice instead of a slider showing exact ms values.
    @Published var markHoldSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "markHoldSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(markHoldSpeed.rawValue, forKey: "markHoldSpeed")
            if oldValue != markHoldSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.mark_hold_speed") }
        }
    }
    /// How long a plain V/B press must be held before it's treated as a hold
    /// (mark) instead of a tap (cycle). Short enough that a deliberate tap
    /// never feels delayed; long enough to reliably catch an intentional
    /// hold. Derived from `markHoldSpeed`; `.medium` matches the value this
    /// was hardcoded to before it became a setting, so existing installs see
    /// no behavior change unless they touch the new preference.
    var vHoldThreshold: TimeInterval { markHoldSpeed.holdSeconds }

    /// Same Fast/Medium/Slow choice for the Space-key double-tap window
    /// (tap twice quickly to pin the current preview into a reference panel).
    @Published var spaceDoubleTapSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "spaceDoubleTapSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(spaceDoubleTapSpeed.rawValue, forKey: "spaceDoubleTapSpeed")
            if oldValue != spaceDoubleTapSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.space_doubletap_speed") }
        }
    }
    /// Max seconds between two Space taps to count as a double-tap (pin
    /// preview) rather than two independent single taps (toggle preview
    /// twice). `.medium` matches the previous hardcoded 0.35s default.
    var spaceDoubleTapWindow: TimeInterval { spaceDoubleTapSpeed.doubleTapSeconds }

    /// Same Fast/Medium/Slow choice for the very first ⌘+hold-V that pins the
    /// popup open (see `firstOpenHoldTimer` below) — independent of
    /// `markHoldSpeed` so pinning the popup and marking an item can be tuned
    /// to different feels even though both start as a plain V hold.
    @Published var pinnedOpenHoldSpeed: GestureSpeed =
        GestureSpeed(rawValue: UserDefaults.standard.string(forKey: "pinnedOpenHoldSpeed") ?? "") ?? .medium {
        didSet {
            UserDefaults.standard.set(pinnedOpenHoldSpeed.rawValue, forKey: "pinnedOpenHoldSpeed")
            if oldValue != pinnedOpenHoldSpeed { AuthManager.shared.registerActionUsage(actionID: "setting.pinned_open_hold_speed") }
        }
    }
    /// How long the first V press must be held before the popup opens
    /// PINNED instead of the normal tap-opens-briefly behavior.
    var pinnedOpenHoldThreshold: TimeInterval { pinnedOpenHoldSpeed.holdSeconds }

    /// Same tap-vs-hold disambiguation as `vTapHoldTimer`, but for the very
    /// FIRST V press that opens the popup (before `previewWindow.isVisible`).
    /// A tap opens the popup exactly as before (⌘-release commits + closes).
    /// A hold opens the popup PINNED: `popupPinnedOpen` becomes true, and
    /// `handleFlagsChanged` skips its normal ⌘-release commit/dismiss while
    /// that's set — the popup stays open until the user explicitly closes it
    /// (X button, Esc, or clicking outside), browsing/pasting (double-click
    /// already pastes without closing) without needing to keep ⌘ held down.
    var firstOpenHoldTimer: Timer?
    /// True once a hold-opened popup should ignore ⌘-release. Cleared
    /// wherever the popup's other session state resets (dismissPreview).
    @Published var popupPinnedOpen: Bool = false

    /// Analytics: when the current popup session opened, and whether any
    /// paste happened during it. Together they produce popup duration and
    /// the abandonment signal (closed without pasting anything).
    var popupOpenedAt: Date? = nil
    var popupSessionPasted = false

    /// True only when loadHistory() successfully read the previous manifest
    /// (or this is a genuine first launch with no manifest at all). While
    /// false, saveHistory() keeps persisting new captures but the
    /// orphan-blob purge and the rolling-backup refresh are both disabled —
    /// a session that couldn't read the real history must not be allowed to
    /// destroy its payloads or its last good backup. See
    /// ClipboardManager+Persistence.loadHistory.
    var historyLoadedCleanly = false

    /// Same tap-vs-hold pattern as V, applied to X: a tap opens/cycles the
    /// transform panel, a hold dismisses it (closes just the transform panel,
    /// leaving the popup itself open). Longer threshold than V's because X is
    /// tapped repeatedly in quick succession to cycle tools — 0.15s would
    /// misfire as a dismiss during fast cycling.
    var xTapHoldTimer: Timer?
    static let xHoldThreshold: TimeInterval = 0.35

    /// Set synchronously (not inside the deferred async block) the instant an
    /// Esc press is determined to fully dismiss the popup. Both Esc's dismiss
    /// and ⌘-release's commit are each deferred via DispatchQueue.main.async,
    /// so pressing Esc and releasing ⌘ in the same instant enqueues both —
    /// and without this flag, handleFlagsChanged's synchronous visibility
    /// check (which runs BEFORE either deferred block executes) would still
    /// see previewWindow.isVisible == true and schedule a stale commit/paste
    /// for a popup that Esc already decided to close. Read+cleared inside
    /// handleFlagsChanged.
    var escapeWillDismiss = false

    var pollTimer: Timer?
    var permissionRetryTimer: Timer?
    /// Exponential backoff for the permission-retry loop: 1s → 2s → … → 30s.
    /// Reset to 1s on every fresh `attemptEventTap()`.
    var permissionRetryBackoff: TimeInterval = 1.0
    /// ID of the item whose transforms were last computed.  Guards against
    /// re-running all tool preview closures (JSON parse, regex, Base64 etc.)
    /// on every V-key tap while the transform stage is active for the SAME item.
    var lastTransformCacheItemID: UUID? = nil
    /// Timer that fires `firstOpenDelay` seconds after the user's first ⌘V
    /// tap. If the user releases ⌘ before it fires we cancel and do a fast
    /// paste of the front item instead of opening the popup.
    var pendingFirstOpenTimer: Timer?
    /// True between the first ⌘V tap of a session and either:
    ///   (a) the delay timer firing → popup opens, or
    ///   (b) ⌘ being released → fast paste of front item.
    var pendingFirstOpen: Bool = false
    var lastChangeCount: Int = NSPasteboard.general.changeCount
    /// Universal Clipboard (iPhone → Mac Handoff) content bumps changeCount
    /// the INSTANT it announces itself, but the actual bytes (image/file
    /// data) stream in asynchronously afterward over Continuity — they can
    /// still be unavailable on the very next 0.3s poll. changeCount never
    /// bumps again once the real data lands, so without this, that poll's
    /// failed capture was never retried and the copy was silently dropped.
    /// This counts consecutive "saw the remote-clipboard marker but nothing
    /// captured" polls for the SAME changeCount; while under the cap,
    /// lastChangeCount is deliberately NOT advanced, so the next poll tick
    /// tries again against the same (hopefully now-ready) pasteboard.
    var remoteClipboardRetryCount = 0
    static let maxRemoteClipboardRetries = 30  // ~9s at the 0.3s poll interval — large iPhone photos/videos can take longer than the original 3s window to fully stream in over Continuity.
    /// Upper bound on text length the (synchronous, capture-path) diff badge
    /// will line-split and set-compare. Human-scale edits are far under this.
    static let maxDiffBadgeTextLength = 20_000
    /// Last-seen byte size per file-URL path, so a file-URL can be required
    /// to report the SAME non-zero size on two consecutive polls before
    /// it's trusted — a non-zero size alone isn't enough: a file mid-write
    /// has real bytes too, just not all of them yet, and capturing that
    /// moment copies a truncated/corrupt file instead of retrying.
    var remoteClipboardLastFileSize: [String: Int] = [:]
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isSimulatingPaste = false

    /// Monotonic token identifying the current synthetic-paste session. Every
    /// paste bumps it; a delayed "clear isSimulatingPaste" only takes effect if
    /// its captured token still matches. Without this, a rapid second paste
    /// (e.g. repeated double-click-to-paste) that starts before the first
    /// paste's fixed-delay reset timer fires would get un-guarded early — and
    /// the poll could then capture the second synthetic ⌘V as a new ring item.
    private var pasteSimulationToken = 0

    /// Begin a synthetic-paste session. Returns the token to hand back to
    /// `endPasteSimulation(token:)` when this specific paste finishes.
    @discardableResult
    func beginPasteSimulation() -> Int {
        pasteSimulationToken &+= 1
        isSimulatingPaste = true
        return pasteSimulationToken
    }

    /// End a synthetic-paste session — but only if no newer paste has started
    /// in the meantime (i.e. the token still matches the latest session).
    func endPasteSimulation(token: Int) {
        guard token == pasteSimulationToken else { return }
        isSimulatingPaste = false
    }

    // Two-stage cycling: Stage 1 = items, Stage 2 = transforms for selected item
    var inTransformStage = false
    var transformIndex   = 0
    /// Snapshot transform ordering for the current stage so ⌘X cycles in a
    /// stable one-by-one sequence even if global usage rankings change.
    var transformDisplaysCache: [TransformDisplay] = []

    // Same tap-to-open/tap-to-cycle shape as Stage 2 transforms, but for the
    // native macOS Share Sheet (S key) instead of Clipen's own tools —
    // ⌘-release invokes whichever NSSharingService is highlighted when the
    // popup closes, same as ⌘-release commits a paste.
    @Published var inShareStage = false
    @Published var shareIndex = 0
    /// The services available for whatever's being shared — recomputed once
    /// when share stage opens, then just cycled through, same reasoning as
    /// transformDisplaysCache (stable order while cycling).
    var shareServices: [NSSharingService] = []
    /// Snapshot of which items are being shared (marked set, or just the
    /// highlighted item) — captured at share-stage entry so a stray
    /// selection change mid-cycle can't retarget the eventual send.
    var shareTargetItems: [ClipboardItem] = []

    var saveCancellable: AnyCancellable?

    /// First-run coach for the popup itself.  Two steps only, surfaced as
    /// small accent-colored bubbles attached to the existing V and X hint
    /// chips in the popup header — no big overlay, no separate window:
    ///   0 → highlight V chip, "Hold ⌘ and tap V to cycle"
    ///        advances after the user cycles ≥ 2 times
    ///   1 → highlight X chip, "Tap X to transform"
    ///        advances after the user enters transform stage
    ///   2 → done; nothing rendered.  Persisted in UserDefaults so a single
    ///        completion sticks across launches; partial progress resumes.
    @Published var popupCoachStep: Int = UserDefaults.standard.integer(forKey: "popupCoachStep") {
        didSet { UserDefaults.standard.set(popupCoachStep, forKey: "popupCoachStep") }
    }

    // MARK: - Inline page-range picker state ("Paste Specific Pages")
    /// True while the page-picker has replaced the tool list in TransformPanel.
    /// Keystrokes (digits / dash / comma / backspace / arrows / space / return / esc)
    /// are routed through the CGEventTap to update the state below.  Mouse clicks
    /// on the page grid go directly through SwiftUI buttons.
    @Published var inPageRangeMode: Bool = false
    /// Live range query, e.g. "1-3, 5, 7-9".  Built character-by-character via the
    /// event tap; the SwiftUI view treats it as read-only display text.
    @Published var pageRangeQuery: String = ""
    /// Pages clicked individually in the grid (0-indexed).  Final selection is the
    /// union of `pageRangeQuery`'s parsed range and this set.
    @Published var pageRangeManualPages: Set<Int> = []
    /// Total page count of the active PDF — published so the view doesn't have to
    /// keep a reference to the PDFDocument itself.
    @Published var pageRangePageCount: Int = 0
    /// PDF being picked from.  Strong-held while in page-range mode.
    var pageRangePDF: PDFDocument?
    /// What to produce when the user commits the picker:
    ///   .combinedPDF — stitch selected pages into one new PDF, paste as file
    ///   .perPageImages — render each selected page to its own PNG, paste files
    enum PageRangeOutputMode { case combinedPDF; case perPageImages }
    @Published var pageRangeOutputMode: PageRangeOutputMode = .combinedPDF

    /// Union of typed-range pages and manually-clicked pages.  This is what the
    /// grid uses for highlight state and what `commitPageRangePaste` extracts.
    var pageRangeEffectiveSelection: Set<Int> {
        PageRangeParser.parse(pageRangeQuery, maxPage: pageRangePageCount)
            .union(pageRangeManualPages)
    }

    // MARK: - Inline language picker state ("Translate")
    //
    // Same pattern as the PDF page-range picker above: replaces the tool
    // list inline under the "Translate" row instead of running a single
    // hardcoded target language. Typed letters build a search query,
    // ↑/↓ move the highlighted language, ↵ commits, ⎋ cancels.

    @Published var inLanguagePickerMode: Bool = false
    /// Live typeahead filter, e.g. "span" narrows to "Spanish".
    @Published var languagePickerQuery: String = ""
    /// Index into `languagePickerFilteredLanguages`, not the full catalog —
    /// clamped whenever the query changes the filtered list's length.
    @Published var languagePickerSelectedIndex: Int = 0
    /// The item being translated. Strong-held while the picker is open.
    var languagePickerSourceItem: ClipboardItem?

    /// All supported languages minus the text's OWN detected language (no
    /// point offering "translate English to English"), then narrowed by
    /// `languagePickerQuery` if the user has typed anything.
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

    /// Inline popup search results — capped at 5 (fits popup height).

    /// Serial queue for history writes. Saves used to go to the CONCURRENT
    /// global background queue, so two debounced saves could overlap — one
    /// purging blob files while the other was still writing its manifest.
    /// Serial ordering makes save + purge atomic relative to each other and
    /// is what makes the blob-reuse caches below safe to touch during saves.
    let saveQueue = DispatchQueue(label: "com.clipen.history-save", qos: .utility)

    private init() {
        // maxItems is now plan-driven only — remove any stale UserDefaults value
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

    // MARK: - Start

    func startMonitoring() {
        loadHistory()
        recomputeEmbeddingsInBackground()
        startPolling()
        startAccessibilityWatcher()
        attemptEventTap()
        startAppAffinityObserver()
    }

    var appActivationObserver: NSObjectProtocol?

    /// Serial queue for the Smart Reference context AppleScript round-trips.
    /// Serial so NSAppleScript is never executed concurrently (the Apple Event
    /// Manager isn't safe for parallel use), and off-main so a hung/busy
    /// browser can't freeze the app on every application switch.
    let referenceContextQueue = DispatchQueue(label: "com.clipen.referenceContext")
    /// Latest app to surface for. Set on main; lets an in-flight fetch chase
    /// the newest frontmost app instead of piling up redundant fetches.
    var pendingReferenceBundleID: String?

    /// Watches for app switches so pinned reference panels can auto-surface:
    /// each pinned page remembers which app was frontmost when it was
    /// pinned (see openQuickClipPanel), and switching to that app again
    /// brings its reference panel forward, jumped to that specific page.
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

    /// If some pinned reference belongs to the app just switched to, brings
    /// its panel forward and jumps to that page. If NONE do, every
    /// reference panel hides (orderOut — pins are preserved, not closed)
    /// until a switch to an app that does have one brings them back.
    func surfaceReferencePanel(forActiveApp bundleID: String) {
        guard referenceAppAffinityEnabled,
              !quickClipPanels.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        // Record the newest target. If a fetch is already running, it will pick
        // this up when it finishes rather than kicking off a parallel one.
        let alreadyFetching = pendingReferenceBundleID != nil
        pendingReferenceBundleID = bundleID
        guard !alreadyFetching else { return }
        fetchReferenceContext(for: bundleID)
    }

    /// Off-main: gather the tab/window context (AppleScript) for `bundleID`,
    /// then apply the panel matching back on the main thread.
    private func fetchReferenceContext(for bundleID: String) {
        referenceContextQueue.async { [weak self] in
            // AppleScript round-trips happen HERE, off the main thread — a page
            // pinned from one specific browser tab/Finder folder should only
            // auto-surface for THAT tab/folder, so we need per-tab context, but
            // fetching it must never block the UI.
            let liveContext = AppContextService.currentContext(for: bundleID)
            let tabTexts    = AppContextService.allTabTexts(for: bundleID)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyReferenceSurface(bundleID: bundleID, liveContext: liveContext, tabTexts: tabTexts)
                // If the frontmost app changed while we were fetching, chase it.
                if let latest = self.pendingReferenceBundleID, latest != bundleID {
                    self.fetchReferenceContext(for: latest)
                } else {
                    self.pendingReferenceBundleID = nil
                }
            }
        }
    }

    private func applyReferenceSurface(bundleID: String, liveContext: String?, tabTexts: [String]) {
        // Panels/toggle could have changed while off-main — re-check the guards.
        guard referenceAppAffinityEnabled,
              !quickClipPanels.isEmpty, bundleID != Bundle.main.bundleIdentifier else { return }

        var matched: QuickClipPanel?
        for panel in quickClipPanels where panel.carousel.jumpToPage(ownedBy: bundleID, context: liveContext) {
            matched = panel
            break
        }

        // No exact bundle-ID/context link — try a semantic fallback before
        // giving up: compare EVERY open tab's title/URL (not just the active
        // one) against every pinned page's own content embedding. Catches
        // e.g. a background tab that's clearly about the same topic as a
        // pinned reference, even though it was never explicitly linked.
        if matched == nil, let (panel, pageID) = semanticBestMatch(forBundleID: bundleID, in: quickClipPanels, tabTexts: tabTexts) {
            panel.carousel.jumpToPage(id: pageID)
            // Now that a real match was found, link it properly so the next
            // switch to this app/tab is an exact match, not a re-scan.
            panel.carousel.linkCurrentPage(toApp: bundleID, context: liveContext)
            matched = panel
        }

        for panel in quickClipPanels {
            if panel === matched {
                // Analytics: Smart Reference matched this app and surfaced
                // the panel automatically — the "guessed right" half of the
                // auto-surface accuracy signal.
                AuthManager.shared.registerActionUsage(actionID: "ref.auto_surface")
                // NOT panel.expand() — that's reserved for the user
                // manually clicking the collapsed badge (which also links
                // whatever app they clicked it from). This is an automatic,
                // ALREADY-correct match; restoreIfCollapsed() just brings it
                // back into view without touching any linking state.
                panel.restoreIfCollapsed()
                panel.orderFrontRegardless()
            } else {
                // No reference in this panel belongs to the app just
                // switched to — shrink to a small corner badge instead of
                // fully hiding, so it stays visible and one click away
                // (which also links this app to the current page, so it
                // matches automatically from then on).
                panel.collapseToCorner(activeApp: bundleID, activeContext: liveContext)
            }
        }
    }

    /// Polls `AXIsProcessTrusted()` once a second. This is the SINGLE source
    /// of truth for `hasAccessibilityPermission` — independent of whether
    /// `CGEvent.tapCreate` happened to succeed. macOS occasionally grants
    /// AX trust slightly before `tapCreate` will accept it; tying the UI
    /// to `tapCreate` instead of `AXIsProcessTrusted` causes a stuck
    /// onboarding screen even when System Settings shows Clipen as ON.
    func startAccessibilityWatcher() {
        accessibilityPollTimer?.invalidate()
        // Sync immediately so the very first render reflects reality.
        let trusted = AXIsProcessTrusted()
        if hasAccessibilityPermission != trusted {
            hasAccessibilityPermission = trusted
        }
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = AXIsProcessTrusted()
            if self.hasAccessibilityPermission != now {
                self.hasAccessibilityPermission = now
            }
            // Once trusted, make sure the event tap is actually live —
            // useful when the user grants permission *after* launch and
            // our initial `tapCreate` call failed.
            if now && self.eventTap == nil {
                self.attemptEventTap()
            }
        }
        RunLoop.main.add(accessibilityPollTimer!, forMode: .common)
    }

    // (caret prewarmer removed — caused stale-position bug: cached position
    // from a previous focus survived across popup sessions, so opening the
    // popup in a different text field showed the popup at the old caret.
    // The 100-300ms AX query on first-open in Safari/Chrome is the
    // necessary cost of always-correct positioning.)

}

// MARK: - Models

struct ClipboardItem: Identifiable {
    let id:        UUID
    let timestamp: Date
    let content:   ClipboardContent
    /// Pre-computed at init so row renders don't redo traditional + semantic
    /// detectors. Content is immutable, so this can never go stale.
    let detectedType: ClipboardContentType
    /// All detection tags (structural + plain-text signals).
    let tags: [ClipboardTag]
    /// Highest-priority tag — used for default filter chip ordering.
    let primaryTag: ClipboardTag
    /// Same idea for color swatches.
    let detectedColor: NSColor?
    var isPinned:  Bool     = false
    var embedding: [Float]? = nil
    var urlTitle:  String?  = nil { didSet { rebuildSearchHaystacks() } }
    var diffBadge: String?  = nil
    var sourceAppName: String? = nil { didSet { rebuildSearchHaystacks() } }
    var sourceBundleID: String? = nil
    /// Free-form annotation the user can type in a Quick Clip panel.
    /// Persisted with the item across launches (AES-GCM encrypted on disk).
    /// didSet rebuild: notes are part of the lexical search haystack (see
    /// rebuildSearchHaystacks), so an edited note must re-index immediately.
    var userNote: String? = nil { didSet { rebuildSearchHaystacks() } }
    /// Text extracted from the image via Vision OCR (async, populated after capture).
    /// Also used for PDF items (extracted via PDFKit). Feeds the search haystacks.
    /// The didSet here is load-bearing: ocrText is assigned AFTER init both
    /// when OCR finishes (capture path) and when history loads from disk —
    /// without it, every OCR'd image silently dropped its text from the
    /// lexical index on app restart (haystacks were built at init, when
    /// ocrText was still nil), so searching a word visible in a screenshot
    /// worked until relaunch and then never again.
    var ocrText: String? = nil { didSet { rebuildSearchHaystacks() } }
    /// Side-car pasteboard flavors: every OTHER representation that was on the
    /// pasteboard alongside the primary content at capture time (app-private
    /// layer data, alternate encodings…), keyed by raw type identifier. macOS
    /// pasteboards hold ALL representations simultaneously; storing only the
    /// priority-ladder winner silently broke copy→paste flows whose meaning
    /// lived in a discarded flavor (Photoshop "copy layer", Sketch symbols,
    /// audio-tool clips…). Restored verbatim on paste alongside the primary.
    /// nil when the pasteboard had nothing beyond what the primary reproduces.
    var sidecarTypes: [String: Data]? = nil

    /// App the item was most recently pasted *into* (destination).  Recorded
    /// in commitPaste / finishTransformPaste at the moment the synthetic ⌘V
    /// fires, so it always reflects the actual receiving app.
    /// nil = never pasted yet.
    var pastedToAppName:  String? = nil
    var pastedToBundleID: String? = nil
    /// Wall-clock time of the most recent paste of this item.
    var lastPastedAt: Date? = nil

    /// Total number of times this item has ever been pasted (any app).  A
    /// raw frequency signal for the predictor — items the user pastes over
    /// and over (a signature, an address, a code snippet) score higher.
    var pasteCount: Int = 0
    /// Per-destination paste tally keyed by bundle identifier.  Lets the
    /// predictor ask "how often has THIS item gone into the app that's
    /// currently frontmost?" — the strongest single contextual signal.
    var pasteCountByApp: [String: Int] = [:]
    /// Human-readable name for every app this item has *ever* been pasted
    /// into, keyed by bundle identifier.  Grows over time — pasting the
    /// same item into Xcode, then Slack, then Notes records all three.
    /// Displayed as destination-app badges in the main window and feeds
    /// the predictor's app-affinity stage alongside `pasteCountByApp`.
    var pastedToAppNames: [String: String] = [:]

    // Pre-normalised search haystacks — built ONCE at init so the per-keystroke
    // hot path (hybridSearch → lexicalScore) doesn't do disk I/O or string
    // allocation per item.  Previously each search call did:
    //   • FileManager.attributesOfItem (size + mtime) — kernel syscall, ×N items
    //   • PDF/NSImage open for image and pdf metadata
    //   • full lowercase + Unicode diacritic-strip transform per item per key
    // Now all that happens once when the item enters the ring.  Re-built only
    // when urlTitle / sourceAppName arrive late (image titles come from a
    // background URL fetch; source-app from frontmost-app sniff).
    private(set) var searchPreviewNorm: String = ""
    private(set) var searchEmbedNorm:   String = ""
    private(set) var searchMetaNorm:    String = ""

    /// `urlTitle` / `sourceAppName` are assigned here (not after init) on the
    /// load path so their `didSet` doesn't fire — setting them post-init would
    /// trigger `rebuildSearchHaystacks()` twice more per item (FS I/O for file
    /// items), once each, on top of the single rebuild below.  Inside `init`
    /// property observers don't run, so the haystacks are built exactly once
    /// with the final field values.
    /// `userNote` / `ocrText` are init parameters ON PURPOSE, not
    /// assign-after-construction fields: both have didSet observers that
    /// rebuild the search haystacks, and Swift doesn't fire didSet during
    /// init — so history load passes them here and pays for ONE haystack
    /// build per item. Assigning them after init (the old loadHistory
    /// pattern) rebuilt every item's haystacks three times at every launch,
    /// including real FileManager syscalls per rebuild for file items.
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

    /// Rebuilds ALL derived caches: metadataSummary, textForEmbedding, and the
    /// three normalised search-haystack strings.  Called once at init, and
    /// again only when urlTitle / sourceAppName arrive late (image titles
    /// from a background URL fetch; source-app from frontmost-app sniff).
    /// File-system I/O happens exactly here — never on a read path.
    mutating func rebuildSearchHaystacks() {
        metadataSummary  = Self.computeMetadataSummary(for: content)
        textForEmbedding = Self.computeTextForEmbedding(content: content,
                                                       urlTitle: urlTitle,
                                                       sourceAppName: sourceAppName)
        searchPreviewNorm = Self.normalize(previewText)
        searchEmbedNorm   = Self.normalize(textForEmbedding ?? "")
        searchMetaNorm    = Self.normalize(metadataSummary ?? "")
        // ocrText is appended to searchEmbedNorm so image/PDF content is searchable.
        if let ocr = ocrText, !ocr.isEmpty {
            searchEmbedNorm += " " + Self.normalize(ocr)
        }
        // The user's own note too — typing a word you wrote on an item is
        // the clearest possible search intent, but notes used to be
        // invisible to the lexical tier (only the embedding saw them).
        if let note = userNote, !note.isEmpty {
            searchEmbedNorm += " " + Self.normalize(note)
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
    }

    /// EVERYTHING known about this item, as one string, for the semantic
    /// embedding: the content text (or type/size/title metadata for
    /// non-text), OCR'd text from images and PDFs, the user's own note, the
    /// page title a copied URL resolved to, and the apps it came from / was
    /// pasted into. This — not the bare `textForEmbedding` — is what should
    /// feed NLEmbedding: an image whose embedding is only "image PNG
    /// 1024×768 pixels" can never semantically match a text note about the
    /// same topic, which made cross-type Similar Items useless for images
    /// in practice even after the type restriction itself was removed.
    /// Capped so a huge OCR dump doesn't degrade the sentence embedding.
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

    /// Cached at init / rebuildSearchHaystacks.  Used by every row render.
    /// For file items this previously did ~3 FileManager syscalls per access.
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

    /// The stored (thumbnail-resolution) image — fine for rows, chips, and
    /// any render up to ~1024px. Surfaces needing full resolution decode
    /// from rawData at an EVENT (drag start, tool run, paste) or inside a
    /// data-change-gated NSViewRepresentable (ZoomableImagePreview's
    /// fullResData) — NEVER inline in a SwiftUI body, which re-evaluates
    /// per render pass and turns one decode into hundreds.
    var image: NSImage? {
        if case .image(let img, _, _) = content { return img }
        return nil
    }

    /// Cached at init / rebuildSearchHaystacks.  Embedding generation + every
    /// hybrid-search call previously triggered this — for file items it meant
    /// FileManager syscalls per item per keystroke.  Now built once.
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
        // Human-readable name — replace _ and - with spaces so NLEmbedding
        // tokenises words correctly (e.g. "my_report_2026" → "my report 2026")
        let readableName = baseName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        parts.append(filename)
        if readableName != baseName { parts.append(readableName) }
        // File-kind keywords
        if FileKindDetector.isImageFile(url)           { parts.append("image photo picture \(ext)") }
        else if FileKindDetector.isVideoFile(url)      { parts.append("video movie clip \(ext)") }
        else if FileKindDetector.isAudioFile(url)      { parts.append("audio music sound recording \(ext)") }
        else if ext == "pdf"                           { parts.append("PDF document") }
        else if FileKindDetector.isTextFile(url)       { parts.append("text code \(ext) document") }
        else if FileKindDetector.isDocumentFile(url)   { parts.append("document file \(ext)") }
        else if FileKindDetector.isArchiveFile(url)    { parts.append("archive zip compressed \(ext)") }
        else if FileKindDetector.isDesignFile(url)     { parts.append("design file \(ext)") }
        else if !ext.isEmpty                           { parts.append(ext) }
        // File size — one FileManager.attributesOfItem call, only at init.
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

/// One toggle per `ClipboardContent` top-level case, for the auto-preview
/// data-type picker — lets the user pick e.g. "always preview images" without
/// also auto-previewing every text snippet copied.
enum AutoPreviewContentType: String, CaseIterable, Identifiable, Codable {
    case text, richText, html, table, image, file, files, svg, blob

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text:     return "Text"
        case .richText: return "Rich Text"
        case .html:     return "HTML"
        case .table:    return "Table"
        case .image:    return "Image"
        case .file:     return "File"
        case .files:    return "Files"
        case .svg:      return "SVG"
        case .blob:     return "Private"
        }
    }

    var sfIcon: String {
        switch self {
        case .text:     return "doc.text"
        case .richText: return "doc.richtext"
        case .html:     return "globe"
        case .table:    return "tablecells"
        case .image:    return "photo"
        case .file:     return "doc"
        case .files:    return "doc.on.doc"
        case .svg:      return "square.on.circle"
        case .blob:     return "lock.doc"
        }
    }

    static func from(_ content: ClipboardContent) -> AutoPreviewContentType {
        switch content {
        case .text:     return .text
        case .richText: return .richText
        case .html:     return .html
        case .rtfd:     return .table
        case .image:    return .image
        case .file:     return .file
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
    /// RTFD data — carries full table structure, embedded images, and cell formatting.
    /// Round-trips faithfully through Notes, Pages, Word, and any RTFD-aware app.
    case rtfd(Data, plain: String)
    case file(URL)
    case files([URL])
    /// SVG source text (public.svg-image, com.adobe.illustrator.svg, etc.)
    case svg(String)
    /// Opaque passthrough: all pasteboard types verbatim — key is the UTI string.
    /// Enables lossless round-trip for Photoshop layers, Sketch symbols, etc.
    case blob([String: Data])

    /// The plain-text representation of text-bearing content, nil for
    /// everything else (images, files, SVG, blobs). THE canonical accessor —
    /// this exact four-case switch used to be copy-pasted in half a dozen
    /// places (paste injection, reference-panel editors, similar-item cards,
    /// tutorial copy-detection…), each a chance to drift out of sync the way
    /// TextTools once did when it forgot the .rtfd case and silently lost
    /// every text tool for Notes/TextEdit items. Call sites that need
    /// different per-case behavior (file paths, SVG source, table cells)
    /// still switch on content themselves; anything that just wants "the
    /// text, if this is text" belongs here.
    var plainText: String? {
        switch self {
        case .text(let s):               return s
        case .richText(_, plain: let s): return s
        case .html(_, plain: let s):     return s
        case .rtfd(_, plain: let s):     return s
        case .svg(let s):                return s   // SVG is editable text markup
        default:                         return nil
        }
    }

    /// THE way to build an image item. The NSImage stored in the enum is a
    /// DOWNSAMPLED thumbnail (≤1024px on the long edge), decoded straight
    /// from the compressed bytes via ImageIO without ever materializing the
    /// full bitmap — a 5K screenshot's decoded bitmap is ~55 MB and, once
    /// any row rendered it, lived in RAM for the item's whole ring lifetime.
    /// That double-storage (full decoded bitmap + rawData) is what pushed
    /// the app to ~700 MB with an image-heavy ring.
    ///
    /// The thumbnail's `.size` is set to the ORIGINAL pixel dimensions, so
    /// every consumer of `img.size` (metadata summaries, embedding text,
    /// panel-sizing math) keeps seeing the real dimensions. Consumers that
    /// genuinely need full resolution (preview zoom, image tools, OCR,
    /// exotic-type paste fallback) decode transiently from `rawData` —
    /// always at an event or behind a data-change gate, never per render.
    ///
    /// `fallback` covers data ImageIO can't thumbnail (PDF-typed images,
    /// odd encodings): those keep the caller's full NSImage, same as before.
    // `fallback` is an @autoclosure so the (full-size) NSImage decode it
    // usually wraps is only evaluated when ImageIO thumbnailing fails — not
    // eagerly for every image. At history load this removes a full-image
    // decode per stored image, since the thumbnail path succeeds for all
    // normal formats and the fallback is never needed.
    static func imageContent(rawData: Data, dataType: NSPasteboard.PasteboardType,
                             fallback: @autoclosure () -> NSImage?) -> ClipboardContent? {
        // PDF data is vector — NSImage's PDF rep is compact and ImageIO
        // can't thumbnail it anyway.
        if !dataType.rawValue.lowercased().contains("pdf"),
           let thumb = NSImage.ringThumbnail(from: rawData) {
            return .image(thumb, rawData: rawData, dataType: dataType)
        }
        guard let fallback = fallback() else { return nil }
        return .image(fallback, rawData: rawData, dataType: dataType)
    }
}

/// Fast/Medium/Slow presets for the app's two tunable gesture-timing
/// windows (hold-to-mark, Space double-tap). Presented in Settings as a
/// feel-based choice rather than a raw-millisecond slider — the exact
/// second values below are what each label maps to for each specific gesture.
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
    /// Seconds a plain V/B press must be held before it counts as a hold
    /// (mark) instead of a tap (cycle). `.medium` (0.2s) is the value this
    /// was hardcoded to before becoming a setting.
    var holdSeconds: TimeInterval {
        switch self {
        case .fast:   return 0.15
        case .medium: return 0.2
        case .slow:   return 0.35
        }
    }
    /// Seconds between two Space taps to count as a double-tap (pin
    /// preview). `.medium` (0.35s) is the value this was hardcoded to
    /// before becoming a setting.
    var doubleTapSeconds: TimeInterval {
        switch self {
        case .fast:   return 0.25
        case .medium: return 0.35
        case .slow:   return 0.5
        }
    }
}

// MARK: - Extensions

extension String {
    /// Leading blank lines/whitespace removed — a DISPLAY-ONLY helper for
    /// popup rows, the main window, and the item/reference previews, so
    /// copied content that happens to start with empty space doesn't open on
    /// a blank-looking row/preview. Never applied to what's actually pasted
    /// or embedded (readableText, search haystacks) — those stay byte-
    /// faithful to the real content; only what's RENDERED is trimmed.
    var displayTrimmedLeading: String {
        String(drop(while: \.isWhitespace))
    }

    /// Bounded-prefix DISPLAY cap — the in-memory counterpart to
    /// FileKindDetector.readableTextPreview's disk-read cap. A pasted/copied
    /// `.text` item is already fully in memory (no file I/O to bound), but
    /// SwiftUI's Text layout cost for one huge string is real regardless —
    /// handing a multi-hundred-KB string straight to a Text view measures
    /// the whole thing every render. This bounds what's RENDERED, never
    /// what's pasted, searched, or embedded (those read the untouched
    /// content directly, not through this helper).
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

    /// Downsampled decode straight from compressed bytes — ImageIO produces
    /// a ≤maxPixel thumbnail WITHOUT decoding the full-size bitmap first,
    /// which is the entire point: the full decode is exactly the memory
    /// cost being avoided. `.size` is set to the original pixel dimensions
    /// so layout/metadata math built on `img.size` stays truthful (drawing
    /// scales the smaller bitmap up; the few surfaces that would visibly
    /// blur at that scale decode full-res on demand instead).
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

    /// Inverse of htmlDecoded — used when reconstructing HTML from
    /// user-edited plain cell text (table editor Save) so literal
    /// &/</>/" in a cell can't break the surrounding markup.
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
            // Full-res for the object representation too — the stored img is
            // a ring thumbnail, and some drop targets prefer the NSImage
            // object over the raw-data representation above. Decoded only
            // when a drag actually starts, so no resident cost.
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

    /// A real NSPasteboardWriting object for exactly this one item — used to
    /// build one NSDraggingItem per marked item for a genuine multi-item
    /// AppKit drag. `NSItemProvider` (used by `makeItemProvider()` above,
    /// for SwiftUI's single-provider `.onDrag`) does NOT conform to
    /// NSPasteboardWriting on macOS, so it can't be reused here.
    func makePasteboardWriter() -> NSPasteboardWriting {
        switch content {
        case .file(let url):
            return url as NSURL
        case .files(let urls):
            // Same "first URL only" limitation makeItemProvider() already
            // has for this case — a single dragged item can carry one
            // pasteboard payload; genuinely splitting a multi-file HISTORY
            // ENTRY into further separate drag items is a separate change.
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
                break // handled above
            }
            return pbItem
        }
    }

    /// Creates a single NSItemProvider that carries ALL items for a multi-item drag.
    /// Text-bearing items are joined with a separator. File items are registered as
    /// file URLs. The provider always also includes a combined plain-text fallback
    /// so any text-accepting drop target receives something useful.
    static func makeCombinedItemProvider(for items: [ClipboardItem]) -> NSItemProvider {
        let provider = NSItemProvider()

        // --- File URLs (register all, so Finder / other file drop targets get them) ---
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

        // --- Plain-text fallback (always registered; separates items clearly) ---
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

        // --- Rich representation for the first text item (best-fidelity for single rich drop) ---
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
