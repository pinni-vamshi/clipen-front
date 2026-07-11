import AppKit
import AVKit
import ModelIO
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit

/// Real system NSPopover, anchored through an invisible helper panel — see the
/// header comment on PreviewOverlayWindow for why this indirection exists: an
/// NSPopover can only anchor to a view inside one of THIS app's own windows,
/// never to a rect inside another app's window, so an invisible 1×1
/// non-activating panel is positioned next to the ring popup and the popover
/// anchors to a view inside that. Gets the same benefit as the ring popup:
/// AppKit's own rounded box, vibrancy, and native pop-in animation for free,
/// instead of the hand-drawn approximation this used to be.
final class ItemPreviewPanel: NSObject, NSPopoverDelegate {
    private let anchorPanel: NSPanel
    private let anchorView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    private let popover = NSPopover()
    /// The anchor strip's frame for the CURRENT popover session, nil when
    /// hidden. Placed once per session and never moved while shown — see
    /// present() for why that invariant matters.
    private var shownStrip: NSRect? = nil
    /// True from show until hide. Closes the race where hide() lands while
    /// the popover is still ANIMATING IN — popover.isShown is false then, so
    /// the performClose was skipped and the preview finished appearing as an
    /// orphan after the popup was already gone. popoverDidShow checks this
    /// and immediately tears down any presentation nobody wants anymore.
    private var wantsVisible = false

    /// `wantsVisible` is ANDed in because NSPopover's close is animated:
    /// popover.isShown keeps returning true until the close animation
    /// finishes, ~0.2s after hide() was called. Guards that ran in that
    /// window ("is the preview open? refresh it") saw stale true and
    /// re-showed a panel that was being dismissed — the "preview reappears
    /// right after Esc closes everything" bug. Intent flips instantly;
    /// isShown alone doesn't.
    var isVisible: Bool { wantsVisible && popover.isShown }
    /// Actual on-screen content rect (not the popover window's frame, which
    /// includes AppKit's arrow/shadow chrome) — used by outside-click
    /// dismissal to know whether a click landed inside this panel.
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
        // Defensive feedback loop: this panel is shared between two owners —
        // the main ring popup's selection preview, and a QuickClipPanel's
        // "similar items" hover preview. By the time the show animation
        // actually finishes, re-verify one of those owners is still around.
        // If neither is, whatever asked for this show() has since vanished
        // (a race between show() firing and its owner closing mid-animation)
        // and this would otherwise be left floating with nothing showing it.
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

    /// Preview several marked items at once, stacked top-to-bottom in a single
    /// scrolling panel. Used when the user presses Space with a multi-paste
    /// queue active — one panel, scroll to see every marked item in order.
    func show(forItems items: [ClipboardItem], near popupFrame: NSRect, anchorPoint: NSPoint? = nil) {
        guard !items.isEmpty else { hide(); return }
        present(AnyView(MultiItemPreviewView(items: items)), width: 520, height: 520,
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

        // Stationary 1pt anchor strip spanning the source frame's full height,
        // placed ONCE per popover session and never moved while shown. The
        // previous approach — teleporting a 1×1 anchor window to the new row
        // per cycle and re-calling show() — broke AppKit's popover attachment
        // and replayed the full close+open animation on every keystroke.
        // Row tracking happens via `positioningRect` inside the fixed strip.
        // When the SOURCE frame itself changes (preview invoked from the
        // popup vs the transform picker vs a Quick Clip panel), the strip
        // must genuinely move, so that rare case is a real re-present.
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
        // Fast open with a REAL visible animation — see clipenAnimateIn.
        // animates is restored so the close keeps the native fade-out.
        popover.animates = false
        popover.show(relativeTo: rowRect, of: anchorView,
                     preferredEdge: placeRight ? .maxX : .minX)
        popover.animates = true
        popover.clipenAnimateIn()
    }

    func hide() {
        wantsVisible = false
        // Reset the SwiftUI tree so AVPlayer / QuickLook / web previews are
        // dismantled (and stop playing) — the content controller outlives the
        // popover's close, so without this a video/audio preview could keep
        // playing invisibly. The old NSPanel implementation did this too; it
        // was lost in the NSPopover conversion.
        if let hostingController = popover.contentViewController as? NSHostingController<AnyView> {
            hostingController.rootView = AnyView(EmptyView())
        }
        if popover.isShown { popover.performClose(nil) }
        anchorPanel.orderOut(nil)
        shownStrip = nil
    }
}

/// Stacked preview of every marked item, in marking order, inside one shared
/// scrolling panel with the standard popover chrome.
private struct MultiItemPreviewView: View {
    let items: [ClipboardItem]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(items.count) marked")
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
                        .padding(.leading, 8)
                    }
                }
            }
        }
        // No background/clipShape/overlay/shadow here — hosted inside a real
        // NSPopover now, which draws all of that itself.
    }
}

