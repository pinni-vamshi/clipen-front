import AppKit
import Carbon
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
        // Bundle-ID first: it's a set lookup, while focusedAppIsOverlay() is
        // a synchronous cross-process Accessibility round trip. Same answer
        // either way (the result is an OR), but Raycast/Alfred now skip the
        // AX call entirely.
        if let id = app?.bundleIdentifier, Self.injectionBundleIDs.contains(id) { return true }
        return Self.focusedAppIsOverlay()
    }

    /// System overlays that take typing without ever becoming the frontmost
    /// app. A paste aimed at "the frontmost app" misses them, so text is
    /// written straight into their focused field instead. Spotlight was the
    /// only one handled; macOS 27's new Siri ("Siri AI", com.apple.campo)
    /// works the same way, and so does the classic Siri panel.
    static let overlayBundleIDs: Set<String> = [
        "com.apple.Spotlight",
        "com.apple.campo",          // Siri AI, macOS 27
        "com.apple.Siri",
        "com.apple.siri.launcher",
    ]

    /// True when the app holding the keyboard focus is an overlay: one of the
    /// known ones above, or any background (menu-bar style) app that has the
    /// text cursor while a different app is frontmost — which is exactly the
    /// situation a normal Cmd-V paste can't reach.
    static func focusedAppIsOverlay() -> Bool {
        guard let app = focusedApplication() else { return false }
        if let id = app.bundleIdentifier, overlayBundleIDs.contains(id) { return true }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != app.processIdentifier else { return false }
        return app.activationPolicy == .accessory
    }

    private static func focusedApplication() -> NSRunningApplication? {
        let systemWide = AXUIElementCreateSystemWide()
        // Every paste of text waits on this. An unresponsive frontmost app
        // makes AX calls hang for the default 6s timeout, which the user
        // experiences as the paste itself being stuck. Nothing here is worth
        // more than a fraction of a second; on timeout we fall through to
        // "not an overlay", which is the common answer anyway.
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
        else { return nil }
        let axApp = unsafeBitCast(focusedAppRef, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(axApp, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
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
           let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
            if AXUIElementSetAttributeValue(focused,
                                            kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success {
                // "Success" only means the element accepted the call, not that
                // it did anything with it — a search field can take the write
                // and still show nothing, and the paste then fails silently.
                // So read the field back; type the text in by hand only when
                // the field is readable and plainly doesn't contain it. An
                // unreadable field (secure, or no value) is trusted as before.
                let needle = String(text.prefix(40))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    var valueRef: CFTypeRef?
                    let readable = AXUIElementCopyAttributeValue(
                        focused, kAXValueAttribute as CFString, &valueRef) == .success
                    if readable, let value = valueRef as? String, !value.contains(needle) {
                        DebugLog.write("inject: field accepted the text but doesn't show it — typing it instead")
                        self?.typeCharacters(text, completion: completion)
                    } else {
                        completion?()
                    }
                }
                return
            }
        }
        typeCharacters(text, completion: completion)
    }

    private func typeCharacters(_ text: String, completion: (() -> Void)?) {
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
                        ClipboardManager.tagSynthetic(dn)
                        dn.post(tap: .cghidEventTap)
                    }
                    if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                        up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: base)
                        ClipboardManager.tagSynthetic(up)
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
        if let destName = dest.localizedName ?? dest.bundleIdentifier {
            AuthManager.shared.registerActionUsage(actionID: "action.paste-to-app", value: destName)
        }
    }

    func recordPaste(itemID: UUID, appName: String?, bundleID: String?) {
        guard let idx = indexOfItem(id: itemID) else { return }
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
        return capturedPasteTarget ?? NSWorkspace.shared.frontmostApplication
    }

    func activateAndWaitIfNeeded(_ target: NSRunningApplication?, completion: @escaping (Bool) -> Void) {

        guard let target else { completion(true); return }

        guard !target.isTerminated else { completion(false); return }
        guard NSWorkspace.shared.frontmostApplication != target else { completion(true); return }

        var didFinish = false
        var observer: NSObjectProtocol?
        let finish = { (ok: Bool) in
            guard !didFinish else { return }
            didFinish = true
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            completion(ok)
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == target.processIdentifier else { return }
            finish(true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            finish(NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier)
        }

        target.activate(options: [])
    }

    func isSafeToPaste(into target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    func abortPaste(token: Int, reason: String = "") {
        endPasteSimulation(token: token)
        flashStatus(String(localized: "Paste cancelled — the target window wasn't ready."))
    }

    func commitPaste(countsAsFastPaste: Bool = false) {
        if inShareStage {
            commitShare()
            return
        }

        if !ProGate.shared.isUnlocked {
            markedItemIDs = []
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
            TrackingService.shared.recordPopupDuration(ms: ms)
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

        if inDetailsStage {
            // detailsIndex/order.fields address STOPS (DetailUnit.stops),
            // not units directly — a group's fields and its whole-section
            // row are each their own stop, so this resolves through the
            // same expansion the panel cycles and marks over. See
            // DetailStop in DetailsPanel.swift.
            let stops = DetailUnit.stops(for: detailUnits)
            guard displayItems.indices.contains(selectedIndex),
                  stops.indices.contains(detailsIndex) else {
                setSidePanelStage(.none); previewWindow.hide(); return
            }
            let source = displayItems[selectedIndex]
            let order  = unifiedMarkOrder()

            if !order.items.isEmpty || !order.fields.isEmpty {
                var ranked: [(rank: Int, item: ClipboardItem)] = []
                let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                for (id, rank) in order.items {
                    if let it = byID[id] { ranked.append((rank, it)) }
                }
                for (idx, rank) in order.fields where stops.indices.contains(idx) {
                    ranked.append((rank, ClipboardItem(content: .text(stops[idx].text(in: detailUnits)))))
                }
                ranked.sort { $0.rank < $1.rank }
                let ordered = ranked.map(\.item)
                guard !ordered.isEmpty else { setSidePanelStage(.none); previewWindow.hide(); return }

                let target = resolvedPasteTarget()
                setSidePanelStage(.none)
                previewWindow.hide()
                markedItemIDs = []
                commitMultiPaste(ordered, target: target,
                                 nudgeKind: ordered.count > 1 ? .multiMarked : .single)
                return
            }

            let text = stops[detailsIndex].text(in: detailUnits)
            setSidePanelStage(.none)
            previewWindow.hide()
            handleTransformResult(.text(text), restoring: source)
            return
        }

        if inTransformStage, transformingMarkedSet {
            let markedItems = orderedMarkedItems
            guard markedItems.count >= 2,
                  transformDisplaysCache.indices.contains(transformIndex) else {
                setSidePanelStage(.none)
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

                    guard self.previewWindow.isVisible, self.inTransformStage, self.transformingMarkedSet else {
                        return
                    }
                    self.setSidePanelStage(.none)
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

            let isAsync  = ToolRegistry.isAsync(item: item, toolID: selectedToolID)

            if isAsync {
                updateTransformPanelProcessing(true)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await ToolRegistry.run(item: item, toolID: selectedToolID)
                    await MainActor.run {

                        guard self.inTransformStage, self.previewWindow.isVisible else { return }
                        self.updateTransformPanelProcessing(false)
                        if self.isInlineEditing { return }
                        if case .status(let msg) = result {

                            self.setSidePanelStage(.none)
                            self.flashStatus(msg)
                            return
                        }
                        self.setSidePanelStage(.none)
                        self.previewWindow.hide()
                        self.markedItemIDs = []
                        self.handleTransformResult(result, restoring: item, toolID: selectedToolID)
                    }
                }
                return
            } else {
                let result = applySyncTransform(item: item, toolID: selectedToolID)
                if isInlineEditing {
                    return
                }
                if case .status(let msg) = result {

                    setSidePanelStage(.none)
                    flashStatus(msg)
                    return
                }
                setSidePanelStage(.none)
                previewWindow.hide()
                markedItemIDs = []
                handleTransformResult(result, restoring: item, toolID: selectedToolID)
                return
            }
        }

        setSidePanelStage(.none)

        if !markedItemIDs.isEmpty {
            let ids = Set(markedItemIDs)
            markedItemIDs = []
            let displayOrder = Dictionary(uniqueKeysWithValues: displayItems.enumerated().map { ($1.id, $0) })
            let orderedItems = items(forIDs: ids)
                .sorted { (displayOrder[$0.id] ?? Int.max) < (displayOrder[$1.id] ?? Int.max) }
            guard !orderedItems.isEmpty else {
                previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
                return
            }
            let pasteTarget = resolvedPasteTarget()
            let markedPositions = orderedItems.compactMap { displayOrder[$0.id] }
            previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
            commitMultiPaste(orderedItems, target: pasteTarget,
                              nudgeKind: orderedItems.count > 1 ? .multiMarked : .single)
            if !countsAsFastPaste {
                AuthManager.shared.registerCommandVAction(
                    position: markedPositions.first,
                    markedCount: orderedItems.count > 1 ? orderedItems.count : nil,
                    markedPositions: orderedItems.count > 1 ? markedPositions : nil)
            }
            return
        }

        let item: ClipboardItem
        if let id = pendingPasteItemID, let found = self.item(id: id) {
            item = found
        } else if displayItems.indices.contains(selectedIndex) {
            item = displayItems[selectedIndex]
        } else {
            previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
            return
        }
        pendingPasteItemID = nil
        let position = indexInDisplayItems(id: item.id)
        recordPasteAnalytics(item: item, displayIndex: position)
        let pasteTarget = resolvedPasteTarget()
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()

        if case .group(let children) = item.content {
            commitMultiPaste(children, target: pasteTarget, nudgeKind: .group)
            if !countsAsFastPaste { AuthManager.shared.registerCommandVAction(position: position) }
            selectedIndex = 0; cycleCount = 0
            return
        }

        recordNudgePaste(kind: .single)
        simulatePaste(item, target: pasteTarget, countsAsRegularPaste: !countsAsFastPaste, position: position) { [weak self] in
            self?.selectedIndex = 0
            self?.cycleCount    = 0
        }
    }

    /// Retained as a call-site marker for "an item was pasted from this
    /// display position" — the position itself now travels with the actual
    /// "paste" event (see `registerCommandVAction(position:)`/`simulatePaste`)
    /// so it lands on the SAME PostHog event rather than a second, silent one.
    func recordPasteAnalytics(item: ClipboardItem, displayIndex: Int?) {}

    func simulatePaste(_ item: ClipboardItem, target: NSRunningApplication?,
                              countsAsRegularPaste: Bool = true,
                              position: Int? = nil,
                              completion: (() -> Void)? = nil) {

        guard ProGate.shared.isUnlocked else { completion?(); return }

        if item.isUncaptured {
            guard let stamped = item.uncapturedChangeCount,
                  stamped == NSPasteboard.general.changeCount else {

                CopyFeedbackPanel.shared.show(message: String(localized: "That copy is no longer on the clipboard"))
                completion?()
                return
            }
            popupSessionPasted = true
            finalizePopupOutcome()
            let token = beginPasteSimulation()
            activateAndWaitIfNeeded(target) { [weak self] ok in
                guard let self else { return }
                guard ok, self.isSafeToPaste(into: target) else {
                    self.abortPaste(token: token); completion?(); return
                }

                Self.postCommandV()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.endPasteSimulation(token: token)
                    completion?()
                }
            }
            if countsAsRegularPaste { AuthManager.shared.registerCommandVAction() }
            return
        }

        popupSessionPasted = true
        finalizePopupOutcome()

        // PASTE-TIME: each stage of a paste is a separate suspect (pasteboard
        // write for big payloads, app activation, the AX injection probe), and
        // they're indistinguishable from the outside. Gated by
        // clipenDebugLogging like the AI-TIME logs.
        let tStart = Date()
        func ms(_ from: Date) -> Int { max(0, Int(Date().timeIntervalSince(from) * 1000)) }

        recordPasteDestination(for: item.id, app: target)
        let tWrite = Date()
        let pb = NSPasteboard.general
        // The item that is still the live clipboard pastes with the system's
        // own paste: nothing is cleared or rewritten, so the target app gets
        // exactly what the source app copied. See `pastesFromSystemClipboard`.
        let usesSystemClipboard = pastesFromSystemClipboard(item)
        if !usesSystemClipboard {
            pb.clearContents()
            write(item, to: pb, plainOnly: pastePlainTextByDefault)
            lastChangeCount = pb.changeCount
        }
        let writeMs = ms(tWrite)

        let token = beginPasteSimulation()
        let tActivate = Date()

        activateAndWaitIfNeeded(target) { [weak self] ok in
            guard let self else { completion?(); return }
            let activateMs = ms(tActivate)
            guard ok, self.isSafeToPaste(into: target) else {
                DebugLog.write("PASTE-TIME aborted after \(ms(tStart))ms write=\(writeMs)ms activate=\(activateMs)ms ok=\(ok)")
                self.abortPaste(token: token); completion?(); return
            }
            let tDecide = Date()
            let injectText = self.extractTextForInjection(from: item)
            let willInject = injectText.map {
                $0.count <= Self.maxInjectionLength && self.shouldInjectCharacters(to: target)
            } ?? false
            let decideMs = ms(tDecide)
            DebugLog.write("PASTE-TIME staged=\(ms(tStart))ms write=\(writeMs)ms activate=\(activateMs)ms injectProbe=\(decideMs)ms inject=\(willInject) system=\(usesSystemClipboard) sidecar=\(item.sidecarTypes?.keys.sorted().joined(separator: ",") ?? "none") app=\(target?.bundleIdentifier ?? "nil")")

            if willInject, let text = injectText {
                let tInject = Date()
                self.injectCharacters(text) { [weak self] in
                    DebugLog.write("PASTE-TIME done total=\(ms(tStart))ms inject=\(ms(tInject))ms chars=\(text.count)")
                    self?.endPasteSimulation(token: token)
                    completion?()
                }
            } else {
                Self.postCommandV()
                DebugLog.write("PASTE-TIME keystroke posted at \(ms(tStart))ms")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.endPasteSimulation(token: token)
                    completion?()
                }
            }
        }
        if countsAsRegularPaste { AuthManager.shared.registerCommandVAction(position: position) }
    }

    func pasteItemKeepingPopupOpen(id: UUID) {
        guard let item = item(id: id) else { return }
        let position = indexInDisplayItems(id: id)
        recordPasteAnalytics(item: item, displayIndex: position)
        recordNudgePaste(kind: .single)
        simulatePaste(item, target: resolvedPasteTarget(), position: position)
    }

    func commitMultiPaste(_ itemList: [ClipboardItem], target: NSRunningApplication?,
                          nudgeKind: NudgePasteKind? = nil) {
        guard !itemList.isEmpty else {
            isSimulatingPaste = false
            selectedIndex = 0; cycleCount = 0
            return
        }
        guard ProGate.shared.isUnlocked else {
            isSimulatingPaste = false
            selectedIndex = 0; cycleCount = 0
            return
        }
        if let nudgeKind {
            recordNudgePaste(kind: nudgeKind)
        }
        popupSessionPasted = true
        finalizePopupOutcome()
        recordPasteAnalytics(item: itemList[0], displayIndex: nil)

        if itemList.count > 1 {
            TrackingService.shared.recordMarkedBatch(id: "multi_paste", size: itemList.count)
        }
        let item      = itemList[0]
        let remaining = Array(itemList.dropFirst())

        let token = beginPasteSimulation()
        recordPasteDestination(for: item.id)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb, plainOnly: pastePlainTextByDefault)
        lastChangeCount = pb.changeCount

        activateAndWaitIfNeeded(target) { [weak self] ok in
            guard let self else { return }

            guard ok, self.isSafeToPaste(into: target) else { self.abortPaste(token: token); return }
            if let text = self.extractTextForInjection(from: item),
               text.count <= Self.maxInjectionLength,
               self.shouldInjectCharacters(to: target) {
                self.injectCharacters(text) { [weak self] in
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
                Self.postCommandV()
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
    }

    func applySidecar(_ item: ClipboardItem, to pitem: NSPasteboardItem) {
        guard let sidecar = item.sidecarTypes else { return }
        let existing = Set(pitem.types.map(\.rawValue))
        for (typeStr, data) in sidecar where !existing.contains(typeStr) {
            pitem.setData(data, forType: .init(typeStr))
        }
    }

    /// The plain text a formatted item pastes with: the source app's own
    /// plain-text flavour when it was captured (Markdown from ChatGPT,
    /// tab-separated rows from Numbers), else the text derived from the
    /// formatting. Editing an item drops its sidecar, so an edited item
    /// always uses its new text. See `prunedSidecar`.
    static func pastePlainText(for item: ClipboardItem, derived: String) -> String {
        guard let data = item.sidecarTypes?["public.utf8-plain-text"],
              let original = String(data: data, encoding: .utf8),
              !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return derived }
        return original
    }

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
            case .richText, .rtfd, .html:

                let pitem = NSPasteboardItem()
                let text = TableCellExtractor.pureText(for: item)
                    ?? item.content.plainText
                    ?? ""
                pitem.setString(text, forType: .string)
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

                let range = NSRange(location: 0, length: attrStr.length)
                if let rtfdData = try? attrStr.data(from: range,
                                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]) {
                    pitem.setData(rtfdData, forType: .rtfd)
                }
            } else if let rtfData = Self.safeRTFData(for: attrStr, sidecarRTF: item.sidecarTypes?["public.rtf"]) {
                pitem.setData(rtfData, forType: .rtf)
            }
            pitem.setString(Self.pastePlainText(for: item, derived: plain), forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .rtfd(let rtfdData, let plain):
            let pitem = NSPasteboardItem()
            pitem.setData(rtfdData, forType: .rtfd)
            if let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil),
               let rtfData = Self.safeRTFData(for: attrStr) {
                pitem.setData(rtfData, forType: .rtf)
            }
            pitem.setString(Self.pastePlainText(for: item, derived: plain), forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .html(let html, let plain):
            let pitem = NSPasteboardItem()
            pitem.setData(Data(html.utf8), forType: .init("public.html"))
            pitem.setData(Data(html.utf8), forType: .init("Apple HTML pasteboard type"))
            applySidecar(item, to: pitem)
            pitem.setString(Self.pastePlainText(for: item, derived: plain), forType: .string)
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

        case .group(let children):

            var objects: [NSPasteboardWriting] = ClipboardItem.flattenedFileURLs(children)
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { makeFilePasteboardItem(for: $0) }
            if let text = ClipboardContent.group(children).plainText {
                let pitem = NSPasteboardItem()
                pitem.setString(text, forType: .string)
                objects.append(pitem)
            }
            if !objects.isEmpty { pb.writeObjects(objects) }
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

    /// Pastes from a Reference panel into the app being worked in. The
    /// panel never takes focus, so that is the frontmost app. Its buttons
    /// used `resolvedPasteTarget()`, which prefers the app the POPUP was
    /// last opened over — often a different one by the time a Reference
    /// panel is used — so Clipen switched to that app and pasted there.
    func pasteFromReferencePanel(itemID: UUID) {
        guard let item = item(id: itemID) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let target = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? capturedPasteTarget : front
        recordNudgePaste(kind: .single)
        simulatePaste(item, target: target, position: indexInDisplayItems(id: itemID))
    }

    func pasteItem(at itemsIndex: Int) {
        guard items.indices.contains(itemsIndex) else { return }
        let item = items[itemsIndex]
        let position = indexInDisplayItems(id: item.id)
        recordPasteAnalytics(item: item, displayIndex: position)
        recordNudgePaste(kind: .single)
        simulatePaste(item, target: resolvedPasteTarget(), position: position)
    }

}

