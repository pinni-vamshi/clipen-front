import AppKit
import AVKit
import Highlightr
import ModelIO
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit

final class ItemPreviewPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var shownStrip: NSRect? = nil
    private var wantsVisible = false

    var isVisible: Bool { wantsVisible && popover.isShown }
    var frame: NSRect {
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    func popoverDidShow(_ notification: Notification) {
        if !wantsVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
            return
        }
        let mainPopupVisible = ClipboardManager.shared.previewWindow.isVisible
        let quickClipVisible = ClipboardManager.shared.hasVisibleQuickClipPanel
        if !mainPopupVisible && !quickClipVisible {
            popover.performClose(nil)
            anchorPanel.orderOut(nil)
        }
    }

    override init() {
        anchorPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        anchorPanel.isOpaque = false
        anchorPanel.backgroundColor = .clear
        anchorPanel.hasShadow = false
        anchorPanel.ignoresMouseEvents = true
        anchorPanel.level = .popUpMenu
        anchorPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        anchorPanel.contentView = anchorView

        super.init()

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
    }

    func show(for item: ClipboardItem, near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        present(AnyView(ItemPreviewView(item: item)), width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func show(forItems items: [ClipboardItem], currentItemID: UUID? = nil,
              near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        guard !items.isEmpty else { hide(); return }
        present(AnyView(MultiItemPreviewView(items: items, currentItemID: currentItemID)), width: 520, height: 520,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    private func present(_ view: AnyView, width w: CGFloat, height h: CGFloat,
                         near popupFrame: NSRect, anchorPoint: NSPoint?) {
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let preferredRightX = popupFrame.maxX + 10
        let rightFits = preferredRightX + w <= screen.maxX
        let leftFits = popupFrame.minX - w - 10 >= screen.minX + 10
        let placeRight = rightFits || !leftFits

        popover.contentSize = NSSize(width: w, height: h)
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = view
        } else {
            popover.contentViewController = NSHostingController(rootView: view)
        }

        let anchorY = anchorPoint?.y ?? popupFrame.midY
        let stripHeight = max(1, popupFrame.height)
        let desiredStrip = NSRect(x: placeRight ? popupFrame.maxX : popupFrame.minX,
                                  y: popupFrame.minY, width: 1, height: stripHeight)
        let localY = max(0, min(stripHeight - 1, anchorY - desiredStrip.minY))
        let rowRect = NSRect(x: 0, y: localY, width: 1, height: 1)

        wantsVisible = true
        if popover.isShown, shownStrip == desiredStrip {
            popover.positioningRect = rowRect
            return
        }

        if popover.isShown { popover.performClose(nil) }
        anchorPanel.setFrame(desiredStrip, display: false)
        if !anchorPanel.isVisible { anchorPanel.orderFront(nil) }
        shownStrip = desiredStrip
        popover.animates = false
        popover.show(relativeTo: rowRect, of: anchorView,
                     preferredEdge: placeRight ? .maxX : .minX)
        popover.animates = true
        popover.clipenAnimateIn()
    }

    func hide() {
        wantsVisible = false
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(EmptyView())
        }
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
        shownStrip = nil
    }
}

private struct MultiItemPreviewView: View {
    let items: [ClipboardItem]
    var currentItemID: UUID? = nil

    private var markedCount: Int {
        currentItemID == nil ? items.count : items.count - 1
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(markedCount) marked")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("Space to close")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        if idx > 0 { Divider() }
                        let isCurrent = item.id == currentItemID
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .frame(width: 18)
                            ItemPreviewView(item: item, compact: true)
                            if isCurrent {
                                Text("CURRENT")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
                            }
                        }
                        .padding(.leading, 8)
                        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.clear)
                    }
                }
            }
        }
    }
}

