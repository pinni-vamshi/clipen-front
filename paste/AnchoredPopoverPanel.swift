import AppKit
import SwiftUI

class AnchoredPopoverPanel: NSObject, NSPopoverDelegate {
    let anchorPanel: NSPanel
    let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let popover = NSPopover()

    private var wantsVisible = false
    private var shownStrip: NSRect? = nil

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

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
    }

    func present<Content: View>(_ content: Content,
                                size: NSSize,
                                near popupFrame: NSRect,
                                anchorPoint: NSPoint?) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let rightFits = popupFrame.maxX + 8 + size.width <= screen.maxX
        let leftFits  = popupFrame.minX - size.width - 8 >= screen.minX + 8
        let placeRight = rightFits || !leftFits

        popover.contentSize = size
        if let hosting = popover.contentViewController as? NSHostingController<Content> {
            hosting.rootView = content
        } else {
            popover.contentViewController = NSHostingController(rootView: content)
        }

        let anchorY = anchorPoint?.y ?? popupFrame.midY
        let stripHeight = max(1, popupFrame.height)
        let desiredStrip = NSRect(x: placeRight ? popupFrame.maxX : popupFrame.minX,
                                  y: popupFrame.minY, width: 1, height: stripHeight)
        let localY = max(0, min(stripHeight - 1, anchorY - desiredStrip.minY))
        let rowRect = NSRect(x: 0, y: localY, width: 1, height: 1)

        wantsVisible = true
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
        wantsVisible = false
        if popover.isShown {
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
        anchorPanel.orderOut(nil)
        shownStrip = nil
    }
}
