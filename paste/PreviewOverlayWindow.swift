import AppKit
import SwiftUI

class PreviewOverlayWindow: NSPanel {
    private var hostingView: NSHostingView<PopoverPreviewView>?

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
        let items = ClipboardManager.shared.displayItems
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

    func hide() { orderOut(nil) }
}

// MARK: - Popover-style container

struct PopoverPreviewView: View {
    // Position-dependent state — passed in once per popup session.
    let visibleCount: Int        // how many rows actually fit on screen
    let arrowAtBottom: Bool
    let arrowOffsetX: CGFloat

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
            if !arrowAtBottom {
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

                    FlatHint(key: "V", label: "Next")
                    FlatHint(key: "⇧V", label: "Category")
                    FlatHint(key: "X", label: "Transform",
                             enabled: auth.transformsEnabled)
                    SpaceKeyFlatHint(label: "Preview")
                    FlatHint(key: "⌘",
                             label: manager.selectionArmed ? "Paste" : "Dismiss",
                             keyColor: manager.selectionArmed ? .green : .secondary,
                             labelColor: manager.selectionArmed ? .green : .secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

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

                // Dismiss countdown strip — isolated to its own subview so the
                // 50ms progress tick only re-renders this 2pt strip, not the
                // whole popup body.
                if manager.dismissTimeout > 0 {
                    DismissProgressStrip(ticker: manager.dismissTicker)
                        .frame(height: 2)
                }

                Divider()

                // Fixed-height row area — category changes swap content only.
                VStack(spacing: 0) {
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
                .frame(height: Self.rowHeight * CGFloat(visibleCount), alignment: .top)

                Divider()
                Text(items.isEmpty
                     ? "0 of 0"
                     : "\(min(selectedIndex + 1, items.count)) of \(items.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 6)

            if arrowAtBottom {
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

/// Isolated subview for the dismiss-countdown progress bar. Only this view
/// observes the 50ms-tick `DismissTicker`, so progress updates don't ripple
/// into the rest of the popup (rows, chips, header).
struct DismissProgressStrip: View {
    @ObservedObject var ticker: DismissTicker

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                Rectangle()
                    .fill(ticker.frozen
                          ? Color.accentColor.opacity(0.7)
                          : Color.secondary.opacity(0.3))
                    .frame(width: geo.size.width * ticker.progress)
                    .animation(
                        ticker.frozen
                            ? .easeOut(duration: 0.15)
                            : .linear(duration: 0.05),
                        value: ticker.progress
                    )
            }
        }
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
    let key: String
    let label: String
    var enabled: Bool = true
    var keyColor:   Color = .primary
    var labelColor: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(keyColor)
                .lineLimit(1)
                .fixedSize()
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(labelColor)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
    }
}

struct SpaceKeyFlatHint: View {
    let label: String
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                    .frame(width: 18, height: 10)
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 10, height: 1.5)
            }
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
        .opacity(enabled ? 1.0 : 0.35)
    }
}

// MARK: - Tag filter strip

struct TagFilterStrip: View {
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        let tags = manager.availableTags
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                TagFilterChip(tag: nil, selected: manager.tagFilter == nil) {
                    manager.tagFilter = nil
                }
                ForEach(tags, id: \.self) { tag in
                    TagFilterChip(tag: tag, selected: manager.tagFilter == tag) {
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
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

            // ── Header: badge · type  ·  badge · ↵ ──────
            HStack(spacing: 8) {
                // Plain row number. The ⌘1–9 binding is advertised by the
                // "1–9 Pick" chip in the header strip; printing ⌘ on every
                // badge was visual noise on top of that.
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.12))
                        .frame(width: 22, height: 18)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(isSelected ? .white : .secondary)
                }

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
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundColor(.accentColor)
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
