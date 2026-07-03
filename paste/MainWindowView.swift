import SwiftUI
import AppKit

// MARK: - Design tokens

private extension Color {
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

// MARK: - Main window

struct MainWindowView: View {

    @StateObject private var manager = ClipboardManager.shared
    @StateObject private var auth    = AuthManager.shared

    @State private var searchText    = ""
    @State private var hoveredID: UUID?      = nil
    @State private var mainSelectedID: UUID? = nil
    @State private var showTutorial          = false
    @State private var showResetConfirm      = false
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
        guard !searchText.isEmpty else { return mainFilteredItems }
        let hits = manager.hybridSearch(query: searchText)
        if hits.isEmpty { return [] }
        let visible = Set(mainFilteredItems.map(\.id))
        return hits.filter { visible.contains($0.id) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                mainArea.frame(minWidth: 400)
            }
            .frame(minWidth: 660, minHeight: 560)

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
        .background(Color.bg)
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
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showTutorial = true } label: {
                    HStack(spacing: 4) {
                        Text("How to use").font(.system(size: 12, weight: .medium))
                        Image(systemName: "questionmark.circle").font(.system(size: 12, weight: .medium))
                    }
                }
                .help("How to use")
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Header
            HStack(alignment: .center, spacing: 0) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://clipen.lovable.app")!)
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                            .resizable().frame(width: 28, height: 28).cornerRadius(6)
                        Text("Clipen").font(.system(size: 15, weight: .bold)).foregroundColor(.textPri)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(manager.items.count)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.accent)
                        Text("/ \(manager.maxItems)")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(.textDim)
                    }
                    Text("items").font(.system(size: 9)).foregroundColor(.textDim)
                }
                .padding(.leading, 10)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)

            Divider().background(Color.border)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    preferencesSection
                    Divider().background(Color.border)
                    aboutSection
                }
            }

            Divider().background(Color.border)

            // Footer
            HStack(spacing: 14) {
                if !manager.items.isEmpty {
                    Button { manager.clearAll() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash").font(.system(size: 10))
                            Text("Clear all").font(.system(size: 11))
                        }
                        .foregroundColor(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(.textDim)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .background(Color.surface)
    }

    // MARK: Preferences section

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PREFERENCES").padding(.bottom, 10)

            settingsCard {
                cardRow(icon: "square.stack", label: "Ring size") {
                    Stepper(value: Binding(get: { manager.maxItems },
                                          set: { manager.setRingSize($0) }),
                            in: 5...200, step: 5) {
                        Text("\(manager.maxItems)")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(.accent).frame(minWidth: 22, alignment: .trailing)
                    }
                    .fixedSize()
                }
                cardDivider()
                cardRow(icon: "power", label: "Launch at Login") {
                    Toggle("", isOn: Binding(get: { manager.launchAtLogin },
                                            set: { manager.launchAtLogin = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                cardDivider()
                cardRow(icon: "arrow.triangle.2.circlepath", label: "Auto updates") {
                    Toggle("", isOn: Binding(
                        get: { AppDelegate.shared?.automaticallyChecksForUpdates ?? true },
                        set: { value in
                            AppDelegate.shared?.automaticallyChecksForUpdates = value
                            if !value { AppDelegate.shared?.automaticallyDownloadsUpdates = false }
                        }
                    ))
                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                cardDivider()
                sliderCardRow(
                    icon: "hourglass",
                    label: "Open delay slider",
                    value: manager.firstOpenDelay == 0
                        ? "Off"
                        : String(format: "%.0f ms", manager.firstOpenDelay * 1000),
                    active: manager.firstOpenDelay != 0,
                    caption: manager.highlightOpenDelaySlider
                        ? "← Drag to adjust. Lower = popup opens sooner; higher = more time before popup appears."
                        : "Release ⌘ within this window to paste the front item without opening the popup."
                ) {
                    Slider(value: Binding(get: { manager.firstOpenDelay * 1000 },
                                         set: { manager.firstOpenDelay = ($0 / 5).rounded() * 5 / 1000 }),
                           in: 0...1000)
                        .tint(.accent)
                }
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accent, lineWidth: manager.highlightOpenDelaySlider ? 2 : 0)
                        .shadow(color: .accent.opacity(manager.highlightOpenDelaySlider ? 0.6 : 0),
                                radius: manager.highlightOpenDelaySlider ? 8 : 0)
                        .animation(manager.highlightOpenDelaySlider
                                   ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                   : .default,
                                   value: manager.highlightOpenDelaySlider)
                )
                cardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    cardRow(icon: "eye", label: "Always show preview") {
                        Toggle("", isOn: $manager.alwaysShowItemPreview)
                            .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                    }
                    Text(manager.alwaysShowItemPreview
                         ? "Preview follows the highlighted item while cycling."
                         : "Press Space while cycling to open preview.")
                        .font(.system(size: 10)).foregroundColor(.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 6)
                }
                cardDivider()
                VStack(alignment: .leading, spacing: 8) {
                    cardRow(icon: "text.cursor", label: "Popup only when writing") {
                        Toggle("", isOn: Binding(
                            get: { !manager.showPopupOutsideTextInputs },
                            set: { manager.showPopupOutsideTextInputs = !$0 }
                        ))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                    }
                    Text("On: show popup only in text fields. Off: show popup anywhere on ⌘V.")
                        .font(.system(size: 10)).foregroundColor(.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
    }

    // MARK: About section

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ABOUT").padding(.bottom, 10)

            settingsCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clipen").font(.system(size: 13, weight: .semibold)).foregroundColor(.textPri)
                    Text(Self.appVersionString).font(.system(size: 10, design: .monospaced)).foregroundColor(.textDim)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                cardDivider()

                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 24)).foregroundColor(.accent)
                    Text("Built by Vamshi Krishna Pinni").font(.system(size: 12)).foregroundColor(.textSec)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                cardDivider()

                HStack(spacing: 12) {
                    linkButton("Website",      "https://clipen.lovable.app")
                    linkButton("Privacy",      "https://clipen.lovable.app/privacy.html")
                    linkButton("Support",      "https://clipen.lovable.app/support.html")
                    Button("Check updates") { AppDelegate.shared?.checkForUpdates() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accent.opacity(0.35), lineWidth: 1))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)

                cardDivider()

                HStack {
                    Spacer()
                    Button("Reset to Factory Defaults…") { showResetConfirm = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#FF5555"))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color(hex: "#FF5555").opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: "#FF5555").opacity(0.3), lineWidth: 1))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
    }

    private func performFactoryReset() {
        // Wipe clipboard history
        manager.clearAll()

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

    private func linkButton(_ title: String, _ urlString: String) -> some View {
        Button(title) { NSWorkspace.shared.open(URL(string: urlString)!) }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: - Sidebar helpers

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9, weight: .semibold)).foregroundColor(.textDim).tracking(1.8)
    }

    private func settingsCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.border, lineWidth: 1))
    }

    private func cardRow<C: View>(icon: String, label: String, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text(label).font(.system(size: 12)).foregroundColor(.textSec)
            Spacer()
            control()
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    private func sliderCardRow<S: View>(icon: String, label: String, value: String,
                                        active: Bool, caption: String,
                                        @ViewBuilder slider: () -> S) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardRow(icon: icon, label: label) {
                Text(value).font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(active ? .accent : .textDim).frame(minWidth: 48, alignment: .trailing)
            }
            slider().padding(.horizontal, 12)
            Text(caption).font(.system(size: 10)).foregroundColor(.textDim)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 10)
        }
    }

    private func cardDivider() -> some View {
        Divider().background(Color.border).padding(.leading, 36)
    }

    // MARK: - Main area

    @ViewBuilder
    private var mainArea: some View {
        Group {
            if !manager.hasAccessibilityPermission && !hasSkippedAccessibility {
                accessibilityOnboarding
            } else {
                VStack(spacing: 0) {
                    if !manager.hasAccessibilityPermission { cyclingUnavailableBanner }
                    clipboardArea
                }
                .onAppear {
                    guard !hasSeenTutorial else { return }
                    hasSeenTutorial = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { showTutorial = true }
                }
            }
        }
        .onChange(of: manager.hasAccessibilityPermission) { _, granted in
            if granted && !hasSeenTutorial {
                hasSeenTutorial = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showTutorial = true }
            }
        }
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

    // MARK: - Clipboard area

    private var clipboardArea: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().background(Color.border)
            if !manager.items.isEmpty {
                typeFilterStrip
                Divider().background(Color.border)
            }
            if filtered.isEmpty { emptyState } else { itemList }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.textDim).font(.system(size: 13))
            TextField("Search clipboard…", text: $searchText)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(.textPri)
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
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Color.surfaceHi)
    }

    // MARK: Type filter strip (local state — never touches popup)

    private var typeFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterPill(label: "All", icon: "square.grid.2x2",
                           count: manager.items.count, selected: mainTagFilter == nil) {
                    mainTagFilter = nil
                }
                ForEach(manager.availableTags, id: \.self) { tag in
                    filterPill(label: tag.label, icon: tag.icon,
                               count: manager.itemCount(for: tag), selected: mainTagFilter == tag) {
                        mainTagFilter = tag
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color.surface)
    }

    private func filterPill(label: String, icon: String, count: Int,
                             selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(label).font(.system(size: 11, weight: .semibold))
                Text("\(count)").font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(selected ? .white.opacity(0.75) : .textDim)
            }
            .foregroundColor(selected ? .white : .textSec)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? Color.accent : Color.surfaceHi, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accent : Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty state / list

    private var emptyState: some View {
        Group {
            if searchText.isEmpty {
                OnboardingView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .thin)).foregroundColor(.textDim)
                    Text("No matches").font(.system(size: 16, weight: .medium)).foregroundColor(.textSec)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    DarkItemRow(
                        item: item, index: index,
                        isSelected: mainSelectedID == item.id,
                        isHovered: hoveredID == item.id,
                        onDelete: {
                            if let i = manager.items.firstIndex(where: { $0.id == item.id }) {
                                manager.removeItem(at: i)
                            }
                        }
                    )
                    .onHover { hoveredID = $0 ? item.id : nil }
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

                    if index < filtered.count - 1 {
                        Divider().background(Color.border).padding(.leading, 52)
                    }
                }
            }
        }
        .background(Color.bg)
    }
}

