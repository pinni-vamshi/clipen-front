import AppKit
import SwiftUI
import NaturalLanguage
import Accelerate
@preconcurrency import PDFKit

extension ClipboardManager {

    func recomputeEmbeddingsInBackground() {

        let snapshot = items.filter { $0.embedding == nil }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard ClipenEmbedder.shared.isAvailable else { return }
            guard !snapshot.isEmpty else { return }
            var computed: [(id: UUID, vector: [Float])] = []
            computed.reserveCapacity(snapshot.count)
            for item in snapshot {
                guard self != nil else { return }
                guard let str = item.richEmbeddingText,
                      let vector = ClipenEmbedder.shared.vector(for: str) else { continue }
                computed.append((item.id, vector))
            }
            guard !computed.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var byID: [UUID: [Float]] = Dictionary(computed.map { ($0.id, $0.vector) }, uniquingKeysWith: { _, last in last })
                var updated = self.items
                var applied = 0
                for idx in updated.indices where updated[idx].embedding == nil {
                    guard let floats = byID.removeValue(forKey: updated[idx].id) else { continue }
                    updated[idx].embedding = floats
                    applied += 1
                }
                guard applied > 0 else { return }
                self.items = updated
                self.embeddedItemCount += applied
                self.saveQueue.async { self.embeddingsDirty = true }
            }
        }
    }

    func cancelPendingFirstOpen() {
        pendingFirstOpenTimer?.invalidate()
        pendingFirstOpenTimer = nil
        pendingFirstOpen = false
    }

    /// R either opens the similar-items side panel for the current
    /// selection, or — if it's already open — advances to the next (or,
    /// with Shift held, previous) related item within it. Deliberately
    /// doesn't touch search, the item preview panel's own auto-show logic,
    /// or the main list's selectedIndex: this panel drives its own cursor
    /// independently, same as TransformPanel does for its tool list.
    func handleFindSimilarKey(backward: Bool = false) {
        guard previewWindow.isVisible,
              displayItems.indices.contains(selectedIndex) else { return }
        if inSimilarStage {
            backward ? cycleSimilarBackward() : cycleSimilarForward()
        } else {
            enterSimilarStage()
        }
    }

    func enterSimilarStage() {
        guard displayItems.indices.contains(selectedIndex) else { return }
        let item = displayItems[selectedIndex]
        let results = similarItems(to: item)
        guard !results.isEmpty else {
            flashStatus("No similar items found.")
            return
        }
        similarPanelItems = results
        similarPanelIndex = 0
        similarPanelSourceItemID = item.id
        setSidePanelStage(.similar)
        AuthManager.shared.registerActionUsage(actionID: "action.find-similar")
        playInteractionSoundIfEnabled(.similar)
        updateSimilarPanel()
    }

    func cycleSimilarForward() {
        guard inSimilarStage, !similarPanelItems.isEmpty else { return }
        similarPanelIndex = Self.cyclicIndex(similarPanelIndex, count: similarPanelItems.count, backward: false)
        AuthManager.shared.registerActionUsage(actionID: "action.find-similar")
        playInteractionSoundIfEnabled(.similar)
        updateSimilarPanel()
    }

    func cycleSimilarBackward() {
        guard inSimilarStage, !similarPanelItems.isEmpty else { return }
        similarPanelIndex = Self.cyclicIndex(similarPanelIndex, count: similarPanelItems.count, backward: true)
        AuthManager.shared.registerActionUsage(actionID: "action.find-similar")
        playInteractionSoundIfEnabled(.similar)
        updateSimilarPanel()
    }

    func updateSimilarPanel() {
        guard inSimilarStage, !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let anchor = previewWindow.selectedRowAnchorPoint(
            selectedIndex: selectedIndex,
            totalItems: displayItems.count
        )
        // Computed here and passed in as a prop, same pattern PopoverRow
        // already uses for the main list — SimilarPanelView used to read
        // ClipboardManager.shared.markOrder(for:) itself from inside body,
        // a global read SwiftUI has no visibility into. Marking the
        // CURRENTLY displayed item doesn't change `items` or
        // `selectedIndex` (the view's only real props), so SwiftUI saw no
        // reason to re-invoke body and the badge never appeared until
        // selectedIndex genuinely changed later (navigating away and
        // back). An explicit prop makes the change visible to SwiftUI's
        // own diffing, the same way it already works for the main list.
        let currentMarkOrder = similarPanelItems.indices.contains(similarPanelIndex)
            ? markOrder(for: similarPanelItems[similarPanelIndex].id) : nil
        similarPanel.show(sourceItem: displayItems[selectedIndex],
                          items: similarPanelItems,
                          selectedIndex: similarPanelIndex,
                          markOrder: currentMarkOrder,
                          near: previewWindow.frame,
                          anchorPoint: anchor)
    }

    func syncSimilarPanelWithSelection() {
        guard inSimilarStage, previewWindow.isVisible,
              !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let currentID = displayItems[selectedIndex].id
        guard currentID != similarPanelSourceItemID else { return }
        setSidePanelStage(.none)
    }

    func fastPasteFront() {
        clearPopupHintHighlights()
        cancelPendingFirstOpen()
        guard !displayItems.isEmpty else { return }

        guard ProGate.shared.isUnlocked else {
            openPopupNow()
            return
        }
        selectedIndex = 0
        setSidePanelStage(.none)
        AuthManager.shared.registerFastPasteAction()
        commitPaste(countsAsFastPaste: true)
        showFastPasteHintIfNeeded()
    }

    func showFastPasteHintIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fastPasteHintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: fastPasteHintShownKey)
        let delayMs = max(1, Int((firstOpenDelay * 1000).rounded()))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.fastPasteHintPanel.show(delayMs: delayMs) {
                AppDelegate.shared?.openMainWindow()
                ClipboardManager.shared.pulseOpenDelaySlider()
            }
        }
    }

    func deleteSelected() {
        if !markedItemIDs.isEmpty {
            deleteMarked()
            return
        }
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let target = displayItems[selectedIndex]
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.delete")
        popupSessionDeleted = true
        items.remove(at: realIndex)
        markBlobPurgeNeeded()
        if displayItems.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)

        selectionDidChange()
    }

    func deleteMarked() {
        let ids = Set(markedItemIDs)
        guard !ids.isEmpty else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.delete", count: ids.count)
        popupSessionDeleted = true
        markedItemIDs = []
        items.removeAll { ids.contains($0.id) }
        markBlobPurgeNeeded()
        if displayItems.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)
        selectionDidChange()
        flashStatus("Deleted \(ids.count) items.")
    }

    func moveSelectedToFront() {
        AuthManager.shared.registerActionUsage(actionID: "action.front")
        if !markedItemIDs.isEmpty {
            moveMarkedToFront()
            return
        }
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let target = displayItems[selectedIndex]
        let nextID: UUID? = displayItems.indices.contains(selectedIndex + 1)
            ? displayItems[selectedIndex + 1].id
            : nil
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        guard realIndex != 0 else { return }
        let moved = items.remove(at: realIndex)
        items.insert(moved, at: 0)
        if let nextID, let idx = displayItems.firstIndex(where: { $0.id == nextID }) {
            selectedIndex = idx
        } else {
            clampSelectedIndexToDisplay()
        }
        selectionDidChange()
    }

    func moveMarkedToFront() {
        let orderedItems = orderedMarkedItems
        guard !orderedItems.isEmpty else { return }
        let movedIDs = Set(orderedItems.map(\.id))
        let remaining = items.filter { !movedIDs.contains($0.id) }
        items = orderedItems + remaining
        if let firstID = orderedItems.first?.id,
           let newIdx = displayItems.firstIndex(where: { $0.id == firstID }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = 0
        }
        selectionDidChange()
    }

    func clampSelectedIndexToDisplay() {
        let display = displayItems
        guard !display.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex), display.count - 1)
    }

    func finalizePopupOutcome() {
        guard popupSessionActive, !popupSessionOutcomeRecorded else { return }
        popupSessionOutcomeRecorded = true
        popupSessionActive = false
        let outcome: String
        if popupSessionPasted {
            outcome = "pasted"
        } else if popupSessionDeleted {
            outcome = "deleted"
        } else if popupSessionAutoTimedOut {
            outcome = "blank"
        } else {
            outcome = "escaped"
        }
        TrackingService.shared.recordPopupOutcome(outcome)
    }

    func dismissPreview() {
        if isInlineEditing { inlineEditItemID = nil; itemPreviewPanel.hide() }
        if previewWindow.isVisible {
            if let openedAt = popupOpenedAt {
                let ms = max(0, Int(Date().timeIntervalSince(openedAt) * 1000))
                TrackingService.shared.recordPopupDuration(ms: ms)
            }
            if !popupSessionPasted {
                AuthManager.shared.registerActionUsage(actionID: "popup.abandon")
            }
        }
        finalizePopupOutcome()
        popupOpenedAt = nil
        captureRememberedSelection()
        clearPopupHintHighlights()
        stopAutoDismissTimer()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        userOpenedItemPreview = false
        cancelPendingFirstOpen()
        vTapHoldTimer?.invalidate()
        vTapHoldTimer = nil
        bTapHoldTimer?.invalidate()
        bTapHoldTimer = nil
        pTapHoldTimer?.invalidate()
        pTapHoldTimer = nil
        sTapHoldTimer?.invalidate()
        sTapHoldTimer = nil
        firstOpenHoldTimer?.invalidate()
        firstOpenHoldTimer = nil
        popupPinnedOpen = false
        caseTransformOriginals.removeAll()
        xTapHoldTimer?.invalidate()
        xTapHoldTimer = nil
        rTapHoldTimer?.invalidate()
        rTapHoldTimer = nil
        setSidePanelStage(.none)
        selectedIndex    = 0
        popupTagFilter   = nil
        cycleCount       = 0
        markedItemIDs      = []
        popupSearchQuery   = ""
        isSearchActive     = false
        inPageRangeMode = false
        pageRangeQuery = ""
        pageRangeManualPages = []
        pageRangePageCount = 0
        pageRangePDF = nil
        inLanguagePickerMode = false
        languagePickerQuery = ""
        languagePickerSelectedIndex = 0
        languagePickerSourceItem = nil
    }

    func selectedItemForQuickClip() -> ClipboardItem? {
        guard displayItems.indices.contains(selectedIndex) else { return nil }
        return displayItems[selectedIndex]
    }

    func openQuickClipPanelForSelection() {
        itemPreviewPanel.hide()
        AuthManager.shared.registerActionUsage(actionID: "action.reference-pin")
        markNudgeUsedNaturally(.pinPreview)

        if !markedItemIDs.isEmpty {
            let orderedItems = orderedMarkedItems
            guard !orderedItems.isEmpty else { return }
            for item in orderedItems {
                openQuickClipPanel(for: item)
            }
            return
        }

        guard let item = selectedItemForQuickClip() else { return }
        openQuickClipPanel(for: item)
    }

    func openQuickClipPanel(for item: ClipboardItem, focusContent: Bool = false) {
        let ownerBundleID = capturedPasteTarget?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // The owning app's live context (front tab URL, Finder path, etc.)
        // used to be fetched here via a synchronous AppleScript/AX
        // round-trip before the panel was even created — that's
        // cross-process IPC on the main thread, blocking the popup UI for
        // however long the target app takes to answer. The panel opens
        // immediately without it now; the context attaches to this
        // specific page a moment later, off-main, same pattern already
        // used by fetchReferenceContext.
        if let ownerBundleID {
            referenceContextQueue.async { [weak self] in
                let context = AppContextService.currentContext(for: ownerBundleID)
                guard let context else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard let panel = self.quickClipPanels.first(where: { panel in
                        panel.carousel.pages.contains(where: { $0.id == item.id })
                    }) else { return }
                    panel.carousel.attachContext(context, toPage: item.id, bundleID: ownerBundleID)
                }
            }
        }

        if let panel = sharedCarouselPanel {
            panel.addPage(item, focusContent: focusContent, ownerBundleID: ownerBundleID)
            panel.orderFrontRegardless()
            return
        }

        if quickClipPanels.count >= 5 {
            let oldest = quickClipPanels.removeFirst()
            oldest.close()
        }
        let panel = QuickClipPanel(item: item, offset: 0, focusContent: focusContent,
                                   ownerBundleID: ownerBundleID)
        panel.orderFrontRegardless()
        quickClipPanels.append(panel)
        sharedCarouselPanel = panel
        surfaceAllPanelsAgainstFrontmostApp()
    }

    func openStandaloneQuickClipPanel(for item: ClipboardItem) {
        if quickClipPanels.count >= 5 {
            let oldest = quickClipPanels.removeFirst()
            oldest.close()
        }
        let offset = CGFloat(quickClipPanels.count * 30)
        let panel = QuickClipPanel(item: item, offset: offset)
        panel.orderFrontRegardless()
        quickClipPanels.append(panel)
        surfaceAllPanelsAgainstFrontmostApp()
    }

    /// A freshly created panel only ever gets evaluated against whichever
    /// app happens to activate NEXT — but the QuickClip popup that just
    /// created it is .nonactivatingPanel, so the app the user was actually
    /// in (Claude, ChatGPT, whatever) never fires a fresh
    /// didActivateApplicationNotification around this whole interaction —
    /// it was frontmost before, during, and after. Without this, a brand
    /// new panel could sit expanded indefinitely, never checked against
    /// what's really on top, until the user happens to switch apps again.
    private func surfaceAllPanelsAgainstFrontmostApp() {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        surfaceReferencePanel(forActiveApp: bundleID)
    }

    func quickClipPanelDidClose(_ panel: NSPanel) {
        quickClipPanels.removeAll { $0 === panel }
        if sharedCarouselPanel === panel { sharedCarouselPanel = nil }
    }

    /// `logRanking`: prints each result's lexical/semantic/recency
    /// breakdown to DebugLog. Off by default — this is for the popup search
    /// bar, where a user can directly compare "why did the item I expected
    /// rank low" against real numbers instead of a guess about how the
    /// scorer behaves. Confirmed live: a URL clipboard item ranked 7th-8th
    /// for a descriptive query, and the scorer's fractional token-overlap
    /// (hits/totalTokens) means a query with words not literally present in
    /// the URL string loses to unrelated items that happen to contain more
    /// of the query's literal words.
    /// `affinityBundleID`: when set, items this app has been involved with
    /// score higher — see `appAffinityBoost`. Opt-in and defaulted to nil so
    /// the popup search bar, related-items, and every other caller keep
    /// exactly the ranking they had.
    /// `preferValues`: rank short, self-contained items (a command, an
    /// address, a URL, an ID) above long prose that merely shares
    /// vocabulary. Opt-in and off by default so the popup search bar is
    /// untouched.
    func hybridSearch(query: String, logRanking: Bool = false, affinityBundleID: String? = nil, preferValues: Bool = false) -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count >= 2 else { return [] }

        // The cached result is only reusable for the same affinity, since
        // affinity changes the ordering. Without this, switching from
        // Terminal to Notes would keep serving Terminal-boosted results.
        if q == lastSearchQuery
            && itemsRevision == lastSearchItemsRev
            && embeddedItemCount == lastSearchEmbedRev
            && affinityBundleID == lastSearchAffinity
            && preferValues == lastSearchPreferValues
            && !logRanking {
            return lastSearchResult
        }

        let qNorm = ClipboardItem.normalize(q)
        let qTokens = Self.queryTokens(qNorm)
        let firstToken = qTokens.first

        var queryVec: [Float]? = nil
        if AuthManager.shared.semanticSearch,
           let v = ClipenEmbedder.shared.vector(for: qNorm) {
            queryVec = v
        }
        if logRanking {
            DebugLog.write("SEARCH-RANK: query=\"\(q)\" tokens=\(qTokens) hasQueryEmbedding=\(queryVec != nil)")
        }

        let now = Date()
        var scored: [(ClipboardItem, Float)] = []
        scored.reserveCapacity(items.count)
        // Only populated when logRanking, and only on the path below that
        // computes lex/sem/rec as separate locals per item.
        var detail: [(ClipboardItem, lex: Float, sem: Float, rec: Float, combined: Float)] = []

        if items.count >= 128 {
            var scores = [Float](repeating: 0, count: items.count)
            scores.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: items.count) { i in
                    let item = items[i]
                    let lex = Self.lexicalScore(query: qNorm, tokens: qTokens, firstToken: firstToken, item: item)
                    let sem = Self.semanticComponent(queryVec: queryVec, itemVec: item.embedding)
                    let rec = Self.recencyBoost(item: item, now: now)
                    let aff = Self.appAffinityBoost(item: item, bundleID: affinityBundleID)
                    let val = preferValues ? Self.valueShapeScore(item: item) : 0
                    buf[i] = 0.55 * lex + 0.40 * sem + rec + aff + val
                }
            }
            for i in items.indices where scores[i] >= 0.15 {
                scored.append((items[i], scores[i]))
            }
        } else {
            for item in items {
                let lex = Self.lexicalScore(query: qNorm, tokens: qTokens, firstToken: firstToken, item: item)
                let sem = Self.semanticComponent(queryVec: queryVec, itemVec: item.embedding)
                let rec = Self.recencyBoost(item: item, now: now)
                let aff = Self.appAffinityBoost(item: item, bundleID: affinityBundleID)
                let val = preferValues ? Self.valueShapeScore(item: item) : 0

                let combined = 0.55 * lex + 0.40 * sem + rec + aff + val
                if logRanking {
                    detail.append((item, lex, sem, rec, combined))
                }
                if combined >= 0.15 {
                    scored.append((item, combined))
                }
            }
        }

        if logRanking {
            // Every item that scored ANYTHING, not just the ones that
            // cleared the 0.15 display threshold — an item ranking 7th
            // needs to be visible here even if it's below that bar, since
            // that's precisely the case worth inspecting.
            let ranked = detail.sorted { $0.combined > $1.combined }
            DebugLog.write("SEARCH-RANK: \(ranked.count) items scored, top 10:")
            for (i, r) in ranked.prefix(10).enumerated() {
                let preview = String(r.0.searchPreviewNorm.prefix(60))
                DebugLog.write(String(format: "  #%d combined=%.3f lex=%.3f sem=%.3f rec=%.3f  \"%@\"",
                                         i + 1, r.combined, r.lex, r.sem, r.rec, preview))
            }
        }

        let sorted = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        lastSearchQuery = q
        lastSearchResult = sorted
        lastSearchItemsRev = itemsRevision
        lastSearchEmbedRev = embeddedItemCount
        lastSearchAffinity = affinityBundleID
        lastSearchPreferValues = preferValues
        return sorted
    }

    nonisolated static func queryTokens(_ qNorm: String) -> [String] {
        var seen = Set<String>()
        return qNorm
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    nonisolated static func lexicalScore(query: String,
                                     tokens: [String],
                                     firstToken: String?,
                                     item: ClipboardItem) -> Float {
        var best: Float = 0
        best = max(best, score(text: item.searchPreviewNorm, query: query, tokens: tokens, firstToken: firstToken) * 1.00)
        best = max(best, score(text: item.searchEmbedNorm,   query: query, tokens: tokens, firstToken: firstToken) * 0.70)
        best = max(best, score(text: item.searchMetaNorm,    query: query, tokens: tokens, firstToken: firstToken) * 0.55)
        best = max(best, tagBoost(tokens: tokens, item: item))
        return best
    }

    /// A query word can name the KIND of thing the user wants ("url",
    /// "code", "pdf") without that word ever literally appearing in the
    /// item's own text — a bare GitHub link contains none of the letters
    /// u-r-l. `score()`'s literal substring overlap has no way to credit
    /// that, so a query like "github project url" scored a real .url item
    /// at 0.33 (only "github" matched) while an unrelated item containing
    /// all three words literally scored 1.0 and outranked it 7th-8th.
    /// This checks each query token against the same synonym table
    /// `parseSearchIntent` uses for category filters, and if a token names
    /// a tag the item actually carries, credits it as a match. Deliberately
    /// capped below 1.0 (a single-tag match alone shouldn't beat an item
    /// that also matches every word literally) and only fires per-token —
    /// it does not replace literal scoring, only supplements it.
    @inline(__always)
    nonisolated static func tagBoost(tokens: [String], item: ClipboardItem) -> Float {
        guard !item.tags.isEmpty else { return 0 }
        var hits = 0
        for t in tokens {
            if let tag = tagSynonymLookup[t], item.tags.contains(tag) {
                hits += 1
            }
        }
        guard hits > 0 else { return 0 }
        return min(0.85, 0.5 + 0.15 * Float(hits - 1))
    }

    @inline(__always)
    nonisolated static func score(text: String, query: String, tokens: [String], firstToken: String?) -> Float {
        guard !text.isEmpty else { return 0 }
        if !query.isEmpty && text.contains(query) { return 1.0 }
        guard !tokens.isEmpty else { return 0 }
        var hits = 0
        for t in tokens where text.contains(t) { hits += 1 }
        var s = Float(hits) / Float(tokens.count)
        if s > 0, let first = firstToken,
           text.hasPrefix(first) || text.contains(" " + first) {
            s = min(1.0, s + 0.15)
        }
        return s
    }

    nonisolated static func semanticComponent(queryVec: [Float]?, itemVec: [Float]?) -> Float {
        guard let qv = queryVec, let iv = itemVec else { return 0 }
        let cos = cosineSimilarity(qv, iv)
        return max(0, min(1, (cos - 0.3) / 0.5))
    }

    /// Extra weight for clipboard items tied to the app the user is
    /// currently typing in.
    ///
    /// Retrieval previously ranked purely on how much an item *reads like*
    /// the sentence being written, which meant the best match for your own
    /// prose was usually your own earlier prose — the model then continued
    /// that old text instead of the live sentence. What app an item belongs
    /// to is a much sharper relevance signal for completion: a shell command
    /// is what you want in Terminal, a code fragment in an editor, a
    /// recipient address in Mail.
    ///
    /// Two tiers, because they mean different things. An item COPIED FROM
    /// this app is the strongest signal — it is literally content from this
    /// context. An item PASTED INTO this app is weaker but still real: it is
    /// something the user has chosen to put here before.
    ///
    /// Deliberately additive and small. It reorders items that already
    /// matched the query; it must never drag in an unrelated item purely
    /// because the app lines up.
    /// Rewards items shaped like an answer rather than a description.
    ///
    /// The ranker's dominant term is literal word overlap, which is exactly
    /// backwards when the user is reaching for a value. Typing "the terminal
    /// command for the user reply from clipen database is " shares ZERO words
    /// with `cd "/Users/…" && python3 -m venv` — a path and a binary name —
    /// so the command scored near nothing, while any long note containing
    /// "clipen" and "database" scored well and won. No amount of reordering
    /// within that ranking fixes it; the shape of the item has to count.
    ///
    /// Short and structurally typed wins; long prose is pushed down. The
    /// magnitudes sit above a lexical near-miss but below a strong literal
    /// match, so this reorders genuinely ambiguous cases without letting an
    /// unrelated URL outrank an item the user actually named.
    nonisolated static func valueShapeScore(item: ClipboardItem) -> Float {
        let text = item.searchPreviewNorm
        guard !text.isEmpty else { return 0 }

        var score: Float = 0

        // Structurally identified content: an address, a link, a snippet.
        let valueTags: Set<ClipboardTag> = [.url, .email, .phone, .code, .json, .color]
        if !valueTags.isDisjoint(with: item.tags) { score += 0.22 }

        // Shell command or filesystem path — the case that motivated this.
        if looksLikeCommandOrPath(text) { score += 0.30 }

        // Brevity is the signal that something IS the answer rather than
        // discussing it. A one-line command, an address, an ID.
        if text.count <= 200 { score += 0.12 }

        // Long prose merely sharing vocabulary is what kept winning.
        if text.count > 600 { score -= 0.18 }

        return score
    }

    private static let commandHeads: Set<String> = [
        "cd", "ls", "mkdir", "rm", "cp", "mv", "git", "npm", "npx", "yarn", "pnpm",
        "python", "python3", "pip", "pip3", "brew", "sudo", "curl", "wget", "ssh",
        "scp", "docker", "kubectl", "make", "cargo", "go", "swift", "xcodebuild",
        "chmod", "chown", "grep", "awk", "sed", "export", "source", "open"
    ]

    nonisolated static func looksLikeCommandOrPath(_ normalized: String) -> Bool {
        let head = normalized
            .components(separatedBy: .whitespacesAndNewlines)
            .first(where: { !$0.isEmpty }) ?? ""
        if commandHeads.contains(head) { return true }
        if normalized.hasPrefix("/") || normalized.hasPrefix("~/") || normalized.hasPrefix("./") { return true }
        return false
    }

    nonisolated static func appAffinityBoost(item: ClipboardItem, bundleID: String?) -> Float {
        guard let bundleID, !bundleID.isEmpty else { return 0 }
        // Symmetric on purpose. The two tiers used to be 0.18 / 0.10, which
        // quietly decided that content copied FROM this app matters more
        // than content the user has deliberately PASTED INTO it. For
        // completion that is backwards as often as not: a command pasted
        // into a note is exactly what belongs in the sentence being written,
        // while prose that merely originated in this app is usually just
        // more prose. Observed live — a real shell command scored 0.10 and
        // lost to two unrelated Notes items at 0.18.
        if item.sourceBundleID == bundleID { return 0.15 }
        if item.pastedToAppNames[bundleID] != nil { return 0.15 }
        return 0
    }

    nonisolated static func recencyBoost(item: ClipboardItem, now: Date) -> Float {
        let ageHours = Float(now.timeIntervalSince(item.timestamp) / 3600)
        let twoWeeks: Float = 24 * 14
        return max(0, 0.08 * (1 - min(ageHours / twoWeeks, 1)))
    }

    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot:  Float = 0
        var sqA:  Float = 0
        var sqB:  Float = 0
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                vDSP_dotpr(ap.baseAddress!, 1, bp.baseAddress!, 1, &dot, n)
                vDSP_svesq(ap.baseAddress!, 1, &sqA, n)
                vDSP_svesq(bp.baseAddress!, 1, &sqB, n)
            }
        }
        guard sqA > 0, sqB > 0 else { return 0 }
        return dot / (sqrt(sqA) * sqrt(sqB))
    }

    func semanticBestMatch(forBundleID bundleID: String, in panels: [QuickClipPanel],
                           tabTexts: [String]) -> (panel: QuickClipPanel, pageID: UUID)? {
        guard ClipenEmbedder.shared.isAvailable else { return nil }
        guard !tabTexts.isEmpty else { return nil }
        let tabVectors: [[Float]] = tabTexts.compactMap { text in
            ClipenEmbedder.shared.vector(for: text)
        }
        guard !tabVectors.isEmpty else { return nil }

        let historyBoost: Float = 0.03

        var best: (panel: QuickClipPanel, pageID: UUID, score: Float)?
        for panel in panels {
            for page in panel.carousel.pages {
                var pageScore: Float = 0
                for tabVec in tabVectors {
                    pageScore = max(pageScore, Self.semanticComponent(queryVec: tabVec, itemVec: page.embedding))
                }
                guard pageScore > 0 else { continue }
                if page.sourceBundleID == bundleID || (page.pasteCountByApp[bundleID] ?? 0) > 0 {
                    pageScore += historyBoost
                }
                if best == nil || pageScore > best!.score {
                    best = (panel, page.id, pageScore)
                }
            }
        }
        return best.map { ($0.panel, $0.pageID) }
    }

    func similarItems(to item: ClipboardItem, count: Int = 7) -> [ClipboardItem] {
        let queryText = Self.similarSearchText(for: item)
        guard !queryText.isEmpty, queryText.count >= 2 else { return [] }
        let results = hybridSearch(query: queryText)
        return Array(results.filter { $0.id != item.id }.prefix(count))
    }

    static func similarSearchText(for item: ClipboardItem) -> String {
        if let text = item.content.plainText,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        if let ocr = item.ocrText,
           !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(ocr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        if let note = item.userNote,
           !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        }
        return ""
    }

    // MARK: - Natural language intent parsing

    /// Shared by `parseSearchIntent` (whole-query category filter) and
    /// `lexicalScore`'s tag boost (single-token match against an item's
    /// actual tags) — one table, two different match granularities.
    static let tagSynonyms: [(Set<String>, ClipboardTag)] = [
        (["url", "urls", "link", "links", "websites", "website"], .url),
        (["image", "images", "picture", "pictures", "photo", "photos", "screenshot", "screenshots"], .image),
        (["gif", "gifs", "animated"], .gif),
        (["pdf", "pdfs"], .pdf),
        (["svg", "svgs", "vector", "vectors"], .svg),
        (["file", "files"], .file),
        (["video", "videos", "movie", "movies", "clip", "clips"], .video),
        (["audio", "audios", "sound", "sounds", "music"], .audio),
        (["code", "codes", "snippet", "snippets", "programming"], .code),
        (["json"], .json),
        (["markdown", "md"], .markdown),
        (["latex", "tex", "math", "equation", "equations"], .latex),
        (["table", "tables", "spreadsheet", "spreadsheets", "csv"], .table),
        (["email", "emails", "mail", "mails", "e-mail", "e-mails"], .email),
        (["phone", "phones", "number", "numbers", "telephone"], .phone),
        (["address", "addresses", "location", "locations"], .address),
        (["color", "colors", "colour", "colours", "hex"], .color),
        (["text", "texts", "plain text"], .text),
        (["html"], .html),
        (["rich", "rich text", "formatted", "richtext"], .richText),
        (["document", "documents", "doc", "docs", "word"], .document),
        (["archive", "archives", "zip", "zips", "compressed"], .archive),
        (["design", "designs", "sketch", "figma"], .design),
        (["font", "fonts", "typeface", "typefaces"], .font),
        (["installer", "installers", "dmg", "pkg"], .installer),
        (["3d", "model", "models", "3d model", "3d models"], .model3D),
        (["group", "groups", "grouped"], .group),
    ]

    /// token -> tag lookup for `lexicalScore`'s boost, flattened once from
    /// `tagSynonyms` rather than rebuilt/rescanned per query.
    static let tagSynonymLookup: [String: ClipboardTag] = {
        var map: [String: ClipboardTag] = [:]
        for (words, tag) in tagSynonyms {
            for w in words { map[w] = tag }
        }
        return map
    }()

    static func parseSearchIntent(_ query: String) -> ClipboardTag? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }

        let stripped = q.replacingOccurrences(
            of: #"^(show\s+(me\s+)?(all\s+(the\s+|my\s+)?)?|find\s+(all\s+)?(my\s+)?|get\s+(all\s+)?(my\s+)?|list\s+(all\s+)?(my\s+)?|all\s+(the\s+|my\s+)?|what\s+are\s+(all\s+)?(the\s+|my\s+)?)"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !stripped.isEmpty else { return nil }

        for (keywords, tag) in tagSynonyms {
            if keywords.contains(stripped) { return tag }
        }

        return nil
    }
}

