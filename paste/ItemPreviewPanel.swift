import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit

/// How tall the single-item preview should be for a given item.
///
/// Deliberately computed from the CONTENT, not measured from the rendered
/// SwiftUI. Self-sizing (`NSHostingController.sizingOptions`) cannot work
/// here: `ItemPreviewView` puts `.frame(maxWidth: .infinity, maxHeight:
/// .infinity)` on its content twice, `ContentPreviewView` adds four more
/// `maxHeight: .infinity` and three ScrollViews, so SwiftUI's ideal height is
/// either unbounded (the greedy frames) or near-zero (the ScrollViews). That
/// is the feedback loop that broke this the last time it was attempted.
///
/// Width stays fixed. Only the height moves, which keeps text wrapping stable
/// and avoids solving in two dimensions at once.
enum PreviewSizing {
    static let width: CGFloat = 520
    /// The current fixed size is the ceiling — nothing gets bigger than the
    /// panel does today.
    static let maxHeight: CGFloat = 420
    /// Below this the header alone dominates and the panel reads as broken.
    static let minHeight: CGFloat = 190

    /// Header (tags + metadata + the two hint lines) + divider + content
    /// padding, from ItemPreviewView's own layout.
    private static let chromeHeight: CGFloat = 73
    private static let contentWidth: CGFloat = width - 28   // 14pt padding each side

    /// Measuring the whole of a huge string is wasted work — anything past
    /// this is already taller than `maxHeight` several times over.
    private static let measuredTextLimit = 6_000

    static func height(for item: ClipboardItem) -> CGFloat {
        clamp(chromeHeight + naturalContentHeight(for: item))
    }

    private static func clamp(_ h: CGFloat) -> CGFloat {
        min(maxHeight, max(minHeight, h.rounded()))
    }

    private static func naturalContentHeight(for item: ClipboardItem) -> CGFloat {
        switch item.content {
        case .text(let text):
            // A web URL renders as a live WebsitePreview, which wants the
            // full height and cannot be measured from the string.
            if ContentPreviewView.validWebURL(text) != nil { return maxHeight }
            return textHeight(text, size: 13, monospaced: false)

        case .svg(let src):
            return textHeight(src, size: 13, monospaced: true)

        case .richText(_, let plain), .rtfd(_, let plain):
            return textHeight(plain, size: 13, monospaced: false)

        case .image(let image, _, _):
            // Aspect ratio decides it: a wide banner needs far less height
            // than a tall screenshot, and both used to get the same 420.
            let size = image.size
            guard size.width > 0, size.height > 0 else { return maxHeight }
            return contentWidth * (size.height / size.width)

        case .files(let urls):
            // Stacked cells, one per file (see ContentPreviewView.filesPreview).
            return CGFloat(urls.count) * 220 + CGFloat(max(0, urls.count - 1)) * 10

        // Everything below renders through a web view, QuickLook, or another
        // panel — all of which genuinely want the room and none of which can
        // be measured cheaply. They keep exactly today's size.
        case .html, .file, .blob, .group:
            return maxHeight
        }
    }

    private static func textHeight(_ text: String, size: CGFloat, monospaced: Bool) -> CGFloat {
        guard !text.isEmpty else { return minHeight - chromeHeight }
        let measured = String(text.prefix(measuredTextLimit))
        let font: NSFont = monospaced
            ? .monospacedSystemFont(ofSize: size, weight: .regular)
            : .systemFont(ofSize: size)
        let bounds = (measured as NSString).boundingRect(
            with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        // A little slack so the last line never sits flush against the edge.
        return ceil(bounds.height) + 12
    }
}

final class ItemPreviewPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var shownStrip: NSRect? = nil
    private var wantsVisible = false

    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { wantsVisible && popover.isShown }
    var frame: NSRect {
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
            return
        }
        let mainPopupVisible = ClipboardManager.shared.previewWindow.isVisible
        let quickClipVisible = ClipboardManager.shared.hasVisibleQuickClipPanel
        if !mainPopupVisible && !quickClipVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
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

    func show(for item: ClipboardItem, near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        // Keyed on more than just id: `content` itself is immutable once
        // captured, but OCR/AI structuring/notes can complete or change
        // while this exact item's preview is already open — the key needs
        // to change then too, or the reposition-only fast path below would
        // keep showing stale content indefinitely.
        let key = AnyHashable([
            item.id.uuidString, item.ocrText ?? "", item.aiStructuredText ?? "",
            item.userNote ?? "", item.diffBadge ?? "",
        ])
        present(AnyView(ItemPreviewView(item: item)),
                width: PreviewSizing.width,
                height: PreviewSizing.height(for: item),
                near: popupFrame, anchorPoint: anchorPoint, contentKey: key)
    }

