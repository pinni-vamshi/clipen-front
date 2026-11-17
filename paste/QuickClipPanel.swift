import AppKit
import Combine
@preconcurrency import PDFKit
import SwiftUI
import WebKit

private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

private final class DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct SnappingDragHandle: NSViewRepresentable {
    let onDragEnd: () -> Void
    let onClick: () -> Void
    func makeNSView(context: Context) -> SnappingDragHandleNSView {
        let view = SnappingDragHandleNSView()
        view.onDragEnd = onDragEnd
        view.onClick = onClick
        return view
    }
    func updateNSView(_ nsView: SnappingDragHandleNSView, context: Context) {
        nsView.onDragEnd = onDragEnd
        nsView.onClick = onClick
    }
}

private final class SnappingDragHandleNSView: NSView {
    var onDragEnd: (() -> Void)?
    var onClick: (() -> Void)?
    private var mouseDownScreenLocation: NSPoint = .zero
    private var windowOriginAtMouseDown: NSPoint = .zero
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenLocation = NSEvent.mouseLocation
        windowOriginAtMouseDown = window?.frame.origin ?? .zero
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - mouseDownScreenLocation.x
        let dy = current.y - mouseDownScreenLocation.y
        if abs(dx) > 2 || abs(dy) > 2 { didDrag = true }
        window.setFrameOrigin(NSPoint(x: windowOriginAtMouseDown.x + dx,
                                       y: windowOriginAtMouseDown.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnd?()
        } else {
            onClick?()
        }
    }
}

struct ReferenceTag: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let kind: Kind
    /// The app the tag belongs to — for a context tag too (the site, folder
    /// or window it was taken from in that app). Context tags carried no
    /// app, so they could not be removed with their app, piled up as the
    /// context changed, and stayed on a page after its app was taken off.
    let bundleID: String?
    enum Kind { case app, context }
}

final class ReferenceCarousel: ObservableObject {
    @Published private(set) var pages: [ClipboardItem]
    @Published var index: Int = 0
    @Published var pendingFocusPageID: UUID? = nil

    @Published var lastActiveAppBundleID: String?
    var lastActiveAppDisplayName: String? {
        lastActiveAppBundleID.map { Self.appDisplayName(for: $0) }
    }

    /// The apps each page belongs to, in the order they were linked. Was a
    /// Set, whose `first` is arbitrary — popping a page out with two apps
    /// gave the new panel a random one of them.
    private(set) var pageOwnerBundleIDs: [UUID: [String]] = [:]
    private(set) var pageOwnerContext: [UUID: [String: String]] = [:]
    @Published private(set) var pageTags: [UUID: [ReferenceTag]] = [:]
    private var dismissedTags: Set<TagKey> = []
    private struct TagKey: Hashable { let pageID: UUID; let label: String }

    private(set) var dismissedOwnerBundleIDs: [UUID: Set<String>] = [:]

    func isDismissed(bundleID: String, pageID: UUID) -> Bool {
        dismissedOwnerBundleIDs[pageID]?.contains(bundleID) == true
    }

