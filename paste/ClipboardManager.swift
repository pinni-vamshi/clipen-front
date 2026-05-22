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

/// Tiny ObservableObject that the popup's progress strip observes
/// directly. Keeping these two state vars off the main ClipboardManager
/// means a 50ms progress tick doesn't blow up the entire popup body —
/// only the 2pt-tall progress rectangle re-renders.
final class DismissTicker: ObservableObject {
    @Published var progress: Double = 1.0
    @Published var frozen:   Bool   = false
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
    /// When the popup is visible but the idle timer has fired, we clear the
    /// row highlight (`selectionArmed == false`) while keeping `selectedIndex`
    /// so the next ⌘V re-highlights the same row. Releasing ⌘ while disarmed
    /// dismisses without pasting.
    @Published var selectionArmed: Bool = true

    /// Optional tag filter. `nil` = Recents (everything). When set,
    /// `displayItems` is filtered to items that include that tag. Cleared
    /// on `dismissPreview` so each new ⌘V session starts at Recents.
    @Published var tagFilter: ClipboardTag? = nil {
        didSet {
            invalidateDisplayItems()
            // Reset selection — old index almost certainly points past the
            // shorter filtered list. Re-arm so the new top row is highlighted.
            selectedIndex = 0
            selectionArmed = true
            if previewWindow.isVisible {
                scheduleDismissTimer()
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
    /// Mirrors `AXIsProcessTrusted()`. Initialized synchronously so the
    /// onboarding screen doesn't flash on launch for users who already
    /// granted permission in a previous run. Refreshed by a 1Hz timer in
    /// `startAccessibilityWatcher()` so the UI auto-advances the moment
    /// the user flips the toggle in System Settings — even if our event
    /// tap creation races with TCC propagation.
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    private var accessibilityPollTimer: Timer?
    /// Dismiss countdown state lives on its own ObservableObject so the
    /// 50ms progress tick only re-renders the small progress strip, not
    /// the entire popup body. Previously this was @Published on the
    /// ClipboardManager itself — every tick fired `objectWillChange` on
    /// the manager, causing the full PopoverPreviewView (rows, chips,
    /// header) to re-evaluate 20× per second.
    let dismissTicker = DismissTicker()
    // Convenience pass-throughs for non-view code that still reads them.
    var dismissProgress: Double {
        get { dismissTicker.progress }
        set { dismissTicker.progress = newValue }
    }
    var timerFrozen: Bool {
        get { dismissTicker.frozen }
        set { dismissTicker.frozen = newValue }
    }
    // Internal counters — only set internally, never read by views.
    // Kept as plain stored properties so writes don't trigger SwiftUI
    // re-renders on every keypress.
    private var previewVisible: Bool = false
    private var cycleCount: Int = 0
    private var transformCycleCount: Int = 0

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

    /// Seconds of inactivity before the row highlight clears (`softDisarm`).
    /// The popup stays open; releasing ⌘ while disarmed dismisses without
    /// pasting. `0` disables auto-clear (highlight stays until Esc or ⌘ up).
    @Published var dismissTimeout: Double = UserDefaults.standard.object(forKey: "dismissTimeout") as? Double ?? 3.0 {
        didSet { UserDefaults.standard.set(dismissTimeout, forKey: "dismissTimeout") }
    }

    /// How long (in seconds) we wait after the user's first ⌘V tap of a
    /// session before actually opening the popup. If the user releases ⌘
    /// inside this window, we treat the tap as a normal "paste front item"
    /// and never show the popup — which makes a quick ⌘V feel identical to
    /// system paste. Hold ⌘ for longer than this and the popup opens, and
    /// the user enters cycling mode.
    ///
    /// Default 0.12 s (120 ms) — short enough that intentional cyclers don't
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
    /// When false (default), popup mode can start only while a text input is
    /// focused. This prevents accidental activation in non-typing contexts.
    /// When true, popup can start anywhere (legacy behavior).
    @Published var showPopupOutsideTextInputs: Bool = UserDefaults.standard.object(forKey: "showPopupOutsideTextInputs") as? Bool ?? false {
        didSet { UserDefaults.standard.set(showPopupOutsideTextInputs, forKey: "showPopupOutsideTextInputs") }
    }

    private var pollTimer: Timer?
    private var dismissTimer: Timer?
    private var progressTimer: Timer?
    private var dismissStartTime: Date?
    private var permissionRetryTimer: Timer?
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
    /// The user types in one spot per session, so we query AX once on first
    /// open and reuse the result for every subsequent cycle. Cleared on
    /// dismiss so the next session starts fresh.
    private var cachedCaretPosition: NSPoint?

    // Two-stage cycling: Stage 1 = items, Stage 2 = transforms for selected item
    private var inTransformStage = false
    private var transformIndex   = 0
    /// Snapshot transform ordering for the current stage so ⌘X cycles in a
    /// stable one-by-one sequence even if global usage rankings change.
    private var transformDisplaysCache: [TransformDisplay] = []

    private var saveCancellable: AnyCancellable?

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

        // 2. HTML (before RTF/plain text so web formatting survives)
        let htmlTypes: [NSPasteboard.PasteboardType] = [
            .init("public.html"),
            .init("Apple HTML pasteboard type")
        ]
        for type in htmlTypes {
            if let htmlData = pb.data(forType: type),
               let html = String(data: htmlData, encoding: .utf8),
               let plain = Self.plainText(fromHTML: htmlData),
               !plain.isEmpty {
                guard !shouldIgnoreSensitiveText(plain) else { return }
                addItem(ClipboardItem(content: .html(html, plain: plain)))
                return
            }
        }

        // 3. RTF (before plain text — RTF also exposes .string)
        if captureRichText,
           let rtfData = pb.data(forType: .rtf),
           let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil),
           !attrStr.string.isEmpty {
            guard !shouldIgnoreSensitiveText(attrStr.string) else { return }
            addItem(ClipboardItem(content: .richText(attrStr, plain: attrStr.string)))
            return
        }

        // 4. Plain text
        if let str = pb.string(forType: .string), !str.isEmpty {
            guard !shouldIgnoreSensitiveText(str) else { return }
            let item = ClipboardItem(content: .text(str))
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
        guard let attr = NSAttributedString(
            html: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) else { return nil }
        return attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldIgnoreSensitiveText(_ text: String) -> Bool {
        guard autoIgnoreSecrets, SecretDetector.isLikelySecret(text) else { return false }
        flashStatus("Secret ignored. Toggle this in Settings if you want to save it.")
        return true
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
                    if let idx = self.items.firstIndex(where: { $0.id == itemID }) {
                        self.items[idx].embedding = floats
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

        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.permissionRetryTimer?.invalidate()
                    self.permissionRetryTimer = nil
                    self.createEventTap()
                }
            }
            RunLoop.main.add(permissionRetryTimer!, forMode: .common)
        }
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

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
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
            if !hasCmd {
                // Release-while-pending cases:
                //  • pendingFirstOpen → fast-paste front item, no popup
                //  • popup visible + armed → commit paste
                //  • popup visible + idle (timer disarmed highlight) → hard
                //    dismiss, nothing pasted
                if pendingFirstOpen {
                    DispatchQueue.main.async { [weak self] in self?.fastPasteFront() }
                } else if itemPreviewPanel.isVisible {
                    DispatchQueue.main.async { [weak self] in self?.dismissPreview() }
                } else if previewWindow.isVisible {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if self.selectionArmed { self.commitPaste() }
                        else { self.dismissPreview() }
                    }
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let key   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let opt   = flags.contains(.maskAlternate)
        let ctrl  = flags.contains(.maskControl)

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

        // Tab / Shift-Tab while popup is visible: cycle category forward /
        // backward without requiring Command.
        if key == 48 && previewWindow.isVisible {
            DispatchQueue.main.async { [weak self] in
                if self?.inTransformStage == true { self?.exitTransformStage() }
                if shift { self?.cycleCategoryBackward() }
                else { self?.cycleCategoryForward() }
            }
            return nil
        }

        // Plain ⌘ allowed; ⌃ never.
        guard cmd && !ctrl else { return Unmanaged.passUnretained(event) }

        if key == 9 { // V — ⌘V cycle, ⌘⌥V jump+5
            if isSimulatingPaste { return Unmanaged.passUnretained(event) }
            // Do not hijack Cmd+Shift+V; many apps reserve it for
            // "paste and match style".
            guard !shift else { return Unmanaged.passUnretained(event) }
            // Optional strict mode: only activate popup flows while user is
            // actively focused in a text-editable element.
            if !previewWindow.isVisible,
               !pendingFirstOpen,
               !showPopupOutsideTextInputs,
               focusedTextInputPosition() == nil {
                return Unmanaged.passUnretained(event)
            }
            if displayItems.isEmpty && !previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }

            if opt {
                // ⌘+⌥V — jump 5 items forward (skip ahead through the ring).
                // Replaces the old "cycle one step back" binding — users
                // hit ⌥V to leapfrog, not to nudge backward.
                DispatchQueue.main.async { [weak self] in
                    if self?.inTransformStage == true { self?.exitTransformStage() }
                    self?.jumpForward(by: 5)
                }
            } else {
                // ⌘V — cycle forward
                DispatchQueue.main.async { [weak self] in
                    if self?.inTransformStage == true { self?.exitTransformStage() }
                    self?.cycleNext()
                }
            }
            return nil
        }

        // Other shortcuts require plain ⌘ — no shift, no opt.
        guard !shift && !opt else { return Unmanaged.passUnretained(event) }

        // ⌘1 … ⌘9 — jump straight to that row (1-indexed). Available
        // whenever the popup is visible OR a delayed-open is pending; in
        // the pending case we open the popup at the picked index without
        // waiting for the rest of the delay.
        if let target = Self.numberRowKeycodeToIndex[key],
           previewWindow.isVisible || pendingFirstOpen {
            DispatchQueue.main.async { [weak self] in
                if self?.inTransformStage == true { self?.exitTransformStage() }
                self?.selectByNumber(target)
            }
            return nil
        }

        if key == 7 && previewWindow.isVisible { // X — enter transform, then cycle
            // Ignore key-repeat while holding X — one step per physical press.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionArmed else { return }
                if self.inTransformStage {
                    self.cycleTransform()
                } else {
                    self.enterTransformStage()
                }
            }
            return nil
        }

        if key == 51 && previewWindow.isVisible { // ⌫ — delete highlighted item
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionArmed else { return }
                self.deleteSelected()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Two-stage transform

    private func enterTransformStage() {
        guard selectionArmed, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        // Free plan — transforms locked
        guard AuthManager.shared.transformsEnabled else {
            transformPanel.showUpgradePrompt(near: previewWindow.frame)
            return
        }
        inTransformStage = true
        refreshTransformDisplaysCache()
        guard !transformDisplaysCache.isEmpty else {
            inTransformStage = false
            return
        }
        transformIndex   = 0
        transformStageActive = true
        // Freeze dismiss timer while inspecting transforms
        dismissTimer?.invalidate(); dismissTimer = nil
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        timerFrozen = true
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
        scheduleDismissTimer()
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
            scheduleDismissTimer()
        } else {
            showSelectedItemPreview()
        }
    }

    private func showSelectedItemPreview() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        itemPreviewPanel.show(for: displayItems[selectedIndex], near: previewWindow.frame)
        dismissTimer?.invalidate(); dismissTimer = nil
        progressTimer?.invalidate(); progressTimer = nil
        timerFrozen = true
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
            writeFileURLs([ImageService.exportFileURL(fileName: fileName)], to: pb)
        }

