import AppKit
import WebKit
import QuickLookThumbnailing
@preconcurrency import PDFKit

/// Caches the decoded/parsed result for a file-backed preview, keyed by the
/// file's URL. Every `Async*FilePreview` view in FilePreviewRenderers.swift
/// used to reload and reparse straight from disk on every single mount —
/// even re-opening the SAME item a second time paid the full cost again.
/// This cache is the reason both re-opening an item and prefetching a
/// neighbor item ahead of time (see `PreviewPrefetcher` below) actually pay
/// off: the expensive part only ever happens once per file.
enum FilePreviewCache {
    private static let images:    NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 30; return c }()
    private static let pdfs:      NSCache<NSString, PDFDocument> = { let c = NSCache<NSString, PDFDocument>(); c.countLimit = 15; return c }()
    private static let gifData:   NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.countLimit = 15; return c }()
    private static let gifImages: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 15; return c }()
    private static let text:      NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 30; return c }()
    private static let textTruncated: NSCache<NSString, NSNumber> = { let c = NSCache<NSString, NSNumber>(); c.countLimit = 30; return c }()
    private static let delimited: NSCache<NSString, NSArray> = { let c = NSCache<NSString, NSArray>(); c.countLimit = 30; return c }()
    private static let delimitedTruncated: NSCache<NSString, NSNumber> = { let c = NSCache<NSString, NSNumber>(); c.countLimit = 30; return c }()

    private static func key(_ url: URL) -> NSString { url.absoluteString as NSString }

    // MARK: Image

    static func image(for url: URL) -> NSImage? { images.object(forKey: key(url)) }

    @discardableResult
    static func loadImage(for url: URL) -> NSImage? {
        let k = key(url)
        if let cached = images.object(forKey: k) { return cached }
        guard let loaded = NSImage(contentsOf: url) else { return nil }
        images.setObject(loaded, forKey: k)
        return loaded
    }

    // MARK: PDF

    static func pdf(for url: URL) -> PDFDocument? { pdfs.object(forKey: key(url)) }

    @discardableResult
    static func loadPDF(for url: URL) -> PDFDocument? {
        let k = key(url)
        if let cached = pdfs.object(forKey: k) { return cached }
        guard let loaded = PDFDocument(url: url) else { return nil }
        pdfs.setObject(loaded, forKey: k)
        return loaded
    }

    // MARK: GIF (image + raw animated data)

    static func gif(for url: URL) -> (image: NSImage, data: Data)? {
        let k = key(url)
        guard let image = gifImages.object(forKey: k), let data = gifData.object(forKey: k) else { return nil }
        return (image, data as Data)
    }

    @discardableResult
    static func loadGIF(for url: URL) -> (image: NSImage, data: Data)? {
        if let cached = gif(for: url) { return cached }
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
        let k = key(url)
        gifImages.setObject(image, forKey: k)
        gifData.setObject(data as NSData, forKey: k)
        return (image, data)
    }

    // MARK: Plain text file

    static func text(for url: URL) -> (text: String, isTruncated: Bool)? {
        let k = key(url)
        guard let t = text.object(forKey: k) else { return nil }
        return (t as String, textTruncated.object(forKey: k)?.boolValue ?? false)
    }

    @discardableResult
    static func loadText(for url: URL) -> (text: String, isTruncated: Bool)? {
        if let cached = text(for: url) { return cached }
        guard let loaded = FileKindDetector.readableTextPreview(from: url) else { return nil }
        let k = key(url)
        text.setObject(loaded.text as NSString, forKey: k)
        textTruncated.setObject(NSNumber(value: loaded.isTruncated), forKey: k)
        return loaded
    }

    // MARK: Delimited (csv/tsv) file — rows are parsed from the same cached text

    static func delimitedRows(for url: URL) -> (rows: [[String]], isTruncated: Bool)? {
        let k = key(url)
        guard let rows = delimited.object(forKey: k) as? [[String]] else { return nil }
        return (rows, delimitedTruncated.object(forKey: k)?.boolValue ?? false)
    }

    @discardableResult
    static func loadDelimitedRows(for url: URL) -> (rows: [[String]], isTruncated: Bool)? {
        if let cached = delimitedRows(for: url) { return cached }
        guard let loaded = FileKindDetector.readableTextPreview(from: url) else { return nil }
        let delimiter = DelimitedTableParser.detectDelimiter(loaded.text)
        let rows = DelimitedTableParser.parse(loaded.text, delimiter: delimiter)
        let k = key(url)
        delimited.setObject(rows as NSArray, forKey: k)
        delimitedTruncated.setObject(NSNumber(value: loaded.isTruncated), forKey: k)
        return (rows, loaded.isTruncated)
    }
}

/// Silently prepares whatever a neighbor item's preview will need, so it's
/// already there — cached content, an already-loading PDF, an already-
/// loading website — by the time the user actually navigates to it. Called
/// for the (up to) 3 items before and 3 after the current selection while
/// the item preview panel is visible; see `ClipboardManager.prefetchNeighborPreviews()`.
enum PreviewPrefetcher {
    static func prefetch(_ item: ClipboardItem) {
        // Same lightweight metadata every capture/edit already warms —
        // cheap, and a no-op if it's already cached.
        ClipboardManager.shared.prewarmPreviewCaches(for: item)

        switch item.content {
        case .text(let text):
            guard let url = ContentPreviewView.validWebURL(text) else { return }
            DispatchQueue.main.async {
                WebsitePreviewPool.shared.prefetch(url: url)
            }

        case .file(let url):
            prefetchFile(at: url)

        case .files(let urls):
            // Bounded — a folder of many files dropped as one item shouldn't
            // fan out into dozens of background loads.
            for url in urls.prefix(3) { prefetchFile(at: url) }

        default:
            break
        }
    }

    private static func prefetchFile(at url: URL) {
        let ext = url.pathExtension.lowercased()
        DispatchQueue.global(qos: .utility).async {
            if ext == "pdf" {
                FilePreviewCache.loadPDF(for: url)
            } else if ext == "gif" {
                FilePreviewCache.loadGIF(for: url)
            } else if ["csv", "tsv"].contains(ext) {
                FilePreviewCache.loadDelimitedRows(for: url)
            } else if FileKindDetector.isTextFile(url) {
                FilePreviewCache.loadText(for: url)
            } else if FileKindDetector.isImageFile(url) {
                FilePreviewCache.loadImage(for: url)
            } else if FileKindDetector.isGLTFModelFile(url) || FileKindDetector.is3DModelFile(url)
                        || FileKindDetector.isMediaFile(url) {
                // No safe/cheap prefetch path for these today (3D loader
                // hangs were already ruled out elsewhere; media just streams
                // on demand) — deliberately skipped rather than guessed at.
                return
            } else {
                // Everything else (docs, spreadsheets, and any other type
                // the system knows how to preview) falls back to QuickLook
                // in the real preview — pre-generate its thumbnail/preview
                // representation so that system-level cache is already warm.
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 800, height: 800),
                    scale: 2, representationTypes: .all)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { _, _ in }
            }
        }
    }
}
