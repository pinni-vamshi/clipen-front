import Foundation
import Combine
import NaturalLanguage

/// Every evidence signal is content-based — it requires an actual
/// identifiable value (a code, a date, an amount) to be present.
/// Deliberately NOT included: anything that scores from shape alone
/// (having a table, a bulleted list, or many lines) — a bulleted grocery
/// list and a bulleted list of legal clauses have the same shape and
/// wildly different importance, and a single line can carry the single
/// most important fact in the whole item ("CAS Number: E4G9MW2N62Z0R9").
/// Format is not evidence; only content is.
enum SignalKind: String, CaseIterable, Identifiable {
    case labeledFields, referenceCode, money, date, longDigits, email, measurement, percent, time, multipleLinks
    case phoneNumber, address, namedEntity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .labeledFields:  return "Labeled fields"
        case .referenceCode:  return "Reference / ID code"
        case .money:          return "Monetary amount"
        case .date:           return "Date"
        case .longDigits:     return "Long number"
        case .email:          return "Email address"
        case .measurement:    return "Measurement"
        case .percent:        return "Percentage"
        case .time:           return "Time of day"
        case .multipleLinks:  return "Multiple links"
        case .phoneNumber:    return "Phone number"
        case .address:        return "Postal address"
        case .namedEntity:    return "Named entity"
        }
    }

    /// `.date`/`.phoneNumber`/`.address` are detected by `NSDataDetector`
    /// (Apple's own system-level detector — the same engine behind
    /// tap-to-call in Messages) rather than hand-rolled regex, since it
    /// already handles every date format ("22 July 2026", relative dates,
    /// locale variants) that regex kept needing new patches for.
    /// `.namedEntity` comes from `NLTagger`'s named-entity recognition —
    /// a real person/organization/place name is content evidence no
    /// regex pattern can express at all.
    var source: String {
        switch self {
        case .date, .phoneNumber, .address: return "NSDataDetector"
        case .namedEntity: return "NLTagger"
        default: return "pattern"
        }
    }

    var defaultWeight: Double {
        switch self {
        case .labeledFields:  return 0.11
        case .referenceCode:  return 0.25
        case .money:          return 0.20
        case .date:           return 0.15
        case .longDigits:     return 0.14
        case .email:          return 0.10
        case .measurement:    return 0.08
        case .percent:        return 0.07
        case .time:           return 0.07
        case .multipleLinks:  return 0.10
        case .phoneNumber:    return 0.14
        case .address:        return 0.16
        case .namedEntity:    return 0.06
        }
    }
}

/// Every weight is user-adjustable from the AI ANALYSIS card itself — a
/// +/- beside each signal's own row, right where you're already looking
/// at what it did for this item, not buried in a separate settings
/// screen. Persisted, and shared across every item since these are global
/// scoring rules, not per-item settings.
@MainActor
final class ImportanceWeightsStore: ObservableObject {
    static let shared = ImportanceWeightsStore()

    private static let weightsKey = "importanceScoring.weights.v1"
    private static let thresholdKey = "importanceScoring.threshold.v1"
    static let defaultThreshold = 0.47
    static let step = 0.02

    @Published private(set) var weights: [String: Double]
    @Published private(set) var threshold: Double

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.weightsKey) as? [String: Double] ?? [:]
        var merged: [String: Double] = [:]
        for kind in SignalKind.allCases { merged[kind.id] = saved[kind.id] ?? kind.defaultWeight }
        weights = merged
        threshold = UserDefaults.standard.object(forKey: Self.thresholdKey) as? Double ?? Self.defaultThreshold
    }

    func weight(for kind: SignalKind) -> Double { weights[kind.id] ?? kind.defaultWeight }

    func adjustWeight(_ kind: SignalKind, by delta: Double) {
        let next = (weight(for: kind) + delta).clamped(0, 1).rounded2
        weights[kind.id] = next
        UserDefaults.standard.set(weights, forKey: Self.weightsKey)
        ImportanceScoringService.shared.invalidateAll()
    }

    func adjustThreshold(by delta: Double) {
        threshold = (threshold + delta).clamped(0, 1).rounded2
        UserDefaults.standard.set(threshold, forKey: Self.thresholdKey)
        ImportanceScoringService.shared.invalidateAll()
    }

    func resetToDefaults() {
        for kind in SignalKind.allCases { weights[kind.id] = kind.defaultWeight }
        threshold = Self.defaultThreshold
        UserDefaults.standard.removeObject(forKey: Self.weightsKey)
        UserDefaults.standard.removeObject(forKey: Self.thresholdKey)
        ImportanceScoringService.shared.invalidateAll()
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.max(lo, Swift.min(hi, self)) }
    var rounded2: Double { (self * 100).rounded() / 100 }
}

