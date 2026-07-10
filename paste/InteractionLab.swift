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

    /// Runs the selected demo's script on a continuous loop — no manual
    /// "Play" trigger needed; picking a row in the interactions list is
    /// itself the trigger, and the animation keeps repeating until a
    /// different row is picked or the stage disappears.
    func play() {
        task?.cancel()
        resetStage()
        let demo = selectedDemo
        stageKeys = demo.heroKeys
        isPlaying = true
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.run(demo)
                    try await self.pause(900)
                } catch {
                    return // cancelled mid-script — a new play()/stop() already took over
                }
                guard !Task.isCancelled else { return }
                self.resetStage()
                self.stageKeys = demo.heroKeys
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
/// caption + result. No manual play trigger and no duplicate title — the
/// selected row in the interactions list already names the gesture, and
/// the animation itself starts immediately and loops continuously.
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

            // Caption — the row already selected in the list on the left
            // names the gesture, so this only needs to explain it.
            Text(lab.selectedDemo.caption)
                .font(.system(size: 11))
                .foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Result line
            Text(lab.resultText.map { "→ \($0)" } ?? " ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .opacity(lab.resultText == nil ? 0 : 1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            guard !lab.isPlaying else { return }
            lab.play()
        }
    }
}

/// Reports a view's natural height up to an enclosing row's PreferenceKey,
/// so the row can stretch its shorter column/card to match — used to make
/// the settings rows and the interactions/lab cards end on the same
/// bottom line instead of drifting to whatever height their own content needs.
private extension View {
    func measured<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.height)
        })
    }
}

// MARK: - Redesigned Settings screen

