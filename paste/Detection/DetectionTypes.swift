import AppKit

enum DetectionMethod {
    case deterministic
    case semantic
}

struct DetectionCandidate {
    let type: ClipboardContentType
    let confidence: Double
    let method: DetectionMethod
}

enum DetectionRegex {
    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
