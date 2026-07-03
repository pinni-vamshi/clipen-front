import AppKit

enum ContentDetector {
    static func detectedColor(for content: ClipboardContent) -> NSColor? {
        TextTraditionalDetectors.color(from: content)
    }

    static func detectedType(for content: ClipboardContent, color: NSColor?) -> ClipboardContentType {
        guard case .text(let text) = content else { return .plain }

        // Deterministic detectors only — highest-confidence match wins, else plain.
        let traditional = TextTraditionalDetectors.candidates(for: text, color: color)
        return traditional.max(by: { $0.confidence < $1.confidence })?.type ?? .plain
    }

    static func category(for item: ClipboardItem) -> ClipboardCategory {
        switch item.content {
        case .image:
            return .image
        case .html:
            return .html
        case .richText, .rtfd:
            return .richText
        case .file(let url):
            return FileKindDetector.isImageFile(url) ? .image : .file
        case .files(let urls):
            return !urls.isEmpty && urls.allSatisfy(FileKindDetector.isImageFile) ? .image : .file
        case .text:
            return category(for: item.detectedType)
        case .svg, .blob:
            return .file
        }
    }

    private static func category(for type: ClipboardContentType) -> ClipboardCategory {
        switch type {
        case .url:      return .url
        case .json:     return .json
        case .latex:    return .latex
        case .markdown: return .markdown
        case .table:    return .table
        case .email,
             .phone,
             .address:  return .contact
        case .code:     return .code
        case .hexColor: return .color
        case .plain:    return .text
        }
    }
}
