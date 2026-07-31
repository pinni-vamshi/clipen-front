import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

enum InteractionDemo: String, CaseIterable, Identifiable {
    case cycle, pinnedOpen, multiPaste, search, nextCategory
    case spacePreview, pinPreview, transform, moveToFront, delete, reverseCycle
    case cyclePinned, pinItem, group, collections
    // Tutorial-only demos — three distinct paste animations, one per element,
    // each with a progressively larger V-tap count (×1, ×2, ×3). Deliberately
    // NOT reusing `.cycle`: they teach "reach the Nth item with N taps" and are
    // wired only into the how-to-use flow, never the Settings interactions list.
    case pasteOne, pasteTwo, pasteThree

    var id: String { rawValue }

    var keyLabel: String {
        switch self {
        case .cycle:        return "⌘ + tap V"
        case .pinnedOpen:   return "⌘ + hold V"
        case .multiPaste:   return "hold V"
        case .search:       return "tap F"
        case .nextCategory: return "tap `"
        case .spacePreview: return "tap ␣"
        case .pinPreview:   return "tap ␣ ×2"
        case .transform:    return "tap X"
        case .moveToFront:  return "tap C"
        case .delete:       return "tap ⌫"
        case .reverseCycle: return "⇧ + tap V"
        case .cyclePinned:  return "tap P"
        case .pinItem:      return "hold P"
        case .group:        return "hold V → G"
        case .collections:  return "⌘ + V → 1 – 9"
        case .pasteOne:     return "⌘ + tap V"
        case .pasteTwo:     return "⌘ + V ×2"
        case .pasteThree:   return "⌘ + V ×3"
        }
    }

    var title: String {
        switch self {
        case .cycle:        return "Open / Next Item"
        case .pinnedOpen:   return "Open Pinned"
        case .multiPaste:   return "Mark for Multi-Paste"
        case .search:       return "Search"
        case .nextCategory: return "Next Category"
        case .spacePreview: return "Preview"
        case .pinPreview:   return "Refer (Pin Preview)"
        case .transform:    return "Transform"
        case .moveToFront:  return "Move to Front"
        case .delete:       return "Delete"
        case .reverseCycle: return "Previous Item"
        case .cyclePinned:  return "Cycle Pinned"
        case .pinItem:      return "Pin / Unpin"
        case .group:        return "Group Marked"
        case .collections:  return "Switch Collection"
        case .pasteOne:     return "Paste 1st Item"
        case .pasteTwo:     return "Paste 2nd Item"
        case .pasteThree:   return "Paste 3rd Item"
        }
    }

    var caption: String {
        switch self {
        case .cycle:        return "Hold ⌘ and tap V to open the popup; each tap moves to the next item.\nRelease ⌘ to paste the highlighted item."
        case .pinnedOpen:   return "HOLD V on the very first press — the popup opens pinned.\nReleasing ⌘ keeps it open; click ✕ or press Esc to close."
        case .multiPaste:   return "With the popup open, HOLD V to mark the highlighted item.\nRelease ⌘ to paste every marked item, in marking order."
        case .search:       return "Tap F while the popup is open to enter search mode.\nType to filter the list by contents."
        case .nextCategory: return "Tap ` to step to the next category one at a time.\nKeeps going through each category and wraps back to Recents."
        case .spacePreview: return "Tap Space to preview the highlighted item full-size.\nTap Space again to close — nothing is pasted."
        case .pinPreview:   return "Double-tap Space on the highlighted item.\nSends it to the Reference panel — the popup closes, the preview stays."
        case .transform:    return "Tap X to open the tools, tap X again to cycle them.\n⇧X steps back · hold X closes · release ⌘ pastes the result."
        case .moveToFront:  return "Tap C to move the highlighted item to the front of the ring.\nThe selection stays put — keep tapping C to promote a run of items."
        case .delete:       return "Tap ⌫ to remove the highlighted item from the ring.\nThe next item slides into its place."
        case .reverseCycle: return "Hold ⌘ and tap ⇧V.\nMoves to the previous item instead of the next."
        case .cyclePinned:  return "Tap P to jump between PINNED items only, wrapping at the end.\nUnpinned items in between are skipped entirely."
        case .pinItem:      return "HOLD P to pin the highlighted item (or unpin it if already pinned).\nUp to 5 items can be pinned at once."
        case .group:        return "Mark a few items (hold V on each), then tap G.\nThey fold into one group at the first-marked spot — paste, share or ungroup it as one."
        case .collections:  return "Hold ⌘ and tap V to open the ring, then press 1 for All — your whole clipboard — or 2 onward for each collection you created.\nThe ring switches to that view instantly."
        case .pasteOne:     return "Hold ⌘ and tap V once to land on the top item.\nRelease ⌘ to paste it."
        case .pasteTwo:     return "Hold ⌘ and tap V twice to reach the second item.\nRelease ⌘ to paste it."
        case .pasteThree:   return "Hold ⌘ and tap V three times to reach the third item.\nRelease ⌘ to paste it."
        }
    }

