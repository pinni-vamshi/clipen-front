import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit


struct ExtractedLink: Identifiable {
    let id = UUID()
    let label: String
    let url: URL
}

enum LinkExtractor {
    /// Built once, reused forever. Constructing an NSDataDetector loads the
    /// system's data-detection resources and an NSRegularExpression compiles
    /// its pattern — both used to happen on EVERY SwiftUI body evaluation of
    /// the preview (i.e. every selection), on the main thread. Both classes
    /// are documented as thread-safe for concurrent matching, so a single
    /// shared instance is safe to share across the main and worker queues.
    private nonisolated static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private nonisolated static let htmlAnchorRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"<a\b[^>]*?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])

    nonisolated static func links(from attr: NSAttributedString) -> [ExtractedLink] {
        guard attr.length > 0 else { return [] }
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        attr.enumerateAttribute(.link, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let url: URL?
            switch value {
            case let u as URL:    url = u
            case let s as String: url = URL(string: s)
            default:              url = nil
            }
            guard let url, url.scheme != nil, seen.insert(url.absoluteString).inserted else { return }
            let text = attr.attributedSubstring(from: range).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ExtractedLink(label: text.isEmpty ? (url.host ?? url.absoluteString) : text, url: url))
        }
        return out
    }

    nonisolated static func links(fromHTML html: String) -> [ExtractedLink] {
        guard html.count <= 300_000, let re = htmlAnchorRegex else { return [] }
        let ns = html as NSString
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let href = ns.substring(with: m.range(at: 1))
            guard let url = URL(string: href), url.scheme != nil,
                  seen.insert(url.absoluteString).inserted else { continue }
            let inner = ns.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ExtractedLink(label: inner.isEmpty ? (url.host ?? href) : inner, url: url))
        }
        return out
    }

    /// URLs that appear as bare text (not markup) inside plain-text copies.
    nonisolated static func links(fromPlainText text: String, cap: Int = 12) -> [ExtractedLink] {
        guard text.count <= 300_000, let detector = linkDetector else { return [] }
        let ns = text as NSString
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let url = match?.url, url.scheme != nil, seen.insert(url.absoluteString).inserted else { return }
            out.append(ExtractedLink(label: url.host ?? url.absoluteString, url: url))
            if out.count >= cap { stop.pointee = true }
        }
        return out
    }
}

/// Parses a plain-text representation of any copied content for things worth
/// surfacing at a glance without opening the full preview: person names,
/// email addresses, code-shaped lines, and lines that repeat verbatim
/// (useful for spotting duplicated rows in pasted lists/logs).
/// The result of one text-insight scan. A reference type so `NSCache` can hold
/// it; every stored property is immutable.
nonisolated final class TextInsights {
    struct RepeatedLine {
        let line: String
        let count: Int
    }

    let emails: [String]
    let names: [String]
    let codeLines: [String]
    let repeatedLines: [RepeatedLine]

    init(emails: [String], names: [String], codeLines: [String], repeatedLines: [RepeatedLine]) {
        self.emails = emails
        self.names = names
        self.codeLines = codeLines
        self.repeatedLines = repeatedLines
    }

    var isEmpty: Bool {
        emails.isEmpty && names.isEmpty && codeLines.isEmpty && repeatedLines.isEmpty
    }
}

/// Runs the insight scan off the main thread and memoizes it per clip.
///
/// This scan (an NLTagger named-entity pass plus several regex/line scans) used
/// to run synchronously inside `RichLinkedPreview.body` — so it re-ran on every
/// SwiftUI body evaluation, on the main thread, for every text-ish clip, and
/// the cost was paid even when the result was empty. That was the bulk of the
/// delay between clicking an item and seeing its preview.
final class TextInsightService {
    static let shared = TextInsightService()

    private let queue = DispatchQueue(label: "com.clipen.textinsights", qos: .userInitiated)
    private let cache = NSCache<NSString, TextInsights>()
    // [ExtractedLink] is a value type, so it's boxed as NSArray for NSCache —
    // same pattern TableCellExtractor already uses for [[String]] above.
    private let linkCache = NSCache<NSString, NSArray>()

    private init() {
        cache.countLimit = 400
        linkCache.countLimit = 400
    }

