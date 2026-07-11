import SwiftUI
import AppKit
@preconcurrency import PDFKit

// MARK: - Design tokens

extension Color {
    static let bg        = Color(light: "#F5F5F7", dark: "#0F0F0F")
    static let surface   = Color(light: "#FFFFFF", dark: "#1A1A1A")
    static let surfaceHi = Color(light: "#ECECEF", dark: "#242424")
    static let border    = Color(light: "#D9D9DE", dark: "#2C2C2C")
    static let accent    = Color(hex: "#4F8EF7")
    static let accentDim = Color(hex: "#4F8EF7").opacity(0.15)
    static let textPri   = Color(light: "#1A1A1A", dark: "#FFFFFF")
    static let textSec   = Color(light: "#6E6E73", dark: "#888888")
    // Dark value was #444444 — barely 1.7:1 on the dark surface, which made
    // the many places that use textDim for real label/description/tool text
    // (edit-picker labels, lab tool abbreviations, helper lines) unreadable
    // in dark mode. #707070 lifts those to a legible ~3.8:1 while staying
    // clearly dimmer than textSec.
    static let textDim   = Color(light: "#9A9AA0", dark: "#707070")
}

// MARK: - Window minimum-size configurator

/// Enforces the window minimum size directly on the NSWindow so it applies
/// from the very first launch, not only when openMainWindow() re-fronts it.
private struct WindowMinSizeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.minSize = NSSize(width: 900, height: 620)
        }
    }
}

// MARK: - Vibrancy background (whole-window frosted glass, Raycast-style)

private struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

// MARK: - Main window

struct MainWindowView: View {

    @StateObject private var manager = ClipboardManager.shared
    @StateObject private var auth    = AuthManager.shared

    @State private var searchText    = ""
    /// Search actually applied to the list. Trails `searchText` by ~150 ms so
    /// hybridSearch (tokenize + score every item) runs once per pause, not
    /// once per keystroke.
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var mainSelectedID: UUID? = nil
    @State private var showTutorial          = false
    @State private var showResetConfirm      = false
    @State private var showSettings          = false
    @AppStorage("hasSkippedAccessibility") private var hasSkippedAccessibility = false
    @AppStorage("hasSeenTutorial")         private var hasSeenTutorial         = false

    // Main window has its own independent tag filter.
    // It never reads or writes manager.popupTagFilter.
    @State private var mainTagFilter: ClipboardTag? = nil

    private var mainFilteredItems: [ClipboardItem] {
        let base = mainTagFilter.map { tag in manager.items.filter { $0.tags.contains(tag) } } ?? manager.items
        // Same pin-block placement as the popup's displayItems — applied
        // here (not in `filtered` below) so an active search's relevance
        // ranking is never overridden by pin position.
        return manager.applyPinOrdering(base)
    }

    private var filtered: [ClipboardItem] {
        guard !debouncedSearchText.isEmpty else { return mainFilteredItems }
        let hits = manager.hybridSearch(query: debouncedSearchText)
        if hits.isEmpty { return [] }
        let visible = Set(mainFilteredItems.map(\.id))
        return hits.filter { visible.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectBackground().ignoresSafeArea()
            WindowMinSizeConfigurator().frame(width: 0, height: 0)

            Group {
                if !manager.hasAccessibilityPermission && !hasSkippedAccessibility && !showSettings {
                    accessibilityOnboarding
                } else {
                    VStack(spacing: 0) {
                        Divider().background(Color.border)
                        if showSettings {
                            settingsFullView
                        } else {
                            browsingView
                                .onAppear {
                                    guard !hasSeenTutorial else { return }
                                    hasSeenTutorial = true
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showTutorial = true }
                                }
                        }
                    }
                }
            }
            .onChange(of: manager.hasAccessibilityPermission) { _, granted in
                if granted && !hasSeenTutorial {
                    hasSeenTutorial = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showTutorial = true }
                }
            }