/// One detected signal for one item — `kind` is nil for the junk
/// penalties below, which aren't (yet) individually configurable.
struct ImportanceSignal: Identifiable {
    let id = UUID()
    let kind: SignalKind?
    let label: String
    let detail: String
    let matchCount: Int
    let points: Double
}

struct ImportanceBreakdown {
    let itemID: UUID
    let sourceTextUsed: String?
    let evidence: [ImportanceSignal]
    let penalties: [ImportanceSignal]
    let evidenceTotal: Double
    let penaltyTotal: Double
    let finalScore: Double
    let threshold: Double
    let decision: Bool
    let isIndeterminate: Bool
}

/// Apple's own system-level entity detector — the same engine behind
/// tap-to-call in Messages / tap-to-open-map in Mail. Used here for
/// dates, phone numbers, and addresses instead of hand-rolled regex:
/// it already covers every locale/format variant regex kept needing new
/// patches for ("22 July 2026" vs "07/22/2026" vs "next Friday" are all
/// just `.date` to it).
enum SystemDataDetector {
    /// `.link` is in the set purely for the Details panel — the importance
    /// scorer below ignores link matches, and always did. Emails arrive
    /// here as `mailto:` links, so they need no separate pass.
    private static let detector = try? NSDataDetector(types:
        NSTextCheckingResult.CheckingType.date.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        | NSTextCheckingResult.CheckingType.address.rawValue
        | NSTextCheckingResult.CheckingType.link.rawValue)

    struct Counts { var dates = 0; var phones = 0; var addresses = 0 }

    /// Scanning is linear in the text length and this runs on the main
    /// thread when the Details panel opens, so a pathological clip (a
    /// whole log file, a pasted database dump) is truncated rather than
    /// allowed to stall the keystroke that opened the panel.
    static let maxScanLength = 100_000
    /// Per-kind and overall caps, so a page of a hundred phone numbers
    /// yields a browsable panel rather than a hundred rows to cycle past.
    private static let maxPerKind = 12
    private static let maxTotal = 40

    static func counts(in text: String) -> Counts {
        guard let detector else { return Counts() }
        var result = Counts()
        let range = NSRange(text.startIndex..., in: text)
        detector.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            switch match?.resultType {
            case .some(.date):        result.dates += 1
            case .some(.phoneNumber): result.phones += 1
            case .some(.address):     result.addresses += 1
            default: break
            }
        }
        return result
    }

    /// The same scan as `counts`, but keeping the matched VALUES instead of
    /// throwing them away — this is what lets the Details panel show
    /// something the instant D is pressed, with no model run and no wait.
    ///
    /// The value kept is the matched substring as the user copied it, not a
    /// reformatted rendering of it: Details rows are pasteable, so what
    /// lands in the destination app should be what was in the source.
    static func fields(in text: String) -> [DetailField] {
        guard let detector, !text.isEmpty else { return [] }
        let scanned = text.count > maxScanLength ? String(text.prefix(maxScanLength)) : text
        let ns = scanned as NSString
        var out: [DetailField] = []
        var perKind: [String: Int] = [:]
        var seen = Set<String>()

        detector.enumerateMatches(in: scanned, options: [],
                                  range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match, out.count < maxTotal else {
                if out.count >= maxTotal { stop.pointee = true }
                return
            }
            let raw = ns.substring(with: match.range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return }

            let key: String
            var value = raw
            switch match.resultType {
            case .date:        key = "Date"
            case .phoneNumber: key = "Phone"
            case .address:
                key = "Address"
                // Postal addresses match across line breaks; a Details row
                // is one line, so fold the run-in whitespace.
                value = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                           .joined(separator: " ")
            case .link:
                if let url = match.url, url.scheme?.lowercased() == "mailto" {
                    key = "Email"
                    value = url.absoluteString
                        .replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                } else {
                    key = "Link"
                    value = match.url?.absoluteString ?? raw
                }
            default: return
            }

            guard value.count <= 400 else { return }
            let dedupe = key + "\u{1}" + value.lowercased()
            guard !seen.contains(dedupe) else { return }
            let used = perKind[key, default: 0]
            guard used < maxPerKind else { return }
            perKind[key] = used + 1
            seen.insert(dedupe)
            out.append(DetailField(key: key, value: value))
        }
        return out
    }
}

