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

    private(set) var pageOwnerBundleIDs: [UUID: Set<String>] = [:]
    private(set) var pageOwnerContext: [UUID: [String: String]] = [:]
    @Published private(set) var pageTags: [UUID: [ReferenceTag]] = [:]
    private var dismissedTags: Set<TagKey> = []
    private struct TagKey: Hashable { let pageID: UUID; let label: String }

    private(set) var dismissedOwnerBundleIDs: [UUID: Set<String>] = [:]

    func isDismissed(bundleID: String, pageID: UUID) -> Bool {
        dismissedOwnerBundleIDs[pageID]?.contains(bundleID) == true
    }

    private func addTag(_ label: String, kind: ReferenceTag.Kind, bundleID: String? = nil, toPage pageID: UUID) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = TagKey(pageID: pageID, label: trimmed)
        guard !dismissedTags.contains(key) else { return }
        var tags = pageTags[pageID] ?? []
        guard !tags.contains(where: { $0.label == trimmed }) else { return }
        tags.append(ReferenceTag(label: trimmed, kind: kind, bundleID: bundleID))
        pageTags[pageID] = tags
    }

    private func autoTag(pageID: UUID, bundleID: String?, context: String?) {
        guard let bundleID, !isDismissed(bundleID: bundleID, pageID: pageID) else { return }
        addTag(Self.appDisplayName(for: bundleID), kind: .app, bundleID: bundleID, toPage: pageID)
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

    func removeTag(_ tagID: UUID, fromPage pageID: UUID) {
        guard var tags = pageTags[pageID] else { return }
        guard let removed = tags.first(where: { $0.id == tagID }) else { return }
        tags.removeAll { $0.id == tagID }
        pageTags[pageID] = tags
        dismissedTags.insert(TagKey(pageID: pageID, label: removed.label))

        if removed.kind == .app, let bundleID = removed.bundleID {
            pageOwnerBundleIDs[pageID]?.remove(bundleID)
            dismissedOwnerBundleIDs[pageID, default: []].insert(bundleID)
        }
    }

    @Published var isCollapsed: Bool = false
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

    func linkCurrentPage(toApp bundleID: String, context: String? = nil) {

        dismissedOwnerBundleIDs[current.id]?.remove(bundleID)
        dismissedTags.remove(TagKey(pageID: current.id, label: Self.appDisplayName(for: bundleID)))
        pageOwnerBundleIDs[current.id, default: []].insert(bundleID)
        if let context { pageOwnerContext[current.id, default: [:]][bundleID] = context }
        autoTag(pageID: current.id, bundleID: bundleID, context: context)
    }

    func attachContext(_ context: String, toPage pageID: UUID, bundleID: String) {
        guard pages.contains(where: { $0.id == pageID }) else { return }
        guard !isDismissed(bundleID: bundleID, pageID: pageID) else { return }
        pageOwnerContext[pageID, default: [:]][bundleID] = context
        autoTag(pageID: pageID, bundleID: bundleID, context: context)
    }

    @discardableResult
    func jumpToPage(id: UUID) -> Bool {
        guard let match = pages.firstIndex(where: { $0.id == id }) else { return false }
        lastMoveDirection = match >= index ? .trailing : .leading
        index = match
        return true
    }

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
    private let similarSidebarWidth: CGFloat = 220
    private var similarGrewLeft = false

    private var expandedFrame: NSRect?
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
            ))
        hostingView.wantsLayer = true
        hostingView.layer?.borderWidth = 0
        self.contentView = hostingView

        self.contentMinSize = Self.expandedMinSize

        resizeForCurrentPage(centeredOffset: offset)
    }

    func addPage(_ item: ClipboardItem, focusContent: Bool, ownerBundleID: String?, ownerContext: String? = nil) {
        carousel.addPage(item, ownerBundleID: ownerBundleID, ownerContext: ownerContext, focusContent: focusContent)
        resizeForCurrentPage(centeredOffset: 0)
    }

    func closeCurrentPage() {
        guard carousel.pages.count > 1 else {
            close()
            return
        }
        carousel.removeCurrent()
        resizeForCurrentPage(centeredOffset: 0)
    }

    func popOutCurrentPage() {
        let item = carousel.current
        if carousel.pages.count > 1 {
            carousel.removeCurrent()
            resizeForCurrentPage(centeredOffset: 0)
        } else {
            close()
        }
        ClipboardManager.shared.openStandaloneQuickClipPanel(for: item)
    }

    private func resizeForCurrentPage(centeredOffset offset: CGFloat) {
        guard !carousel.isCollapsed else { return }
        let item = carousel.current
        let screen = NSScreen.main?.visibleFrame ?? .zero

        var w: CGFloat = 420
        var h: CGFloat = 460
        let chromeHeight: CGFloat = 160
        if case .image(let img, _, _) = item.content,
           img.size.width > 0, img.size.height > 0 {
            let maxPreviewW = min(720, screen.width * 0.55)
            let maxPreviewH = min(620, screen.height * 0.65)
            let scale = min(1, min(maxPreviewW / img.size.width,
                                   maxPreviewH / img.size.height))
            let fittedW = img.size.width * scale
            let fittedH = img.size.height * scale
            w = max(320, fittedW + 24)
            h = max(300, fittedH + 24 + chromeHeight)
        }

        let hasFrame = frame.width > 0 && frame.height > 0
        let centerX = hasFrame ? frame.midX : screen.midX + offset
        let centerY = hasFrame ? frame.midY : screen.midY - offset
        let x = centerX - w / 2
        let y = centerY - h / 2

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true, animate: hasFrame)
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
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            self.animator().setFrame(target, display: true)
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

    func restoreIfCollapsed() {
        guard carousel.isCollapsed else { return }
        carousel.isCollapsed = false
        contentMinSize = Self.expandedMinSize
        carousel.lastActiveAppBundleID = nil
        if let restore = expandedFrame {
            animatedSetFrame(restore)
        } else {
            resizeForCurrentPage(centeredOffset: 0)
        }
        expandedFrame = nil
    }

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

    override var canBecomeKey: Bool { true }

    override func close() {
        ClipboardManager.shared.itemPreviewPanel.hide()
        super.close()
        DispatchQueue.main.async {
            ClipboardManager.shared.quickClipPanelDidClose(self)
        }
    }
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
                    item: pageItem,
                    shouldFocus: carousel.pendingFocusPageID == pageItem.id,
                    onConsumeFocusRequest: { carousel.consumeFocusRequest(for: pageItem.id) },
                    pageCount: carousel.pages.count,
                    pageIndex: carousel.pages.firstIndex(where: { $0.id == pageItem.id }) ?? carousel.index,
                    onClosePanel: onClosePanel,
                    onMinimize: onMinimize,
                    onClosePage: onClosePage,
                    onPopOut: onPopOut,
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
        .onChange(of: item.id) { _, _ in
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
    @ObservedObject private var manager = ClipboardManager.shared

    private var isOn: Bool { manager.referenceAppAffinityEnabled }

    var body: some View {
        Button {
            manager.referenceAppAffinityEnabled.toggle()
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
    let item: ClipboardItem
    let shouldFocus: Bool
    let onConsumeFocusRequest: () -> Void
    let pageCount: Int
    let pageIndex: Int
    let onClosePanel: () -> Void
    let onMinimize: () -> Void
    let onClosePage: () -> Void
    let onPopOut: () -> Void
    let showSimilar: Bool
    let similarCount: Int
    let onToggleSimilar: () -> Void
    let tags: [ReferenceTag]
    let onRemoveTag: (UUID) -> Void

    @State private var noteText: String
    @State private var lastCommittedNote: String
    @State private var noteCommitTask: Task<Void, Never>? = nil
    @FocusState private var noteFocused: Bool
    @State private var editedText: String
    @State private var savedText: String
    @FocusState private var contentFocused: Bool
    @State private var editedRows: [[String]]
    @State private var savedRows: [[String]]
    @State private var urlPreviewReloadToken = 0

    private func commitNote(_ value: String) {
        guard value != lastCommittedNote else { return }
        lastCommittedNote = value
        ClipboardManager.shared.updateUserNote(id: item.id, note: value)
    }

    private var isRichContent: Bool {
        switch item.content {
        case .html, .richText, .rtfd: return true
        default: return false
        }
    }

    private var isEditableTable: Bool {

        guard let cells = TableCellExtractor.cells(for: item) else { return false }
        return TableCellExtractor.isDataTable(cells)
    }

    private var isEditableText: Bool {
        guard !isEditableTable, !isRichContent else { return false }
        return ClipboardManager.editablePlainText(for: item) != nil
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

                Button {
                    if isEditableTable {
                        let flattened = editedRows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
                        ClipboardManager.shared.pasteTransformed(flattened, restoring: item)
                    } else if isEditableText {
                        ClipboardManager.shared.pasteTransformed(editedText, restoring: item)
                    } else if let idx = ClipboardManager.shared.indexOfItem(id: item.id) {
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

            Divider()

            Group {
                if isEditableTable {
                    EditableTableGrid(rows: $editedRows)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else if isEditableText {
                    if case .text = item.content, let previewURL = ContentPreviewView.validWebURL(editedText) {
                        VStack(spacing: 0) {
                            TextEditor(text: $editedText)
                                .font(.system(size: 12, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .focused($contentFocused)
                                .frame(height: 54)
                                .padding(8)
                            Divider()
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Text("Website preview")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    urlPreviewReloadToken += 1
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.plain)
                                .help("Reload preview for this URL")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            Divider()
                            WebsitePreview(url: previewURL, reloadToken: urlPreviewReloadToken)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        TextEditor(text: $editedText)
                            .font(.system(size: 12))
                            .scrollContentBackground(.hidden)
                            .focused($contentFocused)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(8)
                    }
                } else {
                    QuickClipPreview(item: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                        .onDrag {
                            item.makeItemProvider()
                        }
                }
            }
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
                            noteCommitTask?.cancel()
                            commitNote(noteText)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, tags.isEmpty ? 10 : 6)

            if !tags.isEmpty {
                Divider()
                ReferenceTagRow(tags: tags, onRemove: onRemoveTag)
            }
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

    var body: some View {
        ContentPreviewView(item: item, chrome: .reference)
    }
}

private struct SimilarItemsSidePanelView: View {
    let pinned:      ClipboardItem
    let onPreview:   (ClipboardItem) -> Void
    let onEndPreview: () -> Void
    @Binding var similars: [ClipboardItem]

    @ObservedObject private var manager = ClipboardManager.shared

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
                if let idx = ClipboardManager.shared.indexOfItem(id: similar.id) {
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
