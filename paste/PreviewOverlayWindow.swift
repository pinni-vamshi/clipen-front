import AppKit
import SwiftUI

// MARK: - Real system NSPopover, anchored through an invisible helper panel
//
// This used to be a hand-drawn NSPanel: a manually clipped RoundedRectangle,
// a custom NSVisualEffectView wrapper, a hand-painted triangle for the arrow,
// and no entrance animation. All of that was an approximation of the native
// Look Up / Quick Look popover chrome — never the real thing.
//
// NSPopover IS the real thing: AppKit draws the rounded box, the arrow, the
// vibrancy, and — the part no amount of custom SwiftUI can replicate — the
// native pop-in/pop-out animation (NSPopover.animates), for free.
//
// The catch: NSPopover.show(relativeTo:of:preferredEdge:) can only anchor to
// a view inside ONE OF THIS APP'S OWN windows — never to a caret rect living
// inside a completely different process (Safari, Notes, Mail…). The fix is
// an invisible, non-activating 1×1 helper panel positioned exactly at the
// caret point; the popover anchors to a view inside THAT panel, so on screen
// it still appears exactly where the caret is, in any app.
final class PreviewOverlayWindow: NSObject, NSPopoverDelegate {
    /// True from show until hide — closes the animating-in race where hide()
    /// finds popover.isShown still false, skips the close, and the popup
    /// finishes presenting as an orphan after it was already dismissed.
    private var wantsVisible = false

    func popoverDidShow(_ notification: Notification) {
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
    }

    private var visibleRowCount: Int = 5

    /// Invisible, click-through, non-activating helper window. Its only job
    /// is to sit at the caret's screen location so the popover has a view of
    /// ours to anchor to. `.nonactivatingPanel` is the same style mask the
    /// old hand-built panel used — it's what keeps showing this popover from
    /// stealing keyboard focus away from whatever app you're pasting into.
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()

