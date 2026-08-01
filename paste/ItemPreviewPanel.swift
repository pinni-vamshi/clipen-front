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

final class ItemPreviewPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    private var shownStrip: NSRect? = nil
    private var wantsVisible = false

    /// Fires whenever `wantsVisible` actually changes — the one place that
    /// happens is inside `present(...)`/`hide()` below, so this is a single
    /// choke point rather than something every one of this panel's 20+
    /// external call sites would need to remember to report separately.
    /// Lets ClipboardManager mirror this into a real `@Published` property
    /// (`isItemPreviewVisible`) for SwiftUI to react to — this class itself
    /// isn't an ObservableObject, so nothing here is reactive on its own.
    var onVisibilityChange: ((Bool) -> Void)?

    var isVisible: Bool { wantsVisible && popover.isShown }
    var frame: NSRect {
        if let view = popover.contentViewController?.view, let win = view.window {
            return win.convertToScreen(view.convert(view.bounds, to: nil))
        }
        return anchorPanel.frame
    }

    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.sharingType = .none
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

    /// Opens the inline editor at the item's position, side-by-side with the
    /// popup — replaces the old QuickClip-panel edit flow entirely.
    func showEditor(for item: ClipboardItem,
                    initialText: String,
                    near popupFrame: NSRect,
                    anchorPoint: NSPoint? = nil,
                    onCommit: @escaping (String) -> Void,
                    onCommitAndPaste: @escaping (String) -> Void,
                    onCancel: @escaping () -> Void) {
        present(AnyView(InlineEditView(item: item,
                                       initialText: initialText,
                                       onCommit: onCommit,
                                       onCommitAndPaste: onCommitAndPaste,
                                       onCancel: onCancel)),
                width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    /// Table content (a real table structure — richText/RTFD/HTML — not a
    /// plain-text blob) gets edited cell-by-cell instead of being flattened
    /// through the flat text editor above, which would destroy the table
    /// structure by replacing the whole rich container with a plain string.
    func showTableEditor(initialRows: [[String]],
                         near popupFrame: NSRect,
                         anchorPoint: NSPoint? = nil,
                         onCommit: @escaping ([[String]]) -> Void,
                         onCommitAndPaste: @escaping ([[String]]) -> Void,
                         onCancel: @escaping () -> Void) {
        present(AnyView(InlineTableEditView(initialRows: initialRows,
                                            onCommit: onCommit,
                                            onCommitAndPaste: onCommitAndPaste,
                                            onCancel: onCancel)),
                width: 520, height: 420,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func showMixedEditor(initialSegments: [ContentSegment],
                         near popupFrame: NSRect,
                         anchorPoint: NSPoint? = nil,
                         onCommit: @escaping ([ContentSegment]) -> Void,
                         onCommitAndPaste: @escaping ([ContentSegment]) -> Void,
                         onCancel: @escaping () -> Void) {
        present(AnyView(InlineMixedEditView(initialSegments: initialSegments,
                                            onCommit: onCommit,
                                            onCommitAndPaste: onCommitAndPaste,
                                            onCancel: onCancel)),
                width: 520, height: 480,
                near: popupFrame, anchorPoint: anchorPoint)
    }

    func showRichEditor(initialAttributedString: NSAttributedString,
                        near popupFrame: NSRect,
                        anchorPoint: NSPoint? = nil,
                        onCommit: @escaping (NSAttributedString) -> Void,
                        onCommitAndPaste: @escaping (NSAttributedString) -> Void,
                        onCancel: @escaping () -> Void) {
        present(AnyView(InlineRichEditView(initialAttributedString: initialAttributedString,
                                           onCommit: onCommit,
                                           onCommitAndPaste: onCommitAndPaste,
                                           onCancel: onCancel)),
                width: 520, height: 420,
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

        let wasVisible = wantsVisible
        wantsVisible = true
        if !wasVisible { onVisibilityChange?(true) }
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
        let wasVisible = wantsVisible
        wantsVisible = false
        if wasVisible { onVisibilityChange?(false) }
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(EmptyView())
        }
        if popover.isShown {
            // Snap-close to avoid the animated fade visually overlapping
            // whatever panel replaces it (transform, share).
            popover.animates = false
            popover.performClose(nil)
            popover.animates = true
        }
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
                        HStack(spacing: 8) {
                            Text("\(idx + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(.accentColor)
                                .frame(width: 18)
                            ItemPreviewView(item: item, compact: true)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
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
            // A grouped item previews its members individually, same view the
            // popup uses when previewing a marked set.
            MultiItemPreviewView(items: items)
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

    /// Must be called after any edit that changes an item's table content —
    /// otherwise re-opening the item to edit again would show the stale,
    /// pre-edit cells instead of what was just saved.
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

    /// An un-styled re-serialization of a real table — same grid this file
    /// already reads for editing/preview, with every bit of visual styling
    /// (bold, color, font, borders) dropped. "Paste without formatting" needs
    /// this instead of flat tab-separated text: tab/newline text only reads
    /// back as real columns in a spreadsheet. Pasted into anything else
    /// (Word, Pages, Notes, Mail) it shows as bare text with visible tab
    /// gaps — the table itself is gone. An HTML table with no inline style
    /// still renders as an actual table grid everywhere, carrying none of
    /// the original formatting. Returns nil for content that isn't really a
    /// table, so callers fall back to their existing flat-text behavior.
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

    /// Tab-separated, row-per-line rendering of an attributed string's table
    /// (if it has one) — nil when there's no real `NSTextTableBlock` to read.
    /// A table's cells are separate paragraphs in `NSAttributedString.string`
    /// with no column-boundary character at all, so anything that reads the
    /// raw `.string` off a copied Pages/Numbers/Mail/TextEdit table sees every
    /// cell run together on its own line — column structure gone entirely.
    /// This is what capture uses to build the `plain` fallback instead.
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

    // MARK: - Mixed-content segmentation

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
                    DelimitedTablePreview(text: text)
                        .padding(10)
                case .code(let language):
                    CodeSyntaxPreview(text: text, language: language)
                case .json:
                    CodeSyntaxPreview(text: text, language: "json")
                case .latex:
                    CodeSyntaxPreview(text: text, language: "latex")
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
                    HStack(alignment: .top, spacing: 6) { Text("\u{2022}").font(.system(size: 13)); inlineText(content) })))
            } else if let range = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let marker = String(trimmed[trimmed.startIndex..<range.upperBound])
                let listContent = String(trimmed[range.upperBound...])
                blocks.append(Block(view: AnyView(
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker.trimmingCharacters(in: .whitespaces)).font(.system(size: 13)); inlineText(listContent)
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

/// Quote-aware CSV/TSV parsing — the previous version just did
/// `components(separatedBy: delimiter)`, which silently corrupts any file
/// with a quoted field containing the delimiter itself (e.g. `"Smith, John"`
/// in a comma-separated file, extremely common in real Excel/Numbers
/// exports) or an embedded newline inside a quoted field. This walks the
/// text character-by-character tracking quote state, per RFC 4180.
enum DelimitedTableParser {
    static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        return firstLine.contains("\t") ? "\t" : ","
    }

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text)
        var i = 0

        func endField() { currentRow.append(field); field = "" }
        func endRow() { endField(); rows.append(currentRow); currentRow = [] }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\""); i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\n" {
                endRow()
            } else if c == "\r" {
                if i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !currentRow.isEmpty { endRow() }

        // Drop fully-blank trailing/interstitial lines (a common artifact of
        // a trailing newline in the source file).
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

/// Read-only bordered grid — visually matches EditableTableGrid (the table
/// EDITOR's look) so a table reads the same whether you're viewing or
/// editing it, instead of two unrelated visual languages for the same data.
struct StyledTablePreview: View {
    let rows: [[String]]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            if rows.isEmpty {
                Text("No table data").font(.system(size: 13)).foregroundColor(.secondary)
                    .padding(20)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        HStack(spacing: 1) {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(cell.trimmingCharacters(in: .whitespaces))
                                    .font(.system(size: 11, weight: r == 0 ? .semibold : .regular))
                                    .foregroundColor(r == 0 ? .primary : .primary.opacity(0.85))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .frame(minWidth: 90, alignment: .leading)
                                    .background(Color.primary.opacity(r == 0 ? 0.06 : 0.02))
                                    .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                            }
                        }
                    }
                }
                .padding(4)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

struct DelimitedTablePreview: View {
    let text: String

    var body: some View {
        let delimiter = DelimitedTableParser.detectDelimiter(text)
        StyledTablePreview(rows: DelimitedTableParser.parse(text, delimiter: delimiter))
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
    // Revisiting a clip (or switching away and back) used to redo the full
    // highlight.js pass from scratch every time — nothing here remembered a
    // result across calls, only the CALLER's `.task(id:)` avoided repeating
    // the work within a single still-alive view instance. Same fingerprint-
    // keyed NSCache approach TextInsightService/TableCellExtractor already
    // use elsewhere in this file.
    private let cache = NSCache<NSString, NSAttributedString>()

    private init() { cache.countLimit = 200 }

    private static func cacheKey(_ code: String, languageDisplayName: String?, dark: Bool) -> NSString {
        "\(code.count)|\(code.prefix(48))|\(code.suffix(48))|\(languageDisplayName ?? "-")|\(dark ? "d" : "l")" as NSString
    }

    func highlight(_ code: String, languageDisplayName: String?, dark: Bool) async -> NSAttributedString? {
        let key = Self.cacheKey(code, languageDisplayName: languageDisplayName, dark: dark)
        // Fast path: a cache hit never has to hop onto the highlighter's
        // serial queue at all.
        if let hit = cache.object(forKey: key) { return hit }
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let hit = self?.cache.object(forKey: key) {
                    continuation.resume(returning: hit)
                    return
                }
                let result = self?.highlightOnQueue(code, languageDisplayName: languageDisplayName, dark: dark)
                if let result { self?.cache.setObject(result, forKey: key) }
                continuation.resume(returning: result)
            }
        }
    }

    /// Highlightr runs highlight.js through JavaScriptCore — tokenizing multiple
    /// MB of code/JSON through a JS engine takes seconds. Above this cap we skip
    /// highlighting entirely (returns nil) so the preview shows the plain-text
    /// fallback instantly instead of hanging. Highlighting a 5 MB file adds no
    /// real value anyway.
    static let maxHighlightLength = 100_000

    func highlightSync(_ code: String, languageDisplayName: String?, dark: Bool) -> NSAttributedString? {
        let key = Self.cacheKey(code, languageDisplayName: languageDisplayName, dark: dark)
        if let hit = cache.object(forKey: key) { return hit }
        return queue.sync { [weak self] () -> NSAttributedString? in
            if let hit = self?.cache.object(forKey: key) { return hit }
            let result = self?.highlightOnQueue(code, languageDisplayName: languageDisplayName, dark: dark)
            if let result { self?.cache.setObject(result, forKey: key) }
            return result
        }
    }

    private func highlightOnQueue(_ code: String, languageDisplayName: String?, dark: Bool) -> NSAttributedString? {
        guard code.count <= Self.maxHighlightLength else { return nil }
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
            tv.isVerticallyResizable = true
            // maxSize is what actually lets the text view grow wider than its
            // visible frame — without it, long code lines were clipped and the
            // horizontal scroller had nothing to scroll to. Combined with a
            // non-wrapping container, lines now extend and scroll sideways.
            tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
            tv.textContainer?.widthTracksTextView = false
            tv.textContainer?.heightTracksTextView = false
            tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        }
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.textStorage?.setAttributedString(attributed)
        // Re-layout so the text view's frame expands to the widest line, which
        // is what makes the horizontal scroller appear when needed.
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()
    }
}

