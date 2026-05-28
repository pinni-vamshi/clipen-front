import Foundation
import Accelerate

/// Everything the predictor knows about the *moment of prediction* that is
/// NOT carried on the individual clipboard items.  Built fresh each time the
/// user opens the popup so the ranking reflects "what is true right now":
/// which app is frontmost, what time it is, and what the user has been
/// copying lately.
struct PredictionContext {
    /// The app the popup will paste into — the frontmost app when ⌘V fired.
    let targetAppName:  String?
    let targetBundleID: String?
    /// Wall-clock now.  Drives recency decay + time-of-day matching.
    let now: Date
    /// 0–23 hour of `now`, cached so we don't recompute per item.
    let calendarHour: Int
    /// 1–7 weekday of `now` (Sunday = 1), Calendar's convention.
    let weekday: Int
    /// Embeddings of the most-recently-copied N items (newest first).  Used
    /// to build a "what is the user thinking about right now" centroid —
    /// items semantically close to the recent copy stream score higher.
    let recentEmbeddings: [[Float]]

    init(targetAppName: String?,
         targetBundleID: String?,
         now: Date = Date(),
         recentEmbeddings: [[Float]] = []) {
        self.targetAppName  = targetAppName
        self.targetBundleID = targetBundleID
        self.now            = now
        let cal = Calendar.current
        self.calendarHour   = cal.component(.hour,    from: now)
        self.weekday        = cal.component(.weekday, from: now)
        self.recentEmbeddings = recentEmbeddings
    }
}

/// A scored candidate — the item plus the breakdown of *why* it scored the
/// way it did.  The breakdown is kept (not just the total) so the UI can,
/// later, surface a "because you usually paste this into Xcode" reason, and
/// so the scoring is debuggable.
struct PredictionResult {
    let item: ClipboardItem
    let total: Double
    let breakdown: [String: Double]
}

/// Standalone, dependency-light ranking engine.  Pure function of (items,
/// context): give it the ring and the moment, get back the ordered guesses.
/// Nothing here mutates state or touches the pasteboard — that keeps it
/// trivially testable and lets `ClipboardManager` call it on every popup
/// open without side effects.
///
/// ## The "loop of thinking"
///
/// The engine runs in two passes over the items:
///
/// **Pass 1 — observe.** Walk every item once and accumulate the *global*
/// facts a single item can't know on its own:
///   • `maxPasteCount` — so raw frequency can be normalised 0…1.
///   • `recentCentroid` — the mean embedding of the user's recent copies
///     (from the context), i.e. the current "train of thought".
///   • `appCentroid` — the mean embedding of every item that has previously
///     been pasted into the *target* app, i.e. "what kind of thing tends to
///     land here".
///
/// **Pass 2 — judge.** Walk every item again and, for each, run an ordered
/// chain of scoring stages.  Every stage returns a 0…1 sub-score; the stages
/// are combined with fixed weights into a single total.  The stages, in
/// descending influence:
///
///   1. App affinity      — has this exact item gone into the target app
///                          before? (the single strongest signal)
///   2. Semantic fit      — cosine of the item's embedding against the
///                          target app's centroid AND the recent-copy
///                          centroid (max of the two).
///   3. Paste recency     — how long since this item was last pasted.
///   4. Copy recency      — how long since this item entered the ring.
///   5. Global frequency  — total paste count, normalised.
///   6. Time-of-day       — was this item historically pasted near this hour?
///   7. Pinned bonus      — a tiny nudge for explicitly pinned items.
///
/// Then sort by total descending and return the top `limit`.
final class PastePredictor {

    // MARK: Stage weights (sum ≈ 1.0)
    //
    // Tuned by intuition, not data — these are the knobs to turn once real
    // usage telemetry exists.  Kept as named constants so the intent is
    // legible and a future "learned weights" path can swap them out.
    private struct Weights {
        static let appAffinity   = 0.34
        static let semantic      = 0.22
        static let pasteRecency  = 0.16
        static let copyRecency   = 0.12
        static let frequency     = 0.10
        static let timeOfDay     = 0.04
        static let pinned        = 0.02
    }

    /// Recency half-lives.  An item pasted `pasteHalfLife` seconds ago scores
    /// 0.5 on the paste-recency stage; older decays exponentially toward 0.
    private let pasteHalfLife: TimeInterval = 60 * 30      // 30 min
    private let copyHalfLife:  TimeInterval = 60 * 60 * 4  // 4 hours

    /// Main entry point.  Returns the top-`limit` items the user is most
    /// likely to want to paste right now, best-first.
    func predict(from items: [ClipboardItem],
                 context: PredictionContext,
                 limit: Int = 5) -> [ClipboardItem] {
        scored(from: items, context: context)
            .prefix(limit)
            .map { $0.item }
    }

    /// Same as `predict` but exposes the full scored list with breakdowns —
    /// useful for debugging / future "why" UI / unit tests.
    func scored(from items: [ClipboardItem],
                context: PredictionContext) -> [PredictionResult] {
        guard !items.isEmpty else { return [] }

        // ── PASS 1 — observe global facts ───────────────────────────────
        let stats = gatherStats(items: items, context: context)

        // ── PASS 2 — judge each item ────────────────────────────────────
        var results: [PredictionResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let breakdown = score(item: item, context: context, stats: stats)
            let total = breakdown.values.reduce(0, +)
            results.append(PredictionResult(item: item, total: total, breakdown: breakdown))
        }

        // Best first.  Stable tiebreak on recency so equal scores still feel
        // sensible (newest wins) rather than arbitrary.
        return results.sorted {
            if $0.total != $1.total { return $0.total > $1.total }
            return $0.item.timestamp > $1.item.timestamp
        }
    }

