import AppKit
import Foundation

/// Assigns multiple tags per clipboard item using existing detectors on plain
/// text plus structural tags from pasteboard content (image, file, html, …).
enum TagDetector {
    /// Minimum confidence to attach a text-derived tag.
    private static let minConfidence: Double = 0.5

    static func tags(for content: ClipboardContent, color: NSColor?) -> [ClipboardTag] {
        var found = Set<ClipboardTag>()
        appendStructuralTags(for: content, into: &found)
        if let plain = plainText(from: content), !plain.isEmpty {
            appendTextTags(plain: plain, color: color, into: &found)
            if hasLocalFilePath(in: plain) {
                found.insert(.file)
            }
        }
        if found.isEmpty {
            found.insert(.text)
        }
        return found.sorted { $0.priority < $1.priority }
    }

    static func primaryTag(from tags: [ClipboardTag]) -> ClipboardTag {
        tags.first ?? .text
    }

    // MARK: - Structural (pasteboard shape)

    private static func appendStructuralTags(for content: ClipboardContent, into found: inout Set<ClipboardTag>) {
        switch content {
        case .image(_, _, let dataType):
            if dataType.rawValue.localizedCaseInsensitiveContains("pdf") {
                found.insert(.pdf)
            } else {
                found.insert(.image)
            }
        case .file(let url):
            if url.pathExtension.lowercased() == "pdf" {
                found.insert(.pdf)
            } else if FileKindDetector.isImageFile(url) {
                found.insert(.image)
            } else if FileKindDetector.isVideoFile(url) {
                found.insert(.video)
            } else if FileKindDetector.isAudioFile(url) {
                found.insert(.audio)
            } else {
                found.insert(.file)
            }
        case .files(let urls):
            found.insert(.files)
            if !urls.isEmpty, urls.allSatisfy(FileKindDetector.isImageFile) {
                found.insert(.image)
            }
        case .html:
            found.insert(.html)
        case .richText:
            found.insert(.richText)
        case .text:
            break
        }
    }

    // MARK: - Plain-text detectors (existing pipeline)

    private static func appendTextTags(plain: String, color: NSColor?, into found: inout Set<ClipboardTag>) {
        let traditional = TextTraditionalDetectors.candidates(for: plain, color: color)
        let semantic = TextSemanticDetector.candidates(for: plain)
        var bestByTag: [ClipboardTag: Double] = [:]

        for candidate in traditional + semantic {
            guard candidate.confidence >= minConfidence,
                  let tag = ClipboardTag.from(candidate.type) else { continue }
            bestByTag[tag] = max(bestByTag[tag] ?? 0, candidate.confidence)
        }

        for (tag, _) in bestByTag {
            found.insert(tag)
        }

        // Plain prose with no strong signal still gets .text when nothing else matched.
        if bestByTag.isEmpty, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            found.insert(.text)
        }
    }

    private static func plainText(from content: ClipboardContent) -> String? {
        switch content {
        case .text(let s):
            return s
        case .richText(_, plain: let s), .html(_, plain: let s):
            return s
        default:
            return nil
        }
    }

    private static func hasLocalFilePath(in string: String) -> Bool {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\n") else { return false }
        let url: URL
        if raw.hasPrefix("file://"), let parsed = URL(string: raw), parsed.isFileURL {
            url = parsed
        } else if raw.hasPrefix("/") || raw.hasPrefix("~") {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }
}