private struct ItemPreviewView: View {
    let item: ClipboardItem
    var compact: Bool = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    ItemTagStrip(tags: item.tags, maxVisible: 5, compact: true)
                    if let metadata = item.metadataSummary {
                        Text(metadata)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                content
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        ItemTagStrip(tags: item.tags, maxVisible: 5, compact: false)
                        if let metadata = item.metadataSummary {
                            Text(metadata)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Space to close")
                        Text("Double-tap Space to refer")
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            }
        }
    }

    private var content: some View {
        ContentPreviewView(item: item, chrome: .panel)
    }
}

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
                WebsitePreview(url: url)
            } else {
                RichTextContentPreview(text: text, detectedType: item.detectedType)
            }
        case .richText(let attrStr, _):
            let adjusted = attrStr.adjustingColorsForCurrentAppearance()
            RichLinkedPreview(links: LinkExtractor.links(from: adjusted)) {
                AttributedTextPreview(attributedString: adjusted)
            }
        case .html(let html, let plain):
            if plain.isEmpty && html.isEmpty {
                textPreview(plain, monospaced: false)
            } else {
                RichLinkedPreview(links: LinkExtractor.links(fromHTML: html)) {
                    HTMLStringPreview(html: html)
                }
            }
        case .rtfd(let data, let plain):
            if let attrStr = NSAttributedString(rtfd: data, documentAttributes: nil) {
                let adjusted = attrStr.adjustingColorsForCurrentAppearance()
                RichLinkedPreview(links: LinkExtractor.links(from: adjusted)) {
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
            textPreview(typeMap.keys.sorted().map { "· \($0)" }.joined(separator: "\n"),
                        monospaced: true)
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

enum TableCellExtractor {
    private static let cache: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        c.countLimit = 500
        return c
    }()

    static func cells(for item: ClipboardItem) -> [[String]]? {
        if let cached = cache.object(forKey: item.id as NSUUID) as? [[String]] {
            return cached.isEmpty ? nil : cached
        }
        let result = extract(for: item) ?? []
        cache.setObject(result as NSArray, forKey: item.id as NSUUID)
        return result.isEmpty ? nil : result
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

    private static func cells(from attr: NSAttributedString) -> [[String]]? {
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
}

/// Pulls the first embedded image out of `.richText`/`.rtfd` content that
/// mixes real text with an image (so isn't pure-image and stays as rich
/// text) — the compact popup row otherwise has nothing but `Text(plain)` to
/// show for such an item, which for an attachment run is just the
/// object-replacement placeholder character rendering as a stray glyph.
enum EmbeddedImageExtractor {
    private static let cache: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        c.countLimit = 300
        return c
    }()

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

struct MiniTablePreview: View {
    let cells: [[String]]
    var maxRows: Int = 2
    var maxCols: Int = 3

    var body: some View {
        let rows = Array(cells.prefix(maxRows))
        let colCount = max(1, min(maxCols, rows.map(\.count).max() ?? 1))
        VStack(spacing: 0) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<colCount, id: \.self) { c in
                        Text(c < rows[r].count ? rows[r][c] : "")
                            .font(.system(size: 9, weight: r == 0 ? .semibold : .regular))
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.primary.opacity(0.25), lineWidth: 1))
    }
}

struct RichTextContentPreview: View {
    let text: String
    let detectedType: ClipboardContentType

    var body: some View {
        let (text, isTruncated) = self.text.displayTrimmedLeading.displayCapped()
        VStack(alignment: .leading, spacing: 0) {
            if isTruncated {
                Text("Showing the first part of a large paste")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.06))
            }
            Group {
                switch detectedType {
                case .markdown:
                    MarkdownTextPreview(text: text)
                case .table:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text(text)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            DelimitedTablePreview(text: text)
                                .frame(maxHeight: 320)
                        }
                    }
                case .code(let language):
                    CodeSyntaxPreview(text: text, language: language)
                default:
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

struct MarkdownTextPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(parsedBlocks) { $0.view }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private struct Block: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    private var parsedBlocks: [Block] {
        var blocks: [Block] = []
        var inCodeBlock = false
        var codeBuffer: [String] = []
        var codeLang: String? = nil

        func flushCode() {
            guard !codeBuffer.isEmpty else { return }
            let joined = codeBuffer.joined(separator: "\n")
            blocks.append(Block(view: AnyView(
                CodeSyntaxPreview(text: joined, language: codeLang)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            )))
            codeBuffer = []
            codeLang = nil
        }

        for rawLine in text.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    codeLang = lang.isEmpty ? nil : String(lang)
                }
                continue
            }
            if inCodeBlock { codeBuffer.append(rawLine); continue }

            if trimmed.hasPrefix("### ") {
                blocks.append(Block(view: AnyView(
                    Text(String(trimmed.dropFirst(4))).font(.system(size: 15, weight: .semibold)))))
            } else if trimmed.hasPrefix("## ") {
                blocks.append(Block(view: AnyView(
                    Text(String(trimmed.dropFirst(3))).font(.system(size: 17, weight: .bold)))))
            } else if trimmed.hasPrefix("# ") {
                blocks.append(Block(view: AnyView(
                    Text(String(trimmed.dropFirst(2))).font(.system(size: 20, weight: .bold)))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let content = String(trimmed.dropFirst(2))
                blocks.append(Block(view: AnyView(
                    HStack(alignment: .top, spacing: 6) { Text("\u{2022}"); inlineText(content) })))
            } else if let range = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let marker = String(trimmed[trimmed.startIndex..<range.upperBound])
                let listContent = String(trimmed[range.upperBound...])
                blocks.append(Block(view: AnyView(
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker.trimmingCharacters(in: .whitespaces)); inlineText(listContent)
                    })))
            } else if trimmed.isEmpty {
                blocks.append(Block(view: AnyView(Spacer().frame(height: 4))))
            } else {
                blocks.append(Block(view: AnyView(inlineText(trimmed))))
            }
        }
        if inCodeBlock { flushCode() }
        return blocks
    }

    private func inlineText(_ s: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed)
            .font(.system(size: 13))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DelimitedTablePreview: View {
    let text: String

    private var rows: [[String]] {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        let delimiter = lines[0].contains("\t") ? "\t" : ","
        return lines.map { $0.components(separatedBy: delimiter) }
    }

    var body: some View {
        let data = rows
        ScrollView([.horizontal, .vertical]) {
            if data.isEmpty {
                Text("No table data").foregroundColor(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(Array(data.enumerated()), id: \.offset) { rowIdx, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 12,
                                                 weight: rowIdx == 0 ? .semibold : .regular,
                                                 design: .monospaced))
                                    .foregroundColor(rowIdx == 0 ? .primary : .primary.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        if rowIdx == 0 {
                            Divider().gridCellColumns(row.count)
                        }
                    }
                }
                .padding(10)
            }
        }
    }
}