/// Full Settings view, matching the numbered mockup, laid out as two
/// height-matched ROWS rather than two independent-height columns:
///   row 1: (01 RING SIZE + 02 APP SETTINGS)  |  03 MAIN BEHAVIOUR
///   row 2: 04 INTERACTIONS                   |  05 INTERACTION PREVIEW
/// Both pairs end on the same bottom line — row 2 only ever starts once
/// row 1 (settings) has fully finished, never interleaved with it.
/// Footer: version + links + Reset to Defaults.
struct ClipenSettingsView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared
    @StateObject private var lab        = InteractionLabController()

    @Binding var showResetConfirm: Bool

    @State private var row1Height: CGFloat = 0
    @State private var row2Height: CGFloat = 0

    private struct Row1HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
    private struct Row2HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        // Footer OUTSIDE the scroll view — pinned to the window bottom the
        // same way the Dashboard pins its own footer bar; only the content
        // above it scrolls/changes when switching tabs.
        VStack(spacing: 0) {
            settingsScrollContent
            Divider().background(Color.border)
            // Same paddings as the Dashboard's footerBar — the pinned
            // footer must be the SAME height on both tabs, not jump when
            // switching between them.
            footer
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .onDisappear { lab.stop() }
    }

    private var settingsScrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            // No "SETTINGS" heading here — the Dashboard | Settings switcher
            // in the top toolbar already shows Settings selected, so a
            // second, bigger label repeating it was pure redundancy.
            VStack(alignment: .leading, spacing: 30) {
                // Row 1 — Ring Size + App Settings (left) vs Main Behaviour
                // (right), stretched to a shared height so both end flush.
                HStack(alignment: .top, spacing: 40) {
                    VStack(alignment: .leading, spacing: 34) {
                        ringSizeSection
                        appSettingsSection
                    }
                    .frame(maxWidth: .infinity, minHeight: row1Height, alignment: .topLeading)
                    .measured(Row1HeightKey.self)

                    mainBehaviourSection
                        .frame(maxWidth: .infinity, minHeight: row1Height, alignment: .topLeading)
                        .measured(Row1HeightKey.self)
                }
                .onPreferenceChange(Row1HeightKey.self) { row1Height = $0 }

                // Row 2 — Interactions list vs Interaction Preview stage,
                // only begins once row 1 is fully finished. Unlike row 1,
                // both sides here have a visible bordered card, so the
                // CARDS themselves (not just their outer frames) are
                // stretched to match — see interactionsSection/labSection.
                HStack(alignment: .top, spacing: 40) {
                    interactionsSection.frame(maxWidth: .infinity, alignment: .topLeading)
                    labSection.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onPreferenceChange(Row2HeightKey.self) { row2Height = $0 }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
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

    /// One continuous card wrapping several rows, divided by thin
    /// hairlines. Sharp corners, no surrounding border — only a single
    /// left edge line marks the card.
    private func rowCard<C: View>(@ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .background(Color.surfaceHi.opacity(0.4))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.border).frame(width: 2)
            }
    }

    private func rowDivider(leading: CGFloat = 44) -> some View {
        Divider().background(Color.border).padding(.leading, leading)
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
        // More breathing room than the other cards — this list is read
        // top-to-bottom far more often than app settings/interactions, and
        // 12pt vertical made adjacent toggles feel cramped.
        .padding(.horizontal, 14).padding(.vertical, 16)
        // Flexible: when the card is stretched to the shared row height,
        // every row grows by the SAME share, so the whole card fills evenly
        // instead of the rows clustering at the top over a blank void.
        .frame(maxHeight: .infinity)
    }

    /// A nested slider row belonging to the toggle directly above it (e.g.
    /// "Open delay" under "Popup on second tap") — same category, same
    /// setting, so no divider separates them and the icon/label columns
    /// line up exactly with the parent row's. Text reads white while the
    /// control is enabled; dim only when disabled.
    private func nestedSliderRow(icon: String, label: String, valueText: String,
                                 disabled: Bool, slider: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 10))
                .foregroundColor(disabled ? .textDim : .textSec).frame(width: 16)
            Text(label).font(.system(size: 11))
                .foregroundColor(disabled ? .textDim : .textPri)
            slider()
            Text(valueText)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(disabled ? .textDim : .textPri)
                .frame(width: 48, alignment: .trailing)
        }
        // 14 (card inset) + 18 (row number) + 10 (spacing) = 42 — puts this
        // row's icon in the same column as the parent toggle's icon, and
        // therefore its label exactly where the parent's label starts.
        .padding(.leading, 42).padding(.trailing, 14).padding(.vertical, 9)
        // Same equal-share stretching as behaviourRow — see its comment.
        .frame(maxHeight: .infinity)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: 01 — Ring size

    /// Square minus/plus stepper button flanking the ring-size slider —
    /// replaces the old vertical chevron-stepper box entirely.
    private func ringStepButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(.textSec)
                .frame(width: 30, height: 30)
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var ringSizeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("01", "RING SIZE")

            // The big counter — horizontally CENTERED in the section's own
            // stack (not pinned to the left edge), caption centered with it.
            Text("\(manager.maxItems)")
                .font(.system(size: 64, weight: .black))
                .foregroundColor(.textPri)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Maximum items in ring")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .frame(maxWidth: .infinity, alignment: .center)

            // Minus / slider / plus, all one row — no separate stepper box.
            HStack(spacing: 10) {
                ringStepButton("minus") {
                    withAnimation { manager.setRingSize(manager.maxItems - 5) }
                }
                Slider(value: Binding(get: { Double(manager.maxItems) },
                                      set: { manager.setRingSize(Int(($0 / 5).rounded() * 5)) }),
                       in: 10...500)
                    .tint(.accent)
                ringStepButton("plus") {
                    withAnimation { manager.setRingSize(manager.maxItems + 5) }
                }
            }

            // Min / current / max — current value centered in the
            // horizontal space (not pinned to the left).
            HStack {
                Text("10").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                Spacer()
                Text("\(manager.maxItems)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.accent)
                    .contentTransition(.numericText())
                Spacer()
                Text("500").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
            }
        }
    }

    // MARK: 02 — App settings

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("02", "APP SETTINGS")

            rowCard {
                // Every row is maxHeight-flexible: when the card stretches
                // to the shared row-1 height, the extra space distributes
                // EQUALLY across the rows so the card fills edge to edge —
                // no blank void pooling at the bottom.
                HStack(spacing: 10) {
                    Image(systemName: "power").font(.system(size: 11)).foregroundColor(.accent).frame(width: 16)
                    Text("Launch at Login").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(get: { manager.launchAtLogin },
                                            set: { manager.launchAtLogin = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

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
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                // Auto updates lives here (App Settings), not in Main
                // Behaviour — it's an app-level preference, not a popup
                // interaction behaviour.
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Auto updates").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { AppDelegate.shared?.automaticallyChecksForUpdates ?? true },
                        set: { value in
                            AppDelegate.shared?.automaticallyChecksForUpdates = value
                            if !value { AppDelegate.shared?.automaticallyDownloadsUpdates = false }
                        }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: 03 — Main behaviour

    private var mainBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("03", "MAIN BEHAVIOUR")

            rowCard {
                behaviourRow(1, icon: "hand.tap", "Popup on second tap",
                             isOn: Binding(get: { manager.openOnSecondTap },
                                           set: { manager.openOnSecondTap = $0 }))

                // No divider before the nested slider — it belongs to the
                // toggle above (same setting), not a separate row.

                // Open delay — nested under 01, disabled while second-tap mode is on.
                nestedSliderRow(
                    icon: "hourglass", label: "Open delay",
                    valueText: manager.openOnSecondTap ? "—"
                        : manager.firstOpenDelay == 0 ? "Off"
                        : String(format: "%.0f ms", manager.firstOpenDelay * 1000),
                    disabled: manager.openOnSecondTap
                ) {
                    Slider(value: Binding(get: { manager.firstOpenDelay * 1000 },
                                         set: { manager.firstOpenDelay = ($0 / 5).rounded() * 5 / 1000 }),
                           in: 0...1000)
                        .tint(.accent)
                }

                rowDivider()
                behaviourRow(2, icon: "arrow.right.to.line", "Advance after marking",
                             isOn: Binding(get: { manager.advanceAfterMark },
                                           set: { manager.advanceAfterMark = $0 }))
                rowDivider()
                behaviourRow(3, icon: "eye", "Always show preview",
                             isOn: $manager.alwaysShowItemPreview)
                rowDivider()
                behaviourRow(4, icon: "clock.arrow.circlepath", "Remember last position",
                             isOn: $manager.rememberLastSelection)
                rowDivider()
                behaviourRow(5, icon: "timer", "Auto-dismiss popup",
                             isOn: $manager.autoDismissEnabled)

                // Same as Open delay: the interval slider is part of the
                // Auto-dismiss setting itself — no divider between them.
                nestedSliderRow(
                    icon: "hourglass.bottomhalf.filled", label: "Dismiss after",
                    valueText: String(format: "%.0f s", manager.autoDismissSeconds),
                    disabled: !manager.autoDismissEnabled
                ) {
                    Slider(value: Binding(get: { manager.autoDismissSeconds },
                                         set: { manager.autoDismissSeconds = ($0 / 10).rounded() * 10 }),
                           in: 10...600)
                        .tint(.accent)
                }
            }
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

            // minHeight applied BEFORE background/clipShape so the card's
            // own fill and border actually stretch to row2Height, instead
            // of just leaving invisible blank space below a shorter box.
            VStack(spacing: 1) {
                ForEach(Self.interactionDemos) { demo in
                    interactionRow(demo)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: row2Height, alignment: .top)
            .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .measured(Row2HeightKey.self)
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

            // Same before-background minHeight trick as interactionsSection
            // — this card's fill/border stretch to match the interactions
            // list's card exactly, not just its outer frame.
            InteractionLabStage(lab: lab)
                .padding(18)
                .frame(minHeight: row2Height, alignment: .top)
                .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
                .measured(Row2HeightKey.self)
        }
    }

    // MARK: Footer

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    /// Pinned to the window bottom by `body` (divider + padding applied
    /// there) — this is just the row content, like the Dashboard's footerBar.
    private var footer: some View {
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
    }

    private func footerLink(_ title: String, _ urlString: String) -> some View {
        Button(title) { NSWorkspace.shared.open(URL(string: urlString)!) }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundColor(.textSec)
    }
}
