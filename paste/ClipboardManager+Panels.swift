import AppKit
import SwiftUI
@preconcurrency import PDFKit

extension ClipboardManager {

    var orderedMarkedItems: [ClipboardItem] {
        markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
    }

    func enterTransformStage() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        if itemPreviewPanel.isVisible { itemPreviewPanel.hide() }
        userOpenedItemPreview = false
        if inShareStage { exitShareStage() }

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

        guard !transformDisplaysCache.isEmpty else { return }
        transformIndex = (transformIndex + 1) % transformDisplaysCache.count
        updateTransformPanel()

        if popupCoachStep == 1 && transformCycleCount >= 3 {
            popupCoachStep = 2
        }
    }

    func cycleTransformBackward() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformCycleCount += 1

        guard !transformDisplaysCache.isEmpty else { return }
        let n = transformDisplaysCache.count
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

    private var shareCandidateItems: [ClipboardItem] {
        let marked = orderedMarkedItems
        if !marked.isEmpty { return marked }
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return [] }
        return [displayItems[selectedIndex]]
    }

    private func shareRepresentations(for item: ClipboardItem) -> [Any] {
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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.contains(" "), !trimmed.contains("\n"),
               let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                return [url]
            }
            return [text as NSString]
        }
    }

    private static func shareTempFile(_ data: Data, ext: String, id: UUID) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipenShare", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneStaleShareFiles(in: dir)
        let url = dir.appendingPathComponent("Clipen-\(id.uuidString).\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func pruneStaleShareFiles(in dir: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for url in entries {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
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

    private static func shareUsageKey(_ service: NSSharingService) -> String {
        "share.\(service.title)"
    }

    func cycleShare() {
        guard inShareStage, !shareServices.isEmpty else { return }
        shareIndex = (shareIndex + 1) % shareServices.count
        updateSharePanel()
    }

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

    func syncShareStageWithSelection() {
        guard inShareStage, previewWindow.isVisible,
              !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        if !markedItemIDs.isEmpty {
            updateSharePanel()
            return
        }
        let newTarget = displayItems[selectedIndex]
        if shareTargetItems.count == 1, shareTargetItems.first?.id == newTarget.id {
            updateSharePanel()
            return
        }
        if let cached = shareServicesCache[newTarget.id] {
            applyShareTarget(newTarget, services: cached)
            return
        }
        updateSharePanel()
        shareSyncGeneration += 1
        let gen = shareSyncGeneration
        let targetID = newTarget.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let items = self.shareRepresentations(for: newTarget)
            let services = NSSharingService.sharingServices(forItems: items)
            DispatchQueue.main.async {
                guard self.inShareStage, self.shareSyncGeneration == gen,
                      self.displayItems.indices.contains(self.selectedIndex),
                      self.displayItems[self.selectedIndex].id == targetID else { return }
                guard !services.isEmpty else {
                    self.exitShareStage()
                    return
                }
                self.shareServicesCache[targetID] = services
                self.applyShareTarget(newTarget, services: services)
            }
        }
    }

    private func applyShareTarget(_ target: ClipboardItem, services: [NSSharingService]) {
        shareTargetItems = [target]
        shareServices = Self.rankedShareServices(services)
        shareIndex = 0
        updateSharePanel()
    }

    func exitShareStage() {
        inShareStage = false
        shareServices = []
        shareTargetItems = []
        shareServicesCache = [:]
        shareIndex = 0
        sharePanel.hide()
    }

    func commitShare() {
        guard inShareStage, shareServices.indices.contains(shareIndex) else {
            exitShareStage()
            return
        }
        let service = shareServices[shareIndex]
        let items = shareTargetItems.flatMap { shareRepresentations(for: $0) }
        AuthManager.shared.registerToolUsage(toolID: Self.shareUsageKey(service))
        exitShareStage()
        markedItemIDs = []
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
        guard !items.isEmpty else { return }
        service.perform(withItems: items)
        AuthManager.shared.registerActionUsage(actionID: "action.share")
    }

    func refreshTransformDisplaysCache() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else {
            transformDisplaysCache = []
            lastTransformCacheItemID = nil
            return
        }
        let currentItem = displayItems[selectedIndex]
        if currentItem.id == lastTransformCacheItemID, !transformDisplaysCache.isEmpty {
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

    func syncTransformPanelWithSelection() {
        guard !transformingMarkedSet else { return }
        guard inTransformStage, previewWindow.isVisible,
              !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformDisplaysCache = ToolRegistry.displays(for: displayItems[selectedIndex])
        guard !transformDisplaysCache.isEmpty else {
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
            if inTransformStage { exitTransformStage() }
            if inShareStage { exitShareStage() }
            userOpenedItemPreview = true
            AuthManager.shared.registerActionUsage(actionID: "action.preview")
            showSelectedItemPreview()
        }
    }

    func uiPreviewSelectedItem() {
        guard previewWindow.isVisible, !displayItems.isEmpty,
              selectedIndex < displayItems.count else { return }
        if inTransformStage { exitTransformStage() }
        if inShareStage { exitShareStage() }
        userOpenedItemPreview = true
        resetAutoDismissTimer()
        showSelectedItemPreview()
    }

    func showSelectedItemPreview() {
        ClipenSignpost.event("preview.request")
        let anchor = selectedRowAnchor()
        let current: ClipboardItem? = (!displayItems.isEmpty && selectedIndex < displayItems.count)
            ? displayItems[selectedIndex] : nil
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

    func syncItemPreviewWithSelection() {
        guard previewWindow.isVisible else { return }
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
                itemPreviewPanel.hide()
            } else {
                showSelectedItemPreview()
            }
        }
    }

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

    func pasteGeneratedTransformItem(_ item: ClipboardItem, message: String, restoring source: ClipboardItem) {
        pasteGeneratedItem(item, message: message, restoring: source)
    }

    func pasteGeneratedTransformFiles(_ urls: [URL], message: String, restoring source: ClipboardItem) {
        pasteGeneratedFiles(urls, message: message, restoring: source)
    }

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

    func finishTransformPaste(message: String?, restoring source: ClipboardItem?) {
        let pasteTarget = resolvedPasteTarget()
        if let source { recordPasteDestination(for: source.id, app: pasteTarget) }
        AuthManager.shared.registerCommandVAction()
        popupSessionPasted = true
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        if let message { flashStatus(message) }

        let token = beginPasteSimulation()

        let restoreSource: () -> Void = { [weak self] in
            guard let self, let source else { return }
            let pb = NSPasteboard.general
            pb.clearContents()
            self.write(source, to: pb)
            self.lastChangeCount = pb.changeCount
        }

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
            restoreSource()
            self.endPasteSimulation(token: token)
            self.selectedIndex = 0
        }
    }

    func cycleNext() {
        let display = displayItems
        guard !display.isEmpty else { return }

        if !previewWindow.isVisible {
            if pendingFirstOpen {
                cancelPendingFirstOpen()
                openPopupNow()
                selectedIndex = min(1, display.count - 1)
            } else if openOnSecondTap {
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
        ClipenSignpost.event("selection.target")

        cycleCount += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.nav")

        if popupCoachStep == 0 && cycleCount >= 3 { popupCoachStep = 1 }

        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
        syncShareStageWithSelection()
    }

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
        syncShareStageWithSelection()
    }

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
            selectedIndex = pinnedIndices[0]
        }
        resetAutoDismissTimer()
        AuthManager.shared.registerActionUsage(actionID: "action.cycle_pinned")
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
        syncShareStageWithSelection()
    }

    static let numberRowKeycodeToIndex: [Int64: Int] = [
        18: 0,
        19: 1,
        20: 2,
        21: 3,
        23: 4,
        22: 5,
        26: 6,
        28: 7,
        25: 8,
    ]

    func selectCategoryByIndex(_ idx: Int) {
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
        syncShareStageWithSelection()
    }

    func jumpForward(by step: Int = 5) {
        let display = displayItems
        guard !display.isEmpty else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.jump5")

        let isFirstOpen = !previewWindow.isVisible
        if isFirstOpen {
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
        syncShareStageWithSelection()
    }

    func openPopoverAfterDelay() {
        guard pendingFirstOpen else { return }
        pendingFirstOpen = false
        pendingFirstOpenTimer = nil
        guard !displayItems.isEmpty else { return }
        openPopupNow()
        cycleCount += 1
    }

    func openPopupNow() {
        popupTagFilter = nil
        let withinRememberWindow: Bool = {
            guard let savedAt = rememberedSelectionSavedAt else { return false }
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
        capturedPasteTarget = NSWorkspace.shared.frontmostApplication
        ClipenSignpost.event("popup.show")
        previewWindow.show()
        popupOpenGeneration += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.open")
        popupOpenedAt = Date()
        popupSessionPasted = false
        startAutoDismissTimer()
        syncItemPreviewWithSelection()
    }

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

    func resetAutoDismissTimer() {
        guard previewWindow.isVisible else { return }
        startAutoDismissTimer()
    }

    func stopAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
    }

    func captureRememberedSelection() {
        if displayItems.indices.contains(selectedIndex) {
            rememberedIndex  = selectedIndex
            rememberedItemID = displayItems[selectedIndex].id
            rememberedSelectionSavedAt = Date()
        }
    }

    func enterPageRangeMode(pdf: PDFDocument, item: ClipboardItem, outputMode: PageRangeOutputMode = .combinedPDF) {
        pageRangePDF        = pdf
        pageRangePageCount  = pdf.pageCount
        pageRangeQuery      = ""
        pageRangeManualPages = []
        pageRangeOutputMode  = outputMode
        inPageRangeMode      = true

        stopAutoDismissTimer()

        let modeLabel = (outputMode == .perPageImages) ? "images" : "PDF"
        flashStatus("Pick pages → \(modeLabel) · ↵ paste · ␣ preview")

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
        if previewWindow.isVisible { startAutoDismissTimer() }
    }

    func togglePageRangeManualPage(_ index: Int) {
        if pageRangeManualPages.contains(index) {
            pageRangeManualPages.remove(index)
        } else {
            pageRangeManualPages.insert(index)
        }
    }

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
        AuthManager.shared.registerToolUsage(toolID: toolID)

        cleanupAfterPagePicker()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulateCommandV()
        }
    }

    func cleanupAfterPagePicker() {
        exitPageRangeMode()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        inTransformStage = false
    }

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
            let content: ClipboardContent = (urls.count == 1) ? .file(urls[0]) : .files(urls)
            let previewItem = ClipboardItem(content: content)
            itemPreviewPanel.show(for: previewItem, near: transformPanel.frame)
        }
    }

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

    func handleLanguagePickerKeyDown(key: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch key {
        case 53:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exitLanguagePickerMode()
                self.dismissPreview()
            }
            return nil
        case 51:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.languagePickerQuery.isEmpty { self.languagePickerQuery.removeLast() }
                self.languagePickerSelectedIndex = 0
            }
            return nil
        case 36, 76:
            DispatchQueue.main.async { [weak self] in self?.commitLanguagePickerTranslation() }
            return nil
        case 126:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let count = self.languagePickerFilteredLanguages.count
                guard count > 0 else { return }
                self.languagePickerSelectedIndex = (self.languagePickerSelectedIndex - 1 + count) % count
            }
            return nil
        case 125:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let count = self.languagePickerFilteredLanguages.count
                guard count > 0 else { return }
                self.languagePickerSelectedIndex = (self.languagePickerSelectedIndex + 1) % count
            }
            return nil
        default:
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

    func markPasteboardWriteAsOwn() {
        lastChangeCount = NSPasteboard.general.changeCount
    }

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

    func uiSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        multiSelectAnchorIndex = absoluteIndex
        resetAutoDismissTimer()
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
        syncShareStageWithSelection()
    }

    func uiToggleSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        multiSelectAnchorIndex = absoluteIndex
        resetAutoDismissTimer()
        toggleMark(id: displayItems[absoluteIndex].id)
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
        syncShareStageWithSelection()
    }

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
        syncShareStageWithSelection()
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

    func toggleMark(id: UUID) {
        if let idx = markedItemIDs.firstIndex(of: id) {
            markedItemIDs.remove(at: idx)
        } else {
            markedItemIDs.append(id)
        }
    }

    func markOrder(for id: UUID) -> Int? {
        guard let idx = markedItemIDs.firstIndex(of: id) else { return nil }
        return idx + 1
    }

    func markedItemsDragProvider(fallback: ClipboardItem) -> NSItemProvider {
        let markedItems = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
        guard !markedItems.isEmpty else { return fallback.makeItemProvider() }
        return ClipboardItem.makeCombinedItemProvider(for: markedItems)
    }

}