// MARK: - Item row

struct DarkItemRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool
    let isHovered:  Bool
    let onDelete:   () -> Void

    private var manager: ClipboardManager { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowHeader
            contentPreview.padding(.leading, 36)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(isHovered ? Color(hex: "#1E1E1E") : (isSelected ? Color.accentDim : Color.clear))
        .contentShape(Rectangle())
        .onDrag { item.makeItemProvider() }
    }

    private var rowHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color(hex: "#4F8EF7") : Color(hex: "#2A2A2A"))
                    .frame(width: 26, height: 22)
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? .white : Color(hex: "#555555"))
            }

            ItemTagStrip(tags: item.tags, maxVisible: 4, compact: false)

            if let badge = item.diffBadge {
                Text("∆ \(badge)").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.orange).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            }

            if let appName = item.sourceAppName {
                AppBadge(name: appName, bundleID: item.sourceBundleID, arrow: nil)
            }

            let sortedDests = item.pastedToAppNames
                .sorted { (item.pasteCountByApp[$0.key] ?? 0) > (item.pasteCountByApp[$1.key] ?? 0) }
            ForEach(sortedDests, id: \.key) { bid, name in
                AppBadge(name: name, bundleID: bid, arrow: "→")
            }

            Spacer()

            Text(relativeTime(item.timestamp)).font(.system(size: 10)).foregroundColor(Color(hex: "#444444"))

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#4F8EF7"))
            }

            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(Color(hex: "#3A3A3A"))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.content {
        case .text(let str):
            HStack(alignment: .top, spacing: 8) {
                if manager.showColorSwatches, let c = item.detectedColor {
                    Circle().fill(Color(nsColor: c)).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1)).padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    if let title = item.urlTitle {
                        Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
                        Text(str).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            .foregroundColor(Color(hex: "#666666"))
                    } else {
                        Text(str).font(.system(size: 13, design: .monospaced)).lineLimit(2)
                            .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
                    }
                }
            }
        case .richText(_, plain: let plain):
            Text(plain).font(.system(size: 13)).lineLimit(2)
                .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
        case .html(_, plain: let plain):
            Text(plain).font(.system(size: 13)).lineLimit(2)
                .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
        case .rtfd(_, plain: let plain):
            Text(plain).font(.system(size: 13)).lineLimit(2)
                .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
        case .file(let url):
            HStack(spacing: 8) {
                fileThumbnail(url, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
                    Text(item.metadataSummary ?? url.deletingLastPathComponent().path)
                        .font(.system(size: 10)).lineLimit(1).foregroundColor(Color(hex: "#555555"))
                }
            }
        case .files(let urls):
            HStack(spacing: 8) {
                if let first = urls.first(where: FileKindDetector.isImageFile) {
                    fileThumbnail(first, size: 32)
                } else {
                    Image(systemName: "doc.on.doc").frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(urls.count) files").font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
                    Text(item.metadataSummary ?? urls.map(\.lastPathComponent).joined(separator: ", "))
                        .font(.system(size: 10)).lineLimit(1).foregroundColor(Color(hex: "#555555"))
                }
            }
        case .image(let img, _, _):
            VStack(alignment: .leading, spacing: 3) {
                Image(nsImage: img).resizable().scaledToFit().frame(height: 36).cornerRadius(4)
                if let summary = item.metadataSummary {
                    Text(summary).font(.system(size: 10)).lineLimit(1).foregroundColor(Color(hex: "#555555"))
                }
            }
        case .svg(let src):
            Text(src).font(.system(size: 12, design: .monospaced)).lineLimit(2)
                .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
        case .blob(let typeMap):
            VStack(alignment: .leading, spacing: 2) {
                Text("Private clipboard data")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : Color(hex: "#CCCCCC"))
                Text(typeMap.keys.sorted().joined(separator: "  ·  "))
                    .font(.system(size: 10, design: .monospaced)).lineLimit(1)
                    .foregroundColor(Color(hex: "#555555"))
            }
        }
    }

    @ViewBuilder
    private func fileThumbnail(_ url: URL, size: CGFloat) -> some View {
        if FileKindDetector.isImageFile(url) {
            MainWindowAsyncThumbnail(url: url, size: size)
        } else {
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url)).resizable().frame(width: 18, height: 18)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 5    { return "just now" }
        if s < 60   { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }
}

