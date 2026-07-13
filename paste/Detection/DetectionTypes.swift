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
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> Bool {
        let key = pattern + String(options.rawValue)
        let regex: NSRegularExpression
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            regex = cached
        } else if let r = try? NSRegularExpression(pattern: pattern, options: options) {
            cache[key] = r
            lock.unlock()
            regex = r
        } else {
            lock.unlock()
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}
