import AppKit
import SwiftUI

/// Whether popovers being hidden right now should fade out rather than snap.
///
/// Opening has always animated; closing never did, so everything vanished
/// abruptly. But a close is not always a dismissal: a PASTE has to take the
/// popup away before the simulated Cmd-V, so focus is already back in the
/// target app. This flag is the one switch between the two, and it is set
/// only by `dismissPreview()` — Escape, a click outside, the auto-dismiss
/// timer — for the length of that synchronous call. Every paste path calls
/// `hide()` directly and never sets it, so it stays instant.
enum PopoverClose {
    static var animated = false
    static let fadeDuration: TimeInterval = 0.12
}

class AnchoredPopoverPanel: NSObject, NSPopoverDelegate {
    let anchorPanel: NSPanel
    let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    let popover = NSPopover()

    private var wantsVisible = false
    private var shownStrip: NSRect? = nil
    /// The pending close after a fade-out, kept so a re-present can cancel it.
    private var fadeOutWork: DispatchWorkItem?

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
        // Needed again before a fade-out finished: stop the close and bring
        // the window back before anything below reuses or re-shows it.
        cancelFadeOut()

        // The screen the popup is on — `NSScreen.main` is the focused app's
        // screen, so with the popup on another display the side was chosen
        // against the wrong edges and the panel could open off screen.
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(popupFrame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
        let rightFits = popupFrame.maxX + 8 + size.width <= screen.maxX
        let leftFits  = popupFrame.minX - size.width - 8 >= screen.minX + 8
        let placeRight = rightFits || !leftFits

        popover.contentSize = size
        // Side panels hide rather than close, so their looping animations
        // need to know when they're off screen (see TracksWindowVisibility).
        let tracked = content.modifier(TracksWindowVisibility())
        if let hosting = popover.contentViewController as? NSHostingController<ModifiedContent<Content, TracksWindowVisibility>> {
            hosting.rootView = tracked
        } else {
            popover.contentViewController = NSHostingController(rootView: tracked)
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

        // Instant, then show: closing with the system animation and showing
        // again in the same turn can leave the new show swallowed by the
        // close that is still finishing.
        if popover.isShown {
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
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
        shownStrip = nil
        fadeOutWork?.cancel()
        fadeOutWork = nil
        // `isVisible` is already false above, so the rest of the app treats
        // this as gone immediately; the fade is only what the eye sees.
        if PopoverClose.animated, popover.isShown {
            fadeOutWork = popover.clipenAnimateOut { [weak self] in self?.finishHide() }
            return
        }
        finishHide()
    }

    private func cancelFadeOut() {
        guard fadeOutWork != nil else { return }
        fadeOutWork?.cancel()
        fadeOutWork = nil
        popover.clipenCancelAnimateOut()
    }

    private func finishHide() {
        fadeOutWork = nil
        // Presented again during the fade: nothing left to close.
        guard !wantsVisible else { return }
        popover.clipenCancelAnimateOut()
        if popover.isShown {
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
        anchorPanel.orderOut(nil)
    }
}
