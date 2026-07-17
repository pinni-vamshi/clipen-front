import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import PDFKit

extension ClipboardManager {

    static let injectionBundleIDs: Set<String> = [
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    static let maxInjectionLength = 5_000

    func shouldInjectCharacters(to app: NSRunningApplication?) -> Bool {
        if app == nil { return true }
        if Self.focusedAppIsSpotlight() { return true }
        guard let id = app?.bundleIdentifier else { return false }
        return Self.injectionBundleIDs.contains(id)
    }

    static func focusedAppIsSpotlight() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
        else { return false }
        let axApp = focusedAppRef as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(axApp, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return false }
        return app.bundleIdentifier == "com.apple.Spotlight"
    }

    func extractTextForInjection(from item: ClipboardItem) -> String? {
        guard let t = item.content.plainText, !t.isEmpty else { return nil }
        return t
    }

    func injectCharacters(_ text: String, completion: (() -> Void)? = nil) {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide,
                                         kAXFocusedUIElementAttribute as CFString,
                                         &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement
            if AXUIElementSetAttributeValue(focused,
                                            kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success {
                completion?()
                return
            }
        }

        let src = CGEventSource(stateID: .hidSystemState)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) {
            for scalar in text.unicodeScalars {
                var chars: [UniChar]
                if scalar.value <= 0xFFFF {
                    chars = [UniChar(scalar.value)]
                } else {
                    let v = scalar.value - 0x10000
                    chars = [UniChar(0xD800 | (v >> 10)), UniChar(0xDC00 | (v & 0x3FF))]
                }
                chars.withUnsafeBufferPointer { ptr in
                    guard let base = ptr.baseAddress else { return }
                    if let dn = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                        dn.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
                        dn.post(tap: .cghidEventTap)
                    }
                    if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
                        up.post(tap: .cghidEventTap)
                    }
                }
            }
            DispatchQueue.main.async { completion?() }
        }
    }

    func recordPasteDestination(for itemID: UUID, app: NSRunningApplication? = nil) {
        guard let dest = app ?? NSWorkspace.shared.frontmostApplication else { return }
        recordPaste(itemID: itemID,
                    appName: dest.localizedName,
                    bundleID: dest.bundleIdentifier)
    }

    func recordPaste(itemID: UUID, appName: String?, bundleID: String?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].pastedToAppName  = appName
        items[idx].pastedToBundleID = bundleID
        items[idx].lastPastedAt     = Date()
        items[idx].pasteCount      += 1
        if let bid = bundleID {
            items[idx].pasteCountByApp[bid, default: 0] += 1
            if let name = appName {
                items[idx].pastedToAppNames[bid] = name
            }
        }
    }

    func resolvedPasteTarget() -> NSRunningApplication? {
        if popupPinnedOpen,
           let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            return front
        }
        guard let target = capturedPasteTarget else {
            return NSWorkspace.shared.frontmostApplication
        }
        if NSWorkspace.shared.frontmostApplication != target {
            target.activate(options: [])
        }
        return target
    }

    func pasteSingleFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([makeFilePasteboardItem(for: url)])
        markPasteboardWriteAsOwn()
        _ = resolvedPasteTarget()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.simulateCommandV()
        }
    }

    func commitPaste() {
        if inShareStage {
            commitShare()
            return
        }
        vTapHoldTimer?.invalidate()
        vTapHoldTimer = nil
        bTapHoldTimer?.invalidate()
        bTapHoldTimer = nil
        pTapHoldTimer?.invalidate()
        pTapHoldTimer = nil
        sTapHoldTimer?.invalidate()
        sTapHoldTimer = nil
        xTapHoldTimer?.invalidate()
        xTapHoldTimer = nil
        if previewWindow.isVisible, let openedAt = popupOpenedAt {
            let ms = max(0, Int(Date().timeIntervalSince(openedAt) * 1000))
            AuthManager.shared.registerActionUsage(actionID: "popup.dur_ms", count: ms)
            popupOpenedAt = nil
        }
        isSearchActive = false
        guard !items.isEmpty else {
            previewWindow.hide()
            transformPanel.hide()
            itemPreviewPanel.hide()
            markedItemIDs = []
            return
        }
        captureRememberedSelection()

        if inTransformStage, transformingMarkedSet {
            let markedItems = orderedMarkedItems
            guard markedItems.count >= 2,
                  transformDisplaysCache.indices.contains(transformIndex) else {
                exitTransformStage()
                previewWindow.hide()
                markedItemIDs = []
                return
            }
            let toolID = transformDisplaysCache[transformIndex].id
            updateTransformPanelProcessing(true)
            Task { [weak self] in
                guard let self else { return }
                let result = await MarkedToolRegistry.run(items: markedItems, toolID: toolID)
                if let result, self.transformResultCountsAsUsage(result) {
                    TrackingService.shared.recordMarkedBatch(id: toolID, size: markedItems.count)
                }
                await MainActor.run {
                    self.updateTransformPanelProcessing(false)
                    self.inTransformStage = false
                    self.transformingMarkedSet = false
                    self.transformIndex = 0
                    self.transformPanel.hide()
                    self.itemPreviewPanel.hide()
                    self.previewWindow.hide()
                    self.markedItemIDs = []
                    self.handleTransformResult(result, restoring: markedItems[0], toolID: toolID)
                }
            }
            return
        }

        if inTransformStage {
            guard displayItems.indices.contains(selectedIndex) else {
                previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
                markedItemIDs = []
                return
            }
            let item     = displayItems[selectedIndex]
            let idx      = transformIndex
            let selectedToolID = transformDisplaysCache.indices.contains(idx)
                ? transformDisplaysCache[idx].id
                : ToolRegistry.toolID(item: item, index: idx)
            guard let selectedToolID else {
                flashStatus("Selected tool is unavailable.")
                return
            }

            if selectedToolID == "pdf.paste-pages" || selectedToolID == "pdf.paste-pages-as-images" {
                if let input = PDFTools.pdfInput(for: item) {
                    let mode: PageRangeOutputMode =
                        (selectedToolID == "pdf.paste-pages-as-images") ? .perPageImages : .combinedPDF
                    enterPageRangeMode(pdf: input.pdf, item: item, outputMode: mode)
                    return
                } else {
                    flashStatus("Couldn't open PDF for page picker.")
                    return
                }
            }

            if selectedToolID == "ai.translate" {
                enterLanguagePickerMode(item: item)
                return
            }

            let isAsync  = ToolRegistry.isAsync(item: item, toolID: selectedToolID)

            if isAsync {
                updateTransformPanelProcessing(true)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await ToolRegistry.run(item: item, toolID: selectedToolID)
                    await MainActor.run {
                        self.updateTransformPanelProcessing(false)
                        self.inTransformStage = false
                        self.transformIndex   = 0
                        self.transformDisplaysCache = []
                        self.lastTransformCacheItemID = nil
                        self.transformingMarkedSet = false
                        self.transformPanel.hide()
                        self.itemPreviewPanel.hide()
                        self.previewWindow.hide()
                        self.markedItemIDs = []
                        self.handleTransformResult(result, restoring: item, toolID: selectedToolID)
                    }
                }
                return
            } else {
                let result = applySyncTransform(item: item, toolID: selectedToolID)
                inTransformStage = false; transformIndex = 0
                transformDisplaysCache = []
                lastTransformCacheItemID = nil
                transformingMarkedSet = false
                transformPanel.hide()
                itemPreviewPanel.hide()
                previewWindow.hide()
                markedItemIDs = []
                handleTransformResult(result, restoring: item, toolID: selectedToolID)
                return
            }
        }

        inTransformStage = false; transformIndex = 0

        if !markedItemIDs.isEmpty {
            let ids = Set(markedItemIDs)
            markedItemIDs = []
            let displayOrder = Dictionary(uniqueKeysWithValues: displayItems.enumerated().map { ($1.id, $0) })
            let orderedItems = ids.compactMap { id in items.first(where: { $0.id == id }) }
                .sorted { (displayOrder[$0.id] ?? Int.max) < (displayOrder[$1.id] ?? Int.max) }
            guard !orderedItems.isEmpty else {
                previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
                return
            }
            let pasteTarget = resolvedPasteTarget()
            previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
            commitMultiPaste(orderedItems, target: pasteTarget)
            AuthManager.shared.registerCommandVAction()
            return
        }

        let item: ClipboardItem
        if let id = pendingPasteItemID, let found = items.first(where: { $0.id == id }) {
            item = found
        } else if displayItems.indices.contains(selectedIndex) {
            item = displayItems[selectedIndex]
        } else {
            previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
            return
        }
        pendingPasteItemID = nil
        recordPasteAnalytics(item: item,
                             displayIndex: displayItems.firstIndex(where: { $0.id == item.id }))
        let pasteTarget = resolvedPasteTarget()
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
        simulatePaste(item, target: pasteTarget) { [weak self] in
            self?.selectedIndex = 0
            self?.cycleCount    = 0
        }
    }

    func recordPasteAnalytics(item: ClipboardItem, displayIndex: Int?) {
        if let idx = displayIndex, idx >= 0 {
            TrackingService.shared.recordPastePosition(idx)
        }
    }

    func simulatePaste(_ item: ClipboardItem, target: NSRunningApplication?,
                              completion: (() -> Void)? = nil) {
        popupSessionPasted = true
        finalizePopupOutcome()
        recordPasteDestination(for: item.id, app: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb, plainOnly: pastePlainTextByDefault)
        lastChangeCount = pb.changeCount

        let token = beginPasteSimulation()

        if let text = extractTextForInjection(from: item),
           text.count <= Self.maxInjectionLength,
           shouldInjectCharacters(to: target) {
            injectCharacters(text) { [weak self] in
                self?.endPasteSimulation(token: token)
                completion?()
            }
        } else {
            let src  = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.endPasteSimulation(token: token)
                completion?()
            }
        }
        AuthManager.shared.registerCommandVAction()
    }

    func pasteItemKeepingPopupOpen(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        recordPasteAnalytics(item: item,
                             displayIndex: displayItems.firstIndex(where: { $0.id == id }))
        simulatePaste(item, target: resolvedPasteTarget())
    }

    func commitMultiPaste(_ itemList: [ClipboardItem], target: NSRunningApplication?) {
        guard !itemList.isEmpty else {
            isSimulatingPaste = false
            selectedIndex = 0; cycleCount = 0
            return
        }
        popupSessionPasted = true
        finalizePopupOutcome()
        recordPasteAnalytics(item: itemList[0], displayIndex: nil)
        let item      = itemList[0]
        let remaining = Array(itemList.dropFirst())

        let token = beginPasteSimulation()
        recordPasteDestination(for: item.id)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb, plainOnly: pastePlainTextByDefault)
        lastChangeCount = pb.changeCount

        if let text = extractTextForInjection(from: item),
           text.count <= Self.maxInjectionLength,
           shouldInjectCharacters(to: target) {
            injectCharacters(text) { [weak self] in
                guard let self else { return }
                if remaining.isEmpty {
                    self.endPasteSimulation(token: token)
                    self.selectedIndex = 0; self.cycleCount = 0
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.commitMultiPaste(remaining, target: target)
                    }
                }
            }
        } else {
            let src  = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
            down?.flags = .maskCommand; up?.flags = .maskCommand
            down?.post(tap: .cgAnnotatedSessionEventTap)
            up?.post(tap: .cgAnnotatedSessionEventTap)
            let delay: TimeInterval = remaining.isEmpty ? 0.2 : 0.28
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                if remaining.isEmpty {
                    self.endPasteSimulation(token: token)
                    self.selectedIndex = 0; self.cycleCount = 0
                } else {
                    self.commitMultiPaste(remaining, target: target)
                }
            }
        }
    }

    func applySidecar(_ item: ClipboardItem, to pitem: NSPasteboardItem) {
        guard let sidecar = item.sidecarTypes else { return }
        let existing = Set(pitem.types.map(\.rawValue))
        for (typeStr, data) in sidecar where !existing.contains(typeStr) {
            pitem.setData(data, forType: .init(typeStr))
        }
    }

    /// RTF bytes for `attrStr`, but only when it's safe — RTF can't carry
    /// embedded image attachments, so this returns nil rather than silently
    /// converting one away. Shared by the `.richText` and `.rtfd` write
    /// cases above, which otherwise each need this exact same check.
    static func safeRTFData(for attrStr: NSAttributedString, sidecarRTF: Data? = nil) -> Data? {
        guard !attrStr.containsAttachments else { return nil }
        if let sidecarRTF { return sidecarRTF }
        let range = NSRange(location: 0, length: attrStr.length)
        return try? attrStr.data(from: range,
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    func write(_ item: ClipboardItem, to pb: NSPasteboard, plainOnly: Bool = false) {
        if plainOnly {
            switch item.content {
            case .richText(_, let plain), .rtfd(_, let plain), .html(_, let plain):
                let pitem = NSPasteboardItem()
                pitem.setString(plain, forType: .string)
                pb.writeObjects([pitem])
                return
            default:
                break
            }
        }
        switch item.content {
        case .text(let str):
            let pitem = NSPasteboardItem()
            pitem.setString(str, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .image(let img, let rawData, let dataType):
            let pitem = NSPasteboardItem()
            pitem.setData(rawData, forType: dataType)
            if let compat = ImageService.compatibilityPasteboardPayload(
                image: img, rawData: rawData, dataType: dataType
            ), compat.type != dataType {
                pitem.setData(compat.data, forType: compat.type)
            }
            if ImageService.shouldAttachTiffFallback(for: dataType),
               let tiff = img.tiffRepresentation {
                pitem.setData(tiff, forType: .tiff)
            }
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .richText(let attrStr, let plain):
            let pitem = NSPasteboardItem()
            if attrStr.containsAttachments {
                // Plain .rtf can't carry NSTextAttachment images — build RTFD
                // on the fly instead so there's a real image-bearing
                // representation on the pasteboard (there's no pre-existing
                // .rtfd data to reuse here, unlike the .rtfd case below).
                let range = NSRange(location: 0, length: attrStr.length)
                if let rtfdData = try? attrStr.data(from: range,
                                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                    pitem.setData(rtfdData, forType: .rtfd)
                }
            } else if let rtfData = Self.safeRTFData(for: attrStr, sidecarRTF: item.sidecarTypes?["public.rtf"]) {
                pitem.setData(rtfData, forType: .rtf)
            }
            pitem.setString(plain, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .rtfd(let rtfdData, let plain):
            let pitem = NSPasteboardItem()
            pitem.setData(rtfdData, forType: .rtfd)
            if let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil),
               let rtfData = Self.safeRTFData(for: attrStr) {
                pitem.setData(rtfData, forType: .rtf)
            }
            pitem.setString(plain, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .html(let html, let plain):
            let pitem = NSPasteboardItem()
            pitem.setData(Data(html.utf8), forType: .init("public.html"))
            pitem.setData(Data(html.utf8), forType: .init("Apple HTML pasteboard type"))
            pitem.setString(plain, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .file(let url):
            let pitem = makeFilePasteboardItem(for: url)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .files(let urls):
            let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { return }
            let pitems = existing.map { makeFilePasteboardItem(for: $0) }
            if let first = pitems.first { applySidecar(item, to: first) }
            pb.writeObjects(pitems)

        case .svg(let src):
            let pitem = NSPasteboardItem()
            let data = Data(src.utf8)
            pitem.setData(data, forType: .init("public.svg-image"))
            pitem.setString(src, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .blob(let typeMap):
            let pitem = NSPasteboardItem()
            for (typeStr, data) in typeMap {
                pitem.setData(data, forType: .init(typeStr))
            }
            pb.writeObjects([pitem])
        }
    }

    func makeFilePasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()

        item.setData(url.dataRepresentation, forType: .fileURL)
        item.setPropertyList([url.path], forType: .init("NSFilenamesPboardType"))

        let maxInlineBytes = Self.maxDataBytes
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey]),
              values.isDirectory != true,
              let fileSize = values.fileSize, fileSize <= maxInlineBytes,
              let data = try? Data(contentsOf: url) else { return item }

        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            item.setData(data, forType: .init("com.adobe.pdf"))
            item.setData(data, forType: .init("public.pdf"))
        case "png":
            item.setData(data, forType: .init("public.png"))
        case "jpg", "jpeg":
            item.setData(data, forType: .init("public.jpeg"))
        case "gif":
            item.setData(data, forType: .init("public.gif"))
        case "tif", "tiff":
            item.setData(data, forType: .tiff)
        case "heic":
            item.setData(data, forType: .init("public.heic"))
        default:
            if let contentType = values.contentType {
                item.setData(data, forType: .init(contentType.identifier))
            }
        }

        if let text = FileKindDetector.readableText(from: url, maxBytes: maxInlineBytes) {
            item.setString(text, forType: .string)
        } else if let docText = FileKindDetector.readableDocumentText(from: url) {
            item.setString(docText, forType: .string)
        }

        return item
    }

    func pasteItem(at itemsIndex: Int) {
        guard items.indices.contains(itemsIndex) else { return }
        selectedIndex = itemsIndex
        commitPaste()
    }

}