/// Real named-entity recognition via `NLTagger` — a genuine
/// person/organization/place name is content evidence a regex pattern
/// has no way to express ("University of Glasgow" isn't a pattern, it's
/// a fact about the world the tagger's model already knows).
enum NamedEntityDetector {
    static func count(in text: String) -> Int {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var count = 0
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, _ in
            if let tag, tag == .personalName || tag == .organizationName || tag == .placeName {
                count += 1
            }
            return true
        }
        return count
    }
}

enum ExtractableEntityDetector {

    private static func matchCount(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> Int {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private static let labeledFieldPattern = #"[A-Za-z][A-Za-z0-9 /_&.'-]{1,40}:[ \t]*(?![/\s])\S"#
    private static let referenceCodePattern = #"\b(?=[A-Z0-9-]{6,24}\b)(?=[A-Z-]*[0-9])(?=[0-9-]*[A-Z])[A-Z0-9-]{6,24}\b"#
    private static let moneyPattern = #"[$€£¥₹]\s?\d[\d,]*(\.\d+)?|\b\d[\d,]*(\.\d{2})?\s?(USD|EUR|GBP|INR|JPY|AUD|CAD)\b"#
    private static let longDigitPattern = #"\b\d{7,}\b"#
    private static let emailPattern = #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#
    private static let urlPattern = #"\bhttps?://\S+"#
    private static let percentPattern = #"\b\d+(\.\d+)?\s?%"#
    private static let timePattern = #"\b\d{1,2}:\d{2}(:\d{2})?\s?([AaPp]\.?[Mm]\.?)?\b"#
    private static let measurementPattern = #"\b\d+(\.\d+)?\s?(kg|g|mg|lb|oz|km|m|cm|mm|mi|ft|in|GB|MB|KB|TB|hrs?|hours?|mins?|minutes?|days?|weeks?|months?|years?)\b"#

    /// Contribution for one signal kind: `weight` for the first match, up
    /// to double that if several appear — one editable number per kind
    /// instead of a separate, harder-to-explain cap control.
    private static func score(_ count: Int, weight: Double) -> Double {
        guard count > 0 else { return 0 }
        return min(weight * 2, Double(count) * weight)
    }

    static func gather(from text: String) -> [ImportanceSignal] {
        let w = ImportanceWeightsStore.shared
        var found: [ImportanceSignal] = []

        func add(_ kind: SignalKind, count: Int, detail: String) {
            guard count > 0 else { return }
            found.append(ImportanceSignal(kind: kind, label: kind.label, detail: detail,
                                          matchCount: count, points: score(count, weight: w.weight(for: kind))))
        }

        let labeled = matchCount(labeledFieldPattern, in: text)
        add(.labeledFields, count: labeled, detail: "\(labeled) \u{201C}Label: value\u{201D} pair\(labeled == 1 ? "" : "s")")

        let refs = matchCount(referenceCodePattern, in: text)
        add(.referenceCode, count: refs, detail: "\(refs) alphanumeric identifier\(refs == 1 ? "" : "s")")

        let money = matchCount(moneyPattern, in: text)
        add(.money, count: money, detail: "\(money) amount\(money == 1 ? "" : "s")")

        let sysDetected = SystemDataDetector.counts(in: text)
        add(.date, count: sysDetected.dates, detail: "\(sysDetected.dates) date\(sysDetected.dates == 1 ? "" : "s") \u{2014} NSDataDetector")
        add(.phoneNumber, count: sysDetected.phones, detail: "\(sysDetected.phones) phone number\(sysDetected.phones == 1 ? "" : "s") \u{2014} NSDataDetector")
        add(.address, count: sysDetected.addresses, detail: "\(sysDetected.addresses) postal address\(sysDetected.addresses == 1 ? "" : "es") \u{2014} NSDataDetector")

        let entities = NamedEntityDetector.count(in: text)
        add(.namedEntity, count: entities, detail: "\(entities) person/organization/place name\(entities == 1 ? "" : "s") \u{2014} NLTagger")

        let digits = matchCount(longDigitPattern, in: text)
        add(.longDigits, count: digits, detail: "\(digits) 7+ digit run\(digits == 1 ? "" : "s") (account / ID / phone)")

        let emails = matchCount(emailPattern, in: text)
        add(.email, count: emails, detail: "\(emails) address\(emails == 1 ? "" : "es")")

        let measures = matchCount(measurementPattern, in: text, caseInsensitive: true)
        add(.measurement, count: measures, detail: "\(measures) value\(measures == 1 ? "" : "s") with units")

        let percents = matchCount(percentPattern, in: text)
        add(.percent, count: percents, detail: "\(percents) value\(percents == 1 ? "" : "s")")

        let times = matchCount(timePattern, in: text)
        add(.time, count: times, detail: "\(times) timestamp\(times == 1 ? "" : "s")")

        let urls = matchCount(urlPattern, in: text)
        add(.multipleLinks, count: urls >= 2 ? urls : 0, detail: "\(urls) URLs")

        return found.sorted { $0.points > $1.points }
    }
}

/// Splits long text into fixed-size chunks (breaking on whitespace, never
/// mid-word) so a long document is scored by its single densest chunk
/// rather than by the sum of evidence across its whole length. This is
/// what stops a long, mostly-padded document from out-scoring a short,
/// genuinely dense one just by accumulating more matches over more text —
/// and it also catches the opposite case, one important paragraph buried
/// in a lot of filler, since that paragraph is scored on its own instead
/// of being diluted across everything around it.
enum ChunkSplitter {
    static let targetSize = 200

    // Overlapping windows, not disjoint ones. Several detector patterns
    // (a labeled field, a money amount, a date, an address) span several
    // whitespace-separated words — only single-token splits were ever
    // protected here. A disjoint 200-char cut could still land in the
    // middle of one of these multi-word spans, tearing it across two
    // chunks; since scoring takes each chunk's regex/detector matches
    // independently and a torn span matches in neither half, that signal
    // was silently worth zero regardless of how important it was. A
    // 50%-overlap stride guarantees any span up to `stride` characters is
    // fully contained within at least one window. Because scoring only
    // ever takes the single best chunk (never sums across chunks), the
    // extra overlapping windows can only help the score find its true max,
    // never inflate it.
    static let stride = targetSize / 2

    static func chunks(of text: String, targetSize: Int = Self.targetSize) -> [Substring] {
        guard text.count > targetSize else { return [Substring(text)] }
        var result: [Substring] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: targetSize, limitedBy: text.endIndex) ?? text.endIndex
            while end < text.endIndex, !text[end].isWhitespace {
                end = text.index(after: end)
            }
            result.append(text[start..<end])
            if end == text.endIndex { break }
            guard let nextStart = text.index(start, offsetBy: Self.stride, limitedBy: text.endIndex),
                  nextStart > start else { break }
            start = nextStart
        }
        return result
    }
}

