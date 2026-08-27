import AppKit
import SwiftUI
@preconcurrency import PDFKit

extension ClipboardManager {

    /// The one piece of math every shift-reverses-cycling feature shares
    /// (main ring, category filter, transform tools, share services,
    /// similar items): step an index by ±1 with wraparound. Each feature
    /// still wires its own key/hold-timer trigger (they differ: the main
    /// ring's V key, category's plain keydown, transform/share's
    /// hold-and-release), but the actual "shift = backward" arithmetic is
    /// this single function everywhere instead of five separate copies.
    static func cyclicIndex(_ index: Int, count: Int, backward: Bool) -> Int {
        guard count > 0 else { return 0 }
        return backward ? (index - 1 + count) % count : (index + 1) % count
    }

    func items(forIDs ids: some Sequence<UUID>) -> [ClipboardItem] {
        let index = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { index[$0] }
    }

    var orderedMarkedItems: [ClipboardItem] {
        items(forIDs: markedItemIDs)
    }

    func groupMarkedItems() {
        let marked = orderedMarkedItems
        guard marked.count >= 2 else { return }

        var children: [ClipboardItem] = []
        for m in marked {
            if case .group(let inner) = m.content { children.append(contentsOf: inner) }
            else { children.append(m) }
            if children.count >= Self.maxGroupItems { break }
        }
        children = Array(children.prefix(Self.maxGroupItems))
        guard children.count >= 2 else { return }

        let markedSet = Set(markedItemIDs)

        let insertAt = items.firstIndex(where: { $0.id == markedItemIDs.first }) ?? 0
        let anchorPinned = items.first(where: { $0.id == markedItemIDs.first })?.isPinned ?? false

        var groupItem = ClipboardItem(content: .group(children))
        groupItem.isPinned = anchorPinned

        let removedBefore = items.prefix(insertAt).filter { markedSet.contains($0.id) }.count
        items.removeAll { markedSet.contains($0.id) }
        let clampedIndex = min(max(0, insertAt - removedBefore), items.count)
        items.insert(groupItem, at: clampedIndex)

        markedItemIDs = []
        multiSelectAnchorIndex = nil
        markBlobPurgeNeeded()
        selectedIndex = displayItems.firstIndex(where: { $0.id == groupItem.id }) ?? 0
        selectionDidChange()
        AuthManager.shared.registerActionUsage(actionID: "action.group")
        markNudgeUsedNaturally(.groups)
    }

    func ungroup(_ item: ClipboardItem) {
        guard case .group(let children) = item.content,
              let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items.remove(at: idx)
        var insert = idx
        for child in children {
            var c = child
            c.isPinned = false
            items.insert(c, at: min(insert, items.count))
            insert += 1
        }
        markBlobPurgeNeeded()
        selectedIndex = min(idx, max(0, displayItems.count - 1))
        selectionDidChange()
        AuthManager.shared.registerActionUsage(actionID: "action.ungroup")
    }

