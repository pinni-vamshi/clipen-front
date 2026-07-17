import SwiftUI
import AppKit
import Combine

enum InteractionDemo: String, CaseIterable, Identifiable {
    case cycle, pinnedOpen, multiPaste, search, category
    case spacePreview, pinPreview, transform, moveToFront, delete, reverseCycle
    case cyclePinned, pinItem

    var id: String { rawValue }

    var keyLabel: String {
        switch self {
        case .cycle:        return "⌘ + tap V"
        case .pinnedOpen:   return "⌘ + hold V"
        case .multiPaste:   return "hold V"
        case .search:       return "tap F"
        case .category:     return "⌘ 1–9"
        case .spacePreview: return "tap ␣"
        case .pinPreview:   return "tap ␣ ×2"
        case .transform:    return "tap X"
        case .moveToFront:  return "tap C"
        case .delete:       return "tap ⌫"
        case .reverseCycle: return "⇧ + tap V"
        case .cyclePinned:  return "tap P"
        case .pinItem:      return "hold P"
        }
    }

    var title: String {
        switch self {
        case .cycle:        return "Open / Next Item"
        case .pinnedOpen:   return "Open Pinned"
        case .multiPaste:   return "Mark for Multi-Paste"
        case .search:       return "Search"
        case .category:     return "Category Switch"
        case .spacePreview: return "Preview"
        case .pinPreview:   return "Refer (Pin Preview)"
        case .transform:    return "Transform"
        case .moveToFront:  return "Move to Front"
        case .delete:       return "Delete"
        case .reverseCycle: return "Previous Item"
        case .cyclePinned:  return "Cycle Pinned"
        case .pinItem:      return "Pin / Unpin"
        }
    }

    var caption: String {
        switch self {
        case .cycle:        return "Hold ⌘ and tap V to open the popup; each tap moves to the next item.\nRelease ⌘ to paste the highlighted item."
        case .pinnedOpen:   return "HOLD V on the very first press — the popup opens pinned.\nReleasing ⌘ keeps it open; click ✕ or press Esc to close."
        case .multiPaste:   return "With the popup open, HOLD V to mark the highlighted item.\nRelease ⌘ to paste every marked item, in marking order."
        case .search:       return "Tap F while the popup is open to enter search mode.\nType to filter the list by contents."
        case .category:     return "Hold ⌘ and tap 1–9 to jump to a category.\n⌘1 is Recents; ⌘2 onward are your categories."
        case .spacePreview: return "Tap Space to preview the highlighted item full-size.\nTap Space again to close — nothing is pasted."
        case .pinPreview:   return "Double-tap Space on the highlighted item.\nSends it to the Reference panel — the popup closes, the preview stays."
        case .transform:    return "Tap X to open the tools, tap X again to cycle them.\n⇧X steps back · hold X closes · release ⌘ pastes the result."
        case .moveToFront:  return "Tap C to move the highlighted item to the front of the ring.\nThe selection stays put — keep tapping C to promote a run of items."
        case .delete:       return "Tap ⌫ to remove the highlighted item from the ring.\nThe next item slides into its place."
        case .reverseCycle: return "Hold ⌘ and tap ⇧V.\nMoves to the previous item instead of the next."
        case .cyclePinned:  return "Tap P to jump between PINNED items only, wrapping at the end.\nUnpinned items in between are skipped entirely."
        case .pinItem:      return "HOLD P to pin the highlighted item (or unpin it if already pinned).\nUp to 5 items can be pinned at once."
        }
    }

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
        case .cyclePinned:  return [.cmd, .v, .p]
        case .pinItem:      return [.cmd, .v, .p]
        }
    }
}

enum LabKey: String, Identifiable, Hashable {
    case cmd, v, x, f, c, b, p, shift, space, backspace, one

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .cmd:       return "⌘"
        case .v:         return "V"
        case .x:         return "X"
        case .f:         return "F"
        case .c:         return "C"
        case .b:         return "B"
        case .p:         return "P"
        case .shift:     return "⇧"
        case .space:     return "SPACE"
        case .backspace: return "⌫"
        case .one:       return "1"
        }
    }

    var isWide: Bool { self == .space }
}

@MainActor
final class InteractionLabController: ObservableObject {

