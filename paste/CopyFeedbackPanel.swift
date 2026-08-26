import AppKit
import SwiftUI

/// Tiny, non-activating badge shown right at the cursor for ~1.5s when a
/// copy produced nothing Clipen could meaningfully capture — an app-private,
/// undecodable pasteboard write (see basicItem(from:) in
/// ClipboardManager+Capture.swift). Exists so that case never has to show up
/// as a "Private" row in history at all: the user gets told in the moment
/// instead, at the point of the failed copy, without Clipen's own window
/// needing to be open.
final class CopyFeedbackPanel: NSPanel {
    static let shared = CopyFeedbackPanel()

    private var dismissWorkItem: DispatchWorkItem?
    private var followTimer: Timer?
    private var trackedOrigin: NSPoint?

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

    /// Reflects the fallback toggle at the moment each failure fires, not a
    /// fixed string: when the toggle is on, this failure is about to become
    /// a pasteable, flagged ring entry a moment later (see
    /// addUncapturedPlaceholder in ClipboardManager+Capture.swift), so
    /// telling the user it simply "can't" copy would be wrong. When it's
    /// off, that placeholder never gets created, so the plain failure
    /// message is the accurate one.
    static func defaultMessage() -> String {
        ClipboardManager.shared.uncapturedFallbackEnabled
            ? String(localized: "Can't copy — pastes with system default")
            : String(localized: "Can't copy this")
    }

    func show(message: String = CopyFeedbackPanel.defaultMessage()) {
        dismissWorkItem?.cancel()
        followTimer?.invalidate()

        let hosting = NSHostingView(rootView: CopyFeedbackView(message: message))
        // fittingSize is unreliable read immediately after assigning
        // contentView — SwiftUI hasn't had a layout pass yet the first time
        // this runs, so the very first badge could come back sized near
        // zero and get clipped by setContentSize below. sizingOptions keeps
        // AppKit's own tracked size in sync going forward; layoutSubtreeIfNeeded
        // forces that first pass to happen before we read it back.
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

        // A real tooltip trails the cursor instead of sitting frozen where
        // it first appeared — exponential smoothing toward the live mouse
        // location each tick reads as a soft, lagging follow rather than a
        // rigid teleport snapped to the raw position every frame.
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
        let smoothing: CGFloat = 0.25
        let next = NSPoint(x: current.x + (target.x - current.x) * smoothing,
                            y: current.y + (target.y - current.y) * smoothing)
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
