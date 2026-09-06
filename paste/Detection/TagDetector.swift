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
        case .group:              return .group
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

        // Structured formats are asked about their STRUCTURE before their
        // plain-text fallback is consulted. Classifying an HTML or rich-text
        // clip purely by its flattened text is how a real table came out
        // tagged `.html`: the markup was never looked at, and the plain-text
        // table detector only recognises perfectly uniform TSV/CSV, which a
        // flattened HTML table almost never is. That tag is load-bearing —
        // `DeterministicStructuring` converts tables to JSON with no model
        // call at all, and it only runs for `.table` — so mistagging here
        // silently routed every HTML table through the slow model path.
        //
        // "Dominant" and not merely "present": a table inside a long article
        // must not retag the whole clip. See `htmlIsDominantDataTable`.
        case .html(let html, plain: let plain):
            if TableCellExtractor.htmlIsDominantDataTable(html) { return .table }
            return textTag(for: plain, color: nil) ?? .html

        case .richText(let attr, plain: let plain):
            if TableCellExtractor.attributedIsDominantDataTable(attr) { return .table }
            return textTag(for: plain, color: nil) ?? .richText

        case .rtfd(let data, plain: let plain):
            if let attr = NSAttributedString(rtfd: data, documentAttributes: nil),
               TableCellExtractor.attributedIsDominantDataTable(attr) {
                return .table
            }
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
