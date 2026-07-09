import SwiftUI
import AppKit
import Combine

// MARK: - Interaction demos
//
// Every popup gesture the Settings "INTERACTIONS" list teaches, each paired
// with a scripted animation that plays in the INTERACTION PREVIEW stage.
// The scripts are a SwiftUI port of the clipen_interactions.html reference:
// key caps press, a mock popup panel opens, items cycle/select/mark, side
// panels (preview / transforms) appear, and a green result line lands.

enum InteractionDemo: String, CaseIterable, Identifiable {
    case cycle, pinnedOpen, multiPaste, search, category
    case spacePreview, pinPreview, transform, moveToFront, delete, reverseCycle

    var id: String { rawValue }

    /// Short key label shown in the interactions list (left column).
    var keyLabel: String {
        switch self {
        case .cycle:        return "⌘ V"
        case .pinnedOpen:   return "V"
        case .multiPaste:   return "V ⌘V"
        case .search:       return "F"
        case .category:     return "1–9"
        case .spacePreview: return "SPACE"
        case .pinPreview:   return "SPACE ×2"
        case .transform:    return "X"
        case .moveToFront:  return "C"
        case .delete:       return "⌫"
        case .reverseCycle: return "⇧ + V"
        }
    }

    var title: String {
        switch self {
        case .cycle:        return "Hold ⌘ + V"
        case .pinnedOpen:   return "Hold V"
        case .multiPaste:   return "Multi Paste"
        case .search:       return "Search"
        case .category:     return "Category Switch"
        case .spacePreview: return "Preview"
        case .pinPreview:   return "Pin Preview"
        case .transform:    return "Transform"
        case .moveToFront:  return "Move to Front"
        case .delete:       return "Delete"
        case .reverseCycle: return "Reverse Cycle"
        }
    }

    /// Two-line explanation under the stage (mirrors the mockup's copy).
    var caption: String {
        switch self {
        case .cycle:        return "Hold ⌘ and tap V to open the history popup.\nRelease ⌘ to paste the selected item."
        case .pinnedOpen:   return "HOLD V on the first press — the popup opens pinned.\nReleasing ⌘ won't close it; click ✕ to dismiss."
        case .multiPaste:   return "Hold V on an item to mark it, keep cycling and marking.\nRelease ⌘ to paste all marked items in order."
        case .search:       return "Tap F while the popup is open to enter search mode.\nType to filter the list by contents."
        case .category:     return "Tap 1–9 while the popup is open.\nJumps straight to that category filter."
        case .spacePreview: return "Tap Space to preview the highlighted item full-size.\nTap Space again to close the preview."
        case .pinPreview:   return "Double-tap Space on the highlighted item.\nSends it to the floating Reference panel."
        case .transform:    return "Tap X to open transforms, tap again to cycle them.\nRelease ⌘ to paste the transformed result."
        case .moveToFront:  return "Tap C on the highlighted item.\nMoves it to the front of the ring."
        case .delete:       return "Tap ⌫ on the highlighted item.\nRemoves it from the ring."
        case .reverseCycle: return "Hold ⌘ and tap ⇧V.\nCycles to the previous item instead of the next."
        }
    }

    /// Key caps shown large on the idle stage before Play is pressed.
    var heroKeys: [LabKey] {
        switch self {
        case .cycle:        return [.cmd, .v]
        case .pinnedOpen:   return [.v]
        case .multiPaste:   return [.cmd, .v]
        case .search:       return [.cmd, .f]
        case .category:     return [.cmd, .one]
        case .spacePreview: return [.cmd, .space]
        case .pinPreview:   return [.cmd, .space]
        case .transform:    return [.cmd, .x]
        case .moveToFront:  return [.cmd, .c]
        case .delete:       return [.cmd, .backspace]
        case .reverseCycle: return [.cmd, .shift, .v]
        }
    }
}

// MARK: - Key caps

enum LabKey: String, Identifiable, Hashable {
    case cmd, v, x, f, c, shift, space, backspace, one

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cmd:       return "⌘"
        case .v:         return "V"
        case .x:         return "X"
        case .f:         return "F"
        case .c:         return "C"
        case .shift:     return "⇧"
        case .space:     return "SPACE"
        case .backspace: return "⌫"
        case .one:       return "1"
        }
    }

    var isWide: Bool { self == .space }
}

