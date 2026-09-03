import AppKit
import SwiftUI

final class PreviewOverlayWindow: NSObject, NSPopoverDelegate {
    private var wantsVisible = false

    var onHide: (() -> Void)?

    private var hideCalledAt: Date?
    private static let hideAttributionWindow: TimeInterval = 1.0

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
            onHide?()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let hideCalledAt, Date().timeIntervalSince(hideCalledAt) < Self.hideAttributionWindow {
            return
        }

        let wasVisible = wantsVisible
        wantsVisible = false
        anchorPanel.orderOut(nil)
        hintOverlay.hide()
        if wasVisible { onHide?() }
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

        hideCalledAt = nil
        wantsVisible = true
        showAnchored(to: NSEvent.mouseLocation)
    }

    func hide() {

        let wasVisible = wantsVisible
        hideCalledAt = Date()
        wantsVisible = false

        if popover.isShown {
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
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

    /// Last row the list was actually scrolled to, so a selection change
    /// that stays inside the same row (stepping through a run of images)
    /// doesn't re-issue an animated scroll to where it already is.
    @State private var lastScrolledTarget: AnyHashable?

    private var items: [ClipboardItem] { manager.displayItems }

    /// Cached on the manager alongside `displayItems` — this used to be a
    /// computed property here, re-chunking the entire list on every body
    /// evaluation (and again inside `scrollTarget`), several times per
    /// keystroke.
    private var rowSegments: [PopupRowSegment] { manager.rowSegments }

    private func coarseScrollTarget(for idx: Int) -> AnyHashable {
        scrollTarget(for: idx).coarse
    }

    private func scrollTarget(for idx: Int) -> (coarse: AnyHashable, needsRefine: Bool) {
        guard items.indices.contains(idx) else {
            let fallback = items.first.map { AnyHashable($0.id) } ?? AnyHashable("")
            return (fallback, false)
        }
        if ClipboardManager.isImageRunEligible(items[idx].content) {
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
                aiFactStrip
                trialBanner
                updateAvailableBanner
                firstCycleHint
                detailsHint
                rememberForeverBanner

                Divider().padding(.bottom, 4)
                SelectionScope(selection: manager.selection) { rowArea(selectedIndex: $0) }
                Divider()
                SelectionScope(selection: manager.selection) { footer(selectedIndex: $0) }
            }
            .onPreferenceChange(SelectedRowFramePreferenceKey.self) { frame in

                let previous = manager.selectedRowMeasuredFrame
                let movedMeaningfully: Bool
                if let previous, let frame {
                    movedMeaningfully = abs(frame.midY - previous.midY) > 3
                        || abs(frame.midX - previous.midX) > 3
                } else {
                    movedMeaningfully = (previous == nil) != (frame == nil)
                }
                guard movedMeaningfully else { return }
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

                if let intentTag = manager.searchIntentTag {
                    TagChip(tag: intentTag, compact: true)
                        .transition(.scale.combined(with: .opacity))
                }

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
    private var aiFactStrip: some View {
        let chips = manager.popupFactChips
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        AIFactChipView(chip: chip) {

                            if let idx = manager.indexInDisplayItems(id: chip.itemID) {
                                manager.selectedIndex = idx
                                manager.selectionDidChange()
                            }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }
            .frame(height: 40)
            .background(Color.accentColor.opacity(0.05))
        }
    }

    @ViewBuilder
    private var updateAvailableBanner: some View {
        if let version = manager.availableUpdateVersion {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("New update available — \(version)")
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Button {
                    AppDelegate.shared?.checkForUpdates()
                } label: {
                    Text("Update")
                        .font(.system(size: 11, weight: .bold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(Self.bannerBlue)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    private static let bannerBlue = Color(red: 0.04, green: 0.36, blue: 0.94)

    @ViewBuilder
    private var trialBanner: some View {
        if pro.paywallApplies, !pro.isPro, pro.trialDaysRemaining > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(trialBannerText)
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Button {
                    AuthManager.shared.registerActionUsage(actionID: "action.paywall_subscribe_click")
                    NSWorkspace.shared.open(DeviceIdentity.pricingURL)
                } label: {
                    Text("Upgrade")
                        .font(.system(size: 11, weight: .bold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(Self.bannerBlue)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    private var trialBannerText: String {
        let days = pro.trialDaysRemaining
        return days == 1 ? "1 day left in your free trial" : "\(days) days left in your free trial"
    }

    @ViewBuilder
    private var rememberForeverBanner: some View {
        if let name = manager.activeCollection,
           manager.rememberForeverBannerOpensRemaining > 0,
           !manager.rememberForeverCollections.contains(name) {
            HStack(spacing: 6) {
                Text("New: keep")
                    .font(.system(size: 11, weight: .medium))
                HStack(spacing: 4) {
                    Text("“\(name)”").font(.system(size: 11, weight: .semibold))

                    RememberForeverToggle(isOn: manager.rememberForeverCollections.contains(name)) {
                        manager.toggleRememberForever(name)
                    }
                }
                Text("forever, never trimmed by the ring limit")
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                Button {
                    manager.toggleRememberForever(name)
                } label: {
                    Text("Enable")
                        .font(.system(size: 11, weight: .bold))
                        .underline()
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(Self.bannerBlue)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var detailsHint: some View {
        if manager.showDetailsHint {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle").font(.system(size: 10, weight: .semibold))
                Text("Tip: Press D to view and paste individual details")
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()

                Button {
                    manager.dismissDetailsHint()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Dismiss this tip")
            }
            .foregroundColor(Self.bannerBlue)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var firstCycleHint: some View {
        if manager.showFirstCycleHint {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Tip: Tap X to transform the highlighted item")
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .foregroundColor(Self.bannerBlue)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .transition(.opacity)
        }
    }

    private func rowArea(selectedIndex: Int) -> some View {
        normalRingArea(selectedIndex: selectedIndex)
            .frame(height: Self.rowH * CGFloat(visibleCount), alignment: .top)
    }

    private func normalRingArea(selectedIndex: Int) -> some View {
        Group {
            if items.isEmpty {
                if !manager.isHistoryFullyLoaded {

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
                            // Computed once per pass, not once per row:
                            // markOrder(for:) rebuilt and re-sorted the whole
                            // mark order on every call, so a 5-row viewport
                            // did that work five times per body evaluation.
                            let markOrders = manager.unifiedMarkOrder().items
                            ForEach(Array(segments.enumerated()), id: \.element.id) { segIdx, segment in
                                switch segment {
                                case .single(let item, let idx):
                                    PopoverRow(item: item, index: idx,
                                               isSelected: idx == selectedIndex,
                                               markOrder: markOrders[item.id],
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

                                        .id(segment.id)
                                }
                                if segIdx < segments.count - 1 {
                                    Divider().padding(.leading, 38).opacity(0.25)
                                }
                            }
                        }

                        .padding(.top, 14)
                        .padding(.bottom, 10)
                    }
                    .onChange(of: selectedIndex) { _, newIdx in
                        guard items.indices.contains(newIdx) else { return }
                        let targetID = items[newIdx].id
                        let (coarseID, needsRefine) = scrollTarget(for: newIdx)

                        // Stepping between images inside one run keeps the
                        // same target row, which is already centred — the
                        // scroll had nothing to do, but still opened a
                        // spring transaction over the whole ScrollView on
                        // every keystroke, on top of the row's own
                        // re-render.
                        if coarseID != lastScrolledTarget {
                            lastScrolledTarget = coarseID
                            withAnimation(SelectionHighlightStyle.spring) {
                                proxy.scrollTo(coarseID, anchor: .center)
                            }
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
                        let coarse = coarseScrollTarget(for: selectedIndex)
                        lastScrolledTarget = coarse
                        proxy.scrollTo(coarse, anchor: .center)
                        DispatchQueue.main.async {
                            guard items.indices.contains(selectedIndex),
                                  items[selectedIndex].id == targetID else { return }
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }
                    .onChange(of: manager.popupOpenGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        let targetID = items[selectedIndex].id
                        let coarse = coarseScrollTarget(for: selectedIndex)
                        lastScrolledTarget = coarse
                        proxy.scrollTo(coarse, anchor: .center)
                        DispatchQueue.main.async {
                            guard items.indices.contains(selectedIndex),
                                  items[selectedIndex].id == targetID else { return }
                            proxy.scrollTo(targetID, anchor: .center)
                        }
                    }

                    .onChange(of: manager.collectionSwitchGeneration) { _, _ in
                        guard items.indices.contains(selectedIndex) else { return }
                        let idx = selectedIndex
                        let targetID = items[idx].id
                        let (coarseID, needsRefine) = scrollTarget(for: idx)

                        lastScrolledTarget = coarseID
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

    private func footer(selectedIndex: Int) -> some View {
        Text(items.isEmpty
             ? "0 of 0"
             : "\(min(selectedIndex + 1, items.count)) of \(items.count)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}

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
        let lSelected = l.isAnySelected
        let rSelected = r.isAnySelected
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

    static let cellSize:  CGFloat = 51
    private static let cellGap:   CGFloat = 16
    private static let railWidth: CGFloat = 22

    static let maxPerLine = 4

    private static let lineWidth: CGFloat = 420
        - SelectionHighlightStyle.rowInset * 2
        - 18 - railWidth - SelectionHighlightStyle.rowRailSpacing - 1 - SelectionHighlightStyle.rowRailSpacing

    private var isAnySelected: Bool { run.contains(where: { $0.index == selectedIndex }) }

    var body: some View {
        HStack(alignment: .top, spacing: SelectionHighlightStyle.rowRailSpacing) {
            railBadge
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity, alignment: .center)
                .padding(.vertical, 2)
                .clipped()
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 1)
                .frame(maxHeight: .infinity)

            HStack(spacing: 0) {
                ForEach(Array(run.enumerated()), id: \.element.item.id) { cellIdx, entry in
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
                        .equatable()
                }
            }

            .frame(width: Self.lineWidth, alignment: .leading)

            .transaction { $0.animation = nil }
        }
        .padding(.horizontal, 9).padding(.vertical, 10)

        .selectionHighlight(isSelected: isAnySelected,
                            namespace: selectionNamespace,
                            inset: SelectionHighlightStyle.rowInset,
                            appearance: .rowSurface)

        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SelectedRowFramePreferenceKey.self,
                    value: isAnySelected ? geo.frame(in: .global) : nil)
            }
        )
    }

    private func tagLabelText(for item: ClipboardItem) -> String {
        let visible = item.tags.prefix(4)
        let labels = visible.map { String(localized: String.LocalizationValue($0.label)) }
        let suffix = item.tags.count > 4 ? ", +\(item.tags.count - 4)" : ""
        return labels.joined(separator: ", ") + suffix
    }

    private func sourceAppLabelText(for item: ClipboardItem) -> String {
        item.sourceAppName ?? tagLabelText(for: item)
    }

    private func sourceAppLabelText(for run: [(item: ClipboardItem, index: Int)]) -> String {
        let appNames = run.map { $0.item.sourceAppName }
        let known = appNames.compactMap { $0 }
        let distinct = Set(known)
        if distinct.count == 1, let only = distinct.first {
            return only
        }
        if distinct.count > 1 {
            return String(localized: "\(distinct.count) apps")
        }
        return tagLabelText(for: run[0].item)
    }

    @State private var analysisRingWidth: CGFloat = 1

    private func startOrStopRingAnimation(running: Bool, resumeMidCycle: Bool = false) {
        // Stepping between images in a run changes the badge's item, which
        // fires the id-based .onChange on every keystroke. Re-running this
        // each time meant re-installing a `.repeatForever` animation (a
        // known stutter source) or kicking off a fresh easeOut plus a
        // @State write that re-invalidated the row mid-flight. When nothing
        // is analysing and the ring is already at rest, there is nothing to
        // start or stop.
        guard running || analysisRingWidth != 1 else { return }
        startOrStopAnalysisPulse($analysisRingWidth, active: running,
                                 restValue: 1, activeValue: 2.6,
                                 activeDuration: 0.6, restDuration: 0.2,
                                 resumeMidCycle: resumeMidCycle)
    }

    @ViewBuilder
    private var railBadge: some View {
        if let selectedEntry = run.first(where: { $0.index == selectedIndex }) {
            let analysisState = AIStructuringService.shared.state(for: selectedEntry.item)
            let analysing = analysisState == .running
            let hasAnalysis: Bool = { if case .done = analysisState { return true }; return false }()
            Image(systemName: selectedEntry.item.primaryTag.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hasAnalysis ? .black.opacity(0.75) : .white)
                .frame(width: 20, height: 20)
                .background(hasAnalysis ? Color.white : Color.secondary.opacity(0.45), in: Circle())
                .overlay {
                    if analysing {
                        Circle()
                            .strokeBorder(Color.pink, lineWidth: analysisRingWidth)
                            .frame(width: 20, height: 20)
                    } else if hasAnalysis {
                        Circle()
                            .strokeBorder(Color.blue, lineWidth: 1)
                            .frame(width: 20, height: 20)
                    }
                }
                .onChange(of: analysing) { _, running in
                    startOrStopRingAnimation(running: running)
                }
                .onChange(of: selectedEntry.item.id) { _, _ in
                    startOrStopRingAnimation(running: analysing, resumeMidCycle: true)
                }
                .onAppear {
                    startOrStopRingAnimation(running: analysing, resumeMidCycle: true)
                }
        } else {
            Text(sourceAppLabelText(for: run))
                .font(.system(size: 8, weight: .black))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(.secondary.opacity(0.75))
                .frame(width: 88, alignment: .center)
                .rotationEffect(.degrees(-90))
        }
    }
}

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

                let source = original
                let thumbKey = key
                let img = await Task.detached(priority: .userInitiated) {
                    ItemThumbnailCache.resizedThumbnail(from: source, maxPixel: 360)
                }.value
                guard let img, !Task.isCancelled else { return }
                ItemThumbnailCache.shared.storeDataThumbnail(img, key: thumbKey)
                decoded = img
            }
    }
}

private struct ImageRunCell: View, Equatable {
    let item: ClipboardItem
    let index: Int
    let isSelected: Bool
    let selectionNamespace: Namespace.ID
    let markOrder: Int?
    let shakeGeneration: Int

    /// Without this (and the `.equatable()` at the call site) every step
    /// through a row of images re-evaluated all four cells' bodies, because
    /// the parent row legitimately has to re-render when `selectedIndex`
    /// moves within the run. Only the two cells whose selection actually
    /// changed need to rebuild.
    static func == (l: ImageRunCell, r: ImageRunCell) -> Bool {
        l.item.id == r.item.id
            && l.index == r.index
            && l.isSelected == r.isSelected
            && l.markOrder == r.markOrder
            && l.shakeGeneration == r.shakeGeneration
    }

    private static let cellSize: CGFloat = ImageRunRow.cellSize

    @State private var shakeOffsetX: CGFloat = 0

    private func runShake() { runDeniedShake($shakeOffsetX) }

    var body: some View {
        Group {
            switch item.content {
            case .image(let img, let data, _):
                CachedThumbnail(original: img, data: data, key: item.id.uuidString,
                                size: Self.cellSize,
                                cornerRadius: SelectionHighlightStyle.cellCornerRadius)
            case .file(let url):
                CachedFileThumbnail(url: url, size: Self.cellSize)
            default:
                EmptyView()
            }
        }
        .frame(width: Self.cellSize, height: Self.cellSize)
        .clipShape(RoundedRectangle(cornerRadius: SelectionHighlightStyle.cellCornerRadius, style: .continuous))
        .selectionHighlight(isSelected: isSelected, namespace: selectionNamespace,
                             inset: 0, appearance: .cell)

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

    private func runShake() { runDeniedShake($shakeOffsetX) }

    private static let minRowHeight: CGFloat = 56
    private static let maxRowHeight: CGFloat = 104

    private static let horizontalInset: CGFloat = SelectionHighlightStyle.rowInset

    private static let fileIconSize: CGFloat = 48
    private static let folderIconSize: CGFloat = 60

    var body: some View {
        HStack(alignment: .top, spacing: SelectionHighlightStyle.rowRailSpacing) {
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
    @State private var analysisRingWidth: CGFloat = 1

    private func startOrStopRingAnimation(running: Bool, resumeMidCycle: Bool = false) {
        // Stepping between images in a run changes the badge's item, which
        // fires the id-based .onChange on every keystroke. Re-running this
        // each time meant re-installing a `.repeatForever` animation (a
        // known stutter source) or kicking off a fresh easeOut plus a
        // @State write that re-invalidated the row mid-flight. When nothing
        // is analysing and the ring is already at rest, there is nothing to
        // start or stop.
        guard running || analysisRingWidth != 1 else { return }
        startOrStopAnalysisPulse($analysisRingWidth, active: running,
                                 restValue: 1, activeValue: 2.6,
                                 activeDuration: 0.6, restDuration: 0.2,
                                 resumeMidCycle: resumeMidCycle)
    }

    @ViewBuilder
    private var railBadge: some View {
        if let order = markOrder {
            Text("\(order)")
                .font(.system(size: 9, weight: .black))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Self.markedTint, in: Circle())
                .help("Marked #\(order) for multi-paste — hold V to toggle")
        } else if item.isUncaptured {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.orange, in: Circle())
                .help("macOS wouldn't let Clipen copy this — pasting uses the system clipboard instead")
        } else if isSelected {
            let analysisState = AIStructuringService.shared.state(for: item)
            let analysing = analysisState == .running
            let hasAnalysis: Bool = { if case .done = analysisState { return true }; return false }()
            Image(systemName: item.primaryTag.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(hasAnalysis ? .black.opacity(0.75) : .white)
                .frame(width: 20, height: 20)
                .background(hasAnalysis ? Color.white : Color.secondary.opacity(0.45), in: Circle())

                .overlay {
                    if analysing {
                        Circle()
                            .strokeBorder(Color.pink, lineWidth: analysisRingWidth)
                            .frame(width: 20, height: 20)
                    } else if hasAnalysis {
                        Circle()
                            .strokeBorder(Color.blue, lineWidth: 1)
                            .frame(width: 20, height: 20)
                    }
                }

                .onChange(of: analysing) { _, running in
                    startOrStopRingAnimation(running: running)
                }
                .onChange(of: item.id) { _, _ in
                    startOrStopRingAnimation(running: analysing, resumeMidCycle: true)
                }
                .onAppear {
                    startOrStopRingAnimation(running: analysing, resumeMidCycle: true)
                }
        } else if item.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
                .help("Pinned — hold P to unpin")
        } else {
            Text(sourceAppLabelText)
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

    private var sourceAppLabelText: String {
        item.sourceAppName ?? tagLabelText
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

                    if let cells = TableCellExtractor.cells(for: item),
                       TableCellExtractor.isDataTable(cells) {
                        MiniTablePreview(cells: cells)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !plain.isEmpty {
                        Text(plain).font(.system(size: 12)).lineLimit(3).foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .html(_, let rawPlain):
            let plain = rawPlain.rowPreviewPrefix()
            VStack(alignment: .leading, spacing: 2) {
                if let cells = TableCellExtractor.cells(for: item),
                   TableCellExtractor.isDataTable(cells) {
                    MiniTablePreview(cells: cells)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(plain).font(.system(size: 12)).lineLimit(3).foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .file(let url) where FileKindDetector.isImageFile(url):
            CachedFileThumbnail(url: url, size: 48)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .file(let url) where FileKindDetector.isDirectory(url):
            HStack(alignment: .top, spacing: 10) {
                VStack(spacing: 3) {
                    Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                        .resizable().frame(width: Self.folderIconSize, height: Self.folderIconSize)
                    Text(url.lastPathComponent)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                        .frame(width: Self.folderIconSize)
                }
                FolderContentsPreview(url: url, itemID: item.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        case .file(let url):
            HStack(spacing: 6) {
                fileThumbnail(url, size: 28)
                Text(url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .files(let urls):

            HStack(spacing: 4) {
                ForEach(Array(urls.prefix(ImageRunRow.maxPerLine).enumerated()), id: \.offset) { _, url in
                    fileThumbnail(url, size: Self.fileIconSize)
                }
                Spacer(minLength: 8)
                Text("\(urls.count)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct FolderContentsPreview: View {
    let url: URL
    let itemID: UUID

    struct Group: Identifiable {
        let id = UUID()

        let representative: URL
        let count: Int
    }
    struct Level: Identifiable {
        let id = UUID()
        let depth: Int
        let groups: [Group]
    }

    private static let cache = RecentItemCache<[Level]>(capacity: 8)
    private nonisolated static let maxDepth = 3
    private nonisolated static let maxGroupsPerLevel = 4
    private nonisolated static let maxLevels = 4

    private static func iconSize(forDepth depth: Int) -> CGFloat {
        max(12, 26 - CGFloat(depth) * 5.5)
    }

    @State private var levels: [Level]?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ForEach(levels ?? []) { level in
                HStack(alignment: .center, spacing: 5) {
                    ForEach(level.groups) { group in
                        VStack(spacing: 1) {
                            Image(nsImage: ClipenIconCache.shared.fileIcon(for: group.representative))
                                .resizable()
                                .frame(width: Self.iconSize(forDepth: level.depth),
                                       height: Self.iconSize(forDepth: level.depth))
                            Text("\(group.count)")
                                .font(.system(size: max(7, 10 - CGFloat(level.depth)), weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .task(id: itemID) {
            if let cached = Self.cache.value(for: itemID) {
                levels = cached
                return
            }
            let folderURL = url
            let scanned = await Task.detached(priority: .utility) {
                FolderContentsPreview.scan(folderURL)
            }.value
            guard !Task.isCancelled else { return }
            Self.cache.insert(scanned, for: itemID)
            levels = scanned
        }
    }

    nonisolated private static func scan(_ root: URL) -> [Level] {
        let fm = FileManager.default
        var out: [Level] = []
        var frontier: [URL] = [root]
        var depth = 0

        while depth < maxDepth, !frontier.isEmpty, out.count < maxLevels {
            var byKind: [String: (representative: URL, count: Int)] = [:]
            var nextFrontier: [URL] = []

            for dir in frontier {
                guard let entries = try? fm.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]) else { continue }

                for entry in entries {
                    let isDir = FileKindDetector.isDirectory(entry)
                    if isDir { nextFrontier.append(entry) }

                    let kind = isDir ? "\u{1}dir" : entry.pathExtension.lowercased()
                    if let existing = byKind[kind] {
                        byKind[kind] = (existing.representative, existing.count + 1)
                    } else {
                        byKind[kind] = (entry, 1)
                    }
                }
            }

            if !byKind.isEmpty {
                let groups = byKind.values
                    .sorted { $0.count > $1.count }
                    .prefix(maxGroupsPerLevel)
                    .map { Group(representative: $0.representative, count: $0.count) }
                out.append(Level(depth: depth, groups: Array(groups)))
            }

            frontier = nextFrontier
            depth += 1
        }
        return out
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

struct RememberForeverToggle: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isOn ? Color.green : Color.black)
                .frame(width: 15, height: 15)
                .overlay(
                    Image(systemName: "infinity")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                )
        }
        .buttonStyle(.plain)
        .help(isOn
              ? "Remembered forever — never removed by the ring limit. Click to stop."
              : "Click to remember this collection forever, exempt from the ring limit")
    }
}

struct CollectionChip: View {
    let name: String?
    @ObservedObject private var manager = ClipboardManager.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "tray.full")
                .font(.system(size: 9, weight: .semibold))
            Text(name ?? String(localized: "All"))
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            if let name {
                RememberForeverToggle(isOn: manager.rememberForeverCollections.contains(name)) {
                    manager.toggleRememberForever(name)
                }

                .padding(.trailing, 1)
            }
        }
        .foregroundColor(.secondary.opacity(0.85))
        .padding(.leading, 7)
        .padding(.trailing, name != nil ? 3 : 7)
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
    /// The keycap flags live on their own observable object now, so that
    /// flipping one re-renders this small bar and nothing else.
    @ObservedObject private var hintState = ClipboardManager.shared.popupHints
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
        case "g-group":       return hintState.popupHintG
        case "space2-pin",
             "space-close",
             "space-preview": return hintState.popupHintSpace || hintState.popupHintSpaceDoubleTap
        case "x-transform":   return hintState.popupHintX || hintState.popupHintXHold
        case "holdv-mark":    return hintState.popupHintVMark
        case "v-next":        return hintState.popupHintV
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

/// One rendered row of the popup list: either a single item, or a run of
/// consecutive images batched onto one line. Lives at file scope (and its
/// construction on ClipboardManager) so it can be cached with
/// `displayItems` rather than recomputed on every SwiftUI body pass.
enum PopupRowSegment: Identifiable {
    case single(item: ClipboardItem, index: Int)
    case imageRun([(item: ClipboardItem, index: Int)])

    var id: String {
        switch self {
        case .single(let item, _): return item.id.uuidString
        case .imageRun(let run):   return "run-" + (run.first?.item.id.uuidString ?? "")
        }
    }
}

extension ClipboardManager {
    static func isImageRunEligible(_ content: ClipboardContent) -> Bool {
        switch content {
        case .image: return true
        case .file(let url): return FileKindDetector.isImageFile(url)
        default: return false
        }
    }

    var rowSegments: [PopupRowSegment] {
        if let cached = _rowSegments { return cached }
        let computed = Self.computeRowSegments(for: displayItems)
        _rowSegments = computed
        return computed
    }

    static func computeRowSegments(for items: [ClipboardItem]) -> [PopupRowSegment] {
        var result: [PopupRowSegment] = []
        var run: [(item: ClipboardItem, index: Int)] = []

        func flushRun() {
            guard !run.isEmpty else { return }
            // Chunk from the OLD end of the run forward, not the new end.
            // New captures are always prepended to `items` (index 0), so a
            // run's tail-relative position never moves — only its
            // front-relative position does. Slicing front-first here used to
            // mean every chunk boundary after the first re-shifted on every
            // new image capture, changing `.imageRun` chunk identity (keyed
            // on each chunk's first member) for chunks whose actual members
            // barely changed — SwiftUI then tore down and rebuilt those rows
            // instead of diffing them, which is what read as jerky/jumpy
            // whenever several images were copied back to back. Anchoring
            // chunk boundaries to the tail means only the newest (leading,
            // still-growing) chunk's identity changes; every older chunk's
            // membership — and therefore its id — is invariant to further
            // insertions at the front.
            let n = run.count
            let remainder = n % ImageRunRow.maxPerLine
            var chunks: [[(item: ClipboardItem, index: Int)]] = []
            if remainder > 0 {
                chunks.append(Array(run[0..<remainder]))
            }
            var i = remainder
            while i < n {
                chunks.append(Array(run[i..<(i + ImageRunRow.maxPerLine)]))
                i += ImageRunRow.maxPerLine
            }
            for chunk in chunks {
                if chunk.count >= 2 {
                    result.append(.imageRun(chunk))
                } else {
                    result.append(.single(item: chunk[0].item, index: chunk[0].index))
                }
            }
            run = []
        }
        for (idx, item) in items.enumerated() {
            if isImageRunEligible(item.content) {
                run.append((item, idx))
            } else {
                flushRun()
                result.append(.single(item: item, index: idx))
            }
        }
        flushRun()
        return result
    }
}

/// Re-evaluates only its own content when the selection moves.
///
/// `selectedIndex` used to be `@Published` on ClipboardManager, which
/// PopoverPreviewView observes wholesale — so moving the cursor one row
/// re-evaluated the entire popup body: search bar, category strip, AI fact
/// strip, every banner, the footer. Only the row list and the "N of M"
/// counter actually care. Selection now lives on its own tiny observable,
/// and only the scopes below subscribe to it, so navigating repaints two
/// rows and a counter instead of the whole popup.
private struct SelectionScope<Content: View>: View {
    @ObservedObject var selection: ClipboardManager.SelectionState
    @ViewBuilder let content: (Int) -> Content

    var body: some View { content(selection.index) }
}
