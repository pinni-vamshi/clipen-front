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
        Self.refreshLaunchServicesIfNewBuild()
        Self.sweepStaleTempDirectories()

        // Second-instance guard. After a Sparkle-installed update, the old
        // process's kernel record can linger in the running-apps list for up
        // to a second after the process itself has exited — during which the
        // new binary would see a "sibling", self-terminate, and give the user
        // a phantom crash. Wait until the sibling either proves it's alive
        // (a re-check where it's still not terminated) or drops from the list.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipen.app"
        func liveSibling() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                         && $0.isTerminated == false }
        }
        if let candidate = liveSibling() {
            // Give the OS ~500 ms to release a process record left over from
            // an in-flight update install; only self-terminate if the sibling
            // is still live after that grace period.
            Thread.sleep(forTimeInterval: 0.5)
            if let stillAlive = liveSibling(), stillAlive.processIdentifier == candidate.processIdentifier {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.reopenNotification, object: nil, userInfo: nil, deliverImmediately: true)
                stillAlive.activate(options: [])
                NSApp.terminate(nil)
                return
            }
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

    /// A future rename (CFBundleDisplayName/CFBundleName changing) would leave
    /// CFBundleName in Info.plist, but Sparkle's in-place update only
    /// overwrites the bundle's CONTENTS — it never renames the installed
    /// .app folder on disk, and it never nudges Launch Services to re-read
    /// the new metadata. Result: Dock hover tooltips (and sometimes Finder's
    /// Get Info panel) kept showing the OLD name until something forced a
    /// re-scan. `lsregister -f` on our own bundle path does exactly that —
    /// safe, non-destructive, touches no user data, doesn't rename any file.
    /// Runs at most once per build (tracked via the build number so it
    /// doesn't re-run needlessly on every ordinary launch).
    private static func refreshLaunchServicesIfNewBuild() {
        let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        guard !currentBuild.isEmpty else { return }
        let key = "lastLaunchServicesRefreshBuild"
        let d = UserDefaults.standard
        guard d.string(forKey: key) != currentBuild else { return }

        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
        guard FileManager.default.fileExists(atPath: lsregister) else { return }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: lsregister)
        task.arguments = ["-f", Bundle.main.bundlePath]
        task.standardOutput = nil
        task.standardError = nil
        do {
            try task.run()
            // Don't block launch waiting on this — best-effort, fire and forget.
        } catch {
            return
        }
        d.set(currentBuild, forKey: key)
    }

    /// Both `ClipenQuickLook/` (QuickLookController's per-item preview files)
    /// and `ClipenPromises/` (resolved drag-promise files) write a fresh
    /// UUID-named subdirectory on every use and never clean up after
    /// themselves — every entry is a throwaway, always regenerable on
    /// demand, so the whole parent directory is safe to wipe wholesale on
    /// each launch rather than tracking individual entries' lifetimes.
    /// Best-effort, off the main thread, never blocks launch.
    private static func sweepStaleTempDirectories() {
        let tmp = FileManager.default.temporaryDirectory
        let dirs = [tmp.appendingPathComponent("ClipenQuickLook", isDirectory: true),
                    tmp.appendingPathComponent("ClipenPromises", isDirectory: true)]
        DispatchQueue.global(qos: .utility).async {
            for dir in dirs {
                try? FileManager.default.removeItem(at: dir)
            }
        }
    }

    func openMainWindow(retriesLeft: Int = 8) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            existing.minSize = NSSize(width: 900, height: 620)
            existing.makeKeyAndOrderFront(nil)
            // On cold launch, the app was `.accessory` a moment ago and macOS
            // often silently ignores `activate(...)` after such a policy flip,
            // leaving the window layered behind other apps. `orderFrontRegardless`
            // is the OS-level escape hatch that forces the window above every
            // other app's windows regardless of who owns the frontmost slot.
            existing.orderFrontRegardless()
            // A second nudge one runloop tick later covers the case where the
            // policy change wasn't yet visible to the window server on the
            // first try — a common cold-launch race.
            DispatchQueue.main.async { [weak existing] in
                existing?.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
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
        // The closest hook to "this update WILL be installed" — pairs with the
        // app_version person property (already forwarded on every usage ping)
        // to make version-adoption after a release visible: this event marks
        // the moment of transition, app_version on the NEXT ping confirms landing.
        AuthManager.shared.registerActionUsage(actionID: "action.sparkle_update_installed")
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

    /// The overwhelming majority of aborts here are the Mac simply having no
    /// internet at the exact moment Sparkle's silent background timer fires
    /// (asleep, lid closed, wifi reconnecting, VPN hiccup) — not anything
    /// wrong with Clipen. Every laptop drops offline dozens of times a day,
    /// so counting every one of those as a "failure" buried the rare, actually
    /// actionable errors (bad signature, corrupt appcast, install failure)
    /// under a wall of noise. Only report what's left after filtering out
    /// plain connectivity failures.
    private static let benignNetworkErrorCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorDataNotAllowed,
        NSURLErrorSecureConnectionFailed,
        NSURLErrorResourceUnavailable,
    ]

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, Self.benignNetworkErrorCodes.contains(nsError.code) {
            return
        }
        AuthManager.shared.registerActionUsage(actionID: "fail.sparkle_check")
    }
}