            if let status = manager.transientStatus {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.top, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        // Wider floor so the two-column Settings layout (04 INTERACTIONS +
        // 05 INTERACTION PREVIEW side by side) never collapses into overlap.
        .frame(minWidth: 900, minHeight: 620)
        // The REAL window toolbar (not a fake row drawn in the content):
        // macOS owns the strip height, draws the traffic lights vertically
        // centered in it, and lays these items out on that same line —
        // wordmark right after the lights, switcher dead center, action
        // pills at the trailing end. The taller unified style is what
        // provides the breathing room above and below the whole row.
        .toolbar {
            // On macOS 26+ every toolbar item gets wrapped in a Liquid
            // Glass capsule by default — our items are fully self-styled,
            // so that system glass is explicitly opted out of; older
            // systems never drew it in the first place.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { toolbarWordmark }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { toolbarSwitcher }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { toolbarActions }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { toolbarWordmark }
                ToolbarItem(placement: .principal) { toolbarSwitcher }
                ToolbarItem(placement: .primaryAction) { toolbarActions }
            }
        }
        // No system material behind the toolbar — the window's own frosted
        // background shows through, same look as the previous custom row.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showTutorial) {
            TutorialSheet(isPresented: $showTutorial, onSeeMore: { showSettings = true })
        }
        .alert("Heads up",
               isPresented: Binding(get: { auth.lastError != nil },
                                    set: { if !$0 { auth.clearError() } })) {
            Button("OK", role: .cancel) { auth.clearError() }
        } message: { Text(auth.lastError ?? "") }
        .alert("Reset to Factory Defaults?", isPresented: $showResetConfirm) {
            Button("Reset Everything", role: .destructive) { performFactoryReset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will erase all clipboard history, settings, and saved data. The app will quit so changes take effect on next launch.")
        }
    }

    // MARK: - Toolbar item styles (used by the window .toolbar above)

    private var toolbarWordmark: some View {
        Text("CLIPEN")
            .font(.system(size: 13, weight: .heavy))
            .tracking(3)
            .foregroundStyle(LinearGradient(colors: [Color(hex: "#FFB088"), Color(hex: "#FF8A80")],
                                            startPoint: .leading, endPoint: .trailing))
    }

    private var toolbarSwitcher: some View {
        HStack(spacing: 2) {
            toolbarSegment("Dashboard", active: !showSettings) { showSettings = false }
            toolbarSegment("Settings",  active: showSettings)  { showSettings = true }
        }
        .padding(3)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var toolbarActions: some View {
        HStack(spacing: 8) {
            toolbarPill("Check for Updates", icon: "arrow.triangle.2.circlepath") {
                AppDelegate.shared?.checkForUpdates()
            }
            toolbarPill("How to Use", icon: "questionmark.circle") {
                showTutorial = true
            }
        }
    }

    private func toolbarSegment(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundColor(active ? Color(hex: "#FFB088") : .textSec)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(active ? Color.white.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toolbarPill(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(.textSec)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    // MARK: - Settings (full-window takeover)

    private var settingsFullView: some View {
        ClipenSettingsView(showResetConfirm: $showResetConfirm)
    }

    // MARK: - Browsing view (Raycast-style: search on top, split below, footer)

    private var browsingView: some View {
        VStack(spacing: 0) {
            if !manager.hasAccessibilityPermission { cyclingUnavailableBanner }

            raycastSearchBar
            Divider().background(Color.border)

            if manager.items.isEmpty {
                // Nothing copied yet — the split panes would both be empty,
                // so give the animated onboarding the whole area instead.
                OnboardingView()
            } else {
                HSplitView {
                    listPane
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 400)
                        .frame(maxHeight: .infinity)
                    detailPane
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider().background(Color.border)
            footerBar
        }
        .onAppear { if mainSelectedID == nil { mainSelectedID = filtered.first?.id } }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                // Clearing search should feel instant — no debounce on the way out.
                debouncedSearchText = ""
                return
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
                AuthManager.shared.registerActionUsage(actionID: "action.window-search")
            }
        }
        .onChange(of: debouncedSearchText) { _, _ in mainSelectedID = filtered.first?.id }
        .onChange(of: mainTagFilter) { _, _ in mainSelectedID = filtered.first?.id }
    }

    // MARK: Top search bar (full window width, borderless — Raycast style)

    private var raycastSearchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium)).foregroundColor(.textDim)
            TextField("Search clipboard history…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundColor(.textPri)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.textDim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }

            // Ring count at the right end of the search bar, just before the
            // filter dropdown — quieter here than in the footer, and reads
            // as a live status next to the "All" filter it relates to.
            Text("\(manager.items.count) / \(manager.maxItems)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textDim)
                .help("Items in ring / maximum")

            filterDropdown
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Category filter as a compact dropdown at the right end of the search
    /// bar (replaces the old chip strip — same behavior, Raycast placement).
    private var filterDropdown: some View {
        Menu {
            Button {
                mainTagFilter = nil
            } label: {
                Label("All (\(manager.items.count))", systemImage: "square.grid.2x2")
            }
            ForEach(manager.availableTags, id: \.self) { tag in
                Button {
                    mainTagFilter = tag
                } label: {
                    Label("\(tag.label) (\(manager.itemCount(for: tag)))", systemImage: tag.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mainTagFilter?.icon ?? "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                Text(mainTagFilter?.label ?? "All")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundColor(.textSec)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // MARK: Left list pane (minimal rows — icon + one line)

    private var listPane: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .thin)).foregroundColor(.textDim)
                    Text("No matches").font(.system(size: 13, weight: .medium)).foregroundColor(.textSec)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered) { item in
                            CompactItemRow(item: item, isSelected: mainSelectedID == item.id,
                                          onDelete: {
                                              if let i = manager.items.firstIndex(where: { $0.id == item.id }) {
                                                  manager.removeItem(at: i)
                                              }
                                          },
                                          onTogglePin: { manager.togglePin(id: item.id) })
                                .equatable()
                                .onTapGesture(count: 1) { mainSelectedID = item.id }
                                .onTapGesture(count: 2) {
                                    // Double-click opens the native macOS Quick
                                    // Look panel (same as Space in Finder) instead
                                    // of pasting — Enter now pastes the selection,
                                    // see the .onKeyPress(.return) below.
                                    mainSelectedID = item.id
                                    QuickLookController.shared.toggle(for: item)
                                }
                                .contextMenu {
                                    Button("Paste") {
                                        if let i = manager.items.firstIndex(where: { $0.id == item.id }) {
                                            manager.pasteItem(at: i)
                                        }
                                    }
                                    Divider()
                                    Button(item.isPinned ? "Unpin" : "Pin") { manager.togglePin(id: item.id) }
                                    Button("Remove", role: .destructive) {
                                        if let i = manager.items.firstIndex(where: { $0.id == item.id }) {
                                            manager.removeItem(at: i)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        // Paste moved here from double-click (now Quick Look) — Enter pastes
        // whichever row is currently selected.
        .onKeyPress(.return) {
            guard let id = mainSelectedID,
                  let i = manager.items.firstIndex(where: { $0.id == id }) else { return .ignored }
            manager.pasteItem(at: i)
            return .handled
        }
    }

    // MARK: Bottom footer bar

    /// Same "vX.Y.Z (build)" string the Settings footer shows, so both
    /// footers display the running version identically.
    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
            // Left cluster: ♥ Support Clipen · version · Built by — same
            // shape as the Settings footer's left side.
            Button {
                if let url = URL(string: "https://www.instagram.com/clipen.official") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "heart.fill").font(.system(size: 11)).foregroundColor(.pink)
                    Text("Support Clipen").font(.system(size: 11)).foregroundColor(.textSec)
                }
            }
            .buttonStyle(.plain)
            .help("Support Clipen")

            Text("· \(Self.appVersionString) · Built by Vamshi Krishna Pinni")
                .font(.system(size: 11)).foregroundColor(.textDim)

            Spacer()

            if !manager.items.isEmpty {
                Button { manager.clearAll() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "trash").font(.system(size: 9))
                        Text("Clear all").font(.system(size: 11))
                    }
                    .foregroundColor(.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.textDim)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func performFactoryReset() {
        // Wipe clipboard history
        manager.clearAll()

        // Delete the on-disk store DIRECTLY — clearAll only empties the
        // in-memory ring and relies on the 1-second DEBOUNCED save to
        // persist that emptiness, but terminate() below runs immediately,
        // so the debounce never fired and the old encrypted manifest +
        // blobs survived on disk. Result: "factory reset" brought the
        // entire clipboard history back on next launch. Removing the
        // whole Clipen dir (manifest, blobs, file copies, history.key)
        // is what actually makes the next launch a fresh install.
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("Clipen"))

        // Wipe all UserDefaults for this app
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }

        // Wipe Keychain (any legacy stored secrets)
        Keychain.wipeAll()

        // Quit so next launch feels like a fresh install
        NSApp.terminate(nil)
    }

    // MARK: Accessibility permission screen

    private var accessibilityOnboarding: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle().fill(Color.orange.opacity(0.12)).frame(width: 110, height: 110)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 40, weight: .thin)).foregroundColor(.orange)
            }
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                Text("One Permission Needed")
                    .font(.system(size: 24, weight: .bold)).foregroundColor(.textPri)
                Text("Clipen needs Accessibility access so\n⌘V can cycle your clipboard ring.")
                    .font(.system(size: 13)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)

            VStack(alignment: .leading, spacing: 10) {
                axStep("1", "Hold ⌘ and tap V",  "Opens your clipboard ring near the cursor")
                axStep("2", "Tap V · ⌘⌥V",       "Next item · ⌘⌥V jumps 5 forward")
                axStep("3", "Tap V, then X",     "Pick an item with V, then transform it with X")
                axStep("4", "Tap V, then ⌫",     "Pick an item with V, then delete it from the ring")
                axStep("5", "Release ⌘",         "Pastes the highlighted (or transformed) item")
            }
            .padding(.horizontal, 56).padding(.bottom, 30)

            Button {
                manager.attemptEventTap()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                    Text("Open Accessibility Settings")
                }
                .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                .padding(.horizontal, 28).padding(.vertical, 13)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: Color.orange.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain).padding(.bottom, 12)

            Button { hasSkippedAccessibility = true } label: {
                Text("Skip — I'll enable this later").font(.system(size: 12))
                    .foregroundColor(.textSec).underline()
            }
            .buttonStyle(.plain)

            Spacer()

            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.65)
                Text("Waiting for permission to be granted…").font(.system(size: 11)).foregroundColor(.textDim)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.bg)
    }

    private func axStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 11, weight: .bold)).foregroundColor(.orange)
                .frame(width: 22, height: 22).background(Color.orange.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(.textPri)
                Text(subtitle).font(.system(size: 11)).foregroundColor(.textSec)
            }
            Spacer()
        }
    }

    private var cyclingUnavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("⌘V cycling is unavailable")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(.textPri)
                Text("Clipen needs Accessibility permission to show the paste popup. History and double-click-to-paste still work.")
                    .font(.system(size: 11)).foregroundColor(.textSec).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            } label: {
                Text("Open Settings").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .overlay(Rectangle().fill(Color.orange.opacity(0.35)).frame(height: 1), alignment: .bottom)
    }

    // MARK: - Detail pane (selected item)

    @ViewBuilder
    private var detailPane: some View {
        if let id = mainSelectedID, let item = manager.items.first(where: { $0.id == id }) {
            ItemDetailView(item: item)
                .id(item.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 40, weight: .thin)).foregroundColor(.textDim)
                Text("Select an item").font(.system(size: 14, weight: .medium)).foregroundColor(.textSec)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Chip strip for the "Pasted to" row. A plain `ScrollView(.horizontal)` only
/// responds to a horizontal-capable scroll input (trackpad two-finger swipe,
/// or shift+wheel) — a user on a plain vertical-scroll mouse has no way to
/// reveal chips past the visible edge. This tracks its own drag offset so
/// click-and-drag panning works with any pointing device, clamped so it
/// can't be dragged past either end.
private struct PastedToChipStrip: View {
    let names: [String]

    @State private var committedOffset: CGFloat = 0
    @State private var dragOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var stripWidth: CGFloat = 0

    private var maxOffset: CGFloat { max(0, contentWidth - stripWidth) }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.textPri)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
        }
        .background(GeometryReader { geo in
            Color.clear.onAppear { contentWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in contentWidth = newWidth }
        })
        .offset(x: -min(maxOffset, max(0, committedOffset + dragOffset)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(GeometryReader { geo in
            Color.clear.onAppear { stripWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, newWidth in stripWidth = newWidth }
        })
        .gesture(
            DragGesture()
                .onChanged { value in dragOffset = -value.translation.width }
                .onEnded { value in
                    committedOffset = min(maxOffset, max(0, committedOffset - value.translation.width))
                    dragOffset = 0
                }
        )
    }
}

