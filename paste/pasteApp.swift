import SwiftUI
import AppKit
import InputMethodKit
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

    /// IMK server for caret-position tracking (level 1 of the 4-level fallback).
    /// Retained for the app lifetime. Connects to text clients when the user
    /// has added "Clipen" to System Settings › Keyboard › Input Sources.
    private var inputMethodServer: IMKServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

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

        // Start the IMK server so text clients can report caret rects.
        let imkName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
                      ?? "ClipenInput"
        inputMethodServer = IMKServer(name: imkName, bundleIdentifier: Bundle.main.bundleIdentifier)

        ClipboardManager.shared.startMonitoring()

        // Kick one background check shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.checkForUpdatesInBackgroundIfAllowed()
        }

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
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        if let url = URL(string: "clipen://open") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Sparkle gentle reminders
//
// Clipen runs as `.accessory` (LSUIElement) — no dock icon, no Cmd-Tab
// presence. Sparkle's default presentation can therefore pop an update
// dialog while the user is in another app and they'd never notice.

extension AppDelegate: SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

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
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { }
}