enum ImportanceJunkDetector {
    private static let fillerPattern = #"^(ok(ay)?|thanks?|thank you|thx|lol|lmao|haha+|yeah?|yep|yup|yes|no|nope|sure|hi|hey|hello|bye|cool|nice|great|perfect|got it|sounds good|will do|see you( tomorrow| later| soon)?|k|np|ty)[!.…?\s]*$"#

    static func gather(from text: String, tags: [ClipboardTag], primary: ClipboardTag) -> [ImportanceSignal] {
        var penalties: [ImportanceSignal] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let length = trimmed.count

        func add(_ label: String, _ detail: String, _ points: Double) {
            penalties.append(ImportanceSignal(kind: nil, label: label, detail: detail, matchCount: 1, points: points))
        }

        if length < 12 {
            add("Very short", "\(length) characters", -0.55)
        }

        if trimmed.range(of: fillerPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            add("Conversational filler", "matches a common throwaway phrase", -0.70)
        }

        let hasAlphanumeric = trimmed.rangeOfCharacter(from: .alphanumerics) != nil
        if !hasAlphanumeric && !trimmed.isEmpty {
            add("No text content", "emoji or punctuation only", -0.70)
        }

        let isSingleToken = !trimmed.contains(" ") && !trimmed.contains("\n")
        if isSingleToken && primary == .url {
            add("Bare link", "a single URL is already the value \u{2014} nothing to extract", -0.35)
        }

        if primary == .color {
            add("Atomic value", "\(primary.label) is already the value", -0.45)
        }

        if isSingleToken && length < 25 && primary != .url {
            add("Single short token", "no structure to extract", -0.30)
        }

        return penalties
    }
}

