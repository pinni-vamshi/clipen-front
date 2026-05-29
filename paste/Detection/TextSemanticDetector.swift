import Foundation

/// Lightweight semantic fallback for content that does not have a strict
/// syntax signature. This is intentionally local and heuristic: no clipboard
/// content leaves the device.
///
/// These are *soft* signals scored from vocabulary, so they MUST match whole
/// words — substring matching ("table" inside "comfortable", "where" inside
/// "everywhere", "near" inside "nearly") previously tagged ordinary prose as
/// SQL/Code/Address, dumping nearly every text item into multiple categories
/// at once. Whole-word matching plus higher thresholds keeps the categories
/// meaningfully distinct; the syntax-based detectors in
/// `TextTraditionalDetectors` / `CodeLanguageDetector` remain the primary,
/// high-confidence source of structural tags.
enum TextSemanticDetector {
    static func candidates(for text: String) -> [DetectionCandidate] {
        let lowered = text.lowercased()
        guard lowered.count >= 12 else { return [] }

        // Whole-word token set, so keyword hits are real words, not substrings.
        let words = Set(lowered.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func wordHits(_ keys: [String]) -> Int {
            keys.reduce(0) { $0 + (words.contains($1) ? 1 : 0) }
        }
        // Multi-word phrases can't be tokenised — match on the raw string.
        func phraseHits(_ phrases: [String]) -> Int {
            phrases.reduce(0) { $0 + (lowered.contains($1) ? 1 : 0) }
        }

        var candidates: [DetectionCandidate] = []

        // Address — a street-type word *and* a number present.
        if wordHits(["street", "avenue", "road", "suite", "apartment",
                     "boulevard", "lane", "drive"]) >= 1,
           lowered.contains(where: \.isNumber) {
            candidates.append(.init(type: .address, confidence: 0.58, method: .semantic))
        }

        // SQL — these words overlap heavily with prose ("where", "update",
        // "select", "table"), so require strong evidence (≥3 signals).
        if wordHits(["select", "insert", "update", "join", "where",
                     "database", "table"]) + phraseHits(["delete from",
                     "group by", "order by", "inner join"]) >= 3 {
            candidates.append(.init(type: .code("SQL"), confidence: 0.56, method: .semantic))
        }

        // Code — generic programming vocabulary; require ≥3 distinct words.
        if wordHits(["function", "variable", "class", "return", "async",
                     "await", "import", "export", "console", "struct",
                     "const", "def"]) >= 3 {
            candidates.append(.init(type: .code("Code"), confidence: 0.54, method: .semantic))
        }

        // LaTeX — math vocabulary that also exists as plain words; ≥3.
        if wordHits(["equation", "integral", "summation", "matrix",
                     "theorem", "proof", "alpha", "lambda", "sigma"]) >= 3 {
            candidates.append(.init(type: .latex, confidence: 0.52, method: .semantic))
        }

        // Markdown — weak prose words; ≥3.
        if wordHits(["heading", "bullet", "checklist", "markdown",
                     "readme", "section"]) >= 3 {
            candidates.append(.init(type: .markdown, confidence: 0.5, method: .semantic))
        }

        return candidates
    }
}
