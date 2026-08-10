import AppKit
import SwiftUI

final class PreviewOverlayWindow: NSObject, NSPopoverDelegate {
    private var wantsVisible = false

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

    private let hintOverlay = PopupHintOverlay()

    func show() {
        wantsVisible = true
        showAnchored(to: NSEvent.mouseLocation)
    }

    func hide() {

        let wasVisible = wantsVisible
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

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isVisible else { return }
                self.hintOverlay.show(above: self.frame)
            }
        }
    }

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

    @Namespace private var selectionNamespace

    @Namespace private var categoryNamespace

    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    /// `displayItems` folded into display segments: runs of 2+ consecutive
    /// `.image` items become one `ImageRunRow`; everything else stays its
    /// own `PopoverRow`, unchanged. Recomputed on every render — there is
    /// no stored grouping to go stale — so a run splits or reforms for
    /// free whenever pinning, search, or a tag filter reorders
    /// `displayItems` out from under it. `selectedIndex` still means
    /// exactly what it always has: an index into `displayItems`. Nothing
    /// about marking, pinning, delete, or paste changes — they all key off
    /// item identity, which this never touches.
    private enum RowSegment: Identifiable {
        case single(item: ClipboardItem, index: Int)
        case imageRun([(item: ClipboardItem, index: Int)])

        var id: String {
            switch self {
            case .single(let item, _): return item.id.uuidString
            case .imageRun(let run):   return "run-" + (run.first?.item.id.uuidString ?? "")
            }
        }
    }

    private var rowSegments: [RowSegment] {
        var result: [RowSegment] = []
        var run: [(item: ClipboardItem, index: Int)] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= 2 {
                result.append(.imageRun(run))
            } else {
                result.append(.single(item: run[0].item, index: run[0].index))
            }
            run = []
        }
        for (idx, item) in items.enumerated() {
            if case .image = item.content {
                run.append((item, idx))
            } else {
                flushRun()
                result.append(.single(item: item, index: idx))
            }
        }
        flushRun()
        return result
    }

    /// The id to `scrollTo` first for a given item index. For a `.single`
    /// row this is just the item's own id (already a direct, ForEach-level
    /// anchor). For an item inside an `.imageRun`, the item's id lives three
    /// views deep inside `ImageRunCell` and has no anchor at all until that
    /// row has actually been rendered once — so off-screen it must be
    /// found from scratch, and scrolling straight to it silently does
    /// nothing. The row's own id (now tagged via `.id(segment.id)`) is a
    /// direct ForEach-level anchor same as a `.single` row, so it always has
    /// something to jump to, even sight unseen.
    private func coarseScrollTarget(for idx: Int) -> AnyHashable {
        scrollTarget(for: idx).coarse
    }

    /// `needsRefine` is only true for a run that wraps to a second line —
    /// there the coarse (row-level) anchor centers the run's whole bounding
    /// box, which isn't the same vertical position as a cell on its second
    /// line. A single-line run has every cell at the row's own vertical
    /// center already, so re-centering on the individual cell after the
    /// coarse scroll is a redundant second animated scroll to (near enough)
    /// the same offset — that extra correction is what read as the
    /// selection jiggling up and down while stepping between images in one
    /// line.
    private func scrollTarget(for idx: Int) -> (coarse: AnyHashable, needsRefine: Bool) {
        guard items.indices.contains(idx) else {
            let fallback = items.first.map { AnyHashable($0.id) } ?? AnyHashable("")
            return (fallback, false)
        }
        if case .image = items[idx].content {
            for segment in rowSegments {
                if case .imageRun(let run) = segment, run.contains(where: { $0.index == idx }) {
                    return (AnyHashable(segment.id), run.count > ImageRunRow.maxPerLine)
                }
            }
        }
        return (AnyHashable(items[idx].id), false)
    }

    private static let rowH: CGFloat = 72

    var body: some View {

        if !pro.isUnlocked {
            SubscribeGateView()
        } else {
            VStack(spacing: 0) {
                popupSearchBar
                categoryStrip
                firstCycleHint

                Divider().padding(.bottom, 4)
                rowArea
                Divider()
                footer
            }
            .onPreferenceChange(SelectedRowFramePreferenceKey.self) { frame in
                guard manager.selectedRowMeasuredFrame != frame else { return }
                manager.selectedRowMeasuredFrame = frame

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
                HStack(spacing: 12) {
                    TagFilterChip(tag: nil, selected: manager.popupTagFilter == nil,
                                  namespace: categoryNamespace) {
                        manager.popupTagFilter = nil
                    }
                    .id(CategoryChipID.all)
                    ForEach(manager.availableTags, id: \.self) { tag in
                        TagFilterChip(
                            tag: tag,
                            selected: manager.popupTagFilter == tag,
                            namespace: categoryNamespace
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

                withAnimation(SelectionHighlightStyle.spring) {
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
                if !manager.isHistoryFullyLoaded {
                    // Right after launch, manager.items only holds the
                    // priority slice (pinned + the 40 most recent unpinned)
                    // — the rest loads in background chunks (see
                    // performHistoryLoadOffMain in
                    // ClipboardManager+Persistence.swift). A collection or
                    // tag filter can land entirely inside a chunk that
                    // hasn't arrived yet, making displayItems empty even
                    // though the collection genuinely has items — items's
                    // own didSet invalidates the displayItems cache on
                    // every chunk append, so this self-corrects the
                    // instant the data lands. Showing "loading" here
                    // instead of "no items" avoids lying about a
                    // collection being empty during that window.
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No items with this tag")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {

                        LazyVStack(spacing: 10) {
                            let segments = rowSegments
                            ForEach(Array(segments.enumerated()), id: \.element.id) { segIdx, segment in
                                switch segment {
                                case .single(let item, let idx):
                                    PopoverRow(item: item, index: idx,
                                               isSelected: idx == selectedIndex,
                                               markOrder: manager.markOrder(for: item.id),
                                               showColorSwatches: manager.showColorSwatches,
                                               selectionNamespace: selectionNamespace,
                                               shakeGeneration: manager.editDeniedShake?.itemID == item.id
                                                   ? manager.editDeniedShake?.generation ?? 0 : 0)
                                        .equatable()
                                        .id(item.id)

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
                                case .imageRun(let run):
                                    ImageRunRow(run: run, selectedIndex: selectedIndex,
                                                selectionNamespace: selectionNamespace,
                                                markedItemIDs: manager.markedItemIDs,
                                                editDeniedShake: manager.editDeniedShake)
                                        .equatable()
                                        // Without this, scrollTo(item.id) has no
                                        // anchor to estimate against for an
                                        // off-screen run — the id is buried
                                        // inside ImageRunCell, three levels
                                        // below anything ForEach or LazyVStack
                                        // can position ahead of render. Tagging
                                        // the row itself gives scrollTo a real
                                        // target to jump to first.
                                        .id(segment.id)
                                }
                                if segIdx < segments.count - 1 {
                                    Divider().padding(.leading, 38).opacity(0.25)
                                }
                            }
                        }

                        .padding(.top, 6)
                        .padding(.bottom, 10)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        guard items.indices.contains(newIdx) else { return }
                        let targetID = items[newIdx].id
                        let (coarseID, needsRefine) = scrollTarget(for: newIdx)

                        // Jump to the row-level anchor — for an .imageRun
                        // this is the ONLY anchor that exists before the row
                        // has ever been rendered (see `coarseScrollTarget`);
                        // scrolling straight to a nested, never-rendered
                        // item id is a silent no-op, which is why "back"
                        // into an image run used to do nothing. For every
                        // other row it IS the item's own id, so this single
                        // animated scroll is already exact. It shares the
                        // highlight's own spring so the content glides in
                        // step with the selection box instead of snapping
                        // underneath it.
                        withAnimation(SelectionHighlightStyle.spring) {
                            proxy.scrollTo(coarseID, anchor: .center)
                        }

                        guard needsRefine, coarseID != AnyHashable(targetID) else { return }
                        DispatchQueue.main.async {
                            guard manager.selectedIndex == newIdx else { return }
                            withAnimation(SelectionHighlightStyle.spring) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
                    }
                    .onAppear {
                        guard items.indices.contains(selectedIndex) else { return }
                        let targetID = items[selectedIndex].id
                        proxy.scrollTo(coarseScrollTarget(for: selectedIndex), anchor: .center)
                        DispatchQueue.main.async {
                            guard items.indices.contains(selectedIndex),
                                  items[selectedIndex].id == targetID else { return }
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    .onChange(of: manager.popupOpenGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        let targetID = items[selectedIndex].id
                        proxy.scrollTo(coarseScrollTarget(for: selectedIndex), anchor: .center)
                        DispatchQueue.main.async {
                            guard items.indices.contains(selectedIndex),
                                  items[selectedIndex].id == targetID else { return }
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    // Fires on every collection switch, including
                    // re-selecting the collection already active — unlike
                    // onChange(of: selectedIndex), which only fires when
                    // selectedIndex's value actually transitions and would
                    // stay silent when it was already 0. Animated (unlike
                    // popupOpenGeneration's snap) since this always follows
                    // a visible user action, not a popup materializing.
                    .onChange(of: manager.collectionSwitchGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        let idx = selectedIndex
                        let targetID = items[idx].id
                        let (coarseID, needsRefine) = scrollTarget(for: idx)

                        withAnimation(SelectionHighlightStyle.spring) {
                            proxy.scrollTo(coarseID, anchor: .center)
                        }

                        guard needsRefine, coarseID != AnyHashable(targetID) else { return }
                        DispatchQueue.main.async {
                            guard manager.selectedIndex == idx else { return }
                            withAnimation(SelectionHighlightStyle.spring) {
                                proxy.scrollTo(targetID, anchor: .center)
                            }
                        }
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

/// A run of 2+ consecutive `.image` items rendered as ONE shared row: the
/// same leading rail/divider a normal row has, once — then the images
/// themselves, each still its own full `ClipboardItem` with its own id,
/// laid left-to-right with a thin divider between each, wrapping onto a
/// new line inside this same row once the current line is full.
///
/// Deliberately NOT measured via a body-level `GeometryReader` — that
/// expands to fill all available height inside a `VStack`/`LazyVStack`
/// (a standing SwiftUI quirk), which would blow up this row's height
/// rather than shrink-wrap it. Popup width is fixed at 420pt (see
/// `showAnchored`), so how many images fit per line is computed from that
/// same fixed width instead, exactly as `PopoverRow.horizontalInset` is.
struct ImageRunRow: View, Equatable {
    let run: [(item: ClipboardItem, index: Int)]
    let selectedIndex: Int
    let selectionNamespace: Namespace.ID
    let markedItemIDs: [UUID]
    let editDeniedShake: ClipboardManager.DeniedShakeSignal?

    static func == (l: ImageRunRow, r: ImageRunRow) -> Bool {
        guard l.run.count == r.run.count else { return false }
        for (a, b) in zip(l.run, r.run) {
            if a.item.id != b.item.id || a.index != b.index || a.item.isPinned != b.item.isPinned {
                return false
            }
        }
        let lSelected = l.run.contains(where: { $0.index == l.selectedIndex })
        let rSelected = r.run.contains(where: { $0.index == r.selectedIndex })
        if lSelected != rSelected { return false }
        if lSelected && l.selectedIndex != r.selectedIndex { return false }
        let lMarked = Set(l.run.map(\.item.id)).intersection(l.markedItemIDs)
        let rMarked = Set(r.run.map(\.item.id)).intersection(r.markedItemIDs)
        if lMarked != rMarked { return false }
        func shakeGen(_ row: ImageRunRow) -> Int {
            row.run.contains(where: { $0.item.id == row.editDeniedShake?.itemID })
                ? row.editDeniedShake?.generation ?? 0 : 0
        }
        if shakeGen(l) != shakeGen(r) { return false }
        return true
    }

    static let cellSize:  CGFloat = 60
    private static let cellGap:   CGFloat = 16
    private static let railWidth: CGFloat = 22
    /// Fixed at 4 regardless of available width — a straightforward "N
    /// per line" read, rather than however many the popup's 420pt happens
    /// to fit.
    static let maxPerLine = 4
    /// 420 (popup width) − 18 (row's own .horizontal padding, 9 each side)
    /// − 22 (rail) − 12 (rail↔divider spacing) − 1 (divider) − 12
    /// (divider↔first image spacing). Enforced as a hard `.frame` width
    /// below, not just used to size things — so a math mistake clips a
    /// cell instead of letting it push past the popup's own fixed-width
    /// bounds.
    private static let lineWidth: CGFloat = 420 - 18 - railWidth - cellGap - 1 - cellGap
    private static let perImageWidth = cellSize + cellGap + 1 + cellGap

    private var lines: [[(item: ClipboardItem, index: Int)]] {
        let fitsPerLine = max(1, Int((Self.lineWidth - Self.cellSize) / Self.perImageWidth) + 1)
        let perLine = min(Self.maxPerLine, fitsPerLine)
        var out: [[(item: ClipboardItem, index: Int)]] = []
        var i = 0
        while i < run.count {
            let end = min(i + perLine, run.count)
            out.append(Array(run[i..<end]))
            i = end
        }
        return out
    }

    var body: some View {
        HStack(alignment: .top, spacing: Self.cellGap) {
            railBadge
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .clipped()
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: Self.cellGap) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        ForEach(Array(line.enumerated()), id: \.element.item.id) { cellIdx, entry in
                            if cellIdx > 0 {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(width: 1, height: Self.cellSize * 0.7)
                                    .padding(.horizontal, Self.cellGap)
                            }
                            ImageRunCell(item: entry.item, index: entry.index,
                                         isSelected: entry.index == selectedIndex,
                                         selectionNamespace: selectionNamespace,
                                         markOrder: markedItemIDs.firstIndex(of: entry.item.id).map { $0 + 1 },
                                         shakeGeneration: editDeniedShake?.itemID == entry.item.id
                                             ? editDeniedShake?.generation ?? 0 : 0)
                        }
                    }
                }
            }
            // Hard clamp — see the `lineWidth` comment above. Nothing in
            // this VStack can ever be wider than the popup itself,
            // regardless of how many images ended up on the widest line.
            .frame(width: Self.lineWidth, alignment: .leading)
            // Same guard PopoverRow puts on its own rowContent. The
            // LazyVStack carries an .animation(spring, value: selectedIndex),
            // so without this every selection change anywhere in the popup
            // implicitly animates this run's layout — image cells sliding and
            // resizing under a scroll that is already animating. The
            // selection highlight keeps its own animation; only the content
            // underneath opts out.
            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
    }

    /// Same tag-label formatting as `PopoverRow.tagLabelText`, for whichever
    /// item this run's rail badge is currently representing.
    private func tagLabelText(for item: ClipboardItem) -> String {
        let visible = item.tags.prefix(4)
        let labels = visible.map { String(localized: String.LocalizationValue($0.label)) }
        let suffix = item.tags.count > 4 ? ", +\(item.tags.count - 4)" : ""
        return labels.joined(separator: ", ") + suffix
    }

    /// Mirrors `PopoverRow.railBadge`'s default/selected split exactly:
    /// the rotated tag-label TEXT at rest, the tag ICON only once
    /// something in this run is actually selected — never a generic
    /// "this is a group of photos" icon.
    @ViewBuilder
    private var railBadge: some View {
        if let selectedEntry = run.first(where: { $0.index == selectedIndex }) {
            Image(systemName: selectedEntry.item.primaryTag.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.secondary.opacity(0.45), in: Circle())
        } else {
            Text(tagLabelText(for: run[0].item))
                .font(.system(size: 8, weight: .black))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary.opacity(0.75))
                .frame(width: 88, alignment: .center)
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Draws an item's image without ever decoding on the main thread while a
/// scroll is running. `ItemThumbnailCache.thumbnail(forData:key:)` decodes
/// synchronously on a cache miss, and a `LazyVStack` materialises rows *during*
/// the scroll animation — so a run of four images meant up to four full
/// CGImageSource decodes inside a single frame, every time you scrolled onto
/// it for the first time. That is the hitch felt specifically when moving into
/// image rows. Here a miss draws the already-in-memory original for a frame or
/// two while the real thumbnail is decoded off-main.
struct CachedThumbnail: View {
    let original: NSImage
    let data: Data
    let key: String
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var decoded: NSImage?

    var body: some View {
        Image(nsImage: decoded ?? ItemThumbnailCache.shared.cachedDataThumbnail(key: key) ?? original)
            .resizable().aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: key) {
                guard decoded == nil,
                      ItemThumbnailCache.shared.cachedDataThumbnail(key: key) == nil else { return }
                let rawData = data
                let thumbKey = key
                let img = await Task.detached(priority: .userInitiated) {
                    ItemThumbnailCache.decodeDataThumbnail(data: rawData)
                }.value
                guard let img, !Task.isCancelled else { return }
                ItemThumbnailCache.shared.storeDataThumbnail(img, key: thumbKey)
                decoded = img
            }
    }
}

/// One image inside an `ImageRunRow` — still a full `ClipboardItem`, so
/// marking/pinning/delete/paste all key off its own id exactly as they do
/// for a normal row; only how it's DRAWN differs.
private struct ImageRunCell: View {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let markOrder: Int?
    let shakeGeneration: Int

    private static let cellSize: CGFloat = ImageRunRow.cellSize

    @State private var shakeOffsetX: CGFloat = 0

    private func runShake() {
        let step: TimeInterval = 0.045
        let amounts: [CGFloat] = [8, -8, 6, -6, 3, -3, 0]
        for (i, amount) in amounts.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) {
                withAnimation(.easeInOut(duration: step)) { shakeOffsetX = amount }
            }
        }
    }

    var body: some View {
        Group {
            if case .image(let img, let data, _) = item.content {
                CachedThumbnail(original: img, data: data, key: item.id.uuidString,
                                size: Self.cellSize,
                                cornerRadius: SelectionHighlightStyle.cellCornerRadius)
            }
        }
        .frame(width: Self.cellSize, height: Self.cellSize)
        .clipShape(RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous))
        .selectionHighlight(isSelected: isSelected, namespace: selectionNamespace,
                             inset: 0, appearance: .cell)
        // The mark number lives on THIS image's own corner — marks are
        // per-item, same as everywhere else in the popup, just drawn
        // small here instead of on a shared rail.
        .overlay(alignment: .topTrailing) {
            if let order = markOrder {
                Text("\(order)")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(Color(red: 0.20, green: 0.78, blue: 0.35), in: Circle())
                    .offset(x: 4, y: -4)
                    .help("Marked #\(order) for multi-paste — hold V to toggle")
            }
        }
        .id(item.id)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SelectedRowFramePreferenceKey.self,
                    value: isSelected ? geo.frame(in: .global) : nil)
            }
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            ClipboardManager.shared.uiSelectItem(at: index)
            ClipboardManager.shared.pasteItemKeepingPopupOpen(id: item.id)
        }
        .onTapGesture(count: 1) {
            let mods = NSEvent.modifierFlags
            if mods.contains(.shift) {
                ClipboardManager.shared.uiRangeSelectItem(to: index)
                return
            }
            if mods.contains(.command) {
                ClipboardManager.shared.uiToggleSelectItem(at: index)
                return
            }
            ClipboardManager.shared.uiSelectItem(at: index)
            ClipboardManager.shared.uiPreviewSelectedItem()
        }
        .onDrag {
            item.makeItemProvider()
        }
        .offset(x: shakeOffsetX)
        .onChange(of: shakeGeneration) { _, new in
            guard new > 0 else { return }
            runShake()
        }
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
    let makeWriters: () -> [NSPasteboardWriting]

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.makeWriters = makeWriters
        return view
    }

    func updateNSView(_ nsView: DragSourceView, context: Context) {
        nsView.makeWriters = makeWriters
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var makeWriters: () -> [NSPasteboardWriting] = { [] }
        private var mouseDownPoint: NSPoint?

        override func hitTest(_ point: NSPoint) -> NSView? { self }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = mouseDownPoint else { return }
            let current = convert(event.locationInWindow, from: nil)
            guard hypot(current.x - start.x, current.y - start.y) > 4 else { return }
            mouseDownPoint = nil

            let writers = makeWriters()
            guard !writers.isEmpty else { return }
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

    let selectionNamespace: Namespace.ID

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

    private static let horizontalInset: CGFloat = 23

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            verticalRail

            RoundedRectangle(cornerRadius: 1.5)
                .fill(markOrder != nil ? Self.markedTint : Color.secondary.opacity(0.25))
                .frame(width: markOrder != nil ? 3 : 1)
                .frame(maxHeight: .infinity)
            rowContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 9).padding(.vertical, 10)
        .frame(minHeight: Self.minRowHeight, maxHeight: Self.maxRowHeight)
        .selectionHighlight(isSelected: isSelected, namespace: selectionNamespace,
                             inset: Self.horizontalInset)
        .offset(x: shakeOffsetX)
        .overlay(alignment: .topTrailing) { trailingIndicators }
        .overlay {
            if ClipboardManager.shared.markedItemIDs.count > 1 {

                MultiItemDragSource {
                    ClipboardManager.shared.orderedMarkedItems.map { $0.makePasteboardWriter() }
                }
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
            .frame(width: 22)
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
            let str = rawStr.rowPreviewPrefix()
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
                .rowPreviewPrefix()
                .replacingOccurrences(of: "\u{FFFC}", with: "")
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
            let plain = rawPlain.rowPreviewPrefix()
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
            CachedThumbnail(original: img, data: data, key: item.id.uuidString,
                            size: 48, cornerRadius: 6)
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
        .overlay(
            Capsule().stroke(Color(hex: "#4E8DF7"), lineWidth: 1)
        )
        .help("Current collection — press 1–9 to switch")
    }
}

struct TagFilterChip: View {
    let tag:     ClipboardTag?
    let selected: Bool

    let namespace: Namespace.ID
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

            .background {
                Capsule(style: .continuous)
                    .fill(Color(hex: "#4E8DF7"))
                    .opacity(selected ? 1 : 0)
                    .matchedGeometryEffect(id: "categoryHighlight", in: namespace, isSource: selected)
                    .shadow(color: Color(hex: "#4E8DF7").opacity(selected ? 0.22 : 0),
                            radius: selected ? 4 : 0, x: 0, y: selected ? 1.5 : 0)
            }

            .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
            .overlay(Capsule(style: .continuous)
                .stroke(selected ? Color.clear : Color.primary.opacity(0.06), lineWidth: 1))

            .scaleEffect(selected ? SelectionHighlightStyle.scale : 1.0)
            .animation(SelectionHighlightStyle.spring, value: selected)
        }
        .buttonStyle(.plain)
    }
}

struct DynamicHint: Identifiable, Equatable {
    let id: String
    let key: String
    let label: String
}

struct DynamicHintText: View {
    let key: String
    let label: String

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

        .background(isPressed ? Color.accent : Color.surfaceHi, in: Capsule())
        .overlay(Capsule().stroke(isPressed ? Color.clear : Color.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.1), value: isPressed)
    }
}

final class PopupHintOverlay {
    private let panel: NSPanel

    private static let height: CGFloat = 38

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

private struct PopupHintRow: View {
    @ObservedObject private var manager = ClipboardManager.shared
    private let auth = AuthManager.shared

    private var hints: [DynamicHint] {
        guard manager.showPopupInteractionHints, !manager.isInlineEditing,
              !manager.popupPinnedOpen else { return [] }

        let markedCount = manager.markedItemIDs.count
        let previewOpen = manager.isItemPreviewVisible
        var hints: [DynamicHint] = []

        if markedCount > 1 {
            hints.append(DynamicHint(id: "g-group", key: "G", label: "Group"))
        }

        if previewOpen {
            hints.append(DynamicHint(id: "space2-pin", key: "Space ×2", label: "Pin"))
            hints.append(DynamicHint(id: "space-close", key: "Space", label: "Close preview"))
        } else {
            hints.append(DynamicHint(id: "space-preview", key: "Space", label: "Preview"))
        }
        if auth.transformsEnabled {
            hints.append(DynamicHint(id: "x-transform", key: "X", label: "Transform"))
        }

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
