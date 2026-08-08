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

final class TextInsightService {
    static let shared = TextInsightService()

    private let queue = DispatchQueue(label: "com.clipen.textinsights", qos: .userInitiated)
    private let cache = NSCache<NSString, TextInsights>()

    private let linkCache = NSCache<NSString, NSArray>()

    private init() {
        cache.countLimit = 400
        linkCache.countLimit = 400
    }

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

    var id: String = ""
    let kind: Kind
    let icon: String
    let label: String
    let color: Color
    var helpText: String? = nil

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

    static func linkChips(_ links: [ExtractedLink]) -> [PreviewInsightChip] {
        links.map {
            PreviewInsightChip(kind: .link($0.url), icon: "link",
                                label: TextInsightExtractor.truncate($0.label), color: .accentColor,
                                helpText: $0.url.absoluteString)
        }
    }

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

    let computeLinks: () -> [ExtractedLink]
    var plainText: String? = nil

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

        .task(id: taskKey) {
            let key = taskKey

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

            if let hit = TextInsightService.shared.cached(forKey: key) {
                insights = hit
                return
            }

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