/// CSV/TSV FILES specifically — previously these fell into `isTextFile` and
/// rendered as flat monospaced text like any other text file, with no grid
/// at all, even though the exact same delimited content pasted as plain text
/// (not file-backed) already got a table view via `RichTextContentPreview`'s
/// `.table` case. This closes that gap so a copied .csv/.tsv FILE gets the
/// same treatment.
struct AsyncDelimitedFilePreview: View {
    let url: URL
    @State private var rows: [[String]]?
    @State private var isTruncated = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let rows {
                VStack(alignment: .leading, spacing: 0) {
                    if isTruncated {
                        Text("Showing the first part of a large file")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                    }
                    StyledTablePreview(rows: rows)
                        .padding(10)
                }
            } else if loadFailed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            rows = nil
            isTruncated = false
            loadFailed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                FileKindDetector.readableTextPreview(from: url)
            }.value
            guard !Task.isCancelled else { return }
            guard let loaded else { loadFailed = true; return }
            let delimiter = DelimitedTableParser.detectDelimiter(loaded.text)
            rows = DelimitedTableParser.parse(loaded.text, delimiter: delimiter)
            isTruncated = loaded.isTruncated
        }
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
            } else if url.pathExtension.lowercased() == "pdf" {
                AsyncPDFFilePreview(url: url)
            } else if url.pathExtension.lowercased() == "gif" {
                AsyncGIFFilePreview(url: url)
            // Known-not-an-image extensions MUST short-circuit before the
            // greedy `NSImage(contentsOf:)` probe below — that call reads the
            // WHOLE file on main to try image detection, which for a 50 MB
            // GLB / video / etc. is a 2-10 s beach-ball freeze before we ever
            // reach the correct branch.
            } else if FileKindDetector.isGLTFModelFile(url) {
                // glTF/GLB rendering (via GLTFKit2's shared concurrent loader
                // queue) was causing hangs and crashes in practice — removed
                // rather than left half-working. The file itself still
                // copies/pastes normally; it just doesn't render a preview.
                NoPreviewAvailableView(url: url)
            } else if FileKindDetector.is3DModelFile(url) {
                Model3DPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if FileKindDetector.isMediaFile(url) {
                AVMediaPreview(url: url)
            } else if FileKindDetector.isHTMLFile(url) {
                HTMLFilePreview(url: url)
            } else if ["csv", "tsv"].contains(url.pathExtension.lowercased()) {
                AsyncDelimitedFilePreview(url: url)
            } else if FileKindDetector.isTextFile(url) {
                AsyncTextFilePreview(url: url)
            } else if FileKindDetector.isImageFile(url) {
                // Loads via NSImage on a background queue rather than the
                // main-thread NSImage(contentsOf:) below — a 20 MB HEIC used
                // to hitch main for 100-500 ms before the preview appeared.
                AsyncImageFilePreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if let image = NSImage(contentsOf: url) {
                ZoomableImagePreview(image: image)
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

/// Default empty state for a file whose type is recognized but has no
/// working preview renderer. The file itself is unaffected — this only
/// affects what shows in the preview panel.
struct NoPreviewAvailableView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                .resizable()
                .frame(width: 72, height: 72)
            Text(url.lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("No preview available")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    final class Coordinator {
        var loadedURL: URL?
        var loadToken: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SpinUntilTouchedSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = SCNScene() // placeholder until async load lands
        Self.loadSceneAsync(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        Self.loadSceneAsync(url, into: view, coordinator: context.coordinator)
    }

    /// Loads on a background queue and swaps in on the main thread. A UUID
    /// token guards against a stale load winning after the view was reused
    /// for a different URL.
    private static func loadSceneAsync(_ url: URL, into view: SCNView, coordinator: Coordinator) {
        let token = UUID()
        coordinator.loadToken = token
        coordinator.loadedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = loadScene(url)
            DispatchQueue.main.async { [weak view] in
                guard let view, coordinator.loadToken == token else { return }
                view.scene = scene
                startAutoRotation(in: view)
            }
        }
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

    // Native SceneKit/ModelIO formats only — glTF/GLB never reach here
    // (routed to NoPreviewAvailableView instead; see FileKindDetector.isGLTFModelFile).
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
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return QLPreviewView()
        }
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

        // Explicitly handle trackpad pinch. The preview lives in a
        // non-activating panel, so NSScrollView's built-in magnification can't
        // be relied on to receive the gesture — overriding magnify(with:)
        // guarantees pinch-to-zoom works even while ⌘ is held for the popup.
        override func magnify(with event: NSEvent) {
            let target = min(maxMagnification, max(minMagnification, magnification * (1 + event.magnification)))
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            setMagnification(target, centeredAt: point)
            if target <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

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

/// One shared WKWebView reused across every HTMLStringPreview mount. Building
/// a WebKit view is 100-200 ms (WebKit process, JS context, layout engine);
/// cycling through HTML items used to pay that cost per item. Because only
/// one HTML preview is visible at any time (the popover shows one item and
/// swaps rootView on change), reuse is safe.
private enum HTMLWebViewPool {
    static let shared: WKWebView = {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        return view
    }()
}

struct HTMLStringPreview: NSViewRepresentable {
    final class Coordinator {
        var lastHTML: String?
    }

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = HTMLWebViewPool.shared
        // Reparent if AppKit tore off from a previous host — cheap when it's
        // already the child of nothing (fresh) or the same superview.
        view.removeFromSuperview()
        if context.coordinator.lastHTML != html {
            loadHTML(view)
            context.coordinator.lastHTML = html
        }
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
    /// Built once, reused forever. Constructing an NSDataDetector loads the
    /// system's data-detection resources and an NSRegularExpression compiles
    /// its pattern — both used to happen on EVERY SwiftUI body evaluation of
    /// the preview (i.e. every selection), on the main thread. Both classes
    /// are documented as thread-safe for concurrent matching, so a single
    /// shared instance is safe to share across the main and worker queues.
    private nonisolated static let linkDetector: NSDataDetector? =
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private nonisolated static let htmlAnchorRegex: NSRegularExpression? =
        try? NSRegularExpression(
            pattern: #"<a\b[^>]*?href\s*=\s*[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators])

    nonisolated static func links(from attr: NSAttributedString) -> [ExtractedLink] {
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

    nonisolated static func links(fromHTML html: String) -> [ExtractedLink] {
        guard html.count <= 300_000, let re = htmlAnchorRegex else { return [] }
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

    /// URLs that appear as bare text (not markup) inside plain-text copies.
    nonisolated static func links(fromPlainText text: String, cap: Int = 12) -> [ExtractedLink] {
        guard text.count <= 300_000, let detector = linkDetector else { return [] }
        let ns = text as NSString
        var out: [ExtractedLink] = []
        var seen = Set<String>()
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let url = match?.url, url.scheme != nil, seen.insert(url.absoluteString).inserted else { return }
            out.append(ExtractedLink(label: url.host ?? url.absoluteString, url: url))
            if out.count >= cap { stop.pointee = true }
        }
        return out
    }
}

/// Parses a plain-text representation of any copied content for things worth
/// surfacing at a glance without opening the full preview: person names,
/// email addresses, code-shaped lines, and lines that repeat verbatim
/// (useful for spotting duplicated rows in pasted lists/logs).
/// The result of one text-insight scan. A reference type so `NSCache` can hold
/// it; every stored property is immutable.
nonisolated final class TextInsights {
    struct RepeatedLine {
        let line: String
        let count: Int
    }

    let emails: [String]
    let names: [String]
    let codeLines: [String]
    let repeatedLines: [RepeatedLine]

    init(emails: [String], names: [String], codeLines: [String], repeatedLines: [RepeatedLine]) {
        self.emails = emails
        self.names = names
        self.codeLines = codeLines
        self.repeatedLines = repeatedLines
    }

    var isEmpty: Bool {
        emails.isEmpty && names.isEmpty && codeLines.isEmpty && repeatedLines.isEmpty
    }
}

/// Runs the insight scan off the main thread and memoizes it per clip.
///
/// This scan (an NLTagger named-entity pass plus several regex/line scans) used
/// to run synchronously inside `RichLinkedPreview.body` — so it re-ran on every
/// SwiftUI body evaluation, on the main thread, for every text-ish clip, and
/// the cost was paid even when the result was empty. That was the bulk of the
/// delay between clicking an item and seeing its preview.
final class TextInsightService {
    static let shared = TextInsightService()

    private let queue = DispatchQueue(label: "com.clipen.textinsights", qos: .userInitiated)
    private let cache = NSCache<NSString, TextInsights>()
    // [ExtractedLink] is a value type, so it's boxed as NSArray for NSCache —
    // same pattern TableCellExtractor already uses for [[String]] above.
    private let linkCache = NSCache<NSString, NSArray>()

    private init() {
        cache.countLimit = 400
        linkCache.countLimit = 400
    }

    /// Keyed on the clip id AND a content fingerprint, so editing a clip in
    /// place (same id, new text) recomputes instead of serving stale insights.
    /// Shared by both the insights cache and the link cache below — the same
    /// fingerprint invalidates both correctly on edit.
    static func cacheKey(id: UUID?, text: String?) -> String {
        let t = text ?? ""
        return "\(id?.uuidString ?? "-")|\(t.count)|\(t.prefix(48))|\(t.suffix(48))"
    }

    func cached(forKey key: String) -> TextInsights? {
        cache.object(forKey: key as NSString)
    }

    func store(_ insights: TextInsights, forKey key: String) {
        cache.setObject(insights, forKey: key as NSString)
    }

    func storeLinks(_ links: [ExtractedLink], forKey key: String) {
        linkCache.setObject(links as NSArray, forKey: key as NSString)
    }

    func insights(forKey key: String, text: String) async -> TextInsights {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let hit = self?.cache.object(forKey: key as NSString) {
                    continuation.resume(returning: hit)
                    return
                }
                let result = TextInsightExtractor.computeInsights(in: text)
                self?.cache.setObject(result, forKey: key as NSString)
                continuation.resume(returning: result)
            }
        }
    }

    func cachedLinks(forKey key: String) -> [ExtractedLink]? {
        linkCache.object(forKey: key as NSString) as? [ExtractedLink]
    }

    /// `compute` is whichever `LinkExtractor` variant matches the clip's
    /// content type (plain text / attributed string / HTML) — this service
    /// doesn't need to know which; it only owns the off-thread + cache
    /// mechanics, exactly like `insights(forKey:text:)` above.
    func links(forKey key: String, compute: @escaping () -> [ExtractedLink]) async -> [ExtractedLink] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                if let hit = self?.linkCache.object(forKey: key as NSString) as? [ExtractedLink] {
                    continuation.resume(returning: hit)
                    return
                }
                let result = compute()
                self?.linkCache.setObject(result as NSArray, forKey: key as NSString)
                continuation.resume(returning: result)
            }
        }
    }
}

enum TextInsightExtractor {
    nonisolated static let maxLabelLength = 42

    private nonisolated static let emailRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
                                 options: .caseInsensitive)

    /// The whole scan, in one call — always invoked from a background queue
    /// (see TextInsightService), never from a view body.
    nonisolated static func computeInsights(in text: String) -> TextInsights {
        TextInsights(emails: emails(in: text),
                     names: personNames(in: text),
                     codeLines: codeLikeLines(in: text),
                     repeatedLines: repeatedLines(in: text))
    }

    nonisolated static func truncate(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxLabelLength else { return t }
        return String(t.prefix(maxLabelLength)) + "…"
    }

    nonisolated static func emails(in text: String, cap: Int = 6) -> [String] {
        guard text.count <= 300_000, let re = emailRegex else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            guard seen.insert(s.lowercased()).inserted else { continue }
            out.append(s)
            if out.count >= cap { break }
        }
        return out
    }

    /// Named-entity recognition is by far the heaviest thing in this file's
    /// analysis path — NLTagger loads an ML model and runs inference. The cap
    /// used to be 50 k characters, which is a lot of inference to sit behind a
    /// chip strip; a few thousand characters is more than enough to surface
    /// the names worth showing.
    nonisolated static func personNames(in text: String, cap: Int = 6) -> [String] {
        guard !text.isEmpty, text.count <= 5_000 else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var seen = Set<String>()
        var out: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                              options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if tag == .personalName {
                let name = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if name.count > 1, seen.insert(name).inserted {
                    out.append(name)
                }
            }
            return out.count < cap
        }
        return out
    }

    private nonisolated static let codeKeywords = [
        "func ", "def ", "class ", "import ", "return ", "const ", "let ", "var ",
        "public ", "private ", "#include", "=>", "select ", "function ",
    ]

    nonisolated static func codeLikeLines(in text: String, cap: Int = 6) -> [String] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var out: [String] = []
        for line in lines {
            let lower = line.lowercased()
            let looksLikeCode = codeKeywords.contains { lower.contains($0) }
                || (line.contains("{") && line.contains("}"))
                || (line.hasSuffix(";") && line.count > 4)
            if looksLikeCode {
                out.append(line)
                if out.count >= cap { break }
            }
        }
        return out
    }

    nonisolated static func repeatedLines(in text: String, cap: Int = 6) -> [TextInsights.RepeatedLine] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
        guard lines.count <= 5_000 else { return [] }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for l in lines {
            if counts[l] == nil { order.append(l) }
            counts[l, default: 0] += 1
        }
        return order.compactMap { line -> TextInsights.RepeatedLine? in
            guard let c = counts[line], c > 1 else { return nil }
            return TextInsights.RepeatedLine(line: line, count: c)
        }
        .sorted { $0.count > $1.count }
        .prefix(cap)
        .map { $0 }
    }
}

