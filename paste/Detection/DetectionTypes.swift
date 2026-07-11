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
    // Detection runs from ClipboardItem.init, which is called both on the main
    // thread (poll capture) and from background queues (PDF merge, file
    // bundling). Swift's Dictionary is not safe for concurrent mutation, so the
    // compiled-regex cache is guarded by a lock — the critical section is a
    // dictionary lookup/insert, so contention is negligible.
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