// MARK: - Item detail view (Raycast-style right pane)

private struct ItemDetailView: View {
    let item: ClipboardItem

    @State private var noteText: String
    /// Last value actually pushed into the manager. Note commits are debounced
    /// (400 ms) because updateUserNote mutates the @Published items array —
    /// committing per keystroke re-rendered the entire window and reset the
    /// disk-save debounce on every character typed.
    @State private var lastCommittedNote: String
    @State private var noteCommitTask: Task<Void, Never>? = nil
    @FocusState private var noteFocused: Bool

    init(item: ClipboardItem) {
        self.item = item
        let existing = item.userNote ?? ""
        _noteText = State(initialValue: existing)
        _lastCommittedNote = State(initialValue: existing)
    }

    private func commitNote(_ value: String) {
        guard value != lastCommittedNote else { return }
        lastCommittedNote = value
        ClipboardManager.shared.updateUserNote(id: item.id, note: value)
    }

    /// User-adjustable pinned-preview height — dragged via the splitter
    /// under the preview, persisted across launches.
    @AppStorage("detailPreviewHeight") private var previewHeight: Double = 290
    @State private var dragStartHeight: Double? = nil
    /// Live height while actively dragging. Reading/writing `previewHeight`
    /// (an @AppStorage) on every pixel of drag movement did two expensive
    /// things per pixel: a synchronous UserDefaults write, and a full
    /// re-layout of the pinned preview above (which can be a large image/PDF/
    /// zoomable view) — the main thread couldn't keep up on a fast or long
    /// drag, so the visible height fell behind and snapped erratically
    /// ("vibrating"). This tracks the drag with a plain, cheap @State instead;
    /// `previewHeight` itself is only written once, when the drag ends.
    @State private var liveDragHeight: Double? = nil
    private var effectiveHeight: Double { liveDragHeight ?? previewHeight }