struct PreviewInsightChip: Identifiable {
    enum Kind { case link(URL), email, name, code, repeated(Int), added, removed }
    /// Assigned by `uniqued(_:)` from the chip's own content. It used to be a
    /// fresh `UUID()` per chip per build, which meant every rebuild produced
    /// entirely new identities and `ForEach` in InsightsStrip could never diff
    /// — it tore down and relaid out the whole strip each time.
    var id: String = ""
    let kind: Kind
    let icon: String
    let label: String
    let color: Color
    var helpText: String? = nil

    /// Content-derived identity. Stable across rebuilds for the same chip.
    private var stableKey: String {
        switch kind {
        case .link(let url):   return "link|\(url.absoluteString)"
        case .email:           return "email|\(label)"
        case .name:            return "name|\(label)"
        case .code:            return "code|\(label)"
        case .repeated(let n): return "repeated|\(n)|\(label)"
        case .added:           return "added|\(label)"
        case .removed:         return "removed|\(label)"
        }
    }

    /// Stamps stable ids, disambiguating the rare genuine duplicate (e.g. the
    /// same code-shaped line appearing twice) so SwiftUI never sees a repeated
    /// ForEach id.
    static func uniqued(_ chips: [PreviewInsightChip]) -> [PreviewInsightChip] {
        var seen = Set<String>()
        return chips.map { chip in
            var copy = chip
            let base = chip.stableKey
            var candidate = base
            var n = 2
            while !seen.insert(candidate).inserted {
                candidate = "\(base)#\(n)"
                n += 1
            }
            copy.id = candidate
            return copy
        }
    }

