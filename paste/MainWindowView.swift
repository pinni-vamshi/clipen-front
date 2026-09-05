import SwiftUI
import AppKit
@preconcurrency import PDFKit

extension Color {
    static let bg        = Color(light: "#F5F5F7", dark: "#0F0F0F")
    static let surface   = Color(light: "#FFFFFF", dark: "#1A1A1A")
    static let surfaceHi = Color(light: "#ECECEF", dark: "#242424")
    static let border    = Color(light: "#D9D9DE", dark: "#2C2C2C")
    static let accent    = Color(hex: "#4F8EF7")
    static let accentDim = Color(hex: "#4F8EF7").opacity(0.15)
    /// Success green. Taken from the marketing site's palette rather than
    /// SwiftUI's `.green` — system green is a much colder, more saturated
    /// hue than anything else on screen, and read as borrowed from another
    /// app every time it appeared next to the blue.
    static let okGreen   = Color(hex: "#3FAE5C")
    static let okGreenDim = Color(hex: "#3FAE5C").opacity(0.12)
    static let textPri   = Color(light: "#1A1A1A", dark: "#FFFFFF")
    static let textSec   = Color(light: "#6E6E73", dark: "#888888")
    static let textDim   = Color(light: "#9A9AA0", dark: "#707070")
}

private struct WindowMinSizeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ConfigView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ConfigView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.minSize = NSSize(width: 900, height: 620)

            window?.isOpaque = false
            window?.backgroundColor = .clear
        }
    }
}

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

struct MainWindowView: View {

    @StateObject private var manager = ClipboardManager.shared
    @StateObject private var auth    = AuthManager.shared
    @StateObject private var proGate = ProGate.shared

    @State private var searchText    = ""
    @State private var debouncedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var mainSelectedID: UUID? = nil
    @State private var showTutorial          = false
    @State private var showResetConfirm      = false
    private enum MainTab { case dashboard, settings }
    @State private var mainTab: MainTab = .dashboard
    private var showSettings: Bool { mainTab == .settings }
    @AppStorage("hasSkippedAccessibility") private var hasSkippedAccessibility = false
    @AppStorage("hasSeenTutorial")         private var hasSeenTutorial         = false

    @State private var mainTagFilter: ClipboardTag? = nil

    @AppStorage("dashboardListWidth") private var listWidth: Double = 300
    @State private var liveListWidth: Double? = nil
    @State private var dragStartListWidth: Double? = nil
    @State private var dividerHovered = false
    @State private var dividerDragging = false
    private var effectiveListWidth: CGFloat { CGFloat(liveListWidth ?? listWidth) }

