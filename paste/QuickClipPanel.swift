import AppKit
import Combine
@preconcurrency import PDFKit
import SwiftUI
import WebKit

/// Invisible drag surface — dropped into just the header bar so ONLY that
/// area moves the window, instead of the old `isMovableByWindowBackground`
/// behavior which let dragging anywhere in the content (the preview image,
/// the notes field) accidentally drag the whole panel around.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleNSView { DragHandleNSView() }
    func updateNSView(_ nsView: DragHandleNSView, context: Context) {}
}

private final class DragHandleNSView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Drives every page pinned into ONE reference panel window. Pinning a new
/// item appends a page to whichever carousel panel is already open instead
/// of spawning a second, disconnected floating window — the user explicitly
/// asked for "one panel, horizontal scroll between references" instead of
/// the old one-window-per-pin model. Popping a page out (see the toolbar
/// button) removes it from here and gives it its own standalone panel.
/// A removable descriptive tag on a pinned reference page — either the app
/// it was pinned/linked from, or the tab URL / Finder path / window title
/// that was captured alongside it (see AppContextService).
struct ReferenceTag: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let kind: Kind
    enum Kind { case app, context }
}

final class ReferenceCarousel: ObservableObject {
    @Published private(set) var pages: [ClipboardItem]
    @Published var index: Int = 0
    /// Set whenever a page is (re)shown with focus requested — the content
    /// view for the page whose id matches this focuses its editor on
    /// appear, then clears it via consumeFocusRequest(). A per-page id
    /// rather than a Bool/token because ReferencePageContentView is
    /// `.id()`-keyed per item and only needs to know "was THIS specific
    /// page the one that was just asked to focus."
    @Published var pendingFocusPageID: UUID? = nil

    /// Bundle IDs of every app a page is linked to — the app-affinity
    /// auto-surface feature (see ClipboardManager) keys off this to find
    /// which pinned reference, if any, belongs to the app the user just
    /// switched to. A SET, not a single ID: a page starts linked to just the
    /// app frontmost when it was pinned, but expanding a collapsed "no match"
    /// badge (see ClipboardManager.surfaceReferencePanel) links the app you
    /// expanded it FROM too, so the same reference matches multiple apps
    /// over time instead of only ever the original one.
    private(set) var pageOwnerBundleIDs: [UUID: Set<String>] = [:]
    /// Tab/window context captured alongside the bundle ID (see
    /// AppContextService) — a browser tab URL, a Finder folder path, or a
    /// window title, whichever was available for that app. Only set when
    /// capture actually succeeded; a page with no entry here still matches
    /// on bundle ID alone, exactly as before this feature existed. Keyed by
    /// (page ID, bundle ID) since a page can be linked to several apps over
    /// time and each needs its own remembered context.
    private(set) var pageOwnerContext: [UUID: [String: String]] = [:]
    /// Auto-collected tags per page — one for the app it was pinned/linked
    /// from, and one for the tab URL / Finder path / window title if that was
    /// captured too. Purely descriptive (unlike pageOwnerBundleIDs/Context,
    /// removing a tag here does NOT unlink the matching) — the user can `✕`
    /// one off if it's noise, and it stays gone (see removeTag) even if the
    /// same app/context tries to add it again later.
    @Published private(set) var pageTags: [UUID: [ReferenceTag]] = [:]
    /// Tags the user explicitly removed — (page ID, tag label) pairs that
    /// must never be re-added automatically, otherwise the next app switch
    /// would just silently resurrect the exact tag they dismissed.
    private var dismissedTags: Set<TagKey> = []
    private struct TagKey: Hashable { let pageID: UUID; let label: String }

