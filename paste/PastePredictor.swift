import Foundation
import Accelerate

/// Everything the predictor knows about the *moment of prediction* that is
/// NOT carried on the individual clipboard items.  Built fresh each time the
/// user opens the popup so the ranking reflects "what is true right now".
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
    /// Embeddings of the most-recently-copied N items (newest first).
    let recentEmbeddings: [[Float]]

    // ── Field-level context (from AX) ──────────────────────────────────────
    /// Placeholder text of the focused input, e.g. "Enter email address" or
    /// "Search…".  nil when no text field is focused or AX is unavailable.
    let fieldPlaceholder: String?
    /// Accessibility label / description of the focused field, e.g. "Phone".
    let fieldLabel: String?
    /// Title of the active window, e.g. "invoice.xlsx", "index.swift",
    /// "New Message — Mail".  nil when unavailable.
    let windowTitle: String?
    /// Embedding of a natural-language description of the paste destination
    /// (app name + window title + placeholder + label).  The predictor scores
    /// each item by cosine against this — an always-present per-app signal
    /// that makes the ranking change between apps even at cold start.
    let contextEmbedding: [Float]?

    /// Combined lower-cased signal text from all three field-context fields,
    /// used by the scorer so it doesn't repeat the concat work per item.
    var fieldSignal: String {
        [fieldPlaceholder, fieldLabel, windowTitle]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    init(targetAppName:    String?,
         targetBundleID:   String?,
         now:              Date       = Date(),
         recentEmbeddings: [[Float]]  = [],
         fieldPlaceholder: String?    = nil,
         fieldLabel:       String?    = nil,
         windowTitle:      String?    = nil,
         contextEmbedding: [Float]?   = nil) {
        self.targetAppName    = targetAppName
        self.targetBundleID   = targetBundleID
        self.now              = now
        let cal = Calendar.current
        self.calendarHour     = cal.component(.hour,    from: now)
        self.weekday          = cal.component(.weekday, from: now)
        self.recentEmbeddings = recentEmbeddings
        self.fieldPlaceholder = fieldPlaceholder
        self.fieldLabel       = fieldLabel
        self.windowTitle      = windowTitle
        self.contextEmbedding = contextEmbedding
    }
}

/// A scored candidate — the item plus the breakdown of *why* it scored the
/// way it did.  The breakdown is kept so the UI can, later, surface a reason
/// string ("because you usually paste this into Xcode"), and so the scoring
/// is debuggable.
struct PredictionResult {
    let item: ClipboardItem
    let total: Double
    let breakdown: [String: Double]
}

/// Standalone, dependency-light ranking engine.  Pure function of
/// (items, context): give it the ring and the moment, get back the guesses.
/// Nothing here mutates state or touches the pasteboard — that keeps it
/// trivially testable.
///
/// ## The "loop of thinking"  (2 passes)
///
/// **Pass 1 — observe.**  Walk every item once and collect global facts:
///   • `maxPasteCount`    — for frequency normalisation.
///   • `recentCentroid`   — mean embedding of the user's last-N copies
///                          (current "train of thought").
///   • `appCentroid`      — mean embedding of items previously pasted into
///                          the frontmost app ("what lives here").
///   • `fieldTagHints`    — ClipboardTags implied by the focused field's
///                          placeholder / label / window title.
///
/// **Pass 2 — judge.**  Score every item through these weighted stages:
///
///   0. Context match  (0.30) — cosine of the item vs. an embedding of the
///                              paste destination ("Notes", "Cursor main.py",
///                              "ChatGPT Message…").  ALWAYS present, so it's
///                              what makes the ranking differ between apps
///                              before any paste history exists.
///   1. App affinity   (0.22) — has this item gone into the current app before?
///   2. Field context  (0.12) — does the item type match what the field wants?
///                              e.g. placeholder "Email" → boost email items.
///   3. Semantic fit   (0.12) — cosine vs. app centroid & recent-copy centroid.
///   4. Paste recency  (0.11) — how recently was this item last pasted?
///   5. Copy recency   (0.07) — how recently was this item copied?
///   6. Frequency      (0.04) — total paste count, normalised.
///   7. Time-of-day    (0.015)— pasted near this hour of day before?
///   8. Pinned         (0.005)— small nudge for explicitly pinned items.
///
/// Sort descending, return top N.
final class PastePredictor {

    // MARK: Stage weights (sum = 1.0)
    //
    // `contextMatch` (semantic app/field query) and `appAffinity` (learned
    // paste history) are the two signals that make the ranking differ between
    // apps.  appAffinity is empty at cold start, so contextMatch carries the
    // per-app differentiation until paste history accumulates — hence it gets
    // the largest weight.
    private struct W {
        static let contextMatch = 0.30
        static let appAffinity  = 0.22
        static let fieldContext = 0.12
        static let semantic     = 0.12
        static let pasteRecency = 0.11
        static let copyRecency  = 0.07
        static let frequency    = 0.04
        static let timeOfDay    = 0.015
        static let pinned       = 0.005
    }

