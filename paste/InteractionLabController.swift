import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

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

    @Published var syncRealKeyboard = true

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

            await Self.nextRunLoopTurn()
            await Self.nextRunLoopTurn()
            await Self.nextRunLoopTurn()
            guard let self, !Task.isCancelled else { return }
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

    func stopIfStillPlaying(_ demo: InteractionDemo) {
        guard selectedDemo == demo else { return }
        stop()
    }

    private static func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
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

        stageKeys = [.cmd, .v, .grave]
        press(.cmd)
        try await pause(350)
        hint("Tap V to open")
        try await tap(.v)
        showPanel(true)
        try await pause(650)
        hint("Tap ` for the next category")
        try await pause(250)

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

        press(.v)
        try await pause(550)
        release(.v)
        withAnimation(.easeOut(duration: 0.15)) { items[0].mark = 1 }
        try await pause(400)

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

    private func runCollections() async throws {
        stageKeys = [.cmd, .v, .one, .two]
        press(.cmd)
        try await pause(400)
        showPanel(true)

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