    /// Keyed on the clip id AND a content fingerprint, so editing a clip in
    /// place (same id, new text) recomputes instead of serving stale insights.
    /// Shared by both the insights cache and the link cache below — the same
    /// fingerprint invalidates both correctly on edit.
    static func cacheKey(id: UUID?, text: String?) -> String {
        let t = text ?? ""
        return "\(id?.uuidString ?? "-")|\(t.count)|\(t.prefix(48))|\(t.suffix(48))"
    }

    func cached(forKey key: String) -> TextInsights? {
        cache.object(forKey: key as NSString)
    }

    func store(_ insights: TextInsights, forKey key: String) {
        cache.setObject(insights, forKey: key as NSString)
    }

    func storeLinks(_ links: [ExtractedLink], forKey key: String) {
        linkCache.setObject(links as NSArray, forKey: key as NSString)
    }

    func insights(forKey key: String, text: String) async -> TextInsights {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let hit = self?.cache.object(forKey: key as NSString) {
                    continuation.resume(returning: hit)
                    return
                }
                let result = TextInsightExtractor.computeInsights(in: text)
                self?.cache.setObject(result, forKey: key as NSString)
                continuation.resume(returning: result)
            }
        }
    }

    func cachedLinks(forKey key: String) -> [ExtractedLink]? {
        linkCache.object(forKey: key as NSString) as? [ExtractedLink]
    }

    /// `compute` is whichever `LinkExtractor` variant matches the clip's
    /// content type (plain text / attributed string / HTML) — this service
    /// doesn't need to know which; it only owns the off-thread + cache
    /// mechanics, exactly like `insights(forKey:text:)` above.
    func links(forKey key: String, compute: @escaping () -> [ExtractedLink]) async -> [ExtractedLink] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let hit = self?.linkCache.object(forKey: key as NSString) as? [ExtractedLink] {
                    continuation.resume(returning: hit)
                    return
                }
                let result = compute()
                self?.linkCache.setObject(result as NSArray, forKey: key as NSString)
                continuation.resume(returning: result)
            }
        }
    }
}

enum TextInsightExtractor {
    nonisolated static let maxLabelLength = 42

    private nonisolated static let emailRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                                 options: .caseInsensitive)

    /// The whole scan, in one call — always invoked from a background queue
    /// (see TextInsightService), never from a view body.
    nonisolated static func computeInsights(in text: String) -> TextInsights {
        TextInsights(emails: emails(in: text),
                     names: personNames(in: text),
                     codeLines: codeLikeLines(in: text),
                     repeatedLines: repeatedLines(in: text))
    }

    nonisolated static func truncate(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLabelLength else { return t }
        return String(t.prefix(maxLabelLength)) + "…"
    }

    nonisolated static func emails(in text: String, cap: Int = 6) -> [String] {
        guard text.count <= 300_000, let re = emailRegex else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            guard seen.insert(s.lowercased()).inserted else { continue }
            out.append(s)
            if out.count >= cap { break }
        }
        return out
    }

    /// Named-entity recognition is by far the heaviest thing in this file's
    /// analysis path — NLTagger loads an ML model and runs inference. The cap
    /// used to be 50 k characters, which is a lot of inference to sit behind a
    /// chip strip; a few thousand characters is more than enough to surface
    /// the names worth showing.
    nonisolated static func personNames(in text: String, cap: Int = 6) -> [String] {
        guard !text.isEmpty, text.count <= 5_000 else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var seen = Set<String>()
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                              options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName {
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count > 1, seen.insert(name).inserted {
                    out.append(name)
                }
            }
            return out.count < cap
        }
        return out
    }

    private nonisolated static let codeKeywords = [
        "func ", "def ", "class ", "import ", "return ", "const ", "let ", "var ",
        "public ", "private ", "#include", "=>", "select ", "function ",
    ]

    nonisolated static func codeLikeLines(in text: String, cap: Int = 6) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for line in lines {
            let lower = line.lowercased()
            let looksLikeCode = codeKeywords.contains { lower.contains($0) }
                || (line.contains("{") && line.contains("}"))
                || (line.hasSuffix(";") && line.count > 4)
            if looksLikeCode {
                out.append(line)
                if out.count >= cap { break }
            }
        }
        return out
    }

    nonisolated static func repeatedLines(in text: String, cap: Int = 6) -> [TextInsights.RepeatedLine] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
        guard lines.count <= 5_000 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for l in lines {
            if counts[l] == nil { order.append(l) }
            counts[l, default: 0] += 1
        }
        return order.compactMap { line -> TextInsights.RepeatedLine? in
            guard let c = counts[line], c > 1 else { return nil }
            return TextInsights.RepeatedLine(line: line, count: c)
        }
        .sorted { $0.count > $1.count }
        .prefix(cap)
        .map { $0 }
    }
}