struct CodeSyntaxPreview: View {
    let text: String
    let language: String?

    @State private var highlighted: NSAttributedString? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let highlighted {
                HighlightedCodeTextView(attributed: highlighted)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(text)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            }
        }
        .task(id: HighlightKey(text: text, language: language, dark: colorScheme == .dark)) {
            let dark = colorScheme == .dark
            let result = await CodeHighlighter.shared.highlight(
                text, languageDisplayName: language, dark: dark)
            guard !Task.isCancelled else { return }
            highlighted = result
        }
    }

    private struct HighlightKey: Equatable {
        let fingerprint: String
        let language: String?
        let dark: Bool

        init(text: String, language: String?, dark: Bool) {
            self.fingerprint = "\(text.count)|\(text.prefix(48))|\(text.suffix(48))"
            self.language = language
            self.dark = dark
        }
    }

}

final class CodeHighlighter {
    static let shared = CodeHighlighter()

    private let queue = DispatchQueue(label: "com.clipen.codehighlighter", qos: .userInitiated)
    private var highlightr: Highlightr?
    private var didInit = false
    private var currentTheme: String?

    private init() {}

    func highlight(_ code: String, languageDisplayName: String?, dark: Bool) async -> NSAttributedString? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                continuation.resume(returning: self?.highlightOnQueue(code, languageDisplayName: languageDisplayName, dark: dark))
            }
        }
    }

    private func highlightOnQueue(_ code: String, languageDisplayName: String?, dark: Bool) -> NSAttributedString? {
        if !didInit {
            highlightr = Highlightr()
            didInit = true
        }
        guard let highlightr else { return nil }
        let theme = dark ? "atom-one-dark" : "atom-one-light"
        if currentTheme != theme {
            highlightr.setTheme(to: theme)
            currentTheme = theme
        }
        let hljsID = CodeLanguageDetector.hljsIdentifier(for: languageDisplayName)
        return highlightr.highlight(code, as: hljsID, fastRender: true)
    }
}

struct HighlightedCodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 6, height: 6)
            tv.isHorizontallyResizable = true
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textStorage?.setAttributedString(attributed)
    }
}

struct AsyncTextFilePreview: View {
    let url: URL
    @State private var text: String?
    @State private var isTruncated = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 0) {
                    if isTruncated {
                        Text("Showing the first part of a large file")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                    }
                    if let lang = CodeLanguageDetector.languageForExtension(url.pathExtension) {
                        CodeSyntaxPreview(text: text, language: lang)
                            .padding(.top, isTruncated ? 8 : 0)
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, isTruncated ? 8 : 0)
                        }
                    }
                }
            } else if loadFailed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            text = nil
            isTruncated = false
            loadFailed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                FileKindDetector.readableTextPreview(from: url)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                text = loaded.text
                isTruncated = loaded.isTruncated
            } else {
                loadFailed = true
            }
        }
    }
}