    /// Adds a tag to `pageID` if it isn't already present and wasn't
    /// previously dismissed by the user.
    private func addTag(_ label: String, kind: ReferenceTag.Kind, toPage pageID: UUID) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = TagKey(pageID: pageID, label: trimmed)
        guard !dismissedTags.contains(key) else { return }
        var tags = pageTags[pageID] ?? []
        guard !tags.contains(where: { $0.label == trimmed }) else { return }
        tags.append(ReferenceTag(label: trimmed, kind: kind))
        pageTags[pageID] = tags
    }

    /// Auto-tags a page from an app/context pair captured at pin or link
    /// time — one tag for the app name, one for the tab/window context.
    private func autoTag(pageID: UUID, bundleID: String?, context: String?) {
        guard let bundleID else { return }
        addTag(Self.appDisplayName(for: bundleID), kind: .app, toPage: pageID)
        if let context { addTag(context, kind: .context, toPage: pageID) }
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

    /// User explicitly closed this tag via its `✕` — remove it and remember
    /// not to auto-add it again for this page.
    func removeTag(_ tagID: UUID, fromPage pageID: UUID) {
        guard var tags = pageTags[pageID] else { return }
        guard let removed = tags.first(where: { $0.id == tagID }) else { return }
        tags.removeAll { $0.id == tagID }
        pageTags[pageID] = tags
        dismissedTags.insert(TagKey(pageID: pageID, label: removed.label))
    }

    /// True while this carousel is shown as the small "no reference found"
    /// corner badge instead of its full content — see ClipboardManager.
    /// surfaceReferencePanel and QuickClipPanel.collapseToCorner/expand.
    @Published var isCollapsed: Bool = false
    /// Which way the page transition should slide — set by whichever method
    /// changed `index` (next/prev/jumpToPage), so the content view (which
    /// observes this alongside index) always slides the RIGHT direction,
    /// including for the app-affinity auto-jump, not just manual paging.
    @Published private(set) var lastMoveDirection: Edge = .trailing

    init(item: ClipboardItem, ownerBundleID: String?, ownerContext: String? = nil, focusContent: Bool = false) {
        self.pages = [item]
        if let ownerBundleID {
            pageOwnerBundleIDs[item.id] = [ownerBundleID]
            if let ownerContext { pageOwnerContext[item.id, default: [:]][ownerBundleID] = ownerContext }
        }
        autoTag(pageID: item.id, bundleID: ownerBundleID, context: ownerContext)
        if focusContent { pendingFocusPageID = item.id }
    }

    /// Crash-proofed against an empty `pages`: `pages.count - 1` would be -1
    /// there, and indexing at -1 is a fatal Swift trap — which is exactly
    /// what closing the LAST page in a panel via the body's small X button
    /// used to do, killing the whole app instantly (removeCurrent() emptied
    /// pages, and SwiftUI re-rendered against `current` before the window
    /// actually finished closing). closeCurrentPage() below now avoids ever
    /// calling removeCurrent() when it would empty the array; this is the
    /// belt-and-suspenders backstop in case anything else ever does.
    var current: ClipboardItem {
        guard !pages.isEmpty else {
            assertionFailure("ReferenceCarousel.current accessed with empty pages")
            return ClipboardItem(content: .text(""))
        }
        return pages[min(max(0, index), pages.count - 1)]
    }

    func addPage(_ item: ClipboardItem, ownerBundleID: String?, ownerContext: String? = nil, focusContent: Bool) {
        pages.append(item)
        if let ownerBundleID {
            pageOwnerBundleIDs[item.id] = [ownerBundleID]
            if let ownerContext { pageOwnerContext[item.id, default: [:]][ownerBundleID] = ownerContext }
        }
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

    /// True if the app with this bundle ID owns any page in this carousel —
    /// used by the app-affinity auto-surface to find a match. If found,
    /// jumps the carousel to that page (sliding smoothly toward it — see
    /// lastMoveDirection).
    ///
    /// `context` (the LIVE tab URL/window title captured right now, via
    /// AppContextService) makes this tab/window-precise, not just app-wide:
    /// a page that stored a context for this bundle ID only matches if that
    /// stored value equals the live one — same app, different tab, no
    /// match. A page with NO stored context (capture wasn't possible for
    /// that app) stays eligible on bundle ID alone, exactly as this worked
    /// before the feature existed — never a regression for apps we can't
    /// get more precise about.
    @discardableResult
    func jumpToPage(ownedBy bundleID: String, context: String? = nil) -> Bool {
        guard let match = pages.firstIndex(where: { page in
            guard pageOwnerBundleIDs[page.id]?.contains(bundleID) == true else { return false }
            guard let storedContext = pageOwnerContext[page.id]?[bundleID] else { return true }
            guard let context else { return true }
            return storedContext == context
        }) else { return false }
        lastMoveDirection = match >= index ? .trailing : .leading
        index = match
        return true
    }

    /// Links the CURRENT page to an additional app (and its tab/window
    /// context, if captured) — called when the user expands a collapsed
    /// "no reference found" badge, so the reference they clearly wanted
    /// while in that app/tab matches it automatically next time.
    func linkCurrentPage(toApp bundleID: String, context: String? = nil) {
        pageOwnerBundleIDs[current.id, default: []].insert(bundleID)
        if let context { pageOwnerContext[current.id, default: [:]][bundleID] = context }
        autoTag(pageID: current.id, bundleID: bundleID, context: context)
    }

    /// Jumps directly to a specific page by ID — used by the semantic
    /// best-match path (ClipboardManager.surfaceReferencePanel), which finds
    /// a match by comparing tab-content embeddings against page content, not
    /// by an exact bundle ID / context lookup, so it needs to name the page
    /// it found rather than re-deriving it from jumpToPage(ownedBy:).
    @discardableResult
    func jumpToPage(id: UUID) -> Bool {
        guard let match = pages.firstIndex(where: { $0.id == id }) else { return false }
        lastMoveDirection = match >= index ? .trailing : .leading
        index = match
        return true
    }

    /// Removes the current page. Returns true once the carousel is empty —
    /// the caller (QuickClipPanel) closes the whole window in that case.
    @discardableResult
    func removeCurrent() -> Bool {
        guard pages.indices.contains(index) else { return pages.isEmpty }
        let removed = pages.remove(at: index)
        pageOwnerBundleIDs.removeValue(forKey: removed.id)
        pageOwnerContext.removeValue(forKey: removed.id)
        pageTags.removeValue(forKey: removed.id)
        if pages.isEmpty { return true }
        index = min(index, pages.count - 1)
        return false
    }
}

class QuickClipPanel: NSPanel {
    let carousel: ReferenceCarousel
    /// Similar items render as an inline sidebar inside THIS panel now (not a
    /// separate floating window — that read as two disconnected popups
    /// instead of one panel with a sidebar). Showing/hiding it grows/shrinks
    /// this window's width instead.
    private let similarSidebarWidth: CGFloat = 220
    /// Which side the sidebar grew into, so hiding it shrinks back from the
    /// same edge it grew from.
    private var similarGrewLeft = false

    /// Frame to restore when expanding back out of the collapsed corner
    /// badge — captured the moment it collapses.
    private var expandedFrame: NSRect?
    /// The app that was active when this panel last collapsed to a badge —
    /// linked to the current page once the user clicks to expand again, so
    /// the same reference matches that app automatically from then on.
    private var pendingLinkAppBundleID: String?
    /// Tab/window context (see AppContextService) captured alongside
    /// pendingLinkAppBundleID, so a manual expand-to-link remembers the
    /// specific tab too, not just the app.
    private var pendingLinkAppContext: String?
    private static let collapsedSize = NSSize(width: 108, height: 108)
    private static let expandedMinSize = NSSize(width: 320, height: 300)
    private static let collapsedMargin: CGFloat = 16

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
        // Only the header toolbar should drag the window — not the whole
        // panel background (that let dragging the preview/notes content
        // accidentally move the entire window). See WindowDragHandle, applied
        // just to the header HStack below.
        self.isMovableByWindowBackground = false
        // The manager's `quickClipPanels` array owns this panel; don't let
        // AppKit also release it on close (that would over-release now that the
        // content view no longer retains us — see the weak `onClose` below).
        self.isReleasedWhenClosed = false

        // Pass weak-capturing closures rather than a strong `self`. A strong
        // back-reference created a retain cycle (panel → hostingView →
        // content view → panel) that leaked one panel per pin.
        let hostingView = NSHostingView(
            rootView: QuickClipPanelContentView(
                carousel: carousel,
                onExpand: { [weak self] in self?.expand() },
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
            ))
        self.contentView = hostingView

        // .resizable was already in the style mask, but with no floor a
        // borderless panel can be dragged down to a broken, unusable sliver —
        // the content (preview, notes field) needs a sane minimum to stay usable.
        self.contentMinSize = Self.expandedMinSize

        resizeForCurrentPage(centeredOffset: offset)
    }

    /// Adds a page to THIS carousel and brings it to front — used when a new
    /// item is pinned while this panel is already the active reference panel.
    func addPage(_ item: ClipboardItem, focusContent: Bool, ownerBundleID: String?, ownerContext: String? = nil) {
        carousel.addPage(item, ownerBundleID: ownerBundleID, ownerContext: ownerContext, focusContent: focusContent)
        resizeForCurrentPage(centeredOffset: 0)
    }

    /// X button: removes just the CURRENT page (unpins that one reference).
    /// Closes the whole window only once the last page is removed — matches
    /// how a tab-per-reference model would behave, rather than one click
    /// discarding every pinned reference in the panel at once.
    func closeCurrentPage() {
        // Closing the ONLY remaining page would empty carousel.pages —
        // close the window directly instead of mutating pages first. The
        // old order (remove, THEN close) let SwiftUI re-render against
        // carousel.current with an empty pages array in the instant before
        // the window actually finished closing, which crashed the whole
        // app (see current's doc comment). Closing first sidesteps that
        // window entirely: the content view never gets a chance to redraw
        // against the now-empty carousel.
        guard carousel.pages.count > 1 else {
            close()
            return
        }
        carousel.removeCurrent()
        resizeForCurrentPage(centeredOffset: 0)
    }

    /// Detaches the current page into its own standalone panel, removing it
    /// from this carousel.
    func popOutCurrentPage() {
        // Same crash class as closeCurrentPage: never call removeCurrent()
        // when it would empty carousel.pages — close directly instead, so
        // SwiftUI is never asked to re-render against an empty carousel.
        let item = carousel.current
        if carousel.pages.count > 1 {
            carousel.removeCurrent()
            resizeForCurrentPage(centeredOffset: 0)
        } else {
            close()
        }
        ClipboardManager.shared.openStandaloneQuickClipPanel(for: item)
    }

    /// Re-sizes the window for whichever page is now current — image pages
    /// match the image's own aspect ratio; everything else keeps the default
    /// box. Keeps the window's CENTER fixed across a resize (rather than
    /// its origin), so paging between differently-sized references doesn't
    /// make the panel visibly jump.
    private func resizeForCurrentPage(centeredOffset offset: CGFloat) {
        // Don't fight the collapsed badge's size/position — it resumes
        // normal sizing once expand() restores the real frame.
        guard !carousel.isCollapsed else { return }
        let item = carousel.current
        let screen = NSScreen.main?.visibleFrame ?? .zero

        var w: CGFloat = 420
        var h: CGFloat = 460
        // Vertical chrome around the preview: header bar + dividers + notes
        // area + the preview's own padding. Keep in sync with mainContent.
        let chromeHeight: CGFloat = 160
        if case .image(let img, _, _) = item.content,
           img.size.width > 0, img.size.height > 0 {
            let maxPreviewW = min(720, screen.width * 0.55)
            let maxPreviewH = min(620, screen.height * 0.65)
            let scale = min(1, min(maxPreviewW / img.size.width,
                                   maxPreviewH / img.size.height))
            let fittedW = img.size.width * scale
            let fittedH = img.size.height * scale
            w = max(320, fittedW + 24)   // + preview's horizontal padding
            h = max(300, fittedH + 24 + chromeHeight)
        }

        let hasFrame = frame.width > 0 && frame.height > 0
        let centerX = hasFrame ? frame.midX : screen.midX + offset
        let centerY = hasFrame ? frame.midY : screen.midY - offset
        let x = centerX - w / 2
        let y = centerY - h / 2

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: hasFrame)
    }

    /// App-affinity "no match" outcome: instead of fully hiding, shrink to a
    /// small square badge parked in the nearest screen corner — still
    /// visible, just out of the way, so the user is reminded the panel
    /// exists and can bring it back with one click.
    func collapseToCorner(activeApp bundleID: String, activeContext: String? = nil) {
        // Analytics: Smart Reference found NO match for this app and
        // collapsed to the badge — the "guessed wrong / nothing relevant"
        // half of the auto-surface accuracy signal.
        if !carousel.isCollapsed {
            AuthManager.shared.registerActionUsage(actionID: "ref.auto_collapse")
        }
        // Always update which app a manual badge-click would link to — even
        // if already collapsed. The old order (only inside the "not yet
        // collapsed" guard) froze this at whichever app FIRST triggered the
        // collapse: switch A (collapses, pending=A) → switch to B (already
        // collapsed, early-return skipped updating pending) → the panel sat
        // there attributing itself to app A forever, no matter how many
        // OTHER non-matching apps you switched through afterward.
        pendingLinkAppBundleID = bundleID
        pendingLinkAppContext = activeContext
        shrinkToCornerBadge()
    }

    /// The "-" button next to the panel's close button — lets the user shrink
    /// it to the same small corner badge Smart Reference itself uses when it
    /// finds no match, purely as a manual "get this out of my way for now"
    /// action. No app gets linked on the way in (pendingLinkAppBundleID is
    /// left as whatever it already was, usually nil), so clicking the badge
    /// back open via expand() just restores it without mislinking anything.
    func minimize() {
        shrinkToCornerBadge()
    }

    /// Shared corner-shrink animation used by both the automatic "no
    /// reference found" collapse and the manual "-" minimize button.
    private func shrinkToCornerBadge() {
        guard !carousel.isCollapsed else { return }
        // A similar-item preview (shown via itemPreviewPanel.show, positioned
        // near THIS panel's frame — see the init above) has no idea this
        // panel is about to shrink to a corner badge; left open, it stayed
        // floating in place, now pointing at nothing, after the reference
        // panel it was anchored to had already visually moved away. Must
        // close before the collapse animation starts, not after.
        ClipboardManager.shared.itemPreviewPanel.hide()
        if expandedFrame == nil { expandedFrame = frame }
        carousel.isCollapsed = true
        // contentMinSize (320×300, so a dragged-open panel never shrinks to
        // an unusable sliver) would otherwise clamp setFrame below to that
        // floor — drop it to the badge size for the duration of the collapse.
        contentMinSize = Self.collapsedSize

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? frame
        let size = Self.collapsedSize
        let margin = Self.collapsedMargin
        let center = NSPoint(x: frame.midX, y: frame.midY)
        // Whichever corner of the screen is nearest the panel's current
        // position — so it slides the shortest distance, not always to the
        // same corner regardless of where it started.
        let nearLeft   = center.x - screen.minX <= screen.maxX - center.x
        let nearBottom = center.y - screen.minY <= screen.maxY - center.y
        let x = nearLeft   ? screen.minX + margin : screen.maxX - margin - size.width
        let y = nearBottom ? screen.minY + margin : screen.maxY - margin - size.height
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)

        // setFrame(..., animate: true) alone is unreliable on borderless /
        // .nonactivatingPanel windows — it often just jumps. Driving it
        // through an explicit NSAnimationContext + the window's animator
        // proxy is the version that actually animates every time.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().setFrame(target, display: true)
        }
    }

    /// Expands back out of the collapsed corner badge from a MANUAL user
    /// click, restoring the frame it had before collapsing, and links the
    /// app that was active (the one the user clicked the badge FROM) to the
    /// current page — so the same reference matches that app automatically
    /// from now on. Only the badge's own click should ever reach this;
    /// see restoreIfCollapsed() for the auto-affinity-match path, which
    /// must NOT apply this linking. When the collapse came from the manual
    /// "-" button rather than an app switch, pendingLinkAppBundleID is nil,
    /// so this is a no-op linking-wise and just restores the frame.
    func expand() {
        guard carousel.isCollapsed else { return }
        // Analytics: the user clicked the collapsed badge back open —
        // the click-through signal for Smart Reference's auto-collapse.
        AuthManager.shared.registerActionUsage(actionID: "ref.badge_click")
        if let app = pendingLinkAppBundleID {
            carousel.linkCurrentPage(toApp: app, context: pendingLinkAppContext)
        }
        restoreIfCollapsed()
    }

    /// Restores from a collapsed badge WITHOUT linking anything — used by
    /// the app-affinity auto-surface when it finds a REAL match (the page is
    /// already correctly linked to this app; that's how it matched) and just
    /// needs to bring the panel back into view. Using expand() here instead
    /// was the bug: it unconditionally applied whatever pendingLinkAppBundleID
    /// happened to be left over from the last (possibly unrelated, possibly
    /// several-switches-ago) collapse, silently mislinking the page to apps
    /// the user never actually asked to associate it with — which is also
    /// why the feature seemed to "stop working" after the first cycle: pages
    /// picked up spurious extra links and started matching the wrong apps.
    func restoreIfCollapsed() {
        guard carousel.isCollapsed else { return }
        carousel.isCollapsed = false
        contentMinSize = Self.expandedMinSize
        pendingLinkAppBundleID = nil
        pendingLinkAppContext = nil
        if let restore = expandedFrame {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(restore, display: true)
            }
        } else {
            resizeForCurrentPage(centeredOffset: 0)
        }
        expandedFrame = nil
    }

    /// Grows this window to reveal the inline similar-items sidebar (or
    /// shrinks it back). Prefers growing to the right; falls back to growing
    /// left if there's no room on the right, mirroring how the old separate
    /// side panel picked which side to appear on.
    private func resizeForSimilarSidebar(show: Bool) {
        var f = self.frame
        let screen = NSScreen.main?.visibleFrame ?? f
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
        setFrame(f, display: true, animate: true)
    }

    // Borderless windows return NO from canBecomeKey by default — without
    // this override, the panel could never become key, so keyDown events
    // (including every keystroke typed into the Notes TextEditor) never
    // reached it at all. .nonactivatingPanel already keeps this from
    // stealing focus from the app the panel is floating over; this just lets
    // it accept keyboard input once the user clicks into it, same as any
    // normal panel with a text field.
    override var canBecomeKey: Bool { true }

    override func close() {
        ClipboardManager.shared.itemPreviewPanel.hide()
        super.close()
        // Notify ClipboardManager that this panel is closed
        DispatchQueue.main.async {
            ClipboardManager.shared.quickClipPanelDidClose(self)
        }
    }
}

