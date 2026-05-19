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
    @State private var hoveredID: UUID? = nil
    @State private var showTutorial     = false
    @State private var isSemanticSearch = false
    @State private var timeScrubPos: Double = 1.0   // 1.0 = now, 0.0 = oldest
    @AppStorage("hasSkippedAccessibility")   private var hasSkippedAccessibility   = false
    @AppStorage("hasSeenTutorial")           private var hasSeenTutorial           = false

    var filtered: [ClipboardItem] {
        guard !searchText.isEmpty else { return manager.displayItems }

        // Try semantic search first (needs 2+ chars and embeddings)
        let semantic = manager.semanticSearch(query: searchText)
        if !semantic.isEmpty {
            return semantic
        }

        // Fallback: substring match
        return manager.displayItems.filter {
            if case .text(let s) = $0.content { return s.localizedCaseInsensitiveContains(searchText) }
            return false
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                mainArea
                    .frame(minWidth: 400)
            }
            .frame(minWidth: 660, minHeight: 560)

            // (account-deletion overlay and Get Pro toast removed with the
            // account system — kept the transient status toast below for
            // non-account messages like "No text found in image".)

            // Transient transform/system status — short messages like
            // "No text found in image" auto-dismiss after ~2.5 s.
            if let status = manager.transientStatus {
                Text(status)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.top, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }
        }
        .background(Color.bg)
        .preferredColorScheme(.dark)
        .onAppear { }   // onboarding flow is driven by mainArea step conditions above
        // Global error alert — any backend / auth failure surfaces here
        .alert("Heads up",
               isPresented: Binding(
                    get: { auth.lastError != nil },
                    set: { if !$0 { auth.clearError() } }
               )) {
            Button("OK", role: .cancel) { auth.clearError() }
        } message: {
            Text(auth.lastError ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button { showTutorial = true } label: {
                    HStack(spacing: 4) {
                        Text("How to use")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "questionmark.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .help("How to use")
                .sheet(isPresented: $showTutorial) {
                    TutorialSheet(isPresented: $showTutorial)
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Fixed header ─────────────────────────────
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                        .resizable()
                        .frame(width: 28, height: 28)
                        .cornerRadius(6)
                    Text("Clipen")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.textPri)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text("\(manager.items.count)")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundColor(.accent)
                        Text("/ \(manager.maxItems)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.textDim)
                    }
                    Text("items")
                        .font(.system(size: 9))
                        .foregroundColor(.textDim)
                }
                .padding(.leading, 10)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            // (Account section completely removed — Clipen has no
            // user accounts. Scrollable preferences start right below
            // the header.)
            Divider().background(Color.border)

            // ── Scrollable middle ─────────────────────────
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {

                    // PREFERENCES
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("PREFERENCES")
                            .padding(.bottom, 10)

                        settingsCard {
                            cardRow(icon: "square.stack", label: "Ring size") {
                                // Always adjustable now. No Pro/Free split.
                                Stepper(
                                    value: Binding(
                                        get: { manager.maxItems },
                                        set: { manager.setRingSize($0) }
                                    ),
                                    in: 5...200, step: 5
                                ) {
                                    Text("\(manager.maxItems)")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(.accent)
                                        .frame(minWidth: 22, alignment: .trailing)
                                }
                                .fixedSize()
                            }
                            cardDivider()
                            cardRow(icon: "arrow.up.arrow.down", label: "Order") {
                                Button { manager.isReversed.toggle() } label: {
                                    Text(manager.isReversed ? "Oldest first" : "Newest first")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                            }
                            cardDivider()
                            cardRow(icon: "menubar.rectangle", label: "Menu bar") {
                                Toggle("", isOn: Binding(
                                    get: { AppDelegate.shared?.showMenuBarIcon ?? true },
                                    set: { AppDelegate.shared?.showMenuBarIcon = $0 }
                                ))
                                .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                            cardDivider()
                            cardRow(icon: "power", label: "Launch at Login") {
                                Toggle("", isOn: Binding(
                                    get: { manager.launchAtLogin },
                                    set: { manager.launchAtLogin = $0 }
                                ))
                                .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                            cardDivider()
                            cardRow(icon: "arrow.triangle.2.circlepath", label: "Auto updates") {
                                Toggle("", isOn: Binding(
                                    get: { AppDelegate.shared?.automaticallyChecksForUpdates ?? true },
                                    set: { AppDelegate.shared?.automaticallyChecksForUpdates = $0 }
                                ))
                                .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                            cardDivider()
                            cardRow(icon: "pin", label: "Pins go to") {
                                Button { manager.pinnedAtBottom.toggle() } label: {
                                    Text(manager.pinnedAtBottom ? "Bottom" : "Top")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.accent)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 5))
                                }
                                .buttonStyle(.plain)
                            }
                            cardDivider()
                            sliderCardRow(
                                icon: "timer",
                                label: "Idle timer",
                                value: manager.dismissTimeout == 0 ? "Off" : "\(Int(manager.dismissTimeout))s",
                                active: manager.dismissTimeout != 0,
                                caption: "Clears the highlight after idle; popup stays until you release ⌘ or press Esc."
                            ) {
                                Slider(value: $manager.dismissTimeout, in: 0...15, step: 1)
                                    .tint(.accent)
                            }
                            cardDivider()
                            // Quick ⌘V tap-and-release → paste front item
                            // without flashing the popup. Slider in ms so
                            // the user can tune the threshold to their tap
                            // speed.
                            sliderCardRow(
                                icon: "hourglass",
                                label: "Open delay",
                                value: manager.firstOpenDelay == 0
                                    ? "Off"
                                    : String(format: "%.0f ms", manager.firstOpenDelay * 1000),
                                active: manager.firstOpenDelay != 0,
                                caption: "Release ⌘ within this window to paste the front item without opening the popup."
                            ) {
                                Slider(
                                    value: Binding(
                                        get: { manager.firstOpenDelay * 1000 },
                                        set: { manager.firstOpenDelay = $0 / 1000 }
                                    ),
                                    in: 0...500, step: 5
                                )
                                .tint(.accent)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)

                    Divider().background(Color.border)

                    // CAPTURE
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("CAPTURE")
                            .padding(.bottom, 10)

                        settingsCard {
                            cardRow(icon: "doc.richtext", label: "Rich text") {
                                Toggle("", isOn: $manager.captureRichText)
                                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                            cardDivider()
                            cardRow(icon: "link", label: "URL titles") {
                                Toggle("", isOn: $manager.fetchURLTitles)
                                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                            cardDivider()
                            cardRow(icon: "paintpalette", label: "Color swatches") {
                                Toggle("", isOn: $manager.showColorSwatches)
                                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 16)

                    Divider().background(Color.border)

                    // SHORTCUTS
                    VStack(alignment: .leading, spacing: 0) {
                        sectionLabel("SHORTCUTS")
                            .padding(.bottom, 10)
                        VStack(spacing: 6) {
                            shortcutRow("⌘C",      "Capture to ring")
                            shortcutRow("⌘V",      "Next item")
                            shortcutRow("⌘⌥V",     "Jump 5 items forward")
                            shortcutRow("⌘V → ⌘X", "Pick with V, then transform with X")
                            shortcutRow("⌘V → ⌘⌫","Pick with V, then delete highlighted")
                            shortcutRow("release ⌘", "Paste selection")
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                }

                // (Diagnostics card removed with the account system —
                // every value it surfaced was account-related.)
            }

            Divider().background(Color.border)

            // ── Fixed footer ─────────────────────────────
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
                Text(Self.appVersionString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.textDim)
                Button {
                    if let url = URL(string: "https://clipen.app/privacy") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Privacy").font(.system(size: 11)).foregroundColor(.textDim)
                }.buttonStyle(.plain)
                Button {
                    AppDelegate.shared?.checkForUpdates()
                } label: {
                    Text("Check for updates").font(.system(size: 11)).foregroundColor(.textDim)
                }.buttonStyle(.plain)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundColor(.textDim)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.surface)
    }

    /// "v1.0 (1)" — shown in the footer so users always know what they're on.
    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    // MARK: - Upgrade flow

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(.textDim)
            .tracking(1.8)
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.border, lineWidth: 1)
        )
    }

    private func cardRow<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.textDim)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.textSec)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func sliderCardRow<SliderView: View>(
        icon: String,
        label: String,
        value: String,
        active: Bool,
        caption: String,
        @ViewBuilder slider: () -> SliderView
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            cardRow(icon: icon, label: label) {
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(active ? .accent : .textDim)
                    .frame(minWidth: 48, alignment: .trailing)
            }

            slider()
                .padding(.horizontal, 12)

            Text(caption)
                .font(.system(size: 10))
                .foregroundColor(.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    private func cardDivider() -> some View {
        Divider()
            .background(Color.border)
            .padding(.leading, 36)
    }

    private func shortcutRow(_ key: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.accent)
                .frame(width: 36, height: 20)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accent.opacity(0.3), lineWidth: 1))
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.textSec)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Main area

    private var mainArea: some View {
        Group {
            if !manager.hasAccessibilityPermission && !hasSkippedAccessibility {
                accessibilityContentView
            } else {
                clipboardArea
                    .onAppear {
                        guard !hasSeenTutorial else { return }
                        hasSeenTutorial = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            showTutorial = true
                        }
                    }
            }
        }
        // When accessibility is granted while on that screen, auto-advance
        .onChange(of: manager.hasAccessibilityPermission) { _, granted in
            if granted && !hasSeenTutorial {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    hasSeenTutorial = true
                    showTutorial    = true
                }
            }
        }
    }

    // MARK: - Accessibility permission

    private var accessibilityContentView: some View {
        VStack(spacing: 0) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 110, height: 110)
                Image(systemName: "keyboard.badge.ellipsis")
                    .font(.system(size: 40, weight: .thin))
                    .foregroundColor(.orange)
            }
            .padding(.bottom, 24)

            // Title + description
            VStack(spacing: 10) {
                Text("One Permission Needed")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.textPri)
                Text("Clipen needs Accessibility access so\n⌘V can cycle your clipboard ring.")
                    .font(.system(size: 13))
                    .foregroundColor(.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 28)

            // How it works steps
            VStack(alignment: .leading, spacing: 10) {
                accessibilityStep("1", "Hold ⌘ and tap V",  "Opens your clipboard ring near the cursor")
                accessibilityStep("2", "Tap V · ⌥V",        "Next item · ⌥V jumps 5 forward")
                accessibilityStep("3", "Tap V, then X",     "Pick an item with V, then transform it with X")
                accessibilityStep("4", "Tap V, then ⌫",     "Pick an item with V, then delete it from the ring")
                accessibilityStep("5", "Release ⌘",         "Pastes the highlighted (or transformed) item")
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 30)

            // Open Settings button
            Button {
                manager.attemptEventTap()
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.fill")
                    Text("Open Accessibility Settings")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 13)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 10))
                .shadow(color: Color.orange.opacity(0.3), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)

            // Skip
            Button { hasSkippedAccessibility = true } label: {
                Text("Skip — I'll enable this later")
                    .font(.system(size: 12))
                    .foregroundColor(.textSec)
                    .underline()
            }
            .buttonStyle(.plain)

            Spacer()

            // Waiting indicator at bottom
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.65)
                Text("Waiting for permission to be granted…")
                    .font(.system(size: 11))
                    .foregroundColor(.textDim)
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.bg)
    }

    private func accessibilityStep(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.orange)
                .frame(width: 22, height: 22)
                .background(Color.orange.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.textPri)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.textSec)
            }
            Spacer()
        }
    }

    private var clipboardArea: some View {
        VStack(spacing: 0) {

            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.textDim)
                    .font(.system(size: 13))
                TextField("Search clipboard…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundColor(.textPri)
                if !searchText.isEmpty {
                    if !manager.semanticSearch(query: searchText).isEmpty {
                        Text("Semantic")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.accent)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 4))
                    }
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.textDim)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.surfaceHi)

            Divider().background(Color.border)

            // Time machine scrubber (only when there are items to scrub through)
            if manager.items.count > 1 {
                timeMachineScrubber
                Divider().background(Color.border)
            }

            if !manager.items.isEmpty {
                typeFilterStrip
                Divider().background(Color.border)
            }

            if filtered.isEmpty {
                emptyState
            } else {
                itemList
            }
        }
    }

    // MARK: - Time machine scrubber

    private var timeMachineScrubber: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundColor(timeScrubPos < 1.0 ? .accent : .textDim)

            Slider(value: $timeScrubPos, in: 0...1)
                .tint(timeScrubPos < 1.0 ? .accent : .textDim)
                .onChange(of: timeScrubPos) { _, _ in applyWindowScrub() }

            if timeScrubPos < 1.0 {
                Text(windowScrubLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accent)
                    .frame(minWidth: 70, alignment: .trailing)
                Button("Now") {
                    withAnimation { timeScrubPos = 1.0 }
                    manager.timeScrubDate = nil
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundColor(.accent)
            } else {
                Text("Time Machine")
                    .font(.system(size: 10))
                    .foregroundColor(.textDim)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(timeScrubPos < 1.0 ? Color.accentDim : Color.clear)
    }

    private var windowScrubLabel: String {
        guard timeScrubPos < 1.0, let oldest = manager.items.last?.timestamp else { return "" }
        let range  = Date().timeIntervalSince(oldest)
        let cutoff = oldest.addingTimeInterval(range * timeScrubPos)
        let s = Int(-cutoff.timeIntervalSinceNow)
        if s < 60   { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }

    private func applyWindowScrub() {
        guard timeScrubPos < 1.0, let oldest = manager.items.last?.timestamp else {
            manager.timeScrubDate = nil
            return
        }
        let range = Date().timeIntervalSince(oldest)
        manager.timeScrubDate = oldest.addingTimeInterval(range * timeScrubPos)
    }

    // MARK: - Type filters

    private var typeFilterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                typeFilterPill(
                    label: "All",
                    icon: "square.grid.2x2",
                    count: manager.items.count,
                    isSelected: manager.categoryFilter == nil
                ) {
                    manager.categoryFilter = nil
                }

                ForEach(visibleTypeCategories, id: \.self) { category in
                    typeFilterPill(
                        label: category.label,
                        icon: category.icon,
                        count: categoryCount(category),
                        isSelected: manager.categoryFilter == category
                    ) {
                        manager.categoryFilter = category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.surface)
    }

    private var visibleTypeCategories: [ClipboardCategory] {
        ClipboardCategory.allCases.filter { categoryCount($0) > 0 }
    }

    private func categoryCount(_ category: ClipboardCategory) -> Int {
        manager.items.reduce(0) { count, item in
            count + (item.category == category ? 1 : 0)
        }
    }

    private func typeFilterPill(label: String,
                                icon: String,
                                count: Int,
                                isSelected: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.75) : .textDim)
            }
            .foregroundColor(isSelected ? .white : .textSec)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.accent : Color.surfaceHi, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accent : Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty
    private var emptyState: some View {
        Group {
            if searchText.isEmpty {
                OnboardingView()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 36, weight: .thin))
                        .foregroundColor(.textDim)
                    Text("No matches")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.textSec)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - List
    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, item in
                    DarkItemRow(
                        item: item,
                        index: index,
                        isSelected: item.id == manager.displayItems[safe: manager.selectedIndex]?.id,
                        isHovered: hoveredID == item.id,
                        onDelete: {
                            if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                manager.removeItem(at: real)
                            }
                        }
                    )
                    .onHover { hoveredID = $0 ? item.id : nil }
                    .onTapGesture(count: 2) {
                        if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                            manager.pasteItem(at: real)
                        }
                    }
                    .contextMenu {
                        Button("Paste") {
                            if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                manager.pasteItem(at: real)
                            }
                        }
                        Divider()
                        Button(item.isPinned ? "Unpin" : "Pin") {
                            manager.togglePin(id: item.id)
                        }
                        Button("Remove", role: .destructive) {
                            if let real = manager.items.firstIndex(where: { $0.id == item.id }) {
                                manager.removeItem(at: real)
                            }
                        }
                    }

                    if index < filtered.count - 1 {
                        Divider()
                            .background(Color.border)
                            .padding(.leading, 52)
                    }
                }
            }
        }
        .background(Color.bg)
    }
}