    var heroKeys: [LabKey] {
        switch self {
        case .cycle:        return [.cmd, .v]
        case .pinnedOpen:   return [.v]
        case .multiPaste:   return [.cmd, .v]
        case .search:       return [.cmd, .f]
        case .nextCategory: return [.cmd, .grave]
        case .spacePreview: return [.cmd, .space]
        case .pinPreview:   return [.cmd, .space]
        case .transform:    return [.cmd, .x]
        case .moveToFront:  return [.cmd, .c]
        case .delete:       return [.cmd, .backspace]
        case .reverseCycle: return [.cmd, .shift, .v]
        case .cyclePinned:  return [.cmd, .v, .p]
        case .pinItem:      return [.cmd, .v, .p]
        case .group:        return [.cmd, .v, .g]
        case .collections:  return [.cmd, .v, .one, .two]
        case .pasteOne, .pasteTwo, .pasteThree: return [.cmd, .v]
        }
    }
}

enum LabKey: String, Identifiable, Hashable {
    case cmd, v, x, f, c, b, p, g, shift, space, backspace, one, two, grave

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
        case .g:         return "G"
        case .shift:     return "⇧"
        case .space:     return "SPACE"
        case .backspace: return "⌫"
        case .one:       return "1"
        case .two:       return "2"
        case .grave:     return "`"
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
    @Published var instruction: LocalizedStringKey? = nil