struct FilePreviewContent: View {
    let url: URL

    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var body: some View {
        Group {
            if isDirectory {
                FolderTreePreview(url: url)
            } else if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
                PDFPreview(document: pdf)
            } else if url.pathExtension.lowercased() == "gif", let data = try? Data(contentsOf: url),
                      let gifImage = NSImage(data: data) {
                ZoomableImagePreview(image: gifImage, animatedData: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if let image = NSImage(contentsOf: url) {
                ZoomableImagePreview(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if FileKindDetector.isHTMLFile(url) {
                HTMLFilePreview(url: url)
            } else if FileKindDetector.isTextFile(url) {
                AsyncTextFilePreview(url: url)
            } else if FileKindDetector.isMediaFile(url) {
                AVMediaPreview(url: url)
            } else if FileKindDetector.is3DModelFile(url) {
                Model3DPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if FileManager.default.fileExists(atPath: url.path) {
                QuickLookFilePreview(url: url)
            } else if let docText = FileKindDetector.readableDocumentText(from: url) {
                ScrollView {
                    Text(docText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                        .resizable()
                        .frame(width: 72, height: 72)
                    Text(url.lastPathComponent)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    Text(url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct FolderTreePreview: View {
    let url: URL

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let depth: Int
        let isDir: Bool
    }

    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var truncated = false

    private static let maxDepth = 5
    private static let maxEntries = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13)).foregroundColor(.accentColor)
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if !loading {
                    Text("\(entries.count)\(truncated ? "+" : "") items")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 28, weight: .thin)).foregroundColor(.secondary)
                    Text("Empty folder").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { e in
                            HStack(spacing: 6) {
                                Image(systemName: e.isDir ? "folder.fill" : Self.icon(forFile: e.name))
                                    .font(.system(size: 11))
                                    .foregroundColor(e.isDir ? .accentColor : .secondary)
                                    .frame(width: 14)
                                Text(e.name)
                                    .font(.system(size: 12, weight: e.isDir ? .medium : .regular))
                                    .foregroundColor(e.isDir ? .primary : .primary.opacity(0.82))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(e.depth) * 16)
                        }
                        if truncated {
                            Text("… more (truncated)")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .task(id: url) {
            loading = true
            let result = await Self.scan(url)
            entries = result.entries
            truncated = result.truncated
            loading = false
        }
    }

    private static func icon(forFile name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png","jpg","jpeg","gif","heic","webp","tiff","bmp": return "photo"
        case "pdf":                                               return "doc.richtext"
        case "mp4","mov","m4v","avi","mkv":                       return "film"
        case "mp3","wav","aac","m4a","flac":                      return "music.note"
        case "zip","tar","gz","dmg","7z":                         return "archivebox"
        case "swift","js","ts","py","rb","go","c","cpp","h","java","rs","sh": return "chevron.left.forwardslash.chevron.right"
        default:                                                  return "doc"
        }
    }

    private static func scan(_ root: URL) async -> (entries: [Entry], truncated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var out: [Entry] = []
                var truncated = false
                let fm = FileManager.default

                func walk(_ dir: URL, depth: Int) {
                    guard depth < maxDepth else { return }
                    guard let items = try? fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]) else { return }
                    let sorted = items.sorted { a, b in
                        let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if ad != bd { return ad && !bd }
                        return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
                    }
                    for item in sorted {
                        if out.count >= maxEntries { truncated = true; return }
                        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        out.append(Entry(name: item.lastPathComponent, depth: depth, isDir: isDir))
                        if isDir { walk(item, depth: depth + 1) }
                    }
                }
                walk(root, depth: 0)
                continuation.resume(returning: (out, truncated))
            }
        }
    }
}

struct Model3DPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator { var loadedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SpinUntilTouchedSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = Self.loadScene(url)
        context.coordinator.loadedURL = url
        Self.startAutoRotation(in: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.scene = Self.loadScene(url)
        Self.startAutoRotation(in: view)
    }

    final class SpinUntilTouchedSCNView: SCNView {
        private func stopAutoSpin() {
            scene?.rootNode.childNode(withName: "clipenAutoSpin", recursively: false)?
                .removeAllActions()
        }
        override func mouseDown(with event: NSEvent) {
            stopAutoSpin()
            super.mouseDown(with: event)
        }
        override func scrollWheel(with event: NSEvent) {
            stopAutoSpin()
            super.scrollWheel(with: event)
        }
        override func magnify(with event: NSEvent) {
            stopAutoSpin()
            super.magnify(with: event)
        }
    }

    private static func startAutoRotation(in view: SCNView) {
        guard let scene = view.scene else { return }
        let pivotName = "clipenAutoSpin"
        if scene.rootNode.childNode(withName: pivotName, recursively: false) != nil { return }
        let pivot = SCNNode()
        pivot.name = pivotName
        for child in scene.rootNode.childNodes where child.name != pivotName {
            child.removeFromParentNode()
            pivot.addChildNode(child)
        }
        scene.rootNode.addChildNode(pivot)
        let spin = SCNAction.repeatForever(
            .rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 8))
        pivot.runAction(spin)
    }

    private static func loadScene(_ url: URL) -> SCNScene {
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            return scene
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        return scene
    }
}

struct AnimatedImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(data: data)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.lastDataCount = data.count
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.lastDataCount != data.count else { return }
        context.coordinator.lastDataCount = data.count
        view.image = NSImage(data: data)
        view.animates = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastDataCount: Int = -1
    }
}