        write(item, to: pb)
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
        writeFileURLs(urls, to: pb)
        lastChangeCount = pb.changeCount
        finishTransformPaste(message: message, restoring: source)
    }

    /// Paste transform output into the frontmost app, then put the original
    /// source item back on the pasteboard. Transformed output is never added
    /// to the Clipen ring.
    private func finishTransformPaste(message: String?, restoring source: ClipboardItem?) {
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        dismissTimer?.invalidate(); dismissTimer = nil
        progressTimer?.invalidate(); progressTimer = nil
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

        let isFirstOpen = !previewWindow.isVisible

        if isFirstOpen {
            if pendingFirstOpen {
                // Second ⌘V tap arrived inside the delay window → user
                // clearly wants the popup. Cancel the pending timer, open
                // immediately, and advance to row 1 (matching the count of
                // V taps so far).
                cancelPendingFirstOpen()
                selectedIndex = min(1, display.count - 1)
                openPopupNow()
            } else if firstOpenDelay > 0 {
                // First-ever V tap of this ⌘-hold session. Defer opening
                // the popup by `firstOpenDelay` so a fast tap-and-release
                // behaves like normal system paste (handled in handleEvent
                // when ⌘ goes up).
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
                // Delay disabled — preserve the old instant-open behavior.
                selectedIndex = 0
                openPopupNow()
            }
        } else {
            // Popup already open: first ⌘V after an idle disarm only
            // re-highlights the same row; the next ⌘V advances.
            if !selectionArmed {
                clampSelectedIndexToDisplay()
                selectionArmed = true
                previewVisible = true
                cycleCount += 1
                scheduleDismissTimer()
                return
            }
            selectedIndex = (selectedIndex + 1) % display.count
        }

        previewVisible = true
        cycleCount += 1

        // One-time hint: first ever cycle → flash "Tap ⌘X to transform"
        if !UserDefaults.standard.bool(forKey: "seenTransformHint") {
            UserDefaults.standard.set(true, forKey: "seenTransformHint")
            showFirstCycleHint = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                self?.showFirstCycleHint = false
            }
        }

        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }

        scheduleDismissTimer()
    }

    /// Top-row number keycodes (kVK_ANSI_1 … kVK_ANSI_9) mapped to the
    /// zero-based ring index they should select. ⌘0 is intentionally NOT
    /// in the map — most users read "0" as "tenth" which would silently
    /// off-by-one, and ⌘0 is already a system-reserved shortcut in many
    /// apps (zoom-to-fit etc.). For 10+ items the user falls back to ⌘V
    /// or ⌘⌥V to walk past row 9.
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

    /// Pick the row at `idx` directly (⌘1 → row 0, ⌘2 → row 1, …). If the
    /// popup is in the pre-open delay window, cancel the delay and open at
    /// the picked index. If the index is past the end of the ring, bail
    /// silently — pressing ⌘7 with only 3 items shouldn't surprise-jump.
    private func selectByNumber(_ idx: Int) {
        let display = displayItems
        guard !display.isEmpty, idx < display.count else { return }

        let wasFirstOpen = !previewWindow.isVisible
        cancelPendingFirstOpen()
        selectedIndex = idx
        if wasFirstOpen { openPopupNow() } else { selectionArmed = true }
        previewVisible = true
        cycleCount += 1
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        scheduleDismissTimer()
    }

    /// Cycle forward through the category filter: Recents → first category
    /// (alphabetical) → … → last → Recents. Bound to Tab while the popup is
    /// visible.
    private func cycleCategoryForward() {
        let tags: [ClipboardTag?] = [nil] + availableTags
        guard tags.count > 1 else { return }

        let isFirstOpen = !previewWindow.isVisible
        if isFirstOpen {
            cancelPendingFirstOpen()
            openPopupNow()
        }

        let currentIdx = tags.firstIndex(of: tagFilter) ?? 0
        let nextIdx    = (currentIdx + 1) % tags.count
        tagFilter = tags[nextIdx]

        previewVisible = true
        cycleCount += 1
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        scheduleDismissTimer()
    }

    /// Cycle backward through the category filter. Bound to Shift-Tab while
    /// the popup is visible.
    private func cycleCategoryBackward() {
        let tags: [ClipboardTag?] = [nil] + availableTags
        guard tags.count > 1 else { return }

        let isFirstOpen = !previewWindow.isVisible
        if isFirstOpen {
            cancelPendingFirstOpen()
            openPopupNow()
        }

        let currentIdx = tags.firstIndex(of: tagFilter) ?? 0
        let prevIdx    = (currentIdx - 1 + tags.count) % tags.count
        tagFilter = tags[prevIdx]

        previewVisible = true
        cycleCount += 1
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        scheduleDismissTimer()
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
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        scheduleDismissTimer()
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
        scheduleDismissTimer()
    }

    /// Centralised "open the panel near the caret" — used by cycleNext (no
    /// delay path), jumpForward, and openPopoverAfterDelay. Keeps the fresh
    /// AX query + cache write in one place so all three paths stay in sync.
    private func openPopupNow() {
        selectionArmed = true
        // Prefer true text-focus caret anchoring when available.
        let position = focusedTextInputPosition() ?? caretPosition()
        cachedCaretPosition = position
        previewWindow.show(at: position)
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
        cancelPendingFirstOpen()
        guard !displayItems.isEmpty else { return }
        selectedIndex = 0
        inTransformStage = false
        transformIndex = 0
        commitPaste()
    }

    private func deleteSelected() {
        guard selectionArmed, !items.isEmpty else { return }
        let realIndex = isReversed ? (items.count - 1 - selectedIndex) : selectedIndex
        guard items.indices.contains(realIndex) else { return }
        items.remove(at: realIndex)
        if items.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        // @ObservedObject re-render handles the popup refresh. No AX query,
        // no setFrame, no view-tree rebuild — just bump the @Published vars.
        scheduleDismissTimer()
    }

    private func scheduleDismissTimer() {
        if itemPreviewPanel.isVisible {
            timerFrozen = true
            dismissTimer?.invalidate();  dismissTimer  = nil
            progressTimer?.invalidate(); progressTimer = nil
            return
        }
        timerFrozen    = false
        dismissProgress = 1.0
        guard dismissTimeout > 0 else {
            dismissTimer?.invalidate();  dismissTimer  = nil
            progressTimer?.invalidate(); progressTimer = nil
            return
        }

        dismissStartTime = Date()

        // Reset the existing dismiss timer's fire date instead of allocating
        // a new Timer + run-loop source on every cycle. ~100µs vs ~300µs and
        // less GC pressure during fast cycling.
        if let t = dismissTimer, t.isValid {
            t.fireDate = Date(timeIntervalSinceNow: dismissTimeout)
        } else {
            let t = Timer(timeInterval: dismissTimeout, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.softDisarm() }
            }
            RunLoop.main.add(t, forMode: .common)
            dismissTimer = t
        }

        // The progress ticker reads dismissStartTime live, so a single
        // long-lived timer covers the whole session — no need to recreate.
        if progressTimer == nil || !(progressTimer?.isValid ?? false) {
            let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let start = self.dismissStartTime, !self.timerFrozen else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.dismissProgress = max(0, 1.0 - elapsed / self.dismissTimeout)
            }
            RunLoop.main.add(t, forMode: .common)
            progressTimer = t
        }
    }

    /// Clamp `selectedIndex` to `displayItems` after ring mutations or
    /// while the popup is idle (highlight cleared but index remembered).
    private func clampSelectedIndexToDisplay() {
        let display = displayItems
        guard !display.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex), display.count - 1)
    }

    /// Idle timeout: clear the row highlight but keep the popup open. The
    /// remembered `selectedIndex` is unchanged — the next ⌘V only re-arms
    /// the highlight without advancing; the ⌘V after that moves forward.
    private func softDisarm() {
        selectionArmed = false
        dismissTimer?.invalidate()
        dismissTimer = nil
        progressTimer?.invalidate()
        progressTimer = nil
        dismissStartTime = nil
        dismissProgress = 0
    }

    private func dismissPreview() {
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        dismissTimer?.invalidate();  dismissTimer = nil
        progressTimer?.invalidate(); progressTimer = nil
        stageRevertTimer?.invalidate(); stageRevertTimer = nil
        cancelPendingFirstOpen()
        inTransformStage = false
        transformIndex   = 0
        selectedIndex    = 0
        selectionArmed   = true
        tagFilter   = nil
        dismissProgress  = 1.0
        timerFrozen      = false
        previewVisible   = false
        cycleCount       = 0
        // Clear caret cache — session is over, next ⌘V must re-query the
        // user's current caret position (they may have moved cursor).
        cachedCaretPosition = nil
    }

    /// Find the AppKit point where the user is currently typing, so the popup
    /// arrow can point at it. Tries (best → worst):
    /// 1. AX text-range bounds (real caret rect) — works in TextEdit, Mail, Notes, Safari, Chrome, Cursor, …
    /// 2. AX focused-element frame — works for any focused input
    /// 3. AX focused-window center — guaranteed app-window position
    /// 4. Current mouse location — last resort
    ///
    /// Coordinate notes: AX uses top-left origin (y-down) across ALL screens.
    /// AppKit uses bottom-left origin of the PRIMARY screen (y-up). To convert
    /// we use the primary screen's height, NOT NSScreen.main (which can be
    /// the screen with the active window — different on multi-monitor setups).
    private func caretPosition() -> NSPoint {
        // Primary screen height — same y-flip reference AX uses globally
        let primaryH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
                    ?? NSScreen.main?.frame.height
                    ?? 0

        // Focused app
        guard let appEl = focusedApplicationAXElement() else {
            return NSEvent.mouseLocation
        }

        // Focused UI element (text field, web view, etc.)
        let axEl = focusedUIElement(in: appEl) ?? appEl

        // 1) Best path — real text caret bounds via parameterized attribute
        if let caret = textCaretPoint(for: axEl, primaryH: primaryH) { return caret }

        // 2) Focused element frame — center bottom edge
        if let p = elementPoint(axEl, primaryH: primaryH) { return p }

        // 3) Focused window center — much better than mouse position
        var winRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
           let winVal = winRef,
           let p = elementPoint(winVal as! AXUIElement, primaryH: primaryH) {
            return p
        }

        // 4) Last resort
        return NSEvent.mouseLocation
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
                        self.dismissTimer?.invalidate(); self.dismissTimer = nil
                        self.progressTimer?.invalidate(); self.progressTimer = nil
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
                dismissTimer?.invalidate(); dismissTimer = nil
                progressTimer?.invalidate(); progressTimer = nil
                selectionArmed = true
                handleTransformResult(result, restoring: item, toolID: selectedToolID)
                return
            }
        }

        inTransformStage = false; transformIndex = 0

        let item = displayItems[selectedIndex]
        dismissTimer?.invalidate(); dismissTimer = nil
        progressTimer?.invalidate(); progressTimer = nil
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
            self?.cachedCaretPosition = nil   // session over → next ⌘V re-queries
        }
        AuthManager.shared.registerCommandVAction()
    }

    private func write(_ item: ClipboardItem, to pb: NSPasteboard) {
        switch item.content {
        case .text(let str):
            pb.setString(str, forType: .string)
        case .image(let img, let rawData, let dataType):
            let types = ImageService.pasteboardTypes(for: item)
            if !types.isEmpty {
                pb.declareTypes(types, owner: nil)
            }
            pb.setData(rawData, forType: dataType)
            if let compat = ImageService.compatibilityPasteboardPayload(
                image: img, rawData: rawData, dataType: dataType
            ) {
                pb.setData(compat.data, forType: compat.type)
            }
            pb.writeObjects([img])
            if ImageService.shouldAttachTiffFallback(for: dataType),
               let tiff = img.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        case .richText(let attrStr, let plain):
            let range = NSRange(location: 0, length: attrStr.length)
            if let rtfData = try? attrStr.data(from: range,
                                               documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                pb.setData(rtfData, forType: .rtf)
            }
            pb.setString(plain, forType: .string)
        case .html(let html, let plain):
            pb.setData(Data(html.utf8), forType: .init("public.html"))
            pb.setString(plain, forType: .string)
        case .file(let url):
            writeFileURLs([url], to: pb)
        case .files(let urls):
            writeFileURLs(urls, to: pb)
        }
    }

    private func writeFileURLs(_ urls: [URL], to pb: NSPasteboard) {
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingURLs.isEmpty else { return }

        let paths = existingURLs.map(\.path)
        pb.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))
        pb.writeObjects(existingURLs.map { $0 as NSURL })

        if existingURLs.count == 1, let url = existingURLs.first {
            pb.setString(url.absoluteString, forType: .init("public.file-url"))
            pb.setString(url.absoluteString, forType: .init("NSURLPboardType"))
            pb.setString(url.absoluteString, forType: .init("Apple URL pasteboard type"))
            writeSingleFilePayload(url, to: pb)
        }
    }

    private func writeSingleFilePayload(_ url: URL, to pb: NSPasteboard) {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey]),
              values.isDirectory != true else { return }

        // Avoid loading very large files into the pasteboard. Those still paste
        // as files through the file-url/Finder representations above.
        let maxInlineBytes = 50 * 1024 * 1024
        if let fileSize = values.fileSize, fileSize > maxInlineBytes { return }

        guard let data = try? Data(contentsOf: url) else { return }

        var types: [NSPasteboard.PasteboardType] = []
        if let contentType = values.contentType {
            types.append(.init(contentType.identifier))
        } else if let inferredType = UTType(filenameExtension: url.pathExtension) {
            types.append(.init(inferredType.identifier))
        }

        switch url.pathExtension.lowercased() {
        case "png":
            types.append(.init("public.png"))
        case "jpg", "jpeg":
            types.append(.init("public.jpeg"))
        case "gif":
            types.append(.init("public.gif"))
        case "tif", "tiff":
            types.append(.tiff)
        case "pdf":
            types.append(.init("com.adobe.pdf"))
            types.append(.init("public.pdf"))
        default:
            break
        }
        types.append(.init("public.data"))

        var seenTypes = Set<String>()
        for type in types where seenTypes.insert(type.rawValue).inserted {
            pb.setData(data, forType: type)
        }

        if let text = FileKindDetector.readableText(from: url, maxBytes: maxInlineBytes) {
            pb.setString(text, forType: .string)
        }
    }

    func pasteItem(at itemsIndex: Int) {
        guard items.indices.contains(itemsIndex) else { return }
        selectedIndex = isReversed ? (items.count - 1 - itemsIndex) : itemsIndex
        selectionArmed = true
        commitPaste()
    }

    // MARK: - Semantic search

    /// Cached last query → result so SwiftUI views that call this twice per
    /// render (e.g. once for `filtered` and once for the "Semantic" badge
    /// in the search bar) don't pay for the embedding + similarity scan
    /// twice. The embedding step alone is a 5–15ms ANE round-trip.
    private var lastSemanticQuery: String?
    private var lastSemanticResult: [ClipboardItem] = []
    private var lastSemanticItemsRev: Int = -1   // changes with every items mutation

    func semanticSearch(query: String) -> [ClipboardItem] {
        guard AuthManager.shared.semanticSearch else {
            lastSemanticQuery = query
            lastSemanticResult = []
            lastSemanticItemsRev = items.count
            return []
        }

        // Hit the cache if the query AND the underlying items haven't changed.
        if query == lastSemanticQuery && items.count == lastSemanticItemsRev {
            return lastSemanticResult
        }

        guard query.count >= 2,
              let emb = nlEmbedding,
              let queryVec = emb.vector(for: query)?.map({ Float($0) }) else {
            lastSemanticQuery = query
            lastSemanticResult = []
            lastSemanticItemsRev = items.count
            return []
        }
        let scored: [(ClipboardItem, Float)] = items.compactMap { item in
            guard let vec = item.embedding else { return nil }
            let score = cosineSimilarity(queryVec, vec)
            return score > 0.25 ? (item, score) : nil
        }
        let sorted = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        lastSemanticQuery = query
        lastSemanticResult = sorted
        lastSemanticItemsRev = items.count
        return sorted
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
        let imageData: Data?
        let imageType: String?
        let rtfData:   Data?
        let plainText: String?
        let filePath:  String?
        let filePaths: [String]?
        let html:      String?
        let sourceAppName: String?
        let sourceBundleID: String?
    }

    private var historyDir: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

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

    private func saveHistory() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item.content {
            case .text(let str):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "text", text: str,
                                     imageData: nil, imageType: nil, rtfData: nil, plainText: nil, filePath: nil,
                                     filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            case .image(_, let rawData, let dataType):
                guard rawData.count < 8_000_000 else { return nil }
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "image", text: nil,
                                     imageData: rawData, imageType: dataType.rawValue, rtfData: nil,
                                     plainText: nil, filePath: nil, filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            case .richText(let attrStr, let plain):
                let range = NSRange(location: 0, length: attrStr.length)
                let rtf = try? attrStr.data(from: range,
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "richText", text: nil,
                                     imageData: nil, imageType: nil, rtfData: rtf, plainText: plain, filePath: nil,
                                     filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            case .html(let html, let plain):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: item.urlTitle, type: "html", text: nil,
                                     imageData: nil, imageType: nil, rtfData: nil, plainText: plain, filePath: nil,
                                     filePaths: nil, html: html,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            case .file(let url):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "file", text: nil,
                                     imageData: nil, imageType: nil, rtfData: nil, plainText: nil, filePath: url.path,
                                     filePaths: nil, html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            case .files(let urls):
                return PersistedItem(id: item.id, timestamp: item.timestamp, isPinned: item.isPinned,
                                     urlTitle: nil, type: "files", text: nil,
                                     imageData: nil, imageType: nil, rtfData: nil, plainText: nil, filePath: nil,
                                     filePaths: urls.map(\.path), html: nil,
                                     sourceAppName: item.sourceAppName, sourceBundleID: item.sourceBundleID)
            }
        }
        guard let plain = try? enc.encode(persisted),
              let cipher = HistoryCrypto.encrypt(plain) else { return }
        try? cipher.write(to: historyFileURL, options: [.atomic, .completeFileProtection])
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
                guard let raw = p.imageData, let img = NSImage(data: raw) else { return nil }
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
            var item = ClipboardItem(content: content, id: p.id, timestamp: p.timestamp)
            item.isPinned = p.isPinned
            item.urlTitle = p.urlTitle
            item.sourceAppName = p.sourceAppName
            item.sourceBundleID = p.sourceBundleID
            return item
        }
        // Respect plan limit: keep all pinned + up to maxItems unpinned
        let pinned   = allLoaded.filter { $0.isPinned }
        let unpinned = Array(allLoaded.filter { !$0.isPinned }.prefix(maxItems))
        items = pinned + unpinned
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
    var urlTitle:  String?  = nil
    var diffBadge: String?  = nil
    var sourceAppName: String? = nil
    var sourceBundleID: String? = nil

    init(content: ClipboardContent, id: UUID = UUID(), timestamp: Date = Date()) {
        self.id        = id
        self.timestamp = timestamp
        self.content   = content
        self.detectedColor = ContentDetector.detectedColor(for: content)
        self.detectedType  = ContentDetector.detectedType(for: content, color: self.detectedColor)
        self.tags         = TagDetector.tags(for: content, color: self.detectedColor)
        self.primaryTag   = TagDetector.primaryTag(from: self.tags)
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

    var metadataSummary: String? {
        switch content {
        case .image(let img, let data, let dataType):
            let dims = "\(Int(img.size.width))×\(Int(img.size.height))"
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            return "\(dims) · \(size) · \(dataType.rawValue)"
        case .file(let url):
            return Self.fileMetadataSummary(for: url)
        case .files(let urls):
            let total = urls.compactMap { Self.fileSize($0) }.reduce(0, +)
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

    var image: NSImage? {
        if case .image(let img, _, _) = content { return img }
        return nil
    }

    var textForEmbedding: String? {
        switch content {
        case .text(let s):               return s
        case .richText(_, plain: let s): return s
        case .html(_, plain: let s):     return s
        default:                         return nil
        }
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