struct PreviewInsightChip: Identifiable {
    enum Kind { case link(URL), email, name, code, repeated(Int), added, removed }
    /// Assigned by `uniqued(_:)` from the chip's own content. It used to be a
    /// fresh `UUID()` per chip per build, which meant every rebuild produced
    /// entirely new identities and `ForEach` in InsightsStrip could never diff
    /// — it tore down and relaid out the whole strip each time.
    var id: String = ""
    let kind: Kind
    let icon: String
    let label: String
    let color: Color
    var helpText: String? = nil

    /// Content-derived identity. Stable across rebuilds for the same chip.
    private var stableKey: String {
        switch kind {
        case .link(let url):   return "link|\(url.absoluteString)"
        case .email:           return "email|\(label)"
        case .name:            return "name|\(label)"
        case .code:            return "code|\(label)"
        case .repeated(let n): return "repeated|\(n)|\(label)"
        case .added:           return "added|\(label)"
        case .removed:         return "removed|\(label)"
        }
    }

    /// Stamps stable ids, disambiguating the rare genuine duplicate (e.g. the
    /// same code-shaped line appearing twice) so SwiftUI never sees a repeated
    /// ForEach id.
    static func uniqued(_ chips: [PreviewInsightChip]) -> [PreviewInsightChip] {
        var seen = Set<String>()
        return chips.map { chip in
            var copy = chip
            let base = chip.stableKey
            var candidate = base
            var n = 2
            while !seen.insert(candidate).inserted {
                candidate = "\(base)#\(n)"
                n += 1
            }
            copy.id = candidate
            return copy
        }
    }

    /// The concrete added (green) / removed (red) lines from a small edit,
    /// shown first in the strip so "what exactly changed" is obvious.
    static func diffChips(_ detail: DiffDetail?) -> [PreviewInsightChip] {
        guard let detail else { return [] }
        var chips: [PreviewInsightChip] = []
        chips += detail.added.map {
            PreviewInsightChip(kind: .added, icon: "plus",
                                label: TextInsightExtractor.truncate($0), color: .green,
                                helpText: "Added vs #\(detail.fromRank)")
        }
        chips += detail.removed.map {
            PreviewInsightChip(kind: .removed, icon: "minus",
                                label: TextInsightExtractor.truncate($0), color: .red,
                                helpText: "Removed vs #\(detail.fromRank)")
        }
        return chips
    }

    /// Cheap — link extraction already happened at the call site.
    static func linkChips(_ links: [ExtractedLink]) -> [PreviewInsightChip] {
        links.map {
            PreviewInsightChip(kind: .link($0.url), icon: "link",
                                label: TextInsightExtractor.truncate($0.label), color: .accentColor,
                                helpText: $0.url.absoluteString)
        }
    }

    /// Pure formatting of an already-computed (off-main, cached) scan — no
    /// analysis happens here, so this is safe to call from a view body.
    static func textChips(_ insights: TextInsights?) -> [PreviewInsightChip] {
        guard let insights else { return [] }
        var chips: [PreviewInsightChip] = []
        chips += insights.emails.map {
            PreviewInsightChip(kind: .email, icon: "envelope.fill",
                                label: TextInsightExtractor.truncate($0), color: .orange)
        }
        chips += insights.names.map {
            PreviewInsightChip(kind: .name, icon: "person.fill",
                                label: TextInsightExtractor.truncate($0), color: .purple)
        }
        chips += insights.codeLines.map {
            PreviewInsightChip(kind: .code, icon: "curlybraces",
                                label: TextInsightExtractor.truncate($0), color: .cyan)
        }
        chips += insights.repeatedLines.map {
            PreviewInsightChip(kind: .repeated($0.count), icon: "repeat",
                                label: "\($0.count)× " + TextInsightExtractor.truncate($0.line), color: .pink)
        }
        return chips
    }
}

