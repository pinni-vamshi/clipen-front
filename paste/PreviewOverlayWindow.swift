import AppKit
import SwiftUI

final class PreviewOverlayWindow: NSObject, NSPopoverDelegate {
    private var wantsVisible = false

    /// Fired every time the popup actually goes away, regardless of which
    /// call site triggered it — several close paths (paste-and-dismiss,
    /// escape, etc.) call `hide()` directly without going through
    /// `ClipboardManager.dismissPreview()`, so per-call-site cleanup was
    /// easy to miss. Hooking `hide()` itself guarantees it always runs.
    var onHide: (() -> Void)?

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
            onHide?()
        }
    }

    private var visibleRowCount: Int = 5

    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()

    var isVisible: Bool { wantsVisible && popover.isShown }
    var frame: NSRect {
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    override init() {
        anchorPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        anchorPanel.isOpaque = false
        anchorPanel.backgroundColor = .clear
        anchorPanel.hasShadow = false
        anchorPanel.ignoresMouseEvents = true
        anchorPanel.level = .popUpMenu
        anchorPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        anchorPanel.contentView = anchorView

        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    /// The dynamic hint row — genuinely separate from the popup itself (its
    /// own borderless, background-less panel), not a header baked into the
    /// popup's own view. The popup's own content is search + categories +
    /// rows, nothing else. Owned here so `show()`/`hide()` stay the single
    /// choke points for keeping the two in sync.
    private let hintOverlay = PopupHintOverlay()

    func show() {
        wantsVisible = true
        showAnchored(to: NSEvent.mouseLocation)
    }

    func hide() {
        let wasVisible = isVisible
        wantsVisible = false
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
        hintOverlay.hide()
        if wasVisible { onHide?() }
    }

    private func showAnchored(to anchor: NSPoint) {
        let rowH: CGFloat    = 72
        let searchH: CGFloat = 34
        let filterH: CGFloat = 36
        let footerH: CGFloat = 26
        let margin: CGFloat  = 12
        let maxVisible: Int  = 5

        let screen: NSRect = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let slots = min(maxVisible, max(1,
            Int((screen.height - margin * 2 - searchH - filterH - footerH) / rowH)))
        let bodyH = searchH + filterH + CGFloat(slots) * rowH + footerH

        visibleRowCount = slots

        let aboveFits = (anchor.y - bodyH - 6) >= screen.minY + margin
        let preferredEdge: NSRectEdge = aboveFits ? .maxY : .minY

        let popoverView = PopoverPreviewView(visibleCount: slots)
        popover.contentSize = NSSize(width: 420, height: bodyH)
        if let hostingController = popover.contentViewController as? NSHostingController<PopoverPreviewView> {
            hostingController.rootView = popoverView
        } else {
            popover.contentViewController = NSHostingController(rootView: popoverView)
        }

        // `showAnchored` is only ever reached via `show()`, and every caller
        // of `show()` already checks the popup is currently closed before
        // calling it — so `popover.isShown` reading true here is never a
        // legitimate "it's already open for this session" case. It's a
        // stale flag lagging an in-flight close animation from the PREVIOUS
        // session (NSPopover's close is animated; `isShown` can still read
        // true for a moment after a close was requested but hasn't visually
        // settled). Trusting it here used to reposition the hint row and
        // return WITHOUT ever calling `.show()` again — the hints would
        // appear, but the ring itself would silently never (re)appear until
        // a second attempt, once the flag had finally caught up. Forcing a
        // close first guarantees a real `.show()` always follows below,
        // regardless of what the flag said going in.
        if popover.isShown {
            popover.performClose(nil)
        }

        anchorPanel.setFrame(NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1), display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        WakeGuard.afterWakeSettle { [weak self, popover, anchorView] in
            guard let self else { return }
            popover.animates = false
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
            popover.animates = true
            popover.clipenAnimateIn()
            // The popover's real on-screen frame only exists once it's actually
            // shown — position the hint row relative to that, one runloop turn
            // later, rather than guessing where it'll land.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.hintOverlay.show(above: self.frame)
            }
        }
    }

    /// Prefers the row's REAL measured on-screen position (reported by
    /// PopoverPreviewView's GeometryReader via `SelectedRowFramePreferenceKey`
    /// — see `ClipboardManager.selectedRowMeasuredFrame`) over computing a
    /// guess. The formula this replaced modeled the row area as if it
    /// shrank to fit however many items were actually in the list; in
    /// reality the row area is always a fixed height (`rowH *
    /// visibleRowCount`, set once when the popup opens) with its real
    /// SwiftUI content top-anchored inside it — so for any collection
    /// shorter than a full screen's worth of rows, the formula and the
    /// real layout disagreed, sometimes by several rows' worth of pixels.
    /// The formula is kept only as a bootstrap fallback for the narrow
    /// window before SwiftUI has measured anything yet (the very first
    /// call right as the popup opens).
    func selectedRowAnchorPoint(selectedIndex: Int, totalItems: Int) -> NSPoint {
        guard totalItems > 0 else { return NSPoint(x: frame.maxX, y: frame.midY) }

        if let measured = ClipboardManager.shared.selectedRowMeasuredFrame,
           let view = popover.contentViewController?.view, let win = view.window {
            let screenRect = win.convertToScreen(view.convert(measured, to: nil))
            return NSPoint(x: frame.maxX, y: screenRect.midY)
        }

        let win: CGFloat    = CGFloat(min(max(1, visibleRowCount), totalItems))
        let rowH: CGFloat   = 72
        let footerH: CGFloat = 26
        let rowsBottomY     = frame.minY + footerH

        let i               = CGFloat(selectedIndex)
        let total           = CGFloat(totalItems)
        let desiredScrollTopRows = i + 0.5 - win / 2
        let maxScrollTopRows     = max(0, total - win)
        let scrollTopRows   = max(0, min(desiredScrollTopRows, maxScrollTopRows))
        let rowCenterY      = rowsBottomY + rowH * (win - i - 0.5 + scrollTopRows)

        return NSPoint(x: frame.maxX, y: rowCenterY)
    }
}