    private var mainFilteredItems: [ClipboardItem] {
        let base = mainTagFilter.map { tag in manager.items.filter { $0.tags.contains(tag) } } ?? manager.items
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
                .onDisappear {

                    searchText = ""
                    debouncedSearchText = ""
                }

            Group {
                if !manager.hasAccessibilityPermission && !hasSkippedAccessibility && !showSettings {
                    accessibilityOnboarding
                } else {
                    VStack(spacing: 0) {
                        Divider().background(Color.border)
                        switch mainTab {
                        case .settings:
                            settingsFullView
                        case .dashboard:
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
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
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

        .toolbarBackground(.regularMaterial, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .sheet(isPresented: $showTutorial) {
            TutorialSheet(isPresented: $showTutorial, onSeeMore: { mainTab = .settings })
        }
        // Somewhere outside this window asked to put the user in Settings —
        // pressing D with nothing able to analyse, for instance. Switch tabs
        // here and leave the route set: SettingsView clears it once it has
        // scrolled to the section.
        .onChange(of: manager.pendingSettingsRoute) { _, route in
            guard route != nil else { return }
            mainTab = .settings
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

    private var toolbarWordmark: some View {
        HStack(spacing: 0) {
            Text("CLIPEN")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundStyle(Color(hex: "#4E8DF7"))

            if proGate.paywallApplies {

                Text(".")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(Color(hex: "#4E8DF7"))
                    .baselineOffset(-2)
                    .padding(.trailing, 4)

                Text(proGate.isPro ? "PRO" : "FREE")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(proGate.isPro ? Color(hex: "#4E8DF7") : Color.textDim,
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
        .fixedSize()
    }

    private var toolbarSwitcher: some View {
        HStack(spacing: 2) {
            toolbarSegment("Dashboard", active: mainTab == .dashboard) { mainTab = .dashboard }
            toolbarSegment("Settings",  active: mainTab == .settings)  {
                mainTab = .settings

                ProGate.shared.refresh()
            }
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

    private func toolbarSegment(_ title: LocalizedStringKey, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundColor(active ? Color(hex: "#4E8DF7") : .textSec)
                .padding(.horizontal, 14).padding(.vertical, 5)
                .background(active ? Color.white.opacity(0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toolbarPill(_ title: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
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

    private var settingsFullView: some View {
        ClipenSettingsView(showResetConfirm: $showResetConfirm)
    }

    private var browsingView: some View {
        VStack(spacing: 0) {
            if !manager.hasAccessibilityPermission { cyclingUnavailableBanner }

            raycastSearchBar
            Divider().background(Color.border)

            if manager.items.isEmpty {
                if manager.hasLoadedHistoryOnce {

                    OnboardingView()
                } else {

                    historyLoadingView
                }
            } else {
                HStack(spacing: 0) {
                    listPane
                        .frame(width: effectiveListWidth)
                        .frame(maxHeight: .infinity)
                    listDetailDivider
                    detailPane
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider().background(Color.border)
            footerBar
        }
        .onAppear { if mainSelectedID == nil { mainSelectedID = filtered.first?.id } }
        .onChange(of: searchText) { oldValue, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty {
                debouncedSearchText = ""
                return
            }

            if oldValue.isEmpty {
                AuthManager.shared.registerActionUsage(actionID: "action.window-search")
            }
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
            }
        }
        .onChange(of: debouncedSearchText) { _, _ in mainSelectedID = filtered.first?.id }
        .onChange(of: mainTagFilter) { _, _ in mainSelectedID = filtered.first?.id }
    }

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

            Text("\(manager.items.count) / \(manager.maxItems)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.textDim)
                .help("Items in ring / maximum")

            filterDropdown
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

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

    private var listPane: some View {
        HistoryListPane(
            items:            manager.items,
            itemsRevision:    manager.itemsRevision,
            tagFilter:        mainTagFilter,
            searchText:       debouncedSearchText,
            pinStartPosition: manager.pinStartPosition,
            selectedID:       $mainSelectedID,
            manager:          manager,
        )
        .equatable()
        .onKeyPress(.return) {
            guard let id = mainSelectedID,
                  let i = manager.indexOfItem(id: id) else { return .ignored }
            manager.pasteItem(at: i)
            return .handled
        }
    }

    private var listDetailDivider: some View {
        let active = dividerHovered || dividerDragging
        return ZStack {
            Rectangle()
                .fill(active ? Color.accentColor.opacity(0.7) : Color.border)
                .frame(width: active ? 2 : 1)
            Capsule().fill(Color.border)
                .frame(width: 4, height: 36)
        }
        .frame(width: 9)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: active)
        .onHover { inside in
            dividerHovered = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    dividerDragging = true
                    if dragStartListWidth == nil { dragStartListWidth = listWidth }
                    let base = dragStartListWidth ?? listWidth
                    liveListWidth = min(400, max(240, base + Double(value.translation.width)))
                }
                .onEnded { _ in
                    if let w = liveListWidth { listWidth = w }
                    liveListWidth = nil
                    dragStartListWidth = nil
                    dividerDragging = false
                }
        )
    }

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footerBar: some View {
        HStack(spacing: 10) {
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
        manager.clearAll()

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: appSupport.appendingPathComponent("Clipen"))

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }

        Keychain.wipeAll()

        NSApp.terminate(nil)
    }

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

    private var historyLoadingView: some View {
        VStack(spacing: 10) {
            ProgressView().scaleEffect(0.8)
            Text("Loading your clipboard history…")
                .font(.system(size: 13, weight: .medium)).foregroundColor(.textPri)
            Text("A large or older history can take a little while the first time.")
                .font(.system(size: 11)).foregroundColor(.textDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private var detailPane: some View {
        if let id = mainSelectedID, let item = manager.item(id: id) {
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

private struct ItemDetailView: View {
    let item: ClipboardItem

    @ObservedObject private var aiService = AIStructuringService.shared
    @ObservedObject private var localLLM = LocalLLMManager.shared
    @State private var noteText: String
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

    @AppStorage("detailPreviewHeight") private var previewHeight: Double = 290
    @State private var dragStartHeight: Double? = nil
    @State private var liveDragHeight: Double? = nil
    @State private var previewDividerHovered = false
    @State private var previewDividerDragging = false
    private var effectiveHeight: Double { liveDragHeight ?? previewHeight }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                pinnedContent
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: CGFloat(effectiveHeight), alignment: .top)
            .background(Color.black.opacity(0.25))
            .clipped()

            ZStack {
                Rectangle()
                    .fill((previewDividerHovered || previewDividerDragging)
                          ? Color.accentColor.opacity(0.7) : Color.border)
                    .frame(height: (previewDividerHovered || previewDividerDragging) ? 2 : 1)
                Capsule().fill(Color.border)
                    .frame(width: 36, height: 4)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 11)
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: previewDividerHovered || previewDividerDragging)
            .onHover { inside in
                previewDividerHovered = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        previewDividerDragging = true
                        if dragStartHeight == nil { dragStartHeight = previewHeight }
                        let base = dragStartHeight ?? previewHeight
                        liveDragHeight = min(560, max(140, base + Double(value.translation.height)))
                    }
                    .onEnded { _ in
                        if let final = liveDragHeight { previewHeight = final }
                        liveDragHeight = nil
                        dragStartHeight = nil
                        previewDividerDragging = false
                    }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    appsFlowCard
                    propertiesCard
                    aiAnalysisCard
                    notesBlock
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private var pinnedContent: some View {
        switch item.content {
        case .text, .image, .file, .richText, .html, .rtfd:

            contentBlock
        default:
            ScrollView { contentBlock }
        }
    }

    @ViewBuilder
    private var contentBlock: some View {
        switch item.content {
        case .text:

            ContentPreviewView(item: item, chrome: .panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .richText, .html, .rtfd:

            ContentPreviewView(item: item, chrome: .panel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let img, let data, let dataType):
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
        case .file(let url):
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
        case .group(let items):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { child in
                        GroupChildPreviewCard(child: child)
                    }
                }
                .padding(12)
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
        case .group(let items):
            bytes = items.reduce(0) { acc, child in
                switch child.content {
                case .image(_, let d, _): return acc + d.count
                case .text(let s), .svg(let s): return acc + s.utf8.count
                default: return acc
                }
            }
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var dimensionsString: String? {
        if case .image(let img, _, _) = item.content {
            return "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }
        return nil
    }

    private var pastedToNames: [String] {
        var names = Array(Set(item.pastedToAppNames.values)).sorted()
        if names.isEmpty, let last = item.pastedToAppName { names = [last] }
        return names
    }

    @ViewBuilder
    private var appsFlowCard: some View {
        let source = item.sourceAppName
        let destinations = pastedToNames
        if source != nil || !destinations.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let source = source {
                        appChip(source)
                    }
                    if source != nil && !destinations.isEmpty {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.textDim.opacity(0.6))
                    }
                    ForEach(destinations, id: \.self) { name in
                        appChip(name)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
        }
    }

    private func appChip(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.textPri)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
    }

    private var propertiesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROPERTIES").font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
            VStack(spacing: 0) {
                propertyRow("Type", item.typeLabel)
                cardDivider()
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
                    propertyRow("Tags", item.tags.map(\.label).joined(separator: ", "))
                }
                if !item.collections.isEmpty {
                    cardDivider()
                    propertyRow("Collections", item.collections.sorted().joined(separator: ", "))
                }
                if ClipboardManager.shared.aiStructuringEnabled {
                    cardDivider()
                    propertyRow("AI Decision", aiDecisionLabel)
                }
            }
            .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
        }
    }

    private var aiDecisionLabel: String {
        let breakdown = ImportanceScoringService.shared.evaluate(item)
        if breakdown.isIndeterminate { return "Pending" }
        let scoreStr = String(format: "%.2f", breakdown.finalScore)
        return breakdown.decision ? "Yes \u{00B7} \(scoreStr)" : "No \u{00B7} \(scoreStr)"
    }

    /// Which engine is about to run (or already ran), always visible above
    /// the analysis state — so "why is this stuck / not doing anything"
    /// has an answer right here instead of requiring a trip to Settings to
    /// discover the selected model is mid-download, or never finished one.
    @ViewBuilder
    private var modelStatusLine: some View {
        switch localLLM.selectedEngine {
        case .apple:
            Text("Model: Apple Intelligence")
                .font(.system(size: 10)).foregroundColor(.textDim)

        case .local(let tier):
            if localLLM.downloadingTiers.contains(tier) {
                let pct = Int((localLLM.downloadProgress[tier] ?? 0) * 100)
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Downloading \(tier.displayName)\u{2026} \(pct)% \u{2014} please wait")
                        .font(.system(size: 10)).foregroundColor(.textDim)
                }
            } else if localLLM.downloadedTiers.contains(tier) {
                Text("Model: \(tier.displayName)")
                    .font(.system(size: 10)).foregroundColor(.textDim)
            } else {
                // Reachable right after a crash/force-quit mid-download,
                // before LocalLLMManager's own launch-time auto-resume (see
                // its init) has had a chance to pick it back up — or if
                // that resume itself can't proceed (e.g. no network right
                // now). Either way, analysis cannot run yet, so say so
                // here rather than let a stalled "Analyzing…" imply it's
                // just slow.
                Text("\(tier.displayName) hasn't downloaded yet \u{2014} start it in Settings \u{2192} AI Structuring.")
                    .font(.system(size: 10)).foregroundColor(.orange)
            }
        }
    }

    @ViewBuilder
    private var aiAnalysisCard: some View {
        let state = aiService.state(for: item.id)
        if state != .idle {
            VStack(alignment: .leading, spacing: 8) {
                Text("AI ANALYSIS").font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
                modelStatusLine
                Group {
                    switch state {
                    case .idle:
                        EmptyView()
                    case .running:
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Analyzing\u{2026} (attempt \(aiService.attempt(for: item.id)) of \(AIStructuringService.maxAttempts))")
                                    .font(.system(size: 12)).foregroundColor(.textDim)
                            }
                            // Earlier attempts that were rejected, with the
                            // reason each one failed — otherwise a retry
                            // looks identical to a slow first try.
                            ForEach(aiService.failures(for: item.id), id: \.self) { line in
                                Text("\u{2717} \(line)")
                                    .font(.system(size: 11)).foregroundColor(.orange)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .done(let json):
                        VStack(alignment: .leading, spacing: 6) {
                            let priorFailures = aiService.failures(for: item.id)
                            if !priorFailures.isEmpty {
                                Text("Succeeded on attempt \(aiService.attempt(for: item.id)) after \(priorFailures.count) failed \(priorFailures.count == 1 ? "try" : "tries")")
                                    .font(.system(size: 11)).foregroundColor(.orange)
                                    .padding(.horizontal, 12).padding(.top, 8)
                            }
                            JSONTreeView(json: json)
                            rawOutputDisclosure(for: item.id, label: "Raw model output")
                                .padding(.horizontal, 12).padding(.bottom, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    case .failed(let reason):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                            ForEach(aiService.failures(for: item.id), id: \.self) { line in
                                Text("\u{2717} \(line)")
                                    .font(.system(size: 11)).foregroundColor(.textDim)
                            }
                            // The whole point: on a failure, seeing what the
                            // model actually said is what separates "the
                            // model gave nothing" from "the model answered
                            // fine and the format was rejected".
                            rawOutputDisclosure(for: item.id,
                                                label: "Raw model output (what the AI actually returned)",
                                                expandedByDefault: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                    }
                }
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
            }
        }
    }

    /// Shows the model's unmodified answer beside the parsed result, with a
    /// one-line verdict on whether it was valid JSON. Collapsed on success
    /// (the tree is what you want there), open by default on failure (the
    /// raw text is the only thing that explains the failure).
    @ViewBuilder
    private func rawOutputDisclosure(for id: UUID,
                                     label: String,
                                     expandedByDefault: Bool = false) -> some View {
        if let raw = aiService.rawOutput(for: id), !raw.isEmpty {
            RawModelOutputView(raw: raw, label: label, expandedByDefault: expandedByDefault)
        }
    }

    private func relatedItemLabel(for entityID: String) -> String {
        guard let id = UUID(uuidString: entityID),
              let related = ClipboardManager.shared.item(id: id) else { return "Item no longer in history" }
        if let text = related.content.plainText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        }
        return related.typeLabel
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

private struct GroupChildPreviewCard: View {
    let child: ClipboardItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.3)
            content
                .padding(10)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: child.iconName)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.indigo)
            Text(child.typeLabel)
                .font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        switch child.content {
        case .text, .richText, .html, .rtfd:
            ContentPreviewView(item: child, chrome: .panel)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipped()

        case .image(let img, let data, _):
            let thumb = ItemThumbnailCache.shared.thumbnail(forData: data, key: child.id.uuidString) ?? img
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

        case .file(let url):
            HStack(spacing: 10) {
                Image(nsImage: ClipenIconCache.shared.fileIcon(for: url)).resizable().frame(width: 22, height: 22)
                Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(.textPri).lineLimit(1)
                Spacer(minLength: 0)
            }

        case .files(let urls):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(urls, id: \.self) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: ClipenIconCache.shared.fileIcon(for: url)).resizable().frame(width: 18, height: 18)
                        Text(url.lastPathComponent).font(.system(size: 12)).foregroundColor(.textPri).lineLimit(1)
                    }
                }
            }

        case .svg(let src):
            SelectableTextBlock(text: src)
                .frame(maxHeight: 160)

        case .blob(let typeMap):
            VStack(alignment: .leading, spacing: 4) {
                Text("Private clipboard data").font(.system(size: 12, weight: .medium)).foregroundColor(.textPri)
                ForEach(typeMap.keys.sorted(), id: \.self) { key in
                    Text(key).font(.system(size: 10, design: .monospaced)).foregroundColor(.textDim)
                }
            }

        case .group:

            Text(child.previewText).font(.system(size: 12)).foregroundColor(.textPri).lineLimit(2)
        }
    }
}

private struct SelectableTextBlock: View {
    let text: String
    private var capped: (text: String, isTruncated: Bool) { text.displayCapped() }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if capped.isTruncated {
                Text("Showing the first part of a large paste")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.textDim)
            }
            Text(capped.text)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.textPri)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct HistoryListPane: View, Equatable {
    let items:            [ClipboardItem]
    let itemsRevision:    Int
    let tagFilter:        ClipboardTag?
    let searchText:       String
    let pinStartPosition: Int
    @Binding var selectedID: UUID?
    let manager:          ClipboardManager

    static func == (l: HistoryListPane, r: HistoryListPane) -> Bool {
        l.itemsRevision    == r.itemsRevision &&
        l.tagFilter        == r.tagFilter &&
        l.searchText       == r.searchText &&
        l.pinStartPosition == r.pinStartPosition &&
        l.selectedID       == r.selectedID
    }

    private var filtered: [ClipboardItem] {
        let base = tagFilter.map { tag in items.filter { $0.tags.contains(tag) } } ?? items
        let pinOrdered = manager.applyPinOrdering(base)
        guard !searchText.isEmpty else { return pinOrdered }
        let hits = manager.hybridSearch(query: searchText)
        if hits.isEmpty { return [] }
        let visible = Set(pinOrdered.map(\.id))
        return hits.filter { visible.contains($0.id) }
    }

    var body: some View {
        let rows = filtered
        return Group {
            if rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .thin)).foregroundColor(.textDim)
                    Text("No matches").font(.system(size: 13, weight: .medium)).foregroundColor(.textSec)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(rows) { item in
                            CompactItemRow(item: item, isSelected: selectedID == item.id,
                                          onDelete: {
                                              if let i = manager.indexOfItem(id: item.id) {
                                                  manager.removeItem(at: i)
                                              }
                                          },
                                          onTogglePin: { manager.togglePin(id: item.id) },
                                          onRefreshJSON: { AIStructuringService.shared.refresh(item: item) })
                                .equatable()
                                .onTapGesture(count: 1) { selectedID = item.id }
                                .onTapGesture(count: 2) {
                                    selectedID = item.id
                                    QuickLookController.shared.toggle(for: item)
                                }
                                .contextMenu {
                                    Button("Paste") {
                                        if let i = manager.indexOfItem(id: item.id) {
                                            manager.pasteItem(at: i)
                                        }
                                    }
                                    Divider()
                                    Button(item.isPinned ? "Unpin" : "Pin") { manager.togglePin(id: item.id) }
                                    Button("Remove", role: .destructive) {
                                        if let i = manager.indexOfItem(id: item.id) {
                                            manager.removeItem(at: i)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(8)
                }
                .scrollIndicators(.hidden)
            }
        }
    }
}

private struct CompactItemRow: View, Equatable {
    let item:       ClipboardItem
    let isSelected: Bool
    var onDelete: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRefreshJSON: () -> Void = {}

    @State private var isHovered = false
    @State private var borderPulse: Double = 0.15
    @ObservedObject private var aiService = AIStructuringService.shared

    private static let iconZoneWidth: CGFloat = 20 + 4 + 20 + 4 + 20 + 12

    private var isProcessing: Bool {
        aiService.state(for: item.id) == .running
    }

    static func == (l: CompactItemRow, r: CompactItemRow) -> Bool {
        l.item.id == r.item.id &&
        l.isSelected == r.isSelected &&
        l.item.isPinned == r.item.isPinned &&
        l.item.urlTitle == r.item.urlTitle &&
        l.item.metadataSummary == r.item.metadataSummary
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 10) {
                leadingIcon
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .textPri : .textSec)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: (isHovered || item.isPinned)
                           ? max(20, geo.size.width - Self.iconZoneWidth - 10 - 10 - 18 - 12)
                           : .infinity,
                           alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 8)
            .background(
                isSelected ? Color.white.opacity(0.10)
                           : (isHovered ? Color.white.opacity(0.05) : Color.clear),
                in: RoundedRectangle(cornerRadius: 8)
            )

            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.purple, lineWidth: 1.5)
                    .opacity(isProcessing ? borderPulse : 0)
            )
            .onChange(of: isProcessing) { _, running in
                startOrStopAnalysisPulse($borderPulse, active: running,
                                         restValue: 0.15, activeValue: 0.85,
                                         activeDuration: 0.9, restDuration: 0.25)
            }
            .overlay(alignment: .trailing) {
                ZStack(alignment: .trailing) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.green, in: Circle())
                            .opacity(isHovered ? 0 : 1)
                    }
                    HStack(spacing: 4) {
                        rowActionButton(icon: "xmark", background: .red, action: onDelete)
                            .help("Delete")
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(isHovered)
                        rowActionButton(icon: item.isPinned ? "pin.slash.fill" : "pin.fill",
                                        background: .green, action: onTogglePin)
                            .help(item.isPinned ? "Unpin" : "Pin to top")
                            .opacity(isHovered ? 1 : 0)
                            .allowsHitTesting(isHovered)

                        aiRefreshButton
                            .opacity(isHovered && !isProcessing ? 1 : 0)
                            .allowsHitTesting(isHovered && !isProcessing)
                    }
                }
                .padding(.trailing, 12)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .onDrag { item.makeItemProvider() }
        }
        .frame(height: 34)
    }

    private func rowActionButton(icon: String, background: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var aiRefreshButton: some View {
        Button {
            guard !isProcessing else { return }
            onRefreshJSON()
        } label: {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Color.blue, in: Circle())
                .rotationEffect(.degrees(isProcessing ? 360 : 0))
                .animation(isProcessing
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                           : .default,
                           value: isProcessing)
        }
        .buttonStyle(.plain)
        .help(isProcessing ? "Analyzing\u{2026}" : "Analyze this item with AI")
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch item.content {
        case .image(_, let rawData, _):
            CachedDataThumbnail(data: rawData, key: item.id.uuidString, size: 18)
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
        case .group:                  return "square.stack.3d.up.fill"
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
        case .group(let items):
            return "Group · \(items.count) items"
        }
    }

    private func firstLine(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.components(separatedBy: .newlines).first ?? trimmed
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW && x > 0 {
                y += rowH + spacing
                x = 0
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

/// The model's unmodified answer, shown beside the parsed result.
///
/// Exists because "the AI returned nothing useful" and "the AI returned the
/// right data in the wrong shape" are indistinguishable once validation has
/// rejected a result — and they need opposite fixes (better prompt vs.
/// better parsing). The verdict line says which one you are looking at.
private struct RawModelOutputView: View {
    let raw: String
    let label: String
    let expandedByDefault: Bool

    @State private var isExpanded: Bool

    init(raw: String, label: String, expandedByDefault: Bool) {
        self.raw = raw
        self.label = label
        self.expandedByDefault = expandedByDefault
        _isExpanded = State(initialValue: expandedByDefault)
    }

    private var trimmed: String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the raw text is valid JSON on its own, judged the same way
    /// the validator judges it (fences stripped first).
    private var parsesAsJSON: Bool {
        let stripped = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stripped.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(parsesAsJSON ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(parsesAsJSON
                         ? "Valid JSON \u{2014} the model's format was fine"
                         : "Not valid JSON on its own \u{2014} a formatting problem, not an empty answer")
                        .font(.system(size: 10))
                        .foregroundColor(.textDim)
                }
                ScrollView {
                    Text(trimmed)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                HStack(spacing: 8) {
                    Text("\(trimmed.count) characters")
                    Button("Copy") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(trimmed, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accent)
                }
                .font(.system(size: 9))
                .foregroundColor(.textDim)
            }
            .padding(.top, 4)
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.textDim)
        }
    }
}