/// Outer shell: carousel chrome (prev/next arrows, page indicator, pop-out,
/// close-current-page) plus the similar-items sidebar. The actual per-page
/// content lives in ReferencePageContentView, `.id()`-keyed by item so
/// SwiftUI gives every page its own fresh @State (edited text, notes draft,
/// etc.) instead of one shared set of state bleeding across pages.
private struct QuickClipPanelContentView: View {
    @ObservedObject var carousel: ReferenceCarousel
    /// Expands back out of the collapsed "no reference found" corner badge.
    let onExpand: () -> Void
    /// Closes the WHOLE panel — every pinned page in it.
    let onClosePanel: () -> Void
    /// Manually shrinks the panel to the corner badge — same mechanics as
    /// the automatic "no reference found" collapse, just user-triggered.
    let onMinimize: () -> Void
    /// Closes just the CURRENT page (unpins that one reference; the panel
    /// stays open with whatever pages remain).
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
            CollapsedReferenceBadge(onExpand: onExpand)
        } else {
            expandedBody
        }
    }

    private var expandedBody: some View {
        HStack(spacing: 0) {
            SlidingPager(carousel: carousel, controller: pagerController) { pageItem in
                ReferencePageContentView(
                    item: pageItem,
                    shouldFocus: carousel.pendingFocusPageID == pageItem.id,
                    onConsumeFocusRequest: { carousel.consumeFocusRequest(for: pageItem.id) },
                    pageCount: carousel.pages.count,
                    pageIndex: carousel.pages.firstIndex(where: { $0.id == pageItem.id }) ?? carousel.index,
                    onClosePanel: onClosePanel,
                    onMinimize: onMinimize,
                    onClosePage: onClosePage,
                    onPopOut: onPopOut,
                    // Similar-items state describes only the CURRENT page —
                    // the prev/next peeking slots (visible mid-drag) don't
                    // get their own similar-items panel/toggle state.
                    showSimilar: pageItem.id == item.id && showSimilar,
                    similarCount: pageItem.id == item.id ? similarItems.count : 0,
                    onToggleSimilar: {
                        showSimilar.toggle()
                        if showSimilar {
                            AuthManager.shared.registerActionUsage(actionID: "action.similar-items")
                            if similarItems.isEmpty {
                                // Image/PDF similarity runs real Vision work
                                // off the main actor now (text stays fast/
                                // synchronous internally) — hop into a Task
                                // so the UI never blocks waiting for it.
                                Task { @MainActor in
                                    similarItems = await ClipboardManager.shared.similarItems(to: item)
                                }
                            }
                        }
                        onToggleSimilar(showSimilar)
                    },
                    tags: carousel.pageTags[pageItem.id] ?? [],
                    onRemoveTag: { tagID in carousel.removeTag(tagID, fromPage: pageItem.id) }
                )
                .id(pageItem.id)
            }
            // Paging arrows live OUTSIDE the sliding strip, fixed on top of
            // it — only the content underneath moves. Previously the arrows
            // were part of each per-page view, so they slid along with the
            // content instead of staying put.
            .overlay(alignment: .leading) {
                if carousel.pages.count > 1 {
                    pagerArrow(systemName: "chevron.left.circle.fill") { pagerController.advance(-1) }
                        .padding(.leading, 6)
                }
            }
            .overlay(alignment: .trailing) {
                if carousel.pages.count > 1 {
                    pagerArrow(systemName: "chevron.right.circle.fill") { pagerController.advance(1) }
                        .padding(.trailing, 6)
                }
            }
            .frame(maxWidth: .infinity)

            if showSimilar {
                Divider()
                SimilarItemsSidePanelView(pinned: item, onPreview: onPreview,
                                          onEndPreview: onEndPreview, similars: $similarItems)
                    .id(item.id)
                    .frame(width: 220)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        // Dismissing the similar-item preview on outside clicks is handled
        // globally now (ClipboardManager.handleMouseDown, keyed on
        // itemPreviewPanel.isVisible) — that covers clicks ANYWHERE on
        // screen, not just inside this window, which a local tap gesture
        // here could never do.
        .onChange(of: item.id) { _, _ in
            // Similar items describe the OLD page — reset rather than show
            // stale suggestions for the newly-current one.
            showSimilar = false
            similarItems = []
        }
    }

    private func pagerArrow(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
                .background(Circle().fill(.regularMaterial))
        }
        .buttonStyle(.plain)
    }
}

