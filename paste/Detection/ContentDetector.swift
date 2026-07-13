import AppKit

enum ContentDetector {
    static func detectedColor(for content: ClipboardContent) -> NSColor? {
        TextTraditionalDetectors.color(from: content)
    }

    static func detectedType(for content: ClipboardContent, color: NSColor?) -> ClipboardContentType {
        guard case .text(let text) = content else { return .plain }

        let traditional = TextTraditionalDetectors.candidates(for: text, color: color)
        return traditional.max(by: { $0.confidence < $1.confidence })?.type ?? .plain
    }
}
