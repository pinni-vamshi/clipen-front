import AppKit
import SwiftUI

final class PreviewOverlayWindow: NSObject, NSPopoverDelegate {
    private var wantsVisible = false

    func popoverDidShow(_ notification: Notification) {
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
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

    func show() {
        wantsVisible = true
        showAnchored(to: NSEvent.mouseLocation)
    }

    func hide() {
        wantsVisible = false
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
    }

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

        let aboveFits = (anchor.y - bodyH - 6) >= screen.minY + margin
        let preferredEdge: NSRectEdge = aboveFits ? .maxY : .minY

        let popoverView = PopoverPreviewView(visibleCount: slots)
        popover.contentSize = NSSize(width: 420, height: bodyH)
        if let hostingController = popover.contentViewController as? NSHostingController<PopoverPreviewView> {
            hostingController.rootView = popoverView
        } else {
            popover.contentViewController = NSHostingController(rootView: popoverView)
        }

        guard !popover.isShown else { return }

        anchorPanel.setFrame(NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1), display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        popover.animates = false
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: preferredEdge)
        popover.animates = true
        popover.clipenAnimateIn()
    }

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

struct PopoverPreviewView: View {

    let visibleCount: Int

    @ObservedObject private var manager = ClipboardManager.shared
    private let auth = AuthManager.shared

    private var items: [ClipboardItem] { manager.displayItems }
    private var selectedIndex: Int     { manager.selectedIndex }

    private static let rowH: CGFloat = 72

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

    private var header: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            headerContent
        }
    }

    private var headerContent: some View {
        HStack(spacing: 14) {
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

            if !manager.popupPinnedOpen {
                FlatHint(key: manager.reverseCycleUsesB ? "B" : "⇧V",
                         label: "Prev", isActive: manager.popupHintShiftV)

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

                SpaceKeyFlatHint(label: "Preview", isActive: manager.popupHintSpace)

                DoubleSpaceKeyFlatHint(label: "Refer", isActive: manager.popupHintSpaceDoubleTap)

                FlatHint(key: "S", label: "Share", isActive: manager.inShareStage)
            }

            IconFlatHint(icon: "cursorarrow.click", label: "Preview")
            IconFlatHint(icon: "cursorarrow.click.2", label: "Paste")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
                        LazyVStack(spacing: 0) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                PopoverRow(item: item, index: idx,
                                           isSelected: idx == selectedIndex,
                                           markOrder: manager.markOrder(for: item.id),
                                           showColorSwatches: manager.showColorSwatches)
                                    .equatable()
                                    .id(item.id)
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

    static func == (l: PopoverRow, r: PopoverRow) -> Bool {
        l.item.id == r.item.id &&
        l.index == r.index &&
        l.isSelected == r.isSelected &&
        l.markOrder == r.markOrder &&
        l.showColorSwatches == r.showColorSwatches &&
        l.item.isPinned == r.item.isPinned &&
        l.item.urlTitle == r.item.urlTitle &&
        l.item.diffBadge == r.item.diffBadge &&
        l.item.userNote == r.item.userNote &&
        l.item.metadataSummary == r.item.metadataSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            rowHeader
            rowContent.padding(.leading, 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 6)
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

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 14, height: 14)
                    .background(Color.blue, in: Circle())
                    .help("Pinned — hold P to unpin")
            }

            Spacer()

            if let order = markOrder {
                Text("\(order). marked")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.20, green: 0.78, blue: 0.35),
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
            let plain = rawPlain.displayTrimmedLeading
            VStack(alignment: .leading, spacing: 2) {
                Text(plain).font(.system(size: 12)).lineLimit(1).foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let cells = TableCellExtractor.cells(for: item) {
                    MiniTablePreview(cells: cells)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .html(_, let rawPlain):
            let plain = rawPlain.displayTrimmedLeading
            VStack(alignment: .leading, spacing: 2) {
                Text(plain).font(.system(size: 12)).lineLimit(1).foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let cells = TableCellExtractor.cells(for: item) {
                    MiniTablePreview(cells: cells)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        case .image(let img, let data, _):
            VStack(alignment: .leading, spacing: 2) {
                Image(nsImage: ItemThumbnailCache.shared.thumbnail(forData: data, key: item.id.uuidString) ?? img)
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 280, maxHeight: 48, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    func clipenAnimateIn(duration: TimeInterval = 0.17) {
        guard let view = contentViewController?.view else { return }
        view.wantsLayer = true
        if let layer = view.layer {
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