/// Genuinely interactive carousel: renders the previous/current/next pages
/// side by side and offsets the whole strip, so dragging tracks the
/// finger/cursor 1:1 in real time — not a canned insertion/removal
/// transition that just swaps content after the fact. Past the release
/// threshold, the slide animates smoothly the REST of the way off-screen
/// and only THEN swaps `carousel.index` (with the offset reset to 0 in the
/// same instant) — so the content change itself is invisible, hidden
/// behind content that's already fully off-frame. Below threshold, it
/// springs back to the current page. Arrow-button taps reuse the exact same
/// `advance` path via the `requestAdvance` closure handed to `content`, so
/// every trigger (drag, swipe, arrows, app-affinity jump) slides identically.
/// Lets the arrow buttons — which live OUTSIDE the sliding strip, fixed on
/// screen — trigger the strip's advance animation, which lives INSIDE
/// SlidingPager as private @State. Without this indirection the arrows
/// would have to be part of the sliding content to reach `advance`, which
/// is exactly the bug this fixes: arrows sliding along with the page
/// instead of staying put while only the content moves underneath them.
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

    @ViewBuilder
    private func slot(index: Int, width: CGFloat) -> some View {
        if carousel.pages.indices.contains(index) {
            content(carousel.pages[index])
                .frame(width: width)
                .clipped()
        } else {
            Color.clear.frame(width: width)
        }
    }

    /// direction: 1 = next (slide left), -1 = prev (slide right).
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

