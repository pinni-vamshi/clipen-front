import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit

struct ContentPreviewView: View {
    enum Chrome {
        case panel
        case reference
    }
    let item: ClipboardItem
    let chrome: Chrome

    private var plainFontSize: CGFloat { chrome == .panel ? 13 : 12 }
    @State private var selectedFileForFullPreview: URL? = nil

    @ViewBuilder
    var body: some View {
        switch item.content {
        case .text(let text):
            if let url = Self.validWebURL(text) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(url.absoluteString)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    Divider()
                    WebsitePreview(url: url)
                }
            } else {
                RichLinkedPreview(computeLinks: { LinkExtractor.links(fromPlainText: text) }, plainText: text,
                                  insightID: item.id, diff: item.diffDetail) {
                    RichTextContentPreview(text: text, detectedType: item.detectedType)
                }
            }
        case .richText(let attrStr, _):
            let adjusted = attrStr.adjustingColorsForCurrentAppearance()
            RichLinkedPreview(computeLinks: { LinkExtractor.links(from: adjusted) }, plainText: adjusted.string,
                              insightID: item.id) {
                AttributedTextPreview(attributedString: adjusted)
            }
        case .html(let html, let plain):
            if plain.isEmpty && html.isEmpty {
                textPreview(plain, monospaced: false)
            } else {
                RichLinkedPreview(computeLinks: { LinkExtractor.links(fromHTML: html) }, plainText: plain,
                                  insightID: item.id) {
                    HTMLStringPreview(html: html)
                }
            }
        case .rtfd(let data, let plain):
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let adjusted = AdjustedAttrCache.shared.adjustedRTFD(itemID: item.id, data: data, isDark: isDark) {
                RichLinkedPreview(computeLinks: { LinkExtractor.links(from: adjusted) }, plainText: plain,
                                  insightID: item.id) {
                    AttributedTextPreview(attributedString: adjusted)
                }
            } else {
                textPreview(plain, monospaced: false)
            }
        case .image(let image, let data, let dataType):
            imagePreview(image: image, data: data, dataType: dataType)
        case .file(let url):
            FilePreviewContent(url: url)
        case .files(let urls):
            filesPreview(urls)
        case .svg(let src):
            textPreview(src, monospaced: true)
        case .blob(let typeMap):
            BlobContentPreview(typeMap: typeMap)
        case .group(let items):