    private func addTag(_ label: String, kind: ReferenceTag.Kind, bundleID: String?, toPage pageID: UUID) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = TagKey(pageID: pageID, label: trimmed)
        guard !dismissedTags.contains(key) else { return }
        var tags = pageTags[pageID] ?? []
        // One context per app: a newer one (the tab moved on, the folder
        // changed) replaces that app's old context instead of adding a tag.
        if kind == .context {
            tags.removeAll { $0.kind == .context && $0.bundleID == bundleID && $0.label != trimmed }
        }
        guard !tags.contains(where: { $0.kind == kind && $0.label == trimmed && $0.bundleID == bundleID }) else {
            if tags != pageTags[pageID] ?? [] { pageTags[pageID] = tags }
            return
        }
        tags.append(ReferenceTag(label: trimmed, kind: kind, bundleID: bundleID))
        pageTags[pageID] = tags
    }

    /// Makes `bundleID` an owner of the page, keeping any it already has.
    /// Owners used to be ASSIGNED on add, so the same item sent from a
    /// second app replaced the first app's ownership while the first app's
    /// tag stayed on the page: the tag said one app, the page followed
    /// another.
    private func addOwner(_ bundleID: String, context: String?, toPage pageID: UUID) {
        var owners = pageOwnerBundleIDs[pageID] ?? []
        if !owners.contains(bundleID) { owners.append(bundleID) }
        pageOwnerBundleIDs[pageID] = owners
        if let context { pageOwnerContext[pageID, default: [:]][bundleID] = context }
    }

    private func autoTag(pageID: UUID, bundleID: String?, context: String?) {
        guard let bundleID, !isDismissed(bundleID: bundleID, pageID: pageID) else { return }
        addTag(Self.appDisplayName(for: bundleID), kind: .app, bundleID: bundleID, toPage: pageID)
        if let context { addTag(context, kind: .context, bundleID: bundleID, toPage: pageID) }
    }

    private static func appDisplayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    func removeTag(_ tagID: UUID, fromPage pageID: UUID) {
        guard var tags = pageTags[pageID] else { return }
        guard let removed = tags.first(where: { $0.id == tagID }) else { return }
        tags.removeAll { $0.id == tagID }
        dismissedTags.insert(TagKey(pageID: pageID, label: removed.label))

        switch removed.kind {
        case .app:
            // The app goes, and with it everything it put on the page: its
            // context tag, and the stored context that picks between pages.
            if let bundleID = removed.bundleID {
                pageOwnerBundleIDs[pageID]?.removeAll { $0 == bundleID }
                pageOwnerContext[pageID]?[bundleID] = nil
                dismissedOwnerBundleIDs[pageID, default: []].insert(bundleID)
                tags.removeAll { $0.kind == .context && $0.bundleID == bundleID }
            }
        case .context:
            // The page still belongs to the app, just not to that one place.
            if let bundleID = removed.bundleID,
               pageOwnerContext[pageID]?[bundleID] == removed.label {
                pageOwnerContext[pageID]?[bundleID] = nil
            }
        }
        pageTags[pageID] = tags
    }

    @Published var isCollapsed: Bool = false
    @Published private(set) var lastMoveDirection: Edge = .trailing

    /// True while the panel is shrunk to just the referenced item (plus its
    /// note and app names) because the pointer is elsewhere. Set only by
    /// `QuickClipPanel`.
    @Published var isBare: Bool = false

    /// What the current page tells the panel: the area the shrunk panel
    /// occupies (item + note + app names), in the window's top-left
    /// coordinates, and the note shown under the item.
    var bareBox: CGRect = .zero
    var bareNote: String = ""
    /// The current page has an edit or a focused editor — don't shrink.
    var pagePinsChrome = false
    /// The similar-items sidebar is open — don't shrink.
    var similarOpen = false
    var chromePinnedOpen: Bool { pagePinsChrome || similarOpen }
    /// Set by the panel: re-evaluate shrinking now that nothing pins it.
    var requestHoverCheck: (() -> Void)?
    /// Mirrors the panel's key status, so an editor that has focus keeps
    /// the chrome up only while typing could actually be happening.
    @Published var panelIsKey: Bool = false

    init(item: ClipboardItem, ownerBundleID: String?, ownerContext: String? = nil, focusContent: Bool = false) {
        self.pages = [item]
        if let ownerBundleID { addOwner(ownerBundleID, context: ownerContext, toPage: item.id) }
        autoTag(pageID: item.id, bundleID: ownerBundleID, context: ownerContext)
        if focusContent { pendingFocusPageID = item.id }
    }

    var current: ClipboardItem {
        guard !pages.isEmpty else {
            assertionFailure("ReferenceCarousel.current accessed with empty pages")
            return ClipboardItem(content: .text(""))
        }
        return pages[min(max(0, index), pages.count - 1)]
    }

    func addPage(_ item: ClipboardItem, ownerBundleID: String?, ownerContext: String? = nil, focusContent: Bool) {
        // The same item again (sent from another app, or twice) is the same
        // page: owners and tags are keyed by the item, so a second copy of
        // the page shared them with the first, and closing either one wiped
        // both. It now gains the new app and comes forward.
        if let existing = pages.firstIndex(where: { $0.id == item.id }) {
            if let ownerBundleID {
                dismissedOwnerBundleIDs[item.id]?.remove(ownerBundleID)
                dismissedTags.remove(TagKey(pageID: item.id, label: Self.appDisplayName(for: ownerBundleID)))
                addOwner(ownerBundleID, context: ownerContext, toPage: item.id)
            }
            autoTag(pageID: item.id, bundleID: ownerBundleID, context: ownerContext)
            if existing != index {
                lastMoveDirection = existing >= index ? .trailing : .leading
                index = existing
            }
            pendingFocusPageID = focusContent ? item.id : nil
            return
        }
        pages.append(item)
        if let ownerBundleID { addOwner(ownerBundleID, context: ownerContext, toPage: item.id) }
        autoTag(pageID: item.id, bundleID: ownerBundleID, context: ownerContext)
        index = pages.count - 1
        pendingFocusPageID = focusContent ? item.id : nil
    }

    func consumeFocusRequest(for id: UUID) {
        if pendingFocusPageID == id { pendingFocusPageID = nil }
    }

    func next() {
        guard pages.count > 1 else { return }
        lastMoveDirection = .trailing
        index = (index + 1) % pages.count
    }
    func prev() {
        guard pages.count > 1 else { return }
        lastMoveDirection = .leading
        index = (index - 1 + pages.count) % pages.count
    }

    /// Shows the page that belongs to `bundleID`. The APP decides whether a
    /// page matches; context (front tab, Finder folder, window title) only
    /// picks between several pages from the same app.
    ///
    /// Context used to have to match EXACTLY — the same URL, the same window
    /// title — and both change constantly: a link clicked in the same site,
    /// a renamed chat, "Edited" appearing in a document's title. Any change
    /// made the page "not belong" any more, and the panel then fell through
    /// to a meaning-based guess that matched almost anything.
    @discardableResult
    func jumpToPage(ownedBy bundleID: String, context: String? = nil) -> Bool {
        let owned = pages.indices.filter { pageOwnerBundleIDs[pages[$0].id]?.contains(bundleID) == true }
        guard let fallback = owned.last else { return false }
        var pick = owned.contains(index) ? index : fallback
        if let context {
            let scored = owned.map { idx in
                (idx, Self.contextScore(stored: pageOwnerContext[pages[idx].id]?[bundleID], live: context))
            }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0,
               best.1 > Self.contextScore(stored: pageOwnerContext[pages[pick].id]?[bundleID], live: context) {
                pick = best.0
            }
        }
        if pick != index {
            lastMoveDirection = pick >= index ? .trailing : .leading
            index = pick
        }
        return true
    }

    func ownsPage(for bundleID: String) -> Bool {
        pages.contains { pageOwnerBundleIDs[$0.id]?.contains(bundleID) == true }
    }

    func ownedPageCount(for bundleID: String) -> Int {
        pages.filter { pageOwnerBundleIDs[$0.id]?.contains(bundleID) == true }.count
    }

    /// The app (and its context) a page belongs to — kept when the page is
    /// popped out into its own panel.
    func owners(ofPage pageID: UUID) -> [(bundleID: String, context: String?)] {
        (pageOwnerBundleIDs[pageID] ?? []).map { ($0, pageOwnerContext[pageID]?[$0]) }
    }

    /// Gives a page every owner it had in another panel (popping out).
    func adoptOwners(_ owners: [(bundleID: String, context: String?)], forPage pageID: UUID) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        for owner in owners {
            addOwner(owner.bundleID, context: owner.context, toPage: pageID)
            autoTag(pageID: pageID, bundleID: owner.bundleID, context: owner.context)
        }
    }

    /// 3 identical, 2 same website, 1 mostly the same words (a window title
    /// or folder that changed a little), 0 unrelated.
    static func contextScore(stored: String?, live: String) -> Int {
        guard let stored, !stored.isEmpty, !live.isEmpty else { return 0 }
        if stored == live { return 3 }
        // Two web addresses: only the site counts. Word overlap would call
        // any two URLs similar — they all share "https" and "com".
        if let a = URL(string: stored)?.host, let b = URL(string: live)?.host, !a.isEmpty, !b.isEmpty {
            return a == b ? 2 : 0
        }
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 })
        }
        let ws = words(stored), wl = words(live)
        guard !ws.isEmpty, !wl.isEmpty else { return 0 }
        return Double(ws.intersection(wl).count) / Double(min(ws.count, wl.count)) >= 0.5 ? 1 : 0
    }

    @discardableResult
    func jumpToPage(id: UUID) -> Bool {
        guard let match = pages.firstIndex(where: { $0.id == id }) else { return false }
        lastMoveDirection = match >= index ? .trailing : .leading
        index = match
        return true
    }

    func linkCurrentPage(toApp bundleID: String, context: String? = nil) {

        dismissedOwnerBundleIDs[current.id]?.remove(bundleID)
        dismissedTags.remove(TagKey(pageID: current.id, label: Self.appDisplayName(for: bundleID)))
        addOwner(bundleID, context: context, toPage: current.id)
        autoTag(pageID: current.id, bundleID: bundleID, context: context)
    }

    func attachContext(_ context: String, toPage pageID: UUID, bundleID: String) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        guard !isDismissed(bundleID: bundleID, pageID: pageID) else { return }
        pageOwnerContext[pageID, default: [:]][bundleID] = context
        autoTag(pageID: pageID, bundleID: bundleID, context: context)
    }

    @discardableResult
    func removeCurrent() -> Bool {
        guard pages.indices.contains(index) else { return pages.isEmpty }
        let removed = pages.remove(at: index)
        pageOwnerBundleIDs.removeValue(forKey: removed.id)
        pageOwnerContext.removeValue(forKey: removed.id)
        pageTags.removeValue(forKey: removed.id)
        dismissedOwnerBundleIDs.removeValue(forKey: removed.id)
        dismissedTags = dismissedTags.filter { $0.pageID != removed.id }
        if pages.isEmpty { return true }
        index = min(index, pages.count - 1)
        return false
    }
}