    /// The concrete added (green) / removed (red) lines from a small edit,
    /// shown first in the strip so "what exactly changed" is obvious.
    static func diffChips(_ detail: DiffDetail?) -> [PreviewInsightChip] {
        guard let detail else { return [] }
        var chips: [PreviewInsightChip] = []
        chips += detail.added.map {
            PreviewInsightChip(kind: .added, icon: "plus",
                                label: TextInsightExtractor.truncate($0), color: .green,
                                helpText: "Added vs #\(detail.fromRank)")
        }
        chips += detail.removed.map {
            PreviewInsightChip(kind: .removed, icon: "minus",
                                label: TextInsightExtractor.truncate($0), color: .red,
                                helpText: "Removed vs #\(detail.fromRank)")
        }
        return chips
    }

    /// Cheap — link extraction already happened at the call site.
    static func linkChips(_ links: [ExtractedLink]) -> [PreviewInsightChip] {
        links.map {
            PreviewInsightChip(kind: .link($0.url), icon: "link",
                                label: TextInsightExtractor.truncate($0.label), color: .accentColor,
                                helpText: $0.url.absoluteString)
        }
    }

    /// Pure formatting of an already-computed (off-main, cached) scan — no
    /// analysis happens here, so this is safe to call from a view body.
    static func textChips(_ insights: TextInsights?) -> [PreviewInsightChip] {
        guard let insights else { return [] }
        var chips: [PreviewInsightChip] = []
        chips += insights.emails.map {
            PreviewInsightChip(kind: .email, icon: "envelope.fill",
                                label: TextInsightExtractor.truncate($0), color: .orange)
        }
        chips += insights.names.map {
            PreviewInsightChip(kind: .name, icon: "person.fill",
                                label: TextInsightExtractor.truncate($0), color: .purple)
        }
        chips += insights.codeLines.map {
            PreviewInsightChip(kind: .code, icon: "curlybraces",
                                label: TextInsightExtractor.truncate($0), color: .cyan)
        }
        chips += insights.repeatedLines.map {
            PreviewInsightChip(kind: .repeated($0.count), icon: "repeat",
                                label: "\($0.count)× " + TextInsightExtractor.truncate($0.line), color: .pink)
        }
        return chips
    }
}