    /// Drives the small "tap counter" pips shown during the paste demos:
    /// `pasteTapTarget` is how many V taps this element needs (0 = not a paste
    /// demo, hide the pips), `pasteTapDone` is how many have played so far.
    @Published var pasteTapTarget = 0
    @Published var pasteTapDone = 0

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
        pasteTapTarget = 0
        pasteTapDone = 0
    }

    private func hint(_ text: LocalizedStringKey?) {
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

    private func finish(_ key: String.LocalizationValue, _ args: CVarArg...) {
        let template = String(localized: key)
        let text = args.isEmpty ? template : String(format: template, arguments: args)
        withAnimation(.easeOut(duration: 0.25)) { resultText = text }
    }

    private func run(_ demo: InteractionDemo) async throws {
        switch demo {
        case .cycle:         try await runCycle()
        case .pinnedOpen:    try await runPinnedOpen()
        case .multiPaste:    try await runMultiPaste()
        case .search:        try await runSearch()
        case .nextCategory:  try await runNextCategory()
        case .spacePreview:  try await runSpacePreview()
        case .pinPreview:    try await runPinPreview()
        case .transform:     try await runTransform()
        case .moveToFront:   try await runMoveToFront()
        case .delete:        try await runDelete()
        case .reverseCycle:  try await runReverseCycle()
        case .cyclePinned:   try await runCyclePinned()
        case .pinItem:       try await runPinItem()
        case .group:         try await runGroup()
        case .collections:   try await runCollections()
        case .pasteOne:      try await runPasteOne()
        case .pasteTwo:      try await runPasteTwo()
        case .pasteThree:    try await runPasteThree()
        }
    }

    // MARK: - Tutorial paste demos (distinct from runCycle)
    //
    // Three separate animations, one per element. Each reaches a deeper item
    // by adding one more V tap: element 1 = one tap, element 2 = two taps,
    // element 3 = three taps. Kept as their own functions on purpose so the
    // choreography (tap count, pacing, the counter pips) can differ per element
    // without ever touching the shared `.cycle` demo.

    /// Element 1 — a single V tap lands on the top item.
    private func runPasteOne() async throws {
        stageKeys = [.cmd, .v]
        pasteTapTarget = 1
        pasteTapDone = 0
        press(.cmd)
        try await pause(450)
        hint("Tap V once")
        showPanel(true)
        try await pause(250)
        try await tap(.v)
        pasteTapDone = 1
        selectItem(0)
        try await pause(650)
        hint("Release ⌘ to paste")
        try await pause(550)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("Pasted “%@”", items[0].title)
        pasteTapTarget = 0
    }

    /// Element 2 — two V taps step down to the second item.
    private func runPasteTwo() async throws {
        stageKeys = [.cmd, .v]
        pasteTapTarget = 2
        pasteTapDone = 0
        press(.cmd)
        try await pause(450)
        hint("Tap V twice")
        showPanel(true)
        try await pause(250)
        try await tap(.v)
        pasteTapDone = 1
        selectItem(0)
        try await pause(360)
        try await tap(.v)
        pasteTapDone = 2
        selectItem(1)
        try await pause(650)
        hint("Release ⌘ to paste")
        try await pause(500)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("Pasted “%@”", items[1].title)
        pasteTapTarget = 0
    }

    /// Element 3 — three V taps walk all the way to the third item.
    private func runPasteThree() async throws {
        stageKeys = [.cmd, .v]
        pasteTapTarget = 3
        pasteTapDone = 0
        press(.cmd)
        try await pause(450)
        hint("Tap V three times")
        showPanel(true)
        try await pause(250)
        try await tap(.v)
        pasteTapDone = 1
        selectItem(0)
        try await pause(320)
        try await tap(.v)
        pasteTapDone = 2
        selectItem(1)
        try await pause(320)
        try await tap(.v)
        pasteTapDone = 3
        selectItem(2)
        try await pause(650)
        hint("Release ⌘ to paste")
        try await pause(500)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("Pasted “%@”", items[2].title)
        pasteTapTarget = 0
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
        finish("Pasted “%@”", items[idx].title)
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

    private func runNextCategory() async throws {
        // Show all three keys: ⌘ opens, V lights up as the popup appears, then
        // ` steps through the categories one at a time.
        stageKeys = [.cmd, .v, .grave]
        press(.cmd)
        try await pause(350)
        hint("Tap V to open")
        try await tap(.v)
        showPanel(true)
        try await pause(650)
        hint("Tap ` for the next category")
        try await pause(250)
        // Start on Recents, step to each category one tap at a time, then wrap.
        for tab in [1, 0] {
            try await tap(.grave)
            withAnimation(.easeOut(duration: 0.15)) {
                activeTab = tab
                for idx in items.indices {
                    items[idx].title = "\(tabNames[tab]) item \(idx + 1)"
                    items[idx].mark = nil
                }
                selectedIndex = 0
            }
            try await pause(800)
        }
        finish("Stepped through every category with `")
        try await pause(900)
        release(.cmd)
        showPanel(false)
        hint(nil)
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
        finish("Previewed “%@”, no paste", items[1].title)
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
        finish("Pinned “%@” to tray", items[1].title)
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
        finish("%@ applied → pasted", applied)
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
        finish("“%@” moved to front — selection stays on the next item", items[0].title)
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
        finish("“%@” removed from the ring", removedTitle)
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
        finish("Pasted “%@”", items[idx].title)
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

    private func runGroup() async throws {
        stageKeys = [.cmd, .v, .g]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        try await tap(.v)
        try await pause(300)
        hint("Hold V to mark items")
        // Mark the first item.
        press(.v)
        try await pause(550)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[0].mark = 1 }
        try await pause(400)
        // Move down and mark the second.
        try await tap(.v)
        selectItem(1)
        try await pause(300)
        press(.v)
        try await pause(550)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[1].mark = 2 }
        try await pause(500)
        hint("Tap G to group them")
        try await tap(.g)
        // Collapse the marked items into a single group entry.
        withAnimation(.easeOut(duration: 0.35)) {
            items = [LabItem(title: "Group · 2 items")]
            selectedIndex = 0
        }
        try await pause(500)
        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("2 items folded into one group")
    }

    /// 1–5 swaps which collection the ring is showing. The demo starts in
    /// "All", narrows to a collection, then flips back with the same key.
    private func runCollections() async throws {
        stageKeys = [.cmd, .v, .one, .two]
        press(.cmd)
        try await pause(400)
        showPanel(true)
        // Same opening as every other gesture: ⌘ held, then a V tap actually
        // opens the ring. Only then do the number keys come into play.
        try await tap(.v)
        try await pause(400)
        hint("All — your whole clipboard")
        try await pause(700)

        hint("Press 2 for your first collection")
        try await tap(.two)
        withAnimation(.easeOut(duration: 0.3)) {
            items = [LabItem(title: "Work note"),
                     LabItem(title: "Work screenshot")]
            selectedIndex = 0
        }
        try await pause(800)

        hint("Press 1 for All again")
        try await tap(.one)
        withAnimation(.easeOut(duration: 0.3)) {
            items = Self.defaultItems()
            selectedIndex = 0
        }
        try await pause(500)

        release(.cmd)
        showPanel(false)
        hint(nil)
        finish("1 is All, 2 onward are your collections")
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
                    Text(["Recents", "Image"][i])
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
            Text(lab.instruction ?? LocalizedStringKey(" "))
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

                // Paste-demo tap counter: V ● ● ● ×N. The row is ALWAYS present
                // at a fixed height and only its contents fade in/out — otherwise
                // inserting/removing it as the demo restarts (on every paste)
                // changed the stage height and shook the whole sheet up and down.
                ZStack {
                    if lab.pasteTapTarget > 0 {
                        HStack(spacing: 7) {
                            Text("V").font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.textDim)
                            ForEach(0..<lab.pasteTapTarget, id: \.self) { i in
                                Circle()
                                    .fill(i < lab.pasteTapDone ? Color.accent : Color.textDim.opacity(0.3))
                                    .frame(width: 8, height: 8)
                                    .scaleEffect(i == lab.pasteTapDone - 1 ? 1.4 : 1)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: lab.pasteTapDone)
                            }
                            Text("×\(lab.pasteTapTarget)").font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundColor(.accent)
                        }
                    }
                }
                .frame(height: 20)
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

    func measuredWidth<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(GeometryReader { geo in
            Color.clear.preference(key: key, value: geo.size.width)
        })
    }
}