private struct ItemPreviewView: View {
    let item: ClipboardItem
    /// When true, renders without the outer window chrome (header/background/
    /// shadow) and at a fixed height so several can be stacked inside a shared
    /// scrolling container — used by the marked-items multi preview.
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
            // No background/clipShape/overlay/shadow here — hosted inside a
            // real NSPopover now, which draws all of that itself.
        }
    }

    // Shared across the item-preview panel, the reference panel, and (soon)
    // any other full-content surface — one dispatch, parameterized only by the
    // per-surface chrome (font size, image framing, file-row density).
    private var content: some View {
        ContentPreviewView(item: item, chrome: .panel)
    }
}

/// The single source of truth for "render a ClipboardItem's full content."
/// Previously this switch existed three times (item-preview panel, reference
/// panel, main-window detail) and drifted; the two panel surfaces now share
/// this one, differing only via `chrome`. (The main-window detail pane keeps
/// its own distinct, table-extraction-first design on purpose.)
struct ContentPreviewView: View {
    enum Chrome {
        /// Item-preview panel: 13pt text, boxed images (cr10), rich file rows.
        case panel
        /// Reference (Quick Clip) panel: 12pt text, rounded images (cr8), dense file rows.
        case reference
    }
    let item: ClipboardItem
    let chrome: Chrome

