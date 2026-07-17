import AppKit
import Foundation

enum TagDetector {
    static func tags(for content: ClipboardContent, color: NSColor?) -> [ClipboardTag] {
        [tag(for: content, color: color)]
    }

    static func primaryTag(from tags: [ClipboardTag]) -> ClipboardTag {
        tags.first ?? .text
    }

    static func tag(for content: ClipboardContent, color: NSColor?) -> ClipboardTag {
        switch content {
        case .svg:                return .svg
        case .blob:               return .blob

        case .image(_, _, let dataType):
            if dataType.rawValue.localizedCaseInsensitiveContains("pdf") { return .pdf }
            if dataType.rawValue.localizedCaseInsensitiveContains("gif") { return .gif }
            return .image

        case .file(let url):
            return fileTag(for: url)

        case .files(let urls):
            return filesTag(for: urls)

        case .html(_, plain: let plain):
            return textTag(for: plain, color: nil) ?? .html

        case .richText(_, plain: let plain):
            return textTag(for: plain, color: nil) ?? .richText

        case .rtfd(_, plain: let plain):
            // No blind ".table" default here: an RTFD with an embedded image
            // attachment (Notes, Pages, Mail, TextEdit) reports its plain
            // text as just the attachment placeholder character, which never
            // matches a real detector — that used to fall through to .table
            // by elimination, mislabeling every copied image as tabular
            // data. Fall back to .richText instead, matching the sibling
            // .html/.richText cases; a genuine pasted table still gets its
            // mini-table preview from TableCellExtractor regardless of tag.
            return textTag(for: plain, color: nil) ?? .richText

        case .text(let s):
            if let url = resolvedLocalFileURL(from: s) {
                return fileTag(for: url)
            }
            return textTag(for: s, color: color) ?? .text
        }
    }

    private static func textTag(for plain: String, color: NSColor?) -> ClipboardTag? {
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let candidates = TextTraditionalDetectors.candidates(for: plain, color: color)
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }),
              let tag = ClipboardTag.from(best.type) else { return nil }
        return tag
    }

    private static func fileTag(for url: URL) -> ClipboardTag {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":             return .pdf
        case "md", "markdown":  return .markdown
        case "json":            return .json
        case "html", "htm":     return .html
        default: break
        }
        if url.pathExtension.lowercased() == "gif" { return .gif }
        if FileKindDetector.isImageFile(url)     { return .image }
        if FileKindDetector.isVideoFile(url)     { return .video }
        if FileKindDetector.isAudioFile(url)     { return .audio }
        if FileKindDetector.is3DModelFile(url)   { return .model3D }
        if FileKindDetector.isDesignFile(url)    { return .design }
        if FileKindDetector.isFontFile(url)      { return .font }
        if FileKindDetector.isArchiveFile(url)   { return .archive }
        if FileKindDetector.isInstallerFile(url) { return .installer }
        if FileKindDetector.isCodeFile(url)      { return .code }
        if FileKindDetector.isPlainTextFile(url) { return .text }
        if FileKindDetector.isDocumentFile(url)  { return .document }
        return .file
    }

    private static func filesTag(for urls: [URL]) -> ClipboardTag {
        guard !urls.isEmpty else { return .files }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) { return .pdf }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "gif" }) { return .gif }
        if urls.allSatisfy(FileKindDetector.isImageFile)     { return .image }
        if urls.allSatisfy(FileKindDetector.isVideoFile)     { return .video }
        if urls.allSatisfy(FileKindDetector.isAudioFile)     { return .audio }
        if urls.allSatisfy(FileKindDetector.is3DModelFile)   { return .model3D }
        if urls.allSatisfy(FileKindDetector.isDesignFile)    { return .design }
        if urls.allSatisfy(FileKindDetector.isFontFile)      { return .font }
        if urls.allSatisfy(FileKindDetector.isArchiveFile)   { return .archive }
        if urls.allSatisfy(FileKindDetector.isInstallerFile) { return .installer }
        if urls.allSatisfy(FileKindDetector.isCodeFile)      { return .code }
        if urls.allSatisfy(FileKindDetector.isPlainTextFile) { return .text }
        return .files
    }

    private static func resolvedLocalFileURL(from string: String) -> URL? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\n") else { return nil }
        let url: URL
        if raw.hasPrefix("file://"), let parsed = URL(string: raw), parsed.isFileURL {
            url = parsed
        } else if raw.hasPrefix("/") || raw.hasPrefix("~") {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
