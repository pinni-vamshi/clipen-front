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
        let axApp = unsafeBitCast(focusedAppRef, to: AXUIElement.self)
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
           let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() {
            let focused = unsafeBitCast(focusedRef, to: AXUIElement.self)
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
        return capturedPasteTarget ?? NSWorkspace.shared.frontmostApplication
    }

    /// Calls `completion(true)` only when `target` is genuinely frontmost and
    /// it is therefore safe to post keystrokes at it. `completion(false)`
    /// means activation could not be confirmed and the caller must NOT
    /// paste.
    ///
    /// The previous version took no argument and fired unconditionally on
    /// timeout, which turned a *slow* activation into a paste delivered to
    /// whatever window happened to be frontmost instead. That is the
    /// multi-monitor "pasted into the wrong window" report: activating an
    /// app on another display can trigger a Space switch that comfortably
    /// exceeds the old 350ms budget. A paste that doesn't happen is
    /// recoverable — one into the wrong app is not, and can spill clipboard
    /// contents somewhere the user never intended.
    func activateAndWaitIfNeeded(_ target: NSRunningApplication?, completion: @escaping (Bool) -> Void) {
        // No specific target means "paste wherever we already are", which is
        // the caller's intent rather than a failure.
        guard let target else { completion(true); return }
        // A dead target can never come frontmost: activate() no-ops, the
        // notification never arrives, and we would sit out the whole timeout
        // before pasting somewhere wrong. capturedPasteTarget is set once
        // when the popup opens and never cleared, so this is reachable
        // whenever the source app quit mid-session.
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
        // 700ms, not 350ms: a cross-display activation that also switches
        // Spaces regularly needs more than a third of a second, and the old
        // budget was expiring during exactly the scenario being reported.
        // On expiry, check the real state rather than assuming — the
        // notification can be missed even when activation did land.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            finish(NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier)
        }

        target.activate(options: [])
    }

    /// Last line of defence, read immediately before any synthetic keystroke
    /// is posted. Activation can be confirmed and then lost in the gap before
    /// the keys go out (the user clicks elsewhere, another app steals focus),
    /// so the check that matters is the one taken at the moment of posting.
    func isSafeToPaste(into target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    /// Shared bail-out so every paste path reports the same thing and always
    /// releases its simulation token.
    func abortPaste(token: Int, reason: String = "") {
        endPasteSimulation(token: token)
        flashStatus(String(localized: "Paste cancelled — the target window wasn't ready."))
    }

    func pasteSingleFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([makeFilePasteboardItem(for: url)])
        markPasteboardWriteAsOwn()
        let target = resolvedPasteTarget()
        let token = beginPasteSimulation()
        activateAndWaitIfNeeded(target) { [weak self] ok in
            guard let self else { return }
            guard ok else { self.abortPaste(token: token); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                guard self.isSafeToPaste(into: target) else { self.abortPaste(token: token); return }
                self.simulateCommandV()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.endPasteSimulation(token: token)
                }
            }
        }
        AuthManager.shared.registerCommandVAction()
    }

    /// `countsAsFastPaste`, when true, means the caller (fastPasteFront)
    /// already recorded its own registerFastPasteAction() signal for this
    /// exact paste — every registerCommandVAction() this call would
    /// otherwise trigger downstream is suppressed so the same physical
    /// paste doesn't increment both `fast_paste` and `paste` at once. Found
    /// by tracing the call chain: fastPasteFront -> commitPaste ->
    /// simulatePaste unconditionally called registerCommandVAction() with
    /// no awareness that fastPasteFront had already counted the action.
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
                    // If the popup was dismissed (or moved past this stage)
                    // while the transform was still running, `capturedPasteTarget`
                    // — set once when the popup opened and never cleared — may now
                    // be stale or may have been silently overwritten by a newer,
                    // unrelated popup session the user opened in the meantime.
                    // Pasting at this point would land in whatever app that stale
                    // target now resolves to, not the one this transform was
                    // actually meant for. Same guard the single-item async
                    // transform path already uses correctly.
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
            previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
            commitMultiPaste(orderedItems, target: pasteTarget,
                              nudgeKind: orderedItems.count > 1 ? .multiMarked : .single)
            if !countsAsFastPaste { AuthManager.shared.registerCommandVAction() }
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

        if case .group(let children) = item.content {
            commitMultiPaste(children, target: pasteTarget, nudgeKind: .group)
            if !countsAsFastPaste { AuthManager.shared.registerCommandVAction() }
            selectedIndex = 0; cycleCount = 0
            return
        }

        recordNudgePaste(kind: .single)
        simulatePaste(item, target: pasteTarget, countsAsRegularPaste: !countsAsFastPaste) { [weak self] in
            self?.selectedIndex = 0
            self?.cycleCount    = 0
        }
    }

    func recordPasteAnalytics(item: ClipboardItem, displayIndex: Int?) {
        if let idx = displayIndex, idx >= 0 {
            TrackingService.shared.recordPastePosition(idx)
        }
    }

    /// `countsAsRegularPaste`, when false, means the caller already recorded
    /// its own usage signal for this exact paste (see commitPaste's
    /// countsAsFastPaste) — skips both registerCommandVAction() sites below
    /// so the same physical paste is never counted twice under two
    /// different metric names.
    func simulatePaste(_ item: ClipboardItem, target: NSRunningApplication?,
                              countsAsRegularPaste: Bool = true,
                              completion: (() -> Void)? = nil) {

        guard ProGate.shared.isUnlocked else { completion?(); return }

        // A copy macOS never let us read. We hold no bytes for it, so there
        // is nothing to write — the only copy that ever existed is the one
        // still sitting on the system pasteboard. Leave that pasteboard
        // completely untouched and let a plain Cmd+V deliver it.
        //
        // Only valid while that content is still the live pasteboard
        // content: once anything else has been copied (or Clipen itself has
        // pasted, which rewrites the pasteboard and bumps the same counter),
        // the original is gone and a system paste would silently deliver
        // whatever replaced it — the wrong data, into whatever app is
        // focused, with no indication anything went wrong. Refuse instead.
        if item.isUncaptured {
            guard let stamped = item.uncapturedChangeCount,
                  stamped == NSPasteboard.general.changeCount else {
                // flashStatus renders inside the big Dashboard/Settings
                // window (MainWindowView), which is almost never what's
                // focused right after a paste — the user is looking at
                // whatever app they just pasted into. CopyFeedbackPanel is
                // the floating badge built for exactly this moment (already
                // used for "excluded from copying"), visible regardless of
                // which app is frontmost.
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
                // Always the keystroke path, never injectCharacters: there is
                // no stored text to type, and the whole point is to let the
                // system's own paste read the pasteboard we didn't touch.
                let src  = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                down?.flags = .maskCommand; up?.flags = .maskCommand
                Self.tagSynthetic(down); Self.tagSynthetic(up)
                down?.post(tap: .cgAnnotatedSessionEventTap)
                up?.post(tap: .cgAnnotatedSessionEventTap)
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
        recordPasteDestination(for: item.id, app: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb, plainOnly: pastePlainTextByDefault)
        lastChangeCount = pb.changeCount

        let token = beginPasteSimulation()

        activateAndWaitIfNeeded(target) { [weak self] ok in
            guard let self else { completion?(); return }
            guard ok, self.isSafeToPaste(into: target) else {
                self.abortPaste(token: token); completion?(); return
            }
            if let text = self.extractTextForInjection(from: item),
               text.count <= Self.maxInjectionLength,
               self.shouldInjectCharacters(to: target) {
                self.injectCharacters(text) { [weak self] in
                    self?.endPasteSimulation(token: token)
                    completion?()
                }
            } else {
                let src  = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                down?.flags = .maskCommand; up?.flags = .maskCommand
                Self.tagSynthetic(down); Self.tagSynthetic(up)
                down?.post(tap: .cgAnnotatedSessionEventTap)
                up?.post(tap: .cgAnnotatedSessionEventTap)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    self?.endPasteSimulation(token: token)
                    completion?()
                }
            }
        }
        if countsAsRegularPaste { AuthManager.shared.registerCommandVAction() }
    }

    func pasteItemKeepingPopupOpen(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        recordPasteAnalytics(item: item,
                             displayIndex: displayItems.firstIndex(where: { $0.id == id }))
        recordNudgePaste(kind: .single)
        simulatePaste(item, target: resolvedPasteTarget())
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
        // How many marked items landed in one paste — previously invisible:
        // this whole path only ever bumped the same flat cmd_v counter a
        // single-item paste does, so a 5-item multi-paste and five separate
        // pastes were indistinguishable in the data. `itemList.count == 1`
        // (a single marked item pasted through this path rather than the
        // plain paste path) isn't a "multi" paste, so it's excluded here.
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
            // Aborting here also drops `remaining`, which is deliberate: a
            // multi-paste that continued into the wrong window would spill
            // every remaining item there, not just one.
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
                let src  = CGEventSource(stateID: .combinedSessionState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
                let up   = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
                down?.flags = .maskCommand; up?.flags = .maskCommand
                Self.tagSynthetic(down); Self.tagSynthetic(up)
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
    }

    func applySidecar(_ item: ClipboardItem, to pitem: NSPasteboardItem) {
        guard let sidecar = item.sidecarTypes else { return }
        let existing = Set(pitem.types.map(\.rawValue))
        for (typeStr, data) in sidecar where !existing.contains(typeStr) {
            pitem.setData(data, forType: .init(typeStr))
        }
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
                // Only `.string`, and no sidecar — any other representation
                // left on the pasteboard is one the target app can prefer
                // over the plain text, which defeats the whole toggle.
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
            applySidecar(item, to: pitem)
            pitem.setString(plain, forType: .string)
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

    func pasteItem(at itemsIndex: Int) {
        guard items.indices.contains(itemsIndex) else { return }
        let item = items[itemsIndex]
        recordPasteAnalytics(item: item,
                             displayIndex: displayItems.firstIndex(where: { $0.id == item.id }))
        recordNudgePaste(kind: .single)
        simulatePaste(item, target: resolvedPasteTarget())
    }

}
