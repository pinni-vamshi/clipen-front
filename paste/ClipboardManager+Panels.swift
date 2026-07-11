import AppKit
import SwiftUI
@preconcurrency import PDFKit

extension ClipboardManager {
    // MARK: - Two-stage transform

    /// The mark queue resolved to live items, in marking order.
    var orderedMarkedItems: [ClipboardItem] {
        markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func enterTransformStage() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        // Only one secondary panel at a time — close preview/share if open.
        if itemPreviewPanel.isVisible { itemPreviewPanel.hide() }
        userOpenedItemPreview = false
        if inShareStage { exitShareStage() }

        // 2+ marked items: X opens the marked-set tool list (classified by
        // what's marked: all-text / all-image / all-PDF / all-file / mixed)
        // instead of the highlighted item's single-item tools.
        let marked = orderedMarkedItems
        if marked.count >= 2 {
            let displays = MarkedToolRegistry.displays(for: marked)
            guard !displays.isEmpty else { return }
            inTransformStage = true
            transformingMarkedSet = true
            transformDisplaysCache = displays
            transformIndex = 0
            updateTransformPanel()
            return
        }

        // (X coach advancement moved into cycleTransform() — pressing X
        // ONCE just opens the transform panel.  The user needs to TAP X a
        // few more times to feel the cycle through different tools before
        // we retire the bubble.  See cycleTransform() for the rule.)
        inTransformStage = true
        refreshTransformDisplaysCache()
        guard !transformDisplaysCache.isEmpty else {
            inTransformStage = false
            return
        }
        transformIndex   = 0

        updateTransformPanel()
    }

    func cycleTransform() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformCycleCount += 1

        // Unified cycling for ALL content types (text, richText, image, PDF, file)
        guard !transformDisplaysCache.isEmpty else { return }
        transformIndex = (transformIndex + 1) % transformDisplaysCache.count
        updateTransformPanel()

