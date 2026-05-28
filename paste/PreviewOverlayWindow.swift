import AppKit
import SwiftUI

class PreviewOverlayWindow: NSPanel {
    private var hostingView: NSHostingView<PopoverPreviewView>?
    private var visibleRowCount: Int = 5
    private var isArrowAtBottom: Bool = true

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // we draw our own shadow inside SwiftUI
        // Mouse events are accepted so the user can click category chips in
        // the strip. The panel is `.nonactivatingPanel`, so clicks don't
        // steal keyboard focus from the underlying app — ⌘ stays "held"
        // through the click. Outside the chip area there's no tap target,
        // so clicks just sit on the (currently inert) row views.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(at caretPos: NSPoint) {
        let rowH: CGFloat    = 72
        // Header = title row with inline V/X/Paste hints (~44) + category
        // strip (~36). The standalone shortcut chip row is gone.
        let headerH: CGFloat = 80
        let arrowH: CGFloat  = 10
        let gap: CGFloat     = 8
        let w: CGFloat       = 420
        let margin: CGFloat  = 12
        // Cap visible rows at 5 (UX: any more and the popup feels overwhelming)
        // but allow fewer if screen is small.
        let maxVisible: Int  = 5

        // Find the screen the caret is on, fall back to main
        let screen = NSScreen.screens.first(where: { NSMouseInRect(caretPos, $0.visibleFrame, false) })?.visibleFrame
                  ?? NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // AppKit y grows UPWARD. "Above the caret" visually = higher y values.
        //   visualSpaceAbove = room from caret up to screen top
        //   visualSpaceBelow = room from caret down to screen bottom
        // (The previous code had these swapped — fitsAbove evaluated against
        //  the wrong axis, so the popup landed off-screen above the caret.)
        let spaceAbove = screen.maxY - caretPos.y - gap
        let spaceBelow = caretPos.y - screen.minY - gap

        // Determine how many rows fit in the larger free side
        let availableSpace = max(spaceAbove, spaceBelow) - headerH - arrowH - margin
        let maxRows        = max(1, Int(availableSpace / rowH))
        // Fixed slot count keeps popup height stable when switching categories
        // (Images vs Recents can have very different item counts).
        let slotCount      = min(maxVisible, maxRows)
        let footerH: CGFloat = 26

        let bodyH  = headerH + CGFloat(slotCount) * rowH + footerH
        let totalH = bodyH + arrowH

        // Prefer placing ABOVE the typing line (so it doesn't cover what's
        // being typed). If there isn't enough room up there, fall to below.
        let fitsAbove     = totalH <= spaceAbove
        let arrowAtBottom = fitsAbove   // popup above ↦ arrow at popup's bottom pointing down
        visibleRowCount = slotCount
        isArrowAtBottom = arrowAtBottom

        var x = caretPos.x - w / 2
        var y: CGFloat

        if fitsAbove {
            // Popup above caret: bottom edge sits just above the caret + gap
            y = caretPos.y + gap
        } else {
            // Popup below caret: top edge sits just below the caret − gap
            y = caretPos.y - totalH - gap
            y = max(screen.minY + margin, y)            // never go below screen bottom
        }

        // Clamp horizontally within screen
        x = max(screen.minX + margin, min(x, screen.maxX - w - margin))

        // Arrow tip X relative to panel
        let arrowX = min(max(caretPos.x - x, 24), w - 24)

        let view = PopoverPreviewView(
            visibleCount: slotCount,
            arrowAtBottom: arrowAtBottom,
            arrowOffsetX: arrowX
        )

        if let hv = hostingView {
            hv.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            contentView = hv
            hostingView = hv
        }