struct InsightsStrip: View {
    let chips: [PreviewInsightChip]

    /// Alternates chips into two independent rows (1st→row A, 2nd→row B,
    /// 3rd→row A, …) rather than a shared-column grid — a grid would match
    /// each row's column width to its widest paired item, leaving gaps
    /// around shorter chips. Two plain, independently-packed `HStack`s keep
    /// every chip flush against its neighbor.
    private var rowA: [PreviewInsightChip] { chips.enumerated().filter { $0.offset % 2 == 0 }.map(\.element) }
    private var rowB: [PreviewInsightChip] { chips.enumerated().filter { $0.offset % 2 == 1 }.map(\.element) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(rowA) { chip in chipView(chip) }
                }
                HStack(spacing: 8) {
                    ForEach(rowB) { chip in chipView(chip) }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func chipView(_ chip: PreviewInsightChip) -> some View {
        if case .link(let url) = chip.kind {
            Button { NSWorkspace.shared.open(url) } label: { chipLabel(chip) }
                .buttonStyle(.plain)
                .help(chip.helpText ?? "")
        } else {
            chipLabel(chip)
        }
    }

    private func chipLabel(_ chip: PreviewInsightChip) -> some View {
        // Diff chips are tinted with their add/remove color; everything else
        // keeps the neutral gray look.
        let isDiff: Bool = { if case .added = chip.kind { return true }
                             if case .removed = chip.kind { return true }
                             return false }()
        return HStack(spacing: 4) {
            Image(systemName: chip.icon).font(.system(size: 8, weight: isDiff ? .bold : .regular))
            Text(chip.label).font(.system(size: 9, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background((isDiff ? chip.color.opacity(0.16) : Color.gray.opacity(0.16)),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .foregroundColor(isDiff ? chip.color : .secondary)
    }
}

struct RichLinkedPreview<Content: View>: View {
    /// How to find this clip's links — deferred, not run yet. Every call site
    /// used to compute its `LinkExtractor.links(...)` eagerly as a plain
    /// argument expression, meaning the NSDataDetector/regex scan ran
    /// synchronously on the main thread on EVERY body evaluation (every
    /// selection, every re-render), uncached — the same class of stutter the
    /// insights scan below used to cause before it was moved off-thread.
    /// Wrapping it in a closure lets this view run it exactly like insights:
    /// off the main thread, once per clip, cached after that.
    let computeLinks: () -> [ExtractedLink]
    var plainText: String? = nil
    /// Identity of the clip these insights describe — the cache key, so the
    /// scan runs once per clip rather than on every body evaluation.
    var insightID: UUID? = nil
    var diff: DiffDetail? = nil
    @ViewBuilder let content: Content

    @State private var insights: TextInsights? = nil
    @State private var links: [ExtractedLink] = []

    private var taskKey: String { TextInsightService.cacheKey(id: insightID, text: plainText) }

    var body: some View {
        let chips = PreviewInsightChip.uniqued(
            PreviewInsightChip.diffChips(diff)
                + PreviewInsightChip.linkChips(links)
                + PreviewInsightChip.textChips(insights))
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !chips.isEmpty {
                Divider()
                InsightsStrip(chips: chips)
            }
        }
        // The content renders immediately; the insight/link chips appear a
        // beat later on a cache miss. Previously the insights scan ran
        // inline in `body` (same for link extraction until now), so the
        // preview couldn't paint at all until it finished.
        .task(id: taskKey) {
            let key = taskKey

            // Links: cache hit is synchronous, same reasoning as insights
            // below — revisiting a clip shows its link chips immediately.
            if let hit = TextInsightService.shared.cachedLinks(forKey: key) {
                links = hit
            } else {
                links = []
                let computeLinks = computeLinks
                let computed = await TextInsightService.shared.links(forKey: key, compute: computeLinks)
                if !Task.isCancelled { links = computed }
            }

            guard let plainText, !plainText.isEmpty else {
                insights = nil
                return
            }
            // Cache hit is synchronous — revisiting a clip shows its chips
            // immediately, with no flash of the strip appearing late.
            if let hit = TextInsightService.shared.cached(forKey: key) {
                insights = hit
                return
            }
            // Drop the previous clip's chips while the new scan runs, so they
            // can't linger next to unrelated content.
            insights = nil
            let computed = await TextInsightService.shared.insights(forKey: key, text: plainText)
            guard !Task.isCancelled else { return }
            insights = computed
        }
    }
}

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }
}

/// One shared WKWebView reused across every WebsitePreview mount — same
/// rationale as HTMLWebViewPool above (constructing a WKWebView is 100-200 ms
/// and only one URL preview is ever visible at a time).
private enum WebsitePreviewPool {
    static let shared: WKWebView = {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsMagnification = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()
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

        let webView = WebsitePreviewPool.shared
        // Reparent from whatever previous mount last hosted it, same as
        // HTMLStringPreview does with its own pool.
        webView.removeFromSuperview()
        webView.navigationDelegate = context.coordinator
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

// Cache adjusted attributed strings. Two keying schemes because the two call
// sites have different identity guarantees:
//   - .richText holds ONE stable NSAttributedString instance in the enum case
//     across every render, so ObjectIdentifier keying already dedupes.
//   - .rtfd holds raw Data — `NSAttributedString(rtfd:)` allocates a BRAND
//     NEW instance every render, so ObjectIdentifier keying never hits.
//     That path needs to key on the stable ClipboardItem.id instead, and
//     cache the decode itself (not just the color pass) since decoding RTFD
//     is often the heavier half of the work.
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

    /// Decodes RTFD `data` into an appearance-adjusted NSAttributedString
    /// exactly once per (itemID, isDark) — both the decode and the color
    /// pass are skipped on every subsequent render for that item.
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
            // Fast path: scan once to decide whether ANY color needs changing.
            // If not (the common case for plain-ish rich text), return self.
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

// ============================================================================
// Inline editor — E on the popup opens this. Positioned like ItemPreviewView
// (side of the popup, anchored to the selected row), NSTextView-backed, with
// Enter to save, Shift+Enter for a literal newline, Esc to cancel.
// ============================================================================

private struct InlineRichEditView: View {
    let initialAttributedString: NSAttributedString
    let onCommit: (NSAttributedString) -> Void
    let onCommitAndPaste: (NSAttributedString) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            RichEditableTextArea(
                attributedString: initialAttributedString,
                onCommit: onCommit,
                onCommitAndPaste: onCommitAndPaste,
                onCancel: onCancel
            )
            .padding(14)
        }
    }
}

private struct RichEditableTextArea: NSViewRepresentable {
    let attributedString: NSAttributedString
    let onCommit: (NSAttributedString) -> Void
    let onCommitAndPaste: (NSAttributedString) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.inlineEditScrollableTextView()
        guard let tv = scroll.documentView as? InlineEditTextView else { return scroll }
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.textStorage?.setAttributedString(attributedString)

        tv.commitHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommit(NSAttributedString(attributedString: storage))
        }
        tv.commitAndPasteHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommitAndPaste(NSAttributedString(attributedString: storage))
        }
        tv.cancelHandler = onCancel