/// Decides whether a freshly captured item is worth the automatic AI
/// structuring pass, or should wait for the user to explicitly ask for it
/// (pressing D, or the refresh button — both go through
/// `AIStructuringService.refresh(item:)`, which never consults this at
/// all). Every evaluation is cached and kept forever so the Properties
/// panel can show the reasoning for any item, analyzed or skipped —
/// invalidated wholesale whenever a weight or the threshold changes, so
/// adjusting either immediately re-scores everything on next view.
@MainActor
final class ImportanceScoringService: ObservableObject {
    static let shared = ImportanceScoringService()

    /// Above this, automatic analysis is skipped outright regardless of
    /// score — comfortably under `AIStructuringService`'s own 12,000-char
    /// truncation limit, so an auto-triggered run never gets close to
    /// needing it. Manual runs (D key, refresh button) never consult this
    /// at all and always go through in full.
    static let autoAnalysisLengthCeiling = 120_000

    @Published private(set) var breakdowns: [UUID: ImportanceBreakdown] = [:]

    private init() {}

    @discardableResult
    func evaluate(_ item: ClipboardItem) -> ImportanceBreakdown {
        if let cached = breakdowns[item.id], !cached.isIndeterminate { return cached }

        let threshold = ImportanceWeightsStore.shared.threshold
        // Both, not one or the other. `plainText ?? ocrText` meant an item
        // that has both — a file with a name AND OCR'd contents, an HTML
        // clip with recognised text — was judged on the first one only, and
        // the richer of the two was never even looked at.
        let candidates = [item.content.plainText, item.ocrText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let trimmed = candidates.max(by: { scoreOnly($0, item: item) < scoreOnly($1, item: item) }) ?? ""

        if trimmed.isEmpty {
            let pending = ImportanceBreakdown(
                itemID: item.id,
                sourceTextUsed: nil,
                evidence: [],
                penalties: [ImportanceSignal(
                    kind: nil,
                    label: "No readable text yet",
                    detail: "an image still waiting on OCR, or content with no text at all",
                    matchCount: 0,
                    points: 0)],
                evidenceTotal: 0,
                penaltyTotal: 0,
                finalScore: 0,
                threshold: threshold,
                decision: false,
                isIndeterminate: true)
            breakdowns[item.id] = pending
            return pending
        }

        // The ceiling exists from when scoring read the WHOLE text: a long
        // document diluted its own score, so refusing outright saved wasted
        // model calls. Chunk scoring replaced that — a long document is
        // judged by its densest paragraph — so length no longer dilutes
        // anything and the ceiling now only blocks exactly the items best-
        // chunk scoring was built to rescue. It stays as a far higher
        // backstop against pathological inputs, not as a content judgement.
        if trimmed.count > Self.autoAnalysisLengthCeiling {
            let breakdown = ImportanceBreakdown(
                itemID: item.id,
                sourceTextUsed: trimmed,
                evidence: [],
                penalties: [ImportanceSignal(
                    kind: nil,
                    label: "Too long for automatic analysis",
                    detail: "\(trimmed.count) characters, cap is \(Self.autoAnalysisLengthCeiling) \u{2014} press Run Analysis to run it anyway",
                    matchCount: 0,
                    points: 0)],
                evidenceTotal: 0,
                penaltyTotal: 0,
                finalScore: 0,
                threshold: threshold,
                decision: false,
                isIndeterminate: false)
            breakdowns[item.id] = breakdown
            return breakdown
        }

        var evidence = Self.bestChunkEvidence(in: trimmed)
        if let appSignal = Self.sourceAppSignal(for: item) { evidence.append(appSignal) }
        let penalties = ImportanceJunkDetector.gather(from: trimmed, tags: item.tags, primary: item.primaryTag)

        let evidenceTotal = min(1.0, evidence.reduce(0) { $0 + $1.points })
        let penaltyTotal = max(-1.0, penalties.reduce(0) { $0 + $1.points })
        let final = max(0, min(1.0, evidenceTotal + penaltyTotal))

        let breakdown = ImportanceBreakdown(
            itemID: item.id,
            sourceTextUsed: trimmed,
            evidence: evidence,
            penalties: penalties,
            evidenceTotal: evidenceTotal,
            penaltyTotal: penaltyTotal,
            finalScore: final,
            threshold: threshold,
            decision: final >= threshold,
            isIndeterminate: false)
        breakdowns[item.id] = breakdown
        return breakdown
    }

    func invalidate(_ id: UUID) {
        breakdowns[id] = nil
    }

    func invalidateAll() {
        breakdowns.removeAll()
    }

    /// Cheap score used only to pick between two candidate source texts.
    private func scoreOnly(_ text: String, item: ClipboardItem) -> Double {
        let evidence = Self.bestChunk(in: text).signals
        let ev = min(1.0, evidence.reduce(0) { $0 + $1.points })
        let pen = max(-1.0, ImportanceJunkDetector.gather(from: text, tags: item.tags,
                                                          primary: item.primaryTag)
                            .reduce(0) { $0 + $1.points })
        return max(0, min(1.0, ev + pen))
    }

    /// Scores each ~200-character chunk independently and returns only the
    /// densest chunk's evidence, along with the chunk itself.
    ///
    /// Returning the winning TEXT as well as its score matters beyond the
    /// gate: `AIStructuringService` truncates over-long content with
    /// `prefix()` before sending it to the model, so a document whose value
    /// sits on its third page was scored on page three and then had page one
    /// sent. The winning chunk lets the two agree.
    static func bestChunk(in text: String) -> (signals: [ImportanceSignal], text: String) {
        let chunks = ChunkSplitter.chunks(of: text)
        guard chunks.count > 1 else {
            return (ExtractableEntityDetector.gather(from: text) + StructuralSignalDetector.gather(from: text), text)
        }

        var best: [ImportanceSignal] = []
        var bestText = String(chunks[0])
        var bestTotal = -1.0
        let count = Double(chunks.count)
        for (i, chunk) in chunks.enumerated() {
            let body = String(chunk)
            var signals = ExtractableEntityDetector.gather(from: body)
            signals += StructuralSignalDetector.gather(from: body)
            var total = min(1.0, signals.reduce(0) { $0 + $1.points })
            // Small lead bias: an invoice number or a total sits near the
            // top far more often than in a footer, and two chunks that score
            // identically should not be separated by iteration order alone.
            if count > 1 {
                total += (1.0 - Double(i) / (count - 1)) * Self.positionBonus
            }
            if total > bestTotal {
                bestTotal = total
                best = signals
                bestText = body
            }
        }
        return (best, bestText)
    }

    /// How much the first chunk is favoured over the last. Deliberately
    /// small — it breaks ties, it does not decide the outcome.
    private static let positionBonus = 0.04

    /// Apps whose copies are structured data far more often than not.
    /// `sourceBundleID` is recorded on every captured item and the scorer
    /// ignored it completely, even though where something came from is real
    /// evidence about what it is.
    private static let structuredSourceApps: Set<String> = [
        "com.apple.Numbers", "com.microsoft.Excel", "com.apple.Preview",
        "com.adobe.Reader", "com.apple.iWork.Numbers", "com.google.Chrome.app",
        "com.apple.Notes", "com.microsoft.Word", "com.apple.mail",
        "com.readdle.PDFExpert-Mac", "com.apple.iBooksX",
    ]

    /// Modest on purpose: it should tip a borderline item over, never carry
    /// a junk one on its own.
    private static let sourceAppWeight = 0.10

    private static func sourceAppSignal(for item: ClipboardItem) -> ImportanceSignal? {
        guard let bundleID = item.sourceBundleID,
              structuredSourceApps.contains(bundleID) else { return nil }
        return ImportanceSignal(
            kind: nil, label: "Structured source app",
            detail: "copied from \(item.sourceAppName ?? bundleID), which usually means records rather than prose",
            matchCount: 1, points: sourceAppWeight)
    }

    private static func bestChunkEvidence(in text: String) -> [ImportanceSignal] {
        bestChunk(in: text).signals
    }
}

/// Signals about the SHAPE of the text rather than the entities in it.
///
/// The entity detector answers "is there a date / a price / an ID in here",
/// which misses content whose value is that it is a RECORD: a run of
/// `key: value` lines, a consistent column count, a repeated delimiter.
/// Those say "this is structured data worth extracting" more reliably than
/// any single entity match, and previously scored nothing at all.
enum StructuralSignalDetector {
    private static let minRepeats = 3