private struct HTMLFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsMagnification = true
        load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { load(url, in: view) }
    }

    private func load(_ url: URL, in view: WKWebView) {
        if url.pathExtension.lowercased() == "webarchive" {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

private struct AVMediaPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.minScaleFactor = view.scaleFactorForSizeToFit
        view.maxScaleFactor = 8
        view.document = document
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.minScaleFactor = view.scaleFactorForSizeToFit
        }
    }

    final class InteractivePDFView: PDFView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func magnify(with event: NSEvent) {
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + event.magnification)))
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else {
                super.scrollWheel(with: event)
                return
            }
            let delta = max(-10, min(10, event.scrollingDeltaY))
            guard delta != 0 else { return }
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + delta * 0.02)))
        }
    }
}

struct ZoomableImagePreview: NSViewRepresentable {
    let image: NSImage
    var animatedData: Data? = nil
    var fullResData: Data? = nil

    func makeNSView(context: Context) -> FitOnLayoutScrollView {
        let scrollView = FitOnLayoutScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8

        let imageView = NSImageView()
        if let animatedData, let animated = NSImage(data: animatedData) {
            imageView.image = animated
            imageView.animates = true
            scrollView.lastImageDataCount = animatedData.count
        } else if let fullResData {
            imageView.image = image
            scrollView.lastImageDataCount = fullResData.count
            Self.decodeFullRes(fullResData, into: imageView, scrollView: scrollView)
        } else {
            imageView.image = image
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: scrollView,
                                                   action: #selector(FitOnLayoutScrollView.toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
        return scrollView
    }

    func updateNSView(_ scrollView: FitOnLayoutScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        if let animatedData {
            guard scrollView.lastImageDataCount != animatedData.count else { return }
            imageView.image = NSImage(data: animatedData)
            imageView.animates = true
            scrollView.lastImageDataCount = animatedData.count
            scrollView.magnification = 1
        } else if let fullResData {
            guard scrollView.lastImageDataCount != fullResData.count else { return }
            imageView.image = image
            scrollView.lastImageDataCount = fullResData.count
            scrollView.magnification = 1
            Self.decodeFullRes(fullResData, into: imageView, scrollView: scrollView)
        } else if imageView.image !== image {
            imageView.image = image
            scrollView.magnification = 1
        }
    }

    private static func decodeFullRes(_ data: Data, into imageView: NSImageView,
                                      scrollView: FitOnLayoutScrollView) {
        DispatchQueue.global(qos: .userInitiated).async {
            let full = NSImage(data: data)
            DispatchQueue.main.async {
                guard let full, scrollView.lastImageDataCount == data.count else { return }
                imageView.image = full
            }
        }
    }

    final class FitOnLayoutScrollView: NSScrollView {
        var lastImageDataCount: Int?

        override func layout() {
            super.layout()
            if magnification <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else {
                super.scrollWheel(with: event)
                return
            }
            let delta = max(-10, min(10, event.scrollingDeltaY))
            guard delta != 0 else { return }
            let target = min(maxMagnification, max(minMagnification, magnification * (1 + delta * 0.02)))
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            setMagnification(target, centeredAt: point)
            if target <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        @objc func toggleZoom(_ gesture: NSClickGestureRecognizer) {
            let target: CGFloat = magnification <= 1.001 ? 2.5 : 1
            let point = gesture.location(in: documentView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().setMagnification(target, centeredAt: point)
            }
            if target == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                    guard let self, self.magnification <= 1.001 else { return }
                    self.documentView?.frame = self.contentView.bounds
                }
            }
        }
    }
}

