import SwiftUI
import AppKit
import Sparkle

@main
struct pasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Clipen", id: "main") {
            MainWindowView()
                .background(WindowOpenBridge())
        }
        .defaultSize(width: 820, height: 680)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Quit Clipen") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        Settings { EmptyView() }
    }
}

/// Invisible helper hosted inside the main window. It captures SwiftUI's
/// `openWindow` action so `AppDelegate.openMainWindow` can re-create the
/// window scene after it has been closed.
private struct WindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .onAppear { AppDelegate.requestOpenMainWindow = { openWindow(id: "main") } }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// Cross-process signal so a second launch (user clicking the app while
    /// it's already running in the menu bar) tells the live instance to
    /// reopen its main window instead of just silently activating.
    static let reopenNotification = Notification.Name("com.clipen.app.reopenMainWindow")

    /// Set by a hidden SwiftUI bridge view once the main window scene exists,
    /// so `openMainWindow` can re-create the SwiftUI `Window` after it's been
    /// closed/torn down (AppKit `makeKeyAndOrderFront` only works while the
    /// NSWindow is still alive).
    static var requestOpenMainWindow: (() -> Void)?

    private var updaterController: SPUStandardUpdaterController?

    private var pendingUpdateInstall: (() -> Void)?
    private var pendingUpdateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipen.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            // Ask the already-running instance to reopen its main window, then
            // hand over and quit. Just activating it (old behaviour) left the
            // window closed, so clicking the app did nothing visible.
            DistributedNotificationCenter.default().postNotificationName(
                Self.reopenNotification, object: nil, userInfo: nil, deliverImmediately: true)
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Self.reopenNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.openMainWindow()
        }

        AuthManager.shared.registerActionUsage(actionID: "session.open")

        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        NSApp.setActivationPolicy(.accessory)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                let hasVisibleMainWindow = NSApp.windows.contains {
                    !($0 is NSPanel) && $0.isVisible && $0.identifier?.rawValue == "main"
                }
                if !hasVisibleMainWindow {
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }

        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
            updaterController?.updater.automaticallyDownloadsUpdates = true
        }

        ClipboardManager.shared.startMonitoring()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdatesInBackgroundIfAllowed()
        }

        _ = AuthManager.isFirstSessionEver

        let firstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
        if firstLaunch { UserDefaults.standard.set(true, forKey: "hasLaunchedBefore") }

        // Open the main window when the USER launches the app. A user launch
        // (first-ever, or a double-click after quitting) makes the app become
        // active within a moment; a background launch-at-login start never
        // does, so it stays quiet in the menu bar. Poll briefly rather than
        // checking a single instant, so activation timing can't be missed.
        if firstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openMainWindow()
            }
        } else {
            openMainWindowIfUserLaunched(attemptsLeft: 12)
        }
    }

    private func openMainWindowIfUserLaunched(attemptsLeft: Int) {
        if NSApp.isActive {
            openMainWindow()
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.openMainWindowIfUserLaunched(attemptsLeft: attemptsLeft - 1)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        AuthManager.shared.flushPendingDailyUsage()
        pendingUpdateInstall?()
        pendingUpdateInstall = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updaterController?.updater.automaticallyDownloadsUpdates ?? false }
        set { updaterController?.updater.automaticallyDownloadsUpdates = newValue }
    }

    var betaUpdatesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "SUBetaUpdatesEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "SUBetaUpdatesEnabled") }
    }

    func checkForUpdatesInBackgroundIfAllowed() {
        guard automaticallyChecksForUpdates,
              let updater = updaterController?.updater,
              updater.canCheckForUpdates,
              !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        // Always go through Sparkle — it checks the appcast and downloads/installs
        // in place. Never fall back to opening a browser DMG download.
        updaterController?.checkForUpdates(nil)
    }

    func openMainWindow(retriesLeft: Int = 8) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            existing.minSize = NSSize(width: 900, height: 620)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // No live NSWindow — the SwiftUI Window scene was closed/torn down.
        // Ask SwiftUI to re-create it, then retry to bring it forward.
        AppDelegate.requestOpenMainWindow?()
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.openMainWindow(retriesLeft: retriesLeft - 1)
        }
    }
}

extension AppDelegate: SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { false }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard handleShowingUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: SPUUpdaterDelegate {

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        betaUpdatesEnabled ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func updater(_ updater: SPUUpdater,
                 willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        pendingUpdateInstall = immediateInstallationBlock
        installPendingUpdateWhenIdle()
        return true
    }

    private func installPendingUpdateWhenIdle() {
        guard pendingUpdateInstall != nil else { return }
        if tryInstallPendingUpdate() { return }
        guard pendingUpdateTimer == nil else { return }
        pendingUpdateTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            _ = self?.tryInstallPendingUpdate()
        }
    }

    @discardableResult
    private func tryInstallPendingUpdate() -> Bool {
        guard let block = pendingUpdateInstall else {
            pendingUpdateTimer?.invalidate(); pendingUpdateTimer = nil
            return true
        }
        let mainWindowVisible = NSApp.windows.contains {
            !($0 is NSPanel) && $0.isVisible && $0.identifier?.rawValue == "main"
        }
        let popupVisible = ClipboardManager.shared.previewWindow.isVisible
        guard !mainWindowVisible, !popupVisible else { return false }

        pendingUpdateTimer?.invalidate(); pendingUpdateTimer = nil
        pendingUpdateInstall = nil
        block()
        return true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        AuthManager.shared.registerActionUsage(actionID: "fail.sparkle_check")
    }
}