        setFrame(NSRect(x: x, y: y, width: w, height: totalH), display: true)
        if !isVisible { orderFront(nil) }
    }

    /// Show the popup centred on the main screen — used when there is no
    /// focused text input to anchor to. No caret arrow is drawn.
    func showCentered() {
        let rowH: CGFloat     = 72
        let headerH: CGFloat  = 80
        let footerH: CGFloat  = 26
        let w: CGFloat        = 420
        let margin: CGFloat   = 12
        let maxVisible: Int   = 5

        let screen = NSScreen.main?.visibleFrame
                  ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let availableH = screen.height - margin * 2 - headerH - footerH
        let slotCount  = min(maxVisible, max(1, Int(availableH / rowH)))
        let bodyH      = headerH + CGFloat(slotCount) * rowH + footerH

        visibleRowCount = slotCount
        isArrowAtBottom = false

        let x = screen.midX - w / 2
        let y = screen.midY - bodyH / 2

        let view = PopoverPreviewView(
            visibleCount: slotCount,
            arrowAtBottom: false,
            arrowOffsetX: 0,
            showArrow: false
        )
        if let hv = hostingView {
            hv.rootView = view
        } else {
            let hv = NSHostingView(rootView: view)
            contentView = hv
            hostingView = hv
        }
        setFrame(NSRect(x: x, y: y, width: w, height: bodyH), display: true)
        if !isVisible { orderFront(nil) }
    }

    func hide() { orderOut(nil) }

    /// Anchor point at the center of the currently selected visible row.
    /// Used by sibling panels (e.g. transform callout) so their arrows can
    /// point at the same row the user is focused on.
    func selectedRowAnchorPoint(selectedIndex: Int, totalItems: Int) -> NSPoint {
        guard totalItems > 0 else {
            return NSPoint(x: frame.maxX, y: frame.midY)
        }

        let win = min(max(1, visibleRowCount), totalItems)
        let start = selectedIndex < win ? 0 : selectedIndex - (win - 1)
        let clampedStart = max(0, min(start, totalItems - win))
        let rowInWindow = max(0, min(selectedIndex - clampedStart, win - 1))

        let rowH: CGFloat = 72
        let footerH: CGFloat = 26
        let arrowH: CGFloat = 10

        // Bubble sits above the bottom arrow when the popup is above caret.
        let bubbleMinY = isArrowAtBottom ? (frame.minY + arrowH) : frame.minY
        let rowsBottomY = bubbleMinY + footerH
        let rowCenterY = rowsBottomY + (CGFloat(win - rowInWindow) - 0.5) * rowH

        return NSPoint(x: frame.maxX, y: rowCenterY)
    }
}

// MARK: - Popover-style container

struct PopoverPreviewView: View {
    // Position-dependent state — passed in once per popup session.
    let visibleCount: Int        // how many rows actually fit on screen
    let arrowAtBottom: Bool
    let arrowOffsetX: CGFloat
    var showArrow: Bool = true   // false when popup is centered (no caret to point at)

    // Reactive state — read live from the manager so cycling only flips
    // selectedIndex and SwiftUI re-renders via @ObservedObject without
    // having to rebuild the entire view tree on every keypress.
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared

    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    /// "Sticky bottom" scrolling: selected item moves naturally through
    /// positions 0 → (visibleCount-1) at the top of the list. Once it hits
    /// the bottom slot, it stays anchored there and earlier items scroll up
    /// to keep the selection always visible without forcing centering.
    ///
    /// Examples with visibleCount=5 and 10 items:
    ///   selectedIndex 0 → window [0..5)  selection at row 0
    ///   selectedIndex 3 → window [0..5)  selection at row 3
    ///   selectedIndex 4 → window [0..5)  selection at row 4 (bottom)
    ///   selectedIndex 5 → window [1..6)  selection at row 4 (list scrolled +1)
    ///   selectedIndex 9 → window [5..10) selection at row 4
    private static let rowHeight: CGFloat = 72