    static func gather(from text: String) -> [ImportanceSignal] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= minRepeats else { return [] }
        var found: [ImportanceSignal] = []

        // Several lines of "Label: value" is a record, not prose.
        let labelled = lines.filter { line in
            guard let colon = line.firstIndex(of: ":") else { return false }
            let key = line[line.startIndex..<colon]
            return !key.isEmpty && key.count <= 40
                && line.index(after: colon) < line.endIndex
        }.count
        if labelled >= minRepeats {
            found.append(ImportanceSignal(
                kind: nil, label: "Repeated labelled lines",
                detail: "\(labelled) lines shaped like \"Label: value\" — a record rather than prose",
                matchCount: labelled, points: 0.28))
        }

        // Consistent column count across lines is a table, whatever the
        // delimiter happens to be.
        for delimiter in ["\t", "|", ","] {
            let counts = lines.map { $0.components(separatedBy: delimiter).count }.filter { $0 > 1 }
            guard counts.count >= minRepeats,
                  let first = counts.first,
                  counts.allSatisfy({ $0 == first }) else { continue }
            found.append(ImportanceSignal(
                kind: nil, label: "Consistent columns",
                detail: "\(counts.count) lines with \(first) columns — tabular data",
                matchCount: counts.count, points: 0.30))
            break
        }
        return found
    }
}

