import Foundation

/// Lightweight semantic fallback for content that does not have a strict
/// syntax signature. This is intentionally local and heuristic: no clipboard
/// content leaves the device.
enum TextSemanticDetector {
    static func candidates(for text: String) -> [DetectionCandidate] {
        let lowered = text.lowercased()
        guard lowered.count >= 12 else { return [] }

        var candidates: [DetectionCandidate] = []

        if score(lowered, keywords: ["street", "avenue", "road", "suite", "apartment", "zip code", "postal", "near"]) >= 2 {
            candidates.append(.init(type: .address, confidence: 0.58, method: .semantic))
        }

        if score(lowered, keywords: ["select", "insert", "update", "delete from", "join", "where", "database", "table"]) >= 2 {
            candidates.append(.init(type: .code("SQL"), confidence: 0.56, method: .semantic))
        }

        if score(lowered, keywords: ["function", "variable", "class", "return", "async", "import", "console", "struct"]) >= 2 {
            candidates.append(.init(type: .code("Code"), confidence: 0.54, method: .semantic))
        }

        if score(lowered, keywords: ["equation", "integral", "summation", "matrix", "theorem", "proof", "alpha", "lambda"]) >= 2 {
            candidates.append(.init(type: .latex, confidence: 0.52, method: .semantic))
        }

        if score(lowered, keywords: ["heading", "bullet", "checklist", "markdown", "readme", "link", "section"]) >= 2 {
            candidates.append(.init(type: .markdown, confidence: 0.5, method: .semantic))
        }

        return candidates
    }

    private static func score(_ text: String, keywords: [String]) -> Int {
        keywords.reduce(0) { count, keyword in
            count + (text.contains(keyword) ? 1 : 0)
        }
    }
}