    struct LabItem: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var mark: Int? = nil
        var pin: Bool = false
    }

    static func defaultItems() -> [LabItem] {
        [LabItem(title: "History item 1"),
         LabItem(title: "History item 2"),
         LabItem(title: "History item 3")]
    }

    @Published var selectedDemo: InteractionDemo = .cycle
    @Published var isPlaying = false

    @Published var pressedKeys: Set<LabKey> = []
    @Published var stageKeys: [LabKey] = [.cmd, .v]
    @Published var showNumberRow = false
    @Published var pressedNumber: Int? = nil

    @Published var panelVisible = false
    @Published var items: [LabItem] = InteractionLabController.defaultItems()
    @Published var selectedIndex = 0
    @Published var showCloseButton = false
    @Published var searchActive = false
    @Published var activeTab = 0

    @Published var previewVisible = false
    @Published var transformVisible = false
    @Published var activeTransform: Int? = nil
    @Published var transformLabels = ["Capitalize", "Small Case", "Base64"]

    @Published var resultText: String? = nil
    @Published var instruction: String? = nil

    private var task: Task<Void, Never>? = nil
    private let tabNames = ["Recents", "Image"]

    var currentCaption: String {
        if selectedDemo == .reverseCycle, ClipboardManager.shared.reverseCycleUsesB {
            return "Hold ⌘ and tap B to move to the previous item.\nHOLD B to mark the item and step back in one go."
        }
        return selectedDemo.caption
    }

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
            while !Task.isCancelled {
                do {
                    try await self.run(demo)
                    try await self.pause(900)
                } catch {
                    return
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
        instruction = nil
    }

    private func hint(_ text: String?) {
        withAnimation(.easeOut(duration: 0.2)) { instruction = text }
    }

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
        case .cyclePinned:   try await runCyclePinned()
        case .pinItem:       try await runPinItem()
        }
    }

    private func runCycle() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        hint("Release ⌘ to paste")
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
        hint(nil)
        finish("Pasted “\(items[idx].title)”")
    }

    private func runPinnedOpen() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        hint("Double tap to paste")
        showPanel(true)
        press(.v)
        try await pause(600)
        withAnimation(.easeOut(duration: 0.2)) { showCloseButton = true }
        try await pause(600)
        release(.v)
        try await pause(1000)
        release(.cmd)
        finish("Item marked and pinned to tray")
        try await pause(1600)
    }

    private func runMultiPaste() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        hint("Release ⌘ to paste")
        showPanel(true)
        try await tap(.v)
        try await pause(400)
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
        press(.v)
        try await pause(600)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[2].mark = 2 }
        try await pause(1000)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("2 items pasted together")
    }

    private func runSearch() async throws {
        stageKeys = [.cmd, .v, .f]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        hint("Type to search")
        try await tap(.f)
        withAnimation(.easeOut(duration: 0.15)) { searchActive = true }
        try await pause(1800)
        finish("Search active — type to filter")
        try await pause(1200)
        release(.cmd)
        showPanel(false)
        hint(nil)
    }

    private func runCategory() async throws {
        stageKeys = [.cmd, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        hint("Press 1–2 to switch category")
        withAnimation(.easeOut(duration: 0.2)) { showNumberRow = true }
        try await pause(200)
        var last = 0
        for i in 0..<2 {
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
        try await pause(1000)
        release(.cmd)
        showPanel(false)
        hint(nil)
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
        try await pause(500)
        release(.cmd)
        showPanel(false)
        finish("Previewed “\(items[1].title)”, no paste")
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
        showPanel(false)
        release(.cmd)
        finish("Pinned “\(items[1].title)” to tray")
        try await pause(1400)
    }

    private func runTransform() async throws {
        stageKeys = [.cmd, .v, .x]
        press(.cmd)
        try await pause(400)
        hint("Release ⌘ to paste")
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(400)
        try await tap(.x)
        withAnimation(.easeOut(duration: 0.25)) { transformVisible = true }
        try await pause(500)
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
        hint(nil)
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
            selectedIndex = 2
        }
        try await pause(1000)
        release(.cmd)
        showPanel(false)
        finish("“\(items[0].title)” moved to front — selection stays on the next item")
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
        let usesB = ClipboardManager.shared.reverseCycleUsesB
        stageKeys = usesB ? [.cmd, .v, .b] : [.cmd, .shift, .v]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(400)
        if !usesB {
            press(.shift)
            try await pause(200)
        }
        var idx = 0
        for _ in 0..<2 {
            try await tap(usesB ? .b : .v)
            idx = (idx - 1 + items.count) % items.count
            selectItem(idx)
            try await pause(450)
        }
        if !usesB {
            release(.shift)
        }
        try await pause(300)
        release(.cmd)
        showPanel(false)
        finish("Pasted “\(items[idx].title)”")
    }

    private func runCyclePinned() async throws {
        stageKeys = [.cmd, .v, .p]
        items[0].pin = true
        items[2].pin = true
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        selectItem(0)
        try await pause(500)
        hint("Tap P to jump between pins")
        try await tap(.p)
        try await pause(500)
        try await tap(.p)
        selectItem(2)
        try await pause(500)
        try await tap(.p)
        selectItem(0)
        try await pause(800)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("Cycled between 2 pinned items — the unpinned one was skipped")
    }

    private func runPinItem() async throws {
        stageKeys = [.cmd, .v, .p]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(350)
        try await tap(.v)
        selectItem(1)
        try await pause(450)
        hint("Hold P to pin")
        press(.p)
        try await pause(650)
        withAnimation(.easeOut(duration: 0.2)) { items[1].pin = true }
        try await pause(400)
        release(.p)
        try await pause(700)
        hint("Hold P again to unpin")
        press(.p)
        try await pause(650)
        withAnimation(.easeOut(duration: 0.2)) { items[1].pin = false }
        try await pause(400)
        release(.p)
        try await pause(700)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("Hold P pins the highlighted item — hold again to unpin")
    }
}