    var body: some View {
        VStack(spacing: 0) {
            // Pinned preview — fixed at the top of the pane, never scrolls
            // away, on a darker backdrop. No type header and no extra
            // rounded boundary around the content: the type already shows
            // in Properties below, and the darker region IS the frame.
            VStack(alignment: .leading, spacing: 14) {
                pinnedContent
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: CGFloat(effectiveHeight), alignment: .top)
            .background(Color.black.opacity(0.25))
            .clipped()

            // Draggable splitter — resize the preview area to taste.
            ZStack {
                Divider().background(Color.border)
                Capsule().fill(Color.border)
                    .frame(width: 36, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 11)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartHeight ?? previewHeight
                        dragStartHeight = base
                        liveDragHeight = min(560, max(140, base + Double(value.translation.height)))
                    }
                    .onEnded { _ in
                        // Commit to @AppStorage exactly once, on release —
                        // not per pixel — so the drag itself never pays for
                        // a UserDefaults write or the persisted-value's own
                        // observers re-running mid-gesture.
                        if let final = liveDragHeight { previewHeight = final }
                        liveDragHeight = nil
                        dragStartHeight = nil
                    }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    propertiesCard
                    notesBlock
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.clear)
    }

    /// Content inside the pinned region. Text-like content gets its own
    /// scroll view so long text scrolls WITHIN the fixed preview area;
    /// visual content (images, PDFs, files) fills the area directly since
    /// those views manage their own zoom/pan.
    @ViewBuilder
    private var pinnedContent: some View {
        switch item.content {
        case .image, .file:
            contentBlock
        default:
            ScrollView { contentBlock }
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        switch item.content {
        case .text(let s):
            SelectableTextBlock(text: s.displayTrimmedLeading)
        case .richText(_, plain: let rawP), .html(_, plain: let rawP), .rtfd(_, plain: let rawP):
            let p = rawP.displayTrimmedLeading
            // Previously: a document with an embedded table (e.g. a markdown
            // file or Notes/Word doc that has a table alongside other text
            // or code) showed ONLY the extracted table grid, silently
            // discarding every other line — the extractor finding a table
            // ANYWHERE replaced the WHOLE preview instead of supplementing
            // it. Always show the full content; add the table grid as well
            // when one was found, rather than instead.
            VStack(alignment: .leading, spacing: 14) {
                SelectableTextBlock(text: p)
                if let cells = TableCellExtractor.cells(for: item) {
                    MiniTablePreview(cells: cells).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .image(let img, let data, let dataType):
            // Same zoom/pan dispatch as ItemPreviewPanel and the reference
            // panel — the detail pane is one of the four preview surfaces
            // and gets identical interactions: pinch/double-click zoom,
            // scroll-pan; image-typed PDFs get a real PDF view; GIFs play.
            // fullResData decodes ONCE inside the view (data-change gated),
            // never inline here in body — that inline decode was the
            // v1.0.144 CPU/memory churn regression.
            Group {
                if dataType.rawValue.contains("pdf"), let pdf = PDFDocument(data: data) {
                    PDFPreview(document: pdf)
                } else if dataType.rawValue.contains("gif") {
                    ZoomableImagePreview(image: img, animatedData: data)
                } else {
                    ZoomableImagePreview(image: img, fullResData: data)
                }
            }
            // No boxed background/border — the darker pinned region already
            // frames the preview.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file(let url):
            // FilePreviewContent already exists in ItemPreviewPanel.swift and
            // renders the ACTUAL file — PDF pages, images, HTML, readable
            // text, media, 3D models, with a QuickLook fallback for
            // everything else. The main window used to show just an icon
            // and a filename here; now it shows the same real preview the
            // popup does, at a fixed size so the layout doesn't jump around
            // between different file types.
            VStack(alignment: .leading, spacing: 10) {
                FilePreviewContent(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 10) {
                    Image(nsImage: ClipenIconCache.shared.fileIcon(for: url)).resizable().frame(width: 20, height: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).foregroundColor(.textPri)
                        Text(url.path).font(.system(size: 10)).foregroundColor(.textDim).lineLimit(1)
                    }
                }
            }
        case .files(let urls):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: ClipenIconCache.shared.fileIcon(for: url)).resizable().frame(width: 24, height: 24)
                        Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(.textPri).lineLimit(1)
                    }
                }
            }
        case .svg(let src):
            SelectableTextBlock(text: src)
        case .blob(let typeMap):
            VStack(alignment: .leading, spacing: 4) {
                Text("Private clipboard data").font(.system(size: 13, weight: .medium)).foregroundColor(.textPri)
                ForEach(typeMap.keys.sorted(), id: \.self) { key in
                    Text(key).font(.system(size: 11, design: .monospaced)).foregroundColor(.textDim)
                }
            }
        }
    }

    private var sizeString: String {
        let bytes: Int
        switch item.content {
        case .text(let s):
            bytes = s.utf8.count
        case .richText(_, plain: let p), .html(_, plain: let p), .rtfd(_, plain: let p):
            bytes = p.utf8.count
        case .image(_, let data, _):
            bytes = data.count
        case .svg(let s):
            bytes = s.utf8.count
        case .blob(let map):
            bytes = map.values.reduce(0) { $0 + $1.count }
        case .file(let url):
            bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        case .files(let urls):
            bytes = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var dimensionsString: String? {
        if case .image(let img, _, _) = item.content {
            return "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }
        return nil
    }

    /// Every destination app this item has ever been pasted into —
    /// pastedToAppNames accumulates ALL destinations (not just the last one).
    private var pastedToNames: [String] {
        var names = Array(Set(item.pastedToAppNames.values)).sorted()
        if names.isEmpty, let last = item.pastedToAppName { names = [last] }
        return names
    }

    /// "Pasted to" row — the destinations as chips in a HORIZONTALLY
    /// scrolling strip, so any number of apps fits and the user can scroll
    /// sideways to reveal them all.
    private var pastedToRow: some View {
        HStack(spacing: 12) {
            Text("Pasted to").font(.system(size: 12)).foregroundColor(.textSec)
            Spacer(minLength: 8)
            PastedToChipStrip(names: pastedToNames).frame(maxWidth: 280)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var propertiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPERTIES").font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
            VStack(spacing: 0) {
                propertyRow("Type", item.typeLabel)
                cardDivider()
                if let appName = item.sourceAppName {
                    // Where it was copied FROM.
                    propertyRow("Copied from", appName)
                    cardDivider()
                }
                if !pastedToNames.isEmpty {
                    // Where it has been pasted TO — every destination, in a
                    // horizontally scrollable chip strip.
                    pastedToRow
                    cardDivider()
                }
                propertyRow("Size", sizeString)
                if let dims = dimensionsString {
                    cardDivider()
                    propertyRow("Dimensions", dims)
                }
                cardDivider()
                propertyRow("Copied", item.timestamp.formatted(date: .abbreviated, time: .shortened))
                if let lastPasted = item.lastPastedAt {
                    cardDivider()
                    propertyRow("Last pasted", lastPasted.formatted(date: .abbreviated, time: .shortened))
                }
                if !item.tags.isEmpty {
                    cardDivider()
                    // Detected tags / categories, same labels the Reference
                    // panel and category chips use.
                    propertyRow("Tags", item.tags.map(\.label).joined(separator: ", "))
                }
            }
            .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
        }
    }

    private func propertyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(.textSec)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(.textPri)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func cardDivider() -> some View {
        Divider().background(Color.border)
    }

    private var notesBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NOTES").font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $noteText)
                    .font(.system(size: 12))
                    .foregroundColor(.textPri)
                    .frame(minHeight: 80)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))
                    .focused($noteFocused)
                    .onChange(of: noteText) { _, newValue in
                        noteCommitTask?.cancel()
                        noteCommitTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            guard !Task.isCancelled else { return }
                            commitNote(newValue)
                        }
                    }
                    .onDisappear {
                        // Selection switched or window closed mid-debounce —
                        // flush whatever's pending so no typed note is lost.
                        noteCommitTask?.cancel()
                        commitNote(noteText)
                    }
                if noteText.isEmpty && !noteFocused {
                    Text("Add a note…").font(.system(size: 12)).foregroundColor(.textDim)
                        .padding(.horizontal, 10).padding(.vertical, 12).allowsHitTesting(false)
                }
            }
        }
    }
}

