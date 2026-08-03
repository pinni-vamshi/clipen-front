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

final class ItemPreviewPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var shownStrip: NSRect? = nil
    private var wantsVisible = false

    /// Fires whenever `wantsVisible` actually changes — the one place that
    /// happens is inside `present(...)`/`hide()` below, so this is a single
    /// choke point rather than something every one of this panel's 20+
    /// external call sites would need to remember to report separately.
    /// Lets ClipboardManager mirror this into a real `@Published` property
    /// (`isItemPreviewVisible`) for SwiftUI to react to — this class itself
    /// isn't an ObservableObject, so nothing here is reactive on its own.
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
        present(AnyView(ItemPreviewView(item: item)), width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    /// Opens the inline editor at the item's position, side-by-side with the
    /// popup — replaces the old QuickClip-panel edit flow entirely.
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

    /// Table content (a real table structure — richText/RTFD/HTML — not a
    /// plain-text blob) gets edited cell-by-cell instead of being flattened
    /// through the flat text editor above, which would destroy the table
    /// structure by replacing the whole rich container with a plain string.
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
        present(AnyView(MultiItemPreviewView(items: items, currentItemID: currentItemID)), width: 520, height: 520,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    private func present(_ view: AnyView, width w: CGFloat, height h: CGFloat,
                         near popupFrame: NSRect, anchorPoint: NSPoint?) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let preferredRightX = popupFrame.maxX + 10
        let rightFits = preferredRightX + w <= screen.maxX
        let leftFits = popupFrame.minX - w - 10 >= screen.minX + 10
        let placeRight = rightFits || !leftFits

        popover.contentSize = NSSize(width: w, height: h)
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = view
        } else {
            popover.contentViewController = NSHostingController(rootView: view)
        }

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
        WakeGuard.afterWakeSettle { [popover, anchorView] in
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
            // Snap-close to avoid the animated fade visually overlapping
            // whatever panel replaces it (transform, share).
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
        anchorPanel.orderOut(nil)
        shownStrip = nil
    }
}

struct MultiItemPreviewView: View {
    let items: [ClipboardItem]
    var currentItemID: UUID? = nil

    private var markedCount: Int {
        currentItemID == nil ? items.count : items.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(markedCount) marked")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Space to close")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { Divider() }
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .frame(width: 18)
                            ItemPreviewView(item: item, compact: true)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

private struct ItemPreviewView: View {
    let item: ClipboardItem
    var compact: Bool = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ItemTagStrip(tags: item.tags, maxVisible: 5, compact: true)
                    if let metadata = item.metadataSummary {
                        Text(metadata)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                content
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        } else {
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
    }

    private var content: some View {
        ContentPreviewView(item: item, chrome: .panel)
    }
}