        DispatchQueue.main.async {
            if let win = tv.window { win.makeFirstResponder(tv) }
            let end = tv.textStorage?.length ?? 0
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? InlineEditTextView else { return }
        tv.commitHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommit(NSAttributedString(attributedString: storage))
        }
        tv.commitAndPasteHandler = { [weak tv] in
            guard let tv, let storage = tv.textStorage else { return }
            onCommitAndPaste(NSAttributedString(attributedString: storage))
        }
        tv.cancelHandler = onCancel
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: ()) {
        (nsView.documentView as? InlineEditTextView)?.commitHandler = nil
        (nsView.documentView as? InlineEditTextView)?.commitAndPasteHandler = nil
        (nsView.documentView as? InlineEditTextView)?.cancelHandler = nil
    }
}

private struct EditorKeyMonitor: NSViewRepresentable {
    let onCommit: () -> Void
    let onCommitAndPaste: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCommitAndPaste = onCommitAndPaste
        context.coordinator.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onCommit: (() -> Void)?
        var onCommitAndPaste: (() -> Void)?
        var onCancel: (() -> Void)?
        private var monitor: Any?
        private var pendingCommit: DispatchWorkItem?
        private static let doubleEnterWindow: TimeInterval = 0.35

        init() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                if event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                        return event
                    }
                    if let pending = pendingCommit {
                        pending.cancel()
                        pendingCommit = nil
                        onCommitAndPaste?()
                        return nil
                    }
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingCommit = nil
                        self?.onCommit?()
                    }
                    pendingCommit = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleEnterWindow, execute: work)
                    return nil
                }
                if event.keyCode == 53 {
                    pendingCommit?.cancel()
                    pendingCommit = nil
                    onCancel?()
                    return nil
                }
                return event
            }
        }

        deinit {
            pendingCommit?.cancel()
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}

private struct InlineMixedEditView: View {
    let initialSegments: [ContentSegment]
    let onCommit: ([ContentSegment]) -> Void
    let onCommitAndPaste: ([ContentSegment]) -> Void
    let onCancel: () -> Void

    @State private var segments: [ContentSegment] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { idx, seg in
                        switch seg {
                        case .text:
                            MixedTextSegment(text: Binding(
                                get: { if case .text(let t) = segments[idx] { return t }; return "" },
                                set: { segments[idx] = .text($0) }
                            ))
                        case .table:
                            MixedTableSegment(rows: Binding(
                                get: { if case .table(let r) = segments[idx] { return r }; return [] },
                                set: { segments[idx] = .table($0) }
                            ))
                        }
                    }
                }
                .padding(14)
            }
        }
        .onAppear { segments = initialSegments }
        .background(EditorKeyMonitor(
            onCommit: { onCommit(segments) },
            onCommitAndPaste: { onCommitAndPaste(segments) },
            onCancel: onCancel
        ))
    }
}

private struct MixedTextSegment: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Text").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            PlainTextSegmentEditor(text: $text)
                .frame(minHeight: 44, maxHeight: 220)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15), lineWidth: 1))
        }
    }
}

private struct MixedTableSegment: View {
    @Binding var rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Table").font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
            EditableTableGrid(rows: $rows)
        }
    }
}

private struct PlainTextSegmentEditor: NSViewRepresentable {
    @Binding var text: String

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextSegmentEditor
        init(_ p: PlainTextSegmentEditor) { parent = p }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)

        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let tv = NSTextView(frame: .zero, textContainer: container)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .systemFont(ofSize: 11)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.drawsBackground = false
        tv.delegate = context.coordinator
        tv.string = text

        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
    }
}

private struct InlineTableEditView: View {
    let initialRows: [[String]]
    let onCommit: ([[String]]) -> Void
    let onCommitAndPaste: ([[String]]) -> Void
    let onCancel: () -> Void

    @State private var rows: [[String]] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit Table")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            EditableTableGrid(rows: $rows)
                .padding(14)
        }
        .onAppear { rows = initialRows }
        .background(EditorKeyMonitor(
            onCommit: { onCommit(rows) },
            onCommitAndPaste: { onCommitAndPaste(rows) },
            onCancel: onCancel
        ))
    }
}

/// A standalone, centered window that teaches one gesture at a time.
/// Deliberately NOT built on the shared popover/`present(...)` machinery every
/// other panel in this file uses — those are all anchored to and torn down
/// with the ring popup, which is exactly the coupling that made the old
/// nudge design unusable (see ClipboardManager+Nudges.swift): a fluent user's
/// popup session could end, and take the lesson down with it, before there
/// was ever a real chance to read it. This panel owns its own NSPanel,
/// floats above every space, and only closes via its own "Learned"/"Later"
/// buttons or automatic natural-use detection — it does not know or care
/// whether the ring popup is open.
final class NudgeLessonPanel: NSObject, NSWindowDelegate {
    private let panel: NSWindow
    private static let size = NSSize(width: 820, height: 500)
    private var onLater: (() -> Void)?

    // Retained so the "Learned!" confirmation can rebuild the same lesson
    // view with the success overlay on, instead of the window just blinking
    // out of existence the moment the gesture lands.
    private var shownFeature: NudgeFeature?
    private var shownTotal = 0
    private var shownOnLearned: (() -> Void)?
    private var shownOnLater: (() -> Void)?

    override init() {
        // An ordinary titled window — nothing custom. That is what gives the
        // standard rounded corners, the normal title bar to drag by, the
        // system close button, and (crucially) automatic key-window status,
        // which is what lets the practice text field actually take keyboard
        // focus. The previous borderless build had to fake all four and got
        // every one of them wrong.
        panel = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init()
        panel.delegate = self
    }

    /// The title bar's close button is a third way out of the lesson, on top
    /// of the two buttons — treat it exactly like "Later" so a lesson closed
    /// this way retries instead of silently vanishing forever.
    func windowWillClose(_ notification: Notification) {
        onLater?()
    }

    var isVisible: Bool { panel.isVisible }