    // MARK: - Pass 1

    private struct Stats {
        var maxPasteCount: Int = 0
        var recentCentroid: [Float]? = nil
        var appCentroid:    [Float]? = nil
    }

    private func gatherStats(items: [ClipboardItem], context: PredictionContext) -> Stats {
        var stats = Stats()

        // Max paste count for frequency normalisation.
        for item in items {
            if item.pasteCount > stats.maxPasteCount { stats.maxPasteCount = item.pasteCount }
        }

        // "Train of thought" centroid — mean of the recent copy embeddings.
        stats.recentCentroid = mean(of: context.recentEmbeddings)

        // Target-app centroid — mean embedding of items previously pasted
        // into the frontmost app.  Only meaningful when we know the target.
        if let bid = context.targetBundleID {
            let appEmbeddings = items.compactMap { item -> [Float]? in
                guard (item.pasteCountByApp[bid] ?? 0) > 0 else { return nil }
                return item.embedding
            }
            stats.appCentroid = mean(of: appEmbeddings)
        }

        return stats
    }

    // MARK: - Pass 2

    private func score(item: ClipboardItem,
                       context: PredictionContext,
                       stats: Stats) -> [String: Double] {
        var b: [String: Double] = [:]

        // 1. App affinity — fraction of this item's pastes that went into the
        //    target app, blended with whether it has *ever* gone there.
        b["appAffinity"] = appAffinity(item, context) * Weights.appAffinity

        // 2. Semantic fit — best cosine against the two centroids.
        b["semantic"] = semantic(item, stats) * Weights.semantic

        // 3. Paste recency — exponential decay on lastPastedAt.
        b["pasteRecency"] = recency(item.lastPastedAt, half: pasteHalfLife, now: context.now)
            * Weights.pasteRecency

        // 4. Copy recency — exponential decay on the capture timestamp.
        b["copyRecency"] = recency(item.timestamp, half: copyHalfLife, now: context.now)
            * Weights.copyRecency

        // 5. Global frequency — normalised paste count.
        let freq = stats.maxPasteCount > 0
            ? Double(item.pasteCount) / Double(stats.maxPasteCount) : 0
        b["frequency"] = freq * Weights.frequency

        // 6. Time-of-day — was the last paste near this hour of day?
        b["timeOfDay"] = timeOfDay(item, context) * Weights.timeOfDay

        // 7. Pinned nudge.
        b["pinned"] = (item.isPinned ? 1.0 : 0.0) * Weights.pinned

        return b
    }

    private func appAffinity(_ item: ClipboardItem, _ context: PredictionContext) -> Double {
        guard let bid = context.targetBundleID,
              item.pasteCount > 0 else { return 0 }
        let here = Double(item.pasteCountByApp[bid] ?? 0)
        guard here > 0 else { return 0 }
        // Fraction of all pastes that landed in this app (0…1), softened by a
        // floor so a single confident paste still counts strongly.
        let fraction = here / Double(item.pasteCount)
        return min(1.0, 0.5 + 0.5 * fraction)
    }

    private func semantic(_ item: ClipboardItem, _ stats: Stats) -> Double {
        guard let emb = item.embedding else { return 0 }
        var best: Double = 0
        if let c = stats.appCentroid    { best = max(best, Double(cosine(emb, c))) }
        if let c = stats.recentCentroid { best = max(best, Double(cosine(emb, c))) }
        // Cosine is −1…1; clamp negatives to 0 so "unrelated" ≠ "penalised".
        return max(0, best)
    }

    private func recency(_ date: Date?, half: TimeInterval, now: Date) -> Double {
        guard let date else { return 0 }
        let age = max(0, now.timeIntervalSince(date))
        // 2^(-age / halfLife): 1.0 at age 0, 0.5 at one half-life, → 0.
        return pow(2.0, -age / half)
    }

    private func timeOfDay(_ item: ClipboardItem, _ context: PredictionContext) -> Double {
        guard let last = item.lastPastedAt else { return 0 }
        let lastHour = Calendar.current.component(.hour, from: last)
        // Circular hour distance 0…12, mapped to 1…0 over a 6-hour window.
        var diff = abs(lastHour - context.calendarHour)
        if diff > 12 { diff = 24 - diff }
        return max(0, 1.0 - Double(diff) / 6.0)
    }

    // MARK: - Vector helpers

    /// Element-wise mean of equally-sized vectors.  Returns nil for empty.
    private func mean(of vectors: [[Float]]) -> [Float]? {
        guard let first = vectors.first else { return nil }
        let dim = first.count
        var acc = [Float](repeating: 0, count: dim)
        var n: Float = 0
        for v in vectors where v.count == dim {
            vDSP.add(acc, v, result: &acc)
            n += 1
        }
        guard n > 0 else { return nil }
        var scale = 1 / n
        var out = [Float](repeating: 0, count: dim)
        vDSP_vsmul(acc, 1, &scale, &out, 1, vDSP_Length(dim))
        return out
    }

    /// Cosine similarity between two equally-sized vectors via Accelerate.
    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0; vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var na: Float = 0; vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        var nb: Float = 0; vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }
}
