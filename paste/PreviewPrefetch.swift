import AppKit
import AVFoundation
import WebKit
import QuickLookThumbnailing
@preconcurrency import PDFKit

/// Wraps a non-Sendable reference type (NSImage, PDFDocument) so it can
/// cross into/out of the `InFlightLoads` actor below. Safe here because
/// every value only ever gets written once (inside the load closure) and
/// read after that — never mutated from two places at once.
private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

/// Coalesces concurrent loads for the same key so a slow file's load only
/// ever actually runs once — no matter how many times the prefetcher
/// re-triggers for it while it's still in flight, and no matter whether
/// the "user just arrived, need it now" caller asks at the same time as a
/// background prefetch. Whoever asks second just awaits the first's result
/// instead of starting a redundant, competing load of the same file. An
/// actor rather than a lock — `NSLock` across an `await` is flagged by the
/// compiler as unsafe (a hard error under Swift 6 mode), since suspending
/// while holding a lock invites exactly the kind of deadlock/priority
/// inversion this cache exists to avoid.
private actor InFlightLoads<Value: Sendable> {
    private var tasks: [String: Task<Value?, Never>] = [:]

    func load(key: String, priority: TaskPriority, work: @escaping @Sendable () -> Value?) async -> Value? {
        if let existing = tasks[key] {
            return await existing.value
        }
        let task = Task<Value?, Never>.detached(priority: priority) { work() }
        tasks[key] = task
        let result = await task.value
        tasks[key] = nil
        return result
    }
}