/// Small square shown instead of the full panel when app-affinity finds no
/// reference belonging to the app just switched to — stays visible (parked
/// in the nearest screen corner by QuickClipPanel.collapseToCorner) rather
/// than fully hiding, so the user is reminded it exists and can bring the
/// real content back with one click.
private struct CollapsedReferenceBadge: View {
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            VStack(spacing: 4) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Smart Reference")
                    .font(.system(size: 10, weight: .semibold))
                Text("(no reference found)")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(width: 108, height: 108)
        }
        .buttonStyle(.plain)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
        .help("No pinned reference belongs to the active app. Click to reopen — this will also link the reference to this app.")
    }
}

/// One page's actual content: header (type icon/label, page arrows, Save,
/// Copy, similar-items toggle, pop-out, close), the editor/preview area, and
/// the Notes box. Everything here is `let`/`@State` scoped to ONE item —
/// the parent gives this view `.id(item.id)` so switching pages recreates
/// it fresh instead of trying to rebind existing state to different content.
/// The one piece of ReferencePageContentView that needs live manager state:
/// the Smart Reference on/off tint. Isolated into its own view so the PAGE
/// doesn't observe the whole ClipboardManager — it used to, which meant every
/// @Published change anywhere (each popup hint flash on every V tap, every
/// new copy, every selection move) re-rendered every reference page, RTFD
/// parsing included.
private struct SmartReferenceToggle: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        Button {
            manager.referenceAppAffinityEnabled.toggle()
        } label: {
            Text("Smart Reference")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(manager.referenceAppAffinityEnabled ? .accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(manager.referenceAppAffinityEnabled
              ? "Smart auto-surface is on — switching to the app a reference was pinned from brings it forward automatically. Click to turn off."
              : "Smart auto-surface is off. Click to turn back on.")
    }
}

