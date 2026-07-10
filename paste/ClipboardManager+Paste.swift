import AppKit
import ApplicationServices
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import PDFKit

extension ClipboardManager {
    // MARK: - Character injection (Spotlight / Raycast / Alfred)

    /// Apps that have text input fields but don't receive simulated ⌘V from
    /// external processes.  Spotlight is detected via focusedAppIsSpotlight()
    /// below, not by a nil frontmost app — see its doc comment.
    static let injectionBundleIDs: Set<String> = [
        "com.raycast.macos",
        "com.runningwithcrayons.Alfred",
    ]

    /// Max characters to inject char-by-char. Beyond this, fall back to ⌘V.
    static let maxInjectionLength = 5_000

    /// True when `app` is known to ignore externally simulated ⌘V.
    func shouldInjectCharacters(to app: NSRunningApplication?) -> Bool {
        if app == nil { return true } // no frontmost app captured at all
        if Self.focusedAppIsSpotlight() { return true }
        guard let id = app?.bundleIdentifier else { return false }
        return Self.injectionBundleIDs.contains(id)
    }

    /// Opening Spotlight does NOT set `NSWorkspace.frontmostApplication` to
    /// nil on current macOS — it leaves whatever app was frontmost before
    /// ⌘-Space still reporting as frontmost, since Spotlight is a system
    /// overlay, not a normal app switch. That meant `capturedPasteTarget`
    /// was never nil for Spotlight, `shouldInjectCharacters` returned false,
    /// and Clipen fired a synthetic ⌘V at the STALE captured app instead of
    /// injecting into Spotlight's search field — nothing appeared. Asking the
    /// Accessibility API directly which app is REALLY focused system-wide
    /// (independent of NSWorkspace's app-switch bookkeeping) is the reliable
    /// signal instead.
    static func focusedAppIsSpotlight() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedAppRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedAppRef) == .success,
              let focusedAppRef, CFGetTypeID(focusedAppRef) == AXUIElementGetTypeID()
        else { return false }
        let axApp = focusedAppRef as! AXUIElement  // swiftlint:disable:this force_cast
        var pid: pid_t = 0
        guard AXUIElementGetPid(axApp, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid)
        else { return false }
        return app.bundleIdentifier == "com.apple.Spotlight"
    }

    /// Extracts the pasteable plain-text string from a clipboard item, or nil
    /// if the content is not text (files, images, etc. cannot be injected).
    func extractTextForInjection(from item: ClipboardItem) -> String? {
        guard let t = item.content.plainText, !t.isEmpty else { return nil }
        return t
    }

    /// Inserts `text` into the currently focused text field.
    ///
    /// Strategy 1 — AX `kAXSelectedTextAttribute`:  Writes text directly into the
    /// focused element's selection point.  This is how Raycast, Alfred, and any
    /// standard NSTextField/NSTextView accept programmatic input; it bypasses ⌘V
    /// routing entirely and works regardless of keyboard layout or event source.
    ///
    /// Strategy 2 — HID-level CGEvent:  Posts key-down/up pairs at `.cghidEventTap`
    /// with the Unicode string override.  Unlike session-level posting, HID events
    /// travel the full hardware event pipeline and reach even system overlays like
    /// Spotlight that filter higher-level synthetic events.
    ///
    /// `completion` is invoked on the main thread after the text has been sent.
    func injectCharacters(_ text: String, completion: (() -> Void)? = nil) {
        // ── Strategy 1: AX attribute write ─────────────────────────────────────
        // Our popup is non-activating, so the REAL focused element in the target
        // app (Raycast search box, Alfred bar, etc.) is still the AX focused
        // element throughout the entire interaction.
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(systemWide,
                                         kAXFocusedUIElementAttribute as CFString,
                                         &focusedRef) == .success,
           let focusedRef {
            let focused = focusedRef as! AXUIElement  // swiftlint:disable:this force_cast
            if AXUIElementSetAttributeValue(focused,
                                            kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success {
                completion?()
                return
            }
        }

        // ── Strategy 2: HID-level CGEvent keyboard simulation ──────────────────
        // Fallback for apps whose AX attribute is read-only or unavailable
        // (Spotlight, some custom input areas).  HID posting is indistinguishable
        // from real hardware input to the window server.
        let src = CGEventSource(stateID: .hidSystemState)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.06) {
            for scalar in text.unicodeScalars {
                var chars: [UniChar]
                if scalar.value <= 0xFFFF {
                    chars = [UniChar(scalar.value)]
                } else {
                    // Encode supplementary character as a UTF-16 surrogate pair.
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


    // MARK: - Paste

    /// Record the current frontmost app as the paste destination on the item
    /// with the given ID.  Call this right before the synthetic ⌘V fires so
    /// the popup is still visible (non-activating) and frontmost == target.
    func recordPasteDestination(for itemID: UUID, app: NSRunningApplication? = nil) {
        guard let dest = app ?? NSWorkspace.shared.frontmostApplication else { return }
        recordPaste(itemID: itemID,
                    appName: dest.localizedName,
                    bundleID: dest.bundleIdentifier)
    }

    /// Single source of truth for "this item was just pasted into `appName`".
    /// Stamps destination metadata AND bumps the frequency counters the
    /// predictor reads.  Called from every paste path (plain, transform,
    /// search overlay, popup search) so no paste escapes the tally.
    func recordPaste(itemID: UUID, appName: String?, bundleID: String?) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].pastedToAppName  = appName
        items[idx].pastedToBundleID = bundleID
        items[idx].lastPastedAt     = Date()
        items[idx].pasteCount      += 1
        if let bid = bundleID {
            items[idx].pasteCountByApp[bid, default: 0] += 1
            // Accumulate every destination the item has ever landed in so
            // the UI can show ALL destination apps, not just the last one.
            if let name = appName {
                items[idx].pastedToAppNames[bid] = name
            }
        }
    }

    /// The app captured when the popup opened, reactivated first if it's no
    /// longer frontmost (defensive: showing our own NSPopover shouldn't steal
    /// focus, but this makes the paste destination correct even if it does).
    /// Falls back to a fresh frontmost query only if nothing was ever captured.
    func resolvedPasteTarget() -> NSRunningApplication? {
        guard let target = capturedPasteTarget else {
            return NSWorkspace.shared.frontmostApplication
        }
        if NSWorkspace.shared.frontmostApplication != target {
            target.activate(options: [])
        }
        return target
    }

    func commitPaste() {
        // A V/B/X tap/hold decision in flight when ⌘ is released must not
        // fire later against a stale target in a popup that's about to close.
        vTapHoldTimer?.invalidate()
        vTapHoldTimer = nil
        bTapHoldTimer?.invalidate()
        bTapHoldTimer = nil
        xTapHoldTimer?.invalidate()
        xTapHoldTimer = nil
        // Enter commits out of search mode too (handleFlagsChanged suppresses
        // the normal ⌘-release commit while this is true, so clear it here).
        isSearchActive = false
        guard !items.isEmpty else {
            previewWindow.hide()
            transformPanel.hide()
            itemPreviewPanel.hide()
            markedItemIDs = []
            return
        }
        captureRememberedSelection()

        // Stage 2 (marked set): run the selected MARKED tool against the
        // whole ordered mark queue and paste its single combined result.
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
                await MainActor.run {
                    self.updateTransformPanelProcessing(false)
                    self.inTransformStage = false
                    self.transformingMarkedSet = false
                    self.transformIndex = 0
                    self.transformPanel.hide()
                    self.itemPreviewPanel.hide()
                    self.previewWindow.hide()
                    self.markedItemIDs = []
                    // Restore the FIRST marked item to the pasteboard after
                    // pasting, same contract as single-item transforms.
                    self.handleTransformResult(result, restoring: markedItems[0], toolID: toolID)
                }
            }
            return
        }

        // Stage 2: apply selected transform (sync OR async) and paste result
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

            // Interactive transform: "Paste Specific Pages" needs a picker UI
            // inside the existing TransformPanel.  Instead of running the
            // tool's runAsync, swap the transform panel into page-range mode
            // and leave the popup open.  All input (digits, dash, comma,
            // return, escape, space-preview) flows through the CGEventTap
            // just like the popup search bar does — the non-activating panel
            // never has to steal focus from the target app.
            if selectedToolID == "pdf.paste-pages" || selectedToolID == "pdf.paste-pages-as-images" {
                if let input = PDFTools.pdfInput(for: item) {
                    let mode: PageRangeOutputMode =
                        (selectedToolID == "pdf.paste-pages-as-images") ? .perPageImages : .combinedPDF
                    NSLog("[Clipen] commitPaste intercept → enterPageRangeMode mode=\(mode) pages=\(input.pdf.pageCount)")
                    enterPageRangeMode(pdf: input.pdf, item: item, outputMode: mode)
                    return
                } else {
                    NSLog("[Clipen] commitPaste intercept FAILED: pdfInput returned nil for item content=\(item.content)")
                    flashStatus("Couldn't open PDF for page picker.")
                    return
                }
            }

            // Interactive transform: "Translate" needs a language picker,
            // same pattern as the PDF page picker above — swap the transform
            // panel content instead of running a single hardcoded target.
            if selectedToolID == "ai.translate" {
                enterLanguagePickerMode(item: item)
                return
            }

            let isAsync  = ToolRegistry.isAsync(item: item, toolID: selectedToolID)

            if isAsync {
                // Async path (OCR / PDF / export / optimization tools) — show
                // "Processing…", run the work, then paste & dismiss.
                updateTransformPanelProcessing(true)
                Task { [weak self] in
                    guard let self else { return }
                    let result = await ToolRegistry.run(item: item, toolID: selectedToolID)
                    await MainActor.run {
                        self.updateTransformPanelProcessing(false)
                        self.inTransformStage = false
                        self.transformIndex   = 0
                        // Same reasoning as dismissPreview(): the tool just run
                        // above bumped its universal usage score in AuthManager,
                        // but refreshTransformDisplaysCache()'s "same item" cache
                        // shortcut would otherwise keep showing the PRE-bump sort
                        // order next time transforms open on this item.
                        self.transformDisplaysCache = []
                        self.lastTransformCacheItemID = nil
                        self.transformingMarkedSet = false
                        self.transformPanel.hide()
                        self.itemPreviewPanel.hide()
                        self.previewWindow.hide()
                        // This transform path returns early, bypassing the
                        // marked-items reset the non-transform paste path does
                        // below — without this, marks made earlier in the same
                        // session leaked into the NEXT popup open. See report:
                        // "marked elements are persistent... sometimes".
                        self.markedItemIDs = []
                        self.handleTransformResult(result, restoring: item, toolID: selectedToolID)
                    }
                }
                return
            } else {
                // Sync path — apply immediately
                let result = applySyncTransform(item: item, toolID: selectedToolID)
                inTransformStage = false; transformIndex = 0
                // See the async branch above for why this must be cleared here too.
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

        // Multi-paste: if any items are marked, paste them ALL in marking order.
        // Fires only from stage-1 (item selection) — transforms always paste a
        // single result.
        if !markedItemIDs.isEmpty {
            let ids = markedItemIDs
            markedItemIDs = []
            let orderedItems = ids.compactMap { id in items.first(where: { $0.id == id }) }
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

        // Resolve by ID — prevents stale-index paste when displayItems was
        // rebuilt (new capture, filter change) between selection and ⌘ release.
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
        // Use the app captured at popup-open time (and reactivate it if
        // needed) rather than trusting frontmostApplication fresh here — see
        // capturedPasteTarget's doc comment.
        let pasteTarget = resolvedPasteTarget()
        previewWindow.hide(); transformPanel.hide(); itemPreviewPanel.hide()
        simulatePaste(item, target: pasteTarget) { [weak self] in
            self?.selectedIndex = 0
            self?.cycleCount    = 0
        }
    }

    /// Write `item` to the pasteboard and simulate the paste keystroke (or
    /// character injection for apps that ignore synthetic ⌘V). Extracted from
    /// commitPaste's tail so the double-click-to-paste path — which must NOT
    /// close the popup or reset selection — can reuse the exact same,
    /// already-hardened paste mechanics instead of a second implementation.
    func simulatePaste(_ item: ClipboardItem, target: NSRunningApplication?,
                              completion: (() -> Void)? = nil) {
        recordPasteDestination(for: item.id, app: target)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb)
        lastChangeCount = pb.changeCount

        isSimulatingPaste = true

        // Use character injection for Spotlight (nil frontmost), Raycast, Alfred,
        // and any other app that ignores externally simulated ⌘V.
        if let text = extractTextForInjection(from: item),
           text.count <= Self.maxInjectionLength,
           shouldInjectCharacters(to: target) {
            injectCharacters(text) { [weak self] in
                self?.isSimulatingPaste = false
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
                self?.isSimulatingPaste = false
                completion?()
            }
        }
        AuthManager.shared.registerCommandVAction()
    }

    /// Paste this item WITHOUT closing the popup or resetting selection —
    /// used by double-clicking a row, so the user can paste several items
    /// back-to-back in one popup session instead of it closing after the
    /// first double-click. Resolves by ID (not a display-list index, which
    /// is a different index space than `items`).
    func pasteItemKeepingPopupOpen(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        simulatePaste(item, target: resolvedPasteTarget())
    }

    // MARK: - Sequential multi-paste

    /// Paste `items` one at a time in order, with a 250 ms gap between each
    /// so the target app has time to receive and render each paste before the
    /// next arrives. Uses the same injection / ⌘V simulation logic as the
    /// single-item path so every content type works correctly.
    func commitMultiPaste(_ itemList: [ClipboardItem], target: NSRunningApplication?) {
        guard !itemList.isEmpty else {
            isSimulatingPaste = false
            selectedIndex = 0; cycleCount = 0
            return
        }
        let item      = itemList[0]
        let remaining = Array(itemList.dropFirst())

        isSimulatingPaste = true   // set BEFORE clearContents to block the poll guard immediately
        recordPasteDestination(for: item.id)
        let pb = NSPasteboard.general
        pb.clearContents()
        write(item, to: pb)
        lastChangeCount = pb.changeCount

        if let text = extractTextForInjection(from: item),
           text.count <= Self.maxInjectionLength,
           shouldInjectCharacters(to: target) {
            injectCharacters(text) { [weak self] in
                guard let self else { return }
                if remaining.isEmpty {
                    self.isSimulatingPaste = false
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
                    self.isSimulatingPaste = false
                    self.selectedIndex = 0; self.cycleCount = 0
                } else {
                    self.commitMultiPaste(remaining, target: target)
                }
            }
        }
    }

    // MARK: - Pasteboard write
    //
    // Every content type produces exactly ONE NSPasteboardItem with all
    // representations on that single item.  Mixing the old-style API
    // (setData/setString/setPropertyList after clearContents without
    // declareTypes) with writeObjects creates multiple implicit items on the
    // pasteboard; apps that iterate all items then paste each one, which is
    // why everything except plain text was pasting twice.

    /// Restore the item's side-car flavors onto the primary pasteboard item,
    /// skipping any type the primary write already set — so a paste offers
    /// receiving apps the SAME full set of representations the original copy
    /// did (private layer data, alternate encodings, everything).
    func applySidecar(_ item: ClipboardItem, to pitem: NSPasteboardItem) {
        guard let sidecar = item.sidecarTypes else { return }
        let existing = Set(pitem.types.map(\.rawValue))
        for (typeStr, data) in sidecar where !existing.contains(typeStr) {
            pitem.setData(data, forType: .init(typeStr))
        }
    }

    func write(_ item: ClipboardItem, to pb: NSPasteboard) {
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
            // Verbatim-first: the side-car carries the source app's ORIGINAL
            // rtf bytes (kept at capture — see prunedSidecar). Re-encoding
            // through NSAttributedString normalizes formatting and drops
            // anything the parser didn't model; the original bytes are what
            // a raw macOS paste would have delivered. Re-encode only when no
            // original survived (items captured by older builds).
            if let originalRTF = item.sidecarTypes?["public.rtf"] {
                pitem.setData(originalRTF, forType: .rtf)
            } else {
                let range = NSRange(location: 0, length: attrStr.length)
                if let rtfData = try? attrStr.data(from: range,
                                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    pitem.setData(rtfData, forType: .rtf)
                }
            }
            pitem.setString(plain, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .rtfd(let rtfdData, let plain):
            // Write RTFD so apps that support rich tables (Notes, Pages, Word)
            // receive the full table structure. Also write RTF + plain-text
            // fallbacks so simpler apps still get readable content.
            let pitem = NSPasteboardItem()
            pitem.setData(rtfdData, forType: .rtfd)
            // Generate an RTF fallback from the RTFD data (best effort).
            if let attrStr = NSAttributedString(rtfd: rtfdData, documentAttributes: nil) {
                let range = NSRange(location: 0, length: attrStr.length)
                if let rtfData = try? attrStr.data(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
                ) {
                    pitem.setData(rtfData, forType: .rtf)
                }
            }
            pitem.setString(plain, forType: .string)
            applySidecar(item, to: pitem)
            pb.writeObjects([pitem])

        case .html(let html, let plain):
            // Write HTML with full table markup so apps receive table structure.
            // Also write a plain-text fallback for apps that don't read HTML.
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
            // Side-car goes on the FIRST item only — pasteboard types apply
            // per-item, and the extra flavors described the copy as a whole.
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
            // Restore all original pasteboard types verbatim so the receiving
            // app sees exactly what was written by the source app.
            let pitem = NSPasteboardItem()
            for (typeStr, data) in typeMap {
                pitem.setData(data, forType: .init(typeStr))
            }
            pb.writeObjects([pitem])
        }
    }

    /// Build a single NSPasteboardItem for a file URL with every representation
    /// on that one item — Finder-standard file URL, legacy path list, typed raw
    /// data (so PDF viewers, image editors etc. get native format), and extracted
    /// plain text (so text editors receive readable content for text/document files).
    func makeFilePasteboardItem(for url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()

        // Standard file-URL type — how Finder, Mail, Dock etc. reference files.
        item.setData(url.dataRepresentation, forType: .fileURL)
        // Legacy path list for older apps.
        item.setPropertyList([url.path], forType: .init("NSFilenamesPboardType"))

        let maxInlineBytes = Self.maxDataBytes
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey, .fileSizeKey]),
              values.isDirectory != true,
              let fileSize = values.fileSize, fileSize <= maxInlineBytes,
              let data = try? Data(contentsOf: url) else { return item }

        // Typed raw data so specialised apps (Preview, image editors, etc.) get
        // their native format instead of just a file reference.
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

        // Plain-text representation for apps that accept text (editors, terminals).
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