        // Coach step 1 → done: only after the user has cycled through a
        // few transforms.  Opening the panel once doesn't count — the
        // point of the bubble is to teach that X is a CYCLE, not a single
        // action.  Three taps inside the panel proves the user got it.
        if popupCoachStep == 1 && transformCycleCount >= 3 {
            popupCoachStep = 2
        }
    }

    /// ⌘⇧X — step one transform BACKWARD in the cached display list.
    /// Mirrors cycleTransform's wrap (first ← last) so the user can nudge
    /// in either direction without leaving the transform stage.  Same
    /// guard set, same cache, same panel-refresh path.
    func cycleTransformBackward() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformCycleCount += 1

        guard !transformDisplaysCache.isEmpty else { return }
        let n = transformDisplaysCache.count
        // -1 % n is implementation-defined in Swift — compute explicitly.
        transformIndex = (transformIndex - 1 + n) % n
        updateTransformPanel()
    }

    func exitTransformStage() {
        inTransformStage = false
        transformingMarkedSet = false
        transformIndex   = 0
        transformDisplaysCache = []
        lastTransformCacheItemID = nil

        transformPanel.hide()
        itemPreviewPanel.hide()
    }

    // MARK: - Share Sheet (S key)

    /// Whatever S would share right now: every marked item if any are
    /// marked (mirrors commitPaste's multi-paste rule — "marked" always
    /// means "act on the whole set"), otherwise just the highlighted item.
    private var shareCandidateItems: [ClipboardItem] {
        let marked = orderedMarkedItems
        if !marked.isEmpty { return marked }
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return [] }
        return [displayItems[selectedIndex]]
    }

    /// Sharing-Service-compatible representation(s) for an item — always as
    /// FILE URLs. This is the key to AirDrop reliably appearing: AirDrop (and
    /// several other services) can't accept a raw NSString or NSImage, so a
    /// plain-text / code / log item shared as a bare String silently dropped
    /// AirDrop from the destination list ("sometimes I can't see AirDrop").
    /// Writing text/image/svg to a small temp file and sharing the URL makes
    /// EVERY item AirDrop-able, and every other service (Mail, Messages,
    /// Notes…) still handles a file attachment fine. Real files/URLs pass
    /// through untouched.
    private func shareRepresentations(for item: ClipboardItem) -> [URL] {
        switch item.content {
        case .file(let url) where FileManager.default.fileExists(atPath: url.path):
            return [url]
        case .files(let urls):
            return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        case .image(_, let rawData, let dataType):
            let ext = dataType.rawValue.contains("gif") ? "gif"
                : dataType.rawValue.contains("pdf") ? "pdf"
                : dataType.rawValue.contains("jpeg") ? "jpg" : "png"
            return Self.shareTempFile(rawData, ext: ext, id: item.id).map { [$0] } ?? []
        case .svg(let src):
            return Self.shareTempFile(Data(src.utf8), ext: "svg", id: item.id).map { [$0] } ?? []
        default:
            guard let text = item.content.plainText, !text.isEmpty else { return [] }
            return Self.shareTempFile(Data(text.utf8), ext: "txt", id: item.id).map { [$0] } ?? []
        }
    }

    /// Writes share payload bytes to a per-item temp file (idempotent — the
    /// same item id reuses the same path), returning the URL or nil on
    /// failure. Named after the item so AirDrop/Mail show a sensible filename.
    private static func shareTempFile(_ data: Data, ext: String, id: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipenShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Clipen-\(id.uuidString.prefix(8)).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func enterShareStage() {
        let targets = shareCandidateItems
        guard !targets.isEmpty else { return }
        let items = targets.flatMap { shareRepresentations(for: $0) }
        let services = NSSharingService.sharingServices(forItems: items)
        guard !services.isEmpty else {
            flashStatus("No share destinations available for this item.")
            return
        }
        if inTransformStage { exitTransformStage() }
        if itemPreviewPanel.isVisible { itemPreviewPanel.hide() }
        userOpenedItemPreview = false
        shareTargetItems = targets
        shareServices = Self.rankedShareServices(services)
        shareIndex = 0
        inShareStage = true
        updateSharePanel()
    }

    /// Alphabetical by default (no signal to rank by yet); once there's real
    /// usage history for at least one of these services, ranks by the same
    /// frequency + recency + time-of-day composite score transform tools use
    /// (`AuthManager.toolImportanceScore`) — services you actually share
    /// through often, or recently, float to the top instead of staying
    /// pinned alphabetically forever.
    private static func rankedShareServices(_ services: [NSSharingService]) -> [NSSharingService] {
        let scored = services.map { ($0, AuthManager.shared.toolImportanceScore(for: shareUsageKey($0))) }
        let hasData = scored.contains { $0.1 > 0 }
        guard hasData else {
            return services.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.title.localizedCaseInsensitiveCompare(rhs.0.title) == .orderedAscending
        }.map(\.0)
    }

    /// NSSharingService exposes no stable bundle-level identifier publicly —
    /// title is the best available stable-enough key ("Mail", "AirDrop",
    /// "Messages" don't change between launches).
    private static func shareUsageKey(_ service: NSSharingService) -> String {
        "share.\(service.title)"
    }

    func cycleShare() {
        guard inShareStage, !shareServices.isEmpty else { return }
        shareIndex = (shareIndex + 1) % shareServices.count
        updateSharePanel()
    }

    /// Lets the share panel's own row clicks move the highlight without
    /// going through the S-key cycle path — same "click to select" pattern
    /// TransformPanel's rows already use.
    func refreshShareStagePanel() {
        updateSharePanel()
    }

    private func updateSharePanel() {
        guard inShareStage else { return }
        let anchor = selectedRowAnchor()
        sharePanel.show(services: shareServices, selectedIndex: shareIndex,
                        itemCount: shareTargetItems.count,
                        near: previewWindow.frame, anchorPoint: anchor)
    }

    func exitShareStage() {
        inShareStage = false
        shareServices = []
        shareTargetItems = []
        shareIndex = 0
        sharePanel.hide()
    }

    /// ⌘-release while in share stage: invoke the currently-highlighted
    /// service instead of pasting. Called from commitPaste() before its
    /// normal paste logic — sharing and pasting are mutually exclusive
    /// outcomes of the same ⌘-release gesture.
    func commitShare() {
        guard inShareStage, shareServices.indices.contains(shareIndex) else {
            exitShareStage()
            return
        }
        let service = shareServices[shareIndex]
        let items = shareTargetItems.flatMap { shareRepresentations(for: $0) }
        // Feeds next time's ranking — the same usage-score pipeline
        // transform tools already report into.
        AuthManager.shared.registerToolUsage(toolID: Self.shareUsageKey(service))
        exitShareStage()
        markedItemIDs = []
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
        guard !items.isEmpty else { return }
        service.perform(withItems: items)
        AuthManager.shared.registerActionUsage(actionID: "action.share")
    }

    /// Rebuild transform list from current usage scores; keep highlight on the same tool id.
    /// Short-circuits when the selected item hasn't changed — avoids re-running
    /// all tool preview closures (JSON parse, regex, etc.) on every V-key tap.
    func refreshTransformDisplaysCache() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else {
            transformDisplaysCache = []
            lastTransformCacheItemID = nil
            return
        }
        let currentItem = displayItems[selectedIndex]
        if currentItem.id == lastTransformCacheItemID, !transformDisplaysCache.isEmpty {
            // Same item — cache is still valid; just keep the index stable.
            transformIndex = min(transformIndex, max(0, transformDisplaysCache.count - 1))
            return
        }
        lastTransformCacheItemID = currentItem.id
        let selectedID = transformDisplaysCache.indices.contains(transformIndex)
            ? transformDisplaysCache[transformIndex].id
            : nil
        transformDisplaysCache = ToolRegistry.displays(for: currentItem)
        if let selectedID,
           let newIdx = transformDisplaysCache.firstIndex(where: { $0.id == selectedID }) {
            transformIndex = newIdx
        } else {
            transformIndex = min(transformIndex, max(0, transformDisplaysCache.count - 1))
        }
    }

    /// Rebuild the transform panel for the currently-selected item.  Called
    /// when keyboard navigation (V / ⇧V / jump / category switch) moves the
    /// selection WHILE the transform stage is open — without this the panel
    /// keeps showing the previous item's transforms (e.g. text transforms
    /// still visible after cycling onto an image).
    func syncTransformPanelWithSelection() {
        // Marked-set tools describe the MARK QUEUE, not the highlighted row —
        // moving the selection must not swap them out for single-item tools.
        guard !transformingMarkedSet else { return }
        guard inTransformStage, previewWindow.isVisible,
              !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformDisplaysCache = ToolRegistry.displays(for: displayItems[selectedIndex])
        guard !transformDisplaysCache.isEmpty else {
            // New item can't be transformed — retire the stage/panel.
            exitTransformStage()
            return
        }
        transformIndex = 0
        updateTransformPanel()
    }

    func updateTransformPanel() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let anchor = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems: displayItems.count
        )
        transformPanel.show(for: displayItems[selectedIndex],
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            displaysOverride: inTransformStage ? transformDisplaysCache : nil)
    }

    /// Force-redraw the transform panel with the `isProcessing` flag toggled so
    /// the row for the selected transform shows a spinner while async work runs.
    func updateTransformPanelProcessing(_ processing: Bool) {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let anchor = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems: displayItems.count
        )
        transformPanel.show(for: displayItems[selectedIndex],
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            isProcessing: processing,
                            displaysOverride: inTransformStage ? transformDisplaysCache : nil)
    }

    func toggleSelectedItemPreview() {
        guard previewWindow.isVisible,
              !displayItems.isEmpty,
              selectedIndex < displayItems.count else { return }
        if itemPreviewPanel.isVisible {
            itemPreviewPanel.hide()
            userOpenedItemPreview = false
        } else {
            // Only one secondary panel at a time — close transforms/share if open.
            if inTransformStage { exitTransformStage() }
            if inShareStage { exitShareStage() }
            // Explicit user open — the preview now follows the selection and
            // stays open until the user presses Space again (see
            // syncItemPreviewWithSelection).
            userOpenedItemPreview = true
            // Counted HERE (the explicit Space press), not inside
            // showSelectedItemPreview — that's also called on every cycle
            // step by syncItemPreviewWithSelection, which would inflate
            // the count to once per V-tap with always-show-preview on.
            AuthManager.shared.registerActionUsage(actionID: "action.preview")
            showSelectedItemPreview()
        }
    }

    /// Mouse-driven counterpart to `toggleSelectedItemPreview()` (Space key):
    /// a single click on a popup row always SHOWS the preview for that row
    /// (never toggles it closed), reusing the exact same panel/anchor logic.
    /// Only one secondary panel at a time — closes the transform/share stage
    /// first if it was open, same rule Space already follows.
    func uiPreviewSelectedItem() {
        guard previewWindow.isVisible, !displayItems.isEmpty,
              selectedIndex < displayItems.count else { return }
        if inTransformStage { exitTransformStage() }
        if inShareStage { exitShareStage() }
        // A click is an explicit open too — same "stays until the user
        // closes it" behavior as the Space key.
        userOpenedItemPreview = true
        resetAutoDismissTimer()
        showSelectedItemPreview()
    }

    func showSelectedItemPreview() {
        let anchor = selectedRowAnchor()
        let current: ClipboardItem? = (!displayItems.isEmpty && selectedIndex < displayItems.count)
            ? displayItems[selectedIndex] : nil
        // If the user has built a multi-paste queue, preview ALL marked items
        // stacked in one scrolling panel (in marking order) — so Space shows
        // exactly what ⌘-release will paste. But cycling with V can land the
        // highlight on an item that ISN'T marked, and that row would then
        // vanish from the preview entirely even though it's the one actually
        // highlighted right now — always fold the current row into the stack,
        // moved to the front, so what's under the cursor is never missing.
        let marked = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
        if marked.count > 1 {
            var stack = marked
            if let current {
                if let idx = stack.firstIndex(where: { $0.id == current.id }) {
                    stack.insert(stack.remove(at: idx), at: 0)
                } else {
                    stack.insert(current, at: 0)
                }
            }
            itemPreviewPanel.show(forItems: stack, currentItemID: current?.id,
                                   near: previewWindow.frame, anchorPoint: anchor)
            return
        }
        guard let current else { return }
        itemPreviewPanel.show(for: current, near: previewWindow.frame, anchorPoint: anchor)
    }

    /// The highlighted row's screen anchor point, for panels that show beside
    /// the ring popup (item preview, transforms) so their arrow points at the
    /// actual row instead of just somewhere along the popup's edge.
    func selectedRowAnchor() -> NSPoint? {
        guard !displayItems.isEmpty else { return nil }
        return previewWindow.selectedRowAnchorPoint(selectedIndex: selectedIndex, totalItems: displayItems.count)
    }

    func applyAlwaysShowItemPreviewPolicy() {
        guard previewWindow.isVisible else {
            if autoPreviewTypes.isEmpty { itemPreviewPanel.hide() }
            return
        }
        syncItemPreviewWithSelection()
    }

    /// Keeps the item preview panel in sync with the current selection when
    /// the highlighted item's content type is in `autoPreviewTypes`, or
    /// refreshes it when the user already opened preview via Space.
    func syncItemPreviewWithSelection() {
        guard previewWindow.isVisible else { return }
        // A preview the USER opened follows the selection and stays open —
        // it updates to show whatever's now highlighted and only closes when
        // the user closes it, never because the new item's type isn't in the
        // auto-preview set. That auto-hide rule applies ONLY to previews the
        // app itself auto-showed.
        if userOpenedItemPreview {
            if itemPreviewPanel.isVisible {
                showSelectedItemPreview()
            }
            return
        }
        let autoShowsCurrent = !autoPreviewTypes.isEmpty
            && displayItems.indices.contains(selectedIndex)
            && autoPreviewTypes.contains(AutoPreviewContentType.from(displayItems[selectedIndex]))
        if autoShowsCurrent {
            showSelectedItemPreview()
        } else if itemPreviewPanel.isVisible {
            if !autoPreviewTypes.isEmpty {
                // Auto-preview is on but this item's type isn't selected —
                // hide rather than keep showing the PREVIOUS item's preview.
                itemPreviewPanel.hide()
            } else {
                showSelectedItemPreview()
            }
        }
    }

    /// Synchronous sibling of `ToolRegistry.run` for tools that can finish
    /// immediately. Async tools still go through the Task path so the panel can
    /// show processing state.
    func applySyncTransform(item: ClipboardItem, toolID: String) -> TransformOutput? {
        ToolRegistry.runSync(item: item, toolID: toolID)
    }

    func pasteTransformed(_ text: String, restoring source: ClipboardItem? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
        finishTransformPaste(message: nil, restoring: source)
    }

    /// Public entry for menu-bar / settings UI (same path as ⌘X transform paste).
    func pasteGeneratedTransformItem(_ item: ClipboardItem, message: String, restoring source: ClipboardItem) {
        pasteGeneratedItem(item, message: message, restoring: source)
    }

    func pasteGeneratedTransformFiles(_ urls: [URL], message: String, restoring source: ClipboardItem) {
        pasteGeneratedFiles(urls, message: message, restoring: source)
    }

    /// Single entry for applying any transform result (⌘X popup, menu bar, etc.).
    func applyTransformResult(_ result: TransformOutput?, restoring source: ClipboardItem, toolID: String? = nil) {
        guard let result else {
            flashStatus("Transform returned nothing.")
            return
        }

        if let toolID, !toolID.isEmpty, transformResultCountsAsUsage(result) {
            AuthManager.shared.registerToolUsage(toolID: toolID)
        }

        switch result {
        case .text(let text) where !text.isEmpty:
            pasteTransformed(text, restoring: source)
        case .item(let item, let message):
            pasteGeneratedTransformItem(item, message: message, restoring: source)
        case .files(let urls, let message):
            pasteGeneratedTransformFiles(urls, message: message, restoring: source)
        case .revealFiles(let urls, let message):
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            flashStatus(message)
        case .status(let message):
            flashStatus(message)
        default:
            flashStatus("Transform returned nothing.")
        }
    }

    func handleTransformResult(_ result: TransformOutput?, restoring source: ClipboardItem, toolID: String? = nil) {
        applyTransformResult(result, restoring: source, toolID: toolID)
    }

    func transformResultCountsAsUsage(_ result: TransformOutput) -> Bool {
        switch result {
        case .status: return false
        case .text(let text): return !text.isEmpty
        case .item, .files, .revealFiles: return true
        }
    }

    func pasteGeneratedItem(_ item: ClipboardItem, message: String, restoring source: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if ImageService.shouldWriteExportFile(transformed: item, source: source),
           case .image(_, let rawData, let dataType) = item.content,
           let fileName = ImageService.persistExportFile(
               data: rawData,
               dataType: dataType,
               baseName: exportBaseName(for: source)
           ) {
            // Write a single item that carries both the file URL and inline image data
            pb.writeObjects([makeFilePasteboardItem(for: ImageService.exportFileURL(fileName: fileName))])
        } else {
            write(item, to: pb)
        }

        lastChangeCount = pb.changeCount
        finishTransformPaste(message: message, restoring: source)
    }

    func exportBaseName(for item: ClipboardItem) -> String? {
        switch item.content {
        case .file(let url):
            return url.deletingPathExtension().lastPathComponent
        case .files(let urls):
            return urls.first?.deletingPathExtension().lastPathComponent
        default:
            return nil
        }
    }

    func pasteGeneratedFiles(_ urls: [URL], message: String, restoring source: ClipboardItem) {
        guard !urls.isEmpty else {
            flashStatus("No files were generated.")
            return
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map { makeFilePasteboardItem(for: $0) })
        lastChangeCount = pb.changeCount
        finishTransformPaste(message: message, restoring: source)
    }

    /// Paste transform output into the frontmost app, then put the original
    /// source item back on the pasteboard. Transformed output is never added
    /// to the Clipen ring.
    func finishTransformPaste(message: String?, restoring source: ClipboardItem?) {
        let pasteTarget = resolvedPasteTarget()
        // Record destination on the SOURCE item (the one the user picked)
        // before hiding panels — frontmost is still the target app.
        if let source { recordPasteDestination(for: source.id, app: pasteTarget) }
        // A transform paste is still a paste — count it in the daily ⌘V
        // numbers like every other paste path (the single/multi/page-picker
        // paths all register; this one didn't, undercounting transform users).
        AuthManager.shared.registerCommandVAction()
        popupSessionPasted = true
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        if let message { flashStatus(message) }

        let token = beginPasteSimulation()

        // Restore helper — puts the original item back on the pasteboard so
        // pollClipboard() cannot capture the transformed payload into the ring.
        let restoreSource: () -> Void = { [weak self] in
            guard let self, let source else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            self.write(source, to: pb)
            self.lastChangeCount = pb.changeCount
        }

        // Use injection for Spotlight/Raycast/Alfred (text transforms only).
        let pbText = NSPasteboard.general.string(forType: .string)
        if let text = pbText, !text.isEmpty,
           text.count <= Self.maxInjectionLength,
           shouldInjectCharacters(to: pasteTarget) {
            injectCharacters(text) { [weak self] in
                restoreSource()
                self?.endPasteSimulation(token: token)
                self?.selectedIndex = 0
            }
            return
        }

        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // Restore the original item BEFORE clearing isSimulatingPaste so
            // pollClipboard() cannot capture the transformed payload into the ring.
            restoreSource()
            self.endPasteSimulation(token: token)
            self.selectedIndex = 0
        }
    }

    // MARK: - Cycling & pasting

    func cycleNext() {
        let display = displayItems
        guard !display.isEmpty else { return }

        if !previewWindow.isVisible {
            if pendingFirstOpen {
                cancelPendingFirstOpen()
                openPopupNow()
                selectedIndex = min(1, display.count - 1)
            } else if openOnSecondTap {
                // Second-tap mode: no timer at all. The pending flag stays
                // armed until either ⌘ is released (→ fastPasteFront pastes
                // the front item, indistinguishable from system ⌘V) or a
                // second V tap lands (→ the pendingFirstOpen branch above
                // opens the popup instantly at element 2). Disambiguation by
                // COUNT instead of time — zero waiting on either path.
                selectedIndex = 0
                pendingFirstOpen = true
                pendingFirstOpenTimer?.invalidate()
                pendingFirstOpenTimer = nil
                return
            } else if firstOpenDelay > 0 {
                selectedIndex = 0
                pendingFirstOpen = true
                pendingFirstOpenTimer?.invalidate()
                let t = Timer(timeInterval: firstOpenDelay, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { self?.openPopoverAfterDelay() }
                }
                RunLoop.main.add(t, forMode: .common)
                pendingFirstOpenTimer = t
                return
            } else {
                selectedIndex = 0
                openPopupNow()
            }
        } else {
            selectedIndex = (selectedIndex + 1) % display.count
        }

        cycleCount += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.nav")

        if popupCoachStep == 0 && cycleCount >= 3 { popupCoachStep = 1 }

        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// ⌘⇧V — step one item BACKWARD in the current category.  Mirrors
    /// cycleNext / cycleNext's wrap behavior (last → first becomes
    /// first → last) so the user can nudge in either direction without
    /// taking their hand off the ⌘ key.  No popup-open-on-first-press
    /// dance: ⇧V before the popup is open opens it on the LAST item.
    func cyclePrevious() {
        let display = displayItems
        guard !display.isEmpty else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.prev")

        if !previewWindow.isVisible {
            cancelPendingFirstOpen()
            selectedIndex = display.count - 1
            openPopupNow()
        } else {
            selectedIndex = (selectedIndex - 1 + display.count) % display.count
        }

        cycleCount += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.nav")
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// P — step through PINNED items only, one per tap, wrapping from the
    /// last pinned item back to the first instead of stopping. Ignores
    /// everything unpinned in between, unlike ⌘V's full-ring cycle.
    func cyclePinnedItems() {
        guard previewWindow.isVisible, !displayItems.isEmpty else { return }
        let pinnedIndices = displayItems.indices.filter { displayItems[$0].isPinned }
        guard !pinnedIndices.isEmpty else {
            flashStatus("No pinned items yet.")
            return
        }
        if let currentPos = pinnedIndices.firstIndex(of: selectedIndex) {
            selectedIndex = pinnedIndices[(currentPos + 1) % pinnedIndices.count]
        } else {
            // Not currently on a pinned item — jump straight to the first one.
            selectedIndex = pinnedIndices[0]
        }
        resetAutoDismissTimer()
        AuthManager.shared.registerActionUsage(actionID: "action.cycle_pinned")
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// Top-row number keycodes (kVK_ANSI_1 … kVK_ANSI_9) mapped to the
    /// zero-based CATEGORY index they should select.  ⌘1 → Recents (no
    /// filter), ⌘2 → first available category, ⌘3 → second, etc.  Numbers
    /// past 9 (rare — most rings have ≤6 active categories) have no
    /// keybinding and the chip just renders with no prefix.
    /// ⌘0 is intentionally NOT in the map — it's a system-reserved
    /// shortcut in many apps (zoom-to-fit etc.).
    static let numberRowKeycodeToIndex: [Int64: Int] = [
        18: 0, // 1
        19: 1, // 2
        20: 2, // 3
        21: 3, // 4
        23: 4, // 5
        22: 5, // 6
        26: 6, // 7
        28: 7, // 8
        25: 8, // 9
    ]

    /// Switch the active category filter by 1-based chip index.
    ///   idx == 0 → Recents (no filter)
    ///   idx == 1 → first item in `availableTags`
    ///   idx == 2 → second … etc.
    /// Out-of-range indices (e.g. ⌘5 with only 3 categories) are ignored.
    /// Opens the popup if it isn't already visible.
    func selectCategoryByIndex(_ idx: Int) {
        // idx 0 = Recents (no filter), idx 1+ = availableTags[idx-1]
        let total = 1 + availableTags.count
        guard idx >= 0, idx < total else { return }

        let wasFirstOpen = !previewWindow.isVisible
        if wasFirstOpen {
            cancelPendingFirstOpen()
            openPopupNow()
        }
        if idx == 0 {
            popupTagFilter = nil
        } else {
            popupTagFilter = availableTags[idx - 1]
        }
        selectedIndex = 0
        cycleCount += 1
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// Jump `step` items forward through the ring (default 5). Bound to
    /// ⌘+⌥V — the user's leap-ahead shortcut for large rings where ⌘V-by-one
    /// is too slow. If the popup isn't open yet, opens it positioned at the
    /// jumped index; otherwise just advances the selection.
    func jumpForward(by step: Int = 5) {
        let display = displayItems
        guard !display.isEmpty else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.jump5")

        let isFirstOpen = !previewWindow.isVisible
        if isFirstOpen {
            // Explicit jump → user wants the popup, no delay games.
            cancelPendingFirstOpen()
            selectedIndex = min(step, display.count - 1)
            openPopupNow()
        } else {
            clampSelectedIndexToDisplay()
            selectedIndex = (selectedIndex + step) % display.count
        }

        cycleCount += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.nav")
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// Fired by the delay timer when the user kept ⌘ held past
    /// `firstOpenDelay` — open the popup at row 0 just like the old
    /// instant-open did.
    func openPopoverAfterDelay() {
        guard pendingFirstOpen else { return }
        pendingFirstOpen = false
        pendingFirstOpenTimer = nil
        guard !displayItems.isEmpty else { return }
        openPopupNow()
        cycleCount += 1
    }

    /// Centralised "open the panel" — two states only:
    ///   1. Near the active text input (caret anchor).
    ///   2. Centre of the screen — fallback when no text field is focused.
    func openPopupNow() {
        popupTagFilter = nil
        // Restore the last row the user was on, if that setting is enabled —
        // but only within the configured time window: a position captured
        // 45 minutes ago is more likely stale than useful, so a gap longer
        // than rememberLastPositionTimeoutMinutes starts fresh at the top
        // instead, same as if the setting were off. Overrides whatever
        // first-open index the cycle path set (row 0/1), clamped to the
        // current ring so a shrunken history can't overflow.
        let withinRememberWindow: Bool = {
            guard let savedAt = rememberedSelectionSavedAt else { return false }
            // 0 = "Until turned off" — no expiry, always restore regardless
            // of how long the popup's been closed.
            guard rememberLastPositionTimeoutMinutes > 0 else { return true }
            return Date().timeIntervalSince(savedAt) <= TimeInterval(rememberLastPositionTimeoutMinutes * 60)
        }()
        if rememberLastSelection, withinRememberWindow, !displayItems.isEmpty {
            if let id = rememberedItemID,
               let idx = displayItems.firstIndex(where: { $0.id == id }) {
                selectedIndex = idx
            } else {
                selectedIndex = min(max(0, rememberedIndex), displayItems.count - 1)
            }
        }
        // Capture the real destination app NOW, before previewWindow.show()
        // brings up our own NSPopover — see capturedPasteTarget's doc comment.
        capturedPasteTarget = NSWorkspace.shared.frontmostApplication
        previewWindow.show()
        popupOpenGeneration += 1
        // Analytics: one popup session begins.
        AuthManager.shared.registerActionUsage(actionID: "popup.open")
        popupOpenedAt = Date()
        popupSessionPasted = false
        startAutoDismissTimer()
        syncItemPreviewWithSelection()
    }

    // MARK: - Auto-dismiss idle timer

    /// (Re)start the popup auto-dismiss countdown from `autoDismissSeconds`.
    /// Called on open, and on every popup interaction via
    /// `resetAutoDismissTimer` — activity keeps postponing the fire instead
    /// of it landing mid-use.
    func startAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        guard autoDismissEnabled, autoDismissSeconds > 0 else { return }
        let t = Timer(timeInterval: autoDismissSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewWindow.isVisible else { return }
                self.dismissPreview()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        autoDismissTimer = t
    }

    /// Called from every popup key/mouse action while the popup is open —
    /// restarts the countdown so genuine inactivity, not just elapsed time
    /// since open, is what triggers the auto-dismiss.
    func resetAutoDismissTimer() {
        guard previewWindow.isVisible else { return }
        startAutoDismissTimer()
    }

    /// Stops the countdown outright — used while a picker (page-range,
    /// language) is open and the user may sit reading/typing for a while
    /// without the per-keystroke reset covering every relevant key.
    func stopAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    /// Snapshot the current highlight so the next popup open can restore it when
    /// `rememberLastSelection` is on. Called right before the popup tears down.
    func captureRememberedSelection() {
        if displayItems.indices.contains(selectedIndex) {
            rememberedIndex  = selectedIndex
            rememberedItemID = displayItems[selectedIndex].id
            rememberedSelectionSavedAt = Date()
        }
    }

    // MARK: - Inline page-range picker control

    /// Switch the TransformPanel from its tool list into the page-picker view.
    /// Keeps the popup + transform panel visible so the user has continuous
    /// context; freezes the dismiss timer because typing the range takes
    /// time and a silent dismiss mid-edit would feel broken.
    func enterPageRangeMode(pdf: PDFDocument, item: ClipboardItem, outputMode: PageRangeOutputMode = .combinedPDF) {
        pageRangePDF        = pdf
        pageRangePageCount  = pdf.pageCount
        pageRangeQuery      = ""
        pageRangeManualPages = []
        pageRangeOutputMode  = outputMode
        inPageRangeMode      = true

        // Freeze auto-dismiss — picking pages can take a while, and a
        // silent dismiss mid-edit would feel broken.
        stopAutoDismissTimer()

        let modeLabel = (outputMode == .perPageImages) ? "images" : "PDF"
        flashStatus("Pick pages → \(modeLabel) · ↵ paste · ␣ preview")

        // Force the transform panel to re-render with the picker view AND
        // re-measure its height.  The picker is taller than a typical
        // transform list, so without this the footer (Enter/Space/Esc hints)
        // would be clipped below the panel's existing frame.  The flag
        // tells show() to use a guaranteed minimum height suitable for the
        // grid + header + query + footer.
        let displays = transformDisplaysCache.isEmpty
            ? ToolRegistry.displays(for: item)
            : transformDisplaysCache
        let anchor   = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems:    displayItems.count
        )
        transformPanel.show(for: item,
                            near: previewWindow.frame,
                            anchorPoint: anchor,
                            selectedTransformIndex: transformIndex,
                            isProcessing: false,
                            displaysOverride: displays)
    }

    func exitPageRangeMode() {
        inPageRangeMode      = false
        pageRangeQuery       = ""
        pageRangeManualPages = []
        pageRangePageCount   = 0
        pageRangePDF         = nil
        pageRangeOutputMode  = .combinedPDF
        itemPreviewPanel.hide()
        // Resume the dismiss countdown, freshly, only if the popup is still
        // actually open (this also runs from cleanupAfterPagePicker, right
        // before/after previewWindow.hide()).
        if previewWindow.isVisible { startAutoDismissTimer() }
    }

    func togglePageRangeManualPage(_ index: Int) {
        if pageRangeManualPages.contains(index) {
            pageRangeManualPages.remove(index)
        } else {
            pageRangeManualPages.insert(index)
        }
    }

    /// Commit the page picker.  Output depends on pageRangeOutputMode:
    ///   .combinedPDF — stitch selected pages into ONE new PDF (.copy()-d
    ///                  page-by-page; no text extraction, no rasterising)
    ///                  and paste as a single PDF file.
    ///   .perPageImages — render EACH selected page to its own PNG file
    ///                    at 2× scale and paste the collection as files.
    func commitPageRangePaste() {
        let pages = pageRangeEffectiveSelection.sorted()
        guard !pages.isEmpty else {
            flashStatus("Select at least one page first.")
            return
        }
        guard let originalPDF = pageRangePDF else {
            flashStatus("PDF unavailable.")
            exitPageRangeMode()
            return
        }

        let pb = NSPasteboard.general
        let toolID: String
        switch pageRangeOutputMode {
        case .combinedPDF:
            guard let url = Self.buildCombinedPDF(from: originalPDF, pages: pages) else {
                flashStatus("Couldn't build PDF from selected pages.")
                cleanupAfterPagePicker()
                return
            }
            pb.clearContents()
            pb.writeObjects([makeFilePasteboardItem(for: url)])
            toolID = "pdf.paste-pages"

        case .perPageImages:
            let urls = Self.renderPagesAsImages(from: originalPDF, pages: pages)
            guard !urls.isEmpty else {
                flashStatus("Couldn't render pages as images.")
                cleanupAfterPagePicker()
                return
            }
            pb.clearContents()
            pb.writeObjects(urls.map { makeFilePasteboardItem(for: $0) })
            toolID = "pdf.paste-pages-as-images"
        }
        markPasteboardWriteAsOwn()
        // Page-picker tools bypass applyTransformResult (we write to the
        // pasteboard directly), so usage tracking has to be done here too —
        // otherwise these tools never rise in the ToolRegistry ranking.
        AuthManager.shared.registerToolUsage(toolID: toolID)

        cleanupAfterPagePicker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulateCommandV()
        }
    }

    /// Common teardown after a page-picker commit / fatal-error exit.
    func cleanupAfterPagePicker() {
        exitPageRangeMode()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        inTransformStage = false
    }

    /// Preview what would be pasted on Enter.  Shows the actual artefacts:
    ///   .combinedPDF mode  → builds the would-be PDF, previews it
    ///   .perPageImages mode → renders the would-be PNGs, previews them
    ///                         (as a .files collection — first image shown,
    ///                         count indicated by the panel chrome).
    /// Second Space toggles off.
    func showPageRangePreview() {
        if itemPreviewPanel.isVisible {
            itemPreviewPanel.hide()
            return
        }
        let pages = pageRangeEffectiveSelection.sorted()
        guard !pages.isEmpty else {
            flashStatus("Select at least one page first.")
            return
        }
        guard let originalPDF = pageRangePDF else { return }

        switch pageRangeOutputMode {
        case .combinedPDF:
            guard let url = Self.buildCombinedPDF(from: originalPDF, pages: pages) else {
                flashStatus("Couldn't build PDF preview.")
                return
            }
            let previewItem = ClipboardItem(content: .file(url))
            itemPreviewPanel.show(for: previewItem, near: transformPanel.frame)

        case .perPageImages:
            let urls = Self.renderPagesAsImages(from: originalPDF, pages: pages)
            guard !urls.isEmpty else {
                flashStatus("Couldn't render image preview.")
                return
            }
            // Single page → preview as file; multiple → as files collection.
            let content: ClipboardContent = (urls.count == 1) ? .file(urls[0]) : .files(urls)
            let previewItem = ClipboardItem(content: content)
            itemPreviewPanel.show(for: previewItem, near: transformPanel.frame)
        }
    }

    // MARK: - Inline language picker control ("Translate")

    /// Switch the TransformPanel from its tool list into the language-picker
    /// view, same idea as `enterPageRangeMode`: the popup + transform panel
    /// stay open, only the content under the "Translate" row changes.
    func enterLanguagePickerMode(item: ClipboardItem) {
        languagePickerSourceItem     = item
        languagePickerQuery          = ""
        languagePickerSelectedIndex  = 0
        inLanguagePickerMode         = true
        flashStatus("Type to search · ↑↓ choose · ↵ translate · ⎋ cancel")
    }

    func exitLanguagePickerMode() {
        inLanguagePickerMode        = false
        languagePickerQuery         = ""
        languagePickerSelectedIndex = 0
        languagePickerSourceItem    = nil
    }

    /// Commit the picker: translate the source item's text to whichever
    /// language is currently highlighted, then paste through the exact same
    /// generic result path every other transform uses (usage tracking,
    /// pasteboard write, panel teardown) via `handleTransformResult`.
    func commitLanguagePickerTranslation() {
        guard let item = languagePickerSourceItem else {
            exitLanguagePickerMode()
            return
        }
        let languages = languagePickerFilteredLanguages
        guard languages.indices.contains(languagePickerSelectedIndex),
              let text = TextTools.input(for: item), AIService.fits(text) else {
            flashStatus("Nothing to translate.")
            exitLanguagePickerMode()
            return
        }
        let target = languages[languagePickerSelectedIndex]
        exitLanguagePickerMode()
        updateTransformPanelProcessing(true)
        Task { [weak self] in
            guard let self else { return }
            let translated = await AIService.transform(
                instructions: "You are a translator. Translate the given text to \(target.name). Output ONLY the translated text, no preamble, no explanation.",
                text: text
            )
            let result: TransformOutput = translated.map { .text($0) }
                ?? .status("Apple Intelligence couldn't translate this.")
            await MainActor.run {
                self.updateTransformPanelProcessing(false)
                self.inTransformStage = false
                self.transformIndex   = 0
                self.transformPanel.hide()
                self.itemPreviewPanel.hide()
                self.previewWindow.hide()
                self.markedItemIDs = []
                self.handleTransformResult(result, restoring: item, toolID: "ai.translate")
            }
        }
    }

    /// All non-⌘ keys while the language picker is open: letters/spaces build
    /// the search query, ↑/↓ move the highlight, ↵ commits, ⎋ cancels —
    /// mirrors `handlePageRangeKeyDown`'s structure exactly.
    func handleLanguagePickerKeyDown(key: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch key {
        case 53: // Esc — exit picker mode AND close the popup. Nothing pastes.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exitLanguagePickerMode()
                self.dismissPreview()
            }
            return nil
        case 51: // ⌫ Backspace
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.languagePickerQuery.isEmpty { self.languagePickerQuery.removeLast() }
                self.languagePickerSelectedIndex = 0
            }
            return nil
        case 36, 76: // Return / Enter — commit translation
            DispatchQueue.main.async { [weak self] in self?.commitLanguagePickerTranslation() }
            return nil
        case 126: // Up arrow
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let count = self.languagePickerFilteredLanguages.count
                guard count > 0 else { return }
                self.languagePickerSelectedIndex = (self.languagePickerSelectedIndex - 1 + count) % count
            }
            return nil
        case 125: // Down arrow
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let count = self.languagePickerFilteredLanguages.count
                guard count > 0 else { return }
                self.languagePickerSelectedIndex = (self.languagePickerSelectedIndex + 1) % count
            }
            return nil
        default:
            // Accept letters and spaces only — language names, nothing else.
            var length: Int = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4,
                                           actualStringLength: &length,
                                           unicodeString: &chars)
            guard length > 0 else { return nil }
            let typed = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
            let filtered = typed.filter { $0.isLetter || $0 == " " }
            if !filtered.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.languagePickerQuery += filtered
                    self.languagePickerSelectedIndex = 0
                }
            }
            return nil
        }
    }

    /// Construct a new PDFDocument from the user's selected page indices
    /// (0-based, ascending), write it to a unique file in Application
    /// Support/Clipen/Optimized/, and return the URL.  Pages are inserted
    /// IN ORDER — never re-rendered, never re-encoded.  The resulting PDF
    /// is bit-for-bit a subset of the original (just the chosen pages).
    static func buildCombinedPDF(from original: PDFDocument, pages: [Int]) -> URL? {
        guard !pages.isEmpty else { return nil }

        let newPDF = PDFDocument()
        var insertIdx = 0
        for srcIdx in pages {
            guard srcIdx >= 0, srcIdx < original.pageCount,
                  let page = original.page(at: srcIdx)?.copy() as? PDFPage else { continue }
            newPDF.insert(page, at: insertIdx)
            insertIdx += 1
        }
        guard newPDF.pageCount > 0 else { return nil }

        // Output filename includes the picked page numbers when reasonable
        // (≤4 pages); otherwise just "N pages".  Falls back to a UUID-based
        // path so two concurrent picks can't collide.
        let label: String
        if pages.count <= 4 {
            label = pages.map { String($0 + 1) }.joined(separator: "-")
        } else {
            label = "\(pages.count)-pages"
        }
        let fileName = "Clipen-Pages-\(label)-\(UUID().uuidString.prefix(8)).pdf"

        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName)

        guard newPDF.write(to: url) else { return nil }
        return url
    }

    /// Render each selected page to its own PNG file at 2× scale.  Returns
    /// the list of file URLs in ascending page order.  Files land in a
    /// dedicated subfolder per call so multiple invocations don't pollute
    /// each other's output.  No text extraction — pure raster of whatever
    /// is on the page (works for scanned PDFs, vector PDFs, anything).
    static func renderPagesAsImages(from original: PDFDocument, pages: [Int]) -> [URL] {
        guard !pages.isEmpty else { return [] }

        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        let dir = base.appendingPathComponent("PDF-Pages-\(UUID().uuidString.prefix(8))",
                                              isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        urls.reserveCapacity(pages.count)
        for srcIdx in pages {
            guard srcIdx >= 0, srcIdx < original.pageCount,
                  let page = original.page(at: srcIdx),
                  let pngData = renderPDFPageToPNG(page: page, scale: 2.0) else { continue }
            let filename = String(format: "page-%03d.png", srcIdx + 1)
            let url = dir.appendingPathComponent(filename)
            do {
                try pngData.write(to: url, options: .atomic)
                urls.append(url)
            } catch {
                continue
            }
        }
        return urls
    }

    /// Rasterise a single PDFPage to PNG data at the given scale.
    /// Same approach PDFService.exportPagesAsImages uses — kept local here
    /// so the page-picker doesn't have to reach across into the Tools layer.
    static func renderPDFPageToPNG(page: PDFPage, scale: CGFloat) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let width  = max(1, Int(bounds.width  * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Tell the polling capture loop that the *next* changeCount bump is our
    /// own write (so it doesn't re-capture our paste as a new clipboard item).
    /// Used by sub-panels (PageRangePanel, etc.) that write directly to
    /// NSPasteboard from outside the regular paste flow.
    func markPasteboardWriteAsOwn() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

    /// Post a synthetic ⌘V to the frontmost app.  Shared paste-simulation
    /// path for external panels.  Caller is responsible for restoring focus
    /// to the original app BEFORE calling this.
    func simulateCommandV() {
        let token = beginPasteSimulation()
        popupSessionPasted = true
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.endPasteSimulation(token: token)
        }
        AuthManager.shared.registerCommandVAction()
    }

    // MARK: - UI-driven navigation (mouse scroll & click in preview panels)

    func uiSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        multiSelectAnchorIndex = absoluteIndex
        resetAutoDismissTimer()
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// ⌘-click a row: Finder-style toggle of that single row into/out of the
    /// existing multi-selection, leaving every other mark untouched. Also
    /// becomes the new ⇧-click anchor, matching Finder.
    func uiToggleSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        multiSelectAnchorIndex = absoluteIndex
        resetAutoDismissTimer()
        toggleMark(id: displayItems[absoluteIndex].id)
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// ⇧-click a row: Finder-style contiguous range select from the anchor
    /// (the last plain- or ⌘-clicked row) through this row, replacing
    /// whatever was previously marked — not additive, matching Finder's
    /// plain ⇧-click (as opposed to ⌘⇧-click, which this app doesn't
    /// distinguish separately since a single range covers the common case).
    func uiRangeSelectItem(to absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        let anchor = multiSelectAnchorIndex.flatMap { displayItems.indices.contains($0) ? $0 : nil }
            ?? selectedIndex
        guard displayItems.indices.contains(anchor) else { return }
        let range = anchor <= absoluteIndex ? anchor...absoluteIndex : absoluteIndex...anchor
        selectedIndex = absoluteIndex
        resetAutoDismissTimer()
        markedItemIDs = range.map { displayItems[$0].id }
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    func uiSelectTransform(at index: Int) {
        guard inTransformStage, transformDisplaysCache.indices.contains(index) else { return }
        transformIndex = index
        updateTransformPanel()
    }

    func uiApplyTransform(at index: Int) {
        guard inTransformStage, transformDisplaysCache.indices.contains(index) else { return }
        transformIndex = index
        updateTransformPanel()
        commitPaste()
    }

    // MARK: - Multi-paste marking

    /// Toggle whether an item is marked for multi-paste.
    /// If it was not marked, it is appended (assigned the next mark number).
    /// If it was already marked, it is removed and the remaining marks renumber
    /// automatically (they are always positional in `markedItemIDs`).
    func toggleMark(id: UUID) {
        if let idx = markedItemIDs.firstIndex(of: id) {
            markedItemIDs.remove(at: idx)
        } else {
            markedItemIDs.append(id)
        }
    }

    /// 1-based position in the mark queue, or nil if not marked.
    func markOrder(for id: UUID) -> Int? {
        guard let idx = markedItemIDs.firstIndex(of: id) else { return nil }
        return idx + 1
    }

    // MARK: - Drag provider for multi-item drag

    /// Returns an NSItemProvider that carries all marked items (in marking order)
    /// for a system drag-and-drop operation. If no items are marked, falls back
    /// to the item at `selectedIndex`. Called by PopoverRow when a drag begins.
    func markedItemsDragProvider(fallback: ClipboardItem) -> NSItemProvider {
        let markedItems = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
        guard !markedItems.isEmpty else { return fallback.makeItemProvider() }
        return ClipboardItem.makeCombinedItemProvider(for: markedItems)
    }


}