/// Horizontally-scrolling row of a page's auto-collected app/tab tags, each
/// with a small `✕` so the user can dismiss ones that aren't actually
/// related — see ReferenceCarousel.removeTag for why a dismissed tag stays
/// gone instead of getting silently re-added on the next matching switch.
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
    let item: ClipboardItem
    /// True if the carousel wants THIS page's editor focused right now —
    /// consumed (cleared) via onConsumeFocusRequest once acted on, so it
    /// doesn't re-fire the next time this view happens to redraw.
    let shouldFocus: Bool
    let onConsumeFocusRequest: () -> Void
    let pageCount: Int
    let pageIndex: Int
    /// Closes the WHOLE panel — wired to the toolbar's top-left X.
    let onClosePanel: () -> Void
    /// Shrinks the WHOLE panel to the corner badge — wired to the "-" button
    /// right next to the close X.
    let onMinimize: () -> Void
    /// Closes just THIS page — wired to the small X overlaid on the content
    /// body, not the toolbar.
    let onClosePage: () -> Void
    let onPopOut: () -> Void
    let showSimilar: Bool
    let similarCount: Int
    let onToggleSimilar: () -> Void
    /// Auto-collected app/tab tags for this page (see ReferenceCarousel.
    /// pageTags) — shown as a removable chip row under the header.
    let tags: [ReferenceTag]
    let onRemoveTag: (UUID) -> Void

    @State private var noteText: String
    /// Debounced note commit — see MainWindowView's ItemDetailView for why:
    /// updateUserNote mutates the @Published items array, so per-keystroke
    /// commits re-rendered every observing view and reset the save debounce
    /// on each character.
    @State private var lastCommittedNote: String
    @State private var noteCommitTask: Task<Void, Never>? = nil
    @FocusState private var noteFocused: Bool
    @State private var editedText: String
    @State private var savedText: String
    @FocusState private var contentFocused: Bool
    @State private var editedRows: [[String]]
    @State private var savedRows: [[String]]

    private func commitNote(_ value: String) {
        guard value != lastCommittedNote else { return }
        lastCommittedNote = value
        ClipboardManager.shared.updateUserNote(id: item.id, note: value)
    }

    private var isEditableTable: Bool {
        TableCellExtractor.cells(for: item) != nil
    }
    private var isEditableText: Bool {
        !isEditableTable && ClipboardManager.editablePlainText(for: item) != nil
    }

    init(item: ClipboardItem, shouldFocus: Bool, onConsumeFocusRequest: @escaping () -> Void,
         pageCount: Int, pageIndex: Int,
         onClosePanel: @escaping () -> Void, onMinimize: @escaping () -> Void,
         onClosePage: @escaping () -> Void, onPopOut: @escaping () -> Void,
         showSimilar: Bool, similarCount: Int, onToggleSimilar: @escaping () -> Void,
         tags: [ReferenceTag] = [], onRemoveTag: @escaping (UUID) -> Void = { _ in }) {
        self.item = item
        self.shouldFocus = shouldFocus
        self.onConsumeFocusRequest = onConsumeFocusRequest
        self.pageCount = pageCount
        self.pageIndex = pageIndex
        self.onClosePanel = onClosePanel
        self.onMinimize = onMinimize
        self.onClosePage = onClosePage
        self.onPopOut = onPopOut
        self.showSimilar = showSimilar
        self.similarCount = similarCount
        self.onToggleSimilar = onToggleSimilar
        self.tags = tags
        self.onRemoveTag = onRemoveTag
        let existingNote = item.userNote ?? ""
        _noteText          = State(initialValue: existingNote)
        _lastCommittedNote = State(initialValue: existingNote)
        let plain = ClipboardManager.editablePlainText(for: item)
        _editedText = State(initialValue: plain ?? "")
        _savedText  = State(initialValue: plain ?? "")
        let cells = TableCellExtractor.cells(for: item) ?? []
        _editedRows = State(initialValue: cells)
        _savedRows  = State(initialValue: cells)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // Full close — the whole panel, every pinned page in it, not
                // just the current one. On the LEFT, mirroring macOS's own
                // traffic-light convention (red close lives on the left of
                // every window titlebar). Closing just the current page is a
                // separate control, in the content body — see below.
                Button(action: onClosePanel) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(pageCount > 1 ? "Close entire panel (all \(pageCount) references)" : "Close")
                .accessibilityLabel(pageCount > 1 ? "Close entire panel, all \(pageCount) references" : "Close reference panel")

                // Minimize — shrinks the whole panel to the same small corner
                // badge Smart Reference's own "no match" state uses, purely
                // as a manual "get this out of my way for now" action. Click
                // the badge to bring it back, exactly like the automatic one.
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

                // App-affinity auto-surface toggle — a small text label (not
                // an icon), leftmost of the action cluster. Blue when active
                // (the default); click to turn off, remembered for every
                // future pin/panel, not just this one.
                SmartReferenceToggle()

                // Save — appears only once the editable content has changed.
                // Writes the edit back to the ring item itself, so the main
                // popup, main window, and search all show the updated content.
                if isEditableTable && editedRows != savedRows {
                    Button {
                        ClipboardManager.shared.updateItemTable(id: item.id, rows: editedRows)
                        savedRows = editedRows
                    } label: {
                        Text("Save")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Save table edits back to the clipboard item")
                } else if isEditableText && editedText != savedText {
                    Button {
                        ClipboardManager.shared.updateItemText(id: item.id, newText: editedText)
                        savedText = editedText
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

                // Copy button — for editable content this copies the EDITED
                // version, not the original ring item, so edits made here
                // actually make it to the pasteboard.
                Button {
                    if isEditableTable {
                        let flattened = editedRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                        ClipboardManager.shared.pasteTransformed(flattened, restoring: item)
                    } else if isEditableText {
                        ClipboardManager.shared.pasteTransformed(editedText, restoring: item)
                    } else if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == item.id }) {
                        ClipboardManager.shared.pasteItem(at: idx)
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")

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

                // Pop out — detaches THIS reference into its own standalone
                // panel, separate from the shared carousel.
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
            // Only this header bar moves the window (isMovableByWindowBackground
            // is off) — buttons still get their own clicks first since they're
            // drawn on top and hit-test before this background handle does.
            .background(WindowDragHandle())

            if !tags.isEmpty {
                ReferenceTagRow(tags: tags, onRemove: onRemoveTag)
            }

            Divider()

            Group {
                if isEditableTable {
                    EditableTableGrid(rows: $editedRows)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else if isEditableText {
                    TextEditor(text: $editedText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .focused($contentFocused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else {
                    QuickClipPreview(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .onDrag {
                            item.makeItemProvider()
                        }
                }
            }
            // Close just THIS reference — separate from the toolbar's full
            // panel close. Top-trailing corner of the content, alongside a
            // small "n of N" indicator when there's more than one page.
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 6) {
                    if pageCount > 1 {
                        Text("\(pageIndex + 1) of \(pageCount)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
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
                .padding(8)
            }

            Divider()

            // ── Notes area ─────────────────────────────────────────────────
            // Free-form annotation that persists with the item across launches.
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
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }

                ZStack(alignment: .topLeading) {
                    if noteText.isEmpty && !noteFocused {
                        Text("Add a note\u{2026}")
                            .font(.system(size: 11))
                            .foregroundColor(Color.secondary.opacity(0.5))
                            .padding(.horizontal, 4)
                            .padding(.top, 2)
                            .allowsHitTesting(false)
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
                            // Page switched / panel closed mid-debounce —
                            // flush pending text so no typed note is lost.
                            noteCommitTask?.cancel()
                            commitNote(noteText)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .onAppear {
            if shouldFocus {
                if isEditableText { contentFocused = true }
                onConsumeFocusRequest()
            }
        }
    }
}

private struct QuickClipPreview: View {
    let item: ClipboardItem

    // Delegates to the shared ContentPreviewView (defined in ItemPreviewPanel)
    // with the reference-panel chrome — this switch used to be a near-identical
    // copy of the item-preview panel's and drifted from it repeatedly.
    var body: some View {
        ContentPreviewView(item: item, chrome: .reference)
    }
}

// MARK: - Similar Items (inline sidebar)

/// Inline sidebar shown alongside the main content of the SAME QuickClipPanel
/// when "similar items" is toggled — the panel's window grows to make room
/// for it (see resizeForSimilarSidebar), rather than opening a second,
/// disconnected floating window.
/// Hovering (or clicking) a card opens a separate preview panel — the shared
/// ItemPreviewPanel — showing that specific similar item's actual content.
private struct SimilarItemsSidePanelView: View {
    let pinned:      ClipboardItem
    let onPreview:   (ClipboardItem) -> Void
    let onEndPreview: () -> Void
    /// Bound to the parent's state (rather than a locally-seeded copy) so the
    /// "+" button's additions also update the header's count badge — those
    /// used to be two independently-tracked arrays that silently diverged.
    @Binding var similars: [ClipboardItem]

    /// Observed so the "+" menu's candidate list stays live as new items are
    /// captured while the side panel is open (a plain shared-singleton read
    /// would go stale until the view happened to re-render for other reasons).
    @ObservedObject private var manager = ClipboardManager.shared

    /// Anything in the ring not already shown and not the pinned item itself
    /// — what "+" lets the user pick from, most-recent first.
    private var addableItems: [ClipboardItem] {
        let shownIDs = Set(similars.map(\.id) + [pinned.id])
        return manager.items.filter { !shownIDs.contains($0.id) }
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
                    let candidates = addableItems.prefix(20)
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
                                // Click-only, no hover trigger — hovering
                                // over cards while scanning the list no
                                // longer pops a preview open unasked.
                                // Clicking a different card still swaps the
                                // preview to that one.
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
            // Type label
            HStack(spacing: 4) {
                Image(systemName: similar.iconName)
                    .font(.system(size: 9))
                    .foregroundColor(.accentColor)
                Text(similar.typeLabel)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }

            // Content with word-level diff highlight
            diffView
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            // Paste button
            Button {
                if let idx = ClipboardManager.shared.items.firstIndex(where: { $0.id == similar.id }) {
                    ClipboardManager.shared.pasteItem(at: idx)
                }
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
        // Was a fixed 150×130 box floating off to one side — now fills the
        // panel's actual width (and centers within it, via the parent
        // VStack's default center alignment) instead of leaving dead space.
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

/// Renders `compareText` with words that don't appear in `baseText` highlighted
/// in accent colour so differences jump out at a glance.
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

// MARK: - Editable table grid (reference panel table editor)

/// Editable version of MiniTablePreview's read-only grid — every cell is a
/// real TextField, backed by the caller's `rows` binding. Used by the
/// reference panel when the pinned item's content is table-shaped, so the
/// user can correct a cell or two and Save writes real HTML `<table>`
/// markup back to the ring item (see ClipboardManager.updateItemTable).
private struct EditableTableGrid: View {
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
