import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreServices
import CryptoKit
import NaturalLanguage
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import PDFKit

/// AES-GCM encryption for the on-disk clipboard history.
///
/// The clipboard regularly contains passwords, 2FA codes, API keys, and
/// other secrets. Storing the history as plain JSON in Application Support
/// would let any process running as the user (or anyone with brief physical
/// access) scrape years of clipboard contents. We encrypt with a 256-bit
/// symmetric key that lives in the user's login Keychain — only this app
/// (signed by our Team ID) can read it.
private enum HistoryCrypto {
    private static let keychainKey = "historyEncryptionKey"

    /// Returns the user's symmetric key, creating one on first launch.
    private static func key() -> SymmetricKey {
        if let data = Keychain.getData(keychainKey) {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let data  = fresh.withUnsafeBytes { Data($0) }
        Keychain.setData(data, forKey: keychainKey)
        return fresh
    }

    static func encrypt(_ plaintext: Data) -> Data? {
        try? AES.GCM.seal(plaintext, using: key()).combined
    }

    static func decrypt(_ ciphertext: Data) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: ciphertext) else { return nil }
        return try? AES.GCM.open(box, using: key())
    }
}


private enum SecretDetector {
    static func isLikelySecret(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8 else { return false }

        if text.contains("-----BEGIN ") && text.contains("PRIVATE KEY-----") { return true }

        let patterns = [
            #"(?i)(api[_-]?key|secret|password|passwd|token|bearer|client_secret)\s*[:=]\s*["']?[^"'\s]{8,}"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"gh[pousr]_[A-Za-z0-9_]{30,}"#,
            #"xox[baprs]-[A-Za-z0-9-]{20,}"#,
            #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#
        ]
        if patterns.contains(where: { matches($0, in: text) }) { return true }

        let singleLine = !text.contains("\n") && !text.contains(" ")
        guard singleLine, text.count >= 32, text.count <= 256 else { return false }
        let scalars = text.unicodeScalars
        let hasLower = scalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        let hasUpper = scalars.contains { CharacterSet.uppercaseLetters.contains($0) }
        let hasDigit = scalars.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSymbol = scalars.contains { CharacterSet(charactersIn: "_-+/=.").contains($0) }
        return [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count >= 3
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    @Published var items: [ClipboardItem] = [] {
        didSet { invalidateDisplayItems() }
    }
    @Published var selectedIndex: Int = 0
    /// Always true while the popup is visible.  Kept as a property because
    /// a few legacy code paths still read it; the auto-disarm timer that
    /// used to flip it false has been removed entirely — the popup model
    /// is now: hold ⌘, cycle with V, release ⌘ = paste.  Esc to cancel.
    @Published var selectionArmed: Bool = true

    /// Popup header legend — blue while the matching key/modifier is held.
    @Published private(set) var popupHintV = false
    @Published private(set) var popupHintShiftV = false
    @Published private(set) var popupHintX = false
    @Published private(set) var popupHintSpace = false
    @Published private(set) var popupHintCmd = false

    /// Optional tag filter. `nil` = Recents (everything). When set,
    /// `displayItems` is filtered to items that include that tag. Cleared
    /// on `dismissPreview` so each new ⌘V session starts at Recents.
    @Published var tagFilter: ClipboardTag? = nil {
        didSet {
            invalidateDisplayItems()
            selectedIndex = 0
            selectionArmed = true
            if previewWindow.isVisible {
                syncItemPreviewWithSelection()
            }
        }
    }
    // Plan-driven ring cap. private(set) — external code must use setRingSize(_:).
    // Never persisted to UserDefaults so it cannot be overridden via `defaults write`.
    @Published private(set) var maxItems: Int = 10 {
        didSet {
            // Trim must happen on the next runloop tick to avoid mutating
            // @Published state while SwiftUI is mid-render (undefined behaviour warning).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let unpinned = self.items.indices.filter { !self.items[$0].isPinned }
                if unpinned.count > self.maxItems {
                    let toRemove = unpinned.suffix(from: self.maxItems)
                    for idx in toRemove.reversed() { self.items.remove(at: idx) }
                }
            }
        }
    }

    /// Public setter for the ring size. Clamps to the plan's maximum so the UI
    /// cannot exceed what the plan allows even if the Stepper range is wrong.
    /// Also persists the user's chosen size so it survives app launches.
    func setRingSize(_ size: Int) {
        let clamped = min(max(size, 1), AuthManager.shared.ringLimit)
        maxItems = clamped
        UserDefaults.standard.set(clamped, forKey: "preferredRingSize")
    }

    @Published var isReversed: Bool = UserDefaults.standard.bool(forKey: "isReversed") {
        didSet {
            UserDefaults.standard.set(isReversed, forKey: "isReversed")
            invalidateDisplayItems()
        }
    }

    @Published var pinnedAtBottom: Bool = UserDefaults.standard.bool(forKey: "pinnedAtBottom") {
        didSet {
            UserDefaults.standard.set(pinnedAtBottom, forKey: "pinnedAtBottom")
            invalidateDisplayItems()
        }
    }

    @Published var captureRichText: Bool = UserDefaults.standard.object(forKey: "captureRichText") as? Bool ?? true {
        didSet { UserDefaults.standard.set(captureRichText, forKey: "captureRichText") }
    }

    @Published var captureFiles: Bool = UserDefaults.standard.object(forKey: "captureFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(captureFiles, forKey: "captureFiles") }
    }

    @Published var fetchURLTitles: Bool = UserDefaults.standard.object(forKey: "fetchURLTitles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fetchURLTitles, forKey: "fetchURLTitles") }
    }

    @Published var showColorSwatches: Bool = UserDefaults.standard.object(forKey: "showColorSwatches") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showColorSwatches, forKey: "showColorSwatches") }
    }

    @Published var autoIgnoreSecrets: Bool = UserDefaults.standard.object(forKey: "autoIgnoreSecrets") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoIgnoreSecrets, forKey: "autoIgnoreSecrets") }
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

    /// Cached, ordered view over `items`. Recomputed only when one of the
    /// four source variables actually changes (items, isReversed,
    /// pinnedAtBottom, timeScrubDate) — see `invalidateDisplayItems()`.
    ///
    /// Previously this was a computed property; SwiftUI re-reads it on every
    /// `body` rebuild and on every `@ObservedObject` re-publish. With the
    /// 50ms progress-bar tick alone that was 20+ O(n) recomputes per second
    /// per visible view. Now the work happens once per real change.
    @Published private(set) var displayItems: [ClipboardItem] = []

    private func invalidateDisplayItems() {
        let source: [ClipboardItem]
        if let cutoff = timeScrubDate {
            source = items.filter { $0.timestamp <= cutoff }
        } else {
            source = items
        }
        let filtered: [ClipboardItem]
        if let tag = tagFilter {
            filtered = source.filter { $0.tags.contains(tag) }
        } else {
            filtered = source
        }
        var pinned:   [ClipboardItem] = []
        var unpinned: [ClipboardItem] = []
        pinned.reserveCapacity(filtered.count)
        unpinned.reserveCapacity(filtered.count)
        for item in filtered {
            if item.isPinned { pinned.append(item) } else { unpinned.append(item) }
        }
        if isReversed { unpinned.reverse() }
        displayItems = pinnedAtBottom ? unpinned + pinned : pinned + unpinned
    }

    /// Tags that appear on at least one item in the full ring (ignoring
    /// `tagFilter` and `timeScrubDate`). Drives the horizontal chip strip.
    var availableTags: [ClipboardTag] {
        var present = Set<ClipboardTag>()
        for item in items {
            for tag in item.tags { present.insert(tag) }
        }
        return present.sorted { $0.priority < $1.priority }
    }

    func itemCount(for tag: ClipboardTag) -> Int {
        items.reduce(0) { $0 + ($1.tags.contains(tag) ? 1 : 0) }
    }

    let previewWindow  = PreviewOverlayWindow()
    let transformPanel = TransformPanel()
    let itemPreviewPanel = ItemPreviewPanel()
    let fastPasteHintPanel = FastPasteHintPanel()
    /// Mirrors `AXIsProcessTrusted()`. Initialized synchronously so the
    /// onboarding screen doesn't flash on launch for users who already
    /// granted permission in a previous run. Refreshed by a 1Hz timer in
    /// `startAccessibilityWatcher()` so the UI auto-advances the moment
    /// the user flips the toggle in System Settings — even if our event
    /// tap creation races with TCC propagation.
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    private var accessibilityPollTimer: Timer?
    // Internal counters — only set internally, never read by views.
    // Kept as plain stored properties so writes don't trigger SwiftUI
    // re-renders on every keypress.
    private var previewVisible: Bool = false
    private var cycleCount: Int = 0
    private var transformCycleCount: Int = 0
    private var hintKeyVDown = false
    private var hintKeyXDown = false
    private var hintKeySpaceDown = false
    private var hintCmdHeld = false
    private var hintShiftHeld = false

    /// Fires once on the user's first ⌘V cycle — preview overlay shows ⌘X transform tip.
    @Published var showFirstCycleHint: Bool = false
    @Published var transformStageActive: Bool = false
    @Published var timeScrubDate: Date? = nil {        // nil = show all; non-nil = show items up to this date
        didSet { invalidateDisplayItems() }
    }

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

    private let nlEmbedding: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)

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
        }
    }
    /// When false, popup mode can start only while a text input is focused.
    /// When true (default), popup can start anywhere.
    @Published var showPopupOutsideTextInputs: Bool = UserDefaults.standard.object(forKey: "showPopupOutsideTextInputs") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showPopupOutsideTextInputs, forKey: "showPopupOutsideTextInputs") }
    }
    /// When true, the Space-style item preview panel follows the highlighted
    /// row while cycling. When false, Space toggles preview on/off (default).
    @Published var alwaysShowItemPreview: Bool = UserDefaults.standard.object(forKey: "alwaysShowItemPreview") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(alwaysShowItemPreview, forKey: "alwaysShowItemPreview")
            applyAlwaysShowItemPreviewPolicy()
        }
    }

    private var pollTimer: Timer?
    private var permissionRetryTimer: Timer?
    /// Exponential backoff for the permission-retry loop: 1s → 2s → … → 30s.
    /// Reset to 1s on every fresh `attemptEventTap()`.
    private var permissionRetryBackoff: TimeInterval = 1.0
    private var stageRevertTimer: Timer?
    /// Timer that fires `firstOpenDelay` seconds after the user's first ⌘V
    /// tap. If the user releases ⌘ before it fires we cancel and do a fast
    /// paste of the front item instead of opening the popup.
    private var pendingFirstOpenTimer: Timer?
    /// True between the first ⌘V tap of a session and either:
    ///   (a) the delay timer firing → popup opens, or
    ///   (b) ⌘ being released → fast paste of front item.
    private var pendingFirstOpen: Bool = false
    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isSimulatingPaste = false
    /// Caret position cached from the most recent popup open. AX queries in
    /// Safari/Chrome can take 100–300ms because their accessibility trees are
    /// huge; running them on every V tap turns each cycle into a stutter.
    // Two-stage cycling: Stage 1 = items, Stage 2 = transforms for selected item
    private var inTransformStage = false
    private var transformIndex   = 0
    /// Snapshot transform ordering for the current stage so ⌘X cycles in a
    /// stable one-by-one sequence even if global usage rankings change.
    private var transformDisplaysCache: [TransformDisplay] = []

    private var saveCancellable: AnyCancellable?

    // MARK: - Search overlay state (standalone ⌘F window — kept for future use)
    let searchOverlayWindow = SearchOverlayWindow()
    /// Live search query — updated as the user types in the search overlay.
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

    /// Transient replay flag — toggled true when the user clicks the Clipen
    /// logo/name in the popup header to re-watch the coach.  NOT persisted:
    /// stays for one popup session, retired on dismiss or completion.  The
    /// persistent `popupCoachStep` is untouched — clicking the logo doesn't
    /// reset the user's real progress, it just shows the bubbles again on
    /// top of whatever step they're at.
    @Published var coachReplayActive: Bool = false
    /// Session-local coach step used only during a replay.  Mirrors the
    /// shape of `popupCoachStep` (0 = V, 1 = X, 2 = done) but lives in
    /// memory only.
    @Published var coachReplayStep: Int = 0
    /// Snapshot of `cycleCount` at the moment replay started.  Lets us
    /// advance the replay's V step after the user cycles twice MORE,
    /// regardless of how many cycles they've already accumulated.
    private var coachReplayCycleAnchor: Int = 0

    @Published var searchQuery: String = ""
    /// Which result row is highlighted in the search overlay.
    @Published var searchSelectedIndex: Int = 0
    /// True while the search overlay is visible — freezes the paste-popup dismiss timer.
    @Published var isSearchMode: Bool = false
    /// The app that was frontmost when search opened; restored on paste/close.
    private var searchReturnApp: NSRunningApplication?

    // MARK: - Inline popup search state (⌘F while popup is open)
    /// True while the search bar inside the popup is active.
    @Published var isPopupSearchActive: Bool = false
    /// Query text built character-by-character via the event tap (no key window needed).
    @Published var popupSearchQuery: String = ""
    /// Highlighted row index within popupSearchResults.
    @Published var popupSearchSelectedIndex: Int = 0

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
    private var pageRangePDF: PDFDocument?
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

    /// Search overlay (main window + standalone overlay) — capped at 8.
    /// Hybrid scorer handles lexical + semantic + recency in one pass.
    var searchResults: [ClipboardItem] {
        Array(hybridSearch(query: searchQuery).prefix(8))
    }

    /// Inline popup search results — capped at 5 (fits popup height).
    var popupSearchResults: [ClipboardItem] {
        Array(hybridSearch(query: popupSearchQuery).prefix(5))
    }

    private init() {
        // maxItems is now plan-driven only — remove any stale UserDefaults value
        UserDefaults.standard.removeObject(forKey: "maxItems")
        saveCancellable = $items
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.saveHistory() }
    }

    // MARK: - Start

    func startMonitoring() {
        loadHistory()
        recomputeEmbeddingsInBackground()
        startPolling()
        startAccessibilityWatcher()
        attemptEventTap()
    }

    /// Polls `AXIsProcessTrusted()` once a second. This is the SINGLE source
    /// of truth for `hasAccessibilityPermission` — independent of whether
    /// `CGEvent.tapCreate` happened to succeed. macOS occasionally grants
    /// AX trust slightly before `tapCreate` will accept it; tying the UI
    /// to `tapCreate` instead of `AXIsProcessTrusted` causes a stuck
    /// onboarding screen even when System Settings shows Clipen as ON.
    private func startAccessibilityWatcher() {
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

    // MARK: - Polling

    private func startPolling() {
        lastChangeCount = NSPasteboard.general.changeCount
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollClipboard()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    private func pollClipboard() {
        // User-requested pause (e.g. before entering a password)
        guard !isCapturingPaused else { return }

        guard !isSimulatingPaste else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // 1. File URLs
        if captureFiles {
            let urls = fileURLs(from: pb)
            if !urls.isEmpty {
            let snapshots = FileSnapshotStore.snapshot(urls)
            addItem(ClipboardItem(content: snapshots.count == 1 ? .file(snapshots[0]) : .files(snapshots)))
            return
            }
        }

        // 2. HTML (before RTF/plain text so web formatting survives).
        // The raw HTML string and the extracted plain-text both use
        // multi-encoding fallbacks so WhatsApp / Notes / Slack content —
        // which is often UTF-16 or wrapped in malformed wrappers WebKit's
        // sync parser chokes on — still captures correctly.  Without these
        // fallbacks, long pastes from those apps would silently drop.
        let htmlTypes: [NSPasteboard.PasteboardType] = [
            .init("public.html"),
            .init("Apple HTML pasteboard type")
        ]
        for type in htmlTypes {
            guard let htmlData = pb.data(forType: type) else { continue }
            let html: String? = String(data: htmlData, encoding: .utf8)
                ?? String(data: htmlData, encoding: .utf16)
                ?? String(data: htmlData, encoding: .utf16BigEndian)
                ?? String(data: htmlData, encoding: .utf16LittleEndian)
                ?? String(data: htmlData, encoding: .isoLatin1)
                ?? String(data: htmlData, encoding: .ascii)
            guard let html, !html.isEmpty,
                  let plain = Self.plainText(fromHTML: htmlData),
                  !plain.isEmpty else { continue }
            var item = ClipboardItem(content: .html(html, plain: plain))
            item.isSecret = detectSecret(plain)
            addItem(item)
            return
        }

        // 3. RTF (before plain text — RTF also exposes .string)
        if captureRichText,
           let rtfData = pb.data(forType: .rtf),
           let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil),
           !attrStr.string.isEmpty {
            var item = ClipboardItem(content: .richText(attrStr, plain: attrStr.string))
            item.isSecret = detectSecret(attrStr.string)
            addItem(item)
            return
        }

        // 4. Plain text
        if let str = pb.string(forType: .string), !str.isEmpty {
            var item = ClipboardItem(content: .text(str))
            item.isSecret = detectSecret(str)
            addItem(item)
            if fetchURLTitles {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: trimmed),
                   url.scheme == "http" || url.scheme == "https" {
                    fetchURLTitle(for: item.id, url: url)
                }
            }
            return
        }

        // 5. Images
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .init("public.png"), .tiff,
            .init("com.adobe.pdf"), .init("public.jpeg"), .init("public.heic"),
            .init("com.compuserve.gif"), .init("public.gif")
        ]
        for type in imageTypes {
            if let data = pb.data(forType: type), let img = NSImage(data: data) {
                addItem(ClipboardItem(content: .image(img, rawData: data, dataType: type)))
                return
            }
        }
        if let img = NSImage(pasteboard: pb) {
            let data = img.pngData() ?? Data()
            addItem(ClipboardItem(content: .image(img, rawData: data, dataType: .init("public.png"))))
        }
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []

        if let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: objects)
        }

        let filenameType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let paths = pasteboard.propertyList(forType: filenameType) as? [String] {
            urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
        }

        let fileURLTypes: [NSPasteboard.PasteboardType] = [
            .init("public.file-url"),
            .init("NSURLPboardType"),
            .init("Apple URL pasteboard type"),
            .init("com.apple.pasteboard.promised-file-url")
        ]

        for item in pasteboard.pasteboardItems ?? [] {
            for type in fileURLTypes {
                if let string = item.string(forType: type),
                   let url = parseFileURL(string) {
                    urls.append(url)
                } else if let data = item.data(forType: type),
                          let string = String(data: data, encoding: .utf8),
                          let url = parseFileURL(string) {
                    urls.append(url)
                }
            }

            if let paths = item.propertyList(forType: filenameType) as? [String] {
                urls.append(contentsOf: paths.map { URL(fileURLWithPath: $0) })
            }
        }

        if let string = pasteboard.string(forType: .string),
           let url = parseFileURL(string) {
            urls.append(url)
        }

        var seen = Set<String>()
        return urls.filter { url in
            guard url.isFileURL,
                  FileManager.default.fileExists(atPath: url.path),
                  !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
    }

    private func parseFileURL(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("\n") else { return nil }

        if text.hasPrefix("file://"),
           let url = URL(string: text.removingPercentEncoding ?? text),
           url.isFileURL {
            return url
        }

        if text.hasPrefix("/") || text.hasPrefix("~") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }

        return nil
    }

    private static func plainText(fromHTML data: Data) -> String? {
        // Primary path: WebKit-backed parser via NSAttributedString.  Best
        // fidelity (entities, lists, formatting), but slow + fails for some
        // malformed/embedded HTML and can hang on huge pages.  Wrap in a
        // single attempt; if it returns nil we fall back below.
        if let attr = NSAttributedString(
            html: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) {
            let s = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }

        // Fallback path: decode the raw HTML bytes to a String using whatever
        // encoding works (UTF-8 then UTF-16 then ISO-Latin1 then ASCII), then
        // strip tags with regex.  Loses formatting but keeps the TEXT — the
        // whole point of being a clipboard manager.  Catches WhatsApp /
        // Notes / Slack cases where the HTML is malformed or non-UTF-8 and
        // WebKit's parser silently returns nil.
        let raw: String? = String(data: data, encoding: .utf8)
                       ?? String(data: data, encoding: .utf16)
                       ?? String(data: data, encoding: .utf16BigEndian)
                       ?? String(data: data, encoding: .utf16LittleEndian)
                       ?? String(data: data, encoding: .isoLatin1)
                       ?? String(data: data, encoding: .ascii)
        guard let html = raw, !html.isEmpty else { return nil }
        return stripHTMLTags(html)
    }

    /// Last-resort HTML→text: removes scripts/styles, strips tags, decodes
    /// the handful of named entities WhatsApp/Notes actually use, collapses
    /// whitespace.  Not perfect; good enough to never lose a paste to a
    /// formatting quirk.
    private static func stripHTMLTags(_ html: String) -> String? {
        var s = html
        // Drop <script>...</script> and <style>...</style> contents whole.
        s = s.replacingOccurrences(of: "<script[\\s\\S]*?</script>",
                                   with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<style[\\s\\S]*?</style>",
                                   with: " ", options: .regularExpression)
        // Block-level tags → newline so paragraphs survive.
        s = s.replacingOccurrences(of: "</(p|div|br|li|tr|h[1-6])[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<br[^>]*>", with: "\n",
                                   options: [.regularExpression, .caseInsensitive])
        // Strip remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the entities WhatsApp/Notes/Slack/email actually emit.
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&copy;", "©"), ("&reg;", "®"),
        ]
        for (e, r) in entities { s = s.replacingOccurrences(of: e, with: r) }
        // Numeric entities: &#123;
        s = s.replacingOccurrences(of: "&#(\\d+);", with: " ",
                                   options: .regularExpression) // crude, drops them; rare enough
        // Collapse repeated whitespace but PRESERVE newlines.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True if the text looks like an API key / token / password.  Honours the
    /// user's `autoIgnoreSecrets` toggle: when the toggle is OFF, we still
    /// capture everything but never flag — the user explicitly opted out of
    /// the security overlay.  When ON (default), suspected secrets get the
    /// flag so the row shows the red lock badge.  Items are captured either
    /// way — the on-disk history is AES-GCM encrypted regardless.
    private func detectSecret(_ text: String) -> Bool {
        guard autoIgnoreSecrets else { return false }
        return SecretDetector.isLikelySecret(text)
    }

    private func addItem(_ item: ClipboardItem) {
        if let first = items.first(where: { !$0.isPinned }),
           item.isDuplicate(of: first) { return }

        var item = item
        if item.sourceAppName == nil, let app = NSWorkspace.shared.frontmostApplication {
            item.sourceAppName = app.localizedName
            item.sourceBundleID = app.bundleIdentifier
        }

        // Compute diff badge before inserting (existing items are current ring)
        if case .text(let newText) = item.content {
            var mutableItem = item
            mutableItem.diffBadge = computeDiffBadge(newText: newText, against: items)
            items.insert(mutableItem, at: 0)
        } else {
            items.insert(item, at: 0)
        }

        let unpinned = items.indices.filter { !items[$0].isPinned }
        if unpinned.count > maxItems, let oldest = unpinned.last {
            items.remove(at: oldest)
        }
        selectedIndex = 0

        if let str = item.textForEmbedding {
            let itemID = item.id
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, let emb = self.nlEmbedding,
                      let vector = emb.vector(for: str) else { return }
                let floats = vector.map { Float($0) }
                DispatchQueue.main.async {
                    if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                       self.items[idx].embedding == nil {
                        self.items[idx].embedding = floats
                        self.embeddedItemCount += 1
                    }
                }
            }
        }
    }

    private func fetchURLTitle(for itemID: UUID, url: URL) {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let html = String(data: data, encoding: .utf8)
                          ?? String(data: data, encoding: .isoLatin1) else { return }
            guard let startRange = html.range(of: "<title", options: .caseInsensitive),
                  let gtIdx = html[startRange.upperBound...].firstIndex(of: ">"),
                  let endRange = html.range(of: "</title>", options: .caseInsensitive) else { return }
            let titleStart = html.index(after: gtIdx)
            guard titleStart < endRange.lowerBound else { return }
            let title = String(html[titleStart..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .htmlDecoded
            guard !title.isEmpty else { return }
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[idx].urlTitle = title
            }
        }.resume()
    }

    // MARK: - Event tap

    func attemptEventTap() {
        // Skip if a healthy tap already exists — re-entry would leak
        // CFMachPort + CFRunLoopSource pairs every time and force the
        // system to route every Cmd+V through multiple competing taps.
        if eventTap != nil { return }

        // Cancel any previous permission-polling timer — it may still be
        // running from a prior attemptEventTap() call. Multiple timers
        // would each try to createEventTap and then leak.
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        // Reset backoff so a fresh attempt cycle starts at 1s, not 30s.
        permissionRetryBackoff = 1.0

        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            scheduleNextPermissionRetry()
        }
    }

    /// Schedules a single retry of `AXIsProcessTrusted` with growing intervals.
    /// 1s → 2s → 4s → 8s → 16s → 30s (capped).  When permission lands the
    /// timer is invalidated immediately and the tap is created.  Keeping it
    /// non-repeating means we can grow the interval each time without ever
    /// having two timers racing.
    private func scheduleNextPermissionRetry() {
        let interval = min(permissionRetryBackoff, 30.0)
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.permissionRetryTimer?.invalidate()
                self.permissionRetryTimer = nil
                self.permissionRetryBackoff = 1.0
                self.createEventTap()
            } else {
                // Still no permission — double the wait, up to 30s.
                self.permissionRetryBackoff = min(self.permissionRetryBackoff * 2, 30.0)
                self.scheduleNextPermissionRetry()
            }
        }
        if let t = permissionRetryTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Remove the existing tap from the run loop and disable it. Called
    /// before recreating a tap so we never end up with two live ones.
    private func teardownEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    private func createEventTap() {
        // Defensive: if we somehow have a leftover tap, kill it first.
        teardownEventTap()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let mgr = Unmanaged<ClipboardManager>.fromOpaque(refcon!).takeUnretainedValue()
                return mgr.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // `hasAccessibilityPermission` is owned by the AX watcher — don't
        // shadow it here. It already flipped to `true` the moment AX
        // trust was granted, regardless of tap creation timing.
    }

    // MARK: - Event handling

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // ── Critical: handle tap-disable events ──────────────────────────
        // macOS auto-disables event taps when the callback takes too long
        // to return OR when the user triggers a flood of events. Once
        // disabled, our callback stops being invoked — Cmd+V vanishes into
        // a dead tap and never reaches the system, breaking BOTH our popup
        // AND the system's default paste until the app is quit.
        //
        // The fix: re-enable the tap immediately. This is exactly what
        // every well-behaved event tap (e.g. the BetterTouchTool, Karabiner,
        // Maccy reference impls) does.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let hasCmd = event.flags.contains(.maskCommand)
            notePopupHintModifiers(cmd: hasCmd, shift: event.flags.contains(.maskShift))
            if !hasCmd {
                // If search OR page-range picker is active, the user is typing
                // / picking — ⌘ release must NOT close the popup or trigger a
                // paste.  Both modes end only via ⎋ or ↵.
                if (isPopupSearchActive || inPageRangeMode) && previewWindow.isVisible {
                    return Unmanaged.passUnretained(event)
                }
                // Release-while-pending cases:
                //  • pendingFirstOpen → fast-paste front item, no popup
                //  • popup visible → commit paste (Space-preview panel, if
                //    open, is torn down inside commitPaste — so releasing ⌘
                //    while previewing now ALSO pastes the highlighted row
                //    instead of just dismissing the preview).
                if pendingFirstOpen {
                    DispatchQueue.main.async { [weak self] in self?.fastPasteFront() }
                } else if previewWindow.isVisible {
                    // ⌘ release while the popup is open ALWAYS commits the
                    // highlighted row.  No more idle-timer "disarm" path:
                    // popup stays armed as long as it's visible, just like
                    // ⌘Tab.  To cancel without pasting, press Esc.
                    DispatchQueue.main.async { [weak self] in self?.commitPaste() }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
            notePopupHintModifiers(cmd: event.flags.contains(.maskCommand),
                                   shift: event.flags.contains(.maskShift))
            notePopupHintKeyUp(keycode: key)
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let key   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        notePopupHintModifiers(cmd: flags.contains(.maskCommand),
                               shift: flags.contains(.maskShift))
        notePopupHintKeyDown(keycode: Int(key), cmd: flags.contains(.maskCommand))
        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let opt   = flags.contains(.maskAlternate)
        let ctrl  = flags.contains(.maskControl)

        // ── Inline page-range picker routing ───────────────────────────────
        // When the "Paste Specific Pages" picker is active we intercept ALL
        // non-⌘ keystrokes and route them to pageRangeQuery (typed digits,
        // dashes, commas) or to actions (return, escape, space-preview).
        // Mouse clicks on page-grid buttons are handled by SwiftUI directly.
        if inPageRangeMode && !cmd {
            switch key {
            case 53: // Esc — exit picker mode AND close the popup.  Single
                     // press is unambiguous: nothing pastes, everything closes.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.exitPageRangeMode()
                    self.dismissPreview()
                }
                return nil
            case 51: // ⌫ Backspace
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.pageRangeQuery.isEmpty { self.pageRangeQuery.removeLast() }
                }
                return nil
            case 36, 76: // Return / Enter — commit paste
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let n = self.pageRangeEffectiveSelection.count
                    NSLog("[Clipen] page-picker Enter pressed; selection=\(n) pages")
                    self.commitPageRangePaste()
                }
                return nil
            case 49:     // Space — toggle inline preview of would-be-pasted text
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let n = self.pageRangeEffectiveSelection.count
                    NSLog("[Clipen] page-picker Space pressed; selection=\(n) pages; previewVisible=\(self.itemPreviewPanel.isVisible)")
                    self.showPageRangePreview()
                }
                return nil
            default:
                // Accept digits, dash, and comma only — silently drop everything else.
                var length: Int = 0
                var chars = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4,
                                               actualStringLength: &length,
                                               unicodeString: &chars)
                guard length > 0 else { return nil }
                let typed = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                let filtered = typed.filter { c in
                    c.isNumber || c == "-" || c == "," || c == " "
                }
                if !filtered.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.pageRangeQuery += filtered
                    }
                }
                // Swallow everything in page-range mode so stray keystrokes
                // never reach the target app.
                return nil
            }
        }

        // ── Inline popup search routing ────────────────────────────────────
        // When the search bar inside the popup is active we intercept ALL
        // keystrokes here (before the ⌘-guard below) and route them to the
        // popupSearchQuery string.  No window-focus change is needed because
        // every key already flows through this tap.
        if isPopupSearchActive && previewWindow.isVisible && !cmd {
            switch key {
            case 53: // Esc — clear query first; second Esc exits search
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if self.popupSearchQuery.isEmpty {
                        self.isPopupSearchActive = false
                    } else {
                        self.popupSearchQuery = ""
                        self.popupSearchSelectedIndex = 0
                    }
                }
                return nil
            case 51: // ⌫ Backspace
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if !self.popupSearchQuery.isEmpty {
                        self.popupSearchQuery.removeLast()
                        self.popupSearchSelectedIndex = 0
                    }
                }
                return nil
            case 36, 76: // Return / Enter
                DispatchQueue.main.async { [weak self] in self?.commitPopupSearchPaste() }
                return nil
            case 125: // ↓
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let max = max(0, self.popupSearchResults.count - 1)
                    self.popupSearchSelectedIndex = min(self.popupSearchSelectedIndex + 1, max)
                }
                return nil
            case 126: // ↑
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.popupSearchSelectedIndex = max(0, self.popupSearchSelectedIndex - 1)
                }
                return nil
            default:
                // Printable character — extract from CGEvent and append
                var length: Int = 0
                var chars = [UniChar](repeating: 0, count: 8)
                event.keyboardGetUnicodeString(maxStringLength: 8,
                                               actualStringLength: &length,
                                               unicodeString: &chars)
                if length > 0 {
                    let s = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                        .filter { !$0.isNewline && $0.unicodeScalars.allSatisfy { $0.value >= 32 } }
                    if !s.isEmpty {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.popupSearchQuery += s
                            self.popupSearchSelectedIndex = 0
                        }
                        return nil
                    }
                }
            }
        }

        // Escape — cancel popup without pasting
        if key == 53 && previewWindow.isVisible {
            DispatchQueue.main.async { [weak self] in self?.dismissPreview() }
            return nil
        }

        // Space — Quick Look-style temporary preview for the highlighted item.
        // The popup is command-driven, so accept Space while the popup is open
        // regardless of whether Command is currently held.
        if key == 49 && previewWindow.isVisible {
            DispatchQueue.main.async { [weak self] in self?.toggleSelectedItemPreview() }
            return nil
        }

        // Plain ⌘ allowed; ⌃ never. Shift is allowed only for the V key
        // (⌘⇧V → next category) — handled below before we tighten the
        // guard further down.
        guard cmd && !ctrl else { return Unmanaged.passUnretained(event) }

        if key == 9 { // V — ⌘V cycle, ⌘⌥V jump+5, ⌘⇧V next category
            if isSimulatingPaste { return Unmanaged.passUnretained(event) }
            // One logical step per physical press — swallow OS key-repeat
            // (mirrors the X handler).  Without this, holding/firing V fast
            // spins cycleNext at the autorepeat rate; on a large ring that
            // merely scrolls quickly, but on a SHORT list (Prediction's 5, or
            // a sparse tag category) it wraps so fast the selection looks
            // frozen on one row — which read as "cycling only works in
            // Recents."  Recents just has enough rows to make the motion
            // visible.  Swallowing repeats makes every category step evenly.
            if previewWindow.isVisible,
               event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            // Optional strict mode: only activate popup flows while user is
            // actively focused in a text-editable element.
            if !previewWindow.isVisible,
               !pendingFirstOpen,
               !showPopupOutsideTextInputs,
               focusedTextInputPosition() == nil {
                return Unmanaged.passUnretained(event)
            }
            if displayItems.isEmpty && !previewWindow.isVisible && !shift {
                return Unmanaged.passUnretained(event)
            }

            if shift && !opt {
                DispatchQueue.main.async { [weak self] in self?.cyclePrevious() }
                return nil
            }

            if opt {
                // ⌘⌥V — jump 5 items forward
                DispatchQueue.main.async { [weak self] in self?.jumpForward(by: 5) }
            } else {
                // ⌘V — next item
                DispatchQueue.main.async { [weak self] in self?.cycleNext() }
            }
            return nil
        }

        // X / ⇧X — same as V / ⇧V: move the selection one step down or up.
        if key == 7 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            DispatchQueue.main.async { [weak self] in
                if shift { self?.cyclePrevious() }
                else      { self?.cycleNext() }
            }
            return nil
        }

        // Other shortcuts require plain ⌘ — no shift, no opt.
        guard !shift && !opt else { return Unmanaged.passUnretained(event) }

        // ⌘1 … ⌘9 — switch the CATEGORY filter (was: jump to row N).
        // ⌘1 = Recents (no filter), ⌘2 = first available category, ⌘3 =
        // second, …  Numbers are advertised by the "1.", "2." prefixes on
        // the category chip strip itself, so the binding is discoverable.
        if let target = Self.numberRowKeycodeToIndex[key],
           previewWindow.isVisible || pendingFirstOpen {
            DispatchQueue.main.async { [weak self] in self?.selectCategoryByIndex(target) }
            return nil
        }

        if key == 51 && previewWindow.isVisible { // ⌫ — delete highlighted item
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionArmed else { return }
                self.deleteSelected()
            }
            return nil
        }

        if key == 3 { // ⌘F
            if previewWindow.isVisible {
                // Popup is open → toggle inline search bar inside the popup
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isPopupSearchActive.toggle()
                    if self.isPopupSearchActive {
                        // Freeze dismiss timer while the user is typing.
                    } else {
                        // Search cancelled — clear query and resume normal timer.
                        self.popupSearchQuery = ""
                        self.popupSearchSelectedIndex = 0
                    }
                }
                return nil
            }
            // Popup is NOT open → pass through so other apps (Finder, browser) get ⌘F
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Popup header hint press feedback

    private var popupHintSessionActive: Bool {
        previewWindow.isVisible || pendingFirstOpen
    }

    private func clearPopupHintHighlights() {
        hintKeyVDown = false
        hintKeyXDown = false
        hintKeySpaceDown = false
        hintCmdHeld = false
        hintShiftHeld = false
        popupHintV = false
        popupHintShiftV = false
        popupHintX = false
        popupHintSpace = false
        popupHintCmd = false
    }

    private func notePopupHintModifiers(cmd: Bool, shift: Bool) {
        hintCmdHeld = cmd
        hintShiftHeld = shift
        DispatchQueue.main.async { [weak self] in self?.syncPopupHintHighlights() }
    }

    private func notePopupHintKeyDown(keycode: Int, cmd: Bool) {
        switch keycode {
        case 9 where cmd:  hintKeyVDown = true
        case 7 where cmd:  hintKeyXDown = true
        case 49:          hintKeySpaceDown = true
        default: break
        }
        DispatchQueue.main.async { [weak self] in self?.syncPopupHintHighlights() }
    }

    private func notePopupHintKeyUp(keycode: Int) {
        switch keycode {
        case 9:  hintKeyVDown = false
        case 7:  hintKeyXDown = false
        case 49: hintKeySpaceDown = false
        default: break
        }
        DispatchQueue.main.async { [weak self] in self?.syncPopupHintHighlights() }
    }

    private func syncPopupHintHighlights() {
        guard popupHintSessionActive else {
            clearPopupHintHighlights()
            return
        }
        popupHintCmd = hintCmdHeld
        if hintKeyVDown && hintCmdHeld {
            popupHintV = !hintShiftHeld
            popupHintShiftV = hintShiftHeld
        } else {
            popupHintV = false
            popupHintShiftV = false
        }
        popupHintX = hintKeyXDown && hintCmdHeld && previewWindow.isVisible
        popupHintSpace = hintKeySpaceDown && previewWindow.isVisible
    }

    // MARK: - Two-stage transform

    private func enterTransformStage() {
        guard selectionArmed, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        // Free plan — transforms locked
        guard AuthManager.shared.transformsEnabled else {
            transformPanel.showUpgradePrompt(near: previewWindow.frame)
            return
        }
        // (X coach advancement moved into cycleTransform() — pressing X
        // ONCE just opens the transform panel.  The user needs to TAP X a
        // few more times to feel the cycle through different tools before
        // we retire the bubble.  See cycleTransform() for the rule.)
        inTransformStage = true
        refreshTransformDisplaysCache()
        guard !transformDisplaysCache.isEmpty else {
            inTransformStage = false
            return
        }
        transformIndex   = 0
        transformStageActive = true
        // Freeze dismiss timer while inspecting transforms
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        updateTransformPanel()
    }

    private func cycleTransform() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        transformCycleCount += 1

        // Unified cycling for ALL content types (text, richText, image, PDF, file)
        guard !transformDisplaysCache.isEmpty else { return }
        transformIndex = (transformIndex + 1) % transformDisplaysCache.count
        updateTransformPanel()

        // Coach step 1 → done: only after the user has cycled through a
        // few transforms.  Opening the panel once doesn't count — the
        // point of the bubble is to teach that X is a CYCLE, not a single
        // action.  Three taps inside the panel proves the user got it.
        if popupCoachStep == 1 && transformCycleCount >= 3 {
            popupCoachStep = 2
        }
        if coachReplayActive && coachReplayStep == 1 && transformCycleCount >= 3 {
            coachReplayStep = 2
            coachReplayActive = false
        }
    }

    /// ⌘⇧X — step one transform BACKWARD in the cached display list.
    /// Mirrors cycleTransform's wrap (first ← last) so the user can nudge
    /// in either direction without leaving the transform stage.  Same
    /// guard set, same cache, same panel-refresh path.
    private func cycleTransformBackward() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        transformCycleCount += 1

        guard !transformDisplaysCache.isEmpty else { return }
        let n = transformDisplaysCache.count
        // -1 % n is implementation-defined in Swift — compute explicitly.
        transformIndex = (transformIndex - 1 + n) % n
        updateTransformPanel()
    }

    private func scheduleStageRevert() {
        guard inTransformStage else { return }
        stageRevertTimer?.invalidate()
        stageRevertTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.exitTransformStage() }
        }
        RunLoop.main.add(stageRevertTimer!, forMode: .common)
    }

    private func exitTransformStage() {
        inTransformStage = false
        transformIndex   = 0
        transformDisplaysCache = []
        transformStageActive = false
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        transformPanel.hide()
        itemPreviewPanel.hide()
        // Unfreeze and restart dismiss countdown
    }

    /// Rebuild transform list from current usage scores; keep highlight on the same tool id.
    private func refreshTransformDisplaysCache() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else {
            transformDisplaysCache = []
            return
        }
        let selectedID = transformDisplaysCache.indices.contains(transformIndex)
            ? transformDisplaysCache[transformIndex].id
            : nil
        transformDisplaysCache = ToolRegistry.displays(for: displayItems[selectedIndex])
        if let selectedID,
           let newIdx = transformDisplaysCache.firstIndex(where: { $0.id == selectedID }) {
            transformIndex = newIdx
        } else {
            transformIndex = min(transformIndex, max(0, transformDisplaysCache.count - 1))
        }
    }

    private func updateTransformPanel() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let anchor = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems: displayItems.count
        )
        transformPanel.show(for: displayItems[selectedIndex],
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            displaysOverride: inTransformStage ? transformDisplaysCache : nil)
    }

    /// Force-redraw the transform panel with the `isProcessing` flag toggled so
    /// the row for the selected transform shows a spinner while async work runs.
    private func updateTransformPanelProcessing(_ processing: Bool) {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let anchor = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems: displayItems.count
        )
        transformPanel.show(for: displayItems[selectedIndex],
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            isProcessing: processing,
                            displaysOverride: inTransformStage ? transformDisplaysCache : nil)
    }

    private func toggleSelectedItemPreview() {
        guard previewWindow.isVisible,
              !displayItems.isEmpty,
              selectedIndex < displayItems.count else { return }
        if itemPreviewPanel.isVisible {
            itemPreviewPanel.hide()
        } else {
            showSelectedItemPreview()
        }
    }

    private func showSelectedItemPreview() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        itemPreviewPanel.show(for: displayItems[selectedIndex], near: previewWindow.frame)
    }

    private func applyAlwaysShowItemPreviewPolicy() {
        guard previewWindow.isVisible else {
            if !alwaysShowItemPreview { itemPreviewPanel.hide() }
            return
        }
        syncItemPreviewWithSelection()
    }

    /// Keeps the item preview panel in sync with the current selection when
    /// `alwaysShowItemPreview` is on, or refreshes it when the user already
    /// opened preview via Space.
    private func syncItemPreviewWithSelection() {
        guard previewWindow.isVisible else { return }
        if alwaysShowItemPreview {
            guard selectionArmed,
                  !displayItems.isEmpty,
                  selectedIndex < displayItems.count else {
                if itemPreviewPanel.isVisible {
                    itemPreviewPanel.hide()
                }
                return
            }
            showSelectedItemPreview()
        } else if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
    }

    /// Synchronous sibling of `ToolRegistry.run` for tools that can finish
    /// immediately. Async tools still go through the Task path so the panel can
    /// show processing state.
    private func applySyncTransform(item: ClipboardItem, toolID: String) -> TransformOutput? {
        ToolRegistry.runSync(item: item, toolID: toolID)
    }

    func pasteTransformed(_ text: String, restoring source: ClipboardItem? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        finishTransformPaste(message: nil, restoring: source)
    }

    /// Public entry for menu-bar / settings UI (same path as ⌘X transform paste).
    func pasteGeneratedTransformItem(_ item: ClipboardItem, message: String, restoring source: ClipboardItem) {
        pasteGeneratedItem(item, message: message, restoring: source)
    }

    func pasteGeneratedTransformFiles(_ urls: [URL], message: String, restoring source: ClipboardItem) {
        pasteGeneratedFiles(urls, message: message, restoring: source)
    }

    /// Single entry for applying any transform result (⌘X popup, menu bar, etc.).
    func applyTransformResult(_ result: TransformOutput?, restoring source: ClipboardItem, toolID: String? = nil) {
        guard let result else {
            flashStatus("Transform returned nothing.")
            return
        }

        if let toolID, !toolID.isEmpty, transformResultCountsAsUsage(result) {
            AuthManager.shared.registerToolUsage(toolID: toolID)
        }

        switch result {
        case .text(let text) where !text.isEmpty:
            pasteTransformed(text, restoring: source)
        case .item(let item, let message):
            pasteGeneratedTransformItem(item, message: message, restoring: source)
        case .files(let urls, let message):
            pasteGeneratedTransformFiles(urls, message: message, restoring: source)
        case .revealFiles(let urls, let message):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            flashStatus(message)
        case .status(let message):
            flashStatus(message)
        default:
            flashStatus("Transform returned nothing.")
        }
    }

    private func handleTransformResult(_ result: TransformOutput?, restoring source: ClipboardItem, toolID: String? = nil) {
        applyTransformResult(result, restoring: source, toolID: toolID)
    }

    private func transformResultCountsAsUsage(_ result: TransformOutput) -> Bool {
        switch result {
        case .status: return false
        case .text(let text): return !text.isEmpty
        case .item, .files, .revealFiles: return true
        }
    }

    private func pasteGeneratedItem(_ item: ClipboardItem, message: String, restoring source: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if ImageService.shouldWriteExportFile(transformed: item, source: source),
           case .image(_, let rawData, let dataType) = item.content,
           let fileName = ImageService.persistExportFile(
               data: rawData,
               dataType: dataType,
               baseName: exportBaseName(for: source)
           ) {
            // Write a single item that carries both the file URL and inline image data
            pb.writeObjects([makeFilePasteboardItem(for: ImageService.exportFileURL(fileName: fileName))])
        } else {
            write(item, to: pb)
        }

        lastChangeCount = pb.changeCount
        finishTransformPaste(message: message, restoring: source)
    }

    private func exportBaseName(for item: ClipboardItem) -> String? {
        switch item.content {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .files(let urls):
            return urls.first?.deletingPathExtension().lastPathComponent
        default:
            return nil
        }
    }

    private func pasteGeneratedFiles(_ urls: [URL], message: String, restoring source: ClipboardItem) {
        guard !urls.isEmpty else {
            flashStatus("No files were generated.")
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { makeFilePasteboardItem(for: $0) })
        lastChangeCount = pb.changeCount
        finishTransformPaste(message: message, restoring: source)
    }

    /// Paste transform output into the frontmost app, then put the original
    /// source item back on the pasteboard. Transformed output is never added
    /// to the Clipen ring.
    private func finishTransformPaste(message: String?, restoring source: ClipboardItem?) {
        // Record destination on the SOURCE item (the one the user picked)
        // before hiding panels — frontmost is still the target app.
        if let source { recordPasteDestination(for: source.id) }
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        selectionArmed = true
        if let message { flashStatus(message) }

        isSimulatingPaste = true
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // Restore the original item BEFORE clearing isSimulatingPaste so
            // pollClipboard() cannot capture the transformed payload into the ring.
            if let source {
                let pb = NSPasteboard.general
                pb.clearContents()
                self.write(source, to: pb)
                self.lastChangeCount = pb.changeCount
            }
            self.isSimulatingPaste = false
            self.selectedIndex = 0
            self.selectionArmed = true
        }
    }

    // MARK: - Cycling & pasting

    private func cycleNext() {
        let display = displayItems
        guard !display.isEmpty else { return }

        if !previewWindow.isVisible {
            if pendingFirstOpen {
                cancelPendingFirstOpen()
                openPopupNow()
                selectedIndex = min(1, display.count - 1)
            } else if firstOpenDelay > 0 {
                selectedIndex = 0
                pendingFirstOpen = true
                pendingFirstOpenTimer?.invalidate()
                let t = Timer(timeInterval: firstOpenDelay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.openPopoverAfterDelay() }
                }
                RunLoop.main.add(t, forMode: .common)
                pendingFirstOpenTimer = t
                return
            } else {
                selectedIndex = 0
                openPopupNow()
            }
        } else {
            selectedIndex = (selectedIndex + 1) % display.count
        }

        previewVisible = true
        cycleCount += 1

        if popupCoachStep == 0 && cycleCount >= 3 { popupCoachStep = 1 }
        if coachReplayActive, coachReplayStep == 0,
           cycleCount - coachReplayCycleAnchor >= 3 { coachReplayStep = 1 }

        syncItemPreviewWithSelection()
    }

    /// ⌘⇧V — step one item BACKWARD in the current category.  Mirrors
    /// cycleNext / cycleNext's wrap behavior (last → first becomes
    /// first → last) so the user can nudge in either direction without
    /// taking their hand off the ⌘ key.  No popup-open-on-first-press
    /// dance: ⇧V before the popup is open opens it on the LAST item.
    private func cyclePrevious() {
        let display = displayItems
        guard !display.isEmpty else { return }

        if !previewWindow.isVisible {
            cancelPendingFirstOpen()
            selectedIndex = display.count - 1
            openPopupNow()
        } else {
            selectedIndex = (selectedIndex - 1 + display.count) % display.count
        }

        previewVisible = true
        cycleCount += 1
        syncItemPreviewWithSelection()
    }

    /// Top-row number keycodes (kVK_ANSI_1 … kVK_ANSI_9) mapped to the
    /// zero-based CATEGORY index they should select.  ⌘1 → Recents (no
    /// filter), ⌘2 → first available category, ⌘3 → second, etc.  Numbers
    /// past 9 (rare — most rings have ≤6 active categories) have no
    /// keybinding and the chip just renders with no prefix.
    /// ⌘0 is intentionally NOT in the map — it's a system-reserved
    /// shortcut in many apps (zoom-to-fit etc.).
    private static let numberRowKeycodeToIndex: [Int64: Int] = [
        18: 0, // 1
        19: 1, // 2
        20: 2, // 3
        21: 3, // 4
        23: 4, // 5
        22: 5, // 6
        26: 6, // 7
        28: 7, // 8
        25: 8, // 9
    ]

    /// Switch the active category filter by 1-based chip index.
    ///   idx == 0 → Recents (no filter)
    ///   idx == 1 → first item in `availableTags`
    ///   idx == 2 → second … etc.
    /// Out-of-range indices (e.g. ⌘5 with only 3 categories) are ignored.
    /// Opens the popup if it isn't already visible.
    private func selectCategoryByIndex(_ idx: Int) {
        // idx 0 = Recents (no filter), idx 1+ = availableTags[idx-1]
        let total = 1 + availableTags.count
        guard idx >= 0, idx < total else { return }

        let wasFirstOpen = !previewWindow.isVisible
        if wasFirstOpen {
            cancelPendingFirstOpen()
            openPopupNow()
        }
        if idx == 0 {
            tagFilter = nil
        } else {
            tagFilter = availableTags[idx - 1]
        }
        selectedIndex = 0
        selectionArmed = true
        previewVisible = true
        cycleCount += 1
        syncItemPreviewWithSelection()
    }

    /// Jump `step` items forward through the ring (default 5). Bound to
    /// ⌘+⌥V — the user's leap-ahead shortcut for large rings where ⌘V-by-one
    /// is too slow. If the popup isn't open yet, opens it positioned at the
    /// jumped index; otherwise just advances the selection.
    private func jumpForward(by step: Int = 5) {
        let display = displayItems
        guard !display.isEmpty else { return }

        let isFirstOpen = !previewWindow.isVisible
        if isFirstOpen {
            // Explicit jump → user wants the popup, no delay games.
            cancelPendingFirstOpen()
            selectedIndex = min(step, display.count - 1)
            openPopupNow()
        } else {
            clampSelectedIndexToDisplay()
            selectedIndex = (selectedIndex + step) % display.count
            selectionArmed = true
        }

        previewVisible = true
        cycleCount += 1
        syncItemPreviewWithSelection()
    }

    /// Fired by the delay timer when the user kept ⌘ held past
    /// `firstOpenDelay` — open the popup at row 0 just like the old
    /// instant-open did.
    private func openPopoverAfterDelay() {
        guard pendingFirstOpen else { return }
        pendingFirstOpen = false
        pendingFirstOpenTimer = nil
        guard !displayItems.isEmpty else { return }
        openPopupNow()
        previewVisible = true
        cycleCount += 1
    }

    /// Centralised "open the panel" — two states only:
    ///   1. Near the active text input (caret anchor).
    ///   2. Centre of the screen — fallback when no text field is focused.
    private func openPopupNow() {
        selectionArmed = true
        tagFilter = nil
        if let textPos = focusedTextInputPosition() {
            previewWindow.show(at: textPos)
        } else {
            previewWindow.showCentered()
        }
        syncItemPreviewWithSelection()
    }

    // MARK: - Search overlay

    func openSearch() {
        searchReturnApp = NSWorkspace.shared.frontmostApplication
        searchQuery = ""
        searchSelectedIndex = 0
        isSearchMode = true
        searchOverlayWindow.show()
    }

    func closeSearch() {
        isSearchMode = false
        searchQuery  = ""
        searchSelectedIndex = 0
        searchOverlayWindow.hide()
        let app = searchReturnApp
        searchReturnApp = nil
        app?.activate(options: .activateIgnoringOtherApps)
    }

    func searchSelectNext() {
        let cap = min(8, searchResults.count)
        searchSelectedIndex = min(searchSelectedIndex + 1, max(0, cap - 1))
    }

    func searchSelectPrev() {
        searchSelectedIndex = max(searchSelectedIndex - 1, 0)
    }

    /// Paste the currently-selected search result into the original app.
    func commitSearchPaste() {
        let results = searchResults
        guard !results.isEmpty else { closeSearch(); return }
        let item = results[min(searchSelectedIndex, results.count - 1)]

        // searchReturnApp is the destination — the app that was frontmost when
        // the search opened.  Record before we close the search overlay.
        if let returnApp = searchReturnApp {
            recordPaste(itemID: item.id,
                        appName: returnApp.localizedName,
                        bundleID: returnApp.bundleIdentifier)
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb)
        lastChangeCount = pb.changeCount

        isSearchMode = false
        searchQuery  = ""
        searchSelectedIndex = 0
        searchOverlayWindow.hide()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()

        let returnApp = searchReturnApp
        searchReturnApp = nil

        // Restore focus to the original app, then fire ⌘V so it receives the paste.
        returnApp?.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.isSimulatingPaste = true
            let src  = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.isSimulatingPaste = false }
            AuthManager.shared.registerCommandVAction()
        }
    }

    // MARK: - Inline page-range picker control

    /// Switch the TransformPanel from its tool list into the page-picker view.
    /// Keeps the popup + transform panel visible so the user has continuous
    /// context; freezes the dismiss timer because typing the range takes
    /// time and a silent dismiss mid-edit would feel broken.
    func enterPageRangeMode(pdf: PDFDocument, item: ClipboardItem, outputMode: PageRangeOutputMode = .combinedPDF) {
        pageRangePDF        = pdf
        pageRangePageCount  = pdf.pageCount
        pageRangeQuery      = ""
        pageRangeManualPages = []
        pageRangeOutputMode  = outputMode
        inPageRangeMode      = true

        // Freeze auto-dismiss — same trick as popup-search.

        let modeLabel = (outputMode == .perPageImages) ? "images" : "PDF"
        flashStatus("Pick pages → \(modeLabel) · ↵ paste · ␣ preview")

        // Force the transform panel to re-render with the picker view AND
        // re-measure its height.  The picker is taller than a typical
        // transform list, so without this the footer (Enter/Space/Esc hints)
        // would be clipped below the panel's existing frame.  The flag
        // tells show() to use a guaranteed minimum height suitable for the
        // grid + header + query + footer.
        let displays = transformDisplaysCache.isEmpty
            ? ToolRegistry.displays(for: item)
            : transformDisplaysCache
        let anchor   = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems:    displayItems.count
        )
        transformPanel.show(for: item,
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            isProcessing: false,
                            displaysOverride: displays)
    }

    func exitPageRangeMode() {
        inPageRangeMode      = false
        pageRangeQuery       = ""
        pageRangeManualPages = []
        pageRangePageCount   = 0
        pageRangePDF         = nil
        pageRangeOutputMode  = .combinedPDF
        itemPreviewPanel.hide()
        // Resume the dismiss countdown.
    }

    func togglePageRangeManualPage(_ index: Int) {
        if pageRangeManualPages.contains(index) {
            pageRangeManualPages.remove(index)
        } else {
            pageRangeManualPages.insert(index)
        }
    }

    /// Commit the page picker.  Output depends on pageRangeOutputMode:
    ///   .combinedPDF — stitch selected pages into ONE new PDF (.copy()-d
    ///                  page-by-page; no text extraction, no rasterising)
    ///                  and paste as a single PDF file.
    ///   .perPageImages — render EACH selected page to its own PNG file
    ///                    at 2× scale and paste the collection as files.
    func commitPageRangePaste() {
        let pages = pageRangeEffectiveSelection.sorted()
        guard !pages.isEmpty else {
            flashStatus("Select at least one page first.")
            return
        }
        guard let originalPDF = pageRangePDF else {
            flashStatus("PDF unavailable.")
            exitPageRangeMode()
            return
        }

        let pb = NSPasteboard.general
        let toolID: String
        switch pageRangeOutputMode {
        case .combinedPDF:
            guard let url = Self.buildCombinedPDF(from: originalPDF, pages: pages) else {
                flashStatus("Couldn't build PDF from selected pages.")
                cleanupAfterPagePicker()
                return
            }
            pb.clearContents()
            pb.writeObjects([makeFilePasteboardItem(for: url)])
            toolID = "pdf.paste-pages"

        case .perPageImages:
            let urls = Self.renderPagesAsImages(from: originalPDF, pages: pages)
            guard !urls.isEmpty else {
                flashStatus("Couldn't render pages as images.")
                cleanupAfterPagePicker()
                return
            }
            pb.clearContents()
            pb.writeObjects(urls.map { makeFilePasteboardItem(for: $0) })
            toolID = "pdf.paste-pages-as-images"
        }
        markPasteboardWriteAsOwn()
        // Page-picker tools bypass applyTransformResult (we write to the
        // pasteboard directly), so usage tracking has to be done here too —
        // otherwise these tools never rise in the ToolRegistry ranking.
        AuthManager.shared.registerToolUsage(toolID: toolID)

        cleanupAfterPagePicker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulateCommandV()
        }
    }

    /// Common teardown after a page-picker commit / fatal-error exit.
    private func cleanupAfterPagePicker() {
        exitPageRangeMode()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        inTransformStage = false
    }

    /// Preview what would be pasted on Enter.  Shows the actual artefacts:
    ///   .combinedPDF mode  → builds the would-be PDF, previews it
    ///   .perPageImages mode → renders the would-be PNGs, previews them
    ///                         (as a .files collection — first image shown,
    ///                         count indicated by the panel chrome).
    /// Second Space toggles off.
    func showPageRangePreview() {
        if itemPreviewPanel.isVisible {
            itemPreviewPanel.hide()
            return
        }
        let pages = pageRangeEffectiveSelection.sorted()
        guard !pages.isEmpty else {
            flashStatus("Select at least one page first.")
            return
        }
        guard let originalPDF = pageRangePDF else { return }

        switch pageRangeOutputMode {
        case .combinedPDF:
            guard let url = Self.buildCombinedPDF(from: originalPDF, pages: pages) else {
                flashStatus("Couldn't build PDF preview.")
                return
            }
            let previewItem = ClipboardItem(content: .file(url))
            itemPreviewPanel.show(for: previewItem, near: transformPanel.frame)

        case .perPageImages:
            let urls = Self.renderPagesAsImages(from: originalPDF, pages: pages)
            guard !urls.isEmpty else {
                flashStatus("Couldn't render image preview.")
                return
            }
            // Single page → preview as file; multiple → as files collection.
            let content: ClipboardContent = (urls.count == 1) ? .file(urls[0]) : .files(urls)
            let previewItem = ClipboardItem(content: content)
            itemPreviewPanel.show(for: previewItem, near: transformPanel.frame)
        }
    }

    /// Construct a new PDFDocument from the user's selected page indices
    /// (0-based, ascending), write it to a unique file in Application
    /// Support/Clipen/Optimized/, and return the URL.  Pages are inserted
    /// IN ORDER — never re-rendered, never re-encoded.  The resulting PDF
    /// is bit-for-bit a subset of the original (just the chosen pages).
    private static func buildCombinedPDF(from original: PDFDocument, pages: [Int]) -> URL? {
        guard !pages.isEmpty else { return nil }

        let newPDF = PDFDocument()
        var insertIdx = 0
        for srcIdx in pages {
            guard srcIdx >= 0, srcIdx < original.pageCount,
                  let page = original.page(at: srcIdx)?.copy() as? PDFPage else { continue }
            newPDF.insert(page, at: insertIdx)
            insertIdx += 1
        }
        guard newPDF.pageCount > 0 else { return nil }

        // Output filename includes the picked page numbers when reasonable
        // (≤4 pages); otherwise just "N pages".  Falls back to a UUID-based
        // path so two concurrent picks can't collide.
        let label: String
        if pages.count <= 4 {
            label = pages.map { String($0 + 1) }.joined(separator: "-")
        } else {
            label = "\(pages.count)-pages"
        }
        let fileName = "Clipen-Pages-\(label)-\(UUID().uuidString.prefix(8)).pdf"

        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        guard newPDF.write(to: url) else { return nil }
        return url
    }

    /// Render each selected page to its own PNG file at 2× scale.  Returns
    /// the list of file URLs in ascending page order.  Files land in a
    /// dedicated subfolder per call so multiple invocations don't pollute
    /// each other's output.  No text extraction — pure raster of whatever
    /// is on the page (works for scanned PDFs, vector PDFs, anything).
    private static func renderPagesAsImages(from original: PDFDocument, pages: [Int]) -> [URL] {
        guard !pages.isEmpty else { return [] }

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        let dir = base.appendingPathComponent("PDF-Pages-\(UUID().uuidString.prefix(8))",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        urls.reserveCapacity(pages.count)
        for srcIdx in pages {
            guard srcIdx >= 0, srcIdx < original.pageCount,
                  let page = original.page(at: srcIdx),
                  let pngData = renderPDFPageToPNG(page: page, scale: 2.0) else { continue }
            let filename = String(format: "page-%03d.png", srcIdx + 1)
            let url = dir.appendingPathComponent(filename)
            do {
                try pngData.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                continue
            }
        }
        return urls
    }

    /// Rasterise a single PDFPage to PNG data at the given scale.
    /// Same approach PDFService.exportPagesAsImages uses — kept local here
    /// so the page-picker doesn't have to reach across into the Tools layer.
    private static func renderPDFPageToPNG(page: PDFPage, scale: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let width  = max(1, Int(bounds.width  * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Tell the polling capture loop that the *next* changeCount bump is our
    /// own write (so it doesn't re-capture our paste as a new clipboard item).
    /// Used by sub-panels (PageRangePanel, etc.) that write directly to
    /// NSPasteboard from outside the regular paste flow.
    func markPasteboardWriteAsOwn() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Post a synthetic ⌘V to the frontmost app.  Mirrors the handshake used
    /// by commitSearchPaste / commitPopupSearchPaste so external panels share
    /// one paste-simulation path.  Caller is responsible for restoring focus
    /// to the original app BEFORE calling this.
    func simulateCommandV() {
        isSimulatingPaste = true
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isSimulatingPaste = false
        }
        AuthManager.shared.registerCommandVAction()
    }

    /// Paste the selected inline-popup-search result.
    /// The popup is a non-activating panel so focus never left the target app;
    /// we just write to NSPasteboard and fire a simulated ⌘V.
    func commitPopupSearchPaste() {
        let results = popupSearchResults
        guard !results.isEmpty else {
            isPopupSearchActive = false
            popupSearchQuery = ""
            return
        }
        let item = results[min(popupSearchSelectedIndex, results.count - 1)]

        // Popup is non-activating — frontmost is still the target app.
        recordPasteDestination(for: item.id)

        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb)
        lastChangeCount = pb.changeCount

        isPopupSearchActive = false
        popupSearchQuery = ""
        popupSearchSelectedIndex = 0
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()

        // Target app already has focus (non-activating popup never stole it).
        // Fire ⌘V immediately so the app pastes the freshly written content.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.isSimulatingPaste = true
            let src  = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.isSimulatingPaste = false }
            AuthManager.shared.registerCommandVAction()
        }
    }

    // MARK: - Embedding recomputation

    /// After loading history from disk, embeddings are nil (not persisted).
    /// Recompute them in the background so semantic search works immediately.
    private func recomputeEmbeddingsInBackground() {
        guard let emb = nlEmbedding else { return }
        let snapshot = items.filter { $0.embedding == nil }
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for item in snapshot {
                guard let self else { return }
                guard let str = item.textForEmbedding,
                      let vector = emb.vector(for: str) else { continue }
                let floats = vector.map { Float($0) }
                let itemID = item.id
                DispatchQueue.main.async {
                    if let idx = self.items.firstIndex(where: { $0.id == itemID }),
                       self.items[idx].embedding == nil {
                        self.items[idx].embedding = floats
                        self.embeddedItemCount += 1
                    }
                }
            }
        }
    }

    /// Returns caret/input position only when the current AX focused element
    /// looks text-editable. Used for strict "typing-only popup" mode.
    private func focusedTextInputPosition() -> NSPoint? {
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                    ?? NSScreen.main?.frame.height
                    ?? 0
        guard let appEl = focusedApplicationAXElement(),
              let axEl = focusedUIElement(in: appEl),
              isTextInputElement(axEl) else { return nil }
        return textCaretPoint(for: axEl, primaryH: primaryH) ?? elementPoint(axEl, primaryH: primaryH)
    }

    private func focusedApplicationAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appEl = appRef as! AXUIElement? else { return nil }
        return appEl
    }

    private func focusedUIElement(in appEl: AXUIElement) -> AXUIElement? {
        var elRef: CFTypeRef?
        let focusedOK = AXUIElementCopyAttributeValue(
            appEl, kAXFocusedUIElementAttribute as CFString, &elRef
        ) == .success
        return focusedOK ? (elRef as! AXUIElement?) : nil
    }

    private func textCaretPoint(for axEl: AXUIElement, primaryH: CGFloat) -> NSPoint? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axEl, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeVal = rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            axEl, kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeVal, &boundsRef
        ) == .success, let boundsVal = boundsRef else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsVal as! AXValue, AXValueType.cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.height > 0, rect.size.height < 200 else { return nil }
        return NSPoint(x: rect.minX, y: primaryH - rect.maxY)
    }

    private func isTextInputElement(_ axEl: AXUIElement) -> Bool {
        // Best signal: if the element exposes text range + bounds, it's a
        // text-editable context (including rich web editors).
        if textCaretPoint(for: axEl, primaryH: 1) != nil { return true }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axEl, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }
        let knownTextRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXWebArea"
        ]
        if knownTextRoles.contains(role) { return true }

        var editableRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axEl, "AXEditable" as CFString, &editableRef) == .success,
           let editable = editableRef as? Bool {
            return editable
        }
        return false
    }

    private func cancelPendingFirstOpen() {
        pendingFirstOpenTimer?.invalidate()
        pendingFirstOpenTimer = nil
        pendingFirstOpen = false
    }

    /// Paste the front item (selectedIndex 0) without ever showing the
    /// popup. Called when the user releases ⌘ inside `firstOpenDelay`.
    /// Visually identical to a system ⌘V for users who weren't trying to
    /// cycle — they just see the paste happen.
    private func fastPasteFront() {
        clearPopupHintHighlights()
        cancelPendingFirstOpen()
        guard !displayItems.isEmpty else { return }
        selectedIndex = 0
        inTransformStage = false
        transformIndex = 0
        // Count this as a fast-paste event (released ⌘ before the popup
        // could open).  Persists locally + ships to backend on next refresh,
        // and ALSO runs the standard ⌘V pipeline (refresh-throttle, update
        // check) since this is a real paste action from the user's POV.
        AuthManager.shared.registerFastPasteAction()
        commitPaste()
        // First time only: surface a small educational alert telling the
        // user what just happened and how to invoke the popup on purpose.
        // Fired AFTER commitPaste so the synthetic ⌘V doesn't race with
        // NSAlert.runModal stealing focus from the target app.
        showFastPasteHintIfNeeded()
    }

    private let fastPasteHintShownKey = "hasShownFastPasteHint"

    /// First time we hit the fast-paste path, surface a one-shot NSAlert
    /// explaining the timing model so the user understands they CAN reach
    /// Clipen's clipboard picker by holding ⌘ a little longer.  Persisted
    /// so it only fires once per install.
    private func showFastPasteHintIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fastPasteHintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: fastPasteHintShownKey)
        let delayMs = max(1, Int((firstOpenDelay * 1000).rounded()))
        // Defer so the paste's synthetic ⌘V has already fired into the
        // target app before we steal focus with the alert.
        // Show the branded SwiftUI panel instead of NSAlert.  Deferred so the
        // synthetic ⌘V from commitPaste has already fired into the target app
        // before we steal focus.  The "Adjust delay" button closes the panel,
        // brings the main window forward, and pulses the slider card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.fastPasteHintPanel.show(delayMs: delayMs) {
                AppDelegate.shared?.openMainWindow()
                ClipboardManager.shared.pulseOpenDelaySlider()
            }
        }
    }

    private func deleteSelected() {
        guard selectionArmed, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        // Resolve by ID so filters (tagFilter, isReversed, pinnedAtBottom) never
        // cause the wrong item to be deleted.
        let target = displayItems[selectedIndex]
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        items.remove(at: realIndex)
        // displayItems is synchronously rebuilt by the items.didSet above.
        if displayItems.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)
        syncItemPreviewWithSelection()
    }

    /// Click handler for the Clipen logo/name in the popup header.  Forces
    /// the coach bubbles to reappear for THIS popup session only — without
    /// touching the persisted `popupCoachStep`.  Anchors the V-step's
    /// "cycle twice more" counter to the current cycleCount so the bubble
    /// advances based on cycles performed AFTER the replay started.
    func replayPopupCoach() {
        coachReplayStep        = 0
        coachReplayCycleAnchor = cycleCount
        coachReplayActive      = true
    }

    /// Clamp `selectedIndex` to `displayItems` after ring mutations.
    private func clampSelectedIndexToDisplay() {
        let display = displayItems
        guard !display.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex), display.count - 1)
    }

    private func dismissPreview() {
        clearPopupHintHighlights()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        cancelPendingFirstOpen()
        inTransformStage = false
        transformIndex   = 0
        selectedIndex    = 0
        selectionArmed   = true
        tagFilter   = nil
        previewVisible   = false
        cycleCount       = 0
        // Coach replay is single-session — close the popup, the replay is
        // over.  Persistent popupCoachStep is intentionally NOT touched.
        coachReplayActive = false
        coachReplayStep   = 0
        // Always reset inline search state when popup closes
        isPopupSearchActive = false
        popupSearchQuery = ""
        popupSearchSelectedIndex = 0
        // Reset page-range state too — no half-typed picker should outlive
        // a dismiss.
        inPageRangeMode = false
        pageRangeQuery = ""
        pageRangeManualPages = []
        pageRangePageCount = 0
        pageRangePDF = nil
    }

    /// Returns the BOTTOM-LEFT of the AX element's frame in AppKit coords.
    /// (Bottom-left of the element ≈ where text baseline is in input fields.)
    private func elementPoint(_ axEl: AXUIElement, primaryH: CGFloat) -> NSPoint? {
        var posRef: CFTypeRef?; var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axEl, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(axEl, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef else { return nil }
        var cgPos = CGPoint.zero; var cgSize = CGSize.zero
        guard AXValueGetValue(posVal  as! AXValue, AXValueType.cgPoint, &cgPos),
              AXValueGetValue(sizeVal as! AXValue, AXValueType.cgSize,  &cgSize) else { return nil }
        // AX rect is (cgPos, cgSize) in top-down. Bottom-left in AppKit:
        //   y = primaryH - (cgPos.y + cgSize.height)
        //   x = cgPos.x  (left edge — for very wide windows, midX would be off-screen-distant)
        let x = cgPos.x + min(cgSize.width / 2, 60)   // small inset so arrow lands inside
        let y = primaryH - (cgPos.y + cgSize.height)
        return NSPoint(x: x, y: y)
    }

    // MARK: - Paste

    /// Record the current frontmost app as the paste destination on the item
    /// with the given ID.  Call this right before the synthetic ⌘V fires so
    /// the popup is still visible (non-activating) and frontmost == target.
    private func recordPasteDestination(for itemID: UUID) {
        guard let dest = NSWorkspace.shared.frontmostApplication else { return }
        recordPaste(itemID: itemID,
                    appName: dest.localizedName,
                    bundleID: dest.bundleIdentifier)
    }

    /// Single source of truth for "this item was just pasted into `appName`".
    /// Stamps destination metadata AND bumps the frequency counters the
    /// predictor reads.  Called from every paste path (plain, transform,
    /// search overlay, popup search) so no paste escapes the tally.
    private func recordPaste(itemID: UUID, appName: String?, bundleID: String?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].pastedToAppName  = appName
        items[idx].pastedToBundleID = bundleID
        items[idx].lastPastedAt     = Date()
        items[idx].pasteCount      += 1
        if let bid = bundleID {
            items[idx].pasteCountByApp[bid, default: 0] += 1
            // Accumulate every destination the item has ever landed in so
            // the UI can show ALL destination apps, not just the last one.
            if let name = appName {
                items[idx].pastedToAppNames[bid] = name
            }
        }
    }

    func commitPaste() {
        guard !items.isEmpty else {
            previewWindow.hide()
            transformPanel.hide()
            itemPreviewPanel.hide()
            return
        }

        stageRevertTimer?.invalidate(); stageRevertTimer = nil

        // Stage 2: apply selected transform (sync OR async) and paste result
        if inTransformStage {
            let item     = displayItems[selectedIndex]
            let idx      = transformIndex
            let selectedToolID = transformDisplaysCache.indices.contains(idx)
                ? transformDisplaysCache[idx].id
                : ToolRegistry.toolID(item: item, index: idx)
            guard let selectedToolID else {
                flashStatus("Selected tool is unavailable.")
                return
            }

            // Interactive transform: "Paste Specific Pages" needs a picker UI
            // inside the existing TransformPanel.  Instead of running the
            // tool's runAsync, swap the transform panel into page-range mode
            // and leave the popup open.  All input (digits, dash, comma,
            // return, escape, space-preview) flows through the CGEventTap
            // just like the popup search bar does — the non-activating panel
            // never has to steal focus from the target app.
            if selectedToolID == "pdf.paste-pages" || selectedToolID == "pdf.paste-pages-as-images" {
                if let input = PDFTools.pdfInput(for: item) {
                    let mode: PageRangeOutputMode =
                        (selectedToolID == "pdf.paste-pages-as-images") ? .perPageImages : .combinedPDF
                    NSLog("[Clipen] commitPaste intercept → enterPageRangeMode mode=\(mode) pages=\(input.pdf.pageCount)")
                    enterPageRangeMode(pdf: input.pdf, item: item, outputMode: mode)
                    return
                } else {
                    NSLog("[Clipen] commitPaste intercept FAILED: pdfInput returned nil for item content=\(item.content)")
                    flashStatus("Couldn't open PDF for page picker.")
                    return
                }
            }

            let isAsync  = ToolRegistry.isAsync(item: item, toolID: selectedToolID)

            if isAsync {
                // Async path (OCR / PDF / export / optimization tools) — show
                // "Processing…", run the work, then paste & dismiss.
                updateTransformPanelProcessing(true)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await ToolRegistry.run(item: item, toolID: selectedToolID)
                    await MainActor.run {
                        self.updateTransformPanelProcessing(false)
                        self.inTransformStage = false
                        self.transformIndex   = 0
                        self.transformPanel.hide()
                        self.itemPreviewPanel.hide()
                        self.previewWindow.hide()
                        self.selectionArmed = true
                        self.handleTransformResult(result, restoring: item, toolID: selectedToolID)
                    }
                }
                return
            } else {
                // Sync path — apply immediately
                let result = applySyncTransform(item: item, toolID: selectedToolID)
                inTransformStage = false; transformIndex = 0
                transformPanel.hide()
                itemPreviewPanel.hide()
                previewWindow.hide()
                selectionArmed = true
                handleTransformResult(result, restoring: item, toolID: selectedToolID)
                return
            }
        }

        inTransformStage = false; transformIndex = 0

        let item = displayItems[selectedIndex]
        // Record which app is receiving this paste BEFORE we hide the popup
        // (popup is non-activating → frontmost is still the target app).
        recordPasteDestination(for: item.id)
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()

        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb)
        lastChangeCount = pb.changeCount

        isSimulatingPaste = true
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.isSimulatingPaste = false
            self?.selectedIndex    = 0
            self?.selectionArmed   = true
            self?.previewVisible   = false
            self?.cycleCount       = 0
        }
        AuthManager.shared.registerCommandVAction()
    }

    // MARK: - Pasteboard write
    //
    // Every content type produces exactly ONE NSPasteboardItem with all
    // representations on that single item.  Mixing the old-style API
    // (setData/setString/setPropertyList after clearContents without
    // declareTypes) with writeObjects creates multiple implicit items on the
    // pasteboard; apps that iterate all items then paste each one, which is
    // why everything except plain text was pasting twice.

    private func write(_ item: ClipboardItem, to pb: NSPasteboard) {
        switch item.content {
        case .text(let str):
            let pitem = NSPasteboardItem()
            pitem.setString(str, forType: .string)
            pb.writeObjects([pitem])

        case .image(let img, let rawData, let dataType):
            let pitem = NSPasteboardItem()
            pitem.setData(rawData, forType: dataType)
            if let compat = ImageService.compatibilityPasteboardPayload(
                image: img, rawData: rawData, dataType: dataType
            ), compat.type != dataType {
                pitem.setData(compat.data, forType: compat.type)
            }
            if ImageService.shouldAttachTiffFallback(for: dataType),
               let tiff = img.tiffRepresentation {
                pitem.setData(tiff, forType: .tiff)
            }
            pb.writeObjects([pitem])

        case .richText(let attrStr, let plain):
            let pitem = NSPasteboardItem()
            let range = NSRange(location: 0, length: attrStr.length)
            if let rtfData = try? attrStr.data(from: range,
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pitem.setData(rtfData, forType: .rtf)
            }
            pitem.setString(plain, forType: .string)
            pb.writeObjects([pitem])

        case .html(let html, let plain):
            let pitem = NSPasteboardItem()
            pitem.setData(Data(html.utf8), forType: .init("public.html"))
            pitem.setString(plain, forType: .string)
            pb.writeObjects([pitem])

        case .file(let url):
            pb.writeObjects([makeFilePasteboardItem(for: url)])

        case .files(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }
            pb.writeObjects(existing.map { makeFilePasteboardItem(for: $0) })
        }
    }

    /// Build a single NSPasteboardItem for a file URL with every representation
    /// on that one item — Finder-standard file URL, legacy path list, typed raw
    /// data (so PDF viewers, image editors etc. get native format), and extracted
    /// plain text (so text editors receive readable content for text/document files).
    private func makeFilePasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()

        // Standard file-URL type — how Finder, Mail, Dock etc. reference files.
        item.setData(url.dataRepresentation, forType: .fileURL)
        // Legacy path list for older apps.
        item.setPropertyList([url.path], forType: .init("NSFilenamesPboardType"))

        let maxInlineBytes = 50 * 1024 * 1024
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey]),
              values.isDirectory != true,
              let fileSize = values.fileSize, fileSize <= maxInlineBytes,
              let data = try? Data(contentsOf: url) else { return item }

        // Typed raw data so specialised apps (Preview, image editors, etc.) get
        // their native format instead of just a file reference.
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            item.setData(data, forType: .init("com.adobe.pdf"))
            item.setData(data, forType: .init("public.pdf"))
        case "png":
            item.setData(data, forType: .init("public.png"))
        case "jpg", "jpeg":
            item.setData(data, forType: .init("public.jpeg"))
        case "gif":
            item.setData(data, forType: .init("public.gif"))
        case "tif", "tiff":
            item.setData(data, forType: .tiff)
        case "heic":
            item.setData(data, forType: .init("public.heic"))
        default:
            if let contentType = values.contentType {
                item.setData(data, forType: .init(contentType.identifier))
            }
        }

        // Plain-text representation for apps that accept text (editors, terminals).
        if let text = FileKindDetector.readableText(from: url, maxBytes: maxInlineBytes) {
            item.setString(text, forType: .string)
        } else if let docText = FileKindDetector.readableDocumentText(from: url) {
            item.setString(docText, forType: .string)
        }

        return item
    }

    func pasteItem(at itemsIndex: Int) {
        guard items.indices.contains(itemsIndex) else { return }
        selectedIndex = isReversed ? (items.count - 1 - itemsIndex) : itemsIndex
        selectionArmed = true
        commitPaste()
    }

    // MARK: - UI-driven navigation (mouse scroll & click in preview panels)

    func uiSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        selectionArmed = true
        syncItemPreviewWithSelection()
    }

    func uiScrollNext() {
        guard previewWindow.isVisible, !displayItems.isEmpty else { return }
        if inTransformStage { exitTransformStage() }
        selectedIndex = (selectedIndex + 1) % displayItems.count
        selectionArmed = true
        syncItemPreviewWithSelection()
    }

    func uiScrollPrev() {
        guard previewWindow.isVisible, !displayItems.isEmpty else { return }
        if inTransformStage { exitTransformStage() }
        let n = displayItems.count
        selectedIndex = (selectedIndex - 1 + n) % n
        selectionArmed = true
        syncItemPreviewWithSelection()
    }

    func uiScrollTransformNext() {
        guard inTransformStage else { return }
        cycleTransform()
    }

    func uiScrollTransformPrev() {
        guard inTransformStage else { return }
        cycleTransformBackward()
    }

    func uiSelectTransform(at index: Int) {
        guard inTransformStage, transformDisplaysCache.indices.contains(index) else { return }
        transformIndex = index
        updateTransformPanel()
    }

    func uiApplyTransform(at index: Int) {
        guard inTransformStage, transformDisplaysCache.indices.contains(index) else { return }
        transformIndex = index
        updateTransformPanel()
        commitPaste()
    }

    // MARK: - Hybrid search (lexical + semantic + recency)

    // Cache key uses (query, items.count, embeddedItemCount).  The embedded
    // count is maintained as a tracked counter — incremented when an embedding
    // is written, reset on full re-load — so the cache check is O(1) instead
    // of an O(N) walk over items on every keystroke.
    private var lastSearchQuery: String?
    private var lastSearchResult: [ClipboardItem] = []
    private var lastSearchItemsRev: Int = -1
    private var lastSearchEmbedRev: Int = -1
    private var embeddedItemCount: Int = 0

    /// Production search: blends LEXICAL (exact-phrase + per-token), SEMANTIC
    /// (sentence-embedding cosine), and RECENCY into a single combined score.
    /// Per-keystroke cost is O(N · |tokens|) of string `.contains` checks on
    /// PRE-NORMALISED haystacks already stored on each ClipboardItem — no
    /// filesystem I/O, no per-item allocation.
    func hybridSearch(query: String) -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count >= 2 else { return [] }

        // O(1) cache check — no item walk before the cache hit.
        if q == lastSearchQuery
            && items.count == lastSearchItemsRev
            && embeddedItemCount == lastSearchEmbedRev {
            return lastSearchResult
        }

        let qNorm = ClipboardItem.normalize(q)
        // Token extraction: split on non-alphanumerics, drop tokens < 2 chars,
        // dedupe via Set.  Cheap: O(|q|).
        let qTokenSet = Set(
            qNorm.components(separatedBy: CharacterSet.alphanumerics.inverted)
                 .filter { $0.count >= 2 }
        )
        let qTokens = Array(qTokenSet)
        let firstToken = qTokens.first  // any element is fine for the word-boundary bonus

        // Query embedding — one ANE round-trip per query, NOT per item.
        var queryVec: [Float]? = nil
        if AuthManager.shared.semanticSearch,
           let emb = nlEmbedding,
           let v = emb.vector(for: qNorm) {
            queryVec = v.map { Float($0) }
        }

        let now = Date()
        var scored: [(ClipboardItem, Float)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            let lex = Self.lexicalScore(query: qNorm, tokens: qTokens, firstToken: firstToken, item: item)
            let sem = Self.semanticComponent(queryVec: queryVec, item: item, cosine: cosineSimilarity)
            let rec = Self.recencyBoost(item: item, now: now)

            let combined = 0.55 * lex + 0.40 * sem + rec
            if combined >= 0.15 {
                scored.append((item, combined))
            }
        }

        let sorted = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        lastSearchQuery = q
        lastSearchResult = sorted
        lastSearchItemsRev = items.count
        lastSearchEmbedRev = embeddedItemCount
        return sorted
    }

    /// Back-compat alias for older call sites — same return semantics.
    func semanticSearch(query: String) -> [ClipboardItem] { hybridSearch(query: query) }

    // MARK: Scoring helpers (pure functions — read pre-cached haystacks)

    /// LEXICAL score in [0, 1]. Reads PRE-NORMALISED haystacks off the item
    /// (no allocation, no I/O).  Three weighted fields:
    ///   • searchPreviewNorm  — what the row shows (weight 1.00)
    ///   • searchEmbedNorm    — full searchable text (weight 0.70)
    ///   • searchMetaNorm     — type / size / dims (weight 0.55)
    /// We take MAX across fields (not sum) so a match isn't triple-counted.
    private static func lexicalScore(query: String,
                                     tokens: [String],
                                     firstToken: String?,
                                     item: ClipboardItem) -> Float {
        // Inline tuple iteration to avoid Array allocation per call.
        var best: Float = 0
        best = max(best, score(text: item.searchPreviewNorm, query: query, tokens: tokens, firstToken: firstToken) * 1.00)
        best = max(best, score(text: item.searchEmbedNorm,   query: query, tokens: tokens, firstToken: firstToken) * 0.70)
        best = max(best, score(text: item.searchMetaNorm,    query: query, tokens: tokens, firstToken: firstToken) * 0.55)
        return best
    }

    @inline(__always)
    private static func score(text: String, query: String, tokens: [String], firstToken: String?) -> Float {
        guard !text.isEmpty else { return 0 }
        // Tier 1: exact phrase
        if !query.isEmpty && text.contains(query) { return 1.0 }
        guard !tokens.isEmpty else { return 0 }
        // Tier 2: token-coverage fraction
        var hits = 0
        for t in tokens where text.contains(t) { hits += 1 }
        var s = Float(hits) / Float(tokens.count)
        // Tier 2b: word-boundary bonus
        if s > 0, let first = firstToken,
           text.hasPrefix(first) || text.contains(" " + first) {
            s = min(1.0, s + 0.15)
        }
        return s
    }

    /// SEMANTIC score in [0, 1]. Cosine similarity normalised so 0.3 → 0
    /// and 0.8 → 1.0 (below 0.3 is noise; above 0.8 is essentially identical
    /// meaning). Returns 0 when either side has no embedding.
    private static func semanticComponent(queryVec: [Float]?,
                                          item: ClipboardItem,
                                          cosine: ([Float], [Float]) -> Float) -> Float {
        guard let qv = queryVec, let iv = item.embedding else { return 0 }
        let cos = cosine(qv, iv)
        return max(0, min(1, (cos - 0.3) / 0.5))
    }

    /// RECENCY boost in [0, 0.08]. Linear decay over 14 days. Small enough
    /// that it only tiebreaks — never elevates an irrelevant item to the top.
    private static func recencyBoost(item: ClipboardItem, now: Date) -> Float {
        let ageHours = Float(now.timeIntervalSince(item.timestamp) / 3600)
        let twoWeeks: Float = 24 * 14
        return max(0, 0.08 * (1 - min(ageHours / twoWeeks, 1)))
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        // Accelerate (vDSP) routes to SIMD/AMX on Apple Silicon. ~5–10×
        // faster than the previous zip-map-reduce chain and zero
        // intermediate allocations — important because this runs per
        // (item × keystroke) during semantic search.
        let n = vDSP_Length(a.count)
        var dot:  Float = 0
        var sqA:  Float = 0
        var sqB:  Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, n)
                vDSP_svesq(ap.baseAddress!, 1, &sqA, n)
                vDSP_svesq(bp.baseAddress!, 1, &sqB, n)
            }
        }
        guard sqA > 0, sqB > 0 else { return 0 }
        return dot / (sqrt(sqA) * sqrt(sqB))
    }

    func togglePin(id: UUID) {
        guard AuthManager.shared.pinEnabled else {
            flashStatus("Pinning is disabled for this build.")
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isPinned.toggle()
    }
    func moveToFront(at index: Int) { guard items.indices.contains(index) else { return }; let item = items.remove(at: index); items.insert(item, at: 0); selectedIndex = 0 }
    func removeItem(at index: Int) { guard items.indices.contains(index) else { return }; items.remove(at: index); if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) } }
    func clearAll() { items.removeAll(); selectedIndex = 0 }

    /// Called by AuthManager whenever the backend tells us the user's
    /// ring cap. For Free users we always honor the exact backend value.
    /// For Pro users (ringLimit > FREE_RING_LIMIT) we let the user pick
    /// their preferred size up to the cap.
    ///
    /// FREE_RING_LIMIT is the dividing line between "free → fixed" and
    /// "pro → user-adjustable"; keep it in sync with features.py's
    /// FREE["ring_limit"]. If a future server bumps Free above this number
    /// the Free user will simply see the new bigger fixed cap — no bug.
    private static let FREE_RING_LIMIT = 10

    func applyPlanLimits(ringLimit: Int) {
        let target: Int
        if ringLimit <= Self.FREE_RING_LIMIT {
            // Free plan — exact server cap, no user preference applied.
            target = ringLimit
        } else {
            // Pro plan — user picks within the server cap; default to a sane
            // mid-range so first-time Pro users don't see a tiny ring.
            let preferred = UserDefaults.standard.object(forKey: "preferredRingSize") as? Int
            target = max(1, preferred.map { min($0, ringLimit) } ?? 20)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.maxItems != target else { return }
            self.maxItems = target
        }
    }

    // (No cloud sync in this build — it's a local-only clipboard manager.
    //  All "merge cloud items" helpers were removed during cleanup.)

    /// Merge a list of items into the local ring, dedup by UUID, respect maxItems.
    /// Currently unused (cloud sync removed) but kept private as a building block
    /// in case sync is re-introduced.
    private func mergeCloudItems(_ cloudItems: [ClipboardItem]) {
        let existingIDs = Set(items.map { $0.id })
        let newItems = cloudItems.filter { !existingIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }

        items.append(contentsOf: newItems)
        // Re-sort: pinned first, then newest-first among unpinned
        let pinned   = items.filter { $0.isPinned }
        var unpinned = items.filter { !$0.isPinned }
            .sorted { $0.timestamp > $1.timestamp }
        // Trim unpinned to ring limit
        if unpinned.count > maxItems { unpinned = Array(unpinned.prefix(maxItems)) }
        items = pinned + unpinned
        selectedIndex = 0
    }

    // Reorder displayed items (called from drag-to-reorder in UI)
    func moveDisplayItems(from source: IndexSet, to destination: Int) {
        var display = displayItems
        display.move(fromOffsets: source, toOffset: destination)
        let ordered = display.map { $0.id }
        items = ordered.compactMap { id in items.first(where: { $0.id == id }) }
    }

    // Public wrapper so TransformPanel can add items (e.g. PDF pages as images)
    func addItemPublic(_ item: ClipboardItem) { addItem(item) }

    // Show transform panel for any item (e.g. from menu bar tap)
    func showTransformPanelForItem(_ item: ClipboardItem) {
        transformPanel.show(
            for: item,
            near: previewWindow.frame,
            anchorPoint: NSPoint(x: previewWindow.frame.maxX, y: previewWindow.frame.midY),
            selectedTransformIndex: 0
        )
    }

    // MARK: - Diff badge

    private func computeDiffBadge(newText: String, against existing: [ClipboardItem]) -> String? {
        let newLines = newText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard newLines.count >= 2 else { return nil }   // single-line: skip
        let newSet = Set(newLines)

        for (i, item) in existing.prefix(10).enumerated() {
            guard let existText = item.textForEmbedding else { continue }
            let existLines = existText.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard existLines.count >= 2 else { continue }
            let existSet = Set(existLines)

            let shared = newSet.intersection(existSet).count
            let total  = newSet.union(existSet).count
            guard total > 0 else { continue }
            let similarity = Double(shared) / Double(total)
            guard similarity >= 0.4 && similarity < 1.0 else { continue }

            let added   = newSet.subtracting(existSet).count
            let removed = existSet.subtracting(newSet).count
            guard added + removed > 0 else { continue }

            var parts: [String] = []
            if added   > 0 { parts.append("+\(added)") }
            if removed > 0 { parts.append("-\(removed)") }
            return parts.joined(separator: " ") + " from #\(i + 2)"
        }
        return nil
    }

    // MARK: - Persistence

    private struct PersistedItem: Codable {
        let id:        UUID
        let timestamp: Date
        let isPinned:  Bool
        let urlTitle:  String?
        let type:      String   // "text" | "image" | "richText" | "file"
        let text:      String?
        let imageData: Data?         // legacy inline path (kept for old files)
        let imageBlob: String?       // NEW: relative path under blobs/ when split out
        let imageType: String?
        let rtfData:   Data?
        let plainText: String?
        let filePath:  String?
        let filePaths: [String]?
        let html:      String?
        let sourceAppName: String?
        let sourceBundleID: String?
        // Persisted on-device sentence embedding so semantic search is hot
        // the moment the app finishes launching — no 1-3s warm-up while
        // recomputeEmbeddingsInBackground catches up.  ~2 KB per item × 200
        // items = ~400 KB extra in the manifest, well worth it.
        let embedding: [Float]?
        /// Optional for backward compat — older manifests (pre-v1.0.43) don't
        /// have this field and decode as nil, which loads as `false`.
        let isSecret:  Bool?
        /// Where the item was most recently pasted.  Optional — old manifests
        /// (pre-v1.0.47) won't have these fields and decode as nil.
        let pastedToAppName:  String?
        let pastedToBundleID: String?
        let lastPastedAt:     Date?
        /// Frequency signals for the predictor.  Optional for backward compat
        /// — manifests written before the predictor landed decode as nil → 0 / [:].
        let pasteCount:        Int?
        let pasteCountByApp:   [String: Int]?
        /// All destination app names ever recorded for this item.  Optional —
        /// old manifests decode as nil, synthesised from pastedToAppName below.
        let pastedToAppNames:  [String: String]?
    }

    /// `Application Support/Clipen`.  `lazy` so the directory-create call runs
    /// exactly once per process — every other access is a stored-URL read.
    private lazy var historyDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Encrypted-at-rest history. `.clip` extension instead of `.json` so
    /// nobody mistakes the contents for a readable file.
    private var historyFileURL: URL {
        historyDir.appendingPathComponent("history.clip")
    }

    /// Path to the v1 plaintext history file. Read once on first launch
    /// after upgrade, re-encrypt, and delete.
    private var legacyPlaintextHistoryURL: URL {
        historyDir.appendingPathComponent("history.json")
    }

    /// Root directory for per-item binary blobs (image data, large rtf etc.),
    /// sharded by primary tag so the directory tree doubles as a sanity
    /// check when inspecting Application Support.  Each blob is its OWN
    /// AES-GCM encrypted file — the manifest only stores a relative path,
    /// not the bytes.  Goal: history.clip stays small (manifest only) so
    /// the 1-second debounced rewrite is cheap regardless of ring size or
    /// image dimensions.  No 8 MB image cap needed when bytes don't live
    /// in the manifest.
    private var blobsDir: URL {
        historyDir.appendingPathComponent("blobs", isDirectory: true)
    }

    /// Write encrypted `data` to a new blob under `blobs/<tagDir>/<uuid>.bin`
    /// and return the relative path ("image/abcd-1234.bin") for storage in
    /// the manifest.  Returns nil on failure — caller falls back to inline.
    private func writeBlob(_ data: Data, primaryTag: ClipboardTag) -> String? {
        let tagDir = blobsDir.appendingPathComponent(primaryTag.folderName,
                                                     isDirectory: true)
        try? FileManager.default.createDirectory(at: tagDir, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        let fileURL = tagDir.appendingPathComponent("\(id).bin")
        guard let cipher = HistoryCrypto.encrypt(data) else { return nil }
        do {
            try cipher.write(to: fileURL, options: [.atomic, .completeFileProtection])
            return "\(primaryTag.folderName)/\(id).bin"
        } catch {
            return nil
        }
    }

    /// Inverse of `writeBlob`.  Loads `blobs/<relative>`, AES-decrypts, returns
    /// plaintext bytes or nil if the file is missing / corrupt / re-keyed.
    private func readBlob(_ relativePath: String) -> Data? {
        let fileURL = blobsDir.appendingPathComponent(relativePath)
        guard let cipher = try? Data(contentsOf: fileURL),
              let plain  = HistoryCrypto.decrypt(cipher) else { return nil }
        return plain
    }

    /// Delete any blob files in `blobsDir` that are no longer referenced by
    /// the current `items` ring.  Called after every save so the directory
    /// can't accumulate orphans as the ring evicts old captures.
    private func purgeOrphanBlobs(referenced: Set<String>) {
        guard let enumerator = FileManager.default.enumerator(
            at: blobsDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in enumerator {
            guard let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile,
                  isFile else { continue }
            // Build the same "<tagDir>/<file>.bin" relative path that
            // writeBlob returns so the comparison key is consistent.
            let parent = url.deletingLastPathComponent().lastPathComponent
            let name   = url.lastPathComponent
            let rel    = "\(parent)/\(name)"
            if !referenced.contains(rel) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private func saveHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        // Track which blob paths the new manifest references; everything
        // ELSE in blobsDir gets purged at the end of this call so evicted
        // items can't leak bytes on disk forever.
        var referencedBlobs: Set<String> = []

        let persisted: [PersistedItem] = items.compactMap { item in
            switch item.content {
            case .text(let str):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "text", text: str,
                                     imageData: nil, imageBlob: nil, imageType: nil, rtfData: nil,
                                     plainText: nil, filePath: nil, filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            case .image(_, let rawData, let dataType):
                // Image bytes never go in the manifest anymore — written to
                // an encrypted blob under blobs/image/<uuid>.bin.  Manifest
                // only carries the relative path.  No size cap.  Falls back
                // to inline if blob write fails (disk full, sandbox, etc.)
                // so a write hiccup never silently drops the capture.
                let primary = item.primaryTag
                if let rel = writeBlob(rawData, primaryTag: primary) {
                    referencedBlobs.insert(rel)
                    return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                         urlTitle: nil, type: "image", text: nil,
                                         imageData: nil, imageBlob: rel, imageType: dataType.rawValue,
                                         rtfData: nil, plainText: nil, filePath: nil, filePaths: nil, html: nil,
                                         sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                         embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
                }
                // Inline fallback — keep old 8 MB cap so a giant screenshot
                // can't blow up the manifest if the blob layer failed.
                guard rawData.count < 8_000_000 else { return nil }
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "image", text: nil,
                                     imageData: rawData, imageBlob: nil, imageType: dataType.rawValue,
                                     rtfData: nil, plainText: nil, filePath: nil, filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            case .richText(let attrStr, let plain):
                let range = NSRange(location: 0, length: attrStr.length)
                let rtf = try? attrStr.data(from: range,
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "richText", text: nil,
                                     imageData: nil, imageBlob: nil, imageType: nil,
                                     rtfData: rtf, plainText: plain, filePath: nil,
                                     filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            case .html(let html, let plain):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "html", text: nil,
                                     imageData: nil, imageBlob: nil, imageType: nil, rtfData: nil,
                                     plainText: plain, filePath: nil, filePaths: nil, html: html,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            case .file(let url):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "file", text: nil,
                                     imageData: nil, imageBlob: nil, imageType: nil, rtfData: nil,
                                     plainText: nil, filePath: url.path, filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            case .files(let urls):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "files", text: nil,
                                     imageData: nil, imageBlob: nil, imageType: nil, rtfData: nil,
                                     plainText: nil, filePath: nil, filePaths: urls.map(\.path), html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID,
                                     embedding: item.embedding, isSecret: item.isSecret,
                                     pastedToAppName: item.pastedToAppName,
                                     pastedToBundleID: item.pastedToBundleID,
                                     lastPastedAt: item.lastPastedAt,
                                     pasteCount: item.pasteCount,
                                     pasteCountByApp: item.pasteCountByApp,
                                     pastedToAppNames: item.pastedToAppNames)
            }
        }
        guard let plain = try? enc.encode(persisted),
              let cipher = HistoryCrypto.encrypt(plain) else { return }
        try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
        // Drop blob files no longer referenced by the manifest.  Runs after
        // the manifest is on disk so a crash in the middle can never leave
        // the manifest pointing at a deleted blob.
        purgeOrphanBlobs(referenced: referencedBlobs)
    }

    private func loadHistory() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601

        // Prefer the encrypted file. If it's missing but a legacy plaintext
        // history exists, migrate it once: re-encrypt under the user's key,
        // then delete the plaintext copy so the secrets-on-disk window closes
        // on the first launch after upgrade.
        let plaintext: Data? = {
            if let cipher = try? Data(contentsOf: historyFileURL),
               let plain  = HistoryCrypto.decrypt(cipher) {
                return plain
            }
            if let legacy = try? Data(contentsOf: legacyPlaintextHistoryURL) {
                if let cipher = HistoryCrypto.encrypt(legacy) {
                    try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
                }
                try? FileManager.default.removeItem(at: legacyPlaintextHistoryURL)
                return legacy
            }
            return nil
        }()

        guard let data      = plaintext,
              let persisted = try? dec.decode([PersistedItem].self, from: data) else { return }
        let allLoaded = persisted.compactMap { p -> ClipboardItem? in
            let content: ClipboardContent
            switch p.type {
            case "text":
                guard let str = p.text else { return nil }
                content = .text(str)
            case "image":
                // New format: imageBlob → read from blobs/<tag>/<uuid>.bin.
                // Legacy format: imageData inline in the manifest.  Drop the
                // item silently if neither resolves (file deleted, corrupt).
                let raw: Data? = {
                    if let rel = p.imageBlob, let d = readBlob(rel) { return d }
                    return p.imageData
                }()
                guard let raw, let img = NSImage(data: raw) else { return nil }
                content = .image(img, rawData: raw, dataType: .init(p.imageType ?? "public.png"))
            case "richText":
                guard let rtf = p.rtfData,
                      let attrStr = NSAttributedString(rtf: rtf, documentAttributes: nil) else { return nil }
                content = .richText(attrStr, plain: p.plainText ?? attrStr.string)
            case "html":
                guard let html = p.html else { return nil }
                content = .html(html, plain: p.plainText ?? "")
            case "file":
                guard let path = p.filePath else { return nil }
                content = .file(URL(fileURLWithPath: path))
            case "files":
                guard let paths = p.filePaths, !paths.isEmpty else { return nil }
                content = .files(paths.map { URL(fileURLWithPath: $0) })
            default:
                return nil
            }
            var item = ClipboardItem(content: content, id: p.id, timestamp: p.timestamp,
                                     urlTitle: p.urlTitle, sourceAppName: p.sourceAppName)
            item.isPinned = p.isPinned
            item.sourceBundleID = p.sourceBundleID
            item.isSecret = p.isSecret ?? false
            item.pastedToAppName  = p.pastedToAppName
            item.pastedToBundleID = p.pastedToBundleID
            item.lastPastedAt     = p.lastPastedAt
            item.pasteCount       = p.pasteCount ?? 0
            item.pasteCountByApp  = p.pasteCountByApp ?? [:]
            // Restore the full set of destination-app names.  For items
            // written by earlier builds (pre-1.0.49) we synthesise a single
            // entry from pastedToAppName + pastedToBundleID so the badges
            // are still populated on first launch after upgrade.
            if let names = p.pastedToAppNames, !names.isEmpty {
                item.pastedToAppNames = names
            } else if let bid = p.pastedToBundleID, let name = p.pastedToAppName {
                item.pastedToAppNames = [bid: name]
            }
            // Restore persisted embedding so semantic search is HOT from
            // launch — no 1-3 second warm-up while recomputeEmbeddingsIn
            // Background fills them in one by one.
            item.embedding = p.embedding
            return item
        }
        // Respect plan limit: keep all pinned + up to maxItems unpinned
        let pinned   = allLoaded.filter { $0.isPinned }
        let unpinned = Array(allLoaded.filter { !$0.isPinned }.prefix(maxItems))
        items = pinned + unpinned
        // Loaded items have no embeddings yet (recomputeEmbeddingsInBackground
        // re-fills them); reset the counter so the search cache invalidates
        // correctly as those fills land.
        embeddedItemCount = items.reduce(0) { $1.embedding == nil ? $0 : $0 + 1 }
    }
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
    /// Detected as a likely secret (API key, token, password-shaped substring).
    /// Captured anyway — the on-disk history is AES-GCM encrypted — but the
    /// row renders a red lock badge so the user sees it's flagged.
    var isSecret: Bool = false

    /// App the item was most recently pasted *into* (destination).  Recorded
    /// in commitPaste / finishTransformPaste / commitSearchPaste at the moment
    /// the synthetic ⌘V fires, so it always reflects the actual receiving app.
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
    init(content: ClipboardContent, id: UUID = UUID(), timestamp: Date = Date(),
         urlTitle: String? = nil, sourceAppName: String? = nil) {
        self.id        = id
        self.timestamp = timestamp
        self.content   = content
        self.urlTitle      = urlTitle
        self.sourceAppName = sourceAppName
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
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().applyingTransform(.stripDiacritics, reverse: false) ?? s.lowercased()
    }

    var previewText: String {
        switch content {
        case .text(let s):               return String(s.prefix(200))
        case .image:                     return "[Image]"
        case .richText(_, plain: let s): return String(s.prefix(200))
        case .html(_, plain: let s):     return String(s.prefix(200))
        case .file(let url):             return url.lastPathComponent
        case .files(let urls):           return "\(urls.count) files"
        }
    }

    var iconName: String {
        switch content {
        case .text:     return "doc.text"
        case .image:    return "photo"
        case .richText: return "doc.richtext"
        case .html:     return "globe"
        case .file:     return "doc"
        case .files:    return "doc.on.doc"
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
        case .file(let url):
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? "File" : ext
        case .files(let urls):
            return "\(urls.count) Files"
        }
    }

    var typeIcon: String {
        switch content {
        case .text:             return detectedType.sfIcon
        case .image:            return "photo"
        case .richText:         return "doc.richtext"
        case .html:             return "globe"
        case .file(let url):
            return Self.iconName(for: url)
        case .files:            return "doc.on.doc"
        }
    }

    /// Cached at init / rebuildSearchHaystacks.  Used by every row render.
    /// For file items this previously did ~3 FileManager syscalls per access.
    private(set) var metadataSummary: String?

    private static func computeMetadataSummary(for content: ClipboardContent) -> String? {
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

    private static func iconName(for url: URL) -> String {
        if FileKindDetector.isVideoFile(url) { return "film" }
        if FileKindDetector.isAudioFile(url) { return "music.note" }
        if FileKindDetector.isArchiveFile(url) { return "archivebox" }
        if FileKindDetector.isFontFile(url) { return "textformat" }
        if FileKindDetector.isDesignFile(url) { return "paintbrush" }
        if FileKindDetector.is3DFile(url) { return "cube" }
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

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private static func fileMetadataSummary(for url: URL) -> String? {
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

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
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

    /// Cached at init / rebuildSearchHaystacks.  Embedding generation + every
    /// hybrid-search call previously triggered this — for file items it meant
    /// FileManager syscalls per item per keystroke.  Now built once.
    private(set) var textForEmbedding: String?

    private static func computeTextForEmbedding(content: ClipboardContent,
                                                urlTitle: String?,
                                                sourceAppName: String?) -> String? {
        switch content {
        case .text(let s):               return s.isEmpty ? nil : s
        case .richText(_, plain: let s): return s.isEmpty ? nil : s
        case .html(_, plain: let s):     return s.isEmpty ? nil : s
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
        }
    }

    private static func fileMetadataEmbeddingText(for url: URL) -> String {
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

    var category: ClipboardCategory {
        ContentDetector.category(for: self)
    }

    func hasTag(_ tag: ClipboardTag) -> Bool {
        tags.contains(tag)
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

enum ClipboardContent {
    case text(String)
    case image(NSImage, rawData: Data, dataType: NSPasteboard.PasteboardType)
    case richText(NSAttributedString, plain: String)
    case html(String, plain: String)
    case file(URL)
    case files([URL])
}

// MARK: - Extensions

extension NSImage {
    func pngData() -> Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
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