// MARK: - App source / destination badge

/// Loads a local image file asynchronously so large images (RAW, TIFF, etc.)
/// don't block the main-thread scroll view in the main window.
private struct MainWindowAsyncThumbnail: View {
    let url:  URL
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
            image = loaded
        }
    }
}

private struct AppBadge: View {
    let name:     String
    let bundleID: String?
    let arrow:    String?

    private var appIcon: NSImage? {
        guard let bid = bundleID else { return nil }
        return ClipenIconCache.shared.appIcon(forBundleID: bid)
    }

    var body: some View {
        HStack(spacing: 3) {
            if let arrow { Text(arrow).font(.system(size: 8, weight: .medium)).foregroundColor(Color(hex: "#666666")) }
            if let icon = appIcon {
                Image(nsImage: icon).resizable().frame(width: 11, height: 11).cornerRadius(2)
            } else {
                Image(systemName: "app.fill").font(.system(size: 8)).foregroundColor(Color(hex: "#555555"))
            }
            Text(name).font(.system(size: 9, weight: .medium)).foregroundColor(Color(hex: "#666666")).lineLimit(1)
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Color(hex: "#232323"), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Onboarding (animated empty state)

struct OnboardingView: View {
    @State private var step      = 0
    @State private var fade      = true
    @State private var bounce    = false
    @State private var cycleTimer: Timer? = nil

    private let steps: [(icon: String, key: String, title: String, sub: String)] = [
        ("doc.on.clipboard.fill", "⌘C",        "Copy anything",        "Copy text, images, files or URLs anywhere on your Mac"),
        ("arrow.clockwise",       "Hold ⌘ · V", "Cycle your ring",      "Tap V for the next item · ⌘⌥V jumps 5 forward while ⌘ is held"),
        ("arrow.down.doc.fill",   "Release ⌘",  "Paste your pick",      "Let go of ⌘ to paste whichever item is highlighted"),
        ("wand.and.stars",        "V → X",      "Pick, then transform", "Hold ⌘, tap V to land on an item, then tap X — tap X again to cycle transforms"),
        ("trash",                 "V → ⌫",      "Pick, then delete",    "Hold ⌘, tap V to highlight what to remove, then tap ⌫ to drop it from the ring"),
        ("pin.fill",              "Pin",        "Pin your favourites",  "Right-click any item to pin it so it never falls off the ring"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle().fill(Color.accentDim).frame(width: 84, height: 84)
                Image(systemName: steps[step].icon).font(.system(size: 34, weight: .thin))
                    .foregroundColor(.accent)
                    .scaleEffect(bounce ? 1.12 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: bounce)
            }
            .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)
            .padding(.bottom, 24)

            Text(steps[step].key).font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.accent).padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accent.opacity(0.3), lineWidth: 1))
                .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                Text(steps[step].title).font(.system(size: 17, weight: .semibold)).foregroundColor(.textPri)
                Text(steps[step].sub).font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).frame(maxWidth: 280)
            }
            .opacity(fade ? 1 : 0).animation(.easeInOut(duration: 0.25), value: fade)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i == step ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startCycle() }
        .onDisappear {
            cycleTimer?.invalidate()
            cycleTimer = nil
        }
    }

    private func startCycle() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { _ in
            withAnimation { fade = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                step = (step + 1) % steps.count
                withAnimation { fade = true }
                bounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bounce = false }
                }
            }
            if let t = cycleTimer { RunLoop.main.add(t, forMode: .common) }
        }
    }

