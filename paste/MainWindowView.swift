import SwiftUI
import AppKit
@preconcurrency import PDFKit

// MARK: - Design tokens

extension Color {
    static let bg        = Color(hex: "#0F0F0F")
    static let surface   = Color(hex: "#1A1A1A")
    static let surfaceHi = Color(hex: "#242424")
    static let border    = Color(hex: "#2C2C2C")
    static let accent    = Color(hex: "#4F8EF7")
    static let accentDim = Color(hex: "#4F8EF7").opacity(0.15)
    static let textPri   = Color.white
    static let textSec   = Color(hex: "#888888")
    static let textDim   = Color(hex: "#444444")
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
        guard let tag = mainTagFilter else { return manager.items }
        return manager.items.filter { $0.tags.contains(tag) }
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

            Group {
                if !manager.hasAccessibilityPermission && !hasSkippedAccessibility && !showSettings {
                    accessibilityOnboarding
                } else {
                    VStack(spacing: 0) {
                        topToolbar
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
                    // The missing third piece of the same-row-as-traffic-lights
                    // fix: .hiddenTitleBar (pasteApp) hides the title, and the
                    // 62pt leading padding (topToolbar) clears the light
                    // cluster — but SwiftUI still exposes the invisible
                    // titlebar strip as a top safe-area inset, so without this
                    // the whole toolbar row was laid out BELOW it, leaving the
                    // traffic lights alone on an empty strip. Ignoring the top
                    // inset lifts the row into that strip so CLIPEN, the
                    // switcher, and the buttons share one line with the lights.
                    .ignoresSafeArea(.container, edges: .top)
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
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showTutorial) { TutorialSheet(isPresented: $showTutorial) }
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

    // MARK: - Top toolbar (CLIPEN wordmark · Dashboard|Settings · actions)

    /// Single title-bar row (the content stack ignores the top safe-area
    /// inset, so this shares the strip with the traffic lights):
    ///   · leading — CLIPEN, right after the traffic-light cluster
    ///   · center  — the Dashboard | Settings switcher, true window center
    ///   · trailing — Check for Updates + How to Use, pushed to the far end
    /// The window's hard 900pt minimum width (NSWindow.minSize + frame
    /// minWidth) is what keeps the centered switcher from ever colliding
    /// with the leading/trailing groups.
    private var topToolbar: some View {
        ZStack {
            HStack(spacing: 8) {
                Text("CLIPEN")
                    .font(.system(size: 13, weight: .heavy))
                    .tracking(3)
                    .foregroundStyle(LinearGradient(colors: [Color(hex: "#FFB088"), Color(hex: "#FF8A80")],
                                                    startPoint: .leading, endPoint: .trailing))
                    // Clear the traffic-light cluster (⌀ ~70pt from the
                    // window edge) — this row shares their strip.
                    .padding(.leading, 62)

                Spacer(minLength: 0)

                toolbarPill("Check for Updates", icon: "arrow.triangle.2.circlepath") {
                    AppDelegate.shared?.checkForUpdates()
                }
                toolbarPill("How to Use", icon: "questionmark.circle") {
                    showTutorial = true
                }
            }

            // Centered Dashboard | Settings switcher.
            HStack(spacing: 2) {
                toolbarSegment("Dashboard", active: !showSettings) { showSettings = false }
                toolbarSegment("Settings",  active: showSettings)  { showSettings = true }
            }
            .padding(3)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(height: 38)
        .fixedSize(horizontal: false, vertical: true)
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
                if auth.semanticSearch && !filtered.isEmpty {
                    Text("Smart").font(.system(size: 9, weight: .semibold)).foregroundColor(.accent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 4))
                }
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.textDim)
                }
                .buttonStyle(.plain)
            }
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
                            CompactItemRow(item: item, isSelected: mainSelectedID == item.id)
                                .onTapGesture(count: 1) { mainSelectedID = item.id }
                                .onTapGesture(count: 2) {
                                    if let i = manager.items.firstIndex(where: { $0.id == item.id }) {
                                        manager.pasteItem(at: i)
                                    }
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
    }

    // MARK: Bottom footer bar

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button {
                NSWorkspace.shared.open(URL(string: "https://clipen.lovable.app")!)
            } label: {
                HStack(spacing: 6) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                        .resizable().frame(width: 16, height: 16).cornerRadius(4)
                    Text("Clipen").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                }
            }
            .buttonStyle(.plain)

            Text("\(manager.items.count) / \(manager.maxItems)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.textDim)

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

        // Wipe Keychain (JWT + any stored secrets)
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

    var body: some View {
        VStack(spacing: 0) {
            // Pinned preview — fixed at the top of the pane, never scrolls
            // away, on a darker backdrop so the content reads as "the
            // preview" against the rest of the panel. Properties and notes
            // scroll independently underneath.
            VStack(alignment: .leading, spacing: 14) {
                header
                pinnedContent
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 360, alignment: .top)
            .background(Color.black.opacity(0.25))
            .overlay(alignment: .bottom) { Divider().background(Color.border) }

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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName).font(.system(size: 16, weight: .semibold)).foregroundColor(.accent)
            Text(item.typeLabel).font(.system(size: 15, weight: .semibold)).foregroundColor(.textPri)
            Spacer()
            if item.isPinned {
                Image(systemName: "pin.fill").font(.system(size: 12)).foregroundColor(.accent)
            }
        }
    }

    private var iconName: String {
        switch item.content {
        case .text, .richText, .html, .rtfd: return "doc.text"
        case .image:                         return "photo"
        case .file, .files:                  return "doc"
        case .svg:                           return "square.on.circle"
        case .blob:                          return "lock.doc"
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        switch item.content {
        case .text(let s):
            SelectableTextBlock(text: s)
        case .richText(_, plain: let p), .html(_, plain: let p), .rtfd(_, plain: let p):
            if let cells = TableCellExtractor.cells(for: item) {
                MiniTablePreview(cells: cells).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                SelectableTextBlock(text: p)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
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
                    .background(Color.black.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
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

    private var propertiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPERTIES").font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
            VStack(spacing: 0) {
                propertyRow("Type", item.typeLabel)
                cardDivider()
                if let appName = item.sourceAppName {
                    propertyRow("Source", appName)
                    cardDivider()
                }
                propertyRow("Size", sizeString)
                if let dims = dimensionsString {
                    cardDivider()
                    propertyRow("Dimensions", dims)
                }
                cardDivider()
                propertyRow("Copied", item.timestamp.formatted(date: .abbreviated, time: .shortened))
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
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, design: .monospaced))
            .foregroundColor(.textPri)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.surfaceHi.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
    }
}

// MARK: - Compact list row (Raycast-style: icon + one line, nothing else)

private struct CompactItemRow: View {
    let item:       ClipboardItem
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .textPri : .textSec)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if item.isPinned {
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