class QuickClipPanel: NSPanel {
    let carousel: ReferenceCarousel
    static let similarSidebarWidth: CGFloat = 220
    private var similarSidebarWidth: CGFloat { Self.similarSidebarWidth }
    private var similarGrewLeft = false

    private var expandedFrame: NSRect?
    /// The user resized the panel themselves — stop auto-sizing it per page.
    private var userSized = false
    private let hoverTracker = PanelHoverTracker()
    private var hideChromeWork: DispatchWorkItem?
    private var indexObserver: AnyCancellable?
    private var resizeObserver: NSObjectProtocol?
    private static let collapsedSize = NSSize(width: 108, height: 108)
    private static let expandedMinSize = NSSize(width: 320, height: 260)
    private static let collapsedMargin: CGFloat = 16

    /// How long the pointer must be away before the panel shrinks.
    private static let bareDelay: TimeInterval = 0.15
    /// Window moves — to the corner and back, or resizing for a page. Long
    /// enough to travel across the screen smoothly (0.18s read as a jump),
    /// on a fast-out, gentle-settle curve.
    private static let frameAnimationDuration: TimeInterval = 0.34
    private static let frameTiming = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)

    /// While shrunk: watches the pointer, since the window lets clicks pass
    /// through everywhere except the item (see `updateClickThrough`).
    private var bareMouseMonitors: [Any] = []

    init(item: ClipboardItem, offset: CGFloat, focusContent: Bool = false,
         ownerBundleID: String? = nil, ownerContext: String? = nil) {
        self.carousel = ReferenceCarousel(item: item, ownerBundleID: ownerBundleID,
                                         ownerContext: ownerContext, focusContent: focusContent)
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = false
        self.isReleasedWhenClosed = false
        self.sharingType = .none
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden

        let hostingView = NSHostingView(
            rootView: QuickClipPanelContentView(
                carousel: carousel,
                onExpand: { [weak self] in self?.expand() },
                onLinkAndExpand: { [weak self] in self?.linkPendingAppAndExpand() },
                onSnapToEdge: { [weak self] in self?.snapCollapsedToNearestEdge() },
                onClosePanel: { [weak self] in self?.close() },
                onMinimize: { [weak self] in self?.minimize() },
                onClosePage: { [weak self] in self?.closeCurrentPage() },
                onPopOut: { [weak self] in self?.popOutCurrentPage() },
                onToggleSimilar: { [weak self] show in self?.resizeForSimilarSidebar(show: show) },
                onPreview: { [weak self] sim in
                    guard let self else { return }
                    ClipboardManager.shared.itemPreviewPanel.show(for: sim, near: self.frame)
                },
                onEndPreview: { ClipboardManager.shared.itemPreviewPanel.hide() }
            ).focusEffectDisabled().tracksWindowVisibility())
        hostingView.wantsLayer = true
        hostingView.layer?.borderWidth = 0
        self.contentView = hostingView

        // `.activeAlways`: this is a non-activating panel that is rarely
        // key, and hover has to work while the user is in another app.
        // `.inVisibleRect` keeps the area equal to the window as it shrinks
        // and grows, so only the visible panel ever counts as "hovered".
        hoverTracker.onChange = { [weak self] inside in self?.pointerChanged(inside: inside) }
        hostingView.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hoverTracker, userInfo: nil))

        carousel.requestHoverCheck = { [weak self] in self?.requestHoverCheck() }
        indexObserver = carousel.$index.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pageDidChange() } }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEndLiveResizeNotification, object: self, queue: .main
        ) { [weak self] _ in self?.userSized = true }

        self.contentMinSize = Self.expandedMinSize

        resizeForCurrentPage(centeredOffset: offset)
        revealChromeBriefly()
    }

    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
    }

    func addPage(_ item: ClipboardItem, focusContent: Bool, ownerBundleID: String?, ownerContext: String? = nil) {
        if carousel.isCollapsed { restoreIfCollapsed() }
        leaveBare()
        carousel.addPage(item, ownerBundleID: ownerBundleID, ownerContext: ownerContext, focusContent: focusContent)
        if !userSized { resizeForCurrentPage(centeredOffset: 0) }
        revealChromeBriefly()
    }

    // MARK: Shrinking to the item
    //
    // With the pointer away, the panel becomes just the thing referenced,
    // with its note and app names underneath. The window keeps its size;
    // SwiftUI fades the controls and draws the background tight around the
    // item, which itself never moves. Outside the item the window lets
    // clicks through to whatever is below, and only the item counts as
    // hovering the panel.

    private func pointerChanged(inside: Bool) {
        guard !carousel.isBare else { return }   // the monitors handle it then
        hideChromeWork?.cancel()
        if !inside { scheduleBare(after: Self.bareDelay) }
    }

    /// Full panel on arrival (it just opened, or just got a page) so its
    /// controls are seen; it shrinks shortly after if the pointer is away.
    private func revealChromeBriefly() {
        hideChromeWork?.cancel()
        leaveBare()
        scheduleBare(after: 1.6)
    }

    private func requestHoverCheck() {
        guard !frame.contains(NSEvent.mouseLocation) else { return }
        scheduleBare(after: Self.bareDelay)
    }

    private func scheduleBare(after delay: TimeInterval) {
        hideChromeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isVisible, !self.carousel.isCollapsed,
                  !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.enterBare()
        }
        hideChromeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func enterBare() {
        guard !carousel.isBare, !carousel.isCollapsed, !carousel.chromePinnedOpen,
              carousel.bareBox.width > 40 else { return }
        carousel.isBare = true
        startBareMouseMonitors()
        updateClickThrough()
        shadowAfterAnimation()
    }

    private func leaveBare() {
        guard carousel.isBare else { return }
        carousel.isBare = false
        stopBareMouseMonitors()
        ignoresMouseEvents = false
        shadowAfterAnimation()
    }

    /// Whether the pointer is over what the shrunk panel shows.
    private func pointerIsOverBareBox() -> Bool {
        let p = NSEvent.mouseLocation
        let local = CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
        return carousel.bareBox.contains(local)
    }

    /// Clicks outside the item go to the app underneath; on the item they
    /// come here. Re-evaluated on every pointer move while shrunk.
    private func updateClickThrough() {
        let over = pointerIsOverBareBox()
        if ignoresMouseEvents == over { ignoresMouseEvents = !over }
        if over {
            leaveBare()
        }
    }

    private func startBareMouseMonitors() {
        guard bareMouseMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.updateClickThrough()
        }) { bareMouseMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.updateClickThrough()
            return event
        }) { bareMouseMonitors.append(local) }
    }

    private func stopBareMouseMonitors() {
        bareMouseMonitors.forEach(NSEvent.removeMonitor)
        bareMouseMonitors = []
    }

    /// A borderless window's shadow follows what it draws only when asked.
    private func shadowAfterAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            self?.invalidateShadow()
        }
    }

    private func pageDidChange() {
        guard !carousel.isCollapsed else { return }
        if !userSized { resizeForCurrentPage(centeredOffset: 0) }
        if carousel.isBare { shadowAfterAnimation() }
    }

    override func becomeKey() {
        super.becomeKey()
        carousel.panelIsKey = true
    }

    override func resignKey() {
        super.resignKey()
        carousel.panelIsKey = false
    }

    func closeCurrentPage() {
        guard carousel.pages.count > 1 else {
            close()
            return
        }
        leaveBare()
        carousel.removeCurrent()
        if !userSized { resizeForCurrentPage(centeredOffset: 0) }
    }

    /// The page keeps the app it belongs to in its new panel — popping out
    /// used to drop that link, so the new panel could never surface.
    func popOutCurrentPage() {
        let item = carousel.current
        let owners = carousel.owners(ofPage: item.id)
        if carousel.pages.count > 1 {
            leaveBare()
            carousel.removeCurrent()
            if !userSized { resizeForCurrentPage(centeredOffset: 0) }
        } else {
            close()
        }
        ClipboardManager.shared.openStandaloneQuickClipPanel(for: item, owners: owners)
    }

    // MARK: Size

    /// The panel's size follows what's in it. Only images used to be
    /// measured; every other item opened at a fixed 420×460 whatever its
    /// length, and moving to another page never resized at all.
    private func resizeForCurrentPage(centeredOffset offset: CGFloat) {
        guard !carousel.isCollapsed else { return }
        let item = carousel.current
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero

        let hasNote = !(item.userNote ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasTags = !(carousel.pageTags[item.id] ?? []).isEmpty
        // Header, two dividers, notes (one line when empty), tags, padding.
        let chromeHeight: CGFloat = 34 + 2 + (hasNote ? 92 : 30) + (hasTags ? 28 : 0) + 24

        var w: CGFloat
        var h: CGFloat
        if case .image(let img, _, _) = item.content,
           img.size.width > 0, img.size.height > 0 {
            let maxPreviewW = min(720, screen.width * 0.55)
            let maxPreviewH = min(620, screen.height * 0.65)
            let scale = min(1, min(maxPreviewW / img.size.width,
                                   maxPreviewH / img.size.height))
            w = max(320, img.size.width * scale + 24)
            h = max(260, img.size.height * scale + chromeHeight)
        } else {
            w = 520
            h = chromeHeight + PreviewSizing.contentHeight(for: item)
            h = min(max(260, h), screen.height * 0.8)
        }

        if carousel.similarOpen { w += similarSidebarWidth }

        let hasFrame = frame.width > 0 && frame.height > 0
        var target: NSRect
        if hasFrame {
            // Keep the top edge where it is — a panel that resizes around
            // its middle jumps under the pointer.
            target = NSRect(x: frame.midX - w / 2, y: frame.maxY - h, width: w, height: h)
            // Kept on its screen sideways: a wider page (or the sidebar)
            // near an edge used to push part of the panel off screen.
            if target.maxX > screen.maxX { target.origin.x = screen.maxX - target.width }
            if target.minX < screen.minX { target.origin.x = screen.minX }
        } else {
            let centerX = screen.midX + offset
            let centerY = screen.midY - offset
            target = NSRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
        }
        if hasFrame { animatedSetFrame(target) } else { setFrame(target, display: true) }
    }

    func collapseToCorner(activeApp bundleID: String) {
        if !carousel.isCollapsed {
            AuthManager.shared.registerActionUsage(actionID: "ref.auto_collapse")
        }
        carousel.lastActiveAppBundleID = bundleID
        shrinkToCornerBadge()
    }

    var manualCollapseBundleID: String?

    func minimize() {
        manualCollapseBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        shrinkToCornerBadge()
    }

    private func animatedSetFrame(_ target: NSRect) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.frameAnimationDuration
            context.timingFunction = Self.frameTiming
            context.allowsImplicitAnimation = true
            self.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            // A borderless window's shadow follows what it draws only when
            // asked; without this it keeps the old outline.
            self?.invalidateShadow()
        }
    }

    private func nearestCornerOrigin(for center: NSPoint, size: NSSize, screen: NSRect) -> NSPoint {
        let margin = Self.collapsedMargin
        let nearLeft   = center.x - screen.minX <= screen.maxX - center.x
        let nearBottom = center.y - screen.minY <= screen.maxY - center.y
        let x = nearLeft   ? screen.minX + margin : screen.maxX - margin - size.width
        let y = nearBottom ? screen.minY + margin : screen.maxY - margin - size.height
        return NSPoint(x: x, y: y)
    }

    private func shrinkToCornerBadge() {
        guard !carousel.isCollapsed else { return }
        ClipboardManager.shared.itemPreviewPanel.hide()
        hideChromeWork?.cancel()
        leaveBare()
        if expandedFrame == nil { expandedFrame = frame }
        manualExpandBundleID = nil
        carousel.isCollapsed = true
        contentMinSize = Self.collapsedSize

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? frame
        let size = Self.collapsedSize
        let origin = nearestCornerOrigin(for: NSPoint(x: frame.midX, y: frame.midY), size: size, screen: screen)
        animatedSetFrame(NSRect(origin: origin, size: size))
    }

    func snapCollapsedToNearestEdge() {
        guard carousel.isCollapsed else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? frame
        let size = frame.size
        let origin = nearestCornerOrigin(for: NSPoint(x: frame.midX, y: frame.midY), size: size, screen: screen)
        animatedSetFrame(NSRect(origin: origin, size: size))
    }

    var manualExpandBundleID: String?

    func expand() {
        guard carousel.isCollapsed else { return }
        AuthManager.shared.registerActionUsage(actionID: "ref.badge_click")
        manualExpandBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        restoreIfCollapsed()
    }

    func linkPendingAppAndExpand() {
        guard carousel.isCollapsed else { return }
        AuthManager.shared.registerActionUsage(actionID: "ref.badge_click")
        manualExpandBundleID = nil
        if let app = carousel.lastActiveAppBundleID {
            carousel.linkCurrentPage(toApp: app, context: nil)
        }
        restoreIfCollapsed()
    }

    /// Comes back from the corner straight to the right state: shrunk to the
    /// item when the pointer isn't on it. It used to restore the full panel
    /// and flash all its controls for 1.6s on every app switch.
    func restoreIfCollapsed() {
        guard carousel.isCollapsed else { return }
        carousel.isCollapsed = false
        carousel.lastActiveAppBundleID = nil
        contentMinSize = Self.expandedMinSize
        let full = expandedFrame
        expandedFrame = nil
        guard let full else {
            resizeForCurrentPage(centeredOffset: 0)
            return
        }
        animatedSetFrame(full)
        if !full.contains(NSEvent.mouseLocation) {
            // Shrink as the window lands, using the layout measured before
            // it went to the corner; skipped if nothing was measured yet.
            enterBare()
        }
    }

    private func resizeForSimilarSidebar(show: Bool) {
        carousel.similarOpen = show
        if show { leaveBare() }
        // Sized by the page: one calculation for page + sidebar, so the
        // two can't disagree. A panel the user sized by hand keeps its size
        // and only gains or loses the sidebar's width.
        if !userSized {
            resizeForCurrentPage(centeredOffset: 0)
            if !show { requestHoverCheck() }
            return
        }
        var f = self.frame
        // This panel's own screen, as the resize code above uses.
        let screen = (self.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(f) }))?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? f
        if show {
            if f.maxX + similarSidebarWidth <= screen.maxX {
                similarGrewLeft = false
                f.size.width += similarSidebarWidth
            } else {
                similarGrewLeft = true
                f.origin.x -= similarSidebarWidth
                f.size.width += similarSidebarWidth
            }
        } else {
            f.size.width = max(contentMinSize.width, f.size.width - similarSidebarWidth)
            if similarGrewLeft { f.origin.x += similarSidebarWidth }
        }
        animatedSetFrame(f)
        if !show { requestHoverCheck() }
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        ClipboardManager.shared.itemPreviewPanel.hide()
        hideChromeWork?.cancel()
        super.close()
        DispatchQueue.main.async {
            ClipboardManager.shared.quickClipPanelDidClose(self)
        }
    }
}