struct CollectionsWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct SettingsRow2HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ClipenSettingsView: View {
    @ObservedObject private var manager = ClipboardManager.shared
    @ObservedObject private var auth    = AuthManager.shared
    @ObservedObject private var proGate = ProGate.shared

    @Binding var showResetConfirm: Bool

    @State private var row1Height: CGFloat = 0

    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var showingRenameCollection = false
    @State private var renamingCollection: String? = nil
    @State private var renameCollectionText = ""
    @State private var showingDeleteCollection = false
    @State private var deletingCollection: String? = nil
    @State private var scrollViewportWidth: CGFloat = 0
    @State private var showExcludedAppsManager = false
    @State private var row2Height: CGFloat = 0
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

    /// SwiftUI-owned source of truth for the beta channel, persisted to the
    /// same UserDefaults key `AppDelegate.allowedChannels(for:)` reads. Using
    /// @AppStorage (instead of a computed binding through weak AppDelegate.shared)
    /// makes turning it OFF actually persist and stops it snapping back on.
    @AppStorage("SUBetaUpdatesEnabled") private var betaUpdatesEnabled = false

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
                proUpsellBanner
                collectionsSection

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

                interactionsSection
                    .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private func sectionHeader(_ number: String, _ title: LocalizedStringKey) -> some View {
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

    private func behaviourRow(_ n: Int, icon: String, _ label: LocalizedStringKey,
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

    private static let openDelayPresets: [(label: LocalizedStringKey, seconds: Double)] =
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

            ForEach(Self.openDelayPresets, id: \.seconds) { preset in
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

    private func openDelayChoice(label: LocalizedStringKey, isOn: Bool, action: @escaping () -> Void) -> some View {
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
                    .font(.system(size: 20, weight: .bold))
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
                Text(LocalizedStringKey(label)).font(.system(size: 12)).foregroundColor(.textPri)
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

    // MARK: - Pro upsell

    /// Sits above Collections. Disappears entirely once the user is Pro — at
    /// that point the toolbar badge alone carries the status, and a permanent
    /// "subscribe" strip in a paid app would just be noise. Gated on
    /// paywallApplies for the same reason as the toolbar badge: the paywall is
    /// inert for real users today, so there is nothing to upsell them on yet.
    @ViewBuilder
    private var proUpsellBanner: some View {
        if proGate.paywallApplies && !proGate.isPro {
            Button {
                NSWorkspace.shared.open(URL(string: "https://clipen.app/pro")!)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.accent)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Subscribe to Pro")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.textPri)
                        Text("Unlock everything and support Clipen's development.")
                            .font(.system(size: 10))
                            .foregroundColor(.textSec)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.textDim)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.accent.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Collections

    private var collectionsSection: some View {
        VStack(alignment: .center, spacing: 14) {
            sectionHeader("00", "COLLECTIONS")
                .frame(maxWidth: .infinity, alignment: .center)

            Text("All is your whole clipboard, unfiltered. Create a collection and anything you copy while it's active is filed under it — hold ⌘ and press 1–9 in the popup to switch instantly.")
                .font(.system(size: 11)).foregroundColor(.textSec)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    // Slot 1 is always All; collections take 2 onward.
                    collectionPill(name: nil, slot: 1)

                    ForEach(Array(manager.collections.enumerated()), id: \.element) { index, name in
                        collectionPill(name: name, slot: index + 2)
                    }

                    if manager.collections.count < ClipboardManager.maxCollections {
                        Button {
                            newCollectionName = ""
                            showingNewCollection = true
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                                Text("New").font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.accent)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.accent.opacity(0.45),
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                // Centre the pills while they fit, and only start scrolling
                // once they genuinely overflow.
                .frame(minWidth: scrollViewportWidth, alignment: .center)
            }
            .measuredWidth(CollectionsWidthKey.self)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Same card treatment as the Interaction Preview panel, stretched the
        // full width of the settings column with its own interior padding.
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(Color.surfaceHi.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.border, lineWidth: 1))
        .onPreferenceChange(CollectionsWidthKey.self) { scrollViewportWidth = $0 }
        .alert("New collection", isPresented: $showingNewCollection) {
            TextField("Name", text: $newCollectionName)
            Button("Cancel", role: .cancel) { }
            Button("Create") { manager.addCollection(named: newCollectionName) }
        } message: {
            Text("Up to \(ClipboardManager.maxCollections) collections.")
        }
        .alert("Rename collection", isPresented: $showingRenameCollection) {
            TextField("Name", text: $renameCollectionText)
            Button("Cancel", role: .cancel) { }
            Button("Rename") {
                if let old = renamingCollection {
                    manager.renameCollection(old, to: renameCollectionText)
                }
            }
        } message: {
            Text("Items already in this collection follow the new name.")
        }
        .alert("Delete collection?", isPresented: $showingDeleteCollection) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let name = deletingCollection { manager.deleteCollection(name) }
            }
        } message: {
            Text("Items only in “\(deletingCollection ?? "")” are deleted. Items that also live in another collection are kept there.")
        }
    }

    // MARK: - Excluded Apps
    //
    // Deliberately NOT a Collections-style pill row — this lives as a single
    // "Excluded apps / Manage" row inside App Settings instead (in the exact
    // slot the redundant "Check for Updates" row used to occupy, since that
    // duplicated the toolbar's own Check-for-Updates button). The management
    // surface is a compact vertical list in a popover, not a card of its own
    // on the main settings page — a "set once, rarely revisit" feature earns
    // a lower profile than Collections, which people switch between often.

    private var excludedAppsManagerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Excluded apps").font(.system(size: 11, weight: .semibold)).foregroundColor(.textSec)
                Spacer()
                Button {
                    browseForApplicationToExclude()
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(.accent)
                }
                .buttonStyle(.plain)
                .help("Choose any installed app — it doesn't need to be running")
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)

            Text("Copies from these apps are never captured into your history.")
                .font(.system(size: 10)).foregroundColor(.textDim)
                .padding(.horizontal, 12).padding(.bottom, 6)

            if manager.excludedCaptureBundleIDs.isEmpty {
                Text("None yet — tap + to add one.")
                    .font(.system(size: 11)).foregroundColor(.textDim)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.excludedCaptureBundleIDs).sorted(), id: \.self) { bundleID in
                            excludedAppRow(bundleID: bundleID)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Spacer(minLength: 6)
        }
        .frame(width: 240)
        .padding(.bottom, 4)
    }

