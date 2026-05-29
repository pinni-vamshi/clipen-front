import AppKit
import Foundation

/// Assigns EXACTLY ONE tag per clipboard item.
///
/// Rebuilt as a single-tag classifier: each item lands in one — and only one —
/// category, so the filter chips never smear an item across multiple buckets
/// (the old multi-tag system put a `.swift` file under Image, a GitHub URL
/// under Address, etc.).  Detection is purely structural (pasteboard shape) +
/// deterministic regex/syntax detectors in `TextTraditionalDetectors`.  No
/// fuzzy/semantic keyword scoring — that was the source of the cross-category
/// pollution.
enum TagDetector {
    /// Public API kept array-shaped so existing call sites (filtering,
    /// `availableTags`, `ItemTagStrip`) are unchanged — the array always holds
    /// exactly one element.
    static func tags(for content: ClipboardContent, color: NSColor?) -> [ClipboardTag] {
        [tag(for: content, color: color)]
    }

    static func primaryTag(from tags: [ClipboardTag]) -> ClipboardTag {
        tags.first ?? .text
    }

    /// The single tag for an item.
    static func tag(for content: ClipboardContent, color: NSColor?) -> ClipboardTag {
        switch content {
        case .image(_, _, let dataType):
            return dataType.rawValue.localizedCaseInsensitiveContains("pdf") ? .pdf : .image

        case .file(let url):
            return fileTag(for: url)

        case .files(let urls):
            return filesTag(for: urls)

        case .html(_, plain: let plain):
            return textTag(for: plain, color: nil) ?? .html

        case .richText(_, plain: let plain):
            return textTag(for: plain, color: nil) ?? .richText

        case .text(let s):
            // A bare path to a real file on disk is tagged by what it points to.
            if let url = resolvedLocalFileURL(from: s) {
                return fileTag(for: url)
            }
            return textTag(for: s, color: color) ?? .text
        }
    }

    // MARK: - Text (deterministic detectors only)

    /// Highest-confidence traditional/regex tag for `plain`, or nil when the
    /// text is ordinary prose with no structural signature.
    private static func textTag(for plain: String, color: NSColor?) -> ClipboardTag? {
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let candidates = TextTraditionalDetectors.candidates(for: plain, color: color)
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }),
              let tag = ClipboardTag.from(best.type) else { return nil }
        return tag
    }

    // MARK: - Files

    /// Most specific tag for a single file URL.
    private static func fileTag(for url: URL) -> ClipboardTag {
        if url.pathExtension.lowercased() == "pdf" { return .pdf }
        if FileKindDetector.isImageFile(url) { return .image }
        if FileKindDetector.isVideoFile(url) { return .video }
        if FileKindDetector.isAudioFile(url) { return .audio }
        return .file
    }

    /// A multi-file bundle: collapse to the shared type if homogeneous,
    /// otherwise the generic `.files` tag.
    private static func filesTag(for urls: [URL]) -> ClipboardTag {
        guard !urls.isEmpty else { return .files }
        if urls.allSatisfy(FileKindDetector.isImageFile) { return .image }
        if urls.allSatisfy(FileKindDetector.isVideoFile) { return .video }
        if urls.allSatisfy(FileKindDetector.isAudioFile) { return .audio }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "pdf" }) { return .pdf }
        return .files
    }

    /// Returns a URL if `string` is a single local file path that exists on disk.
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