// MARK: - Instant structured extraction

/// Structured fields pulled out of a clip the moment it is captured,
/// without a model and without waiting for one.
///
/// The Details panel had two speeds and nothing in between: intrinsic
/// facts plus `NSDataDetector` matches, computed lazily when D was pressed,
/// and a full model pass that takes 20-60s. Everything genuinely
/// structured but not a date/phone/address — "Invoice: INV-4471",
/// "Order Total: $89.20", a reference code, a person's name — was
/// reachable only through the slow path, so the first D-press on a clip
/// that plainly contained fields showed almost nothing.
///
/// This runs at capture instead: by the time D is pressed the values are
/// already sitting in memory. It is deliberately not a model — every
/// signal here is deterministic and costs microseconds, which is what
/// makes running it on every copy defensible.
///
/// `Extractor` is the seam a learned extractor (GLiNER-class token
/// classification, zero-shot entity types) drops into later without
/// touching the capture wiring, the cache, or the merge: it takes text,
/// it returns fields, and everything around it stays as-is.
enum InstantStructuredExtractor {
    /// Same ceiling `SystemDataDetector` scans to — this runs on every
    /// copy, so a pasted log file must not turn into unbounded work.
    static let maxScanLength = 100_000
    private static let maxFields = 24
    private static let maxValueLength = 400