// MARK: - Animation controller

/// Drives the interaction stage. Scripts run as a cancellable Task; every
/// visual bit of the stage is a @Published so SwiftUI animates the change.
@MainActor
final class InteractionLabController: ObservableObject {

    struct LabItem: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var mark: Int? = nil
    }

    static func defaultItems() -> [LabItem] {
        [LabItem(title: "History item 1"),
         LabItem(title: "History item 2"),
         LabItem(title: "History item 3")]
    }

    @Published var selectedDemo: InteractionDemo = .cycle
    @Published var isPlaying = false

    // Key caps
    @Published var pressedKeys: Set<LabKey> = []
    @Published var stageKeys: [LabKey] = [.cmd, .v]
    @Published var showNumberRow = false
    @Published var pressedNumber: Int? = nil

    // Mock popup panel
    @Published var panelVisible = false
    @Published var items: [LabItem] = InteractionLabController.defaultItems()
    @Published var selectedIndex = 0
    @Published var showCloseButton = false
    @Published var searchActive = false
    @Published var activeTab = 0

    // Side panels
    @Published var previewVisible = false
    @Published var transformVisible = false
    @Published var activeTransform: Int? = nil
    @Published var transformLabels = ["Capitalize", "Small Case", "Base64"]

    // Text under the stage
    @Published var resultText: String? = nil

    private var task: Task<Void, Never>? = nil
    private let tabNames = ["Recents", "Image", "URL"]

    func select(_ demo: InteractionDemo) {
        selectedDemo = demo
        play()
    }

    func play() {
        task?.cancel()
        resetStage()
        let demo = selectedDemo
        stageKeys = demo.heroKeys
        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(demo)
            } catch {
                // Cancelled mid-script — resetStage already ran for the new play.
            }
            if !Task.isCancelled {
                self.isPlaying = false
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        resetStage()
        isPlaying = false
    }

    private func resetStage() {
        pressedKeys = []
        showNumberRow = false
        pressedNumber = nil
        panelVisible = false
        items = Self.defaultItems()
        selectedIndex = 0
        showCloseButton = false
        searchActive = false
        activeTab = 0
        previewVisible = false
        transformVisible = false
        activeTransform = nil
        transformLabels = ["Capitalize", "Small Case", "Base64"]
        resultText = nil
    }

    // MARK: Script plumbing

    private func pause(_ ms: UInt64) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
        try Task.checkCancellation()
    }

    private func press(_ key: LabKey) {
        withAnimation(.easeOut(duration: 0.1)) { _ = pressedKeys.insert(key) }
    }

    private func release(_ key: LabKey) {
        withAnimation(.easeOut(duration: 0.1)) { _ = pressedKeys.remove(key) }
    }

    private func tap(_ key: LabKey, hold: UInt64 = 200) async throws {
        press(key)
        try await pause(hold)
        release(key)
    }

    private func showPanel(_ visible: Bool) {
        withAnimation(.easeOut(duration: 0.25)) { panelVisible = visible }
    }

    private func selectItem(_ index: Int) {
        withAnimation(.easeOut(duration: 0.15)) { selectedIndex = index }
    }

    private func finish(_ text: String) {
        withAnimation(.easeOut(duration: 0.25)) { resultText = text }
    }

    // MARK: Scripts (ported from clipen_interactions.html)

    private func run(_ demo: InteractionDemo) async throws {
        switch demo {
        case .cycle:         try await runCycle()
        case .pinnedOpen:    try await runPinnedOpen()
        case .multiPaste:    try await runMultiPaste()
        case .search:        try await runSearch()
        case .category:      try await runCategory()
        case .spacePreview:  try await runSpacePreview()
        case .pinPreview:    try await runPinPreview()
        case .transform:     try await runTransform()
        case .moveToFront:   try await runMoveToFront()
        case .delete:        try await runDelete()
        case .reverseCycle:  try await runReverseCycle()
        }
    }

    private func runCycle() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        var idx = 0
        for _ in 0..<2 {
            try await tap(.v)
            idx = (idx + 1) % items.count
            selectItem(idx)
            try await pause(450)
        }
        try await pause(300)
        release(.cmd)
        showPanel(false)
        finish("Pasted “\(items[idx].title)”")
    }

    private func runPinnedOpen() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        press(.v)
        try await pause(650)
        withAnimation(.easeOut(duration: 0.2)) { showCloseButton = true }
        try await pause(500)
        release(.v)
        try await pause(700)
        release(.cmd)
        // Pinned: releasing ⌘ does NOT close the panel.
        finish("Popup stays pinned — click ✕ to close")
        try await pause(1600)
        showPanel(false)
        withAnimation(.easeOut(duration: 0.2)) { showCloseButton = false }
    }

    private func runMultiPaste() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        // Hold V — mark item 1
        press(.v)
        try await pause(600)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[0].mark = 1 }
        try await pause(450)
        try await tap(.v)
        selectItem(1)
        try await pause(350)
        try await tap(.v)
        selectItem(2)
        try await pause(350)
        // Hold V — mark item 3
        press(.v)
        try await pause(600)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[2].mark = 2 }
        try await pause(800)
        release(.cmd)
        showPanel(false)
        finish("2 items pasted together, in mark order")
    }

    private func runSearch() async throws {
        stageKeys = [.cmd, .v, .f]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        try await tap(.f)
        withAnimation(.easeOut(duration: 0.15)) { searchActive = true }
        try await pause(1400)
        finish("Search active — type to filter")
        try await pause(1100)
        release(.cmd)
        showPanel(false)
    }

    private func runCategory() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(300)
        withAnimation(.easeOut(duration: 0.2)) { showNumberRow = true }
        try await pause(300)
        var last = 0
        for i in 0..<3 {
            withAnimation(.easeOut(duration: 0.1)) { pressedNumber = i + 1 }
            try await pause(200)
            withAnimation(.easeOut(duration: 0.1)) { pressedNumber = nil }
            withAnimation(.easeOut(duration: 0.15)) {
                activeTab = i
                for idx in items.indices {
                    items[idx].title = "\(tabNames[i]) item \(idx + 1)"
                    items[idx].mark = nil
                }
                selectedIndex = 0
            }
            last = i
            try await pause(600)
        }
        finish("Switched to “\(tabNames[last])” — first item auto-selected")
        try await pause(900)
        release(.cmd)
        showPanel(false)
        withAnimation(.easeOut(duration: 0.2)) { showNumberRow = false }
    }

    private func runSpacePreview() async throws {
        stageKeys = [.cmd, .v, .space]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(550)
        try await tap(.space)
        withAnimation(.easeOut(duration: 0.25)) { previewVisible = true }
        try await pause(1100)
        try await tap(.space)
        withAnimation(.easeOut(duration: 0.25)) { previewVisible = false }
        try await pause(450)
        release(.cmd)
        showPanel(false)
        finish("Previewed “\(items[1].title)” — nothing pasted")
    }

    private func runPinPreview() async throws {
        stageKeys = [.cmd, .v, .space]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(450)
        try await tap(.space, hold: 140)
        withAnimation(.easeOut(duration: 0.2)) { previewVisible = true }
        try await pause(140)
        try await tap(.space, hold: 140)
        withAnimation(.easeOut(duration: 0.2)) { previewVisible = false }
        showPanel(false)
        release(.cmd)
        finish("Pinned “\(items[1].title)” to the Reference panel")
    }

    private func runTransform() async throws {
        stageKeys = [.cmd, .v, .x]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(400)
        try await tap(.x)
        withAnimation(.easeOut(duration: 0.25)) { transformVisible = true }
        var chosen = 0
        for i in 0..<3 {
            try await tap(.x)
            withAnimation(.easeOut(duration: 0.12)) { activeTransform = i }
            chosen = i
            try await pause(400)
        }
        release(.cmd)
        let applied = transformLabels[chosen]
        withAnimation { transformLabels[chosen] = "Applying \(applied)…" }
        try await pause(550)
        showPanel(false)
        withAnimation(.easeOut(duration: 0.25)) { transformVisible = false }
        finish("\(applied) applied → pasted")
    }

    private func runMoveToFront() async throws {
        stageKeys = [.cmd, .v, .c]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(500)
        try await tap(.c)
        withAnimation(.easeOut(duration: 0.3)) {
            let moved = items.remove(at: 1)
            items.insert(moved, at: 0)
            selectedIndex = 0
        }
        try await pause(1000)
        release(.cmd)
        showPanel(false)
        finish("“\(items[0].title)” moved to the front of the ring")
    }

    private func runDelete() async throws {
        stageKeys = [.cmd, .v, .backspace]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(500)
        let removedTitle = items[1].title
        try await tap(.backspace)
        _ = withAnimation(.easeOut(duration: 0.25)) {
            items.remove(at: 1)
        }
        selectItem(min(1, items.count - 1))
        try await pause(1000)
        release(.cmd)
        showPanel(false)
        finish("“\(removedTitle)” removed from the ring")
    }

    private func runReverseCycle() async throws {
        stageKeys = [.cmd, .shift, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        press(.shift)
        try await pause(200)
        var idx = 0
        for _ in 0..<2 {
            try await tap(.v)
            idx = (idx - 1 + items.count) % items.count
            selectItem(idx)
            try await pause(450)
        }
        release(.shift)
        try await pause(300)
        release(.cmd)
        showPanel(false)
        finish("Pasted “\(items[idx].title)”")
    }
}

