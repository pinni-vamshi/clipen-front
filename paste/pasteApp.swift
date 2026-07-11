import SwiftUI
import AppKit
import Sparkle

@main
struct pasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Clipen", id: "main") {
            MainWindowView()
        }
        .defaultSize(width: 820, height: 680)
        .windowResizability(.contentMinSize)
        // No separate native title bar strip above our own toolbar — the
        // CLIPEN wordmark, Dashboard|Settings switcher, and action buttons
        // sit in the SAME row as the traffic lights instead of a second
        // bar stacked underneath them.
        .windowStyle(.hiddenTitleBar)
        // Taller unified toolbar strip (the window .toolbar in
        // MainWindowView) — macOS centers the traffic lights and every
        // toolbar item in it, giving the row breathing room above/below.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // Only one main window — remove the default "New Window" entry.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Quit Clipen") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
        Settings { EmptyView() }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    /// Sparkle auto-update controller — must be retained for the app lifetime.
    private var updaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Single-instance guard: two Clipen processes (a second copy
        // double-launched from a DMG, or a debug build running beside the
        // installed one) share the same Application Support data directory
        // and race each other's history.clip writes — which can and did
        // destroy the entire clipboard history. If another instance is
        // already running, hand over to it and bow out immediately, before
        // any monitoring or persistence starts.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clipen.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        // Pass `self` as the user-driver delegate so Sparkle uses the gentle
        // reminder pattern — without this, Sparkle warns at runtime that a
        // background (LSUIElement) app may pop update dialogs the user never sees.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        // Run as an accessory (no persistent dock icon — like Rectangle).
        // openMainWindow() switches to .regular while the window is visible
        // and the window-close observer below switches back.
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

        // Default to silently pre-downloading updates so users see "Ready to
        // install" instead of a blocking download progress bar.
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
            updaterController?.updater.automaticallyDownloadsUpdates = true
        }

        ClipboardManager.shared.startMonitoring()

        // Kick one background check shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdatesInBackgroundIfAllowed()
        }

        // Evaluate the first-ever-session flag BEFORE hasLaunchedBefore
        // flips below — the flag uses hasLaunchedBefore to tell a genuine
        // fresh install apart from an upgrade, so touching it after the set
        // would misclassify every fresh install.
        _ = AuthManager.isFirstSessionEver

        // Open the main window on first launch for onboarding.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.openMainWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Reopen the main window when the user double-clicks the app icon in /Applications.
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

    func checkForUpdatesInBackgroundIfAllowed() {
        guard automaticallyChecksForUpdates,
              let updater = updaterController?.updater,
              updater.canCheckForUpdates,
              !updater.sessionInProgress else { return }
        updater.checkForUpdatesInBackground()
    }

    /// Manual "Check for Updates…" — Sparkle compares the running app against `SUFeedURL`.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        guard let updaterController else {
            openLatestReleaseDownload()
            return
        }
        guard updaterController.updater.canCheckForUpdates else {
            openLatestReleaseDownload()
            return
        }
        updaterController.checkForUpdates(nil)
    }

    private func openLatestReleaseDownload() {
        guard let url = URL(string: "https://github.com/pinni-vamshi/clipen-releases/releases/latest/download/Clipen.dmg") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Bring the main settings window to front, creating it if needed.
    /// Retries briefly: on a slow first launch the SwiftUI Window scene may
    /// not have materialised its NSWindow yet when this is called. (The old
    /// fallback opened "clipen://open" — a URL scheme this app never
    /// registered, so it silently did nothing.)
    func openMainWindow(retriesLeft: Int = 6) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            // Belt-and-suspenders on top of MainWindowView's own
            // `.frame(minWidth: 900, minHeight: 620)` — SwiftUI's
            // `.windowResizability(.contentMinSize)` is supposed to derive
            // this from that frame, but setting it directly on the real
            // NSWindow guarantees the floor even if that derivation is ever
            // unreliable, which is what let the toolbar get squeezed
            // narrow enough to visually overlap/stack instead of sitting
            // in one clean row.
            existing.minSize = NSSize(width: 900, height: 620)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.openMainWindow(retriesLeft: retriesLeft - 1)
        }
    }
}

// MARK: - Sparkle update presentation
//
// Clipen runs as `.accessory` (LSUIElement) — no dock icon, no Cmd-Tab
// presence, no menu bar item. `supportsGentleScheduledUpdateReminders = true`
// used to tell Sparkle to DEFER showing automatic/scheduled-check results
// until some later "opportune moment" instead of showing them right away —
// but for an app with no persistent UI surface, that moment never reliably
// arrives, so a background check finding an update was effectively invisible
// forever; only a MANUAL "Check for Updates…" (which always shows
// immediately) ever actually surfaced anything. False here makes an
// automatic check behave exactly like a manual one: show the dialog the
// moment an update is found, with standardUserDriverWillShowModalAlert
// activating the app so it isn't hidden behind whatever you're using.

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

// MARK: - Sparkle update lifecycle

extension AppDelegate: SPUUpdaterDelegate {

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSApp.activate(ignoringOtherApps: true)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Surface silent update-delivery failures (broken appcast, bad EdDSA
        // signature, network abort) via the app's existing fail.* analytics
        // convention — otherwise a whole cohort silently stops getting updates
        // with no signal to the developer.
        AuthManager.shared.registerActionUsage(actionID: "fail.sparkle_check")
    }
}
