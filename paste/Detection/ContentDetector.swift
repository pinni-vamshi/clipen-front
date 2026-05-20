import AppKit

enum ContentDetector {
    static func detectedColor(for content: ClipboardContent) -> NSColor? {
        TextTraditionalDetectors.color(from: content)
    }

    static func detectedType(for content: ClipboardContent, color: NSColor?) -> ClipboardContentType {
        guard case .text(let text) = content else { return .plain }

        let traditional = TextTraditionalDetectors.candidates(for: text, color: color)
        if let strongTraditional = traditional
            .filter({ $0.confidence >= 0.7 })
            .max(by: { $0.confidence < $1.confidence }) {
            return strongTraditional.type
        }

        let semantic = TextSemanticDetector.candidates(for: text)
        let all = traditional + semantic
        return all.max(by: { $0.confidence < $1.confidence })?.type ?? .plain
    }

    static func category(for item: ClipboardItem) -> ClipboardCategory {
        switch item.content {
        case .image:
            return .image
        case .html:
            return .html
        case .richText:
            return .richText
        case .file(let url):
            return FileKindDetector.isImageFile(url) ? .image : .file
        case .files(let urls):
            return !urls.isEmpty && urls.allSatisfy(FileKindDetector.isImageFile) ? .image : .file
        case .text:
            return category(for: item.detectedType)
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