/// Reports the currently-selected ring row's real frame (in SwiftUI's
/// `.global` space, i.e. relative to the popover's own hosting view) up to
/// `PopoverPreviewView`, which forwards it to `ClipboardManager` — see
/// `selectedRowAnchorPoint` above for why this replaced a hand-computed
/// approximation.
private struct SelectedRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

struct PopoverPreviewView: View {

    let visibleCount: Int

    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var pro = ProGate.shared
    private let auth = AuthManager.shared
    /// Shared with every PopoverRow so the selection box can travel between
    /// them via matchedGeometryEffect — see PopoverRow's background.
    @Namespace private var selectionNamespace

    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    private static let rowH: CGFloat = 72

    var body: some View {
        // Once the free trial is spent, the popup itself becomes the paywall —
        // same window, same ⌘V trigger, different contents. Deliberately not a
        // separate alert: the popup is the thing the user reached for, so it's
        // where the message belongs.
        if !pro.isUnlocked {
            SubscribeGateView()
        } else {
            VStack(spacing: 0) {
                popupSearchBar
                categoryStrip
                firstCycleHint
                // A little clearance below this divider — the selected row's
                // scale-up (see PopoverRow.body) grows its top edge upward too,
                // and with zero gap here the very first row could crowd right
                // against the divider when it's the selected one.
                Divider().padding(.bottom, 4)
                rowArea
                Divider()
                footer
            }
            .onPreferenceChange(SelectedRowFramePreferenceKey.self) { frame in
                guard manager.selectedRowMeasuredFrame != frame else { return }
                manager.selectedRowMeasuredFrame = frame
                // The panel that first opened (e.g. right when selectedIndex
                // changed) necessarily used whatever anchor was available at
                // that synchronous moment — which, on a fresh selection, is
                // one render behind this real measurement. Repositioning here
                // the instant the real frame lands corrects it within the same
                // render pass instead of leaving it wrong until the next step.
                manager.repositionAnchoredSidePanelForMeasuredRow()
            }
        }
    }

    private var popupSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(manager.popupSearchQuery.isEmpty
                                 ? (manager.isSearchActive ? .accentColor.opacity(0.7) : .secondary.opacity(0.4))
                                 : .accentColor)