    /// "Label: value" lines — the single densest source of real structure
    /// in copied text, and the one an LLM was previously being asked to
    /// re-derive. Bounded on both sides so a URL ("https://…") and prose
    /// containing a colon don't masquerade as fields.
    private static let labeledFieldRe = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*([A-Za-z][A-Za-z0-9 /_&.'-]{1,40}?)[ \t]*:[ \t]*(?!//)([^\r\n]{1,400})$"#)

    private static let referenceCodeRe = try? NSRegularExpression(
        pattern: #"\b(?=[A-Z0-9-]{6,24}\b)(?=[A-Z-]*[0-9])(?=[0-9-]*[A-Z])[A-Z0-9-]{6,24}\b"#)

    private static let moneyRe = try? NSRegularExpression(
        pattern: #"[$€£¥₹]\s?\d[\d,]*(\.\d+)?|\b\d[\d,]*(\.\d{2})?\s?(USD|EUR|GBP|INR|JPY|AUD|CAD)\b"#)

    /// Keys that are almost always page furniture rather than data, and
    /// which otherwise dominate the panel on anything copied from a web
    /// page or an email client.
    private static let noiseKeys: Set<String> = [
        "http", "https", "note", "warning", "error", "tip", "example",
        "subject", "from", "to", "cc", "bcc", "sent", "reply-to",
    ]

    static func extract(from text: String) -> [DetailField] {
        guard !text.isEmpty else { return [] }
        let scanned = text.count > maxScanLength ? String(text.prefix(maxScanLength)) : text
        let ns = scanned as NSString

        var out: [DetailField] = []
        var seen = Set<String>()

        func add(_ key: String, _ value: String) {
            guard out.count < maxFields else { return }
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, !v.isEmpty, v.count <= maxValueLength else { return }
            guard !noiseKeys.contains(k.lowercased()) else { return }
            // Same alphanumerics-only identity the panel merges on, so a
            // value found twice here never becomes two rows downstream.
            let identity = DetailUnit.valueIdentity(v)
            guard !identity.isEmpty, !seen.contains(identity) else { return }
            seen.insert(identity)
            out.append(DetailField(key: k, value: v))
        }

        // 1. Explicit "Label: value" pairs — real, self-describing structure.
        if let re = labeledFieldRe {
            for m in re.matches(in: scanned, range: NSRange(location: 0, length: ns.length)) {
                guard m.numberOfRanges >= 3 else { continue }
                add(ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
            }
        }

        // 2. Identifiers and amounts, which carry meaning without a label.
        if let re = referenceCodeRe {
            for m in re.matches(in: scanned, range: NSRange(location: 0, length: ns.length)).prefix(6) {
                add("Reference", ns.substring(with: m.range))
            }
        }
        if let re = moneyRe {
            for m in re.matches(in: scanned, range: NSRange(location: 0, length: ns.length)).prefix(6) {
                add("Amount", ns.substring(with: m.range))
            }
        }

        // 3. Named entities — the one kind of content no pattern can
        //    express, and already on-device via NLTagger.
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = scanned
        var entityCount = 0
        tagger.enumerateTags(in: scanned.startIndex..<scanned.endIndex, unit: .word,
                             scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            guard entityCount < 8 else { return false }
            guard let tag else { return true }
            let key: String
            switch tag {
            case .personalName:     key = "Name"
            case .organizationName: key = "Organization"
            case .placeName:        key = "Place"
            default:                return true
            }
            let before = out.count
            add(key, String(scanned[range]))
            if out.count > before { entityCount += 1 }
            return true
        }

        return out
    }
}

/// Owns instant extraction results per item: run once at capture, read
/// back when the Details panel opens.
///
/// Results are cached in memory rather than persisted — recomputing is
/// microseconds, and adding a field to the stored item would migrate the
/// on-disk history schema for something that cheap to rebuild.
@MainActor
final class InstantExtractionService {
    static let shared = InstantExtractionService()

    private var fields: [UUID: [DetailField]] = [:]
    /// Separate from `fields`: an item that legitimately yielded nothing
    /// must not be re-extracted on every panel open.
    private var completed = Set<UUID>()

    private init() {}

    func fields(for id: UUID) -> [DetailField]? { fields[id] }

    func invalidate(_ id: UUID) {
        fields[id] = nil
        completed.remove(id)
    }

    /// Fire-and-forget, once ever per item. Runs off the main thread: this
    /// is on the path of every single copy, and the main thread is also
    /// the event tap's thread — a pasted log file must never be able to
    /// stall a keystroke.
    func extractIfNeeded(item: ClipboardItem) {
        guard !completed.contains(item.id) else { return }
        completed.insert(item.id)

        // Both sources, for the same reason the importance scorer reads
        // both: a screenshot has only OCR, an HTML clip only plain text.
        let sources = [item.content.plainText, item.ocrText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !sources.isEmpty else {
            // No text yet — an image still awaiting OCR. Allow a later
            // pass once OCR lands.
            completed.remove(item.id)
            return
        }
        let text = sources.joined(separator: "\n")
        let id = item.id

        DispatchQueue.global(qos: .userInitiated).async {
            let extracted = InstantStructuredExtractor.extract(from: text)
            guard !extracted.isEmpty else { return }
            Task { @MainActor in
                InstantExtractionService.shared.fields[id] = extracted
                // The panel may already be open on this item — an image
                // whose OCR just landed is the common case.
                ClipboardManager.shared.refreshDetailsPanelIfShowing(itemID: id)
            }
        }
    }
}
