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

    static func dismantleNSView(_ container: NSView, coordinator: Coordinator) {
        guard let webView = container.subviews.first(where: { $0 is WKWebView }) as? WKWebView else { return }
        webView.pauseAllMediaPlayback(completionHandler: nil)
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