// MARK: - Tutorial sheet

struct TutorialSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var manager = ClipboardManager.shared

    @State private var page: Int = 0
    @State private var baselineIDs: Set<UUID> = []
    @State private var tick: Int = 0
    @State private var tickTimer: Timer? = nil
    @State private var practiceText: String = ""

    private static let totalPages = 4

    private static let copyTargets: [String] = [
        "Hello from Clipen",
        "https://clipen.app",
        "Made with care on macOS",
    ]

    private var newCopiedTexts: Set<String> {
        let newItems = manager.items.filter { !baselineIDs.contains($0.id) }
        return Set(newItems.compactMap { item -> String? in
            switch item.content {
            case .text(let s):               return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .richText(_, plain: let p): return p.trimmingCharacters(in: .whitespacesAndNewlines)
            case .html(_, plain: let p):     return p.trimmingCharacters(in: .whitespacesAndNewlines)
            case .rtfd(_, plain: let p):     return p.trimmingCharacters(in: .whitespacesAndNewlines)
            default:                         return nil
            }
        })
    }

    private func isCopied(_ t: String) -> Bool { newCopiedTexts.contains(t.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var copiedCount: Int { Self.copyTargets.filter(isCopied).count }
    private var canAdvance: Bool { copiedCount == Self.copyTargets.count }

    var body: some View {
        VStack(spacing: 0) {
            tutorialHeader
            Divider().background(Color.border)
            Group {
                switch page {
                case 0:  copyGatePage
                case 1:  cyclePage
                case 2:  transformPage
                default: deletePage
                }
            }
            .frame(minHeight: 420)
            Divider().background(Color.border)
            tutorialFooter
        }
        .frame(width: 500).background(Color.surface).preferredColorScheme(.dark)
        .onAppear { baselineIDs = Set(manager.items.map(\.id)); startTick() }
        .onDisappear { stopTick() }
    }

    private var tutorialHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill").foregroundColor(.accent)
            Text("How Clipen works").font(.system(size: 16, weight: .bold)).foregroundColor(.textPri)
            Spacer()
            Text("Step \(page + 1) of \(Self.totalPages)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.textDim)
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundColor(.textSec)
            }
            .buttonStyle(.plain).keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    private var tutorialFooter: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<Self.totalPages, id: \.self) { i in
                    Circle().fill(i == page ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == page ? 8 : 6, height: i == page ? 8 : 6)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            Spacer()
            if page > 0 {
                Button { withAnimation { page -= 1 } } label: {
                    Text("Back").font(.system(size: 12, weight: .medium)).foregroundColor(.textSec)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
            let isLast = page == Self.totalPages - 1
            let enabled = page == 0 ? canAdvance : true
            Button {
                if isLast { isPresented = false } else { withAnimation { page += 1 } }
            } label: {
                Text(isLast ? "Done" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(enabled ? .white : .textDim)
                    .padding(.horizontal, 22).padding(.vertical, 9)
                    .background(enabled ? Color.accent : Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(enabled ? Color.clear : Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(!enabled)
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    // MARK: Page 1 — copy gate

    private var copyGatePage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Copy these 3 lines").font(.system(size: 18, weight: .bold)).foregroundColor(.textPri)
                Text("Click into each box, select the text, and press ⌘C. Clipen will catch every copy automatically.")
                    .font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 400)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(Array(Self.copyTargets.enumerated()), id: \.offset) { idx, text in
                    copyTargetRow(index: idx, text: text, copied: isCopied(text))
                }
            }

            Text(canAdvance
                 ? "Nice! Tap Continue to learn how to paste them back."
                 : "Copied \(copiedCount) of \(Self.copyTargets.count) — copy the rest to continue.")
                .font(.system(size: 11))
                .foregroundColor(canAdvance ? .green : .textDim)
                .frame(minHeight: 16).animation(.easeInOut(duration: 0.2), value: canAdvance)
        }
        .padding(.horizontal, 22).padding(.vertical, 22).frame(maxWidth: .infinity)
    }

    private func copyTargetRow(index: Int, text: String, copied: Bool) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(copied ? .white : .textSec).frame(width: 22, height: 22)
                .background(copied ? Color.green : Color.textDim.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 6))
            Text(text).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundColor(.textPri)
                .textSelection(.enabled).padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(copied ? Color.green.opacity(0.5) : Color.border, lineWidth: 1))
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "command")
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(copied ? .green : .textDim)
                Text(copied ? "Copied" : "⌘C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(copied ? .green : .textDim)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background((copied ? Color.green : Color.textDim).opacity(copied ? 0.14 : 0.08),
                        in: RoundedRectangle(cornerRadius: 6))
            .frame(minWidth: 70, alignment: .center)
            .animation(.spring(response: 0.3), value: copied)
        }
    }

    // MARK: Pages 2-4

    private var cyclePage: some View {
        animatedPage(
            title: "Hold ⌘ and tap V to cycle",
            detail: "Hold ⌘ to open your clipboard ring. Each tap of V moves to the next item; ⌘⌥V leaps 5 forward. Release ⌘ to paste the highlighted item.",
            hint:   "Click below, then hold ⌘ · tap V to cycle · release ⌘ to paste."
        ) { cycleAnimation(active: tick % 5) }
    }

    private var transformPage: some View {
        animatedPage(
            title: "Pick with V, then transform with X",
            detail: "First hold ⌘ and tap V to land on the item you want to change. Then tap X to apply a transform — UPPERCASE, lowercase, Base64, JSON pretty-print and more. Tap X again to cycle. Release ⌘ to paste.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap X to transform it."
        ) { transformAnimation(active: tick % 10) }
    }

    private var deletePage: some View {
        animatedPage(
            title: "Pick with V, then delete with ⌫",
            detail: "First hold ⌘ and tap V to land on the item you want to remove. Then tap ⌫ while the popup is still open.",
            hint:   "Click below, hold ⌘, tap V to pick an item, then tap ⌫ to remove it."
        ) { deleteAnimation(active: tick % 6) }
    }

    private func animatedPage<A: View>(title: String, detail: String, hint: String,
                                       @ViewBuilder anim: () -> A) -> some View {
        VStack(spacing: 16) {
            anim()
            VStack(spacing: 6) {
                Text(title).font(.system(size: 17, weight: .bold)).foregroundColor(.textPri)
                Text(detail).font(.system(size: 12)).foregroundColor(.textSec)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            }
            practiceBox(hint: hint)
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14).frame(maxWidth: .infinity)
    }

    private func practiceBox(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip.crop.circle").font(.system(size: 10, weight: .semibold)).foregroundColor(.accent)
                Text("TRY IT HERE").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.textDim).tracking(1.4)
                Spacer()
                if !practiceText.isEmpty {
                    Button { practiceText = "" } label: {
                        Text("Clear").font(.system(size: 10, weight: .medium)).foregroundColor(.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(.textPri)
                    .frame(height: 78).scrollContentBackground(.hidden)
                    .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))
                if practiceText.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundColor(.textDim)
                        .padding(.horizontal, 8).padding(.vertical, 9).allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Animations

    private let snippets = ["Hello from Clipen", "https://clipen.app", "Made with care on macOS"]
    private let vTaps = 2
    private var pickFrames: Int { vTaps * 2 }

    private func cycleAnimation(active: Int) -> some View {
        let phase = active % (pickFrames + 1)
        let cmdHeld = phase < pickFrames
        return animCard {
            HStack(spacing: 12) {
                keyCluster(cmdHeld: cmdHeld, vTap: cmdHeld && (phase % 2 == 0),
                           showRelease: phase == pickFrames)
                Spacer()
                if cmdHeld {
                    ringList(snippets: snippets, selected: min(phase / 2, vTaps - 1))
                } else {
                    pasteLabel()
                }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func transformAnimation(active: Int) -> some View {
        let transforms: [(String, String)] = [("UPPER","HTTPS://CLIPEN.APP"),("lower","https://clipen.app"),("Base64","aHR0cHM6Ly9jbGlwZW4uYXBw")]
        let phase = active % (pickFrames + 6)
        let inPick = phase < pickFrames
        let pickIdx = inPick ? min(phase / 2, vTaps - 1) : vTaps - 1
        let xPhase = phase - pickFrames
        let xIdx = inPick ? 0 : min(xPhase / 2, transforms.count - 1)
        return animCard {
            HStack(spacing: 10) {
                keyCluster(cmdHeld: true, vTap: inPick && phase % 2 == 0, showV: inPick,
                           xTap: !inPick && xPhase % 2 == 0, showX: !inPick)
                Spacer()
                transformRow(pickIdx: inPick ? pickIdx : vTaps - 1,
                             text: inPick ? snippets[pickIdx] : transforms[xIdx].1,
                             label: inPick ? nil : transforms[xIdx].0)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func deleteAnimation(active: Int) -> some View {
        let phase = active % (pickFrames + 2)
        let inPick = phase < pickFrames
        let del = phase == pickFrames
        let removed = phase == pickFrames + 1
        return animCard {
            HStack(spacing: 10) {
                keyCluster(cmdHeld: phase < pickFrames + 1, vTap: inPick && phase % 2 == 0,
                           showV: inPick, delTap: del, showDel: !inPick)
                Spacer()
                deleteRow(snippets: snippets, pickIdx: inPick ? min(phase/2, vTaps-1) : vTaps-1,
                          deleteIdx: vTaps-1, marking: del, removed: removed)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase)
    }

    private func animCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
            content().padding(.horizontal, 18)
        }
        .frame(height: 140)
    }

    private func keyCluster(cmdHeld: Bool, vTap: Bool = false, showV: Bool = true,
                             xTap: Bool = false, showX: Bool = false,
                             delTap: Bool = false, showDel: Bool = false,
                             showRelease: Bool = false) -> some View {
        HStack(spacing: 6) {
            animKey("⌘", pressed: cmdHeld, caption: cmdHeld ? "hold" : "release")
            if !showRelease {
                if showV {
                    Text("+").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("V", pressed: vTap, caption: vTap ? "tap" : nil)
                }
                if showX {
                    Text("→").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("X", pressed: xTap, caption: xTap ? "tap" : nil)
                }
                if showDel {
                    Text("→").font(.system(size: 14, weight: .bold)).foregroundColor(.textDim)
                    animKey("⌫", pressed: delTap, caption: delTap ? "tap" : nil)
                }
            }
        }
    }

    private func animKey(_ label: String, pressed: Bool, caption: String?) -> some View {
        VStack(spacing: 3) {
            Text(label).font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(pressed ? .white : .textPri).frame(width: 56, height: 56)
                .background(RoundedRectangle(cornerRadius: 10).fill(pressed ? Color.accent : Color.surface))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(pressed ? Color.accent : Color.border, lineWidth: 1.5))
                .shadow(color: pressed ? Color.accent.opacity(0.4) : .clear, radius: 8, y: 2)
                .offset(y: pressed ? 2 : 0).animation(.easeOut(duration: 0.2), value: pressed)
            Text(caption ?? " ").font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundColor(pressed ? .accent : .textDim).opacity(caption == nil ? 0 : 1).frame(height: 10)
        }
    }

    private func ringList(snippets: [String], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<snippets.count, id: \.self) { i in
                let sel = i == selected
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(sel ? Color.accent : Color.textDim.opacity(0.4)).frame(width: 12, height: 5)
                    Text(snippets[i]).font(.system(size: 9, weight: sel ? .semibold : .regular, design: .monospaced))
                        .foregroundColor(sel ? .textPri : .textSec).lineLimit(1).truncationMode(.tail).frame(maxWidth: 150, alignment: .leading)
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(sel ? Color.accentDim : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: selected)
    }

    private func pasteLabel() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down").font(.system(size: 14, weight: .bold)).foregroundColor(.accent)
            Text("Pasted!").font(.system(size: 13, weight: .bold)).foregroundColor(.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 8))
        .transition(.scale.combined(with: .opacity))
    }

    private func transformRow(pickIdx: Int, text: String, label: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { i in
                let picked = i == pickIdx
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(picked ? Color.accent : Color.textDim.opacity(0.4)).frame(width: 12, height: 5)
                    if picked {
                        Text(text).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPri).lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
                            .animation(.easeInOut(duration: 0.25), value: text)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.textDim.opacity(0.3)).frame(width: 90, height: 5)
                    }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(picked ? Color.accentDim : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            if let lbl = label {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars").font(.system(size: 8, weight: .semibold)).foregroundColor(.accent)
                    Text(lbl).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.accent)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.accentDim, in: Capsule())
                .overlay(Capsule().stroke(Color.accent.opacity(0.4), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.25), value: lbl)
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
    }

    private func deleteRow(snippets: [String], pickIdx: Int, deleteIdx: Int,
                           marking: Bool, removed: Bool) -> some View {
        let visible = removed ? snippets.indices.filter { $0 != deleteIdx } : Array(snippets.indices)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(visible, id: \.self) { i in
                let picked   = !removed && i == pickIdx
                let deleting = !removed && marking && i == deleteIdx
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(deleting ? Color.red.opacity(0.9) : (picked ? Color.accent : Color.textDim.opacity(0.4)))
                        .frame(width: 12, height: 5)
                    if picked || removed {
                        Text(snippets[i]).font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(deleting ? .red.opacity(0.85) : .textPri)
                            .lineLimit(1).truncationMode(.tail).frame(maxWidth: 130, alignment: .leading)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Color.textDim.opacity(0.3)).frame(width: 90, height: 5)
                    }
                    if deleting { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.red) }
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(deleting ? Color.red.opacity(0.15) : (picked ? Color.accentDim : Color.clear),
                            in: RoundedRectangle(cornerRadius: 4))
                .opacity(deleting ? 0.7 : 1).scaleEffect(deleting ? 0.96 : 1)
            }
            if removed {
                HStack(spacing: 4) {
                    Image(systemName: "trash").font(.system(size: 8, weight: .semibold)).foregroundColor(.red.opacity(0.9))
                    Text("Deleted").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.red.opacity(0.9))
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.35), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(10).background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: pickIdx)
        .animation(.easeInOut(duration: 0.3), value: marking)
        .animation(.easeInOut(duration: 0.3), value: removed)
    }

    // MARK: Tick

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: true) { _ in tick &+= 1 }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func stopTick() { tickTimer?.invalidate(); tickTimer = nil }
}

// MARK: - Utilities

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