            MultiItemPreviewView(items: items, showsHeader: false)
        }
    }

    @ViewBuilder
    private func imagePreview(image: NSImage, data: Data, dataType: NSPasteboard.PasteboardType) -> some View {
        switch chrome {
        case .panel:
            if dataType.rawValue.contains("pdf"), let pdf = PDFDocument(data: data) {
                PDFPreview(document: pdf)
            } else if dataType.rawValue.contains("gif") {
                ZoomableImagePreview(image: image, animatedData: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ZoomableImagePreview(image: image, fullResData: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
        case .reference:
            if dataType.rawValue.contains("pdf"), let pdf = PDFDocument(data: data) {
                PDFPreview(document: pdf)
                    .cornerRadius(8)
            } else if dataType.rawValue.contains("gif") {
                ZoomableImagePreview(image: image, animatedData: data)
                    .cornerRadius(8)
            } else {
                ZoomableImagePreview(image: image, fullResData: data)
                    .cornerRadius(8)
            }
        }
    }

    private func textPreview(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Text(text.displayTrimmedLeading)
                .font(.system(size: plainFontSize, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func fileListPreview(_ urls: [URL]) -> some View {
        switch chrome {
        case .panel:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(urls, id: \.path) { url in
                        HStack(spacing: 10) {
                            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                                .resizable()
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(url.deletingLastPathComponent().path)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        case .reference:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(urls, id: \.path) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func filesPreview(_ urls: [URL]) -> some View {
        ZStack {
            VStack(spacing: 0) {
                fileListPreview(urls)
                let visualURLs = urls.filter { !FileKindDetector.isTextFile($0) }
                if !visualURLs.isEmpty {
                    Divider()
                    elementThumbnailStrip(visualURLs)
                }
            }
            if let selected = selectedFileForFullPreview {
                singleElementOverlay(url: selected)
            }
        }
    }

    private func elementThumbnailStrip(_ urls: [URL]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.path) { url in
                    Button {
                        selectedFileForFullPreview = url
                    } label: {
                        elementThumbnail(url)
                    }
                    .buttonStyle(.plain)
                    .help(url.lastPathComponent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
        }
        .frame(height: 76)
    }

    @ViewBuilder
    private func elementThumbnail(_ url: URL) -> some View {
        Group {
            if FileKindDetector.isImageFile(url), let img = NSImage(contentsOf: url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                    .resizable().aspectRatio(contentMode: .fit).padding(14)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private func singleElementOverlay(url: URL) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .onTapGesture { selectedFileForFullPreview = nil }
            VStack(spacing: 0) {
                HStack {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        selectedFileForFullPreview = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(10)
                FilePreviewContent(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 10)
                Button {
                    ClipboardManager.shared.pasteSingleFile(url)
                    selectedFileForFullPreview = nil
                } label: {
                    Text("Paste").font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                .padding(10)
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(20)
        }
    }

    static func validWebURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), !t.contains("\r"),
              let url = URL(string: t),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }
}

enum ContentSegment: Equatable {
    case text(String)
    case table([[String]])
}

enum TableCellExtractor {
    private static let cache: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        c.countLimit = 500
        return c
    }()

    static func invalidate(itemID: UUID) {
        cache.removeObject(forKey: itemID as NSUUID)
    }

    static func cells(for item: ClipboardItem) -> [[String]]? {
        if let cached = cache.object(forKey: item.id as NSUUID) as? [[String]] {
            return cached.isEmpty ? nil : cached
        }
        let result = extract(for: item) ?? []
        cache.setObject(result as NSArray, forKey: item.id as NSUUID)
        return result.isEmpty ? nil : result
    }

    static func plainTableHTML(for item: ClipboardItem) -> (html: String, plain: String)? {
        guard let rows = cells(for: item) else { return nil }
        let html = "<table>" + rows.map { row in
            "<tr>" + row.map { "<td>\($0.htmlEscaped)</td>" }.joined() + "</tr>"
        }.joined() + "</table>"
        let plain = rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        return (html, plain)
    }

    private static func extract(for item: ClipboardItem) -> [[String]]? {
        switch item.content {
        case .richText(let attr, _):
            return cells(from: attr)
        case .rtfd(let data, _):
            guard let attr = NSAttributedString(rtfd: data, documentAttributes: nil) else { return nil }
            return cells(from: attr)
        case .html(let html, _):
            return cells(fromHTML: html)
        default:
            return nil
        }
    }

    static func tabSeparatedPlainText(from attr: NSAttributedString) -> String? {
        guard let rows = cells(from: attr) else { return nil }
        return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    static func cells(from attr: NSAttributedString) -> [[String]]? {
        var grid: [Int: [Int: String]] = [:]
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  let cell = style.textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
            else { return }
            let text = (attr.string as NSString).substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = grid[cell.startingRow]?[cell.startingColumn] ?? ""
            grid[cell.startingRow, default: [:]][cell.startingColumn] =
                existing.isEmpty ? text : existing + " " + text
        }
        guard !grid.isEmpty else { return nil }
        return grid.keys.sorted().map { r in
            let cols = grid[r] ?? [:]
            return cols.keys.sorted().map { cols[$0] ?? "" }
        }
    }

    private static func cells(fromHTML html: String) -> [[String]]? {
        let opts: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
        guard let rowRe = try? NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: opts),
              let cellRe = try? NSRegularExpression(pattern: "<t[dh][^>]*>(.*?)</t[dh]>", options: opts)
        else { return nil }
        let ns = html as NSString
        var rows: [[String]] = []
        for rowMatch in rowRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let rowHTML = ns.substring(with: rowMatch.range(at: 1))
            let rowNS = rowHTML as NSString
            var cells: [String] = []
            for cellMatch in cellRe.matches(in: rowHTML, range: NSRange(location: 0, length: rowNS.length)) {
                let raw = rowNS.substring(with: cellMatch.range(at: 1))
                let text = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                    .htmlDecoded
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(text)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        return rows.isEmpty ? nil : rows
    }

    static func segments(for item: ClipboardItem) -> [ContentSegment]? {
        let result: [ContentSegment]?
        switch item.content {
        case .richText(let attr, _):
            result = segments(from: attr)
        case .rtfd(let data, _):
            guard let attr = NSAttributedString(rtfd: data, documentAttributes: nil) else { return nil }
            result = segments(from: attr)
        case .html(let html, _):
            result = segmentsFromHTML(html)
        default:
            return nil
        }
        guard let segs = result, segs.count > 1,
              segs.contains(where: { if case .text = $0 { return true }; return false }),
              segs.contains(where: { if case .table = $0 { return true }; return false })
        else { return nil }
        return segs
    }

    private static func segmentsFromHTML(_ html: String) -> [ContentSegment]? {
        let tablePattern = "<table[^>]*>.*?</table>"
        guard let tableRe = try? NSRegularExpression(
            pattern: tablePattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators])
        else { return nil }
        let ns = html as NSString
        let matches = tableRe.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var segments: [ContentSegment] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let plain = Self.stripHTMLTags(chunk).trimmingCharacters(in: .whitespacesAndNewlines)
                if !plain.isEmpty { segments.append(.text(plain)) }
            }
            let tableHTML = ns.substring(with: m.range)
            if let rows = cells(fromHTML: tableHTML), !rows.isEmpty {
                segments.append(.table(rows))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let chunk = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            let plain = Self.stripHTMLTags(chunk).trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty { segments.append(.text(plain)) }
        }
        return segments.isEmpty ? nil : segments
    }

    private static func segments(from attr: NSAttributedString) -> [ContentSegment]? {
        guard attr.length > 0 else { return nil }
        let full = NSRange(location: 0, length: attr.length)
        struct Run { let range: NSRange; let block: NSTextTableBlock? }
        var runs: [Run] = []
        attr.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let block = (value as? NSParagraphStyle)?
                .textBlocks.first(where: { $0 is NSTextTableBlock }) as? NSTextTableBlock
            runs.append(Run(range: range, block: block))
        }
        guard runs.contains(where: { $0.block != nil }) else { return nil }

        var segments: [ContentSegment] = []
        var i = 0
        while i < runs.count {
            if let firstBlock = runs[i].block {
                let currentTable = firstBlock.table
                var grid: [Int: [Int: String]] = [:]
                while i < runs.count, let b = runs[i].block, b.table === currentTable {
                    let text = (attr.string as NSString).substring(with: runs[i].range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let existing = grid[b.startingRow]?[b.startingColumn] ?? ""
                    grid[b.startingRow, default: [:]][b.startingColumn] =
                        existing.isEmpty ? text : existing + " " + text
                    i += 1
                }
                if !grid.isEmpty {
                    let rows = grid.keys.sorted().compactMap { r -> [String]? in
                        guard let cols = grid[r] else { return nil }
                        return cols.keys.sorted().map { cols[$0] ?? "" }
                    }
                    segments.append(.table(rows))
                }
            } else {
                var parts: [String] = []
                while i < runs.count, runs[i].block == nil {
                    parts.append((attr.string as NSString).substring(with: runs[i].range))
                    i += 1
                }
                let combined = parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !combined.isEmpty { segments.append(.text(combined)) }
            }
        }
        return segments.isEmpty ? nil : segments
    }

    private static func stripHTMLTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .htmlDecoded
    }
}

enum EmbeddedImageExtractor {
    private static let cache: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        c.countLimit = 300
        return c
    }()

    static func invalidate(itemID: UUID) {
        cache.removeObject(forKey: itemID as NSUUID)
    }

    static func firstImage(for item: ClipboardItem) -> NSImage? {
        if let cached = cache.object(forKey: item.id as NSUUID) as? [NSImage] {
            return cached.first
        }
        let result = extract(for: item)
        cache.setObject((result.map { [$0] } ?? []) as NSArray, forKey: item.id as NSUUID)
        return result
    }

    private static func extract(for item: ClipboardItem) -> NSImage? {
        switch item.content {
        case .richText(let attr, _):
            return firstImage(in: attr)
        case .rtfd(let data, _):
            guard let attr = NSAttributedString(rtfd: data, documentAttributes: nil) else { return nil }
            return firstImage(in: attr)
        default:
            return nil
        }
    }

    private static func firstImage(in attr: NSAttributedString) -> NSImage? {
        var found: NSImage?
        let full = NSRange(location: 0, length: attr.length)
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            guard found == nil, let attachment = value as? NSTextAttachment else { return }
            if let image = attachment.image {
                found = image
                stop.pointee = true
            } else if let wrapperData = attachment.fileWrapper?.regularFileContents,
                      let image = NSImage(data: wrapperData) {
                found = image
                stop.pointee = true
            }
        }
        return found
    }
}

final class WebsitePreviewPool {
    static let shared = WebsitePreviewPool()
    private init() {}

    private final class Entry {
        let webView: WKWebView
        var lastUsed: Date
        init(webView: WKWebView, lastUsed: Date) { self.webView = webView; self.lastUsed = lastUsed }
    }

    private var entries: [String: Entry] = [:]

    private let maxPoolSize = 7

    private func makeWebView() -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsMagnification = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func webView(for url: URL) -> WKWebView {
        assert(Thread.isMainThread, "WKWebView must only be touched on the main thread")
        let k = url.absoluteString
        if let entry = entries[k] {
            entry.lastUsed = Date()
            return entry.webView
        }
        evictLeastRecentlyUsedIfNeeded()
        let view = makeWebView()
        entries[k] = Entry(webView: view, lastUsed: Date())
        view.load(URLRequest(url: url, timeoutInterval: 10))
        return view
    }

    func hasPooledView(for url: URL) -> Bool { entries[url.absoluteString] != nil }

    func prefetch(url: URL) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.prefetch(url: url) }
            return
        }
        guard !hasPooledView(for: url) else { return }
        _ = webView(for: url)
    }

    private func evictLeastRecentlyUsedIfNeeded() {
        guard entries.count >= maxPoolSize,
              let oldestKey = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
        else { return }
        let evicted = entries.removeValue(forKey: oldestKey)
        evicted?.webView.stopLoading()
        evicted?.webView.removeFromSuperview()
    }
}

struct WebsitePreview: NSViewRepresentable {
    let url: URL

    var reloadToken: Int = 0

    final class Coordinator: NSObject, WKNavigationDelegate {
        var progressView: NSProgressIndicator?
        var lastLoadKey: String?
        var lastURL: URL?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            progressView?.isHidden = false
            progressView?.startAnimation(nil)
        }
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            progressView?.stopAnimation(nil)
            progressView?.isHidden = true
        }
        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            progressView?.stopAnimation(nil)
            progressView?.isHidden = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private static func attach(_ webView: WKWebView, to container: NSView, delegate: WKNavigationDelegate) {
        container.subviews.filter { $0 is WKWebView }.forEach { $0.removeFromSuperview() }
        webView.removeFromSuperview()
        webView.navigationDelegate = delegate
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let wasAlreadyPooled = WebsitePreviewPool.shared.hasPooledView(for: url)
        let webView = WebsitePreviewPool.shared.webView(for: url)
        Self.attach(webView, to: container, delegate: context.coordinator)

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        context.coordinator.progressView = progress
        context.coordinator.lastLoadKey = "\(url.absoluteString)#\(reloadToken)"
        context.coordinator.lastURL = url

        if wasAlreadyPooled && !webView.isLoading {

            progress.isHidden = true
        } else {
            progress.startAnimation(nil)
        }
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let key = "\(url.absoluteString)#\(reloadToken)"
        guard context.coordinator.lastLoadKey != key else { return }
        let urlChanged = context.coordinator.lastURL != url
        context.coordinator.lastLoadKey = key
        context.coordinator.lastURL = url

        let wasAlreadyPooled = WebsitePreviewPool.shared.hasPooledView(for: url)
        let webView = WebsitePreviewPool.shared.webView(for: url)
        if webView.superview !== container {
            Self.attach(webView, to: container, delegate: context.coordinator)
        }

        if !urlChanged {

            context.coordinator.progressView?.isHidden = false
            context.coordinator.progressView?.startAnimation(nil)
            webView.load(URLRequest(url: url, timeoutInterval: 10))
        } else if wasAlreadyPooled && !webView.isLoading {
            context.coordinator.progressView?.isHidden = true
            context.coordinator.progressView?.stopAnimation(nil)
        } else {
            context.coordinator.progressView?.isHidden = false
            context.coordinator.progressView?.startAnimation(nil)
        }
    }
}

final class AdjustedAttrCache {
    static let shared = AdjustedAttrCache()
    private let lock = NSLock()
    private var byObject: [ObjectIdentifier: (isDark: Bool, adjusted: NSAttributedString)] = [:]
    private var byItemID: [UUID: (isDark: Bool, adjusted: NSAttributedString)] = [:]

    func adjusted(for source: NSAttributedString, isDark: Bool,
                  compute: () -> NSAttributedString) -> NSAttributedString {
        let key = ObjectIdentifier(source)
        lock.lock()
        if let hit = byObject[key], hit.isDark == isDark {
            let value = hit.adjusted
            lock.unlock()
            return value
        }
        lock.unlock()
        let computed = compute()
        lock.lock()
        byObject[key] = (isDark, computed)
        if byObject.count > 64, let stale = byObject.first?.key { byObject.removeValue(forKey: stale) }
        lock.unlock()
        return computed
    }

    func adjustedRTFD(itemID: UUID, data: Data, isDark: Bool) -> NSAttributedString? {
        lock.lock()
        if let hit = byItemID[itemID], hit.isDark == isDark {
            let value = hit.adjusted
            lock.unlock()
            return value
        }
        lock.unlock()
        guard let decoded = NSAttributedString(rtfd: data, documentAttributes: nil) else { return nil }
        let adjusted = decoded.adjustingColorsForCurrentAppearance()
        lock.lock()
        byItemID[itemID] = (isDark, adjusted)
        if byItemID.count > 64, let stale = byItemID.first?.key { byItemID.removeValue(forKey: stale) }
        lock.unlock()
        return adjusted
    }

    func invalidate(itemID: UUID) {
        lock.lock()
        byItemID.removeValue(forKey: itemID)
        lock.unlock()
    }
}

extension NSAttributedString {
    func adjustingColorsForCurrentAppearance() -> NSAttributedString {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return AdjustedAttrCache.shared.adjusted(for: self, isDark: isDarkMode) {

            var needsWork = false
            self.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: self.length), options: []) { value, _, stop in
                guard let color = value as? NSColor,
                      let rgb = color.usingColorSpace(.deviceRGB) else { return }
                let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                if (isDarkMode && lum < 0.25) || (!isDarkMode && lum > 0.85) {
                    needsWork = true
                    stop.pointee = true
                }
            }
            guard needsWork else { return self }

            let mutable = NSMutableAttributedString(attributedString: self)
            mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
                guard let color = value as? NSColor,
                      let rgb = color.usingColorSpace(.deviceRGB) else { return }
                let lum = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
                if isDarkMode && lum < 0.25 {
                    mutable.addAttribute(.foregroundColor, value: NSColor.white, range: range)
                } else if !isDarkMode && lum > 0.85 {
                    mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                }
            }
            return mutable
        }
    }
}