    private var plainFontSize: CGFloat { chrome == .panel ? 13 : 12 }
    /// The one file currently shown full-size, when the user tapped a
    /// thumbnail in the multi-file strip below. Non-nil shows the overlay.
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
            AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
        case .html(let html, let plain):
            // .html items only ever exist when the HTML carries real formatting
            // (see ClipboardManager+Capture's htmlMustSurvive check), so render
            // it properly; fall back to flattened plain text only if empty.
            if plain.isEmpty && html.isEmpty {
                textPreview(plain, monospaced: false)
            } else {
                HTMLStringPreview(html: html)
            }
        case .rtfd(let data, let plain):
            if let attrStr = NSAttributedString(rtfd: data, documentAttributes: nil) {
                AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
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
        // PDFs captured as image-typed pasteboard data get a real, zoomable PDF
        // view; GIFs get the animated variant; everything else decodes full-res
        // ONCE inside the view (never in body — that inline decode was the
        // v1.0.144 CPU/memory churn regression).
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

    /// Full `.files` preview: the existing name/icon list, plus — when the
    /// set has any non-text element (image, video, PDF, or any other binary
    /// file) — a horizontal thumbnail strip pinned to the bottom. Tapping a
    /// thumbnail opens that ONE element full-size in an overlay, from which
    /// it can be pasted on its own (see ClipboardManager.pasteSingleFile).
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

    /// One element blown up full-size with a close button and a "Paste"
    /// action that pastes ONLY this file — independent of the multi-file
    /// item it came from. Reuses FilePreviewContent, so images zoom/pan,
    /// PDFs/video/3D models are all already interactive exactly as they are
    /// everywhere else in the app.
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

/// Extracts a cell grid out of table-bearing clipboard content so the row
/// views (main popup rows, main window rows) can render an actual mini table
/// instead of flattened plain text. Handles the two ways tables arrive:
///   • richText/rtfd (Apple Notes, Pages, Word…) — NSTextTable blocks in the
///     attributed string's paragraph styles, addressed by row/column.
///   • html (browsers, Excel-as-html…) — <tr>/<td> parsed with a light regex.
/// Results are NSCache'd per item ID — extraction walks the whole attributed
/// string, far too heavy to redo on every scroll-frame row render.
enum TableCellExtractor {
    private static let cache: NSCache<NSUUID, NSArray> = {
        let c = NSCache<NSUUID, NSArray>()
        // Bound it like the other caches (ItemThumbnailCache, ClipenIconCache)
        // rather than relying solely on system memory-pressure eviction. The
        // ring tops out at 500 items, so this comfortably covers a full ring.
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

/// Compact real-table rendering for LIST ROWS (main popup + main window):
/// a bordered grid of the first few rows/columns, so a copied table looks
/// like a table at a glance instead of two lines of flattened text. The
/// full-fidelity rendering still lives in the preview panel.
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

/// Dispatches `.text` content by its DETECTED type (markdown / delimited
/// table / code) instead of always rendering plain monospaced text — the
/// detection (ClipboardContentType) already existed, but nothing previously
/// rendered based on it. Shared between ItemPreviewPanel and QuickClipPanel.
struct RichTextContentPreview: View {
    let text: String
    let detectedType: ClipboardContentType

    var body: some View {
        // Trimmed once here so every sub-case below (markdown/table/code/
        // plain) benefits — a copy that happens to start with blank lines
        // no longer opens the preview on empty space. Then CAPPED — a huge
        // pasted blob (a JSON dump, a giant log paste) is already fully in
        // memory (no file to bound), but handing it whole to a SwiftUI Text
        // view still costs real layout time on every render; this bounds
        // what's actually RENDERED, never what gets pasted/searched.
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
                    // Detection picks ONE type for the whole item — a code file
                    // or markdown doc that happens to contain a delimited-
                    // looking block could get classified as .table overall,
                    // and this used to render ONLY the parsed grid, discarding
                    // the rest of the text. Show both: the real content stays
                    // visible, with the table rendered as a grid underneath.
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

/// Line-based Markdown renderer — headers, bullet/numbered lists, fenced code
/// blocks (routed to CodeSyntaxPreview), and inline formatting (bold/italic/
/// code spans/links) via AttributedString. Not a full CommonMark parser, but
/// covers what people actually paste.
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

/// Renders CSV/TSV-shaped text as an actual grid instead of raw delimited
/// text — tries tab first (TSV), falls back to comma (CSV). First row is
/// styled as a header.
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

/// Lightweight, best-effort syntax coloring — real per-language keyword sets
/// (not the detection heuristics CodeLanguageDetector uses, which are
/// fingerprint phrases like "if __name__", not actual reserved words) plus
/// generic string/number/whole-line-comment coloring. This is NOT a full
/// tokenizer/parser per language (no block comments, no escape-aware string
/// parsing, no inline trailing comments) — it's a genuine, working
/// approximation, not a placeholder.
struct CodeSyntaxPreview: View {
    let text: String
    let language: String?

    private static let keywordSets: [String: Set<String>] = [
        "Swift": ["func","var","let","if","else","guard","return","struct","class","enum","protocol",
                  "extension","import","for","while","switch","case","default","break","continue","init",
                  "self","Self","super","true","false","nil","private","public","internal","static",
                  "override","in","as","is","try","catch","throw","throws","async","await"],
        "Python": ["def","class","if","elif","else","return","import","from","for","while","in","try",
                   "except","finally","with","as","pass","break","continue","lambda","None","True",
                   "False","and","or","not","is","yield","global","nonlocal","raise","assert","del"],
        "JavaScript": ["function","const","let","var","if","else","return","for","while","do","switch",
                       "case","default","break","continue","class","extends","new","this","try","catch",
                       "finally","throw","typeof","instanceof","in","of","async","await","import",
                       "export","from","null","undefined","true","false"],
        "TypeScript": ["function","const","let","var","if","else","return","for","while","interface",
                       "type","class","extends","implements","new","this","try","catch","finally",
                       "throw","import","export","from","null","undefined","true","false","public",
                       "private","protected","readonly","async","await"],
        "Rust": ["fn","let","mut","if","else","match","for","while","loop","return","struct","enum",
                 "impl","trait","pub","use","mod","self","true","false","as","in","break","continue",
                 "async","await","move","ref","where"],
        "Go": ["func","var","const","if","else","for","range","switch","case","default","return",
               "package","import","struct","interface","go","chan","select","defer","break",
               "continue","true","false","nil","type","map"],
        "Kotlin": ["fun","val","var","if","else","for","while","when","return","class","interface",
                   "object","package","import","true","false","null","is","as","in","override",
                   "private","public","companion","data"],
        "Java": ["public","private","protected","class","interface","extends","implements","static",
                 "final","void","if","else","for","while","switch","case","default","return","new",
                 "this","super","true","false","null","try","catch","finally","throw","throws",
                 "import","package"],
        "C/C++": ["int","float","double","char","void","if","else","for","while","do","switch","case",
                  "default","return","struct","class","public","private","protected","namespace",
                  "using","include","define","static","const","true","false","nullptr","new","delete",
                  "template","typename"],
        "Shell": ["if","then","else","elif","fi","for","while","do","done","case","esac","function",
                  "return","echo","export","local","in"],
        "Ruby": ["def","end","class","module","if","elsif","else","unless","case","when","for","while",
                 "until","return","true","false","nil","self","require","attr_accessor","yield",
                 "begin","rescue","ensure"],
        "SQL": ["SELECT","FROM","WHERE","INSERT","INTO","VALUES","UPDATE","SET","DELETE","CREATE",
                "TABLE","ALTER","DROP","JOIN","LEFT","RIGHT","INNER","OUTER","ON","GROUP","BY",
                "ORDER","HAVING","AND","OR","NOT","NULL","AS","DISTINCT","LIMIT"]
    ]

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
        }
    }

    private var highlighted: AttributedString {
        var result = AttributedString()
        let keywords = language.flatMap { Self.keywordSets[$0] } ?? []
        for line in text.components(separatedBy: "\n") {
            result += highlightLine(line, keywords: keywords)
            result += AttributedString("\n")
        }
        return result
    }

    private func highlightLine(_ line: String, keywords: Set<String>) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") {
            var s = AttributedString(line)
            s.foregroundColor = .secondary
            return s
        }

        var result = AttributedString()
        var current = ""
        var inString: Character? = nil

        func flushWord() {
            guard !current.isEmpty else { return }
            var piece = AttributedString(current)
            if keywords.contains(current) {
                piece.foregroundColor = .purple
                piece.font = .system(size: 12, weight: .semibold, design: .monospaced)
            } else if current.first?.isNumber == true {
                piece.foregroundColor = .orange
            }
            result += piece
            current = ""
        }

        for ch in line {
            if let quote = inString {
                current.append(ch)
                if ch == quote {
                    var piece = AttributedString(current)
                    piece.foregroundColor = .green
                    result += piece
                    current = ""
                    inString = nil
                }
                continue
            }
            if ch == "\"" || ch == "'" {
                flushWord()
                inString = ch
                current = String(ch)
                continue
            }
            if ch.isLetter || ch.isNumber || ch == "_" {
                current.append(ch)
            } else {
                flushWord()
                result += AttributedString(String(ch))
            }
        }
        if inString != nil {
            var piece = AttributedString(current)
            piece.foregroundColor = .green
            result += piece
        } else {
            flushWord()
        }
        return result
    }
}

/// Loads a text file's contents off the main thread and shows a spinner
/// meanwhile, instead of FilePreviewContent's old behavior of reading (and
/// decoding — up to 3 encoding attempts) the whole file synchronously inside
/// `body`, which blocked the entire view update — including switching the
/// selection to a DIFFERENT item — until a large file finished loading.
/// `.task(id: url)` automatically cancels the in-flight load the instant
/// `url` changes, so navigating away never waits for a stale read to finish.
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
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, isTruncated ? 8 : 0)
                    }
                }
            } else if loadFailed {
                // Extension said "text," but the read failed (oversized,
                // undecodable) — fall back to the same generic icon view
                // FilePreviewContent's own last-resort branch uses.
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
            // Bounded-prefix read (readableTextPreview), not the full file —
            // a preview should load fast regardless of how large the file
            // actually is. The full content is still what gets pasted/
            // embedded elsewhere (readableText, untouched); this is a
            // fast, honest glance, not the source of truth.
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

/// Full per-type file preview dispatch (PDF, image, GIF, HTML, plain text,
/// media, 3D model, QuickLook fallback, or a generic icon+name+path as a last
/// resort). Shared between ItemPreviewPanel's own preview and QuickClipPanel
/// so both surfaces render files identically — QuickClipPanel used to have
/// its own much weaker duplicate that only ever showed an icon + filename,
/// never actual PDF/image/media content.
struct FilePreviewContent: View {
    let url: URL

    var body: some View {
        Group {
            if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
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
                // isTextFile is a cheap extension check — the actual file
                // read (readableText, up to 200 MB, tries 3 encodings) now
                // happens off-main inside AsyncTextFilePreview instead of
                // synchronously here in body. That synchronous read used to
                // block the ENTIRE view update — including moving the
                // selection to a different item — until a large file
                // finished loading. Now navigation is instant; the preview
                // itself shows a spinner until its text is ready.
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
                // Fallback when the file isn't on disk (e.g. evicted snapshot) but
                // we cached extractable text from a document (docx, pptx, pages…).
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

/// Renders a 3D model as a rotatable/zoomable scene. SceneKit loads .scn/.usd*
/// natively; everything else (.obj/.stl/.fbx/.gltf/.dae/.ply/.abc/.glb) is
/// bridged in through Model I/O's MDLAsset → SCNScene importer. Falls back to a
/// label if a format can't be decoded on this OS.
struct Model3DPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator { var loadedURL: URL? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SpinUntilTouchedSCNView()
        view.allowsCameraControl = true      // drag to rotate, scroll to zoom
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = Self.loadScene(url)
        context.coordinator.loadedURL = url
        // The preview panel is non-activating (never key), so mouse-drag rotation
        // can't reach SceneKit. Auto-spin the whole scene so the model is seen
        // from all sides without interaction. Drag still works in any window that
        // CAN become key (the reference panel, the main window) — and there the
        // spin stops on the first touch, so the camera doesn't fight the drag
        // (see SpinUntilTouchedSCNView).
        Self.startAutoRotation(in: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        // Only re-parse the scene when the URL actually changed — popup-adjacent
        // views re-render on every keystroke, and loadScene does file I/O +
        // MDLAsset/SCNScene parsing that would otherwise run (and reset the
        // spin) on each pass. Matches the guard the sibling previews use.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        view.scene = Self.loadScene(url)
        Self.startAutoRotation(in: view)
    }

    /// Auto-spin is a showcase for when the model CAN'T be interacted with —
    /// the moment the user actually grabs it (drag, scroll-zoom, or pinch in
    /// a key-capable window like the reference panel), the spin must yield,
    /// otherwise the pivot keeps rotating underneath the camera drag and the
    /// model feels like it's fighting the mouse.
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

    /// Wrap the model in a pivot node and spin it slowly around Y. Idempotent —
    /// re-running on the same scene won't stack multiple rotations.
    private static func startAutoRotation(in view: SCNView) {
        guard let scene = view.scene else { return }
        let pivotName = "clipenAutoSpin"
        if scene.rootNode.childNode(withName: pivotName, recursively: false) != nil { return }
        let pivot = SCNNode()
        pivot.name = pivotName
        // Re-parent all existing top-level content under the spinning pivot.
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
        // Native path: SceneKit reads .scn and USD variants directly.
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            return scene
        }
        // Bridge path: Model I/O imports OBJ/STL/PLY/DAE/Alembic, etc.
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        return scene
    }
}

/// Plays animated GIFs. SwiftUI's `Image` is static and shows only the first
/// frame; `NSImageView` with `animates = true` runs the GIF's frame loop.
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
        // Re-decode ONLY when the payload actually changed. This runs on
        // every SwiftUI render pass — and popup rows re-render on every
        // keypress (hint flags) — so unconditionally rebuilding NSImage
        // meant a full GIF decode + animation restart per keystroke.
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
        view.allowsMagnification = true // pinch-zoom, like Safari
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
        // Auto-play as soon as the preview opens.
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Only swap the player when the URL actually changes to avoid restarting.
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        // Called when the panel is hidden — stop playback immediately.
        view.player?.pause()
        view.player = nil
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true   // Auto-play audio/video inside QuickLook previews.
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // Clear the preview item when the panel is hidden so QL stops any playback.
        view.previewItem = nil
    }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        // Interactive zoom: pinch on a trackpad zooms, scrolling pans —
        // PDFView supports both natively but clamps to autoScales' fit
        // factor unless the min/max range is opened up. minScaleFactor
        // pinned to the size-to-fit factor keeps "zoomed all the way out"
        // meaning "the whole page visible", never a lost-in-space sliver.
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

    /// Same non-key-window reality as FitOnLayoutScrollView (see its doc
    /// comment): the preview popover and reference panel never become key,
    /// so PDFView's own gesture plumbing can't be relied on there. Pinch
    /// and ⌘-scroll are handled from the raw pointer-routed events, and
    /// acceptsFirstMouse lets link-clicks/drag-pans land on first click.
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

/// Zoomable, pannable image preview — one shared component for every place
/// an image renders large (the floating item preview, the reference panel's
/// content area, file previews). Pinch (or double-click) to zoom, scroll to
/// pan while zoomed, double-click again to snap back to fit. Built on
/// NSScrollView's native magnification so gestures feel identical to
/// Preview.app rather than a hand-rolled SwiftUI gesture approximation.
struct ZoomableImagePreview: NSViewRepresentable {
    let image: NSImage
    /// When set, the image view animates this payload's frame loop (GIFs) —
    /// SwiftUI's Image and a plain NSImage assignment both show only the
    /// first frame. Zoom/pan behave identically either way; animation is
    /// the only difference, so GIFs get the same interactions as stills
    /// instead of a separate non-zoomable code path.
    var animatedData: Data? = nil
    /// Full-resolution compressed bytes — when set, the view decodes THESE
    /// (once) instead of showing `image`, which is only a ≤1024px ring
    /// thumbnail for image items. The decode MUST happen in here, gated by
    /// the data-changed check, and never at the call site: this view's
    /// parent bodies re-evaluate on every @Published change (the popup
    /// re-renders per keystroke), and a v1.0.144 regression that decoded
    /// `NSImage(data:)` inline in those bodies re-decoded a multi-MB bitmap
    /// on every render pass — 18% idle CPU and ~1 GB of memory churn.
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
        } else if let fullResData, let full = NSImage(data: fullResData) {
            imageView.image = full
            scrollView.lastImageDataCount = fullResData.count
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
            // Same change-detection AnimatedImageView uses: re-decode only
            // when the payload actually changed, never per render pass
            // (updateNSView runs on every SwiftUI render).
            guard scrollView.lastImageDataCount != animatedData.count else { return }
            imageView.image = NSImage(data: animatedData)
            imageView.animates = true
            scrollView.lastImageDataCount = animatedData.count
            scrollView.magnification = 1
        } else if let fullResData {
            guard scrollView.lastImageDataCount != fullResData.count else { return }
            imageView.image = NSImage(data: fullResData) ?? image
            scrollView.lastImageDataCount = fullResData.count
            scrollView.magnification = 1
        } else if imageView.image !== image {
            imageView.image = image
            scrollView.magnification = 1
        }
    }

    /// NSScrollView whose document view tracks the visible area while at 1×
    /// (so "not zoomed" always means "image fits the panel", including after
    /// a window resize), and stops fighting the user once they've zoomed in.
    ///
    /// Every interaction below is handled from RAW pointer-routed events, on
    /// purpose: this view lives inside non-activating panels and popovers
    /// (the Space preview, the reference panel, similar-item previews) whose
    /// windows may NEVER become key — the entire popup UI is deliberately
    /// non-activating so keyboard focus stays in the app being pasted into.
    /// In that world, gesture recognizers don't reliably engage and first
    /// clicks are swallowed, which made zoom look completely dead. Scroll
    /// and magnify events, however, are delivered to the window under the
    /// POINTER regardless of key/active state — so pinch and ⌘-scroll are
    /// handled explicitly, and acceptsFirstMouse makes the first click land.
    final class FitOnLayoutScrollView: NSScrollView {
        /// Byte count of the animated payload currently decoded into the
        /// image view — updateNSView's cheap "did the GIF actually change"
        /// check, mirroring AnimatedImageView's coordinator.
        var lastImageDataCount: Int?

        override func layout() {
            super.layout()
            if magnification <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        /// First click acts immediately (double-click zoom included) even
        /// while the window isn't key — it never becomes key in the popup.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Trackpad pinch-to-zoom is NOT hand-rolled here. `allowsMagnification
        // = true` (set in makeNSView) already gives this scroll view Apple's
        // own native pinch handling — correctly centered at the pinch
        // location, momentum-aware, and coexisting cleanly with panning —
        // for free. A previous version reimplemented this via a raw
        // `magnify(with:)` override with custom centering math, which is
        // exactly the kind of thing that can go subtly wrong (reported: pinch
        // didn't reliably zoom, and panning after zooming didn't work
        // properly). Deleting the custom override in favor of AppKit's own,
        // more thoroughly-tested implementation fixes both: native pinch
        // zoom, AND panning (a magnified NSScrollView pans via drag/scroll
        // automatically) work the way the platform already guarantees.

        /// ⌘-scroll zooms (mouse-wheel users, and the guaranteed-delivery
        /// fallback everywhere trackpad pinch isn't available); plain
        /// scroll/drag pans — NSScrollView's own default behavior once
        /// magnified, so it's a straight `super` call, not reimplemented.
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
            // Landing back at 1× must re-fit — layout() skips the re-fit
            // while zoomed, so a resize mid-zoom would otherwise leave a
            // stale fit frame behind. (Native pinch zoom re-triggers
            // layout() on every magnification change already, so it gets
            // this re-fit for free without needing the same explicit call.)
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
            // Zooming back out to 1× must also re-fit the document frame in
            // case the window was resized while zoomed (layout() skips the
            // re-fit whenever magnification is above 1).
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
        view.setValue(false, forKey: "drawsBackground") // Make background transparent
        view.allowsMagnification = true // pinch-zoom on tables, like Safari
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

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true // For RTFD graphics
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

// MARK: - Live website preview (shared with QuickClipPanel)

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
        webView.allowsMagnification = true // pinch-zoom, like Safari
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
