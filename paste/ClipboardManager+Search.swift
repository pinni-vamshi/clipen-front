import AppKit
import SwiftUI
import NaturalLanguage
import Accelerate
import Vision
@preconcurrency import PDFKit

extension ClipboardManager {
    // MARK: - Embedding recomputation

    /// THE single code path for computing item embeddings — initial capture,
    /// post-load backfill (embeddings persist, but a schema bump discards
    /// them — see loadHistory), and post-OCR / post-note-edit refreshes all
    /// funnel here by simply nilling `embedding` and calling this.
    ///
    /// All vectors are computed in the background first, then applied in ONE
    /// main-queue write. The old shape (one main-hop per item) meant every
    /// fill triggered `items`'s didSet + @Published individually — cache
    /// invalidation and a full SwiftUI re-render of every observing view,
    /// 200 times in a row on launch with a full ring.
    func recomputeEmbeddingsInBackground() {
        guard let emb = nlEmbedding else { return }
        let snapshot = items.filter { $0.embedding == nil }
        guard !snapshot.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var computed: [(id: UUID, vector: [Float])] = []
            computed.reserveCapacity(snapshot.count)
            for item in snapshot {
                guard self != nil else { return }
                guard let str = item.richEmbeddingText,
                      let vector = emb.vector(for: str) else { continue }
                computed.append((item.id, vector.map { Float($0) }))
            }
            guard !computed.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Mutate a local copy and assign back ONCE — `items[idx].x =`
                // inside a loop fires didSet/@Published per element, which is
                // the exact per-item re-render storm this batching exists to
                // avoid.
                var byID: [UUID: [Float]] = Dictionary(uniqueKeysWithValues: computed.map { ($0.id, $0.vector) })
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
                // New vectors exist → the embeddings dictionary file must be
                // rewritten on the next save (it's skipped otherwise).
                self.saveQueue.async { self.embeddingsDirty = true }
            }
        }
    }

    func cancelPendingFirstOpen() {
        pendingFirstOpenTimer?.invalidate()
        pendingFirstOpenTimer = nil
        pendingFirstOpen = false
    }

    /// Paste the front item (selectedIndex 0) without ever showing the
    /// popup. Called when the user releases ⌘ inside `firstOpenDelay`.
    /// Visually identical to a system ⌘V for users who weren't trying to
    /// cycle — they just see the paste happen.
    func fastPasteFront() {
        clearPopupHintHighlights()
        cancelPendingFirstOpen()
        guard !displayItems.isEmpty else { return }
        selectedIndex = 0
        inTransformStage = false
        transformIndex = 0
        // Count this as a fast-paste event (released ⌘ before the popup
        // could open).  Persists locally + ships to backend on next refresh,
        // and ALSO runs the standard ⌘V pipeline (refresh-throttle, update
        // check) since this is a real paste action from the user's POV.
        AuthManager.shared.registerFastPasteAction()
        commitPaste()
        // First time only: surface a small educational alert telling the
        // user what just happened and how to invoke the popup on purpose.
        // Fired AFTER commitPaste so the synthetic ⌘V doesn't race with
        // NSAlert.runModal stealing focus from the target app.
        showFastPasteHintIfNeeded()
    }

    /// First time we hit the fast-paste path, surface a one-shot NSAlert
    /// explaining the timing model so the user understands they CAN reach
    /// Clipen's clipboard picker by holding ⌘ a little longer.  Persisted
    /// so it only fires once per install.
    func showFastPasteHintIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fastPasteHintShownKey) else { return }
        UserDefaults.standard.set(true, forKey: fastPasteHintShownKey)
        let delayMs = max(1, Int((firstOpenDelay * 1000).rounded()))
        // Defer so the paste's synthetic ⌘V has already fired into the
        // target app before we steal focus with the alert.
        // Show the branded SwiftUI panel instead of NSAlert.  Deferred so the
        // synthetic ⌘V from commitPaste has already fired into the target app
        // before we steal focus.  The "Adjust delay" button closes the panel,
        // brings the main window forward, and pulses the slider card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self else { return }
            self.fastPasteHintPanel.show(delayMs: delayMs) {
                AppDelegate.shared?.openMainWindow()
                ClipboardManager.shared.pulseOpenDelaySlider()
            }
        }
    }

    func deleteSelected() {
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        // Resolve by ID so popupTagFilter never causes the wrong item to be deleted.
        let target = displayItems[selectedIndex]
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.delete")
        items.remove(at: realIndex)
        markBlobPurgeNeeded()
        // displayItems is synchronously rebuilt by the items.didSet above.
        if displayItems.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)
        syncItemPreviewWithSelection()
    }

    /// Move the highlighted popup item to the front (position 0) of the ring.
    /// Resolves by ID so an active category filter can't move the wrong item;
    /// keeps the highlight on the moved item (now at the top of Recents).
    ///
    /// If the user has built a multi-mark queue (⌘-held-V on several items),
    /// this acts on ALL of them instead — same "act on every marked item"
    /// rule the multi-paste and multi-pin paths already follow.
    func moveSelectedToFront() {
        AuthManager.shared.registerActionUsage(actionID: "action.front")
        if !markedItemIDs.isEmpty {
            moveMarkedToFront()
            return
        }
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let target = displayItems[selectedIndex]
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        guard realIndex != 0 else { selectedIndex = 0; return }
        let moved = items.remove(at: realIndex)
        items.insert(moved, at: 0)
        // displayItems is synchronously rebuilt by items.didSet; the moved item
        // is now first in the unfiltered ring.
        if let newIdx = displayItems.firstIndex(where: { $0.id == target.id }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = 0
        }
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// Move every marked item to the front of the ring, preserving the order
    /// they were marked in (`markedItemIDs` is itself ordered by mark sequence
    /// — the first item marked lands at position 0).
    func moveMarkedToFront() {
        let orderedItems = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
        guard !orderedItems.isEmpty else { return }
        let movedIDs = Set(orderedItems.map(\.id))
        let remaining = items.filter { !movedIDs.contains($0.id) }
        items = orderedItems + remaining
        // displayItems is synchronously rebuilt by items.didSet.
        if let firstID = orderedItems.first?.id,
           let newIdx = displayItems.firstIndex(where: { $0.id == firstID }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = 0
        }
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    /// Clamp `selectedIndex` to `displayItems` after ring mutations.
    func clampSelectedIndexToDisplay() {
        let display = displayItems
        guard !display.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex), display.count - 1)
    }

    func dismissPreview() {
        captureRememberedSelection()
        clearPopupHintHighlights()
        stopAutoDismissTimer()
        previewWindow.hide()
        transformPanel.hide()
        itemPreviewPanel.hide()
        cancelPendingFirstOpen()
        // A V tap/hold decision in flight when the popup closes must not
        // fire later against a stale target (or a ring that's shrunk since).
        vTapHoldTimer?.invalidate()
        vTapHoldTimer = nil
        firstOpenHoldTimer?.invalidate()
        firstOpenHoldTimer = nil
        popupPinnedOpen = false
        xTapHoldTimer?.invalidate()
        xTapHoldTimer = nil
        inTransformStage = false
        transformingMarkedSet = false
        transformIndex   = 0
        // Without this, refreshTransformDisplaysCache()'s "same item →
        // reuse cache" shortcut could reuse a STALE, pre-usage-bump sort
        // order the next time transforms are opened for this same item —
        // universal (tool-ID-keyed) usage ranking updates in AuthManager
        // immediately, but the transform panel wouldn't reflect it until
        // a genuinely different item forced a recompute.
        transformDisplaysCache = []
        lastTransformCacheItemID = nil
        selectedIndex    = 0
        popupTagFilter   = nil
        cycleCount       = 0
        markedItemIDs      = []
        popupSearchQuery   = ""
        isSearchActive     = false
        // Reset page-range state too — no half-typed picker should outlive
        // a dismiss.
        inPageRangeMode = false
        pageRangeQuery = ""
        pageRangeManualPages = []
        pageRangePageCount = 0
        pageRangePDF = nil
        // Same reset for the language picker — no half-typed search query
        // should outlive a dismiss.
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
        // The FIRST tap of the double-tap-Space gesture already toggled the
        // item preview open before the second tap was recognized as a pin —
        // close it, otherwise every pin leaves a stray preview popup behind.
        itemPreviewPanel.hide()
        AuthManager.shared.registerActionUsage(actionID: "action.reference-pin")

        // If the user has built a multi-paste mark queue, pin ALL of them
        // into the reference panel (as separate carousel pages) instead of
        // just the highlighted row — same "act on every marked item" rule
        // ⌘-release's multi-paste already follows, applied to pinning too.
        if !markedItemIDs.isEmpty {
            let orderedItems = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
            guard !orderedItems.isEmpty else { return }
            for item in orderedItems {
                openQuickClipPanel(for: item)
            }
            return
        }

        guard let item = selectedItemForQuickClip() else { return }
        openQuickClipPanel(for: item)
    }

    /// `focusContent` is used by the "Edit" transform tool — instead of
    /// building a second, more fragile text editor inside the non-activating
    /// transform popup (which can't hold real keyboard focus), that tool
    /// just opens this panel with the cursor already in its (real,
    /// fully-focusable) content editor.
    ///
    /// Default behavior: pin references into ONE shared panel, added as a
    /// new page (horizontal carousel) rather than opening a second window —
    /// only "pop out" (openStandaloneQuickClipPanel) creates a genuinely
    /// separate panel.
    func openQuickClipPanel(for item: ClipboardItem, focusContent: Bool = false) {
        let ownerBundleID = capturedPasteTarget?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Captured at pin time (a real user action, not a background poll),
        // so a few tens of ms for an AppleScript round-trip is unnoticeable —
        // this is what lets Smart Reference later match the SPECIFIC tab or
        // window this reference was pinned from, not just "any Safari window."
        let ownerContext = ownerBundleID.flatMap { AppContextService.currentContext(for: $0) }

        if let panel = sharedCarouselPanel {
            panel.addPage(item, focusContent: focusContent, ownerBundleID: ownerBundleID, ownerContext: ownerContext)
            panel.orderFrontRegardless()
            return
        }

        if quickClipPanels.count >= 5 {
            let oldest = quickClipPanels.removeFirst()
            oldest.close()
        }
        let panel = QuickClipPanel(item: item, offset: 0, focusContent: focusContent,
                                   ownerBundleID: ownerBundleID, ownerContext: ownerContext)
        panel.orderFrontRegardless()
        quickClipPanels.append(panel)
        sharedCarouselPanel = panel
    }

    /// Detaches a reference into its OWN standalone panel — used by the
    /// carousel's "pop out" button. Never becomes the shared carousel target
    /// itself, so later pins keep merging into the original shared panel
    /// instead of this detached one.
    func openStandaloneQuickClipPanel(for item: ClipboardItem) {
        if quickClipPanels.count >= 5 {
            let oldest = quickClipPanels.removeFirst()
            oldest.close()
        }
        let offset = CGFloat(quickClipPanels.count * 30)
        let panel = QuickClipPanel(item: item, offset: offset)
        panel.orderFrontRegardless()
        quickClipPanels.append(panel)
    }

    func quickClipPanelDidClose(_ panel: NSPanel) {
        quickClipPanels.removeAll { $0 === panel }
        if sharedCarouselPanel === panel { sharedCarouselPanel = nil }
    }

    // MARK: - Hybrid search (lexical + semantic + recency)

    // Cache key uses (query, items.count, embeddedItemCount).  The embedded
    // count is maintained as a tracked counter — incremented when an embedding
    // is written, reset on full re-load — so the cache check is O(1) instead
    // of an O(N) walk over items on every keystroke.

    /// Production search: blends LEXICAL (exact-phrase + per-token), SEMANTIC
    /// (sentence-embedding cosine), and RECENCY into a single combined score.
    /// Per-keystroke cost is O(N · |tokens|) of string `.contains` checks on
    /// PRE-NORMALISED haystacks already stored on each ClipboardItem — no
    /// filesystem I/O, no per-item allocation.
    func hybridSearch(query: String) -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count >= 2 else { return [] }

        // O(1) cache check — no item walk before the cache hit.
        if q == lastSearchQuery
            && items.count == lastSearchItemsRev
            && embeddedItemCount == lastSearchEmbedRev {
            return lastSearchResult
        }

        let qNorm = ClipboardItem.normalize(q)
        let qTokens = Self.queryTokens(qNorm)
        let firstToken = qTokens.first

        // Query embedding — one ANE round-trip per query, NOT per item.
        var queryVec: [Float]? = nil
        if AuthManager.shared.semanticSearch,
           let emb = nlEmbedding,
           let v = emb.vector(for: qNorm) {
            queryVec = v.map { Float($0) }
        }

        let now = Date()
        var scored: [(ClipboardItem, Float)] = []
        scored.reserveCapacity(items.count)

        for item in items {
            let lex = Self.lexicalScore(query: qNorm, tokens: qTokens, firstToken: firstToken, item: item)
            let sem = Self.semanticComponent(queryVec: queryVec, itemVec: item.embedding)
            let rec = Self.recencyBoost(item: item, now: now)

            let combined = 0.55 * lex + 0.40 * sem + rec
            if combined >= 0.15 {
                scored.append((item, combined))
            }
        }

        let sorted = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        lastSearchQuery = q
        lastSearchResult = sorted
        lastSearchItemsRev = items.count
        lastSearchEmbedRev = embeddedItemCount
        return sorted
    }

    // MARK: Scoring helpers (pure functions — read pre-cached haystacks)
    //
    // These are THE scoring core for every retrieval surface in the app —
    // popup search, main-window search, Similar Items, and Smart Reference's
    // semantic tab matching all compose their ranking from these same
    // functions, so relevance behaves identically everywhere. Add new
    // surfaces by composing these; never fork a private copy of one.

    /// Token extraction shared by every lexical scorer: split on
    /// non-alphanumerics, drop tokens < 2 chars, dedupe PRESERVING INPUT
    /// ORDER. Order matters: the first token drives lexicalScore's
    /// word-boundary bonus, and a plain-Set round-trip here once made that a
    /// hash-seeded random pick that reordered results between launches.
    nonisolated static func queryTokens(_ qNorm: String) -> [String] {
        var seen = Set<String>()
        return qNorm
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && seen.insert($0).inserted }
    }

    /// LEXICAL score in [0, 1]. Reads PRE-NORMALISED haystacks off the item
    /// (no allocation, no I/O).  Three weighted fields:
    ///   • searchPreviewNorm  — what the row shows (weight 1.00)
    ///   • searchEmbedNorm    — full searchable text (weight 0.70)
    ///   • searchMetaNorm     — type / size / dims (weight 0.55)
    /// We take MAX across fields (not sum) so a match isn't triple-counted.
    nonisolated static func lexicalScore(query: String,
                                     tokens: [String],
                                     firstToken: String?,
                                     item: ClipboardItem) -> Float {
        // Inline tuple iteration to avoid Array allocation per call.
        var best: Float = 0
        best = max(best, score(text: item.searchPreviewNorm, query: query, tokens: tokens, firstToken: firstToken) * 1.00)
        best = max(best, score(text: item.searchEmbedNorm,   query: query, tokens: tokens, firstToken: firstToken) * 0.70)
        best = max(best, score(text: item.searchMetaNorm,    query: query, tokens: tokens, firstToken: firstToken) * 0.55)
        return best
    }

    @inline(__always)
    nonisolated static func score(text: String, query: String, tokens: [String], firstToken: String?) -> Float {
        guard !text.isEmpty else { return 0 }
        // Tier 1: exact phrase
        if !query.isEmpty && text.contains(query) { return 1.0 }
        guard !tokens.isEmpty else { return 0 }
        // Tier 2: token-coverage fraction
        var hits = 0
        for t in tokens where text.contains(t) { hits += 1 }
        var s = Float(hits) / Float(tokens.count)
        // Tier 2b: word-boundary bonus
        if s > 0, let first = firstToken,
           text.hasPrefix(first) || text.contains(" " + first) {
            s = min(1.0, s + 0.15)
        }
        return s
    }

    /// SEMANTIC score in [0, 1]. Cosine similarity normalised so 0.3 → 0
    /// and 0.8 → 1.0 (below 0.3 is noise; above 0.8 is essentially identical
    /// meaning). Returns 0 when either side has no embedding.
    nonisolated static func semanticComponent(queryVec: [Float]?, itemVec: [Float]?) -> Float {
        guard let qv = queryVec, let iv = itemVec else { return 0 }
        let cos = cosineSimilarity(qv, iv)
        return max(0, min(1, (cos - 0.3) / 0.5))
    }

    /// RECENCY boost in [0, 0.08]. Linear decay over 14 days. Small enough
    /// that it only tiebreaks — never elevates an irrelevant item to the top.
    nonisolated static func recencyBoost(item: ClipboardItem, now: Date) -> Float {
        let ageHours = Float(now.timeIntervalSince(item.timestamp) / 3600)
        let twoWeeks: Float = 24 * 14
        return max(0, 0.08 * (1 - min(ageHours / twoWeeks, 1)))
    }

    /// `nonisolated static` on purpose: this is pure math over value types,
    /// and Similar Items ranks on a background queue — an instance method
    /// would be MainActor-isolated and uncallable from there, which is
    /// exactly how a second private copy of this function once crept in.
    nonisolated static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        // Accelerate (vDSP) routes to SIMD/AMX on Apple Silicon. ~5–10×
        // faster than the previous zip-map-reduce chain and zero
        // intermediate allocations — important because this runs per
        // (item × keystroke) during semantic search.
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

    // MARK: - Smart Reference semantic fallback

    /// Best-effort semantic match between EVERY open tab's title/URL (for
    /// `bundleID`, across every window, not just the active tab) and every
    /// pinned reference page's own content embedding — lets Smart Reference
    /// auto-surface a page even when neither the bundle ID nor an exact tab/
    /// window context was ever linked, as long as some open tab reads as
    /// topically similar to what's pinned. On-device only (NLEmbedding), no
    /// network calls — matches the title/URL-only scope, not full page text.
    ///
    /// A small paste-history boost breaks ties: if the candidate page's
    /// underlying item was ever copied FROM or pasted TO this same app
    /// before, that's a real signal it belongs here even when two pages
    /// score nearly identically on text alone.
    func semanticBestMatch(forBundleID bundleID: String, in panels: [QuickClipPanel]) -> (panel: QuickClipPanel, pageID: UUID)? {
        guard let nlEmbedding else { return nil }
        let tabTexts = AppContextService.allTabTexts(for: bundleID)
        guard !tabTexts.isEmpty else { return nil }
        let tabVectors: [[Float]] = tabTexts.compactMap { text in
            nlEmbedding.vector(for: text)?.map(Float.init)
        }
        guard !tabVectors.isEmpty else { return nil }

        // Scored via the shared semanticComponent (same normalisation and
        // noise floor as every other retrieval surface): 0 = unrelated
        // (raw cosine ≤ 0.3), so `> 0` is the match test.
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

    // MARK: - Similar items

    /// Returns up to `count` items most similar to `item`, regardless of
    /// content type — a photo can land next to a topically-similar note, a
    /// PDF next to a table, a file next to an image, etc. No longer splits
    /// into a text-only pool vs an image-only pool: EVERY item gets a
    /// semantic score (content embeddings exist for every type — images and
    /// files embed their metadata description, not just raw text, see
    /// ClipboardItem.textForEmbedding), boosted by real Vision visual
    /// similarity when BOTH sides happen to be visual (image/PDF), since
    /// that's a much stronger signal than metadata text for "these two
    /// photos look alike." One combined ranked list, top `count` overall.
    func similarItems(to item: ClipboardItem, count: Int = 7) async -> [ClipboardItem] {
        let candidates = items.filter { $0.id != item.id }
        guard !candidates.isEmpty else { return [] }
        let queryVec = item.embedding
        let queryPrint = ImageSimilarityService.featurePrint(id: item.id) { Self.visualCGImage(for: item) }
        // Lexical query: the item's own text — real content for text items,
        // OCR'd text for images/PDFs. This channel is what catches "the
        // word is literally right there": a pinned note reading 'Durham'
        // matches a rankings-table screenshot whose OCR contains 'Durham
        // University' even though the screenshot's embedding is dominated
        // by table numbers and barely resembles the query semantically.
        // Same 120-char cap the pre-unification text path used — enough to
        // fingerprint the topic without a wall of text flooding the tokens.
        let lexicalSource = (item.content.plainText ?? item.ocrText)?
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        let lexNorm = lexicalSource.map { ClipboardItem.normalize(String($0)) } ?? ""

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.combinedSimilarItems(
                    queryNorm: lexNorm, queryVec: queryVec, queryPrint: queryPrint,
                    in: candidates, count: count))
            }
        }
    }

    /// Runs entirely off the main actor — pure computation over Sendable
    /// value-type inputs (a snapshot of `items`, plain arrays/CGImage-free
    /// data) taken before the hop, so it never touches @Published state or
    /// any MainActor-isolated method from a background thread.
    private nonisolated static func combinedSimilarItems(queryNorm: String, queryVec: [Float]?,
                                              queryPrint: VNFeaturePrintObservation?,
                                              in candidates: [ClipboardItem], count: Int) -> [ClipboardItem] {
        let qTokens = queryNorm.isEmpty ? [] : queryTokens(queryNorm)
        let firstToken = qTokens.first
        // Apple's own guidance puts near-identical images under ~0.5
        // distance and unrelated images well above 1.5-2 — map that onto the
        // same [0, 1] scale semanticComponent uses so the two are directly
        // comparable when picking the max of the two per candidate.
        let maxDistance: Float = 1.4
        func visualScore(_ candidate: ClipboardItem) -> Float {
            guard let queryPrint,
                  let candidatePrint = ImageSimilarityService.featurePrint(id: candidate.id, cgImage: { visualCGImage(for: candidate) }),
                  let distance = ImageSimilarityService.distance(queryPrint, candidatePrint),
                  distance <= maxDistance
            else { return 0 }
            return max(0, 1 - distance / maxDistance)
        }

        // Scoring composes the SAME shared core hybridSearch uses
        // (semanticComponent + recencyBoost) plus the visual channel that
        // only exists here — so "similar" ranks by the same notion of
        // relevance as typing in either search field, with recency as the
        // identical small tiebreak.
        //
        // No relevance floor here on purpose — a floor silently re-imposes a
        // type restriction in practice: visual scoring works for images
        // independent of embeddings (Vision runs live on the CGImage), but
        // cross-type scoring only works when BOTH sides already have an
        // .embedding. Any candidate without one (recompute still pending,
        // or genuinely nothing in common) scored exactly 0 and got dropped
        // by a floor — which meant "top 7 regardless of type" quietly
        // degraded back into "images only" whenever non-image items hadn't
        // been embedded yet. Always rank the WHOLE pool and take the top
        // `count`, full stop.
        // Text channel uses hybridSearch's EXACT weights (0.55 lex +
        // 0.40 sem) so "similar to this item" ranks text relevance the same
        // way typing that item's words into search would. The visual channel
        // competes via max() — for two screenshots of the same page, Vision
        // distance is a far stronger signal than either text tier and
        // shouldn't be diluted by averaging with them.
        let now = Date()
        return candidates
            .map { candidate in
                let lex = lexicalScore(query: queryNorm, tokens: qTokens, firstToken: firstToken, item: candidate)
                let sem = semanticComponent(queryVec: queryVec, itemVec: candidate.embedding)
                return (candidate,
                        max(0.55 * lex + 0.40 * sem, visualScore(candidate))
                        + recencyBoost(item: candidate, now: now))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(count)
            .map(\.0)
    }

    /// A CGImage to compare, for either a real image item or a PDF (rendered
    /// from its first page) — visual similarity doesn't care which one the
    /// content originally was, so both funnel into the same comparison pool.
    private static func visualCGImage(for item: ClipboardItem) -> CGImage? {
        if case .image(let img, _, _) = item.content {
            return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        if let input = PDFTools.pdfInput(for: item), let page = input.pdf.page(at: 0) {
            return PDFService.renderCGImage(page: page, scale: 1.0)
        }
        return nil
    }
}

/// Real visual similarity via Vision's feature-print request — on-device,
/// no network, works for both images and PDFs (rendered to an image first).
/// Feature prints are cached per item ID since extraction costs tens of ms
/// and the ring doesn't change between opening "Similar" twice for the
/// same item. NSCache (not a plain dictionary) because this runs off the
/// main actor and needs to be safe under concurrent access.
enum ImageSimilarityService {
    private static let cache = NSCache<NSUUID, VNFeaturePrintObservation>()

    /// `cgImage` is a CLOSURE, not a value, deliberately: producing the
    /// image can itself be expensive (a PDF item renders its first page
    /// every time), and the whole point of the cache is to skip that work
    /// on repeat visits. Taking an eager CGImage forced every caller to pay
    /// the render cost up front just to check a cache that would then
    /// discard it — for a 7-item Similar rank over a ring full of PDFs,
    /// that's dozens of page renders per open, all thrown away.
    static func featurePrint(id: UUID, cgImage: () -> CGImage?) -> VNFeaturePrintObservation? {
        let key = id as NSUUID
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = cgImage() else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
            cache.setObject(observation, forKey: key)
            return observation
        } catch {
            return nil
        }
    }

    /// Lower = more similar. Roughly 0 (near-identical) up past 2 (unrelated),
    /// per Apple's own guidance for this API.
    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var distance: Float = 0
        do {
            try a.computeDistance(&distance, to: b)
            return distance
        } catch {
            return nil
        }
    }
}