/// Receives the panel's hover tracking-area events. A tracking area's owner
/// has to be a responder; this keeps those callbacks off the panel itself.
private final class PanelHoverTracker: NSResponder {
    var onChange: ((Bool) -> Void)?
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}

private struct QuickClipPanelContentView: View {
    @ObservedObject var carousel: ReferenceCarousel
    let onExpand: () -> Void
    let onLinkAndExpand: () -> Void
    let onSnapToEdge: () -> Void
    let onClosePanel: () -> Void
    let onMinimize: () -> Void
    let onClosePage: () -> Void
    let onPopOut: () -> Void
    let onToggleSimilar: (Bool) -> Void
    let onPreview: (ClipboardItem) -> Void
    let onEndPreview: () -> Void

    @State private var showSimilar:  Bool = false
    @State private var similarItems: [ClipboardItem] = []
    @StateObject private var pagerController = PagerController()

    private var item: ClipboardItem { carousel.current }

    var body: some View {
        if carousel.isCollapsed {
            CollapsedReferenceBadge(pendingAppName: carousel.lastActiveAppDisplayName,
                                     onExpand: onExpand,
                                     onLinkAndExpand: onLinkAndExpand,
                                     onSnapToEdge: onSnapToEdge)
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        HStack(spacing: 0) {
            SlidingPager(carousel: carousel, controller: pagerController) { pageItem in
                ReferencePageContentView(
                    carousel: carousel,
                    item: pageItem,
                    isCurrent: pageItem.id == item.id,
                    shouldFocus: carousel.pendingFocusPageID == pageItem.id,
                    onConsumeFocusRequest: { carousel.consumeFocusRequest(for: pageItem.id) },
                    pageCount: carousel.pages.count,
                    pageIndex: carousel.pages.firstIndex(where: { $0.id == pageItem.id }) ?? carousel.index,
                    onClosePanel: onClosePanel,
                    onMinimize: onMinimize,
                    onClosePage: onClosePage,
                    onPopOut: onPopOut,
                    onPrevPage: { pagerController.advance(-1) },
                    onNextPage: { pagerController.advance(1) },
                    showSimilar: pageItem.id == item.id && showSimilar,
                    similarCount: pageItem.id == item.id ? similarItems.count : 0,
                    onToggleSimilar: {
                        showSimilar.toggle()
                        if showSimilar {
                            AuthManager.shared.registerActionUsage(actionID: "action.similar-items")
                            if similarItems.isEmpty {
                                similarItems = ClipboardManager.shared.similarItems(to: item)
                            }
                        }
                        onToggleSimilar(showSimilar)
                    },
                    tags: carousel.pageTags[pageItem.id] ?? [],
                    onRemoveTag: { tagID in carousel.removeTag(tagID, fromPage: pageItem.id) }
                )
                .id(pageItem.id)
            }
            .frame(maxWidth: .infinity)

            if showSimilar && !carousel.isBare {
                Divider()
                SimilarItemsSidePanelView(pinned: item, onPreview: onPreview,
                                          onEndPreview: onEndPreview, similars: $similarItems)
                    .id(item.id)
                    .frame(width: QuickClipPanel.similarSidebarWidth)
                    .background(.regularMaterial)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // The sidebar follows the page: it shows the new page's similar
        // items. Closing it here as well as resizing for the new page ran
        // two window animations at once, and the second subtracted the
        // sidebar from a frame the first had already set — the panel
        // ended up at its minimum width.
        .onChange(of: item.id) { _, _ in
            similarItems = showSimilar ? ClipboardManager.shared.similarItems(to: item) : []
        }
    }
}

private final class PagerController: ObservableObject {
    fileprivate var advanceHandler: ((Int) -> Void)?
    func advance(_ direction: Int) { advanceHandler?(direction) }
}

private struct SlidingPager<Content: View>: View {
    @ObservedObject var carousel: ReferenceCarousel
    @ObservedObject var controller: PagerController
    @ViewBuilder let content: (ClipboardItem) -> Content

    @State private var dragOffset: CGFloat = 0
    @State private var isAnimating = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            HStack(spacing: 0) {
                slot(index: carousel.index - 1, width: w)
                slot(index: carousel.index, width: w)
                slot(index: carousel.index + 1, width: w)
            }
            .frame(width: w * 3, height: geo.size.height, alignment: .leading)
            .offset(x: -w + dragOffset)
            .onAppear { controller.advanceHandler = { direction in advance(direction, pageWidth: w) } }
            .onChange(of: w) { _, newW in
                controller.advanceHandler = { direction in advance(direction, pageWidth: newW) }
            }
        }
        .clipped()
    }

    /// Only the visible page is built. The neighbours exist just for the
    /// slide — they used to be fully built (editors, web previews, image
    /// views) all the time, tripling the work of every panel. Indices wrap,
    /// so sliding from the last page to the first shows the first.
    @ViewBuilder
    private func slot(index: Int, width: CGFloat) -> some View {
        let count = carousel.pages.count
        let isCenter = index == carousel.index
        if count > 0, isCenter || (isAnimating && count > 1) {
            content(carousel.pages[((index % count) + count) % count])
                .frame(width: width)
                .clipped()
        } else {
            Color.clear.frame(width: width)
        }
    }

    private func advance(_ direction: Int, pageWidth: CGFloat) {
        guard carousel.pages.count > 1, !isAnimating else { return }
        isAnimating = true
        withAnimation(.easeInOut(duration: 0.22)) {
            dragOffset = direction > 0 ? -pageWidth : pageWidth
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            if direction > 0 { carousel.next() } else { carousel.prev() }
            dragOffset = 0
            isAnimating = false
        }
    }
}

private struct CollapsedReferenceBadge: View {
    let pendingAppName: String?
    let onExpand: () -> Void
    let onLinkAndExpand: () -> Void
    let onSnapToEdge: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 4) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Smart Reference")
                    .font(.system(size: 10, weight: .semibold))
            }

            if let pendingAppName {
                Button(action: onLinkAndExpand) {
                    Text("Add \(pendingAppName)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 108, height: 108)
        .background(SnappingDragHandle(onDragEnd: onSnapToEdge, onClick: onExpand))
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct SmartReferenceToggle: View {
    // Reads the one setting it shows. It observed all of ClipboardManager,
    // so every page header redrew on every copy and every popup keystroke.
    // The manager writes this same key; writing goes through the manager so
    // its side effects still run.
    @AppStorage("referenceAppAffinityEnabled") private var isOn: Bool = true

    var body: some View {
        Button {
            ClipboardManager.shared.referenceAppAffinityEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(isOn ? Color.accentColor : Color.secondary.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text("Smart Reference")
                    .font(.system(size: 10, weight: .semibold))
                Text(isOn ? "On" : "Off")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundColor(isOn ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(isOn
              ? "Smart auto-surface is on — switching to the app a reference was pinned from brings it forward automatically. Click to turn off."
              : "Smart auto-surface is off. Click to turn back on.")
    }
}

private struct ReferenceTagRow: View {
    let tags: [ReferenceTag]
    let onRemove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags) { tag in
                    HStack(spacing: 4) {
                        Image(systemName: tag.kind == .app ? "app.badge" : "link")
                            .font(.system(size: 8))
                        Text(tag.label)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                        Button(action: { onRemove(tag.id) }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 4)
    }
}

private struct ReferencePageContentView: View {
    @ObservedObject var carousel: ReferenceCarousel
    let item: ClipboardItem
    /// The page the user is looking at (the pager also lays out its
    /// neighbours while sliding). Only the current page reports its layout
    /// and editing state to the panel.
    let isCurrent: Bool
    let shouldFocus: Bool
    let onConsumeFocusRequest: () -> Void
    let pageCount: Int
    let pageIndex: Int
    let onClosePanel: () -> Void
    let onMinimize: () -> Void
    let onClosePage: () -> Void
    let onPopOut: () -> Void
    let onPrevPage: () -> Void
    let onNextPage: () -> Void
    let showSimilar: Bool
    let similarCount: Int
    let onToggleSimilar: () -> Void
    let tags: [ReferenceTag]
    let onRemoveTag: (UUID) -> Void

    @State private var noteText: String
    @State private var lastCommittedNote: String
    @State private var noteCommitTask: Task<Void, Never>? = nil
    @State private var noteEditorOpen = false
    @FocusState private var noteFocused: Bool
    @State private var editedText: String
    @State private var savedText: String
    @FocusState private var contentFocused: Bool
    @State private var editedRows: [[String]]
    @State private var savedRows: [[String]]
    @State private var isEditing: Bool
    @State private var pageSize: CGSize = .zero
    @State private var contentFrame: CGRect = .zero
    @State private var footerHeight: CGFloat = 0

    private static let pageSpace = "referencePage"
    /// One curve for everything the shrink moves.
    static let bareAnimation = Animation.smooth(duration: 0.32)

    /// Decided once per page. These used to be computed properties, re-run
    /// on every body evaluation — the table check parses the item's HTML.
    private let isEditableTable: Bool
    private let isEditableText: Bool

    private var isBare: Bool { carousel.isBare }

    private var hasUnsavedEdits: Bool {
        (isEditableTable && editedRows != savedRows) || (isEditableText && editedText != savedText)
    }

    /// The full panel stays up while there is something you'd lose by
    /// shrinking it: an edit in progress, unsaved changes, or an editor you
    /// are typing in.
    private var pinsChrome: Bool {
        isEditing || hasUnsavedEdits || (carousel.panelIsKey && (noteFocused || contentFocused))
    }

    private var displayedNote: String {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitNote(_ value: String) {
        guard value != lastCommittedNote else { return }
        lastCommittedNote = value
        ClipboardManager.shared.updateUserNote(id: item.id, note: value)
    }

    /// The table editor is offered only when the item IS a table — its text
    /// is mostly that table. It used to open for any item that merely
    /// CONTAINED a table, showing only the table, and Save then replaced the
    /// whole item with it, deleting everything around it.
    private static func isDominantTable(_ item: ClipboardItem) -> Bool {
        guard TableCellExtractor.cells(for: item) != nil else { return false }
        switch item.content {
        case .html(let html, _):
            return TableCellExtractor.htmlIsDominantDataTable(html)
        case .richText(let attr, _):
            return TableCellExtractor.attributedIsDominantDataTable(attr)
        case .rtfd(let data, _):
            return NSAttributedString(rtfd: data, documentAttributes: nil)
                .map(TableCellExtractor.attributedIsDominantDataTable) ?? false
        default:
            return false
        }
    }

    init(carousel: ReferenceCarousel, item: ClipboardItem, isCurrent: Bool,
         shouldFocus: Bool, onConsumeFocusRequest: @escaping () -> Void,
         pageCount: Int, pageIndex: Int,
         onClosePanel: @escaping () -> Void, onMinimize: @escaping () -> Void,
         onClosePage: @escaping () -> Void, onPopOut: @escaping () -> Void,
         onPrevPage: @escaping () -> Void, onNextPage: @escaping () -> Void,
         showSimilar: Bool, similarCount: Int, onToggleSimilar: @escaping () -> Void,
         tags: [ReferenceTag] = [], onRemoveTag: @escaping (UUID) -> Void = { _ in }) {
        self.carousel = carousel
        self.item = item
        self.isCurrent = isCurrent
        self.shouldFocus = shouldFocus
        self.onConsumeFocusRequest = onConsumeFocusRequest
        self.pageCount = pageCount
        self.pageIndex = pageIndex
        self.onClosePanel = onClosePanel
        self.onMinimize = onMinimize
        self.onClosePage = onClosePage
        self.onPopOut = onPopOut
        self.onPrevPage = onPrevPage
        self.onNextPage = onNextPage
        self.showSimilar = showSimilar
        self.similarCount = similarCount
        self.onToggleSimilar = onToggleSimilar
        self.tags = tags
        self.onRemoveTag = onRemoveTag
        let existingNote = item.userNote ?? ""
        _noteText          = State(initialValue: existingNote)
        _lastCommittedNote = State(initialValue: existingNote)

        let table = Self.isDominantTable(item)
        let isRich: Bool = {
            switch item.content {
            case .html, .richText, .rtfd: return true
            default: return false
            }
        }()
        let plain = (table || isRich) ? nil : ClipboardManager.editablePlainText(for: item)
        self.isEditableTable = table
        self.isEditableText = plain != nil
        _editedText = State(initialValue: plain ?? "")
        _savedText  = State(initialValue: plain ?? "")
        let cells = table ? (TableCellExtractor.cells(for: item) ?? []) : []
        _editedRows = State(initialValue: cells)
        _savedRows  = State(initialValue: cells)
        _isEditing  = State(initialValue: shouldFocus && (table || plain != nil))
    }

    var body: some View {
        // The layout never changes between the full panel and the shrunk
        // one — only opacity, the background's shape and the footer's
        // position animate. The first version swapped layouts and resized
        // the window, so the item re-laid out on every animation frame
        // (text re-wrapping, images rescaling) and jittered.
        VStack(spacing: 0) {
            header
                .chrome(!isBare)
            Divider()
                .chrome(!isBare)

            contentArea
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.pageSpace)) } action: { rect in
                    contentFrame = rect
                    reportToPanel()
                }

            Divider()
                .chrome(!isBare)
            notesSection
                .chrome(!isBare)
            if !tags.isEmpty {
                Divider()
                    .chrome(!isBare)
                ReferenceTagRow(tags: tags, onRemove: onRemoveTag)
                    .chrome(!isBare)
            }
        }
        .coordinateSpace(name: Self.pageSpace)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0; reportToPanel() }
        .background(alignment: .topLeading) { pageBackground }
        .overlay(alignment: .topLeading) { positionedBareFooter }
        .animation(Self.bareAnimation, value: isBare)
        .onAppear {
            if shouldFocus {
                if isEditing { contentFocused = true }
                onConsumeFocusRequest()
            }
            reportToPanel()
        }
        .onChange(of: pinsChrome) { _, _ in reportToPanel() }
        .onChange(of: displayedNote) { _, _ in reportToPanel() }
        .onChange(of: isCurrent) { _, _ in reportToPanel() }
        .onChange(of: footerHeight) { _, _ in reportToPanel() }
    }

    /// The item itself, in this page's coordinates: 6pt of panel around
    /// what the preview draws — for an image, around the picture as fitted.
    private var itemBox: CGRect {
        guard contentFrame.width > 0 else { return .zero }
        if case .image(let img, _, _) = item.content, img.size.width > 0, img.size.height > 0,
           !(isEditing) {
            let area = contentFrame.insetBy(dx: 12, dy: 12)
            let scale = min(area.width / img.size.width, area.height / img.size.height)
            let fitted = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            return CGRect(x: area.midX - fitted.width / 2, y: area.midY - fitted.height / 2,
                          width: fitted.width, height: fitted.height).insetBy(dx: -6, dy: -6)
        }
        return contentFrame.insetBy(dx: 6, dy: 6)
    }

    /// Everything the shrunk panel shows: the item plus its note and app
    /// names underneath.
    private var bareBox: CGRect {
        let box = itemBox
        return CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height + footerHeight)
    }

    private func reportToPanel() {
        guard isCurrent else { return }
        carousel.bareNote = displayedNote
        carousel.bareBox = bareBox
        if carousel.pagePinsChrome != pinsChrome {
            carousel.pagePinsChrome = pinsChrome
            if !pinsChrome { carousel.requestHoverCheck?() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClosePanel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(pageCount > 1 ? "Close entire panel (all \(pageCount) references)" : "Close")
            .accessibilityLabel(pageCount > 1 ? "Close entire panel, all \(pageCount) references" : "Close reference panel")

            Button(action: onMinimize) {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Minimize to corner")
            .accessibilityLabel("Minimize reference panel to corner")

            HStack(spacing: 6) {
                Image(systemName: item.iconName)
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)
                Text(item.typeLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
            }

            Spacer()

            SmartReferenceToggle()

            if isEditing && hasUnsavedEdits {
                Button {
                    if isEditableTable {
                        ClipboardManager.shared.updateItemTable(id: item.id, rows: editedRows)
                        savedRows = editedRows
                    } else {
                        ClipboardManager.shared.updateItemText(id: item.id, newText: editedText)
                        savedText = editedText
                    }
                    isEditing = false
                } label: {
                    Text("Save")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Save edits back to the clipboard item")
            }

            if isEditableText || isEditableTable {
                Button {
                    if isEditing {
                        // Done without saving puts the item back as it was.
                        editedText = savedText
                        editedRows = savedRows
                    }
                    isEditing.toggle()
                    if isEditing { DispatchQueue.main.async { contentFocused = true } }
                } label: {
                    Text(isEditing ? "Cancel" : "Edit")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help(isEditing ? "Stop editing without saving" : "Edit this item")
            }

            Button {
                ClipboardManager.shared.pasteFromReferencePanel(itemID: item.id)
            } label: {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            // It pastes (puts it on the clipboard and into the app you're
            // in); the old "Copy to clipboard" described something else.
            .help("Paste into the app you're using")

            Button(action: onToggleSimilar) {
                HStack(spacing: 3) {
                    Image(systemName: showSimilar ? "square.stack.fill" : "square.stack")
                        .font(.system(size: 11))
                    if similarCount > 0 && showSimilar {
                        Text("\(similarCount)")
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(showSimilar ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(showSimilar ? "Hide similar items" : "Show similar items from clipboard")

            Button(action: onPopOut) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Move to its own separate panel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(WindowDragHandle())
    }

    // MARK: Content

    /// The whole item, through the same renderers as the preview — Markdown
    /// rendered, code coloured, tables and HTML drawn, maths typeset. Text
    /// items used to open straight into a raw text editor, so none of that
    /// ever showed here; editing is now an explicit mode.
    private var contentArea: some View {
        Group {
            if isEditing && isEditableTable {
                VStack(alignment: .leading, spacing: 6) {
                    EditableTableGrid(rows: $editedRows)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Saving replaces this item with the edited table.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(8)
            } else if isEditing && isEditableText {
                TextEditor(text: $editedText)
                    .font(.system(size: 12, design: item.detectedType.isCodeLike ? .monospaced : .default))
                    .scrollContentBackground(.hidden)
                    .focused($contentFocused)
                    .padding(8)
            } else {
                QuickClipPreview(item: item)
                    .padding(12)
                    .onDrag { item.makeItemProvider() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            pageControls.padding(8).chrome(!isBare)
        }
    }

    /// Page position and arrows together in one small pill, instead of two
    /// big arrows sitting on top of the content's left and right edges.
    private var pageControls: some View {
        HStack(spacing: 6) {
            if pageCount > 1 {
                HStack(spacing: 4) {
                    Button(action: onPrevPage) {
                        Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Previous reference")
                    Text("\(pageIndex + 1) of \(pageCount)")
                        .font(.system(size: 9, weight: .medium))
                    Button(action: onNextPage) {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Next reference")
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.regularMaterial, in: Capsule())
            }
            Button(action: onClosePage) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
                    .background(Circle().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .help(pageCount > 1 ? "Close this reference" : "Close")
        }
    }

    // MARK: Notes

    /// An empty note is one line until it's wanted, instead of a 90-point
    /// editor under every reference.
    @ViewBuilder
    private var notesSection: some View {
        if noteText.isEmpty && !noteFocused && !noteEditorOpen {
            Button {
                noteEditorOpen = true
                DispatchQueue.main.async { noteFocused = true }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                    Text("Add a note…")
                        .font(.system(size: 10, weight: .semibold))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Notes")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !noteText.isEmpty {
                        Button {
                            noteText = ""
                            noteCommitTask?.cancel()
                            commitNote("")
                            noteEditorOpen = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                TextEditor(text: $noteText)
                    .font(.system(size: 11))
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .background(Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                    .focused($noteFocused)
                    .onChange(of: noteText) { _, newValue in
                        noteCommitTask?.cancel()
                        noteCommitTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled else { return }
                            commitNote(newValue)
                        }
                    }
                    .onDisappear {
                        noteCommitTask?.cancel()
                        commitNote(noteText)
                    }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
    }

    // MARK: Bare state

    /// Under the item while the panel is shrunk: its note and the apps it
    /// belongs to, read-only. Always laid out (so it can be measured and
    /// faded), placed directly below the item.
    private var positionedBareFooter: some View {
        let box = itemBox
        return bareFooter
            .frame(width: max(0, box.width))
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            .offset(x: box.minX, y: box.maxY)
            .opacity(isBare && box.width > 0 ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(!isBare)
    }

    private var bareFooter: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !displayedNote.isEmpty {
                Text(displayedNote)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
            if !tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(tags) { tag in
                        HStack(spacing: 3) {
                            Image(systemName: tag.kind == .app ? "app.badge" : "link")
                                .font(.system(size: 8))
                            Text(tag.label)
                                .font(.system(size: 9, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .frame(height: 24)
                .clipped()
            }
        }
    }

    /// One shape that either fills the page or wraps the item, so shrinking
    /// reads as the panel gathering itself around a still item.
    private var pageBackground: some View {
        let full = CGRect(origin: .zero, size: pageSize)
        let bare = bareBox
        let useBare = isBare && bare.width > 0
        let rect = useBare ? bare : full
        let radius: CGFloat = useBare ? 14 : 0
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(useBare ? 0.18 : 0), lineWidth: 1)
            )
            .frame(width: max(0, rect.width), height: max(0, rect.height))
            .offset(x: rect.minX, y: rect.minY)
    }
}

private extension View {
    /// Panel chrome: faded out, untouchable and hidden from VoiceOver while
    /// the panel is shrunk to the item. It keeps its space, so nothing moves.
    func chrome(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

private extension ClipboardContentType {
    var isCodeLike: Bool {
        switch self {
        case .code, .json, .table, .latex: return true
        default: return false
        }
    }
}

private struct QuickClipPreview: View {
    let item: ClipboardItem

    var body: some View {
        ContentPreviewView(item: item, chrome: .reference)
    }
}

private struct SimilarItemsSidePanelView: View {
    let pinned:      ClipboardItem
    let onPreview:   (ClipboardItem) -> Void
    let onEndPreview: () -> Void
    @Binding var similars: [ClipboardItem]

    /// Read when the sidebar draws, which is whenever its list changes.
    /// It observed all of ClipboardManager, redrawing on every change
    /// anywhere in the app for a menu that's rarely opened.
    private var addableItems: [ClipboardItem] {
        let shownIDs = Set(similars.map(\.id) + [pinned.id])
        return ClipboardManager.shared.items.lazy.filter { !shownIDs.contains($0.id) }.prefix(20).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Text("Similar items")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()

                Menu {
                    let candidates = addableItems
                    if candidates.isEmpty {
                        Text("No other items to add")
                    } else {
                        ForEach(Array(candidates)) { candidate in
                            Button {
                                similars.append(candidate)
                            } label: {
                                Text(String(candidate.previewText.prefix(50)))
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add any clipboard item to this list")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if similars.isEmpty {
                Text("No similar items found")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(similars) { sim in
                            SimilarItemCard(pinned: pinned, similar: sim)
                                .onTapGesture {
                                    onPreview(sim)
                                }
                        }
                    }
                    .padding(10)
                }
            }
        }
    }
}

private struct SimilarItemCard: View {
    let pinned:  ClipboardItem
    let similar: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: similar.iconName)
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor)
                Text(similar.typeLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            diffView
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Button {
                ClipboardManager.shared.pasteFromReferencePanel(itemID: similar.id)
            } label: {
                Text("Paste")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .center)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private var diffView: some View {
        let pinnedText  = pinnedPlainText
        let similarText = similarPlainText
        if let p = pinnedText, let s = similarText {
            DiffHighlightText(baseText: p, compareText: s)
        } else if let s = similarText {
            Text(s)
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(4)
                .foregroundColor(.primary)
        } else {
            Text(similar.typeLabel)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    private var pinnedPlainText: String? { pinned.content.plainText }

    private var similarPlainText: String? { similar.content.plainText }
}

private struct DiffHighlightText: View {
    let baseText:    String
    let compareText: String

    var body: some View {
        let baseWords = Set(baseText.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 })

        let words = compareText
            .components(separatedBy: .whitespacesAndNewlines)
            .prefix(60)

        var result = Text("")
        var first  = true
        for word in words {
            if !first { result = result + Text(" ") }
            first = false
            let isNew = !baseWords.contains(word.lowercased())
            if isNew {
                result = result + Text(word)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .bold()
            } else {
                result = result + Text(word)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.7))
            }
        }
        return result.lineLimit(4)
    }
}

struct EditableTableGrid: View {
    @Binding var rows: [[String]]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(spacing: 1) {
                ForEach(rows.indices, id: \.self) { r in
                    HStack(spacing: 1) {
                        ForEach(rows[r].indices, id: \.self) { c in
                            TextField("", text: Binding(
                                get: { rows[r][c] },
                                set: { rows[r][c] = $0 }
                            ))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: r == 0 ? .semibold : .regular))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .frame(minWidth: 80, alignment: .leading)
                            .background(Color.primary.opacity(r == 0 ? 0.06 : 0.02))
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                        }
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}
