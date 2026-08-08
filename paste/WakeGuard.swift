import AppKit

enum WakeGuard {
    private static let settleWindow: TimeInterval = 2.0
    private static var wokeAt: Date?

    static func install() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in wokeAt = Date() }
    }

    static func afterWakeSettle(_ action: @escaping () -> Void) {
        guard let wokeAt, Date().timeIntervalSince(wokeAt) < settleWindow else {
            action()
            return
        }
        let remaining = settleWindow - Date().timeIntervalSince(wokeAt)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, remaining), execute: action)
    }
}