private struct SelectableTextBlock: View {
    /// Raw text — capped for DISPLAY here (never affects paste/search,
    /// which read the item's actual content directly). A huge pasted blob
    /// (a JSON dump, a giant log) is already fully in memory, but handing
    /// it whole to a SwiftUI Text view still costs real per-render layout
    /// time; this bounds what's actually rendered.
    let text: String
    private var capped: (text: String, isTruncated: Bool) { text.displayCapped() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if capped.isTruncated {
                Text("Showing the first part of a large paste")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textDim)
            }
            // Plain text on the pinned region's own darker backdrop — no
            // boxed background or rounded border of its own.
            Text(capped.text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.textPri)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Compact list row (Raycast-style: icon + one line, nothing else)

private struct CompactItemRow: View, Equatable {
    let item:       ClipboardItem
    let isSelected: Bool
    var onDelete: () -> Void = {}
    var onTogglePin: () -> Void = {}

    @State private var isHovered = false

    // Skip re-rendering unchanged rows when the list re-evaluates (any manager
    // @Published change, incl. async enrichment re-publishing `items`). Local
    // hover @State still updates independently — `.equatable()` only short-
    // circuits parent-driven re-renders, not a view's own state changes.
    // Compares exactly what title/icon/pin render: identity, selection, and the
    // mutable fields (isPinned, urlTitle, metadataSummary); content is immutable.
    static func == (l: CompactItemRow, r: CompactItemRow) -> Bool {
        l.item.id == r.item.id &&
        l.isSelected == r.isSelected &&
        l.item.isPinned == r.item.isPinned &&
        l.item.urlTitle == r.item.urlTitle &&
        l.item.metadataSummary == r.item.metadataSummary
    }

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .textPri : .textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isHovered {
                // Hover-revealed actions — delete (red) and pin/unpin
                // (blue) — instead of needing the right-click context menu
                // for the two most common row-level actions.
                HStack(spacing: 6) {
                    rowActionButton(icon: "xmark", background: .red, action: onDelete)
                        .help("Delete")
                    rowActionButton(icon: item.isPinned ? "pin.slash.fill" : "pin.fill",
                                    background: .blue, action: onTogglePin)
                        .help(item.isPinned ? "Unpin" : "Pin to top")
                }
            } else if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.accent)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(
            isSelected ? Color.white.opacity(0.10)
                       : (isHovered ? Color.white.opacity(0.05) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onDrag { item.makeItemProvider() }
    }

    private func rowActionButton(icon: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 16, height: 16)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch item.content {
        case .image(let img, let rawData, _):
            Image(nsImage: ItemThumbnailCache.shared.thumbnail(forData: rawData, key: item.id.uuidString) ?? img)
                .resizable().scaledToFill()
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        case .file(let url):
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                .resizable().frame(width: 16, height: 16)
        default:
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isSelected ? .textPri : .textDim)
                .frame(width: 18)
        }
    }

    private var iconName: String {
        switch item.content {
        case .text:                   return item.urlTitle != nil ? "link" : "doc.text"
        case .richText, .html, .rtfd: return "doc.richtext"
        case .image:                  return "photo"
        case .file:                   return "doc"
        case .files:                  return "doc.on.doc"
        case .svg:                    return "chevron.left.forwardslash.chevron.right"
        case .blob:                   return "lock.doc"
        }
    }

    private var title: String {
        switch item.content {
        case .text(let s):
            if let t = item.urlTitle { return t }
            return firstLine(s)
        case .richText(_, plain: let p), .html(_, plain: let p), .rtfd(_, plain: let p):
            return firstLine(p)
        case .image:
            return item.metadataSummary.map { "Image · \($0)" } ?? "Image"
        case .file(let url):
            return url.lastPathComponent
        case .files(let urls):
            return item.metadataSummary ?? "\(urls.count) files"
        case .svg:
            return "SVG"
        case .blob:
            return "Private clipboard data"
        }
    }

    private func firstLine(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .newlines).first ?? trimmed
    }
}

// MARK: - Utilities

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