    func enterTransformStage() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }

        // Nothing to transform: this entry's only text is its own label,
        // and the content it stands for lives on the system pasteboard
        // where no tool here can reach it.
        if displayItems[selectedIndex].isUncaptured {
            flashStatus(String(localized: "Clipen never received this copy, so it can't be transformed."))
            return
        }

        setSidePanelStage(.transform)
        markNudgeUsedNaturally(.transformPanel)

        let marked = orderedMarkedItems
        if marked.count >= 2 {
            let displays = MarkedToolRegistry.displays(for: marked)
            guard !displays.isEmpty else { setSidePanelStage(.none); return }
            transformingMarkedSet = true
            transformDisplaysCache = displays
            transformIndex = 0
            updateTransformPanel()
            return
        }

        refreshTransformDisplaysCache()
        guard !transformDisplaysCache.isEmpty else {
            setSidePanelStage(.none)
            return
        }
        transformIndex   = 0

        updateTransformPanel()
    }

    func cycleTransform() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformCycleCount += 1

        guard !transformDisplaysCache.isEmpty else { return }
        transformIndex = Self.cyclicIndex(transformIndex, count: transformDisplaysCache.count, backward: false)
        updateTransformPanel()
    }

    func cycleTransformBackward() {
        guard inTransformStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        transformCycleCount += 1

        guard !transformDisplaysCache.isEmpty else { return }
        transformIndex = Self.cyclicIndex(transformIndex, count: transformDisplaysCache.count, backward: true)
        updateTransformPanel()
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
        case .group(let items):

            return items.flatMap { shareRepresentations(for: $0) }
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

        setSidePanelStage(.share)
        shareTargetItems = targets
        shareServices = Self.rankedShareServices(services)
        shareIndex = 0
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
        shareIndex = Self.cyclicIndex(shareIndex, count: shareServices.count, backward: false)
        updateSharePanel()
    }

    func cycleShareBackward() {
        guard inShareStage, !shareServices.isEmpty else { return }
        shareIndex = Self.cyclicIndex(shareIndex, count: shareServices.count, backward: true)
        updateSharePanel()
    }

    func refreshShareStagePanel() {
        updateSharePanel()
    }

    private func updateSharePanel() {
        guard inShareStage else { return }
        let liveCount = shareCandidateItems.count
        let anchor = selectedRowAnchor()
        sharePanel.show(services: shareServices, selectedIndex: shareIndex,
                        itemCount: liveCount > 0 ? liveCount : shareTargetItems.count,
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
                      self.markedItemIDs.isEmpty,
                      self.displayItems.indices.contains(self.selectedIndex),
                      self.displayItems[self.selectedIndex].id == targetID else { return }
                guard !services.isEmpty else {
                    self.setSidePanelStage(.none)
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

    func commitShare() {
        guard inShareStage, shareServices.indices.contains(shareIndex) else {
            setSidePanelStage(.none)
            return
        }
        let service = shareServices[shareIndex]
        let liveTargets = shareCandidateItems
        let targets = liveTargets.isEmpty ? shareTargetItems : liveTargets
        var seenURLs = Set<String>()
        let rawItems = targets.flatMap { shareRepresentations(for: $0) }.filter { rep in
            guard let url = rep as? URL else { return true }
            return seenURLs.insert(url.absoluteString).inserted
        }

        let items: [Any]
        if rawItems.count > 1, rawItems.allSatisfy({ $0 is NSString }) {
            let combined = rawItems.compactMap { ($0 as? NSString) as String? }.joined(separator: "\n\n")
            items = [combined as NSString]
        } else {
            items = rawItems
        }
        AuthManager.shared.registerToolUsage(toolID: Self.shareUsageKey(service))
        setSidePanelStage(.none)
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

        let currentItem = displayItems[selectedIndex]
        if currentItem.id != lastTransformCacheItemID || transformDisplaysCache.isEmpty {
            lastTransformCacheItemID = currentItem.id
            transformDisplaysCache = ToolRegistry.displays(for: currentItem)
            transformIndex = 0
        }
        guard !transformDisplaysCache.isEmpty else {
            setSidePanelStage(.none)
            return
        }
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
            setSidePanelStage(.none)
            userOpenedItemPreview = true
            AuthManager.shared.registerActionUsage(actionID: "action.preview")
            recordNudgePreviewOpen()
            showSelectedItemPreview()
        }
    }

    func uiPreviewSelectedItem() {
        guard previewWindow.isVisible, !displayItems.isEmpty,
              selectedIndex < displayItems.count else { return }
        setSidePanelStage(.none)
        userOpenedItemPreview = true
        resetAutoDismissTimer()
        showSelectedItemPreview()
    }

    func showSelectedItemPreview() {
        ClipenSignpost.event("preview.request")
        let anchor = selectedRowAnchor()
        let current: ClipboardItem? = (!displayItems.isEmpty && selectedIndex < displayItems.count)
            ? displayItems[selectedIndex] : nil
        let marked = orderedMarkedItems
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

    func repositionAnchoredSidePanelForMeasuredRow() {
        guard previewWindow.isVisible else { return }
        if itemPreviewPanel.isVisible {
            showSelectedItemPreview()
        }
        if inTransformStage {
            updateTransformPanel()
        }
        if inShareStage {
            updateSharePanel()
        }
        if inSimilarStage {
            updateSimilarPanel()
        }
    }

    func applyCaseTransformForSelection(_ kind: CaseTransformKind) {
        guard previewWindow.isVisible, !isInlineEditing else { return }
        guard displayItems.indices.contains(selectedIndex) else { return }

        setSidePanelStage(.none)
        let item = displayItems[selectedIndex]
        guard let currentText = Self.editablePlainText(for: item) else {
            signalEditDenied(for: item.id)
            return
        }

        if let saved = caseTransformOriginals[item.id], saved.kind == kind {

            if case .file = item.content {
                updateFileItemText(id: item.id, newText: saved.text)
            } else {
                updateItemText(id: item.id, newText: saved.text)
            }
            caseTransformOriginals.removeValue(forKey: item.id)
        } else {

            let transformed: String
            switch kind {
            case .lowercase: transformed = currentText.lowercased()
            case .uppercase: transformed = currentText.uppercased()
            }
            guard transformed != currentText else { return }
            caseTransformOriginals[item.id] = (text: currentText, kind: kind)
            if case .file = item.content {
                updateFileItemText(id: item.id, newText: transformed)
            } else {
                updateItemText(id: item.id, newText: transformed)
            }
        }
        invalidateCachesAfterContentEdit()
        playInteractionSoundIfEnabled(.moveFront)
        userOpenedItemPreview = true

        showSelectedItemPreview()
        let toolID = kind == .uppercase ? "text.uppercase" : "text.lowercase"
        AuthManager.shared.registerToolUsage(toolID: toolID)
    }

    func beginInlineEditForSelection() {
        guard previewWindow.isVisible, !isInlineEditing else { return }
        guard displayItems.indices.contains(selectedIndex) else { return }
        beginInlineEdit(for: displayItems[selectedIndex])
    }

    func beginInlineEdit(for item: ClipboardItem) {

        if item.tags.contains(.markdown) {
            switch item.content {
            case .html, .richText, .rtfd:
                signalEditDenied(for: item.id)
                return
            default: break
            }
        }

        setSidePanelStage(.none)

        if let segs = TableCellExtractor.segments(for: item) {
            beginInlineMixedEdit(for: item, segments: segs)
            return
        }

        if let rows = TableCellExtractor.cells(for: item) {
            beginInlineTableEdit(for: item, rows: rows)
            return
        }

        if let attr = Self.editableAttributedString(for: item) {
            beginInlineRichEdit(for: item, attributedString: attr)
            return
        }
        guard let plain = Self.editablePlainText(for: item) else {

            signalEditDenied(for: item.id)
            return
        }
        beginInlineEditPresentation(for: item)

        let anchor = selectedRowAnchor()
        itemPreviewPanel.showEditor(
            for: item,
            initialText: plain,
            near: previewWindow.frame,
            anchorPoint: anchor,
            onCommit: { [weak self] newText in
                DispatchQueue.main.async { self?.commitInlineEdit(with: newText) }
            },
            onCommitAndPaste: { [weak self] newText in
                DispatchQueue.main.async { self?.commitInlineEditAndPaste(with: newText) }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async { self?.cancelInlineEdit() }
            })
        AuthManager.shared.registerToolUsage(toolID: "text.edit")
    }

    private func beginInlineEditPresentation(for item: ClipboardItem) {

        inlineEditItemID = item.id
        setSidePanelStage(.none)
        popupPinnedOpen = true
        stopAutoDismissTimer()
        userOpenedItemPreview = true
    }

    private func beginInlineTableEdit(for item: ClipboardItem, rows: [[String]]) {
        beginInlineEditPresentation(for: item)

        let anchor = selectedRowAnchor()
        itemPreviewPanel.showTableEditor(
            initialRows: rows,
            near: previewWindow.frame,
            anchorPoint: anchor,
            onCommit: { [weak self] newRows in
                DispatchQueue.main.async { self?.commitInlineTableEdit(with: newRows) }
            },
            onCommitAndPaste: { [weak self] newRows in
                DispatchQueue.main.async { self?.commitInlineTableEditAndPaste(with: newRows) }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async { self?.cancelInlineEdit() }
            })
        AuthManager.shared.registerToolUsage(toolID: "text.edit")
    }

    private func beginInlineMixedEdit(for item: ClipboardItem, segments: [ContentSegment]) {
        beginInlineEditPresentation(for: item)

        let anchor = selectedRowAnchor()
        itemPreviewPanel.showMixedEditor(
            initialSegments: segments,
            near: previewWindow.frame,
            anchorPoint: anchor,
            onCommit: { [weak self] newSegments in
                DispatchQueue.main.async { self?.commitInlineMixedEdit(with: newSegments) }
            },
            onCommitAndPaste: { [weak self] newSegments in
                DispatchQueue.main.async { self?.commitInlineMixedEditAndPaste(with: newSegments) }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async { self?.cancelInlineEdit() }
            })
        AuthManager.shared.registerToolUsage(toolID: "text.edit")
    }

    func commitInlineMixedEdit(with segments: [ContentSegment]) {
        guard let id = inlineEditItemID else { return }
        inlineEditItemID = nil
        saveInlineEditOriginal(for: id)
        updateItemMixed(id: id, segments: segments)
        finishInlineEditCommit()
    }

    private func beginInlineRichEdit(for item: ClipboardItem, attributedString: NSAttributedString) {
        beginInlineEditPresentation(for: item)

        let anchor = selectedRowAnchor()
        itemPreviewPanel.showRichEditor(
            initialAttributedString: attributedString,
            near: previewWindow.frame,
            anchorPoint: anchor,
            onCommit: { [weak self] editedAttr in
                DispatchQueue.main.async { self?.commitInlineRichEdit(with: editedAttr) }
            },
            onCommitAndPaste: { [weak self] editedAttr in
                DispatchQueue.main.async { self?.commitInlineRichEditAndPaste(with: editedAttr) }
            },
            onCancel: { [weak self] in
                DispatchQueue.main.async { self?.cancelInlineEdit() }
            })
        AuthManager.shared.registerToolUsage(toolID: "text.edit")
    }

    func commitInlineRichEdit(with attributedString: NSAttributedString) {
        guard let id = inlineEditItemID else { return }
        inlineEditItemID = nil
        saveInlineEditOriginal(for: id)
        updateItemRichText(id: id, editedAttributedString: attributedString)
        finishInlineEditCommit()
    }

    func commitInlineEdit(with newText: String) {
        guard let id = inlineEditItemID else { return }
        inlineEditItemID = nil
        saveInlineEditOriginal(for: id)
        if let item = items.first(where: { $0.id == id }), case .file = item.content {
            updateFileItemText(id: id, newText: newText)
        } else {
            updateItemText(id: id, newText: newText)
        }
        finishInlineEditCommit()
    }

    func commitInlineEditAndPaste(with newText: String) {
        commitInlineEditThenPaste { [self] in commitInlineEdit(with: newText) }
    }

    func commitInlineTableEdit(with rows: [[String]]) {
        guard let id = inlineEditItemID else { return }
        inlineEditItemID = nil
        saveInlineEditOriginal(for: id)
        updateItemTable(id: id, rows: rows)
        finishInlineEditCommit()
    }

    func commitInlineRichEditAndPaste(with attributedString: NSAttributedString) {
        commitInlineEditThenPaste { [self] in commitInlineRichEdit(with: attributedString) }
    }

    func commitInlineMixedEditAndPaste(with segments: [ContentSegment]) {
        commitInlineEditThenPaste { [self] in commitInlineMixedEdit(with: segments) }
    }

    func commitInlineTableEditAndPaste(with rows: [[String]]) {
        commitInlineEditThenPaste { [self] in commitInlineTableEdit(with: rows) }
    }

    private func invalidateCachesAfterContentEdit() {
        _displayItems = nil
        lastTransformCacheItemID = nil
        transformDisplaysCache = []
        ToolRegistry.invalidateCache()
    }

    private func finishInlineEditCommit() {
        invalidateCachesAfterContentEdit()
        endInlineEditPresentation()
    }

    private func commitInlineEditThenPaste(_ commit: () -> Void) {
        guard let id = inlineEditItemID else { return }
        commit()
        popupPinnedOpen = false
        guard let idx = displayItems.firstIndex(where: { $0.id == id }) else { return }
        selectedIndex = idx
        commitPaste()
    }

    func cancelInlineEdit() {
        guard isInlineEditing else { return }
        inlineEditItemID = nil
        endInlineEditPresentation()
    }

    private func saveInlineEditOriginal(for id: UUID) {
        guard inlineEditOriginals[id] == nil,
              let item = items.first(where: { $0.id == id }) else { return }
        inlineEditOriginals[id] = item.content
    }

    func revertInlineEdit(id: UUID) {
        guard let original = inlineEditOriginals.removeValue(forKey: id) else { return }
        replaceItemContent(id: id, newContent: original)
        TableCellExtractor.invalidate(itemID: id)
        invalidateCachesAfterContentEdit()
        flashStatus("Edit reverted.")
    }

    private func endInlineEditPresentation() {
        itemPreviewPanel.hide()

        userOpenedItemPreview = false
        if previewWindow.isVisible {
            startAutoDismissTimer()
            selectionDidChange()
        }
    }

    func applyAlwaysShowItemPreviewPolicy() {
        guard previewWindow.isVisible else {
            if autoPreviewTypes.isEmpty { itemPreviewPanel.hide() }
            return
        }
        syncItemPreviewWithSelection()
    }

    func selectionDidChange() {
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
        syncShareStageWithSelection()
        syncSimilarPanelWithSelection()
    }

    private static let itemPreviewSyncDelay: TimeInterval = 0.07

    func syncItemPreviewWithSelection() {

        guard previewWindow.isVisible else { return }
        if isInlineEditing { return }
        if sidePanelStage != .none { return }

        itemPreviewSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyItemPreviewSync()
        }
        itemPreviewSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.itemPreviewSyncDelay, execute: work)
    }

    func cancelPendingItemPreviewSync() {
        itemPreviewSyncWork?.cancel()
        itemPreviewSyncWork = nil
    }

    private func applyItemPreviewSync() {
        itemPreviewSyncWork = nil
        guard previewWindow.isVisible else { return }

        if isInlineEditing { return }

        if sidePanelStage != .none { return }
        if userOpenedItemPreview {
            if itemPreviewPanel.isVisible {
                showSelectedItemPreview()
                prefetchNeighborPreviews()
            }
            return
        }
        let autoShowsCurrent = !autoPreviewTypes.isEmpty
            && displayItems.indices.contains(selectedIndex)
            && autoPreviewTypes.contains(AutoPreviewContentType.from(displayItems[selectedIndex]))
        if autoShowsCurrent {
            showSelectedItemPreview()
            prefetchNeighborPreviews()
        } else if itemPreviewPanel.isVisible {
            if !autoPreviewTypes.isEmpty {
                itemPreviewPanel.hide()
            } else {
                showSelectedItemPreview()
                prefetchNeighborPreviews()
            }
        }
    }

    private func prefetchNeighborPreviews() {
        guard itemPreviewPanel.isVisible, !displayItems.isEmpty else { return }
        let lower = max(0, selectedIndex - 3)
        let upper = min(displayItems.count - 1, selectedIndex + 3)
        guard lower <= upper else { return }

        let windowIDs = Set((lower...upper).filter { $0 != selectedIndex }.map { displayItems[$0].id })

        prefetchedNeighborIDs.formIntersection(windowIDs)

        for idx in lower...upper where idx != selectedIndex {
            let item = displayItems[idx]
            guard !prefetchedNeighborIDs.contains(item.id) else { continue }
            prefetchedNeighborIDs.insert(item.id)
            PreviewPrefetcher.prefetch(item)
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
            write(item, to: pb, plainOnly: pastePlainTextByDefault)
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
        finalizePopupOutcome()
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
        Self.tagSynthetic(down); Self.tagSynthetic(up)
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            restoreSource()
            self.endPasteSimulation(token: token)
            self.selectedIndex = 0
        }
    }

    /// Taps of V faster than this land as instant, unanimated selection
    /// changes instead of retargeting the (0.35s response) spring that
    /// drives the image-elevation, row-highlight, and scroll-to effects.
    /// Below this interval the spring never gets close to converging
    /// before the next tap arrives — it's perpetually redirected mid-flight,
    /// which reads as stutter. Since an unanimated update fully resolves
    /// immediately, there's no "unfinished" state left over once a fast
    /// burst ends — the view is already exactly where it should be.
    /// Deliberate, slower taps still animate normally.
    private static let selectionAnimationCooldown: TimeInterval = 0.15

    @discardableResult
    private func withRateLimitedSelectionAnimation<T>(_ mutate: () -> T) -> T {
        let now = Date()
        let shouldAnimate = now.timeIntervalSince(lastAnimatedSelectionChangeAt) > Self.selectionAnimationCooldown
        lastAnimatedSelectionChangeAt = now
        guard shouldAnimate else {
            var t = Transaction(animation: nil)
            t.disablesAnimations = true
            return withTransaction(t, mutate)
        }
        return mutate()
    }

    func cycleNext() {
        let display = displayItems
        guard !display.isEmpty else { return }
        let wasVisible = previewWindow.isVisible

        let shouldContinue = withRateLimitedSelectionAnimation { () -> Bool in
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
                    return false
                } else if firstOpenDelay > 0 {
                    selectedIndex = 0
                    pendingFirstOpen = true
                    pendingFirstOpenTimer?.invalidate()
                    let t = Timer(timeInterval: firstOpenDelay, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async { self?.openPopoverAfterDelay() }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    pendingFirstOpenTimer = t
                    return false
                } else {
                    selectedIndex = 0
                    openPopupNow()
                }
            } else {
                selectedIndex = Self.cyclicIndex(selectedIndex, count: display.count, backward: false)
            }
            return true
        }
        guard shouldContinue else { return }

        ClipenSignpost.event("selection.target")

        cycleCount += 1

        if wasVisible {
            AuthManager.shared.registerActionUsage(actionID: "popup.nav")
        }

        selectionDidChange()
    }

    func cyclePrevious() {
        let display = displayItems
        guard !display.isEmpty else { return }
        let wasVisible = previewWindow.isVisible
        AuthManager.shared.registerActionUsage(actionID: "action.prev")

        withRateLimitedSelectionAnimation {
            if !previewWindow.isVisible {
                cancelPendingFirstOpen()
                selectedIndex = display.count - 1
                openPopupNow()
            } else {
                selectedIndex = Self.cyclicIndex(selectedIndex, count: display.count, backward: true)
            }
        }

        cycleCount += 1
        if wasVisible {
            AuthManager.shared.registerActionUsage(actionID: "popup.nav")
        }
        selectionDidChange()
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
        selectionDidChange()
    }

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
        selectionDidChange()
    }

    func cycleCategoryForward() {
        let total = 1 + availableTags.count
        guard total > 1 else { return }
        let current: Int
        if let filter = popupTagFilter,
           let pos = availableTags.firstIndex(where: { $0 == filter }) {
            current = pos + 1
        } else {
            current = 0
        }
        selectCategoryByIndex(Self.cyclicIndex(current, count: total, backward: false))
        AuthManager.shared.registerActionUsage(actionID: "action.next-category")

        popupHintCategory = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.popupHintCategory = false
        }
    }

    func cycleCategoryBackward() {
        let total = 1 + availableTags.count
        guard total > 1 else { return }
        let current: Int
        if let filter = popupTagFilter,
           let pos = availableTags.firstIndex(where: { $0 == filter }) {
            current = pos + 1
        } else {
            current = 0
        }
        selectCategoryByIndex(Self.cyclicIndex(current, count: total, backward: true))
        AuthManager.shared.registerActionUsage(actionID: "action.prev-category")

        popupHintCategory = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.popupHintCategory = false
        }
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
        if !isFirstOpen {
            AuthManager.shared.registerActionUsage(actionID: "popup.nav")
        }
        selectionDidChange()
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
        // Opening the popup means a copy or paste is imminent — treated the
        // same as an actually-detected pasteboard change for the poll
        // timer's idle backoff (see startPolling), so this doesn't sit at
        // the slow 500ms interval right when it matters most.
        lastPollActivityAt = Date()
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
        if rememberForeverBannerOpensRemaining > 0 {
            rememberForeverBannerOpensRemaining -= 1
        }

        ProGate.shared.evaluate()
        ProGate.shared.refresh()
        ClipenSignpost.event("popup.show")
        previewWindow.show()
        popupOpenGeneration += 1
        AuthManager.shared.registerActionUsage(actionID: "popup.open")
        popupOpenedAt = Date()
        popupSessionPasted = false
        popupSessionDeleted = false
        popupSessionAutoTimedOut = false
        popupSessionActive = true
        popupSessionOutcomeRecorded = false
        scheduleNudgeEvaluation()
        startAutoDismissTimer()
        selectionDidChange()
    }

    func startAutoDismissTimer() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = nil
        guard autoDismissEnabled, autoDismissSeconds > 0 else { return }
        let t = Timer(timeInterval: autoDismissSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.previewWindow.isVisible else { return }
                self.popupSessionAutoTimedOut = true
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
        setSidePanelStage(.none)
        previewWindow.hide()
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
        finalizePopupOutcome()
        let src  = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand; up?.flags = .maskCommand
        Self.tagSynthetic(down); Self.tagSynthetic(up)
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
        selectionDidChange()
    }

    func uiToggleSelectItem(at absoluteIndex: Int) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(absoluteIndex) else { return }
        selectedIndex = absoluteIndex
        multiSelectAnchorIndex = absoluteIndex
        resetAutoDismissTimer()
        toggleMark(id: displayItems[absoluteIndex].id)
        selectionDidChange()
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
        selectionDidChange()
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

    @discardableResult
    func toggleMark(id: UUID) -> Bool {
        // An uncaptured placeholder holds no content — only a label. Marking
        // it would feed that label into multi-paste, transforms or share as
        // if it were real text, pasting the words "Not captured…" into the
        // user's document. It can only ever be pasted alone, straight from
        // the system pasteboard, so it is never markable.
        if let item = items.first(where: { $0.id == id }), item.isUncaptured {
            flashStatus(String(localized: "This one can only be pasted on its own."))
            return false
        }
        let nowMarked: Bool
        if let idx = markedItemIDs.firstIndex(of: id) {
            markedItemIDs.remove(at: idx)
            nowMarked = false
        } else {
            markedItemIDs.append(id)
            nowMarked = true
        }
        if inShareStage { refreshShareTargetsForMarkChange() }
        return nowMarked
    }

    func refreshShareTargetsForMarkChange() {
        let targets = shareCandidateItems
        guard !targets.isEmpty else {
            setSidePanelStage(.none)
            return
        }
        let reps = targets.flatMap { shareRepresentations(for: $0) }
        let services = NSSharingService.sharingServices(forItems: reps)
        guard !services.isEmpty else {
            flashStatus("No share destinations available for the marked items.")
            setSidePanelStage(.none)
            return
        }
        let previousTitle = shareServices.indices.contains(shareIndex)
            ? shareServices[shareIndex].title : nil
        shareTargetItems = targets
        shareServices = Self.rankedShareServices(services)
        shareIndex = previousTitle.flatMap { title in
            shareServices.firstIndex(where: { $0.title == title })
        } ?? 0
        updateSharePanel()
    }

    func markOrder(for id: UUID) -> Int? {
        guard let idx = markedItemIDs.firstIndex(of: id) else { return nil }
        return idx + 1
    }

    func selectCollection(slot: Int) {
        if slot == 1 {
            if activeCollection != nil {
                AuthManager.shared.registerActionUsage(actionID: "action.collection-switch")
            }
            activeCollection = nil
            // activeCollection's own didSet already resets selectedIndex to
            // 0 on every assignment, including a same-value reassignment
            // (re-pressing the number for the collection already active).
            // What it can't do is move the *scroll position* back to the
            // top when selectedIndex's value doesn't actually change (was
            // already 0) — onChange(of: selectedIndex) only fires on a real
            // transition. collectionSwitchGeneration drives a dedicated,
            // animated scroll-to-top for exactly that case (a separate
            // counter from popupOpenGeneration, whose own scroll snap stays
            // instant since it also fires on ordinary popup-open).
            collectionSwitchGeneration += 1
            return
        }
        let index = slot - 2
        guard collections.indices.contains(index) else { return }
        if activeCollection != collections[index] {
            AuthManager.shared.registerActionUsage(actionID: "action.collection-switch")
        }
        activeCollection = collections[index]
        collectionSwitchGeneration += 1
    }

    var highestCollectionSlot: Int { collections.count + 1 }

    @discardableResult
    func addCollection(named rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        guard collections.count < Self.maxCollections else {
            flashStatus(String(localized: "Only \(Self.maxCollections) collections can exist at once."))
            return false
        }
        guard name.count <= Self.maxCollectionNameLength else {
            flashStatus(String(localized: "Collection names can be up to \(Self.maxCollectionNameLength) characters."))
            return false
        }
        guard !collections.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else {
            flashStatus(String(localized: "“\(name)” already exists."))
            return false
        }
        collections.append(name)
        AuthManager.shared.registerActionUsage(actionID: "action.collection-create")
        return true
    }

    func renameCollection(_ old: String, to rawNew: String) {
        let new = rawNew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, new != old,
              let slot = collections.firstIndex(of: old) else { return }
        guard new.count <= Self.maxCollectionNameLength else {
            flashStatus(String(localized: "Collection names can be up to \(Self.maxCollectionNameLength) characters."))
            return
        }
        guard !collections.contains(where: { $0.caseInsensitiveCompare(new) == .orderedSame }) else {
            flashStatus(String(localized: "“\(new)” already exists."))
            return
        }
        collections[slot] = new
        for i in items.indices where items[i].collections.contains(old) {
            items[i].collections.remove(old)
            items[i].collections.insert(new)
        }
        if activeCollection == old { activeCollection = new }
        _displayItems = nil
        AuthManager.shared.registerActionUsage(actionID: "action.collection-rename")
        saveHistory()
    }

    func deleteCollection(_ name: String) {
        guard let slot = collections.firstIndex(of: name) else { return }
        collections.remove(at: slot)
        items.removeAll { $0.collections == [name] }
        for i in items.indices where items[i].collections.contains(name) {
            items[i].collections.remove(name)
        }
        if activeCollection == name { activeCollection = nil }
        markBlobPurgeNeeded()
        _displayItems = nil
        AuthManager.shared.registerActionUsage(actionID: "action.collection-delete")
        saveHistory()
    }

    func moveItem(_ id: UUID, toCollection target: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if let activeCollection { items[idx].collections.remove(activeCollection) }
        items[idx].collections.insert(target)
        _displayItems = nil
        saveHistory()
        AuthManager.shared.registerActionUsage(actionID: "action.collection-move")
    }

    func shareItem(_ id: UUID, toCollection target: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].collections.insert(target)
        _displayItems = nil
        saveHistory()
        AuthManager.shared.registerActionUsage(actionID: "action.collection-share")
    }

}