    private let pasteHalfLife: TimeInterval = 60 * 30       // 30 min
    private let copyHalfLife:  TimeInterval = 60 * 60 * 4   // 4 hours

    // MARK: Public API

    func predict(from items: [ClipboardItem],
                 context: PredictionContext,
                 limit: Int = 5) -> [ClipboardItem] {
        scored(from: items, context: context)
            .prefix(limit)
            .map { $0.item }
    }

    func scored(from items: [ClipboardItem],
                context: PredictionContext) -> [PredictionResult] {
        guard !items.isEmpty else { return [] }
        let stats = gatherStats(items: items, context: context)
        var results: [PredictionResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let bd = score(item: item, context: context, stats: stats)
            results.append(PredictionResult(item: item,
                                            total: bd.values.reduce(0, +),
                                            breakdown: bd))
        }
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
        /// Tags inferred from the field context (placeholder + label + window title).
        /// Used in the field-context stage so it's computed once, not per item.
        var fieldTagHints: Set<String> = []
        /// Whether the field signal contains any text at all — used to decide
        /// whether to award a partial score for items with no tag match.
        var hasFieldSignal: Bool = false
    }

    private func gatherStats(items: [ClipboardItem], context: PredictionContext) -> Stats {
        var stats = Stats()

        for item in items {
            if item.pasteCount > stats.maxPasteCount { stats.maxPasteCount = item.pasteCount }
        }

        stats.recentCentroid = mean(of: context.recentEmbeddings)

        if let bid = context.targetBundleID {
            let embeds = items.compactMap { item -> [Float]? in
                guard (item.pasteCountByApp[bid] ?? 0) > 0 else { return nil }
                return item.embedding
            }
            stats.appCentroid = mean(of: embeds)
        }

        // ── Field context: map the signal text to likely ClipboardTag names ──
        let sig = context.fieldSignal
        stats.hasFieldSignal = !sig.isEmpty
        if !sig.isEmpty {
            stats.fieldTagHints = inferTagHints(from: sig)
        }

        return stats
    }

    // MARK: - Pass 2

    private func score(item: ClipboardItem,
                       context: PredictionContext,
                       stats: Stats) -> [String: Double] {
        var b: [String: Double] = [:]

        // 0. Context match — cosine of the item vs. the app/field query
        //    embedding.  Always present (app name alone gives a query), so
        //    this is what makes the ranking differ between apps at cold start.
        b["contextMatch"] = contextMatch(item, context) * W.contextMatch

        // 1. App affinity
        b["appAffinity"] = appAffinity(item, context) * W.appAffinity

        // 2. Field context — does the item's type match what the field wants?
        b["fieldContext"] = fieldContext(item, stats) * W.fieldContext

        // 3. Semantic fit
        b["semantic"] = semantic(item, stats) * W.semantic

        // 4. Paste recency
        b["pasteRecency"] = recency(item.lastPastedAt, half: pasteHalfLife, now: context.now)
            * W.pasteRecency

        // 5. Copy recency
        b["copyRecency"] = recency(item.timestamp, half: copyHalfLife, now: context.now)
            * W.copyRecency

        // 6. Frequency
        let freq = stats.maxPasteCount > 0
            ? Double(item.pasteCount) / Double(stats.maxPasteCount) : 0
        b["frequency"] = freq * W.frequency

        // 7. Time-of-day
        b["timeOfDay"] = timeOfDay(item, context) * W.timeOfDay

        // 8. Pinned nudge
        b["pinned"] = (item.isPinned ? 1.0 : 0.0) * W.pinned

        return b
    }

    // MARK: - Stage implementations

    /// Cosine similarity of the item's content embedding against the
    /// app/field query embedding.  Cosine is −1…1; we clamp to 0…1 and apply
    /// a mild curve so only genuinely related items get a meaningful boost.
    private func contextMatch(_ item: ClipboardItem, _ ctx: PredictionContext) -> Double {
        guard let q = ctx.contextEmbedding, let emb = item.embedding else { return 0 }
        let c = Double(cosine(emb, q))
        guard c > 0 else { return 0 }
        // Square it: 0.8→0.64, 0.4→0.16 — sharpens the gap between a strong
        // contextual match and a weak one so the ranking reorders decisively.
        return c * c
    }