struct InsightsStrip: View {
    let chips: [PreviewInsightChip]

    /// Alternates chips into two independent rows (1st→row A, 2nd→row B,
    /// 3rd→row A, …) rather than a shared-column grid — a grid would match
    /// each row's column width to its widest paired item, leaving gaps
    /// around shorter chips. Two plain, independently-packed `HStack`s keep
    /// every chip flush against its neighbor.
    private var rowA: [PreviewInsightChip] { chips.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
    private var rowB: [PreviewInsightChip] { chips.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(rowA) { chip in chipView(chip) }
                }
                HStack(spacing: 8) {
                    ForEach(rowB) { chip in chipView(chip) }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chipView(_ chip: PreviewInsightChip) -> some View {
        if case .link(let url) = chip.kind {
            Button { NSWorkspace.shared.open(url) } label: { chipLabel(chip) }
                .buttonStyle(.plain)
                .help(chip.helpText ?? "")
        } else {
            chipLabel(chip)
        }
    }

    private func chipLabel(_ chip: PreviewInsightChip) -> some View {
        // Diff chips are tinted with their add/remove color; everything else
        // keeps the neutral gray look.
        let isDiff: Bool = { if case .added = chip.kind { return true }
                             if case .removed = chip.kind { return true }
                             return false }()
        return HStack(spacing: 4) {
            Image(systemName: chip.icon).font(.system(size: 8, weight: isDiff ? .bold : .regular))
            Text(chip.label).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background((isDiff ? chip.color.opacity(0.16) : Color.gray.opacity(0.16)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundColor(isDiff ? chip.color : .secondary)
    }
}

struct RichLinkedPreview<Content: View>: View {
    /// How to find this clip's links — deferred, not run yet. Every call site
    /// used to compute its `LinkExtractor.links(...)` eagerly as a plain
    /// argument expression, meaning the NSDataDetector/regex scan ran
    /// synchronously on the main thread on EVERY body evaluation (every
    /// selection, every re-render), uncached — the same class of stutter the
    /// insights scan below used to cause before it was moved off-thread.
    /// Wrapping it in a closure lets this view run it exactly like insights:
    /// off the main thread, once per clip, cached after that.
    let computeLinks: () -> [ExtractedLink]
    var plainText: String? = nil
    /// Identity of the clip these insights describe — the cache key, so the
    /// scan runs once per clip rather than on every body evaluation.
    var insightID: UUID? = nil
    var diff: DiffDetail? = nil
    @ViewBuilder let content: Content

    @State private var insights: TextInsights? = nil
    @State private var links: [ExtractedLink] = []

    private var taskKey: String { TextInsightService.cacheKey(id: insightID, text: plainText) }

    var body: some View {
        let chips = PreviewInsightChip.uniqued(
            PreviewInsightChip.diffChips(diff)
                + PreviewInsightChip.linkChips(links)
                + PreviewInsightChip.textChips(insights))
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !chips.isEmpty {
                Divider()
                InsightsStrip(chips: chips)
            }
        }
        // The content renders immediately; the insight/link chips appear a
        // beat later on a cache miss. Previously the insights scan ran
        // inline in `body` (same for link extraction until now), so the
        // preview couldn't paint at all until it finished.
        .task(id: taskKey) {
            let key = taskKey

            // Links: cache hit is synchronous, same reasoning as insights
            // below — revisiting a clip shows its link chips immediately.
            if let hit = TextInsightService.shared.cachedLinks(forKey: key) {
                links = hit
            } else {
                links = []
                let computeLinks = computeLinks
                let computed = await TextInsightService.shared.links(forKey: key, compute: computeLinks)
                if !Task.isCancelled { links = computed }
            }

            guard let plainText, !plainText.isEmpty else {
                insights = nil
                return
            }
            // Cache hit is synchronous — revisiting a clip shows its chips
            // immediately, with no flash of the strip appearing late.
            if let hit = TextInsightService.shared.cached(forKey: key) {
                insights = hit
                return
            }
            // Drop the previous clip's chips while the new scan runs, so they
            // can't linger next to unrelated content.
            insights = nil
            let computed = await TextInsightService.shared.insights(forKey: key, text: plainText)
            guard !Task.isCancelled else { return }
            insights = computed
        }
    }
}

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }
}
