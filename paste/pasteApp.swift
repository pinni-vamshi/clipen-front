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
            // Remove "New Window" — only one main window
            CommandGroup(replacing: .newItem) {}
            // Menu-bar module is disabled for now, so Cmd+Q should quit normally.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Clipen") {
                    NSApp.terminate(nil)
                }
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

    private var statusItem: NSStatusItem?
    private var menuPanel: NSPanel?
    private var outsideClickMonitor: Any?

    var showMenuBarIcon: Bool = false {
        didSet {
            // Keep persisted as false while this feature is disabled.
            UserDefaults.standard.set(false, forKey: "showMenuBarIcon")
            applyMenuBarVisibility()
        }
    }

    private let menuBarFeatureEnabled = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Pass `self` as the user-driver delegate so Sparkle uses the gentle
        // reminder pattern below — without this, Sparkle warns at runtime
        // that a background (LSUIElement) app may pop update dialogs the
        // user never sees, because there's no dock icon to draw attention.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )

        // Run as an accessory (no persistent dock icon — like Rectangle).
        // openMainWindow() switches to .regular while the window is visible
        // and the window-close observer below switches back.
        NSApp.setActivationPolicy(.accessory)
        statusItem = nil
        menuPanel = nil

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

        applyMenuBarVisibility()

        // Default to silently pre-downloading updates so users see "Ready to
        // install" instead of a blocking download progress bar. Only set on
        // first run so users who explicitly turned this off keep their choice.
        if UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate") == nil {
            updaterController?.updater.automaticallyDownloadsUpdates = true
        }

        // Start the IMK server so text clients can connect and report caret rects.
        // This only activates when the user has enabled "Clipen" in
        // System Settings › Keyboard › Input Sources — otherwise it's a no-op.
        let imkName = Bundle.main.infoDictionary?["InputMethodConnectionName"] as? String
                      ?? "ClipenInput"
        inputMethodServer = IMKServer(name: imkName, bundleIdentifier: Bundle.main.bundleIdentifier)

        ClipboardManager.shared.startMonitoring()
        // Kick one background check shortly after launch so update availability
        // is known even before the user starts cycling with ⌘V.
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

    /// Reopen the main window when the user double-clicks the app icon
    /// in /Applications (since there's no dock icon to click).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openMainWindow() }
        return true
    }

    private func applyMenuBarVisibility() {
        guard menuBarFeatureEnabled else {
            statusItem?.isVisible = false
            hideMenu()
            return
        }
        statusItem?.isVisible = showMenuBarIcon
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
        hideMenu()
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

    /// Fallback path when Sparkle cannot start a check (e.g. transient
    /// session state). This still gets the user to the newest DMG.
    private func openLatestReleaseDownload() {
        guard let url = URL(string: "https://github.com/pinni-vamshi/clipen-releases/releases/latest/download/Clipen.dmg") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Bring the main settings window to front, creating it if needed.
    func openMainWindow() {
        // Restore dock icon and Cmd-Tab presence while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        // Fallback: use the SwiftUI URL scheme for opening the Window scene
        if let url = URL(string: "clipen://open") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func statusItemClicked(_ sender: AnyObject?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp ||
                           (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            showRightClickMenu()
        } else {
            toggleMenu(sender)
        }
    }

    private func showRightClickMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Clipen",
                                action: #selector(openMainWindowAction),
                                keyEquivalent: ""))

        // Pause / Resume clipboard capture — privacy toggle for sensitive
        // entry (passwords, 2FA codes, etc.). Toggle reflects current state.
        let paused = ClipboardManager.shared.isCapturingPaused
        let pauseItem = NSMenuItem(
            title: paused ? "Resume capturing clipboard" : "Pause capturing clipboard",
            action: #selector(toggleCapturePause),
            keyEquivalent: "")
        pauseItem.state = paused ? .on : .off
        menu.addItem(pauseItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "About Clipen",
                                action: #selector(showAboutWindow),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check for Updates…",
                                action: #selector(checkForUpdatesAction),
                                keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Clipen",
                                action: #selector(quitApp),
                                keyEquivalent: "q"))
        for item in menu.items { item.target = self }

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Detach so left-click goes back to the panel toggle
        DispatchQueue.main.async { [weak self] in self?.statusItem?.menu = nil }
    }

    @objc private func openMainWindowAction() { openMainWindow() }
    @objc private func checkForUpdatesAction() { checkForUpdates() }
    @objc private func quitApp()              { NSApp.terminate(nil) }

    @objc private func toggleCapturePause() {
        ClipboardManager.shared.isCapturingPaused.toggle()
    }

    @objc private func showAboutWindow() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"]            as? String ?? "?"
        let credits = NSMutableAttributedString(
            string: "A keyboard-first clipboard manager for macOS.\nSupport: support@clipen.app",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11)
            ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName:    "Clipen",
            .applicationVersion: version,
            .version:            "Build \(build)",
            .credits:            credits,
            .init(rawValue: "Copyright"): "© 2026 Clipen"
        ])
    }

    @objc private func toggleMenu(_ sender: AnyObject?) {
        guard let panel = menuPanel else { return }
        if panel.isVisible {
            hideMenu()
        } else {
            showMenu()
        }
    }

    private func showMenu() {
        guard let panel = menuPanel,
              let btn = statusItem?.button,
              let btnWindow = btn.window else { return }

        // Rebuild the hosting view fresh each time the menu opens so SwiftUI
        // re-evaluates with the current ClipboardManager state. Avoids any
        // stale-render issues when items change while the panel is hidden.
        let menuRoot = MenuBarView()
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        panel.contentView = NSHostingView(rootView: menuRoot)
        guard let hosting = panel.contentView else { return }

        let btnFrame = btnWindow.convertToScreen(btn.convert(btn.bounds, to: nil))
        let fitting  = hosting.fittingSize
        let w = max(320, min(fitting.width, 480))
        let h = max(140, min(fitting.height, 600))
        let x = btnFrame.midX - w / 2
        let y = btnFrame.minY - h - 4

        // Clamp to screen bounds
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let clampedX = max(screen.minX + 8, min(x, screen.maxX - w - 8))
        let clampedY = max(screen.minY + 8, y)

        panel.setFrame(NSRect(x: clampedX, y: clampedY, width: w, height: h), display: false)
        panel.orderFront(nil)

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hideMenu()
        }
    }

    private func hideMenu() {
        menuPanel?.orderOut(nil)
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }
}

// MARK: - Sparkle gentle reminders
//
// Clipen runs as `.accessory` (LSUIElement) — no dock icon, no Cmd-Tab
// presence. Sparkle's default presentation can therefore pop an update
// dialog while the user is in another app and they'd never notice. The
// "gentle reminder" pattern below opts in to:
//   1. Tell Sparkle we're aware of the background-app problem.
//   2. When Sparkle wants to show a non-user-initiated update dialog,
//      bring the app forward so the dialog is actually on screen.
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
        // Bring app forward so the update dialog is visible — update found is
        // the one case where interrupting the user is warranted.
        NSApp.activate(ignoringOtherApps: true)
    }

    // didNotFindUpdate and didAbortWithError must NOT activate — they fire on
    // every silent background check (launch + 24h scheduler). Activating here
    // yanks Clipen to the foreground even when nothing interesting happened.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) { }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { }
}