// MARK: - Stage views

/// One key cap — pressed state sinks it and lights it blue, same as the
/// HTML reference's .key.pressed.
struct LabKeyCapView: View {
    let key: LabKey
    let pressed: Bool
    var size: CGFloat = 44

    var body: some View {
        Text(key.symbol)
            .font(.system(size: key.isWide ? size * 0.26 : size * 0.42, weight: .semibold))
            .foregroundColor(pressed ? .white : .textPri)
            .frame(width: key.isWide ? size * 2.2 : size, height: size)
            .background(pressed ? Color.accent : Color.surfaceHi,
                        in: RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.border, lineWidth: 1))
            .shadow(color: .black.opacity(pressed ? 0 : 0.45), radius: 0, y: pressed ? 0 : 4)
            .offset(y: pressed ? 4 : 0)
    }
}

/// The mock popup panel — search row, category tabs, three history items,
/// optional ✕ pin-close button and per-item mark badges.
private struct LabMockPanel: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(spacing: 0) {
            // Search row
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                if lab.searchActive {
                    Text("Type to search")
                        .font(.system(size: 9))
                    Rectangle().fill(Color.white).frame(width: 1, height: 10)
                        .opacity(0.9)
                } else {
                    Text("Press F to search").font(.system(size: 9))
                }
                Spacer()
            }
            .foregroundColor(lab.searchActive ? .textPri : .textDim)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(lab.searchActive ? Color.accent.opacity(0.10) : Color.clear)

            Divider().background(Color.border)

            // Category tabs
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    Text("⌘\(i + 1) \(["Recents", "Image", "URL"][i])")
                        .font(.system(size: 8, weight: lab.activeTab == i ? .bold : .regular))
                        .foregroundColor(lab.activeTab == i ? .white : .textDim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(lab.activeTab == i ? Color.accent : Color.surfaceHi,
                                    in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider().background(Color.border)

            // Items
            VStack(spacing: 3) {
                ForEach(Array(lab.items.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        Text(item.title)
                            .font(.system(size: 10, weight: idx == lab.selectedIndex ? .semibold : .regular))
                            .foregroundColor(idx == lab.selectedIndex ? .white : .textSec)
                        Spacer()
                        if let mark = item.mark {
                            Text("\(mark)")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Color.green, in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(idx == lab.selectedIndex ? Color.accent : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(5)

            Spacer(minLength: 0)
        }
        .frame(width: 190, height: 158)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.border, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            if lab.showCloseButton {
                Text("✕")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 20, height: 20)
                    .background(Color.accent, in: Circle())
                    .offset(x: -8, y: -8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
    }
}

/// Preview / transform side panel that slides in beside the mock popup.
private struct LabSidePanel: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if lab.previewVisible {
                Text("Preview").font(.system(size: 10, weight: .bold)).foregroundColor(.textPri)
                Text("Full text content of the selected item.")
                    .font(.system(size: 9)).foregroundColor(.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                ForEach(Array(lab.transformLabels.enumerated()), id: \.offset) { idx, label in
                    Text(label)
                        .font(.system(size: 9, weight: lab.activeTransform == idx ? .semibold : .regular))
                        .foregroundColor(lab.activeTransform == idx ? .white : .textDim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(lab.activeTransform == idx ? Color.accent : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(width: 120, height: 158, alignment: .topLeading)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 16, y: 8)
        .transition(.opacity.combined(with: .move(edge: .leading)))
    }
}

/// The whole INTERACTION PREVIEW stage: mock panel area, key caps row,
/// title + caption + result, and the Play Animation button.
struct InteractionLabStage: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(spacing: 16) {
            // Stage area — mock panel while playing, hero key caps while idle.
            ZStack {
                if lab.panelVisible {
                    HStack(spacing: 12) {
                        LabMockPanel(lab: lab)
                        if lab.previewVisible || lab.transformVisible {
                            LabSidePanel(lab: lab)
                        }
                    }
                    .transition(.opacity)
                } else {
                    HStack(spacing: 14) {
                        ForEach(Array(lab.selectedDemo.heroKeys.enumerated()), id: \.offset) { i, key in
                            if i > 0 {
                                Text("+").font(.system(size: 20, weight: .medium)).foregroundColor(.textSec)
                            }
                            LabKeyCapView(key: key,
                                          pressed: lab.pressedKeys.contains(key),
                                          size: 60)
                        }
                    }
                    .transition(.opacity)
                }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)

            // Animated key row — only while a script is running with the
            // panel up (idle state already shows the hero caps above).
            if lab.panelVisible {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        ForEach(lab.stageKeys) { key in
                            LabKeyCapView(key: key, pressed: lab.pressedKeys.contains(key), size: 32)
                        }
                    }
                    if lab.showNumberRow {
                        HStack(spacing: 5) {
                            ForEach(1...9, id: \.self) { n in
                                Text("\(n)")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(lab.pressedNumber == n ? .white : (n <= 3 ? .textSec : .textDim))
                                    .frame(width: 20, height: 20)
                                    .background(lab.pressedNumber == n ? Color.accent : Color.surfaceHi,
                                                in: RoundedRectangle(cornerRadius: 5))
                                    .opacity(n <= 3 ? 1 : 0.4)
                                    .offset(y: lab.pressedNumber == n ? 2 : 0)
                            }
                        }
                        .transition(.opacity)
                    }
                }
            }

            // Title + caption
            VStack(spacing: 8) {
                Text(lab.selectedDemo.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.textPri)
                Text(lab.selectedDemo.caption)
                    .font(.system(size: 11))
                    .foregroundColor(.textSec)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Result line
            Text(lab.resultText.map { "→ \($0)" } ?? " ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .opacity(lab.resultText == nil ? 0 : 1)

            Button {
                lab.play()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    Text("Play Animation").font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Color.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Redesigned Settings screen

/// Full Settings view, matching the numbered two-column mockup:
///   left column:  01 RING SIZE · 02 APP SETTINGS · 04 INTERACTIONS
///   right column: 03 MAIN BEHAVIOUR · 05 INTERACTION PREVIEW
/// Footer: version + links + Reset to Defaults.
struct ClipenSettingsView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared
    @StateObject private var lab        = InteractionLabController()

    @Binding var showResetConfirm: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 30) {
                Text("SETTINGS")
                    .font(.system(size: 20, weight: .bold))
                    .tracking(6)
                    .foregroundColor(.textPri)
                    .padding(.top, 6)

                HStack(alignment: .top, spacing: 40) {
                    // Left column
                    VStack(alignment: .leading, spacing: 34) {
                        ringSizeSection
                        appSettingsSection
                        interactionsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    // Right column
                    VStack(alignment: .leading, spacing: 34) {
                        mainBehaviourSection
                        labSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
        .onDisappear { lab.stop() }
    }

    // MARK: Section chrome

    private func sectionHeader(_ number: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.textDim)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(3)
                .foregroundColor(.textSec)
        }
    }

    /// Numbered row prefix, mockup-style ("01", "02", …).
    private func rowNumber(_ n: Int) -> some View {
        Text(String(format: "%02d", n))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.textDim)
            .frame(width: 18, alignment: .leading)
    }

    private func behaviourRow(_ n: Int, icon: String, _ label: String,
                              isOn: Binding<Bool>) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text(label).font(.system(size: 13)).foregroundColor(.textPri)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Color.surfaceHi.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
    }

    // MARK: 01 — Ring size

    private var ringSizeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("01", "RING SIZE")

            HStack(alignment: .center, spacing: 18) {
                Text("\(manager.maxItems)")
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.textPri)
                    .contentTransition(.numericText())

                // Vertical stepper — chevron up / value / chevron down.
                VStack(spacing: 2) {
                    Button {
                        withAnimation { manager.setRingSize(manager.maxItems + 5) }
                    } label: {
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                            .foregroundColor(.textSec).frame(width: 34, height: 24)
                    }
                    .buttonStyle(.plain)
                    Text("\(manager.maxItems)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.accent)
                    Button {
                        withAnimation { manager.setRingSize(manager.maxItems - 5) }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                            .foregroundColor(.textSec).frame(width: 34, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.border, lineWidth: 1))

                Spacer()
            }

            Text("Maximum items in ring")
                .font(.system(size: 11)).foregroundColor(.textSec)

            VStack(spacing: 5) {
                Slider(value: Binding(get: { Double(manager.maxItems) },
                                      set: { manager.setRingSize(Int(($0 / 5).rounded() * 5)) }),
                       in: 10...500)
                    .tint(.accent)
                HStack {
                    Text("10").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                    Spacer()
                    Text("\(manager.maxItems)").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(.textSec)
                    Spacer()
                    Text("500").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                }
            }
        }
    }

    // MARK: 02 — App settings

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("02", "APP SETTINGS")

            HStack(spacing: 10) {
                Image(systemName: "power").font(.system(size: 11)).foregroundColor(.accent).frame(width: 16)
                Text("Launch at Login").font(.system(size: 13)).foregroundColor(.textPri)
                Spacer()
                Toggle("", isOn: Binding(get: { manager.launchAtLogin },
                                        set: { manager.launchAtLogin = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.surfaceHi.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))

            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(.accent).frame(width: 16)
                Text("Check for Updates").font(.system(size: 13)).foregroundColor(.textPri)
                Spacer()
                Button("Check now") { AppDelegate.shared?.checkForUpdates() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.surfaceHi.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
    }

    // MARK: 03 — Main behaviour

    private var mainBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("03", "MAIN BEHAVIOUR")

            behaviourRow(1, icon: "hand.tap", "Popup on second tap",
                         isOn: Binding(get: { manager.openOnSecondTap },
                                       set: { manager.openOnSecondTap = $0 }))

            // Open delay — nested under 01, disabled while second-tap mode is on.
            HStack(spacing: 10) {
                Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                Text("Open delay").font(.system(size: 12)).foregroundColor(.textSec)
                Slider(value: Binding(get: { manager.firstOpenDelay * 1000 },
                                     set: { manager.firstOpenDelay = ($0 / 5).rounded() * 5 / 1000 }),
                       in: 0...1000)
                    .tint(.accent)
                Text(manager.openOnSecondTap ? "—"
                     : manager.firstOpenDelay == 0 ? "Off"
                     : String(format: "%.0f ms", manager.firstOpenDelay * 1000))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.textSec)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
            .padding(.leading, 28)
            .disabled(manager.openOnSecondTap)
            .opacity(manager.openOnSecondTap ? 0.4 : 1)

            behaviourRow(2, icon: "arrow.right.to.line", "Advance after marking",
                         isOn: Binding(get: { manager.advanceAfterMark },
                                       set: { manager.advanceAfterMark = $0 }))
            behaviourRow(3, icon: "eye", "Always show preview",
                         isOn: $manager.alwaysShowItemPreview)
            behaviourRow(4, icon: "clock.arrow.circlepath", "Remember last position",
                         isOn: $manager.rememberLastSelection)
            behaviourRow(5, icon: "arrow.triangle.2.circlepath", "Auto updates",
                         isOn: Binding(
                            get: { AppDelegate.shared?.automaticallyChecksForUpdates ?? true },
                            set: { value in
                                AppDelegate.shared?.automaticallyChecksForUpdates = value
                                if !value { AppDelegate.shared?.automaticallyDownloadsUpdates = false }
                            }))
            behaviourRow(6, icon: "timer", "Auto-dismiss popup",
                         isOn: $manager.autoDismissEnabled)

            // Auto-dismiss interval — nested under 06.
            HStack(spacing: 10) {
                Image(systemName: "hourglass.bottomhalf.filled").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                Text("Dismiss after").font(.system(size: 12)).foregroundColor(.textSec)
                Slider(value: Binding(get: { manager.autoDismissSeconds },
                                     set: { manager.autoDismissSeconds = ($0 / 10).rounded() * 10 }),
                       in: 10...600)
                    .tint(.accent)
                Text(String(format: "%.0f s", manager.autoDismissSeconds))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.textSec)
                    .frame(width: 52, alignment: .trailing)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border.opacity(0.6), lineWidth: 1))
            .padding(.leading, 28)
            .disabled(!manager.autoDismissEnabled)
            .opacity(manager.autoDismissEnabled ? 1 : 0.4)
        }
    }

    // MARK: 04 — Interactions list (clickable — plays the lab animation)

    private static let interactionDemos: [InteractionDemo] = [
        .cycle, .pinnedOpen, .multiPaste, .search, .category,
        .spacePreview, .pinPreview, .transform, .moveToFront, .delete, .reverseCycle
    ]

    private var interactionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("04", "INTERACTIONS")

            VStack(spacing: 1) {
                ForEach(Self.interactionDemos) { demo in
                    interactionRow(demo)
                }
            }
            .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func interactionRow(_ demo: InteractionDemo) -> some View {
        let isActive = lab.selectedDemo == demo
        return Button {
            lab.select(demo)
        } label: {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(isActive ? Color.accent : Color.clear)
                    .frame(width: 3)
                Text(demo.keyLabel)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? .accent : .textSec)
                    .frame(width: 74, alignment: .leading)
                Text(demo.title)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .textPri : .textSec)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.textDim)
            }
            .padding(.trailing, 14).padding(.vertical, 10)
            .background(isActive ? Color.accent.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: 05 — Interaction preview (the lab)

    private var labSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("05", "INTERACTION PREVIEW")
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.accent).frame(width: 6, height: 6)
                    Text("LIVE PREVIEW")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(.textSec)
                }
            }

            InteractionLabStage(lab: lab)
                .padding(18)
                .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
    }

    // MARK: Footer

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider().background(Color.border)
            HStack(spacing: 18) {
                Text("Clipen \(Self.appVersionString)  ·  Built by Vamshi Krishna Pinni")
                    .font(.system(size: 11)).foregroundColor(.textDim)
                Spacer()
                footerLink("Website", "https://clipen.lovable.app")
                footerLink("Privacy", "https://clipen.lovable.app/privacy.html")
                footerLink("Support", "https://clipen.lovable.app/support.html")
                Button {
                    AppDelegate.shared?.checkForUpdates()
                } label: {
                    HStack(spacing: 4) {
                        Text("Check updates")
                        Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9))
                    }
                    .font(.system(size: 11)).foregroundColor(.textSec)
                }
                .buttonStyle(.plain)
                Button {
                    showResetConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        Text("Reset to Defaults")
                        Image(systemName: "arrow.counterclockwise").font(.system(size: 9))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#FF5555"))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 16)
        }
    }

    private func footerLink(_ title: String, _ urlString: String) -> some View {
        Button(title) { NSWorkspace.shared.open(URL(string: urlString)!) }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundColor(.textSec)
    }
}
