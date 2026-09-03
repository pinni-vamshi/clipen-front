import AppKit
import SwiftUI

final class CopyFeedbackPanel: NSPanel {
    static let shared = CopyFeedbackPanel()

    private var dismissWorkItem: DispatchWorkItem?
    private var followTimer: Timer?
    private var trackedOrigin: NSPoint?
    private var idleTickCount = 0

    private init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    static func defaultMessage() -> String {
        ClipboardManager.shared.uncapturedFallbackEnabled
            ? String(localized: "Can't copy — pastes with system default")
            : String(localized: "Can't copy this")
    }

    func show(message: String = CopyFeedbackPanel.defaultMessage()) {
        dismissWorkItem?.cancel()
        followTimer?.invalidate()

        let hosting = NSHostingView(rootView: CopyFeedbackView(message: message))

        hosting.sizingOptions = [.standardBounds, .intrinsicContentSize]
        contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let measured = hosting.fittingSize
        let size = NSSize(width: max(measured.width, 120), height: max(measured.height, 30))
        setContentSize(size)

        let origin = Self.clampedOrigin(anchoredTo: NSEvent.mouseLocation, size: size)
        trackedOrigin = origin
        setFrameOrigin(origin)

        orderFrontRegardless()

        idleTickCount = 0
        followTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.followCursor()
        }
        RunLoop.main.add(followTimer!, forMode: .common)

        let workItem = DispatchWorkItem { [weak self] in
            self?.followTimer?.invalidate()
            self?.followTimer = nil
            self?.orderOut(nil)
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func followCursor() {
        guard let current = trackedOrigin else { return }
        let target = Self.clampedOrigin(anchoredTo: NSEvent.mouseLocation, size: frame.size)
        let dx = target.x - current.x, dy = target.y - current.y

        guard abs(dx) > 0.1 || abs(dy) > 0.1 else {
            // The cursor has settled — stop ticking at 60Hz for the rest of
            // the toast's 1.5s lifetime. A few consecutive idle ticks
            // (rather than the very first) avoids stopping on a momentary
            // pause mid-movement; show() restarts this timer fresh on the
            // next toast regardless.
            idleTickCount += 1
            if idleTickCount >= 6 {
                followTimer?.invalidate()
                followTimer = nil
            }
            return
        }
        idleTickCount = 0
        let smoothing: CGFloat = 0.25
        let next = NSPoint(x: current.x + dx * smoothing, y: current.y + dy * smoothing)
        trackedOrigin = next
        setFrameOrigin(next)
    }

    private static func clampedOrigin(anchoredTo cursor: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = NSPoint(x: cursor.x + 14, y: cursor.y - size.height - 10)
        origin.x = min(origin.x, screen.maxX - size.width - 8)
        origin.y = max(origin.y, screen.minY + 8)
        return origin
    }
}

private struct CopyFeedbackView: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "nosign")
                .font(.system(size: 11, weight: .semibold))
            Text(message)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: "#4F8EF7"), in: Capsule())
    }
}
