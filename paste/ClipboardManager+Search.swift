import AppKit
import SwiftUI
import NaturalLanguage
import Accelerate
import Vision
@preconcurrency import PDFKit

extension ClipboardManager {

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
                self.saveQueue.async { self.embeddingsDirty = true }
            }
        }
    }

    func cancelPendingFirstOpen() {
        pendingFirstOpenTimer?.invalidate()
        pendingFirstOpenTimer = nil
        pendingFirstOpen = false
    }

    func fastPasteFront() {
        clearPopupHintHighlights()
        cancelPendingFirstOpen()
        guard !displayItems.isEmpty else { return }
        selectedIndex = 0
        inTransformStage = false
        transformIndex = 0
        AuthManager.shared.registerFastPasteAction()
        commitPaste()
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
        guard !displayItems.isEmpty, selectedIndex < displayItems.count else { return }
        let target = displayItems[selectedIndex]
        guard let realIndex = items.firstIndex(where: { $0.id == target.id }) else { return }
        AuthManager.shared.registerActionUsage(actionID: "action.delete")
        items.remove(at: realIndex)
        markBlobPurgeNeeded()
        if displayItems.isEmpty { dismissPreview(); return }
        selectedIndex = min(selectedIndex, displayItems.count - 1)
        syncItemPreviewWithSelection()
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
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    func moveMarkedToFront() {
        let orderedItems = markedItemIDs.compactMap { id in items.first(where: { $0.id == id }) }
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
        syncItemPreviewWithSelection()
        syncTransformPanelWithSelection()
    }

    func clampSelectedIndexToDisplay() {
        let display = displayItems
        guard !display.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex), display.count - 1)
    }

    func dismissPreview() {
        if previewWindow.isVisible {
            if let openedAt = popupOpenedAt {
                let ms = max(0, Int(Date().timeIntervalSince(openedAt) * 1000))
                AuthManager.shared.registerActionUsage(actionID: "popup.dur_ms", count: ms)
            }
            if !popupSessionPasted {
                AuthManager.shared.registerActionUsage(actionID: "popup.abandon")
            }
        }
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
        xTapHoldTimer?.invalidate()
        xTapHoldTimer = nil
        inTransformStage = false
        transformingMarkedSet = false
        transformIndex   = 0
        transformDisplaysCache = []
        lastTransformCacheItemID = nil
        inShareStage = false
        shareServices = []
        shareTargetItems = []
        shareIndex = 0
        sharePanel.hide()
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

    func openQuickClipPanel(for item: ClipboardItem, focusContent: Bool = false) {
        let ownerBundleID = capturedPasteTarget?.bundleIdentifier
            ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
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

    func hybridSearch(query: String) -> [ClipboardItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, q.count >= 2 else { return [] }

        if q == lastSearchQuery
            && items.count == lastSearchItemsRev
            && embeddedItemCount == lastSearchEmbedRev {
            return lastSearchResult
        }

        let qNorm = ClipboardItem.normalize(q)
        let qTokens = Self.queryTokens(qNorm)
        let firstToken = qTokens.first

        var queryVec: [Float]? = nil
        if AuthManager.shared.semanticSearch,
           let emb = nlEmbedding,
           let v = emb.vector(for: qNorm) {
            queryVec = v.map { Float($0) }
        }

        let now = Date()
        var scored: [(ClipboardItem, Float)] = []
        scored.reserveCapacity(items.count)

        if items.count >= 128 {
            var scores = [Float](repeating: 0, count: items.count)
            scores.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: items.count) { i in
                    let item = items[i]
                    let lex = Self.lexicalScore(query: qNorm, tokens: qTokens, firstToken: firstToken, item: item)
                    let sem = Self.semanticComponent(queryVec: queryVec, itemVec: item.embedding)
                    let rec = Self.recencyBoost(item: item, now: now)
                    buf[i] = 0.55 * lex + 0.40 * sem + rec
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

                let combined = 0.55 * lex + 0.40 * sem + rec
                if combined >= 0.15 {
                    scored.append((item, combined))
                }
            }
        }

        let sorted = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        lastSearchQuery = q
        lastSearchResult = sorted
        lastSearchItemsRev = items.count
        lastSearchEmbedRev = embeddedItemCount
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
        return best
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
        guard let nlEmbedding else { return nil }
        guard !tabTexts.isEmpty else { return nil }
        let tabVectors: [[Float]] = tabTexts.compactMap { text in
            nlEmbedding.vector(for: text)?.map(Float.init)
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

    func similarItems(to item: ClipboardItem, count: Int = 7) async -> [ClipboardItem] {
        let candidates = items.filter { $0.id != item.id }
        guard !candidates.isEmpty else { return [] }
        let queryVec = item.embedding
        let queryPrint = ImageSimilarityService.featurePrint(id: item.id) { Self.visualCGImage(for: item) }
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

    private nonisolated static func combinedSimilarItems(queryNorm: String, queryVec: [Float]?,
                                              queryPrint: VNFeaturePrintObservation?,
                                              in candidates: [ClipboardItem], count: Int) -> [ClipboardItem] {
        let qTokens = queryNorm.isEmpty ? [] : queryTokens(queryNorm)
        let firstToken = qTokens.first
        let maxDistance: Float = 1.4
        func visualScore(_ candidate: ClipboardItem) -> Float {
            guard let queryPrint,
                  let candidatePrint = ImageSimilarityService.featurePrint(id: candidate.id, cgImage: { visualCGImage(for: candidate) }),
                  let distance = ImageSimilarityService.distance(queryPrint, candidatePrint),
                  distance <= maxDistance
            else { return 0 }
            return max(0, 1 - distance / maxDistance)
        }

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

enum ImageSimilarityService {
    private static let cache = NSCache<NSUUID, VNFeaturePrintObservation>()

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