    private func appAffinity(_ item: ClipboardItem, _ ctx: PredictionContext) -> Double {
        guard let bid = ctx.targetBundleID, item.pasteCount > 0 else { return 0 }
        let here = Double(item.pasteCountByApp[bid] ?? 0)
        guard here > 0 else { return 0 }
        let fraction = here / Double(item.pasteCount)
        return min(1.0, 0.5 + 0.5 * fraction)
    }

    /// Field-context scoring.
    ///
    /// The AX layer tells us the placeholder/label ("Enter email address",
    /// "Phone number", "Search…") and the window title ("invoice.xlsx",
    /// "index.swift", "New message").  We map these to tag hints and ask:
    /// does the item carry a tag that matches the field's intent?
    ///
    ///   • Strong match (item tag ∈ hints)  → 1.0
    ///   • Partial match (content preview contains a hint keyword) → 0.5
    ///   • No signal at all                 → 0 (stage skipped gracefully)
    private func fieldContext(_ item: ClipboardItem, _ stats: Stats) -> Double {
        guard stats.hasFieldSignal else { return 0 }
        let hints = stats.fieldTagHints
        guard !hints.isEmpty else { return 0 }

        // Check item's detected tags — strong signal.
        let itemTagNames = Set(item.tags.map { $0.rawValue })
        if !itemTagNames.isDisjoint(with: hints) { return 1.0 }

        // Fallback: keyword present in the content preview — partial credit.
        let preview = item.previewText.lowercased()
        for hint in hints {
            if preview.contains(hint) { return 0.5 }
        }
        return 0
    }

    private func semantic(_ item: ClipboardItem, _ stats: Stats) -> Double {
        guard let emb = item.embedding else { return 0 }
        var best: Double = 0
        if let c = stats.appCentroid    { best = max(best, Double(cosine(emb, c))) }
        if let c = stats.recentCentroid { best = max(best, Double(cosine(emb, c))) }
        return max(0, best)
    }

    private func recency(_ date: Date?, half: TimeInterval, now: Date) -> Double {
        guard let date else { return 0 }
        let age = max(0, now.timeIntervalSince(date))
        return pow(2.0, -age / half)
    }

    private func timeOfDay(_ item: ClipboardItem, _ ctx: PredictionContext) -> Double {
        guard let last = item.lastPastedAt else { return 0 }
        let lastHour = Calendar.current.component(.hour, from: last)
        var diff = abs(lastHour - ctx.calendarHour)
        if diff > 12 { diff = 24 - diff }
        return max(0, 1.0 - Double(diff) / 6.0)
    }

    // MARK: - Field → tag hint mapping
    //
    // Maps words from the field signal (placeholder + label + window title)
    // to ClipboardTag raw values.  The tag raw values are the same strings
    // used by `TagDetector` (e.g. "email", "url", "code", "phone", etc.) so
    // the comparison in fieldContext() is a simple Set intersection.

    private static let tagKeywords: [(keywords: [String], tag: String)] = [
        // Contacts / form fields
        (["email", "mail", "e-mail", "@"],                      "email"),
        (["phone", "tel", "mobile", "cell", "fax", "sms"],       "phone"),
        (["address", "street", "city", "zip", "postal", "state", "country"], "address"),

        // Web / network
        (["url", "link", "website", "http", "https", "site",
          "domain", "href"],                                      "url"),

        // Code / programming — also from window title file extensions
        (["code", "snippet", "function", "script",
          ".swift", ".js", ".ts", ".jsx", ".tsx",
          ".py", ".rb", ".go", ".cpp", ".c", ".h",
          ".java", ".kt", ".rs", ".php"],                         "code"),

        // Data formats
        ([".json", "json", "key", "value", "api"],                "json"),
        ([".md", "markdown", "readme"],                           "markdown"),
        (["table", "csv", "row", "column", "spreadsheet"],        "table"),
        (["html", "<html", "markup"],                             "html"),
        (["latex", "tex", "equation", "formula"],                 "latex"),

        // Files
        ([".pdf"],                                                 "pdf"),

        // Colour / design
        (["color", "colour", "hex", "#", "rgb", "hsl"],           "color"),
    ]

    /// Produce a set of ClipboardTag raw values suggested by the signal text.
    private func inferTagHints(from signal: String) -> Set<String> {
        var hints = Set<String>()
        for (keywords, tag) in Self.tagKeywords {
            for kw in keywords {
                if signal.contains(kw) {
                    hints.insert(tag)
                    break
                }
            }
        }
        return hints
    }

    // MARK: - Vector helpers

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

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0; vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var na: Float = 0;  vDSP_svesq(a, 1, &na, vDSP_Length(a.count))
        var nb: Float = 0;  vDSP_svesq(b, 1, &nb, vDSP_Length(b.count))
        let denom = sqrt(na) * sqrt(nb)
        return denom > 0 ? dot / denom : 0
    }
}