    private func excludedAppRow(bundleID: String) -> some View {
        HStack(spacing: 8) {
            if let icon = ClipenIconCache.shared.appIcon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed").font(.system(size: 12)).foregroundColor(.textDim)
            }
            Text(excludedAppDisplayName(for: bundleID))
                .font(.system(size: 12)).foregroundColor(.textPri)
            Spacer()
            Button {
                manager.excludedCaptureBundleIDs.remove(bundleID)
            } label: {
                Image(systemName: "trash").font(.system(size: 10, weight: .semibold)).foregroundColor(.textDim)
            }
            .buttonStyle(.plain)
            .help("Stop excluding this app")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    /// Native "choose an app" panel, scoped to /Applications — the standard
    /// macOS pattern for this (Automator, "Open With → Other…", login-item
    /// pickers all work this way). Deliberately NOT a list of currently
    /// running processes: the whole point of an exclusion list is apps like
    /// a password manager that you set up once and that may well not be
    /// open at the moment you're configuring this.
    private func browseForApplicationToExclude() {
        let panel = NSOpenPanel()
        panel.title = "Choose an App to Exclude"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier
        else { return }
        manager.excludedCaptureBundleIDs.insert(bundleID)
    }

    private func excludedAppDisplayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            return running.localizedName ?? bundleID
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    @ViewBuilder
    private func collectionPill(name: String?, slot: Int) -> some View {
        let isActive = manager.activeCollection == name

        HStack(spacing: 8) {
            // Leading shortcut badge — the literal keystroke that selects it.
            Text("⌘\(slot)")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(isActive ? .white.opacity(0.9) : .textDim)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)))

            Text(name ?? String(localized: "All"))
                .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                .foregroundColor(isActive ? .white : .textPri)

