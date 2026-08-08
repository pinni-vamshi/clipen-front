import SwiftUI
import AppKit
import Sparkle
import FirebaseCore

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

private struct WindowOpenBridge: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .onAppear { AppDelegate.requestOpenMainWindow = { openWindow(id: "main") } }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    static let reopenNotification = Notification.Name("com.clipen.app.reopenMainWindow")

    static var requestOpenMainWindow: (() -> Void)?

    private var updaterController: SPUStandardUpdaterController?

    private var pendingUpdateInstall: (() -> Void)?
    private var pendingUpdateTimer: Timer?

    private static let pendingUpdateVersionKey = "clipen.sparkle.pendingUpdateVersion"

    private static func confirmPendingUpdateOutcome() {
        let d = UserDefaults.standard
        guard let expected = d.string(forKey: pendingUpdateVersionKey) else { return }
        d.removeObject(forKey: pendingUpdateVersionKey)
        let running = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        if running == expected {
            AuthManager.shared.registerActionUsage(actionID: "action.sparkle_update_confirmed")
        } else {
            AuthManager.shared.registerActionUsage(actionID: "fail.sparkle_update_did_not_land")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        FirebaseApp.configure()
        WakeGuard.install()
        Self.refreshLaunchServicesIfNewBuild()
        Self.sweepStaleTempDirectories()

        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipen.app"
        func liveSibling() -> NSRunningApplication? {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                         && $0.isTerminated == false }
        }
        if let candidate = liveSibling() {

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
        Self.confirmPendingUpdateOutcome()

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

        updaterController?.checkForUpdates(nil)
    }

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

        } catch {
            return
        }
        d.set(currentBuild, forKey: key)
    }

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

            existing.orderFrontRegardless()

            DispatchQueue.main.async { [weak existing] in
                existing?.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
            return
        }

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

        AuthManager.shared.registerActionUsage(actionID: "action.sparkle_update_installed")
        UserDefaults.standard.set(item.displayVersionString, forKey: Self.pendingUpdateVersionKey)
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

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        AuthManager.shared.registerActionUsage(actionID: "action.sparkle_check_up_to_date")
    }

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