    private var visibleRange: Range<Int> {
        let total = items.count
        guard total > 0 else { return 0..<0 }
        let win   = min(visibleCount, total)
        let start: Int
        if selectedIndex < win {
            start = 0                                        // hasn't hit bottom yet
        } else {
            start = selectedIndex - (win - 1)                // anchor at bottom
        }
        let clampedStart = max(0, min(start, total - win))
        return clampedStart..<(clampedStart + win)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showArrow && !arrowAtBottom {
                arrowShape.padding(.leading, arrowOffsetX - 10)
            }

            // Main bubble
            VStack(spacing: 0) {
                // Header — Clipen mark on the left, flat usage hints on
                // the right (no chip boxes — just plain text). The right-
                // most ⌘ is colored to signal release-state: green = paste,
                // gray = dismiss.
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                            .resizable()
                            .frame(width: 18, height: 18)
                            .cornerRadius(4)
                        Text("Clipen")
                            .font(.system(.callout, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize()
                    }

                    Spacer()

                    // The "⌘ Paste" affordance moved out of the header — it's
                    // now shown inline on the currently-highlighted row as
                    // "Release ⌘ to paste", which puts the action right next
                    // to its target.  Header stays focused on cycle hints.
                    FlatHint(key: "V", label: "Next",
                             isActive: manager.popupHintV)
                    FlatHint(key: "⇧V", label: "Prev",
                             isActive: manager.popupHintShiftV)
                    FlatHint(key: "X", label: "Transform",
                             enabled: auth.transformsEnabled,
                             isActive: manager.popupHintX)
                    SpaceKeyFlatHint(label: "Preview",
                                     isActive: manager.popupHintSpace)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                // ── Inline search text box (always visible) ──
                // Sits between the Clipen heading row and the category strip.
                // Idle state: shows "⌘F · Search your copied items" as
                // placeholder text — no border highlight.
                // Active state (⌘F pressed): accent-colored border + caret;
                // typed characters route through the event tap so the popup
                // never has to steal focus. Popup dismiss timer is frozen
                // while typing so the user can take their time.
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(manager.isPopupSearchActive
                                         ? .accentColor
                                         : .secondary.opacity(0.55))
                    Group {
                        if manager.isPopupSearchActive {
                            // BlinkingCursor sits at the caret position
                            // (start when empty, end of query when typing) so
                            // the user can see this is an active input even
                            // though the non-activating panel can't host a
                            // real TextField.
                            if manager.popupSearchQuery.isEmpty {
                                HStack(spacing: 0) {
                                    BlinkingCursor()
                                        .foregroundColor(.accentColor)
                                    Text("Type to search… ⎋ to cancel")
                                        .foregroundColor(.secondary.opacity(0.55))
                                    Spacer(minLength: 0)
                                }
                            } else {
                                HStack(spacing: 0) {
                                    Text(manager.popupSearchQuery)
                                        .foregroundColor(.primary)
                                    BlinkingCursor()
                                        .foregroundColor(.accentColor)
                                    Spacer(minLength: 0)
                                }
                            }
                        } else {
                            HStack(spacing: 4) {
                                Text("Press")
                                Text("⌘F")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.primary.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 3))
                                Text("to search your copied items")
                            }
                            .foregroundColor(.secondary.opacity(0.55))
                        }
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(manager.isPopupSearchActive ? 0.06 : 0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(manager.isPopupSearchActive
                                ? Color.accentColor.opacity(0.45)
                                : Color.primary.opacity(0.08),
                                lineWidth: 1)
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
                .animation(.easeInOut(duration: 0.15), value: manager.isPopupSearchActive)

                // Category strip — horizontal scrolling list of category
                // pills the user can click to filter the ring. "Recents"
                // (nil filter) is pinned first, then categories present in
                // the ring in alphabetical order. Mouse-driven for now;
                // keyboard nav is a future enhancement.
                TagFilterStrip()

                // First-time-ever cycle hint — appears on the very first
                // ⌘V cycling and auto-disappears after a few seconds. Kept
                // even though the chip row covers transforms; first-launch
                // users benefit from the louder gradient version too.
                if manager.showFirstCycleHint {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Tip: Tap X to transform the highlighted item")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        LinearGradient(colors: [Color(hex: "#4F8EF7"), Color(hex: "#A855F7")],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .transition(.opacity)
                }

                Divider()

                // Bind once: popupSearchResults is a computed property that
                // allocates a fresh Array<ClipboardItem>(prefix(5)) per call.
                // Reading it once per body render (used in rows AND footer)
                // is fine; reading it 3× would triple the alloc.
                let popupResults = manager.isPopupSearchActive ? manager.popupSearchResults : []

                // Fixed-height row area — shows search results or normal items.
                VStack(spacing: 0) {
                    if manager.isPopupSearchActive {
                        // ── Search results ──
                        let results = popupResults
                        if manager.popupSearchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 22))
                                    .foregroundColor(.secondary.opacity(0.35))
                                Text("Semantic search — type anything")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if results.isEmpty {
                            VStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary.opacity(0.3))
                                Text("No results for \"\(manager.popupSearchQuery)\"")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ForEach(Array(results.prefix(visibleCount).enumerated()), id: \.element.id) { idx, item in
                                PopoverRow(item: item,
                                           index: idx,
                                           isSelected: idx == manager.popupSearchSelectedIndex)
                                    .onTapGesture { manager.commitPopupSearchPaste() }
                                if idx < min(results.count, visibleCount) - 1 {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                    } else {
                        // ── Normal clipboard ring ──
                        if items.isEmpty {
                            Text("No items with this tag")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ForEach(Array(items[visibleRange].enumerated()), id: \.element.id) { pair in
                                let absoluteIndex = visibleRange.lowerBound + pair.offset
                                PopoverRow(item: pair.element,
                                           index: absoluteIndex,
                                           isSelected: manager.selectionArmed && absoluteIndex == selectedIndex)
                                if absoluteIndex < visibleRange.upperBound - 1 {
                                    Divider().padding(.leading, 38)
                                }
                            }
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(visibleCount), alignment: .top)
                .animation(.easeInOut(duration: 0.15), value: manager.isPopupSearchActive)
                .animation(.easeInOut(duration: 0.1), value: manager.popupSearchQuery)

                Divider()
                // Footer — search mode shows result count; normal mode shows position
                if manager.isPopupSearchActive && !manager.popupSearchQuery.isEmpty {
                    let count = popupResults.count   // reuse the body-local bind
                    Text(count == 0 ? "No results" : "\(count) result\(count == 1 ? "" : "s")")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                } else {
                    Text(items.isEmpty
                         ? "0 of 0"
                         : "\(min(selectedIndex + 1, items.count)) of \(items.count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)

            if showArrow && arrowAtBottom {
                arrowShape.padding(.leading, arrowOffsetX - 10)
            }
        }
    }

    // Triangle arrow (points toward caret)
    private var arrowShape: some View {
        ArrowTip(pointingDown: arrowAtBottom)
            .fill(.regularMaterial)
            .frame(width: 20, height: 10)
            .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: arrowAtBottom ? 2 : -2)
    }
}


// MARK: - Shortcut chip
//
// Keycap-styled pill that advertises one gesture. The popup always shows
// five chips (Next / Back / Transform / Delete / Paste) so the user has a
// permanent legend of every interaction the popup responds to — no need
// to remember anything between sessions.
struct ShortcutChip: View {
    let keys: String
    let label: String
    var enabled: Bool = true       // false = dimmed (e.g. transforms gated)
    var emphasized: Bool = false   // true = paste / commit-style highlight

    var body: some View {
        HStack(spacing: 5) {
            // Keycap
            Text(keys)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(emphasized ? .white : .primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(emphasized
                              ? Color.accentColor
                              : Color.primary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .opacity(enabled ? 1.0 : 0.35)
    }
}

// MARK: - Flat hint (no chip boxes — just bold key + muted label)

struct FlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let key: String
    let label: String
    var enabled: Bool = true
    var isActive: Bool = false
    var idleKeyColor: Color = .primary
    var idleLabelColor: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? Self.activeColor : idleKeyColor)
                .lineLimit(1)
                .fixedSize()
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? Self.activeColor : idleLabelColor)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

struct SpaceKeyFlatHint: View {
    private static let activeColor = Color(hex: "#4F8EF7")

    let label: String
    var enabled: Bool = true
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
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
        .animation(.easeOut(duration: 0.1), value: isActive)
    }
}

// MARK: - Tag filter strip

struct TagFilterStrip: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        // 1. Recents (default), 2. <first category>, 3. <second>, …
        // Numbers ≤ 9 are key-bindable: ⌘1 → Recents, ⌘2 → first category, etc.
        // Beyond 9 the prefix is dropped (no shortcut) — mouse-click only.
        let tags = manager.availableTags
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TagFilterChip(
                    tag: nil,
                    selected: manager.tagFilter == nil,
                    shortcutNumber: 1
                ) {
                    manager.tagFilter = nil
                }
                ForEach(Array(tags.enumerated()), id: \.element) { idx, tag in
                    TagFilterChip(
                        tag: tag,
                        selected: manager.tagFilter == tag,
                        shortcutNumber: idx + 2 <= 9 ? idx + 2 : nil
                    ) {
                        manager.tagFilter = (manager.tagFilter == tag) ? nil : tag
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 36)
        .background(Color.primary.opacity(0.02))
    }
}

struct TagFilterChip: View {
    let tag: ClipboardTag?
    let selected: Bool
    var shortcutNumber: Int? = nil      // 1…9, used as ⌘N keybinding
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let n = shortcutNumber {
                    Text("\(n).")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(selected ? .white.opacity(0.85) : .secondary.opacity(0.75))
                }
                Image(systemName: tag?.icon ?? "clock")
                    .font(.system(size: 9, weight: .semibold))
                Text(tag?.label ?? "Recents")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(selected ? .white : .secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.accentColor : Color.primary.opacity(0.08))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(selected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct ArrowTip: Shape {
    let pointingDown: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointingDown {
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - Row

struct PopoverRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {

            // ── Header: type tags · diff badge · ↵ ──────
            // The per-row number badge was removed: numbers now live on the
            // category chips above (⌘1 → Recents, ⌘2 → first category, …)
            // since ⌘1–9 now switches CATEGORY, not row.  V / ⇧V step through
            // items in the current category instead.
            HStack(spacing: 8) {
                ItemTagStrip(tags: item.tags, maxVisible: 4, style: .plainComma)

                if let badge = item.diffBadge {
                    Text("∆ \(badge)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                if isSelected {
                    // Replaces the small ↵ arrow that used to mark the
                    // selected row.  Shows the actual paste affordance
                    // right next to the highlighted item so the user
                    // sees what releasing ⌘ will do.  Header lost its
                    // "⌘ Paste" chip in the same change — this is its
                    // new home.
                    HStack(spacing: 4) {
                        Text("Release")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.accentColor.opacity(0.85))
                        Text("⌘")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.accentColor)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 3))
                        Text("to paste")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.accentColor.opacity(0.85))
                    }
                }
            }

            // ── Content ──────────────────────────────────
            Group {
                switch item.content {
                case .text(let str):
                    if let title = item.urlTitle {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .foregroundColor(.primary)
                            Text(str).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                                .foregroundColor(.primary.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 6) {
                            if ClipboardManager.shared.showColorSwatches, let c = item.detectedColor {
                                Circle().fill(Color(nsColor: c)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                            }
                            Text(str).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                                .foregroundColor(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                case .richText(_, plain: let plain):
                    Text(plain).font(.system(size: 12)).lineLimit(2)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .html(_, plain: let plain):
                    Text(plain).font(.system(size: 12)).lineLimit(2)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .file(let url):
                    HStack(spacing: 6) {
                        fileThumbnail(url, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(item.metadataSummary ?? url.deletingLastPathComponent().path).font(.system(size: 9)).lineLimit(1)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .files(let urls):
                    HStack(spacing: 6) {
                        if let firstImageURL = urls.first(where: FileKindDetector.isImageFile) {
                            fileThumbnail(firstImageURL, size: 28)
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
                case .image(let img, _, _):
                    VStack(alignment: .leading, spacing: 2) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 280, maxHeight: 48)
                            .cornerRadius(5).clipped()
                        if let summary = item.metadataSummary {
                            Text(summary).font(.system(size: 9)).lineLimit(1).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, in: Rectangle())
    }

    @ViewBuilder
    private func fileThumbnail(_ url: URL, size: CGFloat) -> some View {
        if FileKindDetector.isImageFile(url), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 14, height: 14)
        }
    }
}