final class ClipenEmbedder {
    static let shared = ClipenEmbedder()

    private let fallback: NLEmbedding?
    private let contextual: Any?
    let usingContextual: Bool

    var isAvailable: Bool { usingContextual || fallback != nil }

    var dimension: Int {
        if #available(macOS 14.0, *), let model = contextual as? NLContextualEmbedding {
            return model.dimension
        }
        return fallback?.dimension ?? 0
    }

    private init() {
        fallback = NLEmbedding.sentenceEmbedding(for: .english)

        var box: Any? = nil
        var usingCtx = false
        if #available(macOS 14.0, *) {

            if let model = NLContextualEmbedding(script: .latin),
               (try? model.load()) != nil {
                box = model
                usingCtx = true
            } else if #available(macOS 14.0, *) {

                NLContextualEmbedding(script: .latin)?.requestAssets { _, _ in }
            }
        }
        contextual = box
        usingContextual = usingCtx
    }

    func vector(for text: String) -> [Float]? {
        if #available(macOS 14.0, *), let model = contextual as? NLContextualEmbedding {
            // NLContextualEmbedding's tokenizer has been observed to raise a
            // bare NSException from deep inside CoreNLP for certain input
            // text (a framework bug, not something callers can predict or
            // sanitize for in advance) instead of surfacing it through its
            // own `throws` API — Swift's try? only catches NSError-bridged
            // failures, so a raw exception like that crashes the whole app
            // unless caught at the Objective-C level first. See
            // ClipenExceptionCatcher.
            var vector: [Float]? = nil
            let completedSafely = ClipenCatchingExceptions {
                vector = Self.computeContextualVector(model: model, text: text)
            }
            return completedSafely ? vector : nil
        }
        return fallback?.vector(for: text)?.map { Float($0) }
    }

    private static func computeContextualVector(model: NLContextualEmbedding, text: String) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: nil) else { return nil }
        let dim = model.dimension
        guard dim > 0 else { return nil }
        var sum = [Double](repeating: 0, count: dim)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vec, _ in
            if vec.count == dim {
                for i in 0..<dim { sum[i] += vec[i] }
                count += 1
            }
            return true
        }
        guard count > 0 else { return nil }
        let inv = 1.0 / Double(count)
        return sum.map { Float($0 * inv) }
    }
}