            // Trailing delete — only real collections can be removed; All is
            // the unfiltered view, not something that can be deleted.
            if let name {
                Button {
                    deletingCollection = name
                    showingDeleteCollection = true
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(isActive ? .white.opacity(0.8) : .textDim)
                }
                .buttonStyle(.plain)
                .help("Delete “\(name)”")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(isActive ? Color.accent : Color.surfaceHi.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(isActive ? Color.clear : Color.border, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { manager.activeCollection = name }
        .contextMenu {
            if let name {
                Button("Rename\u{2026}") {
                    renamingCollection = name
                    renameCollectionText = name
                    showingRenameCollection = true
                }
                Button("Delete\u{2026}", role: .destructive) {
                    deletingCollection = name
                    showingDeleteCollection = true
                }
            }
        }
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
                    Toggle("", isOn: $betaUpdatesEnabled)
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

                rowDivider(leading: 40)

                HStack(spacing: 10) {
                    Image(systemName: "eye.slash").font(.system(size: 11)).foregroundColor(.textDim).frame(width: 16)
                    Text("Excluded apps").font(.system(size: 13)).foregroundColor(.textPri)
                    Spacer()
                    Button {
                        showExcludedAppsManager.toggle()
                    } label: {
                        Text("Manage")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.accent)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentDim, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .help("Apps whose copies are never captured into history")
                    .popover(isPresented: $showExcludedAppsManager, arrowEdge: .bottom) {
                        excludedAppsManagerPopover
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
                autoPreviewRow(2)
                rowDivider()
                pinPositionRow(3)
                rowDivider()
                rememberLastPositionRow(4)
                rowDivider()
                autoDismissRow(5)
                rowDivider()
                behaviourRow(6, icon: "arrow.right.to.line", "Advance after marking",
                             isOn: Binding(get: { manager.advanceAfterMark },
                                           set: { manager.advanceAfterMark = $0 }))
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
        [.transform, .search, .nextCategory, .moveToFront, .delete],
        [.cyclePinned, .pinItem, .group, .collections],
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

                Button {
                    manager.interactionSoundsEnabled.toggle()
                } label: {
                    Text("Interaction sounds")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(manager.interactionSoundsEnabled ? .accent : .textDim)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(manager.interactionSoundsEnabled ? Color.accentDim : Color.white.opacity(0.06),
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .help(manager.interactionSoundsEnabled
                      ? "Turn off sound feedback for popup gestures (V, Space, X, C, S, P, Delete)"
                      : "Play a sound for every popup gesture (V, Space, X, C, S, P, Delete)")
            }

            KeyboardInteractionPanel()
                .padding(.vertical, 14)
                .frame(minHeight: row2Height, alignment: .top)
                .background(Color.surfaceHi.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .measured(SettingsRow2HeightKey.self)
        }
    }

    // MARK: - Keyboard-based interaction picker
    //
    // Replaces the old flat list of demo rows. Renders an actual keyboard;
    // the keys that trigger a real gesture (V, C, X, G, P, F, `, Space,
    // Delete, Shift) get a pulsing blue border, ⌘ is gold. Click a key to
    // toggle a popup beside it (not over it) showing that gesture's demo —
    // and, for gestures with a configurable speed, the Slow/Medium/Fast
    // picker right there in the same popup. Click the same key again to
    // close it.

    private struct KBKey: Identifiable, Equatable {
        let id: String
        let label: String
        var width: CGFloat = 1
        var demos: [InteractionDemo] = []
        var isCommand: Bool = false
        static func == (l: KBKey, r: KBKey) -> Bool { l.id == r.id }
    }

    private enum KBLayout {
        static let rows: [[KBKey]] = [
            [KBKey(id: "GRAVE", label: "`", demos: [.nextCategory]),
             KBKey(id: "1", label: "1", demos: [.collections]),
             KBKey(id: "2", label: "2"), KBKey(id: "3", label: "3"), KBKey(id: "4", label: "4"),
             KBKey(id: "5", label: "5"), KBKey(id: "6", label: "6"), KBKey(id: "7", label: "7"),
             KBKey(id: "8", label: "8"), KBKey(id: "9", label: "9"), KBKey(id: "0", label: "0"),
             KBKey(id: "MINUS", label: "-"), KBKey(id: "EQUAL", label: "="),
             KBKey(id: "DELETE", label: "⌫", width: 1.6, demos: [.delete])],
            [KBKey(id: "TAB", label: "tab", width: 1.4),
             KBKey(id: "Q", label: "Q"), KBKey(id: "W", label: "W"), KBKey(id: "E", label: "E"),
             KBKey(id: "R", label: "R"), KBKey(id: "T", label: "T"), KBKey(id: "Y", label: "Y"),
             KBKey(id: "U", label: "U"), KBKey(id: "I", label: "I"), KBKey(id: "O", label: "O"),
             KBKey(id: "P", label: "P", demos: [.cyclePinned, .pinItem]),
             KBKey(id: "LBRACKET", label: "["), KBKey(id: "RBRACKET", label: "]"),
             KBKey(id: "BACKSLASH", label: "\\", width: 1.2)],
            [KBKey(id: "CAPS", label: "caps", width: 1.6),
             KBKey(id: "A", label: "A"), KBKey(id: "S", label: "S"), KBKey(id: "D", label: "D"),
             KBKey(id: "F", label: "F", demos: [.search]),
             KBKey(id: "G", label: "G", demos: [.group]),
             KBKey(id: "H", label: "H"), KBKey(id: "J", label: "J"), KBKey(id: "K", label: "K"),
             KBKey(id: "L", label: "L"), KBKey(id: "SEMI", label: ";"), KBKey(id: "QUOTE", label: "'"),
             KBKey(id: "RETURN", label: "return", width: 1.8)],
            [KBKey(id: "LSHIFT", label: "shift", width: 2.0, demos: [.reverseCycle]),
             KBKey(id: "Z", label: "Z"),
             KBKey(id: "X", label: "X", demos: [.transform]),
             KBKey(id: "C", label: "C", demos: [.moveToFront]),
             KBKey(id: "V", label: "V", demos: [.cycle, .multiPaste, .pinnedOpen]),
             KBKey(id: "B", label: "B"), KBKey(id: "N", label: "N"), KBKey(id: "M", label: "M"),
             KBKey(id: "COMMA", label: ","), KBKey(id: "PERIOD", label: "."), KBKey(id: "SLASH", label: "/"),
             KBKey(id: "RSHIFT", label: "shift", width: 2.4)],
            [KBKey(id: "FN", label: "fn", width: 1.2),
             KBKey(id: "CTRL", label: "control", width: 1.3),
             KBKey(id: "OPT", label: "option", width: 1.3),
             KBKey(id: "LCMD", label: "⌘", width: 1.3, isCommand: true),
             KBKey(id: "SPACE", label: "", width: 5.6, demos: [.spacePreview, .pinPreview]),
             KBKey(id: "RCMD", label: "⌘", width: 1.3, isCommand: true),
             KBKey(id: "ROPT", label: "option", width: 1.3),
             KBKey(id: "ARROWS", label: "", width: 3.3)],
        ]
        static let all: [KBKey] = rows.flatMap { $0 }
    }

    private struct KeyCapView: View {
        let key: KBKey
        let isActive: Bool
        let unitWidth: CGFloat
        let keyHeight: CGFloat
        @State private var pulse = false
        @State private var hovered = false

        private var isInteractive: Bool { !key.demos.isEmpty }
        private static let interactiveColor = Color(hex: "#4F8EF7")
        private static let commandColor = Color(hex: "#D4AF37")

        var body: some View {
            Text(key.label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(key.isCommand ? Self.commandColor
                                  : (isInteractive ? Self.interactiveColor : .textSec))
                .frame(width: key.width * unitWidth, height: keyHeight)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Color.accentDim
                          : (hovered && isInteractive ? Self.interactiveColor.opacity(0.18) : Color.surfaceHi.opacity(0.6))))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            key.isCommand ? Self.commandColor
                                : (isInteractive ? Self.interactiveColor.opacity(isActive || hovered ? 1 : (pulse ? 1 : 0.4)) : Color.border),
                            lineWidth: (key.isCommand || isInteractive) ? (isActive ? 2.5 : 1.6) : 1)
                )
                .scaleEffect(isActive ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.15), value: isActive)
                .animation(.easeOut(duration: 0.12), value: hovered)
                .onHover { hovering in
                    guard isInteractive else { return }
                    hovered = hovering
                }
                .onAppear {
                    guard isInteractive else { return }
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                }
        }
    }

    private struct KeyDemoPopup: View {
        let key: KBKey

        @State private var selected: InteractionDemo
        @StateObject private var lab = InteractionLabController()

        init(key: KBKey) {
            self.key = key
            _selected = State(initialValue: key.demos.first ?? .cycle)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                if key.demos.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(key.demos, id: \.self) { demo in
                            Button {
                                selected = demo
                                lab.select(demo)
                            } label: {
                                Text(LocalizedStringKey(demo.title))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(selected == demo ? .white : .textSec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(selected == demo ? Color.accent : Color.surfaceHi, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text(LocalizedStringKey(selected.title))
                        .font(.system(size: 11, weight: .semibold)).foregroundColor(.textPri)
                }

                Text(LocalizedStringKey(selected.caption))
                    .font(.system(size: 10)).foregroundColor(.textSec)
                    .fixedSize(horizontal: false, vertical: true)

                InteractionLabStage(lab: lab)
                    .frame(height: 150)

                if let binding = speedBinding(for: selected) {
                    HStack(spacing: 8) {
                        Text(selected == .pinPreview ? "Double-tap speed" : "Hold speed")
                            .font(.system(size: 9)).foregroundColor(.textDim)
                        ForEach(GestureSpeed.allCases) { speed in
                            Button {
                                binding.wrappedValue = speed
                                lab.select(selected)
                            } label: {
                                Text(LocalizedStringKey(speed.label))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(binding.wrappedValue == speed ? .white : .textSec)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(binding.wrappedValue == speed ? Color.accent : Color.surfaceHi,
                                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(14)
            .frame(width: 300)
            .onAppear { lab.select(selected) }
            .onDisappear { lab.stop() }
        }

        private func speedBinding(for demo: InteractionDemo) -> Binding<GestureSpeed>? {
            let m = ClipboardManager.shared
            switch demo {
            case .multiPaste:  return Binding(get: { m.markHoldSpeed }, set: { m.markHoldSpeed = $0 })
            case .pinItem:     return Binding(get: { m.pinHoldSpeed }, set: { m.pinHoldSpeed = $0 })
            case .pinPreview:  return Binding(get: { m.spaceDoubleTapSpeed }, set: { m.spaceDoubleTapSpeed = $0 })
            case .pinnedOpen:  return Binding(get: { m.pinnedOpenHoldSpeed }, set: { m.pinnedOpenHoldSpeed = $0 })
            default:           return nil
            }
        }
    }

    private struct ArrowKeysCluster: View {
        let totalWidth: CGFloat
        let keyHeight: CGFloat

        var body: some View {
            let gap: CGFloat = 1.5
            let arrowW = (totalWidth - 2 * gap) / 3
            let halfH = (keyHeight - gap) / 2

            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    Color.clear.frame(width: arrowW, height: halfH)
                    arrowCap("chevron.up", width: arrowW, height: halfH)
                    Color.clear.frame(width: arrowW, height: halfH)
                }
                HStack(spacing: gap) {
                    arrowCap("chevron.left", width: arrowW, height: halfH)
                    arrowCap("chevron.down", width: arrowW, height: halfH)
                    arrowCap("chevron.right", width: arrowW, height: halfH)
                }
            }
            .frame(width: totalWidth, height: keyHeight)
        }

        private func arrowCap(_ icon: String, width: CGFloat, height: CGFloat) -> some View {
            Image(systemName: icon)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.textSec)
                .frame(width: width, height: height)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.surfaceHi.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.border, lineWidth: 1))
        }
    }

    private struct KeyboardInteractionPanel: View {
        @State private var activeKeyID: String? = nil

        private let keySpacing: CGFloat = 6
        private let horizontalPadding: CGFloat = 14
        private let keyHeight: CGFloat = 32

        var body: some View {
            GeometryReader { geo in
                let totalWidth = geo.size.width

                VStack(spacing: keySpacing) {
                    ForEach(Array(KBLayout.rows.enumerated()), id: \.offset) { _, row in
                        let rowUnits = row.reduce(CGFloat(0)) { $0 + $1.width }
                        let rowGaps = CGFloat(row.count - 1)
                        let rowAvail = totalWidth - horizontalPadding * 2 - rowGaps * keySpacing
                        let unitW = max(16, rowAvail / rowUnits)

                        HStack(spacing: keySpacing) {
                            ForEach(row) { key in
                                if key.id == "ARROWS" {
                                    ArrowKeysCluster(totalWidth: key.width * unitW, keyHeight: keyHeight)
                                } else {
                                    KeyCapView(key: key, isActive: activeKeyID == key.id, unitWidth: unitW, keyHeight: keyHeight)
                                        .onTapGesture {
                                            guard !key.demos.isEmpty else { return }
                                            activeKeyID = (activeKeyID == key.id) ? nil : key.id
                                        }
                                        .popover(isPresented: Binding(
                                            get: { activeKeyID == key.id },
                                            set: { isPresented in if !isPresented { activeKeyID = nil } }
                                        ), arrowEdge: .bottom) {
                                            KeyDemoPopup(key: key)
                                        }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)
                .frame(width: totalWidth, alignment: .center)
            }
            .frame(minHeight: 210)
        }
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
        Button(LocalizedStringKey(title)) { NSWorkspace.shared.open(URL(string: urlString)!) }
            .buttonStyle(.plain)
            .font(.system(size: 11)).foregroundColor(.textSec)
    }
}