    func showEditor(for item: ClipboardItem,
                    initialText: String,
                    near popupFrame: NSRect,
                    anchorPoint: NSPoint? = nil,
                    onCommit: @escaping (String) -> Void,
                    onCommitAndPaste: @escaping (String) -> Void,
                    onCancel: @escaping () -> Void) {
        present(AnyView(InlineEditView(item: item,
                                       initialText: initialText,
                                       onCommit: onCommit,
                                       onCommitAndPaste: onCommitAndPaste,
                                       onCancel: onCancel)),
                width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func showTableEditor(initialRows: [[String]],
                         near popupFrame: NSRect,
                         anchorPoint: NSPoint? = nil,
                         onCommit: @escaping ([[String]]) -> Void,
                         onCommitAndPaste: @escaping ([[String]]) -> Void,
                         onCancel: @escaping () -> Void) {
        present(AnyView(InlineTableEditView(initialRows: initialRows,
                                            onCommit: onCommit,
                                            onCommitAndPaste: onCommitAndPaste,
                                            onCancel: onCancel)),
                width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func showMixedEditor(initialSegments: [ContentSegment],
                         near popupFrame: NSRect,
                         anchorPoint: NSPoint? = nil,
                         onCommit: @escaping ([ContentSegment]) -> Void,
                         onCommitAndPaste: @escaping ([ContentSegment]) -> Void,
                         onCancel: @escaping () -> Void) {
        present(AnyView(InlineMixedEditView(initialSegments: initialSegments,
                                            onCommit: onCommit,
                                            onCommitAndPaste: onCommitAndPaste,
                                            onCancel: onCancel)),
                width: 520, height: 480,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func showRichEditor(initialAttributedString: NSAttributedString,
                        near popupFrame: NSRect,
                        anchorPoint: NSPoint? = nil,
                        onCommit: @escaping (NSAttributedString) -> Void,
                        onCommitAndPaste: @escaping (NSAttributedString) -> Void,
                        onCancel: @escaping () -> Void) {
        present(AnyView(InlineRichEditView(initialAttributedString: initialAttributedString,
                                           onCommit: onCommit,
                                           onCommitAndPaste: onCommitAndPaste,
                                           onCancel: onCancel)),
                width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func show(forItems items: [ClipboardItem], currentItemID: UUID? = nil,
              near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        guard !items.isEmpty else { hide(); return }
        let key = AnyHashable([currentItemID?.uuidString ?? ""] + items.map(\.id.uuidString))
        present(AnyView(MultiItemPreviewView(items: items, currentItemID: currentItemID)), width: 520, height: 520,
                near: popupFrame, anchorPoint: anchorPoint, contentKey: key)
    }

    // Set only by the two call sites above (single-item / marked-stack
    // preview) — the editor variants below intentionally pass no key, so
    // they always rebuild.
    private var lastShownContentKey: AnyHashable?

    private func present(_ view: AnyView, width w: CGFloat, height h: CGFloat,
                         near popupFrame: NSRect, anchorPoint: NSPoint?,
                         contentKey: AnyHashable? = nil) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let preferredRightX = popupFrame.maxX + 10
        let rightFits = preferredRightX + w <= screen.maxX
        let leftFits = popupFrame.minX - w - 10 >= screen.minX + 10
        let placeRight = rightFits || !leftFits

        popover.contentSize = NSSize(width: w, height: h)
        // Skip rebuilding the SwiftUI content entirely when we already have
        // this exact content on screen and this is purely a reposition —
        // repositionAnchoredSidePanelForMeasuredRow() re-calls show(for:)
        // on every >3pt change in the selected row's measured frame, which
        // fires many times over the course of a single spring-scroll
        // animation (cycling through the ring, or a fresh capture shifting
        // rows). Reassigning `rootView` to a freshly-constructed view value
        // on every one of those ticks re-evaluates the preview's whole body
        // — real work for a table (TableCellExtractor), code (Highlightr
        // syntax highlighting), or image content — even though the actual
        // item being previewed hasn't changed, only its on-screen position.
        // That repeated rebuild during the scroll is what read as jerky
        // navigation specifically while a preview was showing.
        let contentUnchanged = contentKey != nil && popover.isShown && contentKey == lastShownContentKey
        if !contentUnchanged {
            if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
                hostingController.rootView = view
            } else {
                popover.contentViewController = NSHostingController(rootView: view)
            }
        }
        lastShownContentKey = contentKey

        let anchorY = anchorPoint?.y ?? popupFrame.midY
        let stripHeight = max(1, popupFrame.height)
        let desiredStrip = NSRect(x: placeRight ? popupFrame.maxX : popupFrame.minX,
                                  y: popupFrame.minY, width: 1, height: stripHeight)
        let localY = max(0, min(stripHeight - 1, anchorY - desiredStrip.minY))
        let rowRect = NSRect(x: 0, y: localY, width: 1, height: 1)

        let wasVisible = wantsVisible
        wantsVisible = true
        if !wasVisible { onVisibilityChange?(true) }
        if popover.isShown, shownStrip == desiredStrip {
            popover.positioningRect = rowRect
            return
        }

        if popover.isShown { popover.performClose(nil) }
        anchorPanel.setFrame(desiredStrip, display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        shownStrip = desiredStrip
        let edge: NSRectEdge = placeRight ? .maxX : .minX
        WakeGuard.afterWakeSettle { [popover, anchorView, weak self] in

            guard let self, self.wantsVisible else { return }
            popover.animates = false
            popover.show(relativeTo: rowRect, of: anchorView, preferredEdge: edge)
            popover.animates = true
            popover.clipenAnimateIn()
        }
    }

    func hide() {
        let wasVisible = wantsVisible
        wantsVisible = false
        if wasVisible { onVisibilityChange?(false) }
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(EmptyView())
        }
        if popover.isShown {

            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
        anchorPanel.orderOut(nil)
        shownStrip = nil
        lastShownContentKey = nil
    }
}

struct MultiItemPreviewView: View {
    let items: [ClipboardItem]
    var currentItemID: UUID? = nil

    var showsHeader: Bool = true

    private var markedCount: Int {
        currentItemID == nil ? items.count : items.count - 1
    }

    private var isGroupPreview: Bool { currentItemID == nil }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: isGroupPreview ? "square.stack.3d.up.fill" : "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(isGroupPreview ? "Group" : "Marked") · \(markedCount)")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.indigo)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.14), in: Capsule())
                    .overlay(Capsule().stroke(Color.indigo.opacity(0.35), lineWidth: 0.5))

                    Spacer()
                    Text("Space to close")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()
            }

            // Just the raw preview of each item, stacked one below another,
            // scrolling — same treatment for every content type (image,
            // text, mixed, whatever). No numbering, no tag strip, no
            // metadata line, no grid: those all used to sit as an extra bar
            // of chrome on every item.
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items, id: \.id) { item in
                        HStack(spacing: 6) {
                            // A plain, non-scrollable label — never a
                            // ContentPreviewView, which for text/table/PDF/
                            // HTML content hosts its own inner ScrollView.
                            // Scrolling the stack by dragging over an item's
                            // actual preview handed the gesture to that
                            // inner scroll view instead of the outer list,
                            // making it impossible to scroll past an item
                            // with its own scrollable content. This strip
                            // has nothing scrollable under it, so a drag
                            // here always reaches the outer ScrollView —
                            // and it doubles as the filename, oriented
                            // vertically the same way the popup's image-run
                            // rows already label a batch of images.
                            Text(Self.displayLabel(for: item))
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundColor(.secondary)
                                .frame(width: 190, alignment: .center)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 20)

                            ContentPreviewView(item: item, chrome: .panel)
                                .frame(maxWidth: .infinity)
                        }
                        .frame(height: 220)
                    }
                }
                .padding(12)
            }
        }
    }

    private static func displayLabel(for item: ClipboardItem) -> String {
        switch item.content {
        case .file(let url):
            return url.lastPathComponent
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        default:
            let preview = item.previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            return preview.isEmpty ? item.primaryTag.label : preview
        }
    }
}

private struct ItemPreviewView: View {
    let item: ClipboardItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ItemTagStrip(tags: item.tags, maxVisible: 5, compact: false)
                    if let metadata = item.metadataSummary {
                        Text(metadata)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("Space to close")
                    Text("Double-tap Space to refer")
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        }
    }

    private var content: some View {

        ContentPreviewView(item: item, chrome: .panel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
