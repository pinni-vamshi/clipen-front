import AppKit
import Foundation

enum TextTraditionalDetectors {
    static func color(from content: ClipboardContent) -> NSColor? {
        guard case .text(let s) = content else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 4 else { return nil }
        let hex = String(t.dropFirst())
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return NSColor(hexString: t)
    }

    static func candidates(for text: String, color: NSColor?) -> [DetectionCandidate] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }

        var candidates: [DetectionCandidate] = []

        if let color {
            candidates.append(.init(type: .hexColor(color), confidence: 1.0, method: .deterministic))
        }

        if (t.hasPrefix("http://") || t.hasPrefix("https://")),
           let url = URL(string: t), url.host != nil {
            candidates.append(.init(type: .url, confidence: 0.98, method: .deterministic))
        }

        if isEmail(t) {
            candidates.append(.init(type: .email, confidence: 0.97, method: .deterministic))
        }

        if isPhoneNumber(t) {
            candidates.append(.init(type: .phone, confidence: 0.9, method: .deterministic))
        }

        if t.hasPrefix("{") || t.hasPrefix("["),
           (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil {
            candidates.append(.init(type: .json, confidence: 0.99, method: .deterministic))
        }

        if let table = detectDelimitedTable(t) {
            candidates.append(.init(type: .table(table), confidence: 0.92, method: .deterministic))
        }

        if isLatex(t) {
            candidates.append(.init(type: .latex, confidence: 0.9, method: .deterministic))
        }

        if isMarkdown(t) {
            candidates.append(.init(type: .markdown, confidence: 0.86, method: .deterministic))
        }

        if let lang = CodeLanguageDetector.detect(t) {
            candidates.append(.init(type: .code(lang), confidence: 0.84, method: .deterministic))
        }

        if isPostalAddress(t) {
            candidates.append(.init(type: .address, confidence: 0.72, method: .deterministic))
        }

        return candidates
    }

    private static func detectDelimitedTable(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2, lines.count <= 200 else { return nil }
        for (delimiter, label) in [("\t", "TSV"), (",", "CSV")] {
            let counts = lines.map { $0.split(separator: Character(delimiter), omittingEmptySubsequences: false).count }
            if let first = counts.first, first >= 2, counts.allSatisfy({ $0 == first }) {
                return label
            }
        }
        return nil
    }

    private static func isLatex(_ text: String) -> Bool {
        let keywords = ["\\begin{", "\\end{", "\\frac{", "\\sum", "\\int",
                        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\theta",
                        "\\lambda", "\\pi", "\\sigma", "\\sqrt{", "\\infty",
                        "\\text{", "\\mathbf{", "\\cdot", "\\times"]
        let inlineMath = text.hasPrefix("$") && text.hasSuffix("$") && text.count > 2
        let displayMath = text.hasPrefix("\\[") && text.hasSuffix("\\]")
        return keywords.contains(where: { text.contains($0) }) || inlineMath || displayMath
    }

    private static func isMarkdown(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return false }
        if t.hasPrefix("# ") || t.hasPrefix("## ") || t.contains("\n# ") { return true }
        if t.contains("```") || DetectionRegex.matches(#"\[[^\]]+\]\([^)]+\)"#, in: t) { return true }
        if DetectionRegex.matches(#"(?m)^\s*[-*]\s+\S+"#, in: t) ||
           DetectionRegex.matches(#"(?m)^\s*\d+\.\s+\S+"#, in: t) { return true }
        return t.contains("**") || t.contains("__")
    }

    private static func isEmail(_ text: String) -> Bool {
        DetectionRegex.matches(#"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, in: text, options: [.caseInsensitive])
    }

    private static func isPhoneNumber(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        let allowed = CharacterSet(charactersIn: "+0123456789()-. ")
        guard text.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let digits = text.filter(\.isNumber).count
        return digits >= 7 && digits <= 15
    }

    private static func isPostalAddress(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 180, t.contains(where: \.isNumber) else { return false }
        let markers = [" street", " st.", " road", " rd.", " avenue", " ave", " boulevard",
                       " blvd", " lane", " ln", " drive", " dr.", " apt", " suite", " floor"]
        return markers.contains(where: { t.contains($0) })
    }
}
