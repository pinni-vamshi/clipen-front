import AppKit

/// Guards every NSPopover.show(...) call site against a real crash class:
/// showing a popover routes through AppKit's own window-ordering machinery,
/// which can throw an uncaught NSException deep inside ViewBridge's
/// NSRemoteView — but only during CoreAnimation's transaction commit,
/// asynchronously, outside any Swift call stack we control. That means no
/// try/catch reaches it, and AppKit's display-cycle protection catches the
/// exception itself and calls +[NSApplication _crashOnException:] directly,
/// so a custom NSSetUncaughtExceptionHandler never sees it either — there is
/// no app-level recovery or logging hook for this specific failure.
///
/// The one concrete correlating fact from an actual crash report was ~133
/// seconds since the Mac woke from sleep — the window server's remote-view
/// proxies (what ViewBridge/NSRemoteView broker) can still be reconnecting
/// then. Since we can't catch the exception, the only lever is not calling
/// into that AppKit path during the fragile window.
enum WakeGuard {
    private static let settleWindow: TimeInterval = 2.0
    private static var wokeAt: Date?

    /// Call once, at app launch.
    static func install() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in wokeAt = Date() }
    }

    /// Runs `action` immediately unless the Mac woke from sleep within the
    /// last `settleWindow` seconds, in which case `action` waits out the
    /// remainder of that window first. Outside that rare window this is a
    /// same-tick call, identical to calling `action()` directly.
    static func afterWakeSettle(_ action: @escaping () -> Void) {
        guard let wokeAt, Date().timeIntervalSince(wokeAt) < settleWindow else {
            action()
            return
        }
        let remaining = settleWindow - Date().timeIntervalSince(wokeAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining), execute: action)
    }
}
