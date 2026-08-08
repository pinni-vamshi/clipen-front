import AppKit
import AVKit
import Highlightr
import LaTeXSwiftUI
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit


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
                    LaTeXRenderedPreview(text: text)
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
    // Pure string parsing, no shared state — safe to call from any
    // isolation context, including the background prefetch path in
    // PreviewPrefetch.swift.
    nonisolated static func detectDelimiter(_ text: String) -> Character {
        let firstLine = text.prefix(while: { $0 != "\n" && $0 != "\r" })
        return firstLine.contains("\t") ? "\t" : ","
    }

    nonisolated static func parse(_ text: String, delimiter: Character) -> [[String]] {
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

/// Renders `.latex`-tagged captures as actual typeset math (via
/// LaTeXSwiftUI/MathJax) instead of the syntax-highlighted-source treatment
/// every other code-like type gets. The detector that assigns `.latex`
/// (`isLatex` in TextTraditionalDetectors.swift) explicitly excludes
/// anything with its own `\documentclass`/`\begin{document}` — so this is
/// always a math expression, never a whole document, which is exactly what
/// this package renders (it doesn't compile full LaTeX documents).
struct LaTeXRenderedPreview: View {
    let text: String

    /// Bare math source (e.g. copied `\frac{a}{b}` with no `$`/`\[` wrapper)
    /// needs to be wrapped for the renderer to treat it as an equation
    /// instead of literal prose — only wrap if it isn't already delimited.
    private var normalizedSource: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyDelimited = t.hasPrefix("$") || t.hasPrefix("\\[") || t.hasPrefix("\\(")
        return alreadyDelimited ? t : "\\[\n\(t)\n\\]"
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            // `.font(NSFont)` is only defined as an extension on the
            // concrete `LaTeX` type, not `View` — it must be the first
            // modifier applied, before anything else erases the type to
            // `some View`, or overload resolution silently falls back to
            // SwiftUI's own `.font(Font?)` and fails to compile against NSFont.
            LaTeX(normalizedSource)
                .font(NSFont.systemFont(ofSize: 15))
                .parsingMode(.onlyEquations)
                .blockMode(.blockViews)
                // Malformed/partial LaTeX (a copy cut off mid-expression)
                // falls back to the original source instead of an error
                // glyph, so a bad parse never looks like a broken preview.
                .errorMode(.original)
                .foregroundColor(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
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
