import AppKit
import AVFoundation
import WebKit
import QuickLookThumbnailing
@preconcurrency import PDFKit

enum PreviewWorkQueue {
    private static let maxConcurrent: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return max(2, min(4, cores / 3))
    }()

    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.clipen.previewwork"
        q.maxConcurrentOperationCount = maxConcurrent
        q.qualityOfService = .userInitiated
        return q
    }()

    static func run(_ work: @escaping @Sendable () -> Void) {
        queue.addOperation(work)
    }
}

private struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
}

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

enum FilePreviewCache {

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

    static func image(for url: URL) -> NSImage? { images.object(forKey: key(url)) }

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

enum PreviewPrefetcher {
    static func prefetch(_ item: ClipboardItem) {

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

            for url in urls.prefix(3) { prefetchFile(at: url) }

        default:
            break
        }
    }

    private static func prefetchFile(at url: URL) {
        let ext = url.pathExtension.lowercased()

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

                return
            } else if FileKindDetector.isMediaFile(url) {

                let asset = AVURLAsset(url: url)
                _ = try? await asset.load(.duration, .isPlayable)
            } else {

                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 800, height: 800),
                    scale: 2, representationTypes: .all)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { _, _ in }
            }
        }
    }
}
