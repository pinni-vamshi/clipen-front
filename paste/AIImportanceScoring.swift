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
    private static let detector = try? NSDataDetector(types:
        NSTextCheckingResult.CheckingType.date.rawValue
        | NSTextCheckingResult.CheckingType.phoneNumber.rawValue
        | NSTextCheckingResult.CheckingType.address.rawValue)

    struct Counts { var dates = 0; var phones = 0; var addresses = 0 }

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
    static let autoAnalysisLengthCeiling = 8_000

    @Published private(set) var breakdowns: [UUID: ImportanceBreakdown] = [:]

    private init() {}

    @discardableResult
    func evaluate(_ item: ClipboardItem) -> ImportanceBreakdown {
        if let cached = breakdowns[item.id], !cached.isIndeterminate { return cached }

        let threshold = ImportanceWeightsStore.shared.threshold
        let sourceText = item.content.plainText ?? item.ocrText
        let trimmed = (sourceText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

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

        let evidence = Self.bestChunkEvidence(in: trimmed)
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

    /// Scores each ~200-character chunk of `text` independently and
    /// returns only the densest chunk's evidence. A short text is a
    /// single chunk, so nothing changes for the cases that were already
    /// working; a long text is judged by its best paragraph, not by the
    /// sum of matches spread across everything around it.
    private static func bestChunkEvidence(in text: String) -> [ImportanceSignal] {
        let chunks = ChunkSplitter.chunks(of: text)
        guard chunks.count > 1 else { return ExtractableEntityDetector.gather(from: text) }

        var best: [ImportanceSignal] = []
        var bestTotal = -1.0
        for chunk in chunks {
            let signals = ExtractableEntityDetector.gather(from: String(chunk))
            let total = min(1.0, signals.reduce(0) { $0 + $1.points })
            if total > bestTotal {
                bestTotal = total
                best = signals
            }
        }
        return best
    }
}
