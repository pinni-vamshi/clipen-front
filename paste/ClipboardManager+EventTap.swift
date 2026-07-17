import AppKit
import SwiftUI

extension ClipboardManager {

    func attemptEventTap() {
        if eventTap != nil { return }

        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        permissionRetryBackoff = 1.0

        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            scheduleNextPermissionRetry()
        }
    }

    func scheduleNextPermissionRetry() {
        let interval = min(permissionRetryBackoff, 30.0)
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.permissionRetryTimer?.invalidate()
                self.permissionRetryTimer = nil
                self.permissionRetryBackoff = 1.0
                self.createEventTap()
            } else {
                self.permissionRetryBackoff = min(self.permissionRetryBackoff * 2, 30.0)
                self.scheduleNextPermissionRetry()
            }
        }
        if let t = permissionRetryTimer { RunLoop.main.add(t, forMode: .common) }
    }

    func teardownEventTap() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    func createEventTap() {
        teardownEventTap()

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let mgr = Unmanaged<ClipboardManager>.fromOpaque(refcon!).takeUnretainedValue()
                return mgr.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged { return handleFlagsChanged(event) }
        if type == .keyUp        { return handleKeyUp(event) }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
            return handleMouseDown(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        return handleKeyDown(event)
    }

    func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let loc = NSEvent.mouseLocation

        if previewWindow.isVisible {
            let insidePopup = previewWindow.frame.contains(loc)
                || (transformPanel.isVisible && transformPanel.frame.contains(loc))
                || (itemPreviewPanel.isVisible && itemPreviewPanel.frame.contains(loc))
            if !insidePopup {
                DispatchQueue.main.async { [weak self] in self?.dismissPreview() }
            }
        } else if itemPreviewPanel.isVisible {
            if !itemPreviewPanel.frame.contains(loc) {
                DispatchQueue.main.async { [weak self] in self?.itemPreviewPanel.hide() }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let hasCmd = event.flags.contains(.maskCommand)
        notePopupHintModifiers(cmd: hasCmd, shift: event.flags.contains(.maskShift))
        if !hasCmd {
            if inPageRangeMode && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            if inLanguagePickerMode && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            if popupPinnedOpen && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            if isSearchActive && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            if previewWindow.isVisible,
               NSEvent.pressedMouseButtons & 0x1 != 0,
               previewWindow.frame.contains(NSEvent.mouseLocation) {
                return Unmanaged.passUnretained(event)
            }
            if pendingFirstOpen {
                DispatchQueue.main.async { [weak self] in self?.fastPasteFront() }
            } else if previewWindow.isVisible && !escapeWillDismiss {
                DispatchQueue.main.async { [weak self] in self?.commitPaste() }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        if key == 9, let timer = vTapHoldTimer {
            timer.invalidate()
            vTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in self?.cycleNext() }
        }
        if key == 9, let timer = firstOpenHoldTimer {
            timer.invalidate()
            firstOpenHoldTimer = nil
        }
        if key == 7, let timer = xTapHoldTimer {
            timer.invalidate()
            xTapHoldTimer = nil
            let shift = event.flags.contains(.maskShift)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.inTransformStage {
                    if shift { self.cycleTransformBackward() }
                    else      { self.cycleTransform() }
                } else {
                    self.enterTransformStage()
                }
            }
        }
        if key == 11, let timer = bTapHoldTimer {
            timer.invalidate()
            bTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.inTransformStage {
                    self.cycleTransformBackward()
                } else {
                    self.cyclePrevious()
                }
            }
        }
        if key == 35, let timer = pTapHoldTimer {
            timer.invalidate()
            pTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in self?.cyclePinnedItems() }
        }
        if key == 1, let timer = sTapHoldTimer {
            timer.invalidate()
            sTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.inShareStage { self.cycleShare() } else { self.enterShareStage() }
            }
        }
        if key == 49 { spaceKeyIsDown = false }
        notePopupHintModifiers(cmd: event.flags.contains(.maskCommand),
                               shift: event.flags.contains(.maskShift))
        notePopupHintKeyUp(keycode: key)
        return Unmanaged.passUnretained(event)
    }

    func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        notePopupHintModifiers(cmd: flags.contains(.maskCommand),
                               shift: flags.contains(.maskShift))
        notePopupHintKeyDown(keycode: Int(key), cmd: flags.contains(.maskCommand))
        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let opt   = flags.contains(.maskAlternate)
        let ctrl  = flags.contains(.maskControl)

        if previewWindow.isVisible && !inPageRangeMode && !inLanguagePickerMode {
            resetAutoDismissTimer()
        }

        if inPageRangeMode && !cmd {
            return handlePageRangeKeyDown(key: key, event: event)
        }

        if inLanguagePickerMode && !cmd {
            return handleLanguagePickerKeyDown(key: key, event: event)
        }

        if key == 53 && previewWindow.isVisible {
            if popupSearchQuery.isEmpty && !isSearchActive {
                escapeWillDismiss = true
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.popupSearchQuery.isEmpty {
                    self.popupSearchQuery = ""
                } else if self.isSearchActive {
                    self.isSearchActive = false
                } else {
                    self.dismissPreview()
                }
                self.escapeWillDismiss = false
            }
            return nil
        }

        if key == 3 && !ctrl && !opt && !isSearchActive && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in
                self?.isSearchActive = true
                AuthManager.shared.registerActionUsage(actionID: "action.popup-search")
            }
            return nil
        }

        if (key == 36 || key == 76) && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in self?.commitPaste() }
            return nil
        }

        if isSearchActive && previewWindow.isVisible && (key == 125 || key == 126) {
            if key == 126 {
                DispatchQueue.main.async { [weak self] in self?.cyclePrevious() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.cycleNext() }
            }
            return nil
        }

        if key == 49 && !ctrl && !opt {
            let isRepeat = spaceKeyIsDown
            spaceKeyIsDown = true
            let isAutorepeat = isRepeat || event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if previewWindow.isVisible && !isSearchActive {
                if isAutorepeat { return nil }
                let isDoubleTap = Date().timeIntervalSince(lastSpaceKeyTime) < spaceDoubleTapWindow
                lastSpaceKeyTime = isDoubleTap ? .distantPast : Date()
                if isDoubleTap {
                    DispatchQueue.main.async { [weak self] in
                        self?.flashSpaceDoubleTapHint()
                        self?.openQuickClipPanelForSelection()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in self?.toggleSelectedItemPreview() }
                }
                return nil
            }

        }

        if isSearchActive && previewWindow.isVisible && !cmd {
            if key == 51 {
                if !popupSearchQuery.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.popupSearchQuery.removeLast() }
                }
                return nil
            }
            var length: Int = 0
            var chars = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4,
                                           actualStringLength: &length,
                                           unicodeString: &chars)
            if length > 0 {
                let typed = String(utf16CodeUnits: Array(chars.prefix(length)), count: length)
                let printable = typed.filter { $0.unicodeScalars.allSatisfy { $0.properties.generalCategory != .control } && !$0.isNewline }
                if !printable.isEmpty {
                    DispatchQueue.main.async { [weak self] in self?.popupSearchQuery += printable }
                }
            }
            return nil
        }

        guard cmd && !ctrl else { return Unmanaged.passUnretained(event) }

        if key == 9 {
            if isSimulatingPaste { return Unmanaged.passUnretained(event) }
            ClipenSignpost.event("v.keydown")
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            if previewWindow.isVisible && !shift && !opt {
                if !isAutorepeat {
                    let pendingID: UUID? = displayItems.indices.contains(selectedIndex)
                        ? displayItems[selectedIndex].id : nil
                    vTapHoldTimer?.invalidate()
                    let t = Timer(timeInterval: vHoldThreshold, repeats: false) { [weak self] _ in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.vTapHoldTimer = nil
                            self.popupHintVMark = true
                            self.popupHintV = false
                            self.popupHintShiftV = false
                            guard let id = pendingID,
                                  self.items.contains(where: { $0.id == id }) else { return }
                            self.toggleMark(id: id)
                            AuthManager.shared.registerActionUsage(actionID: "action.mark")
                            if self.advanceAfterMark, self.previewWindow.isVisible,
                               !self.displayItems.isEmpty {
                                self.selectedIndex = (self.selectedIndex + 1) % self.displayItems.count
                                self.syncItemPreviewWithSelection()
                                self.syncTransformPanelWithSelection()
                            }
                        }
                    }
                    RunLoop.main.add(t, forMode: .common)
                    vTapHoldTimer = t
                }
                return nil
            }

            if displayItems.isEmpty && !previewWindow.isVisible && !shift {
                return Unmanaged.passUnretained(event)
            }

            if shift && !opt {
                // Shift (⇧V) is always a plain "previous item in the main
                // ring" shortcut — Shift+X is the separate, dedicated way to
                // step backward within the transform panel (cycleTransformBackward,
                // handled elsewhere via key == 7 + shift). Only the alternate
                // "B" reverse-key binding is context-aware about inTransformStage.
                if !reverseCycleUsesB {
                    DispatchQueue.main.async { [weak self] in self?.cyclePrevious() }
                }
                return nil
            }

            if opt {
                DispatchQueue.main.async { [weak self] in self?.jumpForward(by: 5) }
                return nil
            }

            if !isAutorepeat {
                firstOpenHoldTimer?.invalidate()
                let t = Timer(timeInterval: pinnedOpenHoldThreshold, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.firstOpenHoldTimer = nil
                        guard self.previewWindow.isVisible else { return }
                        self.popupPinnedOpen = true
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                firstOpenHoldTimer = t
            }
            DispatchQueue.main.async { [weak self] in self?.cycleNext() }
            return nil
        }

        if key == 7 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return nil
            }
            xTapHoldTimer?.invalidate()
            let t = Timer(timeInterval: Self.xHoldThreshold, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.xTapHoldTimer = nil
                    self.popupHintXHold = true
                    self.popupHintX = false
                    self.popupHintShiftX = false
                    if self.inTransformStage { self.exitTransformStage() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            xTapHoldTimer = t
            return nil
        }

        if key == 1 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            sTapHoldTimer?.invalidate()
            let t = Timer(timeInterval: Self.xHoldThreshold, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.sTapHoldTimer = nil
                    if self.inShareStage { self.exitShareStage() }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            sTapHoldTimer = t
            return nil
        }

        guard !shift && !opt else { return Unmanaged.passUnretained(event) }

        if key == 8 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in self?.moveSelectedToFront() }
            return nil
        }

        if key == 35 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            let pendingID: UUID? = displayItems.indices.contains(selectedIndex)
                ? displayItems[selectedIndex].id : nil
            pTapHoldTimer?.invalidate()
            let t = Timer(timeInterval: pinHoldThreshold, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pTapHoldTimer = nil
                    guard let id = pendingID,
                          self.items.contains(where: { $0.id == id }) else { return }
                    self.togglePin(id: id)
                    self.resetAutoDismissTimer()
                    self.syncItemPreviewWithSelection()
                    AuthManager.shared.registerActionUsage(actionID: "action.pin")
                }
            }
            RunLoop.main.add(t, forMode: .common)
            pTapHoldTimer = t
            return nil
        }

        if key == 11 && previewWindow.isVisible && reverseCycleUsesB {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            let pendingID: UUID? = displayItems.indices.contains(selectedIndex)
                ? displayItems[selectedIndex].id : nil
            bTapHoldTimer?.invalidate()
            let t = Timer(timeInterval: vHoldThreshold, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.bTapHoldTimer = nil
                    self.popupHintVMark = true
                    guard let id = pendingID,
                          self.items.contains(where: { $0.id == id }) else { return }
                    self.toggleMark(id: id)
                    AuthManager.shared.registerActionUsage(actionID: "action.mark")
                    if self.advanceAfterMark, self.previewWindow.isVisible,
                       !self.displayItems.isEmpty {
                        self.selectedIndex = (self.selectedIndex - 1 + self.displayItems.count) % self.displayItems.count
                        self.syncItemPreviewWithSelection()
                        self.syncTransformPanelWithSelection()
                    }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            bTapHoldTimer = t
            return nil
        }

        if let target = Self.numberRowKeycodeToIndex[key],
           previewWindow.isVisible || pendingFirstOpen {
            DispatchQueue.main.async { [weak self] in self?.selectCategoryByIndex(target) }
            return nil
        }

        if key == 51 && previewWindow.isVisible {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deleteSelected()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    func handlePageRangeKeyDown(key: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch key {
        case 53:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exitPageRangeMode()
                self.dismissPreview()
            }
            return nil
        case 51:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.pageRangeQuery.isEmpty { self.pageRangeQuery.removeLast() }
            }
            return nil
        case 36, 76:
            DispatchQueue.main.async { [weak self] in
                self?.commitPageRangePaste()
            }
            return nil
        case 49:
            DispatchQueue.main.async { [weak self] in
                self?.showPageRangePreview()
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
            let filtered = typed.filter { c in
                c.isNumber || c == "-" || c == "," || c == " "
            }
            if !filtered.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.pageRangeQuery += filtered }
            }
            return nil
        }
    }

    var popupHintSessionActive: Bool {
        previewWindow.isVisible || pendingFirstOpen
    }

    func clearPopupHintHighlights() {
        hintKeyVDown = false
        hintKeyXDown = false
        hintKeyCDown = false
        hintKeySpaceDown = false
        hintCmdHeld = false
        hintShiftHeld = false
        popupHintV = false
        popupHintShiftV = false
        popupHintVMark = false
        popupHintX = false
        popupHintShiftX = false
        popupHintXHold = false
        popupHintC = false
        popupHintSpace = false
        popupHintSpaceDoubleTap = false
        popupHintCmd = false
    }

    func flashSpaceDoubleTapHint() {
        popupHintSpaceDoubleTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.popupHintSpaceDoubleTap = false
        }
    }

    func notePopupHintModifiers(cmd: Bool, shift: Bool) {
        hintCmdHeld = cmd
        hintShiftHeld = shift
        scheduleHintSync()
    }

    func notePopupHintKeyDown(keycode: Int, cmd: Bool) {
        switch keycode {
        case 9 where cmd:  hintKeyVDown = true
        case 7 where cmd:  hintKeyXDown = true
        case 8 where cmd:  hintKeyCDown = true
        case 11 where cmd: hintKeyBDown = true
        case 49:          hintKeySpaceDown = true
        default: break
        }
        scheduleHintSync()
    }

    func notePopupHintKeyUp(keycode: Int) {
        switch keycode {
        case 9:  hintKeyVDown = false
        case 7:  hintKeyXDown = false
        case 8:  hintKeyCDown = false
        case 11: hintKeyBDown = false
        case 49: hintKeySpaceDown = false
        default: break
        }
        if keycode == 9 { popupHintVMark = false }
        if keycode == 7 { popupHintXHold = false }
        scheduleHintSync()
    }

    func scheduleHintSync() {
        guard popupHintSessionActive, !hintSyncScheduled else { return }
        hintSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hintSyncScheduled = false
            self.syncPopupHintHighlights()
        }
    }

    func syncPopupHintHighlights() {
        guard popupHintSessionActive else {
            clearPopupHintHighlights()
            return
        }
        let visible = previewWindow.isVisible
        let cmd = hintCmdHeld

        var v = false, shiftV = false
        if hintKeyVDown && cmd {
            v = !hintShiftHeld
            shiftV = hintShiftHeld && !reverseCycleUsesB
        }
        if reverseCycleUsesB, hintKeyBDown, cmd, visible { shiftV = true }

        var x = false, shiftX = false
        if hintKeyXDown && cmd && visible {
            x = !hintShiftHeld
            shiftX = hintShiftHeld
        }
        let c = hintKeyCDown && cmd && visible
        let space = hintKeySpaceDown && visible

        if popupHintCmd    != cmd    { popupHintCmd = cmd }
        if popupHintV      != v      { popupHintV = v }
        if popupHintShiftV != shiftV { popupHintShiftV = shiftV }
        if popupHintX      != x      { popupHintX = x }
        if popupHintShiftX != shiftX { popupHintShiftX = shiftX }
        if popupHintC      != c      { popupHintC = c }
        if popupHintSpace  != space  { popupHintSpace = space }
    }

}
