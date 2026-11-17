import AppKit
import CryptoKit
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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                RichTextContentPreview(text: text, detectedType: item.detectedType)
            }
        case .richText(let attrStr, _):
            let adjusted = attrStr.adjustingColorsForCurrentAppearance()
            AttributedTextPreview(attributedString: adjusted)
        case .html(let html, let plain):
            if plain.isEmpty && html.isEmpty {
                textPreview(plain, monospaced: false)
            } else {
                HTMLStringPreview(html: html)
            }
        case .rtfd(let data, let plain):
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if let adjusted = AdjustedAttrCache.shared.adjustedRTFD(itemID: item.id, data: data, isDark: isDark) {
                AttributedTextPreview(attributedString: adjusted)
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
            SVGPreview(source: src, fontSize: plainFontSize)
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
    private func filesPreview(_ urls: [URL]) -> some View {
        // Every element that was copied, one below another, each showing its
        // own real preview — nothing else. No filename/path list, and no
        // bottom thumbnail bar.
        //
        // Image files deliberately do NOT go through FilePreviewContent
        // here: that routes to AsyncImageFilePreview -> ZoomableImagePreview,
        // an NSScrollView-backed magnifiable view holding a full-resolution
        // NSImage. Stacking two or three of those (each rescaling several
        // megapixels into a 220pt cell) is what made cycling onto a
        // multi-file row stutter compared with every other row. A stacked
        // cell can't be zoomed anyway, so it only needs the same
        // downsampled, already-cached thumbnail the list row itself decoded.
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(urls, id: \.path) { url in
                    Group {
                        if FileKindDetector.isImageFile(url) {
                            StackedImagePreviewCell(url: url)
                        } else {
                            FilePreviewContent(url: url)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: chrome == .panel ? 220 : 140)
                }
            }
            .padding(chrome == .panel ? 12 : 6)
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

    static func htmlIsDataTable(_ html: String) -> Bool {
        guard let rows = cells(fromHTML: html) else { return false }
        return isDataTable(rows)
    }

    /// Share of the clip's visible text that lives inside its tables, used
    /// to decide whether this clip *is* a table or merely *contains* one.
    ///
    /// A table is very often a small part of a much larger page — one
    /// two-row spec table in the middle of a long article, a pricing grid
    /// under three paragraphs of copy. Tagging the whole clip `.table`
    /// because a `<table>` appeared somewhere inside it would mislabel the
    /// clip, hand the wrong preview to the popup, and route it into the
    /// table-to-JSON conversion, which would then throw away everything
    /// that wasn't in the table. Measuring instead of just testing for
    /// presence is what separates "this clip is a table" from "this clip
    /// has a table in it."
    ///
    /// Non-dominant tables are NOT lost: `cells(fromHTML:)` still extracts
    /// them for preview and the table editor, and `segments(for:)` still
    /// splits mixed content into text and table parts. This governs the
    /// TAG only.
    static func htmlTableDominance(_ html: String) -> Double {
        HTMLTableParser.tableDominance(inHTML: html)
    }

    /// Minimum share of the text a table must be for the clip to be tagged
    /// `.table`. Matches the fill-ratio threshold `isDataTable` already
    /// uses, so both "is this shaped like data" and "is this mostly the
    /// table" answer to the same bar.
    static let tableDominanceThreshold = 0.6

    /// Non-table text this side of a caption. A ratio alone can't tell
    /// "a table under a one-line heading" from "a table buried in an
    /// article" — a short lead-in over a small table scores about 0.59 and
    /// would be rejected on ratio, even though the clip plainly *is* the
    /// table. Anything under roughly a sentence or two of surrounding text
    /// is a caption, not competing content.
    static let tableCaptionBudget = 160

    /// The tag-level question: is this clip essentially a data table?
    /// Requires a real, well-formed data grid, AND that the grid is either
    /// most of the text or leaves no more than a caption beside it.
    static func htmlIsDominantDataTable(_ html: String) -> Bool {
        guard htmlIsDataTable(html) else { return false }
        let split = HTMLTableParser.tableTextSplit(inHTML: html)
        guard split.total > 0 else { return false }
        let ratio = Double(split.table) / Double(split.total)
        return ratio >= tableDominanceThreshold
            || (split.total - split.table) <= tableCaptionBudget
    }

    /// Same question for rich text / RTFD, which carry tables as
    /// `NSTextTableBlock` runs rather than markup — a table copied out of
    /// Numbers, Excel or Word arrives this way, and hit exactly the same
    /// "tagged by plain-text fallback only" bug that HTML did.
    static func attributedIsDominantDataTable(_ attr: NSAttributedString) -> Bool {
        guard let rows = cells(from: attr), isDataTable(rows) else { return false }
        let tableChars = rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.filter { !$0.isWhitespace }.count } }
        let totalChars = attr.string.filter { !$0.isWhitespace }.count
        guard totalChars > 0 else { return false }
        let ratio = Double(min(tableChars, totalChars)) / Double(totalChars)
        return ratio >= tableDominanceThreshold
            || max(0, totalChars - tableChars) <= tableCaptionBudget
    }

    static func pureText(for item: ClipboardItem) -> String? {
        if let rows = cells(for: item), isDataTable(rows) {
            return rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
        }
        switch item.content {
        case .html(_, let plain):
            return cleanedPlainText(plain)
        case .richText(let attr, let plain):
            return cleanedPlainText(attr.string.isEmpty ? plain : attr.string)
        case .rtfd(let data, let plain):
            if let attr = NSAttributedString(rtfd: data, documentAttributes: nil),
               !attr.string.isEmpty {
                return cleanedPlainText(attr.string)
            }
            return cleanedPlainText(plain)
        default:
            return nil
        }
    }

    static func isDataTable(_ rows: [[String]]) -> Bool {
        guard rows.count >= 2 else { return false }
        let widths = Set(rows.map(\.count))
        guard widths.count == 1, let cols = widths.first, cols >= 2 else { return false }
        let filled = rows.reduce(0) { $0 + $1.filter { !$0.isEmpty }.count }
        return Double(filled) / Double(rows.count * cols) >= 0.6
    }

    static func cleanedPlainText(_ s: String) -> String {
        let raw = s.replacingOccurrences(of: "\r\n", with: "\n")
        var out: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let collapsed = line
                .replacingOccurrences(of: "[ \\t]*\\t[ \\t]*", with: "\t",
                                      options: .regularExpression)

                .replacingOccurrences(of: " +([.,])", with: "$1",
                                      options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if collapsed.isEmpty {
                if out.last?.isEmpty == false { out.append("") }
            } else {
                out.append(collapsed)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
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

    /// Real DOM parse first; the regex below is only a fallback for input
    /// libxml2 refuses outright.
    ///
    /// The regex path cannot express what HTML tables actually do. It reads
    /// `<tr>...</tr>` non-greedily, so a table nested inside a cell ends the
    /// OUTER row at the INNER `</tr>` — layout and email HTML nest tables
    /// constantly. It also has no way to see `colspan`/`rowspan`, so a
    /// merged header emits fewer cells than the rows below it, `isDataTable`
    /// sees a ragged width and rejects the whole table, and a genuine table
    /// silently stops being one. `HTMLTableParser` walks a real tree, takes
    /// only rows structurally belonging to the table in hand, and expands
    /// spans into a dense grid, which is what makes widths uniform.
    private static func cells(fromHTML html: String) -> [[String]]? {
        if let grid = HTMLTableParser.bestGrid(fromHTML: html), !grid.isEmpty {
            return grid
        }
        return cellsViaRegex(fromHTML: html)
    }

    private static func cellsViaRegex(fromHTML html: String) -> [[String]]? {
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

            if cells.contains(where: { !$0.isEmpty }) { rows.append(cells) }
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

    /// Prose between tables, via the same parser the capture path uses.
    ///
    /// This was a third, weaker HTML-to-text implementation: four regex
    /// passes that knew only `<br>`, `</p>` and `</div>`, so headings and
    /// list items ran together and `.htmlDecoded` handled only the entities
    /// it happened to know. Sharing `TidyHTML` means these chunks get the
    /// same block separation, list markers and entity decoding as everything
    /// else — and, more to the point, they stop silently losing non-ASCII
    /// the way this file's table extraction did.
    ///
    /// The old passes remain as the fallback for markup too broken to parse.
    private static func stripHTMLTags(_ html: String) -> String {
        if let parsed = TidyHTML.plainText(html) { return parsed }
        return html.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .htmlDecoded
    }
}

/// HTML table extraction over a real document tree, via `XMLDocument`'s
/// `.documentTidyHTML` mode (libxml2's HTML parser, already part of
/// Foundation — no new dependency, and it recovers from the malformed
/// markup real clipboard HTML is full of: unclosed `<tr>`, stray tags,
/// missing `<tbody>`).
///
/// Everything here exists because the regex it replaced could not, even in
/// principle, answer three questions that decide whether a table survives:
/// which table a row belongs to (nesting), how wide a row really is
/// (`colspan`/`rowspan`), and how much of the clip the table actually is.
enum HTMLTableParser {
    /// A single cell claiming thousands of columns is malformed or hostile;
    /// either way it must not be allowed to allocate a grid that size.
    private static let maxSpan = 64
    private static let maxRows = 2000

    private static func document(_ html: String) -> XMLDocument? {
        // Via TidyHTML, not a bare XMLDocument call: parsing raw UTF-8 with
        // no declared encoding silently drops every non-ASCII character, so
        // currency symbols, accented names and CJK were being stripped out
        // of extracted tables. See TidyHTML for the measurements.
        TidyHTML.document(html)
    }

    /// Tables that are not themselves inside another table. A nested table
    /// is part of its parent's cell, not a table in its own right.
    private static func topLevelTables(_ doc: XMLDocument) -> [XMLElement] {
        let nodes = (try? doc.nodes(forXPath: "//table[not(ancestor::table)]")) ?? []
        return nodes.compactMap { $0 as? XMLElement }
    }

    private static func cellText(_ el: XMLElement) -> String {
        (el.stringValue ?? "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rows structurally belonging to THIS table. Selecting direct children
    /// (plus the section elements tidy inserts) rather than descendants is
    /// what keeps a nested table's rows out — the exact failure the regex
    /// had, where an inner `</tr>` truncated the outer row.
    private static func directRows(_ table: XMLElement) -> [XMLElement] {
        let nodes = (try? table.nodes(forXPath: "./tr | ./thead/tr | ./tbody/tr | ./tfoot/tr")) ?? []
        return nodes.compactMap { $0 as? XMLElement }
    }

    /// One table as a dense, uniform-width grid with `colspan`/`rowspan`
    /// expanded — a spanned cell is written into every slot it covers.
    ///
    /// Uniform width is the point: `isDataTable` requires every row to have
    /// the same count, and merged header cells are precisely why real
    /// tables used to fail that test.
    static func grid(from table: XMLElement) -> [[String]] {
        var filled: [[String?]] = []
        func ensure(_ r: Int, _ c: Int) {
            while filled.count <= r { filled.append([]) }
            while filled[r].count <= c { filled[r].append(nil) }
        }

        for (r, rowEl) in directRows(table).prefix(maxRows).enumerated() {
            let cellEls = ((try? rowEl.nodes(forXPath: "./td | ./th")) ?? [])
                .compactMap { $0 as? XMLElement }
            var c = 0
            for cell in cellEls {
                ensure(r, c)
                // Step over slots a rowspan from an earlier row already owns.
                while c < filled[r].count, filled[r][c] != nil { c += 1 }
                let text = cellText(cell)
                let colspan = min(maxSpan, max(1, Int(cell.attribute(forName: "colspan")?.stringValue ?? "1") ?? 1))
                let rowspan = min(maxSpan, max(1, Int(cell.attribute(forName: "rowspan")?.stringValue ?? "1") ?? 1))
                for dr in 0..<rowspan {
                    for dc in 0..<colspan {
                        ensure(r + dr, c + dc)
                        filled[r + dr][c + dc] = text
                    }
                }
                c += colspan
            }
        }

        let width = filled.map(\.count).max() ?? 0
        guard width > 0 else { return [] }
        return filled
            .map { row in (0..<width).map { $0 < row.count ? (row[$0] ?? "") : "" } }
            .filter { $0.contains { !$0.isEmpty } }
    }

    /// The largest top-level table, by cell count — when a page holds
    /// several, the biggest is the one the clip is actually about.
    static func bestGrid(fromHTML html: String) -> [[String]]? {
        guard let doc = document(html) else { return nil }
        let grids = topLevelTables(doc).map { grid(from: $0) }.filter { !$0.isEmpty }
        return grids.max { lhs, rhs in
            lhs.count * (lhs.first?.count ?? 0) < rhs.count * (rhs.first?.count ?? 0)
        }
    }

    /// Visible, whitespace-stripped character counts: how much text is
    /// inside top-level tables, and how much the document holds in total.
    /// Returned as both numbers rather than a ratio because the caller
    /// needs the absolute remainder too — a ratio alone can't distinguish
    /// a caption from an article (see `tableCaptionBudget`).
    static func tableTextSplit(inHTML html: String) -> (table: Int, total: Int) {
        guard let doc = document(html), let root = doc.rootElement() else { return (0, 0) }
        func visibleLength(_ s: String?) -> Int {
            (s ?? "").replacingOccurrences(of: "\\s+", with: "", options: .regularExpression).count
        }
        let total = visibleLength(root.stringValue)
        guard total > 0 else { return (0, 0) }
        let tableChars = topLevelTables(doc).reduce(0) { $0 + visibleLength($1.stringValue) }
        return (min(tableChars, total), total)
    }

    /// Share of the document's visible text that sits inside top-level
    /// tables. 1.0 is a clip that is nothing but table; a lone spec table
    /// inside a long article scores near zero.
    static func tableDominance(inHTML html: String) -> Double {
        let split = tableTextSplit(inHTML: html)
        guard split.total > 0 else { return 0 }
        return min(1.0, Double(split.table) / Double(split.total))
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

/// Link previews: a web page is rendered ONCE, kept as a picture, and the
/// page itself is thrown away.
///
/// This used to keep up to seven live web pages in a pool — scripts, ads,
/// video and animation all still running, each in its own WebKit process —
/// for as long as Clipen ran, whether or not anything was showing them, and
/// prefetching while cycling added more. A clipboard manager sits in the
/// background all day; that was CPU and memory spent on pages nobody was
/// looking at.
///
/// Now: the first time a link is previewed it loads live, a snapshot is
/// taken once it has finished, and from then on the preview is that
/// snapshot (memory, then disk) — no page, no process. Scrolling or clicking
/// the snapshot brings the live page back, and the reference panel's
/// Reload button always loads it fresh.
/// Links Clipen must never open on its own. Requesting a link is not
/// harmless: a sign-in link, password reset, email verification, invite or
/// unsubscribe/approve link is spent by the first GET, so a background title
/// fetch or preview prefetch left the user with "this link has expired".
/// Signed URLs (S3 and friends) and anything carrying a token are private too.
enum LinkSafety {
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "refresh_token", "auth", "authtoken",
        "code", "otp", "key", "apikey", "api_key", "secret", "sig", "signature",
        "password", "pass", "pwd", "session", "sessionid", "sid", "ticket",
        "nonce", "state", "magic", "hash", "jwt", "invite", "reset",
        "x-amz-signature", "x-amz-credential", "x-goog-signature", "se", "sv", "sp",
    ]
    private static let sensitivePathWords = [
        "login", "signin", "sign-in", "sign_in", "logout", "signout", "auth", "oauth",
        "magic", "verify", "verification", "confirm", "activate", "reset", "password",
        "invite", "invitation", "unsubscribe", "approve", "accept", "decline",
        "callback", "token", "otp", "2fa", "mfa", "sso", "saml", "download",
    ]

    static func mustNotAutoOpen(_ url: URL) -> Bool {
        if url.user != nil || url.password != nil { return true }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in items {
                let name = item.name.lowercased()
                if sensitiveQueryKeys.contains(name) || name.contains("token") || name.contains("signature") {
                    return true
                }
                // A long random-looking value is a credential whatever it's called.
                if let v = item.value, v.count >= 24,
                   v.allSatisfy({ $0.isLetter || $0.isNumber || "-_.~%=+/".contains($0) }),
                   v.contains(where: \.isNumber), v.contains(where: \.isLetter) {
                    return true
                }
            }
        }
        if let fragment = url.fragment?.lowercased(),
           fragment.contains("token") || fragment.contains("code=") { return true }
        let path = url.path.lowercased()
        let segments = path.split(whereSeparator: { $0 == "/" || $0 == "." })
        return segments.contains { seg in sensitivePathWords.contains { seg.contains($0) } }
    }
}

final class WebsitePreviewPool {
    static let shared = WebsitePreviewPool()

    private let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 40
        return cache
    }()
    private let diskQueue = DispatchQueue(label: "com.clipen.web-snapshots", qos: .utility)
    private let diskDir: URL
    /// A snapshot older than this is re-rendered: pages do change.
    private static let snapshotLifetime: TimeInterval = 3 * 24 * 60 * 60
    private static let maxDiskSnapshots = 200

    private init() {
        diskDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.clipen.app/WebSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    private func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func diskURL(_ url: URL) -> URL { diskDir.appendingPathComponent(key(url) + ".jpg") }

    func snapshot(for url: URL) -> NSImage? {
        let k = key(url) as NSString
        if let hit = memory.object(forKey: k) { return hit }
        let file = diskURL(url)
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
              Date().timeIntervalSince(modified) < Self.snapshotLifetime,
              let image = NSImage(contentsOf: file) else { return nil }
        memory.setObject(image, forKey: k)
        return image
    }

    func storeSnapshot(_ image: NSImage, for url: URL) {
        // Snapshots are unencrypted cache files: none for private links.
        guard !LinkSafety.mustNotAutoOpen(url) else { return }
        memory.setObject(image, forKey: key(url) as NSString)
        let file = diskURL(url)
        let dir = diskDir
        diskQueue.async {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
            else { return }
            try? jpeg.write(to: file, options: .atomic)
            Self.pruneDisk(in: dir)
        }
    }

    private static func pruneDisk(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > maxDiskSnapshots else { return }
        let byAge = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
        for stale in byAge.prefix(files.count - maxDiskSnapshots) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    func makeWebView() -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsMagnification = true
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    // MARK: Prefetch

    /// Prefetch loads a page ONCE, invisibly, so WebKit's shared cache holds
    /// it when the preview is opened — then lets the page go. At most two at
    /// a time, and each is torn down after it finishes or 15 seconds.
    private var prefetching: [String: (view: WKWebView, delegate: PrefetchDelegate)] = [:]
    private static let maxConcurrentPrefetches = 2

    private final class PrefetchDelegate: NSObject, WKNavigationDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { done() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) { done() }
    }

    func prefetch(url: URL) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.prefetch(url: url) }
            return
        }
        let k = key(url)
        guard !LinkSafety.mustNotAutoOpen(url),
              snapshot(for: url) == nil, prefetching[k] == nil,
              prefetching.count < Self.maxConcurrentPrefetches else { return }
        let view = makeWebView()
        let delegate = PrefetchDelegate { [weak self] in self?.endPrefetch(k) }
        view.navigationDelegate = delegate
        prefetching[k] = (view, delegate)
        view.load(URLRequest(url: url, timeoutInterval: 10))
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.endPrefetch(k) }
    }

    private func endPrefetch(_ k: String) {
        guard let entry = prefetching.removeValue(forKey: k) else { return }
        entry.view.stopLoading()
        entry.view.navigationDelegate = nil
    }
}

struct WebsitePreview: NSViewRepresentable {
    let url: URL

    var reloadToken: Int = 0

    func makeNSView(context: Context) -> WebsitePreviewContainer {
        WebsitePreviewContainer(url: url, reloadToken: reloadToken)
    }

    func updateNSView(_ container: WebsitePreviewContainer, context: Context) {
        container.update(url: url, reloadToken: reloadToken)
    }

    static func dismantleNSView(_ container: WebsitePreviewContainer, coordinator: ()) {
        container.tearDown()
    }
}

/// Shows a link's stored snapshot when there is one, the live page when
/// there isn't (or when the user reaches for it), and never leaves a live
/// page running once it's gone from the screen.
final class WebsitePreviewContainer: NSView, WKNavigationDelegate {
    private var url: URL
    private var reloadToken: Int
    private var webView: WKWebView?
    private var snapshotView: SnapshotView?
    private let progress = NSProgressIndicator()

    init(url: URL, reloadToken: Int) {
        self.url = url
        self.reloadToken = reloadToken
        super.init(frame: .zero)
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.isHidden = true
        addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        show(forceLive: reloadToken > 0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(url newURL: URL, reloadToken newToken: Int) {
        if newURL != url {
            url = newURL
            reloadToken = newToken
            show(forceLive: false)
        } else if newToken != reloadToken {
            reloadToken = newToken
            goLive()
        }
    }

    private func show(forceLive: Bool) {
        if !forceLive, let image = WebsitePreviewPool.shared.snapshot(for: url) {
            showSnapshot(image)
        } else if !forceLive, LinkSafety.mustNotAutoOpen(url) {
            showHeldBack()
        } else {
            goLive()
        }
    }

    /// A sign-in, reset or other one-time link: opening it here would spend
    /// it, so the page loads only when the user clicks.
    private var heldBackLabel: NSTextField?

    private func showHeldBack() {
        removeWebView()
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        progress.stopAnimation(nil)
        progress.isHidden = true
        guard heldBackLabel == nil else { return }
        let label = NSTextField(wrappingLabelWithString: String(localized:
            "This looks like a sign-in or one-time link, so it isn't opened automatically — opening it can use it up.\nClick to load the page."))
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        heldBackLabel = label
    }

    private func showSnapshot(_ image: NSImage) {
        removeWebView()
        let view = snapshotView ?? {
            let v = SnapshotView()
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v, positioned: .below, relativeTo: progress)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: topAnchor),
                v.leadingAnchor.constraint(equalTo: leadingAnchor),
                v.trailingAnchor.constraint(equalTo: trailingAnchor),
                v.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            snapshotView = v
            return v
        }()
        view.image = image
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    private func goLive() {
        heldBackLabel?.removeFromSuperview()
        heldBackLabel = nil
        snapshotView?.removeFromSuperview()
        snapshotView = nil
        removeWebView()
        let view = WebsitePreviewPool.shared.makeWebView()
        view.navigationDelegate = self
        addSubview(view, positioned: .below, relativeTo: progress)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor),
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        webView = view
        progress.isHidden = false
        progress.startAnimation(nil)
        view.load(URLRequest(url: url, timeoutInterval: 10))
    }

    private func removeWebView() {
        guard let view = webView else { return }
        view.stopLoading()
        view.pauseAllMediaPlayback(completionHandler: nil)
        view.navigationDelegate = nil
        view.removeFromSuperview()
        webView = nil
    }

    func tearDown() {
        removeWebView()
    }

    // The stored picture is a stand-in; reaching for it — scrolling or
    // clicking — means the user wants the real page.
    override func scrollWheel(with event: NSEvent) {
        if snapshotView != nil { goLive() } else { super.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        if snapshotView != nil || heldBackLabel != nil { goLive() } else { super.mouseDown(with: event) }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.stopAnimation(nil)
        progress.isHidden = true
        // Pages keep laying out for a moment after "finished"; give them that
        // moment before taking the one picture that will stand in for them.
        let pageURL = url
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak webView] in
            guard let self, let webView, webView === self.webView, webView.window != nil,
                  webView.bounds.width > 40, webView.bounds.height > 40 else { return }
            webView.takeSnapshot(with: nil) { image, _ in
                guard let image else { return }
                WebsitePreviewPool.shared.storeSnapshot(image, for: pageURL)
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        progress.stopAnimation(nil)
        progress.isHidden = true
    }

    /// Draws the snapshot filling the width, pinned to the top — how the page
    /// itself sits. Passes every event through to the container.
    private final class SnapshotView: NSView {
        var image: NSImage? { didSet { needsDisplay = true } }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard let image, image.size.width > 0 else { return }
            let scale = bounds.width / image.size.width
            let height = image.size.height * scale
            image.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: height),
                       from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
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
    /// Makes rich text readable on the panel's own background.
    ///
    /// Three cases, of which the original handled only the first:
    ///  - near-black text in Dark Mode / near-white text in Light Mode;
    ///  - text with NO colour at all — plain RTF (TextEdit, many exports)
    ///    leaves it unset, and unset draws black, so in Dark Mode it was
    ///    black on dark;
    ///  - a near-white highlight in Dark Mode (or near-black in Light) behind
    ///    text that the first rule had just recoloured to match it, leaving
    ///    white-on-white. Those page-colour backgrounds are dropped.
    func adjustingColorsForCurrentAppearance() -> NSAttributedString {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return AdjustedAttrCache.shared.adjusted(for: self, isDark: isDarkMode) {
            let full = NSRange(location: 0, length: self.length)
            func luminance(_ value: Any?) -> CGFloat? {
                guard let color = value as? NSColor, let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
                return 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            }
            func clashingText(_ value: Any?) -> Bool {
                if value == nil { return isDarkMode }
                guard let lum = luminance(value) else { return false }
                return isDarkMode ? lum < 0.25 : lum > 0.85
            }
            func pageBackground(_ value: Any?) -> Bool {
                guard let lum = luminance(value) else { return false }
                return isDarkMode ? lum > 0.85 : lum < 0.15
            }

            var needsWork = false
            self.enumerateAttributes(in: full, options: []) { attrs, _, stop in
                if clashingText(attrs[.foregroundColor]) || pageBackground(attrs[.backgroundColor]) {
                    needsWork = true
                    stop.pointee = true
                }
            }
            guard needsWork else { return self }

            let mutable = NSMutableAttributedString(attributedString: self)
            mutable.enumerateAttributes(in: full, options: []) { attrs, range, _ in
                if pageBackground(attrs[.backgroundColor]) {
                    mutable.removeAttribute(.backgroundColor, range: range)
                }
                if clashingText(attrs[.foregroundColor]) {
                    mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                }
            }
            return mutable
        }
    }
}

/// One image in the stacked multi-file preview. Deliberately non-interactive
/// and downsampled: it reuses the very same URL-keyed thumbnail the list row
/// already decoded (`ItemThumbnailCache`), so landing on a multi-file row
/// usually costs no decode at all, instead of spinning up a magnifiable
/// scroll view per image around a full-resolution bitmap.
private struct StackedImagePreviewCell: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.06))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            if let hit = ItemThumbnailCache.shared.cachedFileThumbnail(for: url) {
                image = hit
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                ItemThumbnailCache.decodeFileThumbnail(url: url)
            }.value
            guard !Task.isCancelled, let decoded else { return }
            ItemThumbnailCache.shared.storeFileThumbnail(decoded, for: url)
            image = decoded
        }
    }
}

/// An SVG clip, drawn — it used to be shown only as its XML source. The
/// graphic takes the space; the source stays underneath for reference.
/// Decoded off the main thread once per source; falls back to the source
/// alone if AppKit can't draw it.
private struct SVGPreview: View {
    let source: String
    let fontSize: CGFloat

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // A light card in both appearances: most SVGs are drawn
                    // in dark ink for a light page and vanish on Dark Mode's
                    // background otherwise.
                    .background(Color(white: 0.95), in: RoundedRectangle(cornerRadius: 8))
                Divider().padding(.vertical, 6)
            }
            if image != nil || failed {
                ScrollView {
                    Text(source.displayTrimmedLeading)
                        .font(.system(size: fontSize - 1, design: .monospaced))
                        .foregroundColor(image == nil ? .primary : .secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: image == nil ? .infinity : 110)
            }
        }
        .task(id: source) {
            image = nil
            failed = false
            let data = Data(source.utf8)
            let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                guard let img = NSImage(data: data), img.isValid,
                      img.size.width > 0, img.size.height > 0 else { return nil }
                return img
            }.value
            guard !Task.isCancelled else { return }
            image = decoded
            failed = decoded == nil
        }
    }
}