// MARK: - Command-V keystroke

extension ClipboardManager {

    /// Presses Command-V the way a person does: Command down, V down, V up,
    /// Command up, posted at the hardware level with a short gap between.
    ///
    /// Clipen used to post only V down/up with a Command FLAG on them, into
    /// the session (not the hardware) event stream, with no Command key
    /// event at all. Most apps accept that. Text fields that ask the system
    /// whether Command is actually held — Spotlight's search field, Finder's
    /// rename and search fields — see that it isn't and ignore the paste.
    /// Dictation tools that do paste into those fields send exactly this
    /// sequence: VoiceInk (CursorPaster.pasteFromClipboard: 0x37 down,
    /// 0x09 down/up, 0x37 up at .cghidEventTap) and Handy
    /// (input.rs send_paste_ctrl_v: Meta press, V click, Meta release).
    ///
    /// Every event is tagged as Clipen's own, so Clipen's event tap lets it
    /// through instead of reading it as the user's Command-V.
    static func postCommandV() {
        let vKey = commandVKeyCode()
        let src = CGEventSource(stateID: .privateState)
        guard let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: true),
              let vDown = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false),
              let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Command), keyDown: false)
        else { return }
        cmdDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand
        cmdUp.flags = []
        let sequence = [cmdDown, vDown, vUp, cmdUp]
        sequence.forEach { tagSynthetic($0) }
        // A few milliseconds apart, as both references do: an app that
        // reads the modifier state when V arrives must see Command already
        // down. Off the main thread so the gaps never stall the UI.
        DispatchQueue.global(qos: .userInteractive).async {
            for (i, event) in sequence.enumerated() {
                if i > 0 { usleep(8_000) }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    /// The key that types "v" while Command is held on the current keyboard
    /// layout. Key 9 is V only on QWERTY-style layouts: on Dvorak it is
    /// ".", so a fixed 9 pasted nothing there. Layouts that switch to QWERTY
    /// under Command ("Dvorak – QWERTY ⌘", most non-Latin layouts) answer 9
    /// here because the lookup is done with Command held — the same lookup
    /// Handy's `resolve_command_v_keycode` makes. Falls back to 9.
    static func commandVKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard Thread.isMainThread,
              let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        let keyboardType = UInt32(LMGetKbdType())
        let commandModifier = UInt32((cmdKey >> 8) & 0xFF)

        func types(_ code: UInt16) -> String? {
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), commandModifier,
                                        keyboardType, OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length == 1 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
        // The usual key first: on almost every layout it is the answer.
        if types(UInt16(kVK_ANSI_V))?.lowercased() == "v" { return fallback }
        for code in UInt16(0)..<UInt16(128) where types(code)?.lowercased() == "v" {
            return CGKeyCode(code)
        }
        return fallback
    }
}