            if manager.popupSearchQuery.isEmpty {
                HStack(spacing: 0) {
                    Text(manager.isSearchActive ? "Type to search\u{2026}" : "Press F to search")
                        .font(.system(size: 12))
                        .foregroundColor(manager.isSearchActive ? .secondary.opacity(0.6) : .secondary.opacity(0.35))
                    if manager.isSearchActive { BlinkingCursor() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    Text(manager.popupSearchQuery)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                    if manager.isSearchActive { BlinkingCursor() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    manager.popupSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search (Esc)")
            }

            // Active collection — the scope everything below is filtered to.
            CollectionChip(name: manager.activeCollection)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(manager.popupSearchQuery.isEmpty && !manager.isSearchActive
                    ? Color.primary.opacity(0.03)
                    : Color.accentColor.opacity(0.06))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .overlay {
            if manager.isSearchActive {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                    .padding(2)
            }
        }
    }

    private enum CategoryChipID: Hashable {
        case all
        case tag(ClipboardTag)
    }

    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    TagFilterChip(tag: nil, selected: manager.popupTagFilter == nil) {
                        manager.popupTagFilter = nil
                    }
                    .id(CategoryChipID.all)
                    ForEach(manager.availableTags, id: \.self) { tag in
                        TagFilterChip(
                            tag: tag,
                            selected: manager.popupTagFilter == tag
                        ) {
                            manager.popupTagFilter = tag
                        }
                        .id(CategoryChipID.tag(tag))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .onChange(of: manager.popupTagFilter) { _, newValue in
                let target: CategoryChipID = newValue.map(CategoryChipID.tag) ?? .all
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(target, anchor: .center)
                }
            }
        }
        .frame(height: 36)
        .background(Color.primary.opacity(0.02))
    }

    @ViewBuilder
    private var firstCycleHint: some View {
        if manager.showFirstCycleHint {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Tip: Tap X to transform the highlighted item")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(LinearGradient(colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                       startPoint: .leading, endPoint: .trailing))
            .transition(.opacity)
        }
    }

    private var rowArea: some View {
        normalRingArea
            .frame(height: Self.rowH * CGFloat(visibleCount), alignment: .top)
    }