    func show(feature: NudgeFeature, learnedCount: Int, total: Int,
              onLearned: @escaping () -> Void, onLater: @escaping () -> Void) {
        self.onLater = onLater
        shownFeature = feature
        shownTotal = total
        shownOnLearned = onLearned
        shownOnLater = onLater
        let content = NudgeCalloutView(
            demo: feature.demo,
            learnedCount: learnedCount,
            total: total,
            justLearned: false,
            onLearned: onLearned,
            onLater: onLater
        )
        if let hostingController = panel.contentViewController as? NSHostingController<NudgeCalloutView> {
            hostingController.rootView = content
        } else {
            panel.contentViewController = NSHostingController(rootView: content)
        }
        panel.title = "Tip: \(feature.demo.title)"
        panel.subtitle = "\(learnedCount) of \(total) learned"
        panel.setContentSize(Self.size)
        centerOnMainScreen()
        // Clipen is a menu-bar accessory, so it is normally not the active
        // app — a key window in an inactive app still receives no typing.
        // Activating is what actually routes keystrokes into the practice
        // field, and is exactly what FastPasteHintPanel does for the same
        // reason. The lesson is a deliberate, dismiss-to-continue
        // interruption, so taking focus here is correct.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Marks the lesson visibly complete — a checkmark + "Learned!" over the
    /// panel, with the progress count already advanced — and only then hands
    /// back so the caller can close it. Without this the window vanished the
    /// instant the gesture fired, so the user never saw that the thing they
    /// just did was the thing being taught.
    func flashLearnedThenHide(learnedCount: Int, onDone: @escaping () -> Void) {
        guard let feature = shownFeature,
              let hostingController = panel.contentViewController as? NSHostingController<NudgeCalloutView>
        else { onDone(); return }
        hostingController.rootView = NudgeCalloutView(
            demo: feature.demo,
            learnedCount: learnedCount,
            total: shownTotal,
            justLearned: true,
            onLearned: shownOnLearned ?? {},
            onLater: shownOnLater ?? {}
        )
        panel.subtitle = "\(learnedCount) of \(shownTotal) learned"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { onDone() }
    }

    func hide() {
        // orderOut, not close — close would fire windowWillClose and count a
        // programmatic hide (e.g. "Learned") as a "Later" retry.
        onLater = nil
        panel.orderOut(nil)
    }

    private func centerOnMainScreen() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - Self.size.width / 2,
            y: screenFrame.midY - Self.size.height / 2
        )
        panel.setFrameOrigin(origin)
    }
}

private struct NudgeCalloutView: View {
    let demo: InteractionDemo
    let learnedCount: Int
    let total: Int
    let justLearned: Bool
    let onLearned: () -> Void
    let onLater: () -> Void

    @StateObject private var lab = InteractionLabController()
    @State private var practiceText: String = ""
    @FocusState private var practiceFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // No hand-rolled header row — this is an ordinary titled window
            // now, so the real title bar carries the tip name and the
            // "X of 5 learned" progress as its subtitle.
            //
            // Side by side, matching the "How to Use" paste-practice page:
            // the practice target on the left, the live animation + key
            // legend on the right — not stacked, so both are visible and
            // legible at once instead of the practice field being squeezed
            // in as an afterthought below the animation.
            HStack(alignment: .top, spacing: 44) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("PRACTICE HERE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                        if practiceText.isEmpty {
                            Text("Try the gesture, then paste or type here…")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                        }
                        TextEditor(text: $practiceText)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .focused($practiceFocused)
                    }
                    .frame(height: 160)
                    Text("Keep using the app to see more interactions.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                InteractionLabStage(lab: lab)
                    .frame(width: 300)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            HStack(spacing: 10) {
                Button("Later") { onLater() }
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Learned") { onLearned() }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        // A titled window paints its own standard background — no custom
        // fill needed (and a custom one would square off the system's
        // rounded corners).
        .overlay {
            if justLearned { NudgeLearnedOverlay() }
        }
        .onAppear {
            lab.select(demo)
            // Next runloop turn — the panel isn't key yet during onAppear,
            // and focus set before the window is key doesn't stick.
            DispatchQueue.main.async { practiceFocused = true }
        }
        // The hosting controller reuses one NSHostingController across every
        // nudge (only `rootView` is reassigned — see NudgeLessonPanel.show),
        // so onAppear only ever fires once, for the very first lesson shown.
        // Without this, every later nudge kept replaying that first demo's
        // animation regardless of which feature was actually being taught.
        .onChange(of: demo) { newDemo in
            lab.select(newDemo)
            practiceText = ""
            DispatchQueue.main.async { practiceFocused = true }
        }
        .onDisappear { lab.stop() }
    }
}

/// The "you just did it" confirmation. Shown for ~1.6s over the lesson after
/// the real gesture fires (or "Learned" is clicked) before the window closes,
/// so completing a lesson reads as an accomplishment instead of the panel
/// silently disappearing mid-interaction.
private struct NudgeLearnedOverlay: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundColor(.green)
                Text("Learned!")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
            }
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { shown = true }
        }
    }
}

private struct InlineEditView: View {
    let item: ClipboardItem
    let initialText: String
    let onCommit: (String) -> Void
    let onCommitAndPaste: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                HStack(spacing: 12) {
                    Text("↩ Save").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("⇧↩ Newline").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("↩↩ Save & Paste").font(.system(size: 9)).foregroundColor(.secondary)
                    Text("Esc Cancel").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            EditableTextArea(text: $draft,
                             onCommit: { onCommit(draft) },
                             onCommitAndPaste: { onCommitAndPaste(draft) },
                             onCancel: onCancel)
                .padding(14)
        }
        .onAppear { draft = initialText }
    }
}

private struct EditableTextArea: NSViewRepresentable {
    @Binding var text: String
    let onCommit: () -> Void
    let onCommitAndPaste: () -> Void
    let onCancel: () -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableTextArea
        init(_ p: EditableTextArea) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.inlineEditScrollableTextView()
        guard let tv = scroll.documentView as? InlineEditTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .systemFont(ofSize: 13)
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.commitHandler = onCommit
        tv.commitAndPasteHandler = onCommitAndPaste
        tv.cancelHandler = onCancel

        DispatchQueue.main.async {
            if let win = tv.window { win.makeFirstResponder(tv) }
            // Cursor placed at the end, not a select-all — pressing E should
            // drop the user straight into typing/appending, with the blinking
            // caret already live, no extra click needed to start writing.
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = nsView.documentView as? InlineEditTextView else { return }
        if tv.string != text { tv.string = text }
        tv.commitHandler = onCommit
        tv.commitAndPasteHandler = onCommitAndPaste
        tv.cancelHandler = onCancel
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        (nsView.documentView as? InlineEditTextView)?.commitHandler = nil
        (nsView.documentView as? InlineEditTextView)?.commitAndPasteHandler = nil
        (nsView.documentView as? InlineEditTextView)?.cancelHandler = nil
    }
}

private final class InlineEditTextView: NSTextView {
    var commitHandler: (() -> Void)?
    var commitAndPasteHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    /// A bare Return doesn't commit right away — it waits this long for a
    /// second Return. If one lands in time, that's "Save & Paste"; if not,
    /// the pending commit fires on its own as a plain Save. This is the only
    /// way to detect a double-tap at all, since a naive immediate-commit
    /// would tear the editor down on the first Return and leave nothing
    /// alive to catch the second.
    private static let doubleEnterWindow: TimeInterval = 0.35
    private var pendingCommit: DispatchWorkItem?

