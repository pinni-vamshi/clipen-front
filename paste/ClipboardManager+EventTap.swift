import AppKit
import SwiftUI

extension ClipboardManager {
    // MARK: - Event tap

    func attemptEventTap() {
        // Skip if a healthy tap already exists — re-entry would leak
        // CFMachPort + CFRunLoopSource pairs every time and force the
        // system to route every Cmd+V through multiple competing taps.
        if eventTap != nil { return }

        // Cancel any previous permission-polling timer — it may still be
        // running from a prior attemptEventTap() call. Multiple timers
        // would each try to createEventTap and then leak.
        permissionRetryTimer?.invalidate()
        permissionRetryTimer = nil
        // Reset backoff so a fresh attempt cycle starts at 1s, not 30s.
        permissionRetryBackoff = 1.0

        if AXIsProcessTrusted() {
            createEventTap()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            AXIsProcessTrustedWithOptions(opts as CFDictionary)
            scheduleNextPermissionRetry()
        }
    }

    /// Schedules a single retry of `AXIsProcessTrusted` with growing intervals.
    /// 1s → 2s → 4s → 8s → 16s → 30s (capped).  When permission lands the
    /// timer is invalidated immediately and the tap is created.  Keeping it
    /// non-repeating means we can grow the interval each time without ever
    /// having two timers racing.
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
                // Still no permission — double the wait, up to 30s.
                self.permissionRetryBackoff = min(self.permissionRetryBackoff * 2, 30.0)
                self.scheduleNextPermissionRetry()
            }
        }
        if let t = permissionRetryTimer { RunLoop.main.add(t, forMode: .common) }
    }

    /// Remove the existing tap from the run loop and disable it. Called
    /// before recreating a tap so we never end up with two live ones.
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
        // Defensive: if we somehow have a leftover tap, kill it first.
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
        // `hasAccessibilityPermission` is owned by the AX watcher — don't
        // shadow it here. It already flipped to `true` the moment AX
        // trust was granted, regardless of tap creation timing.
    }

    // MARK: - Event handling

    func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // ── Critical: handle tap-disable events ──────────────────────────
        // macOS auto-disables event taps when the callback takes too long
        // to return OR when the user triggers a flood of events. Once
        // disabled, our callback stops being invoked — Cmd+V vanishes into
        // a dead tap and never reaches the system, breaking BOTH our popup
        // AND the system's default paste until the app is quit.
        //
        // The fix: re-enable the tap immediately. This is exactly what
        // every well-behaved event tap (e.g. the BetterTouchTool, Karabiner,
        // Maccy reference impls) does.
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

    /// A click anywhere outside all three popup surfaces (main ring, transform
    /// panel, item preview panel) dismisses the whole popup — same as Esc.
    /// Never swallows the click; it's only observed here, then passed through
    /// untouched so it still reaches whatever app/window it actually landed on.
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
            // itemPreviewPanel showing on its own (main popup closed) means
            // it's a reference panel's "similar items" preview — close it on
            // ANY click outside the preview itself, anywhere on screen, not
            // only clicks that happen to land inside the reference panel's
            // own window (that was the previous, too-narrow behavior).
            if !itemPreviewPanel.frame.contains(loc) {
                DispatchQueue.main.async { [weak self] in self?.itemPreviewPanel.hide() }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Modifier press/release. Releasing ⌘ commits the highlighted paste (or
    /// fast-pastes the front item if the popup hasn't opened yet). While the
    /// page-range picker is active, ⌘ release is ignored — that mode ends only
    /// via ⎋ or ↵.
    func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let hasCmd = event.flags.contains(.maskCommand)
        notePopupHintModifiers(cmd: hasCmd, shift: event.flags.contains(.maskShift))
        if !hasCmd {
            if inPageRangeMode && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            // Same idea as the page-range picker: ⌘ release must NOT commit
            // while the language picker is open — that mode ends only via
            // ⎋ (cancel) or ↵ (translate + paste the chosen language).
            if inLanguagePickerMode && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            // Popup was opened via a HOLD of the first V press (not a tap) —
            // it stays open on ⌘ release. Only the explicit close paths
            // (X button, Esc, click outside) end it; double-click still
            // pastes without closing, same as always.
            if popupPinnedOpen && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            // Search mode (F pressed): letting go of ⌘ must NOT commit/dismiss
            // — that's the whole point of search mode, so the user can release
            // ⌘ and type a query with both hands normally. Enter commits;
            // Esc cancels.
            if isSearchActive && previewWindow.isVisible {
                return Unmanaged.passUnretained(event)
            }
            // Mid-drag: the user has the mouse button down inside the popup
            // (dragging a row out to drop somewhere). Releasing ⌘ during a
            // drag must NOT paste-and-close — the popup teardown killed every
            // drag-and-drop at the instant ⌘ was let go, which made the rows'
            // existing .onDrag support effectively unusable. The drag
            // continues; the popup stays open afterwards (Esc or the next
            // paste closes it).
            if previewWindow.isVisible,
               NSEvent.pressedMouseButtons & 0x1 != 0,
               previewWindow.frame.contains(NSEvent.mouseLocation) {
                return Unmanaged.passUnretained(event)
            }
            if pendingFirstOpen {
                DispatchQueue.main.async { [weak self] in self?.fastPasteFront() }
            } else if previewWindow.isVisible && !escapeWillDismiss {
                // ⌘ release while the popup is open ALWAYS commits the
                // highlighted row (Esc cancels without pasting). escapeWillDismiss
                // guards the race where Esc landed an instant before this and
                // is about to close the popup — see its doc comment.
                DispatchQueue.main.async { [weak self] in self?.commitPaste() }
            }
        }
        return Unmanaged.passUnretained(event)
    }

    func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = Int(event.getIntegerValueField(.keyboardEventKeycode))
        // Releasing V: if the hold timer never fired, this was a genuine tap
        // (not a hold) — cancel it and cycle now, exactly as if V had been
        // handled instantly. If the timer already fired, the mark already
        // happened and vTapHoldTimer is already nil, so there's nothing to do.
        if key == 9, let timer = vTapHoldTimer {
            timer.invalidate()
            vTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in self?.cycleNext() }
        }
        // Releasing V before firstOpenHoldTimer fired means the FIRST V press
        // was a tap, not a hold — the popup already opened immediately on
        // keyDown (unconditionally, tap or hold), so there's nothing left to
        // do here except stop the confirm-timer from ever pinning it.
        if key == 9, let timer = firstOpenHoldTimer {
            timer.invalidate()
            firstOpenHoldTimer = nil
        }
        // Releasing X before the hold timer fired means it was a tap, not a
        // hold — run the open/cycle action now instead of the dismiss.
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
        // Releasing B before its hold timer fired means it was a TAP —
        // step backward now (context-aware: transforms if that panel is
        // open, otherwise the item ring). The hold path (mark + move back)
        // already ran from the timer if it fired.
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
        // Releasing P before its hold timer fired means it was a TAP —
        // cycle to the next pinned item now. The hold path (pin/unpin the
        // highlighted item) already ran from the timer if it fired.
        if key == 35, let timer = pTapHoldTimer {
            timer.invalidate()
            pTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in self?.cyclePinnedItems() }
        }
        // Releasing S before its hold timer fired means it was a TAP — open
        // the Share Sheet or cycle to the next destination. The hold path
        // (close the share panel) already ran from the timer if it fired.
        if key == 1, let timer = sTapHoldTimer {
            timer.invalidate()
            sTapHoldTimer = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.inShareStage { self.cycleShare() } else { self.enterShareStage() }
            }
        }
        // Releasing Space ends the current physical press, independent of
        // whether the OS's autorepeat flag was reliable for this key event
        // stream (see spaceKeyIsDown in handleKeyDown).
        if key == 49 { spaceKeyIsDown = false }
        notePopupHintModifiers(cmd: event.flags.contains(.maskCommand),
                               shift: event.flags.contains(.maskShift))
        notePopupHintKeyUp(keycode: key)
        return Unmanaged.passUnretained(event)
    }

    /// All popup key handling: PDF page picker, Esc, Space preview/pin, V
    /// cycling, X transforms, C move-to-front, ⌘1–9 category filters, ⌫ delete,
    /// and inline search. Returns nil to swallow the event, or passes it through
    /// when Clipen isn't interested.
    func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        // No "a Clipen window is key, let this keystroke through" guard
        // here on purpose — the ring shortcut (hold ⌘, tap V) is meant to
        // work identically everywhere, including while typing in Clipen's
        // own search bar or a notes editor (main window, reference panel).
        // This is safe because every branch below is already scoped
        // tightly enough on its own:
        //   - Plain (non-⌘) keys never reach the popup-specific logic at
        //     all (see the `guard cmd && !ctrl` a few lines down) — normal
        //     typing, backspace, arrows, Enter, Tab are completely
        //     unaffected regardless of what's focused.
        //   - ⌘C/⌘X/etc. only get hijacked once `previewWindow.isVisible`
        //     is already true (i.e. the user already opened the ring) —
        //     otherwise they fall through untouched at the end of this
        //     function, so system copy/cut in a text field is unaffected
        //     until the user has deliberately invoked the ring.
        //   - The committed paste itself (⌘ release) posts a SYNTHETIC ⌘V
        //     guarded by `isSimulatingPaste` (see simulatePaste), which
        //     independently lets that specific event bypass this handler
        //     and land in whatever's really focused — including back into
        //     the same Clipen text field the ring was opened from.
        let key   = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        notePopupHintModifiers(cmd: flags.contains(.maskCommand),
                               shift: flags.contains(.maskShift))
        notePopupHintKeyDown(keycode: Int(key), cmd: flags.contains(.maskCommand))
        let cmd   = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let opt   = flags.contains(.maskAlternate)
        let ctrl  = flags.contains(.maskControl)

        // Any handled popup keystroke counts as activity — postpone the
        // auto-dismiss countdown. Page-range/language-picker mode freeze the
        // timer outright instead (see enterPageRangeMode), so this is
        // deliberately skipped for those two branches below.
        if previewWindow.isVisible && !inPageRangeMode && !inLanguagePickerMode {
            resetAutoDismissTimer()
        }

        // While the "Paste Specific Pages" picker is open, all non-⌘ keys are
        // routed to it (digits/dash/comma build the query; ↵ pastes, ␣ previews,
        // ⎋ cancels).
        if inPageRangeMode && !cmd {
            return handlePageRangeKeyDown(key: key, event: event)
        }

        // While the language picker is open, all non-⌘ keys build the search
        // query / move the highlight / commit / cancel — same routing as
        // the page-range picker above.
        if inLanguagePickerMode && !cmd {
            return handleLanguagePickerKeyDown(key: key, event: event)
        }

        // Escape — clear inline search query first, then exit search mode,
        // then (only if neither applies) dismiss the whole popup.
        if key == 53 && previewWindow.isVisible {
            // Decide synchronously (these are just reads) whether this Esc
            // will actually close the whole popup, so escapeWillDismiss is
            // set before handleFlagsChanged can possibly run for a ⌘-release
            // landing in the same instant. See escapeWillDismiss's doc comment.
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

        // F — enter search mode. Not typed as a character; it flips a mode
        // that changes what Space, ⌘-release, and the arrow keys do (see
        // isSearchActive's doc comment). No !cmd check, same reasoning as
        // Space below: the popup only stays open while ⌘ is already held, so
        // requiring !cmd here would mean this could never fire.
        // !isSearchActive is load-bearing: without it this handler (which runs
        // BEFORE the search-typing block) swallowed every "f" pressed while
        // already searching — making it impossible to ever type the letter f
        // into a query ("coffee", "file"…). Once search is active, f is just
        // a character like any other.
        if key == 3 && !ctrl && !opt && !isSearchActive && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in
                self?.isSearchActive = true
                AuthManager.shared.registerActionUsage(actionID: "action.popup-search")
            }
            return nil
        }

        // Enter/Return — commit while the popup is open. In search mode this
        // mirrors ⌘-release's normal commit (search mode suppresses that path
        // specifically so this is needed as the alternative way to finish).
        // Outside search mode it's the way to commit a ⌘/⇧-click multi-
        // selection or a pinned-open popup without needing ⌘ held down —
        // commitPaste() already knows to paste every marked item together
        // when markedItemIDs isn't empty, same as the hold-V mark queue.
        if (key == 36 || key == 76) && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in self?.commitPaste() }
            return nil
        }

        // ↑/↓ — move the selection within the (possibly filtered) list while
        // in search mode, without needing ⌘ held (⌘ is likely already
        // released at this point, that's the point of search mode).
        if isSearchActive && previewWindow.isVisible && (key == 125 || key == 126) {
            if key == 126 {
                DispatchQueue.main.async { [weak self] in self?.cyclePrevious() }
            } else {
                DispatchQueue.main.async { [weak self] in self?.cycleNext() }
            }
            return nil
        }

        if key == 49 && !ctrl && !opt {
            // Only the FIRST physical keyDown of a press is ever treated as a
            // tap — spaceKeyIsDown is reset on keyUp, so it can't suppress a
            // genuine second tap of a real double-tap (that always has a keyUp
            // between the two presses). It exists because CGEvent's autorepeat
            // flag alone isn't trustworthy enough through an event tap; relying
            // on it solely let a held Space key be misread as a rapid stream of
            // fresh presses, each landing inside the double-tap window and
            // spawning a new Quick Clip panel over and over for as long as the
            // key was held.
            let isRepeat = spaceKeyIsDown
            spaceKeyIsDown = true
            let isAutorepeat = isRepeat || event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            // Space INSIDE the popup: handle regardless of ⌘ (the popup only
            // stays open while ⌘ is held, so the flag is almost always set —
            // requiring !cmd here is exactly why Space used to fall through and
            // type into the app instead of previewing). First tap toggles the
            // large preview; a second quick tap pins the selection into a Quick
            // Clip panel. Autorepeat is ignored so a held key can't machine-gun
            // the toggle / pin.
            // EXCEPT in search mode — there, Space is just another character to
            // search for, so skip all of this and let it fall through to the
            // printable-character catch-all below instead.
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

            // NOTE: there used to be a "double-tap Space outside the popup
            // pins the newest item" gesture here. It's removed — it ran on
            // EVERY Space keydown system-wide, in every app, all the time
            // (this whole `if key == 49` branch isn't gated on the popup
            // being open). Space is the single most-typed character on a
            // keyboard, so two ordinary key presses typed at normal speed —
            // literally just typing a sentence — regularly land under the
            // 0.35s window and get misread as an intentional double-tap,
            // spawning Quick Clip panels continuously during normal typing in
            // any app. Pinning via double-tap-Space is still available WHILE
            // the ring popup is open (handled above) — that context is
            // constrained to when ⌘ is already held and the popup is visible,
            // so it can't fire from ordinary typing.
        }

        // Search mode: build the query here, BEFORE the `guard cmd` below.
        // That guard returns early whenever ⌘ isn't held — which, now that
        // search mode lets the user release ⌘ and type normally, is exactly
        // the state typing happens in. Handling it after the guard would mean
        // it could never fire while ⌘ is up (and the previous inline-search
        // catch-all further down never actually worked, for that same
        // reason — it required !cmd but sat after a guard that requires cmd).
        // Escape/F/Enter/arrows are already handled above this point.
        // !cmd: while ⌘ is (still) held during search mode, keys stay
        // commands — ⌘V cycles, ⌘1–9 switch categories, ⌫ deletes the item —
        // instead of being eaten into the query. Plain (⌘-released) keys type.
        if isSearchActive && previewWindow.isVisible && !cmd {
            if key == 51 { // ⌫ Backspace
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
            // Swallow everything else too — nothing typed while composing a
            // search query should leak through to the app underneath.
            return nil
        }

        // Plain ⌘ allowed; ⌃ never. Shift is allowed only for the V key
        // (⌘⇧V → next category) — handled below before we tighten the
        // guard further down.
        guard cmd && !ctrl else { return Unmanaged.passUnretained(event) }

        if key == 9 { // V — ⌘V cycle, ⌘⌥V jump+5, ⌘⇧V next category
            if isSimulatingPaste { return Unmanaged.passUnretained(event) }
            let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            // Plain V while the popup is ALREADY open: don't act on keyDown at
            // all — wait to see whether this turns into a tap (cycle) or a
            // hold (mark), the same wait-then-decide shape cycleNext() already
            // uses for ⌘V itself via pendingFirstOpen/pendingFirstOpenTimer.
            // The decision fires either when the timer elapses while V is
            // still held (hold → mark, via the timer closure) or when keyUp
            // arrives first (tap → cycle, handled in handleKeyUp). Every
            // autorepeat event in between is swallowed with no new action —
            // one physical hold produces exactly one decision.
            if previewWindow.isVisible && !shift && !opt {
                if !isAutorepeat {
                    // Capture the item's ID (not its index) — if a new capture
                    // lands between keyDown and the timer firing, an index
                    // would silently point at a different row; the ID either
                    // resolves to the same item or the mark is skipped.
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
                            // Optional: mark a run of items without a separate
                            // V-tap between each hold — advance the selection
                            // right after marking, same step cycleNext takes.
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
                DispatchQueue.main.async { [weak self] in self?.cyclePrevious() }
                return nil
            }

            if opt {
                // ⌘⌥V — jump 5 items forward
                DispatchQueue.main.async { [weak self] in self?.jumpForward(by: 5) }
                return nil
            }

            // Plain V while the popup ISN'T open yet — open IMMEDIATELY,
            // tap or hold, exactly like before this feature existed. Do NOT
            // wait to see which one it is; only whether it turns into a
            // hold is decided afterward, in the background, while the
            // now-open popup is already showing. If V is still down
            // `vHoldThreshold` later, the hold is confirmed and the popup
            // becomes PINNED — handled by firstOpenHoldTimer below.
            if !isAutorepeat {
                firstOpenHoldTimer?.invalidate()
                let t = Timer(timeInterval: pinnedOpenHoldThreshold, repeats: false) { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.firstOpenHoldTimer = nil
                        // Only pins if the popup this hold opened is still
                        // the one showing (guards against a stray fire after
                        // a fast dismiss/reopen in between).
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

        // X — tap opens/cycles the transform panel (⌘X forward, ⌘⇧X back);
        // holding X dismisses it. Mirrors the V tap-vs-hold pattern: the tap
        // action fires on key-up if the hold timer never fires, and the hold
        // timer fires the dismiss while X is still down.
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

        // S — tap-vs-hold, mirroring X for the transform panel:
        //   tap  → open the native Share Sheet for the highlighted item (or
        //          every marked item); tapping again cycles destinations
        //   hold → close the share panel
        // Releasing ⌘ (commitPaste → commitShare) still sends via whichever
        // destination is highlighted. The tap action fires on key-up if the
        // hold timer never fired; the hold timer fires the close while S is
        // still down.
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

        // Other shortcuts require plain ⌘ — no shift, no opt.
        guard !shift && !opt else { return Unmanaged.passUnretained(event) }

        // C — move the highlighted item to the front (position 0) of the ring.
        // ⌘ is held while the popup is open, so this reads as ⌘C at the tap;
        // one press per hold (swallow autorepeat) so it can't thrash the ring.
        if key == 8 && previewWindow.isVisible {
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return nil }
            DispatchQueue.main.async { [weak self] in self?.moveSelectedToFront() }
            return nil
        }

        // P — tap-vs-hold, same wait-then-decide shape as V:
        //   tap  → cycle through PINNED items only (wraps at the end)
        //   hold → pin/unpin the highlighted item
        // The decision fires either when the timer elapses while P is still
        // held (hold → pin) or when keyUp arrives first (tap → cycle, in
        // handleKeyUp). Autorepeat between is swallowed.
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

        // B — context-aware "back", only when the user picked B as the
        // reverse key in Settings. Same tap-vs-hold decision shape as V:
        //   tap  → step backward (previous transform while the transform
        //          panel is open, previous item otherwise)
        //   hold → mark/unmark the highlighted item, then auto-move
        //          BACKWARD when advance-after-marking is on — V's
        //          hold-to-mark mirrored, in the reverse direction.
        // ⇧V and ⇧X keep working regardless.
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

        // ⌘1 … ⌘9 — switch the CATEGORY filter (was: jump to row N).
        // ⌘1 = Recents (no filter), ⌘2 = first available category, ⌘3 =
        // second, …  Numbers are advertised by the "1.", "2." prefixes on
        // the category chip strip itself, so the binding is discoverable.
        if let target = Self.numberRowKeycodeToIndex[key],
           previewWindow.isVisible || pendingFirstOpen {
            DispatchQueue.main.async { [weak self] in self?.selectCategoryByIndex(target) }
            return nil
        }

        if key == 51 && previewWindow.isVisible { // ⌫ — delete highlighted item
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deleteSelected()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    /// Keystrokes while the inline PDF page-range picker is open. Digits, dash,
    /// comma (and space) build the query; ↵ pastes, ␣ previews, ⎋ cancels, ⌫
    /// edits. Everything is swallowed so stray keys never reach the target app.
    func handlePageRangeKeyDown(key: Int64, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch key {
        case 53: // Esc — exit picker mode AND close the popup. Nothing pastes.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.exitPageRangeMode()
                self.dismissPreview()
            }
            return nil
        case 51: // ⌫ Backspace
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.pageRangeQuery.isEmpty { self.pageRangeQuery.removeLast() }
            }
            return nil
        case 36, 76: // Return / Enter — commit paste
            DispatchQueue.main.async { [weak self] in
                self?.commitPageRangePaste()
            }
            return nil
        case 49: // Space — toggle inline preview of would-be-pasted text
            DispatchQueue.main.async { [weak self] in
                self?.showPageRangePreview()
            }
            return nil
        default:
            // Accept digits, dash, and comma only — silently drop everything else.
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

    // MARK: - Popup header hint press feedback

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

    /// Pulses the "double-tap Space · Refer" hint blue briefly — double-tap has
    /// no sustained "held" state the way V/X do, so this is a timed flash
    /// instead of a live key-state highlight.
    func flashSpaceDoubleTapHint() {
        popupHintSpaceDoubleTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.popupHintSpaceDoubleTap = false
        }
    }

    func notePopupHintModifiers(cmd: Bool, shift: Bool) {
        hintCmdHeld = cmd
        hintShiftHeld = shift
        // The header hint highlights only matter while the popup is on screen.
        // Skip the main-queue dispatch (and the @Published churn it triggers)
        // otherwise — this callback fires on EVERY keystroke system-wide, so
        // dispatching when nothing is visible was pure battery waste. The
        // highlights are cleared on popup close via clearPopupHintHighlights().
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
        // The hold-fired flags (V-mark, X-close) only make sense for the
        // duration of THIS hold — clear them the instant the key comes back
        // up, otherwise a completed mark/close would stay lit until the next
        // press of the same key.
        if keycode == 9 { popupHintVMark = false }
        if keycode == 7 { popupHintXHold = false }
        scheduleHintSync()
    }

    /// Coalesced entry point for the note… callbacks — schedules at most ONE
    /// hint recompute per main-queue turn no matter how many key callbacks
    /// fired, and no-ops entirely while the popup isn't on screen.
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
            shiftV = hintShiftHeld
        }
        // With B as the chosen reverse key, the "Prev" hint (relabelled "B"
        // in the legend) lights up on ⌘B too.
        if reverseCycleUsesB, hintKeyBDown, cmd, visible { shiftV = true }

        var x = false, shiftX = false
        if hintKeyXDown && cmd && visible {
            x = !hintShiftHeld
            shiftX = hintShiftHeld
        }
        let c = hintKeyCDown && cmd && visible
        let space = hintKeySpaceDown && visible

        // Assign ONLY what changed. @Published fires objectWillChange on every
        // set — even to the same value — and each fire re-renders the entire
        // popup, so a keystroke that changes no highlight must produce zero
        // re-renders, not seven.
        if popupHintCmd    != cmd    { popupHintCmd = cmd }
        if popupHintV      != v      { popupHintV = v }
        if popupHintShiftV != shiftV { popupHintShiftV = shiftV }
        if popupHintX      != x      { popupHintX = x }
        if popupHintShiftX != shiftX { popupHintShiftX = shiftX }
        if popupHintC      != c      { popupHintC = c }
        if popupHintSpace  != space  { popupHintSpace = space }
    }


}