struct LabKeyCapView: View {
    let key: LabKey
    let pressed: Bool
    var size: CGFloat = 44

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(pressed ? Color.accent : Color.surfaceHi)
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .stroke(Color.border, lineWidth: 1))
            .frame(width: key.isWide ? size * 2.2 : size, height: size)
            .shadow(color: .black.opacity(pressed ? 0 : 0.45), radius: 0, y: pressed ? 0 : 4)
            .overlay(
                Text(key.symbol)
                    .font(.system(size: key.isWide ? size * 0.26 : size * 0.42, weight: .semibold))
                    .foregroundColor(pressed ? .white : .textPri)
            )
            .offset(y: pressed ? 4 : 0)
    }
}

private struct LabMockPanel: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 9))
                if lab.searchActive {
                    Text("Type to search")
                        .font(.system(size: 9))
                    Rectangle().fill(Color.textPri).frame(width: 1, height: 10)
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

            HStack(spacing: 5) {
                ForEach(0..<2, id: \.self) { i in
                    Text("⌘\(i + 1) \(["Recents", "Image"][i])")
                        .font(.system(size: 8, weight: lab.activeTab == i ? .bold : .regular))
                        .foregroundColor(lab.activeTab == i ? .white : .textDim)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(lab.activeTab == i ? Color.accent : Color.surfaceHi,
                                    in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            Divider().background(Color.border)

            VStack(spacing: 3) {
                ForEach(Array(lab.items.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        Text(item.title)
                            .font(.system(size: 10, weight: idx == lab.selectedIndex ? .semibold : .regular))
                            .foregroundColor(idx == lab.selectedIndex ? .white : .textSec)
                        Spacer()
                        if item.pin {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 15, height: 15)
                                .background(Color.blue, in: Circle())
                        }
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

struct InteractionLabStage: View {
    @ObservedObject var lab: InteractionLabController

    var body: some View {
        VStack(spacing: 14) {
            Text(lab.instruction ?? " ")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Color.white.opacity(0.16), in: Capsule())
                .opacity(lab.instruction == nil ? 0 : 1)
                .frame(height: 20)

            ZStack {
                LabMockPanel(lab: lab)
                    .opacity(lab.panelVisible ? 1 : 0)
                    .offset(x: (lab.previewVisible || lab.transformVisible) ? -66 : 0)
                    .animation(.easeOut(duration: 0.25),
                               value: lab.previewVisible || lab.transformVisible)
                LabSidePanel(lab: lab)
                    .opacity((lab.previewVisible || lab.transformVisible) ? 1 : 0)
                    .offset(x: 101)
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)

            Text(lab.resultText.map { "→ \($0)" } ?? " ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.green)
                .opacity(lab.resultText == nil ? 0 : 1)
                .frame(height: 16)

            Text(LocalizedStringKey(lab.currentCaption))
                .font(.system(size: 11))
                .foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .frame(height: 30)

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    ForEach(lab.stageKeys) { key in
                        LabKeyCapView(key: key, pressed: lab.pressedKeys.contains(key), size: 54)
                    }
                }
                .frame(height: 58)
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
                .opacity(lab.showNumberRow ? 1 : 0)
            }
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .onAppear {
            guard !lab.isPlaying else { return }
            lab.play()
        }
    }
}

private extension View {
    func measured<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.height)
        })
    }
}

struct SettingsRow2HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct InteractionPreviewCard: View {
    let selectedDemo: InteractionDemo
    let replayToken: Int
    let minHeight: CGFloat

    @StateObject private var lab = InteractionLabController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Text("INTERACTION PREVIEW").font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundColor(.textSec)
                }
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(Color.accent).frame(width: 6, height: 6)
                    Text("LIVE PREVIEW")
                        .font(.system(size: 9, weight: .semibold)).tracking(1.5).foregroundColor(.textSec)
                }
            }

            InteractionLabStage(lab: lab)
                .padding(18)
                .frame(minHeight: minHeight, alignment: .center)
                .background(Color.surfaceHi.opacity(0.3), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.border, lineWidth: 1))
                .measured(SettingsRow2HeightKey.self)
        }
        .onAppear { lab.select(selectedDemo) }
        .onChange(of: replayToken) { _, _ in lab.select(selectedDemo) }
        .onDisappear { lab.stop() }
    }
}