    // NSTextView's default class isn't overridable through
    // scrollableTextView() — but the constructor stores an NSTextView, which
    // we replace with a real InlineEditTextView subclass instance via a swap
    // in scrollableTextView (see the extension below).

    override func keyDown(with event: NSEvent) {
        // Return alone commits (or commits+pastes on a fast double-tap);
        // Shift/Option+Return inserts a literal newline.
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                super.keyDown(with: event)
                return
            }
            if let pending = pendingCommit {
                pending.cancel()
                pendingCommit = nil
                commitAndPasteHandler?()
                return
            }
            let work = DispatchWorkItem { [weak self] in
                self?.pendingCommit = nil
                self?.commitHandler?()
            }
            pendingCommit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleEnterWindow, execute: work)
            return
        }
        // Escape cancels — NSTextView's default cancelOperation would only
        // dismiss the completion window if any, so we override outright.
        if event.keyCode == 53 {
            pendingCommit?.cancel()
            pendingCommit = nil
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        pendingCommit?.cancel()
        pendingCommit = nil
        cancelHandler?()
    }
}

// Route NSTextView.scrollableTextView() through our subclass so the returned
// scroll view already contains an InlineEditTextView document view.
private extension NSTextView {
    static func inlineEditScrollableTextView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.heightTracksTextView = false

        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let tv = InlineEditTextView(frame: .zero, textContainer: container)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        tv.drawsBackground = false
        scroll.documentView = tv
        return scroll
    }
}

// ============================================================================
// Blob preview — the ".blob(typeMap)" content case used to just list the
// pasteboard type names. Freeform, Notes canvas fragments, WebKit-custom
// clipboards, private-app copies etc. all land here. When any of the blob's
// types map to a renderer we already have, use it — the shape/data on the
// clipboard is the same bytes the destination app would receive on paste, so
// this preview matches what pasting produces.
// ============================================================================

struct BlobContentPreview: View {
    let typeMap: [String: Data]

    var body: some View {
        Group {
            if let (image, data, dataType) = firstImage() {
                if dataType.contains("pdf"), let pdf = PDFDocument(data: data) {
                    PDFPreview(document: pdf)
                } else if dataType.contains("gif") {
                    ZoomableImagePreview(image: image, animatedData: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ZoomableImagePreview(image: image, fullResData: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if let pdf = firstPDF() {
                PDFPreview(document: pdf)
            } else if let attr = firstRichText() {
                let adjusted = attr.adjustingColorsForCurrentAppearance()
                AttributedTextPreview(attributedString: adjusted)
            } else if let svg = firstSVG() {
                let plain = String(data: svg, encoding: .utf8) ?? ""
                if !plain.isEmpty { textPreview(plain, monospaced: true) }
                else { fallbackTypeList }
            } else if let html = firstHTML() {
                HTMLStringPreview(html: html)
            } else if let text = firstUTF8Text() {
                textPreview(text, monospaced: shouldMonospace(text))
            } else {
                fallbackTypeList
            }
        }
    }

    // MARK: - Type resolvers

    private static let imageTypes: [String] = [
        "public.png", "public.tiff", "public.jpeg", "public.heic",
        "public.gif", "com.compuserve.gif", "com.adobe.pdf"
    ]

    private func firstImage() -> (NSImage, Data, String)? {
        for type in Self.imageTypes {
            guard let data = typeMap[type], let img = NSImage(data: data) else { continue }
            return (img, data, type)
        }
        return nil
    }

    private func firstPDF() -> PDFDocument? {
        guard let data = typeMap["com.adobe.pdf"] else { return nil }
        return PDFDocument(data: data)
    }

    private func firstRichText() -> NSAttributedString? {
        for type in ["com.apple.flat-rtfd", "public.rtfd", "NSRTFDPboardType"] {
            if let data = typeMap[type],
               let attr = NSAttributedString(rtfd: data, documentAttributes: nil),
               !attr.string.isEmpty { return attr }
        }
        for type in ["public.rtf", "NSRTFPboardType"] {
            if let data = typeMap[type],
               let attr = NSAttributedString(rtf: data, documentAttributes: nil),
               !attr.string.isEmpty { return attr }
        }
        return nil
    }

    private func firstSVG() -> Data? {
        for type in ["public.svg-image", "com.adobe.illustrator.svg", "org.w3.svg"] {
            if let data = typeMap[type], !data.isEmpty { return data }
        }
        return nil
    }

    private func firstHTML() -> String? {
        for type in ["public.html", "Apple HTML pasteboard type"] {
            guard let data = typeMap[type] else { continue }
            let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
            if let s, !s.isEmpty { return s }
        }
        return nil
    }

    private static let plainTextPreferred = [
        "public.utf8-plain-text", "public.plain-text", "public.text", "NSStringPboardType"
    ]

    private func firstUTF8Text() -> String? {
        for type in Self.plainTextPreferred {
            if let data = typeMap[type],
               let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
               !s.isEmpty { return s }
        }
        // Some private types are actually plain UTF-8 payloads; opportunistic
        // decode as a last resort before giving up on the whole clipping.
        for (_, data) in typeMap where data.count < 128_000 {
            if let s = String(data: data, encoding: .utf8),
               !s.isEmpty, s.allSatisfy({ $0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace }) {
                return s
            }
        }
        return nil
    }

    private func shouldMonospace(_ s: String) -> Bool {
        s.contains("{") || s.contains("[") || s.contains("\t") || s.contains("<?xml")
    }

    // MARK: - Fallback

    private var fallbackTypeList: some View {
        textPreview(typeMap.keys.sorted().map { "· \($0)" }.joined(separator: "\n"),
                    monospaced: true)
    }

    private func textPreview(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Loads a file-URL image with NSImage on a background queue, shows a spinner
/// until the image lands. Cycling to a big HEIC/PNG file in the preview no
/// longer freezes main while NSImage reads and decodes the whole file.
struct AsyncImageFilePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImagePreview(image: image)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// `PDFDocument(url:)` reads and parses the whole file — for a large PDF
/// that's a real main-thread stall. Same async-decode pattern as
/// AsyncImageFilePreview above.
struct AsyncPDFFilePreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                PDFPreview(document: document)
            } else if failed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            document = nil
            failed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded { document = loaded } else { failed = true }
        }
    }
}

/// `Data(contentsOf:)` + `NSImage(data:)` for a large animated GIF is real
/// main-thread I/O + decode work. Same async pattern as the image/PDF cases.
struct AsyncGIFFilePreview: View {
    let url: URL
    @State private var loaded: (image: NSImage, data: Data)?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                ZoomableImagePreview(image: loaded.image, animatedData: loaded.data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if failed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            loaded = nil
            failed = false
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, Data)? in
                guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
                return (image, data)
            }.value
            guard !Task.isCancelled else { return }
            if let result { loaded = result } else { failed = true }
        }
    }
}