struct HTMLStringPreview: NSViewRepresentable {
    final class Coordinator {
        var lastHTML: String?
    }

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        loadHTML(view)
        context.coordinator.lastHTML = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        loadHTML(view)
        context.coordinator.lastHTML = html
    }

    private func loadHTML(_ view: WKWebView) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                color-scheme: light dark;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                font-size: 13px;
                margin: 0;
                padding: 8px;
                background-color: transparent;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                margin-top: 8px;
                margin-bottom: 12px;
            }
            th, td {
                border: 1px solid rgba(128, 128, 128, 0.3);
                padding: 6px 8px;
                text-align: left;
            }
            th {
                background-color: rgba(128, 128, 128, 0.1);
                font-weight: 600;
            }
        </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
        view.loadHTMLString(styledHTML, baseURL: nil)
    }
}

struct ExtractedLink: Identifiable {
    let id = UUID()
    let label: String
    let url: URL
}

enum LinkExtractor {
    static func links(from attr: NSAttributedString) -> [ExtractedLink] {
        guard attr.length > 0 else { return [] }
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        attr.enumerateAttribute(.link, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let url: URL?
            switch value {
            case let u as URL:    url = u
            case let s as String: url = URL(string: s)
            default:              url = nil
            }
            guard let url, url.scheme != nil, seen.insert(url.absoluteString).inserted else { return }
            let text = attr.attributedSubstring(from: range).string
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ExtractedLink(label: text.isEmpty ? (url.host ?? url.absoluteString) : text, url: url))
        }
        return out
    }

    static func links(fromHTML html: String) -> [ExtractedLink] {
        guard html.count <= 300_000,
              let re = try? NSRegularExpression(
                pattern: #"<a\b[^>]*?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = html as NSString
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) where m.numberOfRanges >= 3 {
            let href = ns.substring(with: m.range(at: 1))
            guard let url = URL(string: href), url.scheme != nil,
                  seen.insert(url.absoluteString).inserted else { continue }
            let inner = ns.substring(with: m.range(at: 2))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(ExtractedLink(label: inner.isEmpty ? (url.host ?? href) : inner, url: url))
        }
        return out
    }
}

struct LinkStrip: View {
    let links: [ExtractedLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                Text("\(links.count) LINK\(links.count == 1 ? "" : "S")")
                    .font(.system(size: 9, weight: .semibold)).tracking(1)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(links) { link in
                        Button { NSWorkspace.shared.open(link.url) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "link").font(.system(size: 9))
                                Text(link.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .overlay(Capsule().stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                            .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(link.url.absoluteString)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
    }
}

struct RichLinkedPreview<Content: View>: View {
    let links: [ExtractedLink]
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !links.isEmpty {
                Divider()
                LinkStrip(links: links)
            }
        }
    }
}

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }
}

struct WebsitePreview: NSViewRepresentable {
    let url: URL

    final class Coordinator: NSObject, WKNavigationDelegate {
        var progressView: NSProgressIndicator?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
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

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsMagnification = true
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        progress.startAnimation(nil)
        context.coordinator.progressView = progress

        webView.load(URLRequest(url: url, timeoutInterval: 10))
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView = container.subviews.first(where: { $0 is WKWebView }) as? WKWebView,
              (webView.url?.absoluteString ?? "") != url.absoluteString else { return }
        webView.load(URLRequest(url: url, timeoutInterval: 10))
    }
}

extension NSAttributedString {
    func adjustingColorsForCurrentAppearance() -> NSAttributedString {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let mutable = NSMutableAttributedString(attributedString: self)

        mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
            if let color = value as? NSColor {
                if let rgbColor = color.usingColorSpace(.deviceRGB) {
                    let r = rgbColor.redComponent
                    let g = rgbColor.greenComponent
                    let b = rgbColor.blueComponent
                    let luminance = 0.299 * r + 0.587 * g + 0.114 * b

                    if isDarkMode && luminance < 0.25 {
                        mutable.addAttribute(.foregroundColor, value: NSColor.white, range: range)
                    } else if !isDarkMode && luminance > 0.85 {
                        mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                    }
                }
            }
        }
        return mutable
    }
}