    private var normalRingArea: some View {
        Group {
            if items.isEmpty {
                Text("No items with this tag")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        // Drives the matchedGeometryEffect box's travel
                        // between rows. Needed here, not just on each row's
                        // own `.animation(value: isSelected)`: selectedIndex
                        // changes originate outside SwiftUI (keyboard
                        // handling in ClipboardManager), so there's no
                        // withAnimation at the source — this ancestor-level
                        // animation is what gives the transition a
                        // consistent curve to interpolate under. Same spring
                        // as each row's own scale bounce, so the box's
                        // travel and the landing row's pop stay in sync.
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                PopoverRow(item: item, index: idx,
                                           isSelected: idx == selectedIndex,
                                           markOrder: manager.markOrder(for: item.id),
                                           showColorSwatches: manager.showColorSwatches,
                                           selectionNamespace: selectionNamespace,
                                           shakeGeneration: manager.editDeniedShake?.itemID == item.id
                                               ? manager.editDeniedShake?.generation ?? 0 : 0)
                                    .equatable()
                                    .id(item.id)
                                    // Reports the SELECTED row's real frame
                                    // up via SelectedRowFramePreferenceKey —
                                    // applied after .equatable() so it isn't
                                    // skipped by that optimization, and
                                    // conditioned on idx == selectedIndex so
                                    // only one row's GeometryReader ever
                                    // reports a non-nil value.
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.preference(
                                                key: SelectedRowFramePreferenceKey.self,
                                                value: idx == selectedIndex ? geo.frame(in: .global) : nil)
                                        }
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        manager.uiSelectItem(at: idx)
                                        manager.pasteItemKeepingPopupOpen(id: item.id)
                                    }
                                    .onTapGesture(count: 1) {
                                        let mods = NSEvent.modifierFlags
                                        if mods.contains(.shift) {
                                            manager.uiRangeSelectItem(to: idx)
                                            return
                                        }
                                        if mods.contains(.command) {
                                            manager.uiToggleSelectItem(at: idx)
                                            return
                                        }
                                        manager.uiSelectItem(at: idx)
                                        manager.uiPreviewSelectedItem()
                                    }
                                if idx < items.count - 1 {
                                    Divider().padding(.leading, 38).opacity(0.25)
                                }
                            }
                        }
                        // Non-bouncy on purpose: a spring's whole defining
                        // trait is that it overshoots the target and wobbles
                        // back before settling — that oscillation is exactly
                        // what read as the box "moving up and down" instead
                        // of traveling in one clean motion. easeInOut still
                        // gives the box's matchedGeometryEffect travel a
                        // smooth accelerate-then-decelerate feel (the "3D
                        // lift" quality), just with no overshoot/wobble.
                        .animation(.easeInOut(duration: 0.16), value: selectedIndex)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        guard items.indices.contains(newIdx) else { return }
                        // Same curve and duration as the box's travel above
                        // (LazyVStack's `.animation(value: selectedIndex)`)
                        // — so the box gliding to the new row and the list
                        // scrolling to reveal it move as one continuous
                        // motion, neither one bouncing independently of
                        // the other.
                        withAnimation(.easeInOut(duration: 0.16)) {
                            proxy.scrollTo(items[newIdx].id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard items.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                    }
                    .onChange(of: manager.popupOpenGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text(items.isEmpty
             ? "0 of 0"
             : "\(min(selectedIndex + 1, items.count)) of \(items.count)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

private struct PopoverDragPreview: View {
    let item:        ClipboardItem
    let markedCount: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: item.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            if markedCount > 1 {
                Text("\(markedCount) items")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                ZStack {
                    ForEach(0..<min(markedCount, 3), id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.3 - Double(i) * 0.08))
                            .frame(width: 18, height: 14)
                            .offset(x: CGFloat(i) * 2, y: CGFloat(i) * -2)
                    }
                }
                .frame(width: 24, height: 18)
            } else {
                Text(item.typeLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [Color(red: 0.11, green: 0.11, blue: 0.12),
                         Color(red: 0.22, green: 0.22, blue: 0.24)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 3)
    }
}

private struct MultiItemDragSource: NSViewRepresentable {
    let writers: [NSPasteboardWriting]

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.writers = writers
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.writers = writers
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var writers: [NSPasteboardWriting] = []
        private var mouseDownPoint: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { self }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint, !writers.isEmpty else { return }
            let current = convert(event.locationInWindow, from: nil)
            guard hypot(current.x - start.x, current.y - start.y) > 4 else { return }
            mouseDownPoint = nil

            let draggingItems: [NSDraggingItem] = writers.map { writer in
                let dragItem = NSDraggingItem(pasteboardWriter: writer)
                dragItem.setDraggingFrame(bounds, contents: nil)
                return dragItem
            }
            beginDraggingSession(with: draggingItems, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .every
        }
    }
}

struct PopoverRow: View, Equatable {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool
    let markOrder:  Int?
    let showColorSwatches: Bool
    /// Shared across every row in the list — lets the ONE selection box
    /// below travel and resize between rows via `matchedGeometryEffect`
    /// instead of each row independently drawing its own static
    /// pop-in/pop-out box. A `Namespace.ID` never changes after creation,
    /// so it's safe to leave out of `==` below.
    let selectionNamespace: Namespace.ID
    /// Nonzero (and changed) means "shake now" — a refused action (E on a
    /// non-editable item) on this row. 0 for every row except the one that
    /// was just refused.
    var shakeGeneration: Int = 0

    static func == (l: PopoverRow, r: PopoverRow) -> Bool {
        l.item.id == r.item.id &&
        l.index == r.index &&
        l.isSelected == r.isSelected &&
        l.markOrder == r.markOrder &&
        l.showColorSwatches == r.showColorSwatches &&
        l.shakeGeneration == r.shakeGeneration &&
        l.item.isPinned == r.item.isPinned &&
        l.item.urlTitle == r.item.urlTitle &&
        l.item.diffBadge == r.item.diffBadge &&
        l.item.userNote == r.item.userNote &&
        l.item.metadataSummary == r.item.metadataSummary
    }

    @State private var shakeOffsetX: CGFloat = 0

    /// Classic macOS "refused" shake: a few quick alternating nudges settling
    /// back to center — no persistent popup, just this plus the denied tone.
    private func runShake() {
        let step: TimeInterval = 0.045
        let amounts: [CGFloat] = [8, -8, 6, -6, 3, -3, 0]
        for (i, amount) in amounts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
                withAnimation(.easeInOut(duration: step)) { shakeOffsetX = amount }
            }
        }
    }

    private static let minRowHeight: CGFloat = 56
    private static let maxRowHeight: CGFloat = 104

    /// Horizontal inset on each side of the selection box, and how much the
    /// selected row pops. This inset applies to EVERY row, selected or not —
    /// so it has to stay small (unselected rows shouldn't carry extra
    /// left/right margin just to make room for a scale-up that only the
    /// selected row uses).
    private static let horizontalInset: CGFloat = 12
    /// Only `rowContent` scales by this — the box, rail, and divider stay
    /// completely static. No containment math needed here (unlike when the
    /// whole row used to scale): rowContent already sits inside the row's
    /// fixed layout bounds, so scaling just it draws slightly outside its
    /// own bounds without ever approaching the popup's edge.
    private static let selectedScale:   CGFloat = 1.05

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            verticalRail
            // Vertical divider — turns green and thickens when the row is
            // marked, a thin neutral hairline otherwise.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(markOrder != nil ? Self.markedTint : Color.secondary.opacity(0.25))
                .frame(width: markOrder != nil ? 3 : 1)
                .frame(maxHeight: .infinity)
            rowContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                // Hard block, not just `.animation(nil, value:)` (which only
                // cancels animation tied to one specific value) — this row's
                // text must never animate its own reflow no matter what
                // ambient animation is active around it: not the selection
                // box's travel, not the scroll's ease-out, not a newly-
                // materializing row's own first-appearance transaction as
                // LazyVStack scrolls it into range. `.transaction` zeroes
                // out inherited animation for this subtree entirely.
                .transaction { $0.animation = nil }
                // The pop lives HERE, on the content only — not the row, not
                // the box, not the rail/divider — so only the icon/text
                // visibly elevates while everything else around it stays
                // completely static. Applied outside the `.transaction`
                // block above, with its own explicit local animation, so
                // this scale still animates smoothly even though the block
                // it wraps deliberately blocks inherited animation.
                .scaleEffect(isSelected ? Self.selectedScale : 1.0)
                .animation(.easeInOut(duration: 0.16), value: isSelected)
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
        .frame(minHeight: Self.minRowHeight, maxHeight: Self.maxRowHeight)
        // The blue selection box draws at this view's bounds and never
        // scales — it's the one fixed, static element (rail and divider
        // are the same). Only the SELECTED row ever hosts it, tagged with
        // the shared namespace — SwiftUI interpolates its frame between
        // whichever two rows hold that tag across a selection change,
        // producing one box that visibly travels to the new row rather
        // than one box disappearing while a separate one pops in
        // elsewhere. Needs a real "from" view still on screen to
        // interpolate from — LazyVStack only keeps nearby rows
        // materialized, so a selection jump far outside the currently-
        // rendered range falls back to a plain cross-fade for that jump.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor)
                    .matchedGeometryEffect(id: "selectionBox", in: selectionNamespace)
            }
        }
        .padding(.horizontal, Self.horizontalInset)
        .offset(x: shakeOffsetX)
        .overlay(alignment: .topTrailing) { trailingIndicators }
        .overlay {
            if ClipboardManager.shared.markedItemIDs.count > 1 {
                MultiItemDragSource(
                    writers: ClipboardManager.shared.orderedMarkedItems.map { $0.makePasteboardWriter() })
            }
        }
        .onDrag {
            item.makeItemProvider()
        } preview: {
            PopoverDragPreview(item: item,
                               markedCount: ClipboardManager.shared.markedItemIDs.count)
        }
        .onChange(of: shakeGeneration) { _, new in
            guard new > 0 else { return }
            runShake()
        }
    }

    private var verticalRail: some View {
        railBadge
            .frame(width: isSelected || markOrder != nil ? 22 : 18)
            .frame(maxHeight: .infinity, alignment: .center)
            .padding(.vertical, 2)
            .clipped()
    }

    private static let markedTint = Color(red: 0.20, green: 0.78, blue: 0.35)

    @ViewBuilder
    private var railBadge: some View {
        if let order = markOrder {
            Text("\(order)")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Self.markedTint, in: Circle())
                .help("Marked #\(order) for multi-paste — hold V to toggle")
        } else if isSelected {
            Image(systemName: item.primaryTag.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.45), in: Circle())
        } else if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
                .help("Pinned — hold P to unpin")
        } else {
            Text(tagLabelText)
                .font(.system(size: 8, weight: .black))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary.opacity(0.75))
                .frame(width: 88, alignment: .center)
                .rotationEffect(.degrees(-90))
        }
    }

    private var tagLabelText: String {
        let visible = item.tags.prefix(4)
        let labels = visible.map { String(localized: String.LocalizationValue($0.label)) }
        let suffix = item.tags.count > 4 ? ", +\(item.tags.count - 4)" : ""
        return labels.joined(separator: ", ") + suffix
    }

    @ViewBuilder
    private var trailingIndicators: some View {
        HStack(spacing: 6) {
            // The diff badge is intentionally NOT shown in the popup anymore —
            // the exact difference is surfaced in the preview panel's insights
            // strip instead (see ItemPreviewPanel). Keeping the popup row clean.
            if item.userNote != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .help("This item has a note")
            }
        }
        .padding(.top, 8).padding(.trailing, 14)
    }

    @ViewBuilder
    private var rowContent: some View {
        switch item.content {
        case .text(let rawStr):
            let str = rawStr.displayTrimmedLeading
            if item.tags.contains(.table) {
                PopoverMiniTable(text: str)
            } else if let title = item.urlTitle {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundColor(.primary)
                    Text(str).font(.system(size: 10, design: .monospaced)).lineLimit(1).foregroundColor(.primary.opacity(0.6))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    if showColorSwatches, let c = item.detectedColor {
                        Circle().fill(Color(nsColor: c)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    }
                    Text(str).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .richText(_, plain: let rawPlain), .rtfd(_, plain: let rawPlain):
            let plain = rawPlain
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .displayTrimmedLeading
            HStack(alignment: .top, spacing: 8) {
                if let embedded = EmbeddedImageExtractor.firstImage(for: item) {
                    Image(nsImage: embedded)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    if !plain.isEmpty {
                        Text(plain).font(.system(size: 12)).lineLimit(3).foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let cells = TableCellExtractor.cells(for: item) {
                        MiniTablePreview(cells: cells)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .html(_, let rawPlain):
            let plain = rawPlain.displayTrimmedLeading
            VStack(alignment: .leading, spacing: 2) {
                Text(plain).font(.system(size: 12)).lineLimit(3).foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let cells = TableCellExtractor.cells(for: item) {
                    MiniTablePreview(cells: cells)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .file(let url):
            HStack(spacing: 6) {
                fileThumbnail(url, size: 28)
                Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .files(let urls):
            HStack(spacing: 6) {
                if let first = urls.first(where: FileKindDetector.isImageFile) {
                    fileThumbnail(first, size: 28)
                } else {
                    Image(systemName: "doc.on.doc").frame(width: 14, height: 14)
                }
                Text("\(urls.count) files").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let img, let data, _):
            Image(nsImage: ItemThumbnailCache.shared.thumbnail(forData: data, key: item.id.uuidString) ?? img)
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .svg(let src):
            Text(src).font(.system(size: 11, design: .monospaced)).lineLimit(2)
                .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
        case .blob(let typeMap):
            VStack(alignment: .leading, spacing: 2) {
                Text("Private clipboard data")
                    .font(.system(size: 11, weight: .medium)).foregroundColor(.primary)
                Text(typeMap.keys.sorted().joined(separator: "  ·  "))
                    .font(.system(size: 9, design: .monospaced)).lineLimit(1).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .group(let items):
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 13)).foregroundColor(.indigo)
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Group · \(items.count) items")
                        .font(.system(size: 11, weight: .medium)).foregroundColor(.primary).lineLimit(1)
                    Text(items.prefix(4).map { $0.primaryTag.label }.joined(separator: " · "))
                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func fileThumbnail(_ url: URL, size: CGFloat) -> some View {
        if FileKindDetector.isImageFile(url) {
            CachedFileThumbnail(url: url, size: size)
        } else {
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                .resizable().frame(width: size, height: size)
        }
    }
}

private struct PopoverMiniTable: View {
    let text: String

    private var rows: [[String]] {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return [] }
        let delim: Character = text.contains("\t") ? "\t" : ","
        return lines.prefix(2).map { line in
            line.split(separator: delim, omittingEmptySubsequences: false)
                .prefix(4).map { String($0.prefix(14)) }
        }
    }

    var body: some View {
        let rows = self.rows
        if rows.isEmpty {
            Text(text).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 3) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                                .font(.system(size: 9, design: .monospaced))
                                .lineLimit(1)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(
                                    rowIdx == 0
                                        ? Color.mint.opacity(0.15)
                                        : Color.primary.opacity(0.05),
                                    in: RoundedRectangle(cornerRadius: 3)
                                )
                                .frame(maxWidth: 64, alignment: .leading)
                        }
                        if row.count > 4 {
                            Text("…").font(.system(size: 9)).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The collection the popup is currently scoped to, shown at the right edge of
/// the search bar. `nil` is the "All" view.
struct CollectionChip: View {
    let name: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.full")
                .font(.system(size: 9, weight: .semibold))
            Text(name ?? String(localized: "All"))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.secondary.opacity(0.85))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.primary.opacity(0.07))
        )
        .help("Current collection — press 1–9 to switch")
    }
}

struct TagFilterChip: View {
    let tag:     ClipboardTag?
    let selected: Bool
    var customIcon:  String? = nil
    var customLabel: String? = nil
    let action: () -> Void

    private var icon:  String { customIcon  ?? tag?.icon  ?? "clock" }
    private var label: String { customLabel ?? tag?.label ?? "Recents" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(LocalizedStringKey(label)).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule(style: .continuous)
                .fill(selected ? AnyShapeStyle(Color(hex: "#4E8DF7"))
                               : AnyShapeStyle(Color.primary.opacity(0.08))))
            .overlay(Capsule(style: .continuous)
                .stroke(selected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// One entry in the popup's dynamic "what can I do right now" hint row —
/// `id` is what drives the insertion/removal animation when the set changes
/// (e.g. "hold V - Mark" swapping out for "G - Group" once 2+ items are
/// marked), so it must be stable across re-renders of the SAME logical hint.
struct DynamicHint: Identifiable, Equatable {
    let id: String
    let key: String
    let label: String
}

/// Each hint is its own pill (rounded capsule background) — kept
/// deliberately small (smaller than the first attempt at this) so it fits
/// the available row height without needing more outer padding to avoid
/// clipping.
struct DynamicHintText: View {
    let key: String
    let label: String
    /// True for the instant the real key this hint describes is actually
    /// held down — flashes the pill blue so it reads as "you're doing that
    /// right now", not just a static legend.
    var isPressed: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(isPressed ? .white : .primary.opacity(0.85))
                .lineLimit(1).fixedSize()
            Text(label)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(isPressed ? .white.opacity(0.9) : .secondary)
                .lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 7.5)
        .padding(.vertical, 3.5)
        // Solid, not translucent — the overlay panel itself has no window
        // backing (isOpaque = false), so a low-opacity fill here let the
        // desktop/whatever's behind Clipen show straight through the pill.
        .background(isPressed ? Color.accent : Color.surfaceHi, in: Capsule())
        .overlay(Capsule().stroke(isPressed ? Color.clear : Color.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}

/// A small, genuinely separate, background-less panel that floats directly
/// above the ring popup showing "what can I do right now." Deliberately NOT
/// part of the popup's own window/view hierarchy — the popup's own content
/// is search + categories + rows only. Owned and driven entirely by
/// `PreviewOverlayWindow.show()`/`hide()`, which are already the single
/// choke points for the popup's own visibility.
final class PopupHintOverlay {
    private let panel: NSPanel
    // Was 26 — right at the edge of what the text itself needs with zero
    // vertical padding around it, which is why it read as clipped top and
    // bottom, not just at the sides.
    private static let height: CGFloat = 38
    // Inset from the popup's own edges (NOT wider than the popup — an
    // earlier attempt made this panel wider than the popup below it, which
    // read as the hint row spilling past the popup's own boundary instead
    // of sitting contained within it). Centered under the popup.
    private static let horizontalInset: CGFloat = 14

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
    }

    /// `popupFrame` is the ring popup's actual current on-screen frame —
    /// this sits directly above it, same width, same horizontal position.
    func show(above popupFrame: NSRect) {
        if panel.contentViewController == nil {
            panel.contentViewController = NSHostingController(rootView: PopupHintRow())
        }
        let width = popupFrame.width - Self.horizontalInset * 2
        let frame = NSRect(x: popupFrame.minX + Self.horizontalInset, y: popupFrame.maxY + 4,
                           width: width, height: Self.height)
        panel.setFrame(frame, display: false)
        if !panel.isVisible { panel.orderFront(nil) }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

/// Content of the separate hint overlay above. Ordered by priority, not by
/// when each action was added — the most state-specific/important action
/// for whatever's happening right now leads, universally-available ones
/// (Preview, Transform, Next) trail behind it.
private struct PopupHintRow: View {
    @ObservedObject private var manager = ClipboardManager.shared
    private let auth = AuthManager.shared

    private var hints: [DynamicHint] {
        guard manager.showPopupInteractionHints, !manager.isInlineEditing,
              !manager.popupPinnedOpen else { return [] }

        let markedCount = manager.markedItemIDs.count
        let previewOpen = manager.isItemPreviewVisible
        var hints: [DynamicHint] = []

        // Highest priority: marking 2+ items unlocks Group, the one action
        // that only exists in this state — it always leads when active.
        if markedCount > 1 {
            hints.append(DynamicHint(id: "g-group", key: "G", label: "Group"))
        }
        // Next: once preview is already open, Pin is the natural next move —
        // it only makes sense in this state, so it leads over the baseline
        // preview/transform pair (but still behind an active Group).
        if previewOpen {
            hints.append(DynamicHint(id: "space2-pin", key: "Space ×2", label: "Pin"))
            hints.append(DynamicHint(id: "space-close", key: "Space", label: "Close preview"))
        } else {
            hints.append(DynamicHint(id: "space-preview", key: "Space", label: "Preview"))
        }
        if auth.transformsEnabled {
            hints.append(DynamicHint(id: "x-transform", key: "X", label: "Transform"))
        }
        // Only teach "hold V to mark" while nothing's marked yet — once
        // Group has already taken the lead slot, repeating the mark hint
        // here is redundant.
        if markedCount <= 1 {
            hints.append(DynamicHint(id: "holdv-mark", key: "hold V", label: "Mark"))
        }
        hints.append(DynamicHint(id: "v-next", key: "V", label: "Next"))
        return Array(hints.prefix(4))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(hints) { hint in
                    DynamicHintText(key: hint.key, label: hint.label, isPressed: isPressed(hint))
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.85)),
                            removal: .opacity.combined(with: .scale(scale: 0.85))))
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.75), value: hints)
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Maps each hint back to the real, live key-state the event tap already
    /// tracks (`popupHintV`/`popupHintX`/… synced from actual keydown/keyup),
    /// so the pill lights up in step with the real keystroke instead of only
    /// existing as a static legend.
    private func isPressed(_ hint: DynamicHint) -> Bool {
        switch hint.id {
        case "g-group":       return manager.popupHintG
        case "space2-pin",
             "space-close",
             "space-preview": return manager.popupHintSpace || manager.popupHintSpaceDoubleTap
        case "x-transform":   return manager.popupHintX || manager.popupHintXHold
        case "holdv-mark":    return manager.popupHintVMark
        case "v-next":        return manager.popupHintV
        default:              return false
        }
    }
}

struct FlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let key:   String
    let label: String
    var enabled:  Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? Self.activeColor : .primary)
                .lineLimit(1).fixedSize()
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? Self.activeColor : .secondary)
                .lineLimit(1).fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}


extension NSPopover {
    func clipenAnimateIn(duration: TimeInterval = 0.17) {
        guard let view = contentViewController?.view else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [fade, scale]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "clipenPopIn")
    }
}