/// Caches the decoded/parsed result for a file-backed preview, keyed by the
/// file's URL. Every `Async*FilePreview` view in FilePreviewRenderers.swift
/// used to reload and reparse straight from disk on every single mount —
/// even re-opening the SAME item a second time paid the full cost again.
/// This cache is the reason both re-opening an item and prefetching a
/// neighbor item ahead of time (see `PreviewPrefetcher` below) actually pay
/// off: the expensive part only ever happens once per file.
enum FilePreviewCache {
    // `nonisolated(unsafe)`, not the project's default MainActor isolation:
    // NSCache is documented thread-safe, and every one of these is read and
    // written from background prefetch tasks as well as the main actor — the
    // whole point of this cache is to be touched from wherever a load
    // happens to run, which the default isolation would otherwise forbid
    // without actually adding any real safety (NSCache already serializes
    // its own access internally).
    private nonisolated(unsafe) static let images:    NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 30; return c }()
    private nonisolated(unsafe) static let pdfs:      NSCache<NSString, PDFDocument> = { let c = NSCache<NSString, PDFDocument>(); c.countLimit = 15; return c }()
    private nonisolated(unsafe) static let gifData:   NSCache<NSString, NSData> = { let c = NSCache<NSString, NSData>(); c.countLimit = 15; return c }()
    private nonisolated(unsafe) static let gifImages: NSCache<NSString, NSImage> = { let c = NSCache<NSString, NSImage>(); c.countLimit = 15; return c }()
    private nonisolated(unsafe) static let text:      NSCache<NSString, NSString> = { let c = NSCache<NSString, NSString>(); c.countLimit = 30; return c }()
    private nonisolated(unsafe) static let textTruncated: NSCache<NSString, NSNumber> = { let c = NSCache<NSString, NSNumber>(); c.countLimit = 30; return c }()
    private nonisolated(unsafe) static let delimited: NSCache<NSString, NSArray> = { let c = NSCache<NSString, NSArray>(); c.countLimit = 30; return c }()
    private nonisolated(unsafe) static let delimitedTruncated: NSCache<NSString, NSNumber> = { let c = NSCache<NSString, NSNumber>(); c.countLimit = 30; return c }()

    private static let imageLoads = InFlightLoads<UncheckedBox<NSImage>>()
    private static let pdfLoads = InFlightLoads<UncheckedBox<PDFDocument>>()
    private static let gifLoads = InFlightLoads<GIFResult>()
    private static let textLoads = InFlightLoads<TextResult>()
    private static let delimitedLoads = InFlightLoads<DelimitedResult>()

    private nonisolated static func key(_ url: URL) -> NSString { url.absoluteString as NSString }

    // MARK: Image

    static func image(for url: URL) -> NSImage? { images.object(forKey: key(url)) }

    /// `priority` lets a foreground "user just arrived" call ask more
    /// urgently than a background prefetch would — but if a load for this
    /// URL is already in flight at any priority, this just awaits it rather
    /// than starting a second one.
    @discardableResult
    static func loadImage(for url: URL, priority: TaskPriority = .userInitiated) async -> NSImage? {
        if let cached = images.object(forKey: key(url)) { return cached }
        let boxed = await imageLoads.load(key: url.absoluteString, priority: priority) {
            guard let loaded = NSImage(contentsOf: url) else { return nil }
            images.setObject(loaded, forKey: key(url))
            return UncheckedBox(value: loaded)
        }
        return boxed?.value
    }

    // MARK: PDF

    static func pdf(for url: URL) -> PDFDocument? { pdfs.object(forKey: key(url)) }

    @discardableResult
    static func loadPDF(for url: URL, priority: TaskPriority = .userInitiated) async -> PDFDocument? {
        if let cached = pdfs.object(forKey: key(url)) { return cached }
        let boxed = await pdfLoads.load(key: url.absoluteString, priority: priority) {
            guard let loaded = PDFDocument(url: url) else { return nil }
            pdfs.setObject(loaded, forKey: key(url))
            return UncheckedBox(value: loaded)
        }
        return boxed?.value
    }

    // MARK: GIF (image + raw animated data)

    struct GIFResult: @unchecked Sendable { let image: NSImage; let data: Data }

    static func gif(for url: URL) -> (image: NSImage, data: Data)? {
        let k = key(url)
        guard let image = gifImages.object(forKey: k), let data = gifData.object(forKey: k) else { return nil }
        return (image, data as Data)
    }

    @discardableResult
    static func loadGIF(for url: URL, priority: TaskPriority = .userInitiated) async -> (image: NSImage, data: Data)? {
        if let cached = gif(for: url) { return cached }
        let result = await gifLoads.load(key: url.absoluteString, priority: priority) { () -> GIFResult? in
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
            let k = key(url)
            gifImages.setObject(image, forKey: k)
            gifData.setObject(data as NSData, forKey: k)
            return GIFResult(image: image, data: data)
        }
        return result.map { ($0.image, $0.data) }
    }

    // MARK: Plain text file

    struct TextResult: @unchecked Sendable { let text: String; let isTruncated: Bool }

    static func text(for url: URL) -> (text: String, isTruncated: Bool)? {
        let k = key(url)
        guard let t = text.object(forKey: k) else { return nil }
        return (t as String, textTruncated.object(forKey: k)?.boolValue ?? false)
    }

    @discardableResult
    static func loadText(for url: URL, priority: TaskPriority = .userInitiated) async -> (text: String, isTruncated: Bool)? {
        if let cached = text(for: url) { return cached }
        let result = await textLoads.load(key: url.absoluteString, priority: priority) { () -> TextResult? in
            guard let loaded = FileKindDetector.readableTextPreview(from: url) else { return nil }
            let k = key(url)
            text.setObject(loaded.text as NSString, forKey: k)
            textTruncated.setObject(NSNumber(value: loaded.isTruncated), forKey: k)
            return TextResult(text: loaded.text, isTruncated: loaded.isTruncated)
        }
        return result.map { ($0.text, $0.isTruncated) }
    }

    // MARK: Delimited (csv/tsv) file — rows are parsed from the same cached text

    struct DelimitedResult: @unchecked Sendable { let rows: [[String]]; let isTruncated: Bool }

    static func delimitedRows(for url: URL) -> (rows: [[String]], isTruncated: Bool)? {
        let k = key(url)
        guard let rows = delimited.object(forKey: k) as? [[String]] else { return nil }
        return (rows, delimitedTruncated.object(forKey: k)?.boolValue ?? false)
    }

    @discardableResult
    static func loadDelimitedRows(for url: URL, priority: TaskPriority = .userInitiated) async -> (rows: [[String]], isTruncated: Bool)? {
        if let cached = delimitedRows(for: url) { return cached }
        let result = await delimitedLoads.load(key: url.absoluteString, priority: priority) { () -> DelimitedResult? in
            guard let loaded = FileKindDetector.readableTextPreview(from: url) else { return nil }
            let delimiter = DelimitedTableParser.detectDelimiter(loaded.text)
            let rows = DelimitedTableParser.parse(loaded.text, delimiter: delimiter)
            let k = key(url)
            delimited.setObject(rows as NSArray, forKey: k)
            delimitedTruncated.setObject(NSNumber(value: loaded.isTruncated), forKey: k)
            return DelimitedResult(rows: rows, isTruncated: loaded.isTruncated)
        }
        return result.map { ($0.rows, $0.isTruncated) }
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
        // Background priority: a prefetch must never outrun/starve the
        // foreground "user just arrived" load for a DIFFERENT file, but if
        // it's the SAME file, loadX's in-flight coalescing means the
        // foreground call simply awaits this one instead of racing it.
        Task.detached(priority: .utility) {
            if ext == "pdf" {
                await FilePreviewCache.loadPDF(for: url, priority: .utility)
            } else if ext == "gif" {
                await FilePreviewCache.loadGIF(for: url, priority: .utility)
            } else if ["csv", "tsv"].contains(ext) {
                await FilePreviewCache.loadDelimitedRows(for: url, priority: .utility)
            } else if FileKindDetector.isTextFile(url) {
                await FilePreviewCache.loadText(for: url, priority: .utility)
            } else if FileKindDetector.isImageFile(url) {
                await FilePreviewCache.loadImage(for: url, priority: .utility)
            } else if FileKindDetector.isGLTFModelFile(url) || FileKindDetector.is3DModelFile(url) {
                // Still deliberately skipped: glTF rendering was previously
                // removed outright after causing hangs/crashes (see
                // FilePreviewRenderers.swift's isGLTFModelFile branch), and
                // native SceneKit/ModelIO loading shares the same loader
                // family. Without being able to verify what specifically
                // caused those hangs is no longer reachable from a
                // background prefetch path, guessing here risks
                // reintroducing them — left alone on purpose, not an
                // oversight.
                return
            } else if FileKindDetector.isMediaFile(url) {
                // Unlike 3D, AVFoundation's own async property loading is
                // built exactly for this — non-blocking, no known hang
                // history — so it's safe to warm here even though the
                // player view itself is never preloaded.
                let asset = AVURLAsset(url: url)
                _ = try? await asset.load(.duration, .isPlayable)
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