// MARK: - Dark row

struct DarkItemRow: View {
    let item:       ClipboardItem
    let index:      Int
    let isSelected: Bool
    let isHovered:  Bool
    let onDelete:   () -> Void

    private var manager: ClipboardManager { ClipboardManager.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {

            // ── Header: badge · type  ·  time · pin · X ──
            HStack(spacing: 10) {
                // Badge
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.accent : Color(hex: "#2A2A2A"))
                        .frame(width: 26, height: 22)
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(isSelected ? .white : Color(hex: "#555555"))
                }

                // Type icon + label
                HStack(spacing: 4) {
                    Image(systemName: item.typeIcon)
                        .font(.system(size: 9, weight: .semibold))
                    Text(item.typeLabel)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(Color(hex: "#666666"))

                ContentTypeBadge(type: item.detectedType)

                // Diff badge
                if let badge = item.diffBadge {
                    Text("∆ \(badge)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                }

                Spacer()

                Text(relativeTime(item.timestamp))
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "#444444"))

                Button { manager.togglePin(id: item.id) } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundColor(item.isPinned ? .accent : Color(hex: "#3A3A3A"))
                }
                .buttonStyle(.plain)
                .help(item.isPinned ? "Unpin" : "Pin")

                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#3A3A3A"))
                }
                .buttonStyle(.plain)
            }

            // ── Content ──────────────────────────────────
            contentPreview
                .padding(.leading, 36)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isHovered ? Color(hex: "#1E1E1E") : (isSelected ? Color.accentDim : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var contentPreview: some View {
        switch item.content {
        case .text(let str):
            HStack(alignment: .top, spacing: 8) {
                if manager.showColorSwatches, let nsColor = item.detectedColor {
                    Circle().fill(Color(nsColor: nsColor)).frame(width: 13, height: 13)
                        .overlay(Circle().stroke(Color.primary.opacity(0.2), lineWidth: 1))
                        .padding(.top, 2)
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
        case .file(let url):
            HStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(url.deletingLastPathComponent().path).font(.system(size: 10)).lineLimit(1)
                    .foregroundColor(Color(hex: "#555555"))
            }
        case .image(let img, _, _):
            Image(nsImage: img).resizable().scaledToFit().frame(height: 36).cornerRadius(4)
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 5  { return "just now" }
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }
}

// MARK: - Onboarding (animated empty state)

struct OnboardingView: View {
    @State private var step    = 0
    @State private var fade    = true
    @State private var bounce  = false

    private let steps: [(icon: String, key: String, title: String, sub: String)] = [
        ("doc.on.clipboard.fill", "⌘C",        "Copy anything",        "Copy text, images, files or URLs anywhere on your Mac"),
        ("arrow.clockwise",       "Hold ⌘ · V", "Cycle your ring",        "Tap V for the next item · ⌥V jumps 5 forward while ⌘ is held"),
        ("arrow.down.doc.fill",   "Release ⌘",  "Paste your pick",          "Let go of ⌘ to paste whichever item is highlighted"),
        ("wand.and.stars",        "V → X",      "Pick, then transform",     "Hold ⌘, tap V to land on an item, then tap X — tap X again to cycle transforms"),
        ("trash",                 "V → ⌫",      "Pick, then delete",        "Hold ⌘, tap V to highlight what to remove, then tap ⌫ to drop it from the ring"),
        ("pin.fill",              "Pin",        "Pin your favourites",      "Right-click any item to pin it so it never falls off the ring"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Animated icon
            ZStack {
                Circle()
                    .fill(Color.accentDim)
                    .frame(width: 84, height: 84)
                Image(systemName: steps[step].icon)
                    .font(.system(size: 34, weight: .thin))
                    .foregroundColor(.accent)
                    .scaleEffect(bounce ? 1.12 : 1.0)
                    .animation(.spring(response: 0.35, dampingFraction: 0.55), value: bounce)
            }
            .opacity(fade ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: fade)
            .padding(.bottom, 24)

            // Key badge
            Text(steps[step].key)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accent.opacity(0.3), lineWidth: 1))
                .opacity(fade ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: fade)
                .padding(.bottom, 14)

            // Text
            VStack(spacing: 6) {
                Text(steps[step].title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.textPri)
                Text(steps[step].sub)
                    .font(.system(size: 12))
                    .foregroundColor(.textSec)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .opacity(fade ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: fade)

            Spacer()

            // Step dots
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startCycle() }
    }

    private func startCycle() {
        Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { _ in
            withAnimation { fade = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                step = (step + 1) % steps.count
                withAnimation { fade = true }
                bounce = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { bounce = false }
            }
        }
    }
}

// MARK: - Tutorial sheet
//
// Four-page wizard. Each page is its own focused screen — no auto-scrolling,
// no try-it-yourself sandbox at the bottom. Progression is driven by an
// explicit Continue button (Page 1 also gates on the user actually copying
// 3 things first; pages 2–4 are pure animations and Continue is always on).
//
//   Page 1 — Copy 3 items. Continue unlocks when 3 new items are in the ring.
//   Page 2 — Paste / cycle animation.
//   Page 3 — Transform animation.
//   Page 4 — Delete animation. Last button says Done and closes the sheet.

struct TutorialSheet: View {
    @Binding var isPresented: Bool

    @ObservedObject private var manager = ClipboardManager.shared

    /// Current wizard page (0…3).
    @State private var page: Int = 0

    /// IDs that already lived in the ring when the sheet opened — used to
    /// count only NEW copies the user makes during the tutorial.
    @State private var baselineIDs: Set<UUID> = []

    /// Animation tick — drives the looping demos on pages 2–4.
    @State private var tick: Int = 0
    @State private var tickTimer: Timer? = nil

    /// Live practice scratchpad shared across pages 2–4. Users actually
    /// paste / transform / delete here using the same ⌘V / ⌘X / ⌘⌫
    /// shortcuts they'd use system-wide — Clipen's global event tap fires
    /// regardless of which window has focus.
    @State private var practiceText: String = ""

    private static let totalPages = 4

    /// Three concrete snippets the user must copy themselves with ⌘C.
    /// Detection is by exact-string match against pasteboard items added
    /// after the sheet opened — we never put anything on the clipboard
    /// ourselves, so the user has to actually press ⌘C.
    private static let copyTargets: [String] = [
        "Hello from Clipen",
        "https://clipen.app",
        "Made with care on macOS",
    ]

    /// Plain-text content of every new clipboard item the user copied
    /// after the tutorial opened. Trimmed for forgiveness around trailing
    /// whitespace that some apps add when you copy a line.
    private var newCopiedTexts: Set<String> {
        let newItems = manager.items.filter { !baselineIDs.contains($0.id) }
        return Set(newItems.compactMap { item -> String? in
            switch item.content {
            case .text(let s):                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .richText(_, plain: let p):  return p.trimmingCharacters(in: .whitespacesAndNewlines)
            default:                          return nil
            }
        })
    }

    private func isCopied(_ target: String) -> Bool {
        newCopiedTexts.contains(target.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var copiedCount: Int { Self.copyTargets.filter(isCopied).count }

    private var canAdvanceFromGate: Bool { copiedCount == Self.copyTargets.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.border)

            Group {
                switch page {
                case 0: copyGatePage
                case 1: cyclePage
                case 2: transformPage
                default: deletePage
                }
            }
            .frame(minHeight: 420)

            Divider().background(Color.border)
            footer
        }
        .frame(width: 500)
        .background(Color.surface)
        .preferredColorScheme(.dark)
        .onAppear {
            baselineIDs = Set(manager.items.map(\.id))
            startTick()
        }
        .onDisappear { stopTick() }
    }

    // MARK: Header & footer

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "graduationcap.fill")
                .foregroundColor(.accent)
            Text("How Clipen works")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.textPri)
            Spacer()
            Text("Step \(page + 1) of \(Self.totalPages)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.textDim)
            Button { isPresented = false } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.textSec)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(0..<Self.totalPages, id: \.self) { i in
                    Circle()
                        .fill(i == page ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: i == page ? 8 : 6, height: i == page ? 8 : 6)
                        .animation(.spring(response: 0.3), value: page)
                }
            }
            Spacer()

            if page > 0 {
                Button { withAnimation { page -= 1 } } label: {
                    Text("Back")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.textSec)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }

            let isLast = page == Self.totalPages - 1
            let enabled = page == 0 ? canAdvanceFromGate : true

            Button {
                if isLast {
                    isPresented = false
                } else {
                    withAnimation { page += 1 }
                }
            } label: {
                Text(isLast ? "Done" : "Continue")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(enabled ? .white : .textDim)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 9)
                    .background(enabled ? Color.accent : Color.surfaceHi,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(enabled ? Color.clear : Color.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: Page 1 — copy gate

    private var copyGatePage: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Copy these 3 lines")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.textPri)
                Text("Click into each box, select the text, and press ⌘C. Clipen will catch every copy automatically.")
                    .font(.system(size: 12))
                    .foregroundColor(.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
            }
            .padding(.top, 4)

            VStack(spacing: 10) {
                ForEach(Array(Self.copyTargets.enumerated()), id: \.offset) { idx, text in
                    copyTargetRow(index: idx, text: text, copied: isCopied(text))
                }
            }

            Text(canAdvanceFromGate
                 ? "Nice! Tap Continue to learn how to paste them back."
                 : "Copied \(copiedCount) of \(Self.copyTargets.count) — copy the rest to continue.")
                .font(.system(size: 11))
                .foregroundColor(canAdvanceFromGate ? .green : .textDim)
                .frame(minHeight: 16)
                .animation(.easeInOut(duration: 0.2), value: canAdvanceFromGate)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }

    /// One row on the copy-gate page — number badge, the literal text the
    /// user has to copy (system-selectable), and a status pill.
    private func copyTargetRow(index: Int, text: String, copied: Bool) -> some View {
        HStack(spacing: 12) {
            // Number badge
            Text("\(index + 1)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundColor(copied ? .white : .textSec)
                .frame(width: 22, height: 22)
                .background(
                    copied ? Color.green : Color.textDim.opacity(0.18),
                    in: RoundedRectangle(cornerRadius: 6)
                )

            // The literal text — selectable so the user can drag-select & ⌘C
            Text(text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.textPri)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(copied ? Color.green.opacity(0.5) : Color.border, lineWidth: 1)
                )

            // Status pill
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark.circle.fill" : "command")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(copied ? .green : .textDim)
                Text(copied ? "Copied" : "⌘C")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(copied ? .green : .textDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                (copied ? Color.green : Color.textDim).opacity(copied ? 0.14 : 0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .frame(minWidth: 70, alignment: .center)
            .animation(.spring(response: 0.3), value: copied)
        }
    }

    // MARK: Pages 2–4 — animation + live practice

    private var cyclePage: some View {
        animatedPage(
            title:       "Hold ⌘ and tap V to cycle",
            detail:      "Hold ⌘ to open your clipboard ring near the cursor. Each tap of V moves to the next item; tap ⌥V to leap 5 forward. Release ⌘ to paste whichever item is highlighted.",
            practiceHint:"Click below, then hold ⌘ · tap V to cycle · release ⌘ to paste one of the lines you just copied."
        ) { cycleAnimation(active: tick % 4) }
    }

    private var transformPage: some View {
        animatedPage(
            title:       "Pick with V, then transform with X",
            detail:      "First hold ⌘ and tap V to land on the item you want to change. Then tap X to apply a transform — UPPERCASE, lowercase, Base64, JSON pretty-print, URL encode and more. Tap X again to cycle through every transform that fits the picked item. Release ⌘ to paste the result.",
            practiceHint:"Click below, hold ⌘, tap V until the item you want is highlighted, then tap X to transform it. Tap X again to try the next transform."
        ) { transformAnimation(active: tick % 6) }
    }

    private var deletePage: some View {
        animatedPage(
            title:       "Pick with V, then delete with ⌫",
            detail:      "First hold ⌘ and tap V to land on the item you want to remove. Then tap ⌫ while the popup is still open — only that highlighted item is deleted. You can also click × on any row in the popup.",
            practiceHint:"Click below, hold ⌘, tap V until the item you want is highlighted, then tap ⌫ to remove it from the ring."
        ) { deleteAnimation(active: tick % 6) }
    }

    /// Shared layout for pages 2–4: animation on top, title + body, then a
    /// live text-editor where the user actually performs the gesture with
    /// the snippets they copied on page 1.
    private func animatedPage<Anim: View>(title:        String,
                                          detail:       String,
                                          practiceHint: String,
                                          @ViewBuilder anim: () -> Anim) -> some View {
        VStack(spacing: 16) {
            anim()

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.textPri)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            practiceBox(hint: practiceHint)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
    }

    /// Real text editor — the user clicks into it and actually performs the
    /// ⌘V / ⌘X / ⌘⌫ flow with the snippets they just copied.
    private func practiceBox(hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.tip.crop.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.accent)
                Text("TRY IT HERE")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.textDim)
                    .tracking(1.4)
                Spacer()
                if !practiceText.isEmpty {
                    Button { practiceText = "" } label: {
                        Text("Clear")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.textDim)
                    }
                    .buttonStyle(.plain)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.textPri)
                    .frame(height: 78)
                    .scrollContentBackground(.hidden)
                    .background(Color.surfaceHi, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.border, lineWidth: 1)
                    )

                if practiceText.isEmpty {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(.textDim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: Animations

    /// 4-frame loop: ⌘ pressed → V tapped (row 0 selected) → V again (row 1)
    /// → ⌘ released = paste confirmation.
    private func cycleAnimation(active: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
            HStack(spacing: 14) {
                animatedKey("⌘", isPressed: active <= 2)
                animatedKey("V", isPressed: active == 1 || active == 2)
                Spacer()
                if active <= 2 {
                    popupIllustration(active: active >= 1, selectedIndex: max(0, active - 1))
                } else {
                    pasteIllustration()
                }
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 140)
        .animation(.easeInOut(duration: 0.35), value: active)
    }

    /// 6-frame, two-phase loop — first show ⌘V picking *which* item to act
    /// on, then ⌘X cycling transforms on the picked item.
    ///   0: ⌘ pressed, popup opens with row 0 highlighted (original text)
    ///   1: ⌘+V again → row 1 highlighted (different item)
    ///   2: ⌘+V again → row 2 highlighted (the one we'll transform)
    ///   3: ⌘+X → row 2's text turns UPPER CASE
    ///   4: ⌘+X again → lowercase
    ///   5: ⌘+X again → Base64
    private func transformAnimation(active: Int) -> some View {
        let snippets = [
            "Hello from Clipen",
            "https://clipen.app",
            "Made with care",
        ]
        let transforms: [(name: String, sample: String)] = [
            ("UPPER",  "MADE WITH CARE"),
            ("lower",  "made with care"),
            ("Base64", "TWFkZSB3aXRoIGNhcmU="),
        ]

        let inPickPhase = active <= 2
        let pickIndex   = min(active, 2)
        let xIndex      = max(0, active - 3)
        let xPressed    = active >= 3
        let rowText     = inPickPhase
            ? snippets[pickIndex]
            : transforms[min(xIndex, transforms.count - 1)].sample
        let transformLabel = inPickPhase
            ? nil
            : transforms[min(xIndex, transforms.count - 1)].name

        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
            HStack(spacing: 10) {
                animatedKey("⌘", isPressed: true)
                animatedKey("V", isPressed: inPickPhase)
                Text("→")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textDim)
                animatedKey("X", isPressed: xPressed)
                Spacer()
                transformRowIllustration(
                    pickIndex:      pickIndex,
                    rowText:        rowText,
                    transformLabel: transformLabel
                )
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 140)
        .animation(.easeInOut(duration: 0.35), value: active)
    }

    /// 6-frame, two-phase loop — first ⌘V picks *which* item to delete,
    /// then ⌘⌫ removes the highlighted row (same rhythm as transform).
    ///   0–2: pick phase — highlight walks rows 0 → 1 → 2
    ///   3:   ⌫ pressed — row 2 marked for deletion
    ///   4–5: row 2 gone — ring shows 2 items left
    private func deleteAnimation(active: Int) -> some View {
        let snippets = [
            "Hello from Clipen",
            "https://clipen.app",
            "Made with care",
        ]
        let inPickPhase  = active <= 2
        let pickIndex    = min(active, 2)
        let deleteTarget = 2
        let marking      = active == 3
        let removed      = active >= 4

        return ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceHi)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.border, lineWidth: 1))
            HStack(spacing: 10) {
                animatedKey("⌘", isPressed: true)
                animatedKey("V", isPressed: inPickPhase)
                Text("→")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.textDim)
                animatedKey("⌫", isPressed: marking)
                Spacer()
                deleteRowIllustration(
                    snippets:    snippets,
                    pickIndex:   inPickPhase ? pickIndex : deleteTarget,
                    deleteIndex: deleteTarget,
                    marking:     marking,
                    removed:     removed,
                    showDone:    active == 5
                )
            }
            .padding(.horizontal, 18)
        }
        .frame(height: 140)
        .animation(.easeInOut(duration: 0.35), value: active)
    }

    // MARK: Reusable illustration pieces

    private func animatedKey(_ label: String, isPressed: Bool) -> some View {
        Text(label)
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundColor(isPressed ? .white : .textPri)
            .frame(width: 56, height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isPressed ? Color.accent : Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isPressed ? Color.accent : Color.border, lineWidth: 1.5)
            )
            .shadow(color: isPressed ? Color.accent.opacity(0.4) : .clear, radius: 8, y: 2)
            .offset(y: isPressed ? 2 : 0)
            .animation(.easeOut(duration: 0.2), value: isPressed)
    }

    private func popupIllustration(active: Bool, selectedIndex: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<3) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == selectedIndex ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: 14, height: 5)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.textDim.opacity(i == selectedIndex ? 0.9 : 0.3))
                        .frame(width: 70, height: 5)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    i == selectedIndex ? Color.accentDim : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }
        }
        .padding(10)
        .background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .opacity(active ? 1 : 0.3)
        .scaleEffect(active ? 1 : 0.92)
        .animation(.spring(response: 0.35), value: active)
        .animation(.easeInOut(duration: 0.3), value: selectedIndex)
    }

    private func pasteIllustration() -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.accent)
            Text("Pasted!")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 8))
        .transition(.scale.combined(with: .opacity))
    }

    /// Three-row popup with the currently picked row highlighted and showing
    /// `rowText`. When `transformLabel` is non-nil we're in the X phase and
    /// show a small badge announcing which transform was applied.
    private func transformRowIllustration(pickIndex: Int,
                                          rowText: String,
                                          transformLabel: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<3) { i in
                let isPicked = i == pickIndex
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isPicked ? Color.accent : Color.textDim.opacity(0.4))
                        .frame(width: 12, height: 5)
                    if isPicked {
                        Text(rowText)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 130, alignment: .leading)
                            .animation(.easeInOut(duration: 0.25), value: rowText)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.textDim.opacity(0.3))
                            .frame(width: 90, height: 5)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    isPicked ? Color.accentDim : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4)
                )
            }

            if let label = transformLabel {
                HStack(spacing: 4) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.accent)
                    Text(label)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.accent)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.accentDim, in: Capsule())
                .overlay(Capsule().stroke(Color.accent.opacity(0.4), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.25), value: label)
            }
        }
        .padding(10)
        .background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
    }

    /// Three-row popup: during pick phase the highlight walks with ⌘V; during
    /// delete phase the picked row turns red, then disappears.
    private func deleteRowIllustration(snippets: [String],
                                       pickIndex: Int,
                                       deleteIndex: Int,
                                       marking: Bool,
                                       removed: Bool,
                                       showDone: Bool) -> some View {
        let visibleIndices: [Int] = removed ? [0, 1] : [0, 1, 2]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(visibleIndices, id: \.self) { i in
                let isPicked   = !removed && i == pickIndex
                let isDeleting = !removed && marking && i == deleteIndex
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isDeleting ? Color.red.opacity(0.9)
                              : (isPicked ? Color.accent : Color.textDim.opacity(0.4)))
                        .frame(width: 12, height: 5)
                    if isPicked || (removed && i < snippets.count) {
                        Text(snippets[i])
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(isDeleting ? .red.opacity(0.85) : .textPri)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 130, alignment: .leading)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.textDim.opacity(0.3))
                            .frame(width: 90, height: 5)
                    }
                    if isDeleting {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    isDeleting ? Color.red.opacity(0.15)
                               : (isPicked ? Color.accentDim : Color.clear),
                    in: RoundedRectangle(cornerRadius: 4)
                )
                .opacity(isDeleting ? 0.7 : 1)
                .scaleEffect(isDeleting ? 0.96 : 1)
            }

            if showDone {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.red.opacity(0.9))
                    Text("Deleted")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.red.opacity(0.9))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Color.red.opacity(0.35), lineWidth: 1))
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(10)
        .background(Color.bg, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.border, lineWidth: 1))
        .animation(.easeInOut(duration: 0.3), value: pickIndex)
        .animation(.easeInOut(duration: 0.3), value: marking)
        .animation(.easeInOut(duration: 0.3), value: removed)
    }

    // MARK: Tick loop

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            tick &+= 1
        }
        RunLoop.main.add(tickTimer!, forMode: .common)
    }

    private func stopTick() {
        tickTimer?.invalidate(); tickTimer = nil
    }
}


// MARK: - Safe subscript
extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