    /// `wantsVisible` is ANDed in because NSPopover's close is animated:
    /// popover.isShown keeps returning true until the close animation
    /// finishes, ~0.2s after hide() was called. dismissPreview() resets
    /// @Published state right after hiding, and those didSets check
    /// `previewWindow.isVisible` — a stale true there re-showed the item
    /// preview panel that had just been dismissed. Intent flips instantly.
    var isVisible: Bool { wantsVisible && popover.isShown }
    /// The popup CONTENT's actual on-screen rect once shown — used by
    /// TransformPanel/ItemPreviewPanel anchoring and by the row-anchor math
    /// in selectedRowAnchorPoint. Deliberately NOT the popover window's
    /// frame: that includes AppKit's arrow/shadow chrome padding, which
    /// shifted every row-anchor calculation by the chrome delta.
    var frame: NSRect {
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    /// The popover's own backing NSWindow, if currently shown. Lets the
    /// event tap tell "one of Clipen's OTHER windows (main window, reference
    /// panel, …) is key" apart from "the ring popup itself happens to be
    /// key" — only the former should suppress the popup's own key handling.
    var window: NSWindow? { popover.contentViewController?.view.window }

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

        // .applicationDefined: we drive show/close ourselves (⌘ release, Esc,
        // paste) — the same explicit lifecycle the old panel had. .transient
        // would auto-close on outside clicks/losing key, which doesn't fit
        // how the rest of Clipen manages this popup.
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    /// Show popup anchored at the mouse cursor's current screen position.
    /// This used to try IMK, then Accessibility-API caret lookup, then fall
    /// back to the mouse only as a last resort — removed entirely. Both of
    /// those required cooperation the target app frequently didn't actually
    /// provide (IMK needs the user to manually enable "Clipen" as an input
    /// source; AX caret bounds are unreliable or plain unimplemented in a lot
    /// of custom/Electron/web-rendered text controls), so the popup would
    /// silently fall back to the cursor anyway in exactly the cases it
    /// mattered — just with extra unreliable machinery in between. One
    /// position, always correct by definition: wherever the cursor is.
    func show() {
        wantsVisible = true
        showAnchored(to: NSEvent.mouseLocation)
    }

    func hide() {
        wantsVisible = false
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
    }

    // MARK: - Positioning

    private func showAnchored(to anchor: NSPoint) {
        let rowH: CGFloat    = 72
        let headerH: CGFloat = 80
        let searchH: CGFloat = 34
        let filterH: CGFloat = 36
        let footerH: CGFloat = 26
        let margin: CGFloat  = 12
        let maxVisible: Int  = 5

        let screen: NSRect = NSScreen.screens.first(where: { $0.frame.contains(anchor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let slots = min(maxVisible, max(1,
            Int((screen.height - margin * 2 - headerH - searchH - filterH - footerH) / rowH)))
        let bodyH = headerH + searchH + filterH + CGFloat(slots) * rowH + footerH

        visibleRowCount = slots

        // Prefer showing above the cursor (arrow points down at it); fall back
        // to below if there isn't room above. NSPopover handles the final
        // on-screen clamping/flip itself once given a preferred edge.
        let aboveFits = (anchor.y - bodyH - 6) >= screen.minY + margin
        let preferredEdge: NSRectEdge = aboveFits ? .maxY : .minY

        let popoverView = PopoverPreviewView(visibleCount: slots)
        popover.contentSize = NSSize(width: 420, height: bodyH)
        if let hostingController = popover.contentViewController as? NSHostingController<PopoverPreviewView> {
            hostingController.rootView = popoverView
        } else {
            popover.contentViewController = NSHostingController(rootView: popoverView)
        }

        // In practice show() only runs on popup open (openPopupNow guards on
        // !isVisible), but enforce the invariant anyway: never move the
        // anchor window or re-call show() under a live popover — that tears
        // the attachment down and replays the open/close animation.
        guard !popover.isShown else { return }

        // Position the invisible 1×1 anchor exactly at the cursor, on the
        // correct screen, then order it front WITHOUT activating the app.
        anchorPanel.setFrame(NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1), display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        // Fast open with a REAL visible animation — see clipenAnimateIn.
        // animates is restored so the close keeps the native fade-out.
        popover.animates = false
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
        popover.animates = true
        popover.clipenAnimateIn()
    }

    /// Center Y of the currently-selected visible row — used by sibling panels
    /// (transform callout, item preview) to anchor their arrows.
    ///
    /// Mirrors the REAL scroll behavior in `rowArea`, which calls
    /// `proxy.scrollTo(id, anchor: .center)` — a continuous, always-recenter
    /// scroll, not a discrete "window slides one row at a time" model. That
    /// means: near the top of the list, scrolling clamps at the start (rows
    /// sit at their natural unscrolled position); near the bottom, it clamps
    /// at the end (rows sit at their natural from-the-bottom position); but
    /// everywhere in between, the selected row is ALWAYS exactly centered in
    /// the viewport, regardless of index. An earlier version of this function
    /// assumed the discrete model, which only coincidentally matched reality
    /// for the first few rows (before scrolling starts) and drifted further
    /// off the further into the list you went.
    func selectedRowAnchorPoint(selectedIndex: Int, totalItems: Int) -> NSPoint {
        guard totalItems > 0 else { return NSPoint(x: frame.maxX, y: frame.midY) }

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

// MARK: - Popup SwiftUI view

struct PopoverPreviewView: View {

    let visibleCount: Int

    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared

    // Popup always renders from displayItems — the exact same array that
    // keyboard navigation (V/⌘V) and paste use. One array, one index,
    // zero mismatch possible.
    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    private static let rowH: CGFloat = 72

    // No clipShape/background/overlay/shadow/arrow here anymore — this view
    // is now hosted inside a real NSPopover, which draws the rounded box, the
    // vibrancy, the arrow, and the entrance animation itself. Adding any of
    // that here would just double up on what AppKit already provides.
    var body: some View {
        VStack(spacing: 0) {
            header
            popupSearchBar
            categoryStrip
            firstCycleHint
            Divider()
            rowArea
            Divider()
            footer
        }
    }

    // MARK: Header

    // Hints only — the Clipen icon + name that used to lead this row are
    // gone (the user knows what app this is; the space is better spent on
    // shortcuts). The coach-replay tap target went with the branding button;
    // the coach bubbles themselves still show on their anchor hints.
    private var header: some View {
        // Horizontally scrollable: 9 hints (7 keyboard + 2 mouse) no longer
        // fit inside the popup's fixed 420pt width without clipping. A
        // ScrollView here means an overflow scrolls instead of cutting hints
        // off invisibly — scope this out further (grouping, or a
        // "more hints" affordance) if it feels cramped in practice.
        ScrollView(.horizontal, showsIndicators: false) {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 14) {
            // The "V · Next" hint slot IS the close control once a hold on
            // the first V press has been confirmed (popupPinnedOpen) — same
            // slot, not a separate button. A solid filled circle so it
            // visibly reads as a clickable button, not a stray letter;
            // icon only, no "Close" label needed next to it.
            if manager.popupPinnedOpen {
                Button {
                    manager.dismissPreview()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close (opened via hold — ⌘ release won't close this)")
            } else {
                FlatHint(key: "V", label: "Next", isActive: manager.popupHintV)
                    .overlay(alignment: .bottom) {
                        if manager.popupCoachStep == 0 {
                            CoachBubble(text: "Hold ⌘ and tap V a few times to cycle items")
                                .offset(y: 38).allowsHitTesting(false)
                        }
                    }
            }

            // Once pinned, ⌘ is typically no longer held — and V/C/X are ALL
            // gated behind `guard cmd` in handleKeyDown, so Mark/Front/
            // Transform stop actually doing anything at that point. Showing
            // hints for dead shortcuts would be actively misleading, so
            // pinned mode strips the header down to only what still works:
            // the close button above, plus click/double-click below.
            if !manager.popupPinnedOpen {
                FlatHint(key: "⇧V", label: "Prev", isActive: manager.popupHintShiftV)

                FlatHint(key: "hold V", label: "Mark", isActive: manager.popupHintVMark)

                FlatHint(key: "C", label: "Front", isActive: manager.popupHintC)

                FlatHint(key: "X", label: "Transform",
                         enabled: auth.transformsEnabled,
                         isActive: manager.popupHintX)
                    .overlay(alignment: .bottom) {
                        if manager.popupCoachStep == 1 {
                            CoachBubble(text: "Tap X a few times to cycle transforms")
                                .offset(y: 38).allowsHitTesting(false)
                        }
                    }

                // Click to preview, double-click to Refer — both are Space-key
                // gestures, so both use the SAME spacebar-glyph icon language
                // (single bar = single tap, doubled bar = double tap), not an
                // unrelated SF Symbol. "Refer" opens the Reference panel; see
                // its own doc note below for why it isn't called "Pin".
                SpaceKeyFlatHint(label: "Preview", isActive: manager.popupHintSpace)

                // Renamed from "Pin" — that name already belongs to the
                // ring's separate keep-from-eviction feature (togglePin/
                // isPinned), so reusing it here for "send to the Reference
                // panel" was actively confusing. "Refer" matches what this
                // actually does.
                DoubleSpaceKeyFlatHint(label: "Refer", isActive: manager.popupHintSpaceDoubleTap)
            }

            // Mouse equivalents of the keyboard hints above — click and
            // double-click work on any row regardless of what's highlighted,
            // ⌘ held or not, so these stay visible in BOTH states.
            IconFlatHint(icon: "cursorarrow.click", label: "Preview")
            IconFlatHint(icon: "cursorarrow.click.2", label: "Paste")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Inline search bar

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
                .help("Clear search (Esc)")
            }
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

    // MARK: Category strip (popup-only — popupTagFilter, never touches main window)

    /// Stable id for the "All" chip plus every tag chip, used to scroll the
    /// active one into view. A plain enum instead of ClipboardTag? directly —
    /// ScrollViewReader needs a Hashable id, and this reads more clearly at
    /// the scrollTo call site than juggling an Optional.
    private enum CategoryChipID: Hashable {
        case all
        case tag(ClipboardTag)
    }

    private var categoryStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    TagFilterChip(tag: nil, selected: manager.popupTagFilter == nil, shortcutNumber: 1) {
                        manager.popupTagFilter = nil
                    }
                    .id(CategoryChipID.all)
                    ForEach(manager.availableTags, id: \.self) { tag in
                        TagFilterChip(
                            tag: tag,
                            selected: manager.popupTagFilter == tag,
                            shortcutNumber: (manager.availableTags.firstIndex(of: tag) ?? 0) + 2
                        ) {
                            manager.popupTagFilter = tag
                        }
                        .id(CategoryChipID.tag(tag))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            // Keep the active category chip visible (centered) whenever the
            // filter changes — including via ⌘1-9, not just clicking a chip
            // that might already be scrolled off-screen.
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

    // MARK: First-cycle hint banner

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

    // MARK: Row area

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
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                PopoverRow(item: item, index: idx,
                                           isSelected: idx == selectedIndex,
                                           markOrder: manager.markOrder(for: item.id))
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        manager.uiSelectItem(at: idx)
                                        // Paste without closing the popup —
                                        // lets the user double-click several
                                        // items in a row, pasting each one,
                                        // instead of the popup closing after
                                        // the first (⌘-release still commits
                                        // + closes normally, unaffected).
                                        manager.pasteItemKeepingPopupOpen(id: item.id)
                                    }
                                    .onTapGesture(count: 1) {
                                        manager.uiSelectItem(at: idx)
                                        // Single click both selects AND previews —
                                        // same "peek" intent Space already provides,
                                        // just reused here instead of requiring a
                                        // separate keypress. Double-click (above)
                                        // still pastes, unaffected.
                                        manager.uiPreviewSelectedItem()
                                    }
                                if idx < items.count - 1 {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        guard items.indices.contains(newIdx) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(items[newIdx].id, anchor: .center)
                        }
                    }
                    .onAppear {
                        guard items.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                    }
                    // The hosting controller (and this whole view hierarchy,
                    // including the ScrollView's offset) survives hide/show —
                    // onAppear above only fires once, ever. Without this,
                    // scrolling manually then collapsing + reopening the
                    // popup resumed at the stale offset instead of jumping
                    // back to the selection. See popupOpenGeneration's doc.
                    .onChange(of: manager.popupOpenGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        proxy.scrollTo(items[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: Footer

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

// MARK: - Drag preview

/// Visual badge that appears attached to the cursor during a drag from the popup.
/// Shows the item's type icon + label for single-item drags, or a stacked chip
/// with a count badge for multi-item (marked) drags.
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
                // Stack indicator — three offset capsules suggest "multiple"
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
        // Subtle dark chip (near-black → dark grey), fully opaque — matches
        // the app's dark chrome instead of the old loud blue→purple/green
        // gradients.
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

// MARK: - Row

struct PopoverRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool
    /// 1-based position in the multi-paste mark queue, or nil if unmarked.
    let markOrder:  Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            rowHeader
            rowContent.padding(.leading, 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
        .onDrag {
            // If this item is marked (part of the multi-paste queue), drag ALL
            // marked items together. Otherwise drag just this item.
            ClipboardManager.shared.markedItemsDragProvider(fallback: item)
        } preview: {
            PopoverDragPreview(item: item,
                               markedCount: ClipboardManager.shared.markedItemIDs.count)
        }
    }

    private var rowHeader: some View {
        HStack(spacing: 8) {
            ItemTagStrip(tags: item.tags, maxVisible: 4, style: .plainComma)

            if let badge = item.diffBadge {
                Text("∆ \(badge)")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            }

            if item.userNote != nil {
                Image(systemName: "pencil")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
                    .help("This item has a note")
            }

            Spacer()

            if let order = markOrder {
                // Ordinal label — shows the item's position in the paste queue
                Text("\(order). marked")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.20, green: 0.78, blue: 0.35),   // system green
                                in: Capsule())
                    .help("Marked #\(order) for multi-paste — hold V to toggle")
            } else if isSelected {
                HStack(spacing: 5) {
                    Text("Release").font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
                    Text("⌘")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    Text("to paste").font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
                }
            }
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        switch item.content {
        case .text(let str):
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
                    if ClipboardManager.shared.showColorSwatches, let c = item.detectedColor {
                        Circle().fill(Color(nsColor: c)).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                    }
                    Text(str).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                        .foregroundColor(.primary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        // richText / rtfd / html: if the content actually contains a table
        // (Apple Notes / Pages / Word tables come through as rich text with
        // NSTextTable blocks; browser/Excel tables as HTML <tr>/<td>), render
        // a real mini table grid in the row — same visual promise the preview
        // panel keeps — instead of two lines of flattened text.
        case .richText(_, plain: let plain), .rtfd(_, plain: let plain):
            if let cells = TableCellExtractor.cells(for: item) {
                MiniTablePreview(cells: cells)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(plain).font(.system(size: 12)).lineLimit(2).foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .html(_, let plain):
            if let cells = TableCellExtractor.cells(for: item) {
                MiniTablePreview(cells: cells)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(plain).font(.system(size: 12)).lineLimit(2).foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .file(let url):
            HStack(spacing: 6) {
                fileThumbnail(url, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? url.deletingLastPathComponent().path)
                        .font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .files(let urls):
            HStack(spacing: 6) {
                if let first = urls.first(where: FileKindDetector.isImageFile) {
                    fileThumbnail(first, size: 28)
                } else {
                    Image(systemName: "doc.on.doc").frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(urls.count) files").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(item.metadataSummary ?? urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .image(let img, let data, let dataType):
            VStack(alignment: .leading, spacing: 2) {
                if dataType.rawValue.contains("gif") {
                    AnimatedImageView(data: data)
                        .frame(maxWidth: 280, maxHeight: 48).cornerRadius(5).clipped()
                } else {
                    // Downsampled thumbnail — same scroll-perf fix as the main
                    // window's rows (full-res bitmaps rescaled per frame).
                    Image(nsImage: ItemThumbnailCache.shared.thumbnail(forData: data, key: item.id.uuidString) ?? img)
                        .resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 280, maxHeight: 48).cornerRadius(5).clipped()
                }
                if let summary = item.metadataSummary {
                    Text(summary).font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                }
            }
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

// MARK: - Mini table preview (CSV / TSV)

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
        // Compute once per render — `rows` parses the text, and referencing
        // the computed property twice (isEmpty check + ForEach) parsed twice.
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

// MARK: - Category filter chip

struct TagFilterChip: View {
    let tag:     ClipboardTag?
    let selected: Bool
    var shortcutNumber: Int? = nil
    var customIcon:  String? = nil
    var customLabel: String? = nil
    let action: () -> Void

    private var icon:  String { customIcon  ?? tag?.icon  ?? "clock" }
    private var label: String { customLabel ?? tag?.label ?? "Recents" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let n = shortcutNumber {
                    Text("⌘\(n).")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(selected ? .white.opacity(0.85) : .secondary.opacity(0.75))
                }
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(label).font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule(style: .continuous)
                .fill(selected ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(Color.primary.opacity(0.08))))
            .overlay(Capsule(style: .continuous)
                .stroke(selected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Header hint views

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

/// Icon-based sibling of `FlatHint` — same layout and active-state coloring,
/// but an SF Symbol instead of a monospaced key label (for actions that read
/// better as a glyph than as text, e.g. the pin-shaped "Refer" hint).
struct IconFlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let icon:     String
    let label:    String
    var enabled:  Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isActive ? Self.activeColor : .primary)
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

struct SpaceKeyFlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let label:    String
    var enabled:  Bool = true
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isActive ? Self.activeColor : Color.primary.opacity(0.45), lineWidth: 1)
                    .frame(width: 18, height: 10)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(isActive ? Self.activeColor : Color.primary.opacity(0.7))
                    .frame(width: 10, height: 1.5)
            }
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

/// Double-tap sibling of `SpaceKeyFlatHint` — the SAME spacebar-key glyph,
/// drawn twice side by side, so "single tap = Preview" and "double tap =
/// Refer" read as one consistent icon language instead of an unrelated
/// SF Symbol standing in for "double-tap Space."
struct DoubleSpaceKeyFlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let label:    String
    var enabled:  Bool = true
    var isActive: Bool = false

    private var keyGlyph: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .stroke(isActive ? Self.activeColor : Color.primary.opacity(0.45), lineWidth: 1)
                .frame(width: 14, height: 10)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(isActive ? Self.activeColor : Color.primary.opacity(0.7))
                .frame(width: 7, height: 1.5)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 2) {
                keyGlyph
                keyGlyph
            }
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

// MARK: - First-run coach bubble

struct CoachBubble: View {
    let text: String
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 3) {
            Triangle().fill(Color.accentColor).frame(width: 9, height: 5)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                .fixedSize()
        }
        .shadow(color: .accentColor.opacity(0.4), radius: pulse ? 8 : 3, x: 0, y: 2)
        .scaleEffect(pulse ? 1.04 : 1.0)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

extension NSPopover {
    /// Fast custom appear animation, shared by all three Clipen popovers
    /// (main popup, transform panel, item preview). NSPopover's built-in
    /// open animation is private (~0.25s, ignores NSAnimationContext) with
    /// no duration knob — so the popovers are shown with `animates = false`
    /// and this runs instead: a quick ease-out fade + subtle center-anchored
    /// grow, so opening still FEELS animated, just much faster than stock.
    func clipenAnimateIn(duration: TimeInterval = 0.17) {
        guard let view = contentViewController?.view else { return }
        view.wantsLayer = true
        if let layer = view.layer {
            // AppKit layers anchor at (0,0); re-anchor to the center (and
            // compensate position) so the scale grows from the middle
            // instead of the bottom-left corner.
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
        // Also fade the popover WINDOW (chrome + arrow), so the frame
        // doesn't pop in fully-formed around still-animating content.
        if let win = view.window {
            win.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1
            }
        }
    }
}