struct ClipenSettingsView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared

    @State private var selectedDemo: InteractionDemo = .cycle
    @State private var labReplayToken = 0

    @Binding var showResetConfirm: Bool

    @State private var row1Height: CGFloat = 0
    @State private var row2Height: CGFloat = 0
    @State private var showReverseKeyEditor = false
    @State private var showMarkSpeedEditor = false
    @State private var showReferSpeedEditor = false
    @State private var showPinnedOpenSpeedEditor = false
    @State private var showPinHoldSpeedEditor = false
    @State private var showAutoPreviewPicker = false
    @State private var showRememberTimeoutPicker = false
    @State private var showAutoDismissPicker = false
    @State private var showOpenDelayPicker = false
    @State private var showPinPositionPicker = false

    private enum FeedbackSendState { case idle, sent, failed }
    @State private var feedbackText = ""
    @State private var feedbackSending = false
    @State private var feedbackSendState: FeedbackSendState = .idle
    @State private var pendingLanguage: AppLanguage?
    @State private var showLanguagePicker = false

    private struct Row1HeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsScrollContent
            Divider().background(Color.border)
            footer
                .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .onAppear { manager.refreshLaunchAtLoginStatus() }
    }

    private var settingsScrollContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 44) {
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

                HStack(alignment: .top, spacing: 40) {
                    interactionsSection.frame(maxWidth: .infinity, alignment: .topLeading)
                    InteractionPreviewCard(selectedDemo: selectedDemo,
                                           replayToken: labReplayToken,
                                           minHeight: row2Height)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .onPreferenceChange(SettingsRow2HeightKey.self) { row2Height = $0 }

                feedbackSection
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
        }
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("05", "FEEDBACK")

            rowCard(border: .allSides) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Send a message straight to the developer.")
                        .font(.system(size: 11)).foregroundColor(.textSec)

                    TextEditor(text: $feedbackText)
                        .font(.system(size: 12))
                        .scrollContentBackground(.hidden)
                        .frame(height: 80)
                        .padding(6)
                        .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))

                    HStack {
                        if feedbackSendState == .failed {
                            Text("Couldn't send — check your connection and try again.")
                                .font(.system(size: 10)).foregroundColor(.red.opacity(0.8))
                        }
                        Spacer()
                        feedbackReplyHint
                        Button {
                            sendFeedback()
                        } label: {
                            Text(feedbackSending ? "Sending…" : "Send")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .disabled(feedbackSending
                                  || feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(14)
            }
        }
    }

    private var feedbackReplyHint: some View {
        HStack(spacing: 4) {
            Text("You can see replies on the")
                .font(.system(size: 11)).foregroundColor(.textPri.opacity(0.85))
            Button {
                if let url = URL(string: "https://www.instagram.com/clipen.official") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text("Clipen Instagram page")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func sendFeedback() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !feedbackSending else { return }
        feedbackSending = true
        feedbackSendState = .idle
        TrackingService.shared.sendFeedback(trimmed) { success in
            feedbackSending = false
            if success {
                feedbackText = ""
                feedbackSendState = .sent
            } else {
                feedbackSendState = .failed
            }
        }
    }

    private func sectionHeader(_ number: String, _ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .tracking(3)
            .foregroundColor(.textSec)
    }

    private func rowNumber(_ n: Int) -> some View {
        Text(String(format: "%02d", n))
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(.textDim)
            .frame(width: 18, alignment: .leading)
    }

    private enum RowCardBorder { case leadingLine, allSides }

    private func rowCard<C: View>(border: RowCardBorder = .leadingLine,
                                  @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .overlay {
                if case .allSides = border {
                    Rectangle().stroke(Color.border, lineWidth: 1)
                }
            }
            .overlay(alignment: .leading) {
                if case .leadingLine = border {
                    Rectangle().fill(Color.border).frame(width: 2)
                }
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
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private func autoPreviewRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "eye").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Always show preview").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                showAutoPreviewPicker.toggle()
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help("Choose which content types auto-show preview")
            .popover(isPresented: $showAutoPreviewPicker, arrowEdge: .bottom) {
                autoPreviewPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var autoPreviewPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Auto-preview for").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                Spacer()
                Button(manager.autoPreviewTypes.count == AutoPreviewContentType.allCases.count ? "Clear" : "Select All") {
                    if manager.autoPreviewTypes.count == AutoPreviewContentType.allCases.count {
                        manager.autoPreviewTypes = []
                    } else {
                        manager.autoPreviewTypes = Set(AutoPreviewContentType.allCases)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(.accent)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(AutoPreviewContentType.allCases) { type in
                let isOn = manager.autoPreviewTypes.contains(type)
                Button {
                    if isOn { manager.autoPreviewTypes.remove(type) } else { manager.autoPreviewTypes.insert(type) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: type.sfIcon).font(.system(size: 11)).foregroundColor(.textSec).frame(width: 16)
                        Text(type.label).font(.system(size: 12)).foregroundColor(.textPri)
                        Spacer()
                        if isOn {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 6)
        }
        .frame(width: 200)
        .padding(.bottom, 4)
    }

    private var languagePicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Language").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppLanguage.supported) { lang in
                        let isOn = lang.code == manager.appLanguageCode
                        Button {
                            showLanguagePicker = false
                            guard !isOn else { return }
                            pendingLanguage = lang
                        } label: {
                            HStack(spacing: 8) {
                                Text(lang.displayName).font(.system(size: 12)).foregroundColor(.textPri)
                                Spacer()
                                if isOn {
                                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
            Spacer(minLength: 6)
        }
        .frame(width: 200)
        .padding(.bottom, 4)
    }

    private static let rememberTimeoutPresets = [1, 3, 5, 10, 15, 30, 60]

    private func rememberLastPositionRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Remember last position").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                showRememberTimeoutPicker.toggle()
            } label: {
                let minutes = manager.rememberLastPositionTimeoutMinutes
                let label = minutes == 0 ? "∞"
                    : (minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")
                HStack(spacing: 4) {
                    Image(systemName: minutes == 0 ? "infinity" : "timer").font(.system(size: 9, weight: .semibold))
                    Text(label).font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(manager.rememberLastSelection ? .textPri : .textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(manager.rememberLastSelection ? Color.surfaceHi : Color.surfaceHi.opacity(0.4),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!manager.rememberLastSelection)
            .opacity(manager.rememberLastSelection ? 1 : 0.4)
            .help("How long a remembered position stays valid before reopening starts at the top again")
            .popover(isPresented: $showRememberTimeoutPicker, arrowEdge: .bottom) {
                rememberTimeoutPicker
            }
            Toggle("", isOn: $manager.rememberLastSelection).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static let openDelayPresets: [(label: String, seconds: Double)] =
        [("Fast", 0.10), ("Medium", 0.25), ("Slow", 0.50)]

    private func openDelayRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "hourglass").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Open delay").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                showOpenDelayPicker.toggle()
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showOpenDelayPicker, arrowEdge: .bottom) {
                openDelayPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var openDelayPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: $manager.openOnSecondTap) {
                Text("Open on second V click").font(.system(size: 12)).foregroundColor(.textPri)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            .padding(.horizontal, 12).padding(.vertical, 10)

            Divider().padding(.horizontal, 8)

            Text("Delay speed").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            openDelayChoice(label: "Off",
                            isOn: !manager.openOnSecondTap && manager.firstOpenDelay == 0) {
                manager.firstOpenDelay = 0
                manager.openOnSecondTap = false
            }

            ForEach(Self.openDelayPresets, id: \.label) { preset in
                openDelayChoice(label: preset.label,
                                isOn: !manager.openOnSecondTap && manager.firstOpenDelay == preset.seconds) {
                    manager.firstOpenDelay = preset.seconds
                    manager.openOnSecondTap = false
                }
            }
        }
        .padding(.vertical, 6)
        .frame(width: 200)
    }

    private func openDelayChoice(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundColor(.textPri)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pinPositionRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "pin.fill").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Pin to top").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                showPinPositionPicker.toggle()
            } label: {
                Text("Configure")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accent)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPinPositionPicker, arrowEdge: .bottom) {
                pinPositionPicker
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private var pinPositionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Starting position").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)

            HStack(spacing: 14) {
                pinCounterButton("minus", enabled: manager.pinStartPosition > 1) {
                    manager.pinStartPosition = max(1, manager.pinStartPosition - 1)
                }
                Text("\(manager.pinStartPosition)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.textPri)
                    .frame(minWidth: 28)
                pinCounterButton("plus", enabled: manager.pinStartPosition < ClipboardManager.maxPinnedItems) {
                    manager.pinStartPosition = min(ClipboardManager.maxPinnedItems, manager.pinStartPosition + 1)
                }
            }
            .frame(maxWidth: .infinity)

            Text("At most \(ClipboardManager.maxPinnedItems) items can be pinned at once.")
                .font(.system(size: 10)).foregroundColor(.textSec)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 200)
    }

    private func pinCounterButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(enabled ? .textPri : .textDim)
                .frame(width: 30, height: 30)
                .background(Color.surfaceHi.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private static let autoDismissPresets: [Double] = [10, 30, 60, 180, 300, 600, 1800]

    private func autoDismissRow(_ n: Int) -> some View {
        HStack(spacing: 10) {
            rowNumber(n)
            Image(systemName: "timer").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
            Text("Auto-dismiss popup").font(.system(size: 13)).foregroundColor(.textPri)
            Spacer(minLength: 8)
            Button {
                showAutoDismissPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hourglass.bottomhalf.filled").font(.system(size: 9, weight: .semibold))
                    Text(Self.autoDismissLabel(manager.autoDismissSeconds))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(manager.autoDismissEnabled ? .textPri : .textDim)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(manager.autoDismissEnabled ? Color.surfaceHi : Color.surfaceHi.opacity(0.4),
                            in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!manager.autoDismissEnabled)
            .opacity(manager.autoDismissEnabled ? 1 : 0.4)
            .help("How long the popup sits idle before it auto-dismisses")
            .popover(isPresented: $showAutoDismissPicker, arrowEdge: .bottom) {
                autoDismissPicker
            }
            Toggle("", isOn: $manager.autoDismissEnabled).toggleStyle(.switch).controlSize(.mini).tint(.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static func autoDismissLabel(_ seconds: Double) -> String {
        seconds >= 60 ? "\(Int(seconds / 60))m" : "\(Int(seconds))s"
    }

    private var autoDismissPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Dismiss after").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            ForEach(Self.autoDismissPresets, id: \.self) { seconds in
                rememberTimeoutRow(
                    label: seconds >= 60 ? "\(Int(seconds / 60)) min\(seconds == 60 ? "" : "s")" : "\(Int(seconds)) sec",
                    isOn: manager.autoDismissSeconds == seconds
                ) {
                    manager.autoDismissSeconds = seconds
                    showAutoDismissPicker = false
                }
            }
            Spacer(minLength: 6)
        }
        .frame(width: 160)
        .padding(.bottom, 4)
    }

    private var rememberTimeoutPicker: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reopen within").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)

            rememberTimeoutRow(label: "Until turned off", isOn: manager.rememberLastPositionTimeoutMinutes == 0) {
                manager.rememberLastPositionTimeoutMinutes = 0
                showRememberTimeoutPicker = false
            }

            Divider().padding(.horizontal, 8).padding(.vertical, 2)

            ForEach(Self.rememberTimeoutPresets, id: \.self) { minutes in
                rememberTimeoutRow(label: minutes >= 60 ? "\(minutes / 60) hour" : "\(minutes) min\(minutes == 1 ? "" : "s")",
                                   isOn: manager.rememberLastPositionTimeoutMinutes == minutes) {
                    manager.rememberLastPositionTimeoutMinutes = minutes
                    showRememberTimeoutPicker = false
                }
            }
            Spacer(minLength: 6)
        }
        .frame(width: 160)
        .padding(.bottom, 4)
    }

    private func rememberTimeoutRow(label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12)).foregroundColor(.textPri)
                Spacer()
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.accent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

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

            Text("\(manager.maxItems)")
                .font(.system(size: 64, weight: .black))
                .foregroundColor(.textPri)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, alignment: .center)

            Text("Maximum items in ring")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .frame(maxWidth: .infinity, alignment: .center)

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

            HStack {
                Text("10").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
                Spacer()
                Text("500").font(.system(size: 9, design: .monospaced)).foregroundColor(.textDim)
            }
        }
    }

    private var appSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("02", "APP SETTINGS")

            rowCard(border: .allSides) {
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

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "testtube.2").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Beta updates").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { AppDelegate.shared?.betaUpdatesEnabled ?? false },
                        set: { AppDelegate.shared?.betaUpdatesEnabled = $0 }))
                        .toggleStyle(.switch).controlSize(.mini).tint(.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "globe").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Language").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Button {
                        showLanguagePicker.toggle()
                    } label: {
                        Text(AppLanguage.current(for: manager.appLanguageCode).displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showLanguagePicker, arrowEdge: .bottom) {
                        languagePicker
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
        }
        .alert("Restart Clipen to switch language?",
               isPresented: Binding(get: { pendingLanguage != nil }, set: { if !$0 { pendingLanguage = nil } })) {
            Button("Restart Now", role: .destructive) {
                if let lang = pendingLanguage {
                    manager.appLanguageCode = lang.code
                    AppLanguage.apply(lang.code)
                }
                pendingLanguage = nil
            }
            Button("Cancel", role: .cancel) { pendingLanguage = nil }
        } message: {
            Text("Clipen needs to restart to switch to \(pendingLanguage?.displayName ?? "").")
        }
    }

    private var mainBehaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("03", "MAIN BEHAVIOUR")

            rowCard {
                openDelayRow(1)

                rowDivider()
                behaviourRow(2, icon: "arrow.right.to.line", "Advance after marking",
                             isOn: Binding(get: { manager.advanceAfterMark },
                                           set: { manager.advanceAfterMark = $0 }))
                rowDivider()
                autoPreviewRow(3)
                rowDivider()
                rememberLastPositionRow(4)
                rowDivider()
                autoDismissRow(5)
                rowDivider()
                pinPositionRow(6)
                rowDivider()
                purePasteRow(7)
            }
        }
    }

    private func purePasteRow(_ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                rowNumber(n)
                Image(systemName: "textformat").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                Text("Pure paste").font(.system(size: 13)).foregroundColor(.textPri)
                Spacer()
                Toggle("", isOn: Binding(get: { manager.pastePlainTextByDefault },
                                          set: { manager.pastePlainTextByDefault = $0 }))
                    .toggleStyle(.switch).controlSize(.mini).tint(.accent)
            }
            Text(manager.pastePlainTextByDefault
                 ? "Paste with formatting is available via Transform (X)"
                 : "Paste without formatting is available via Transform (X)")
                .font(.system(size: 10))
                .foregroundColor(.textDim.opacity(0.6))
                .padding(.leading, 44)
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .frame(maxHeight: .infinity)
    }

    private static let interactionGroups: [[InteractionDemo]] = [
        [.cycle, .pinnedOpen],
        [.reverseCycle, .multiPaste],
        [.spacePreview, .pinPreview],
        [.transform, .search, .category, .moveToFront, .delete],
        [.cyclePinned, .pinItem],
    ]

    private var interactionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionHeader("04", "INTERACTIONS")

                Button {
                    manager.showPopupInteractionHints.toggle()
                } label: {
                    Text(manager.showPopupInteractionHints ? "Hide in popup" : "Show in popup")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.accent)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.accentDim, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.showPopupInteractionHints
                      ? "Hide the interaction hint strip at the top of the popup"
                      : "Show the interaction hint strip at the top of the popup")
            }

            VStack(spacing: 1) {
                ForEach(Array(Self.interactionGroups.enumerated()), id: \.offset) { groupIndex, group in
                    if groupIndex > 0 {
                        Divider().background(Color.border)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                    ForEach(group) { demo in
                        interactionRow(demo)
                        if demo == .reverseCycle && showReverseKeyEditor {
                            reverseKeyPicker
                        }
                        if demo == .multiPaste && showMarkSpeedEditor {
                            speedPicker(label: "Hold speed", selection: $manager.markHoldSpeed) {
                                playDemo(.multiPaste)
                            }
                        }
                        if demo == .pinPreview && showReferSpeedEditor {
                            speedPicker(label: "Double-tap speed", selection: $manager.spaceDoubleTapSpeed) {
                                playDemo(.pinPreview)
                            }
                        }
                        if demo == .pinnedOpen && showPinnedOpenSpeedEditor {
                            speedPicker(label: "Hold speed", selection: $manager.pinnedOpenHoldSpeed) {
                                playDemo(.pinnedOpen)
                            }
                        }
                        if demo == .pinItem && showPinHoldSpeedEditor {
                            speedPicker(label: "Hold speed", selection: $manager.pinHoldSpeed) {
                                playDemo(.pinItem)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(minHeight: row2Height, alignment: .top)
            .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .measured(SettingsRow2HeightKey.self)
        }
    }

    private func playDemo(_ demo: InteractionDemo) {
        selectedDemo = demo
        labReplayToken += 1
    }

    private func interactionRow(_ demo: InteractionDemo) -> some View {
        let isActive = selectedDemo == demo
        let keyLabel = (demo == .reverseCycle && manager.reverseCycleUsesB) ? "tap B" : demo.keyLabel
        return Button {
            playDemo(demo)
        } label: {
            HStack(spacing: 12) {
                Text(LocalizedStringKey(keyLabel))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(isActive ? .textPri : .textSec)
                    .frame(width: 90, alignment: .leading)
                Text(LocalizedStringKey(demo.title))
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? .textPri : .textSec)
                Spacer()
                if demo == .reverseCycle {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showReverseKeyEditor.toggle() }
                    } label: {
                        Image(systemName: showReverseKeyEditor ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(showReverseKeyEditor ? .accent : .textSec)
                    }
                    .buttonStyle(.plain)
                    .help("Choose the reverse key")
                }
                if demo == .multiPaste {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showMarkSpeedEditor.toggle() }
                    } label: {
                        Image(systemName: showMarkSpeedEditor ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(showMarkSpeedEditor ? .accent : .textSec)
                    }
                    .buttonStyle(.plain)
                    .help("Adjust hold speed")
                }
                if demo == .pinPreview {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showReferSpeedEditor.toggle() }
                    } label: {
                        Image(systemName: showReferSpeedEditor ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(showReferSpeedEditor ? .accent : .textSec)
                    }
                    .buttonStyle(.plain)
                    .help("Adjust double-tap speed")
                }
                if demo == .pinnedOpen {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showPinnedOpenSpeedEditor.toggle() }
                    } label: {
                        Image(systemName: showPinnedOpenSpeedEditor ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(showPinnedOpenSpeedEditor ? .accent : .textSec)
                    }
                    .buttonStyle(.plain)
                    .help("Adjust hold speed")
                }
                if demo == .pinItem {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showPinHoldSpeedEditor.toggle() }
                    } label: {
                        Image(systemName: showPinHoldSpeedEditor ? "pencil.circle.fill" : "pencil.circle")
                            .font(.system(size: 13))
                            .foregroundColor(showPinHoldSpeedEditor ? .accent : .textSec)
                    }
                    .buttonStyle(.plain)
                    .help("Adjust hold-to-pin speed")
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.textDim)
            }
            .padding(.leading, 14).padding(.trailing, 14).padding(.vertical, 10)
            .background(isActive ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var reverseKeyPicker: some View {
        HStack(spacing: 8) {
            Text("Reverse key")
                .font(.system(size: 10)).foregroundColor(.textDim)
            reverseKeyChoice("⇧ + V", usesB: false)
            reverseKeyChoice("B", usesB: true)
            Spacer()
        }
        .padding(.leading, 116).padding(.trailing, 14).padding(.vertical, 8)
    }

    private func reverseKeyChoice(_ label: String, usesB: Bool) -> some View {
        let selected = manager.reverseCycleUsesB == usesB
        return Button {
            manager.reverseCycleUsesB = usesB
            playDemo(.reverseCycle)
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(selected ? .white : .textSec)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accent : Color.surfaceHi,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func speedPicker(label: String, selection: Binding<GestureSpeed>,
                             onSelect: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10)).foregroundColor(.textDim)
            ForEach(GestureSpeed.allCases) { speed in
                speedChoice(speed, selection: selection, onSelect: onSelect)
            }
            Spacer()
        }
        .padding(.leading, 116).padding(.trailing, 14).padding(.vertical, 8)
    }

    private func speedChoice(_ speed: GestureSpeed, selection: Binding<GestureSpeed>,
                             onSelect: @escaping () -> Void) -> some View {
        let selected = selection.wrappedValue == speed
        return Button {
            selection.wrappedValue = speed
            onSelect()
        } label: {
            Text(speed.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(selected ? .white : .textSec)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(selected ? Color.accent : Color.surfaceHi,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private static var appVersionString: String {
        let info  = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"]            as? String ?? "?"
        return "v\(short) (\(build))"
    }

    private var footer: some View {
        HStack(spacing: 18) {
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
            }
            Spacer()
            footerLink("Website", "https://clipen.lovable.app")
            footerLink("Privacy", "https://clipen.lovable.app/privacy.html")
            footerLink("Support", "https://clipen.lovable.app/support.html")
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
