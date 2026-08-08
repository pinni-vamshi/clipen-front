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
                case .code(let language) where language == "LaTeX":
                    // A whole .tex file — CodeLanguageDetector tags these
                    // "LaTeX" the same as it would any other source file,
                    // but raw syntax-highlighted source isn't a useful
                    // preview for a document meant to be read. Render it as
                    // formatted text instead (see LaTeXDocumentPreview).
                    LaTeXDocumentPreview(text: text)
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

/// Renders a whole `.tex` file (a real document — `\documentclass`,
/// `\usepackage`, etc. — see `LaTeXRenderedPreview`'s doc comment for why
/// that's routed here instead) as readable formatted text, the same idea as
/// `MarkdownTextPreview` but for a first pass of the most common LaTeX
/// constructs rather than the full language: sections, bold/italic, simple
/// itemize/enumerate lists, and inline/display math. Preamble and layout
/// commands (`\documentclass`, `\usepackage`, `\newcommand`, `\vspace`, …)
/// carry no readable content, so they're dropped rather than shown as raw
/// backslash-noise. Custom macros this doesn't specifically recognize (e.g.
/// a resume template's own `\resumeItem{...}`) fall back to showing
/// whatever text sits in the LAST brace group — not a real macro expansion,
/// just a heuristic that happens to work for the common single-purpose-
/// wrapper shape those tend to have.
struct LaTeXDocumentPreview: View {
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

    /// The readable content lives between `\begin{document}` and
    /// `\end{document}` — everything before that is preamble. Falls back to
    /// the whole text for a bare fragment with no preamble/document wrapper.
    private var documentBody: String {
        guard let start = text.range(of: "\\begin{document}") else { return text }
        let afterStart = String(text[start.upperBound...])
        guard let end = afterStart.range(of: "\\end{document}") else { return afterStart }
        return String(afterStart[..<end.lowerBound])
    }

    /// Multi-line display-math openers this preview specifically buffers
    /// across lines (see `parsedBlocks`). `\[` and `\begin{equation}`/
    /// `equation*` are recognized natively by LaTeXSwiftUI's own equation
    /// scanner, so their content is passed through as-is. The amsmath
    /// environments (`align`, `gather`, `eqnarray`, `multline`, `alignat`)
    /// are NOT recognized as math on their own by that scanner — it only
    /// looks for `$…$`, `\(…\)`, `\[…\]`, and `equation`/`equation*` — so
    /// those need `needsDisplayWrap` to get wrapped in `\[ \]` before being
    /// handed off; MathJax itself understands `align` etc. just fine once
    /// it's inside a math region the scanner actually finds.
    private static let mathOpeners: [(open: String, close: String, needsDisplayWrap: Bool)] = [
        ("\\[", "\\]", false),
        ("\\begin{equation*}", "\\end{equation*}", false),
        ("\\begin{equation}",  "\\end{equation}",  false),
        ("\\begin{align*}",    "\\end{align*}",    true),
        ("\\begin{align}",     "\\end{align}",     true),
        ("\\begin{gather*}",   "\\end{gather*}",   true),
        ("\\begin{gather}",    "\\end{gather}",    true),
        ("\\begin{eqnarray*}", "\\end{eqnarray*}", true),
        ("\\begin{eqnarray}",  "\\end{eqnarray}",  true),
        ("\\begin{multline*}", "\\end{multline*}", true),
        ("\\begin{multline}",  "\\end{multline}",  true),
        ("\\begin{alignat*}",  "\\end{alignat*}",  true),
        ("\\begin{alignat}",   "\\end{alignat}",   true),
        ("\\begin{flalign*}",  "\\end{flalign*}",  true),
        ("\\begin{flalign}",   "\\end{flalign}",   true),
        ("\\begin{subequations}", "\\end{subequations}", true),
        // Matrix/case environments are normally nested inside one of the
        // delimiters above (`$\begin{pmatrix}...\end{pmatrix}$`), which
        // already works without any of these entries. These specifically
        // cover the same environments pasted BARE at the top level, with no
        // outer math delimiter of their own.
        ("\\begin{pmatrix}",   "\\end{pmatrix}",   true),
        ("\\begin{bmatrix}",   "\\end{bmatrix}",   true),
        ("\\begin{vmatrix}",   "\\end{vmatrix}",   true),
        ("\\begin{Vmatrix}",   "\\end{Vmatrix}",   true),
        ("\\begin{smallmatrix}", "\\end{smallmatrix}", true),
        ("\\begin{matrix}",    "\\end{matrix}",    true),
        ("\\begin{cases}",     "\\end{cases}",     true),
        ("\\begin{array}",     "\\end{array}",     true),
        ("$$", "$$", true),
    ]

    /// A standalone display-math block, rendered on its own (as opposed to
    /// `inlineContent`'s per-line mixed prose+math handling) — `.blockViews`
    /// gives it the same centered block treatment `LaTeXRenderedPreview`
    /// uses for a bare equation, appropriate here since the whole block IS
    /// the equation, not prose with math embedded in it.
    private func mathBlock(_ source: String) -> some View {
        LaTeX(source)
            .font(NSFont.systemFont(ofSize: 13))
            .parsingMode(.onlyEquations)
            .blockMode(.blockViews)
            .errorMode(.original)
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let noiseCommands: Set<String> = [
        "documentclass", "usepackage", "newcommand", "renewcommand", "providecommand",
        "newenvironment", "renewenvironment", "def", "let", "RequirePackage",
        "pagestyle", "thispagestyle", "fancyhf", "headrulewidth", "footrulewidth",
        "addtolength", "setlength", "tabcolsep", "setcounter",
        "urlstyle", "raggedbottom", "raggedright", "raggedleft",
        "hypersetup", "DeclareMathOperator", "definecolor", "geometry",
        "allsectionsfont", "selectfont", "fontsize", "familydefault", "sfdefault",
        "vspace", "hspace", "newline", "noindent", "indent",
        "clearpage", "newpage", "vfill", "hfill", "medskip", "smallskip", "bigskip",
        "label", "maketitle",
    ]

    private var parsedBlocks: [Block] {
        var blocks: [Block] = []
        let lines = documentBody.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1

            if trimmed.isEmpty {
                blocks.append(Block(view: AnyView(Spacer().frame(height: 4))))
                continue
            }
            if trimmed.hasPrefix("%") { continue }

            if let (level, title) = sectionHeader(trimmed) {
                blocks.append(Block(view: AnyView(
                    inlineContent(title)
                        .font(.system(size: level == 1 ? 17 : 15, weight: .bold))
                )))
                continue
            }

            // A display-math block often spans several lines — `\[ ... \]`,
            // `$$ ... $$`, or an amsmath environment like `align`/`gather`.
            // The per-line handling below (`inlineContent`) only sees ONE
            // line at a time, so a block whose closing delimiter is several
            // lines down would never get past its opening line unrendered.
            // Buffer every line from the opener through its matching closer
            // and hand the whole thing to the renderer as one block.
            if let opener = Self.mathOpeners.first(where: { trimmed.hasPrefix($0.open) }) {
                var blockLines = [lines[i - 1]]
                var closed = trimmed.dropFirst(opener.open.count).contains(opener.close)
                while !closed, i < lines.count {
                    blockLines.append(lines[i])
                    closed = lines[i].contains(opener.close)
                    i += 1
                }
                let raw = blockLines.joined(separator: "\n")
                let source = opener.needsDisplayWrap ? "\\[\n\(raw)\n\\]" : raw
                blocks.append(Block(view: AnyView(mathBlock(source))))
                continue
            }

            if trimmed.hasPrefix("\\begin{itemize}") || trimmed.hasPrefix("\\begin{enumerate}") {
                let numbered = trimmed.hasPrefix("\\begin{enumerate}")
                var n = 1
                while i < lines.count {
                    let itemLine = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if itemLine.hasPrefix("\\end{itemize}") || itemLine.hasPrefix("\\end{enumerate}") { break }
                    guard itemLine.hasPrefix("\\item") else { continue }
                    let content = String(itemLine.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    guard !content.isEmpty else { continue }
                    let marker = numbered ? "\(n)." : "\u{2022}"
                    n += 1
                    blocks.append(Block(view: AnyView(
                        HStack(alignment: .top, spacing: 6) {
                            Text(marker).font(.system(size: 13)).frame(minWidth: 14, alignment: .leading)
                            inlineContent(content)
                        }
                        .padding(.leading, 8)
                    )))
                }
                continue
            }

            if isNoiseLine(trimmed) { continue }

            // A bare `\begin{X}`/`\end{X}` for anything else (center,
            // tabular*, document's own leftover markers, …) has no content
            // of its own — drop just the marker and keep processing what's
            // inside as ordinary lines.
            if trimmed.hasPrefix("\\begin{") || trimmed.hasPrefix("\\end{") { continue }

            blocks.append(Block(view: AnyView(inlineContent(trimmed))))
        }
        return blocks
    }

    private func sectionHeader(_ line: String) -> (level: Int, title: String)? {
        for (level, tag) in [(1, "section"), (2, "subsection"), (3, "subsubsection")] {
            for form in ["\\\(tag)*{", "\\\(tag){"] {
                guard line.hasPrefix(form), let close = matchingBrace(in: line, openAt: form.count - 1) else { continue }
                return (level, String(line[line.index(line.startIndex, offsetBy: form.count)..<close]))
            }
        }
        return nil
    }

    /// `openAt` is the index of the `{` itself; returns the index of its
    /// matching `}`, accounting for nested braces (e.g. a `\textbf{}` inside
    /// a section title).
    ///
    /// Generic over `StringProtocol` so it can run directly on a `Substring`
    /// (as `formattedText` needs to, below) without first copying it into a
    /// `String` — a `String.Index` is only valid against the exact string
    /// value it was produced from, so returning an index computed against a
    /// COPY and then using it to subscript the original `Substring` is
    /// undefined behavior. That mismatch is exactly what crashed here: the
    /// copy and the original happen to share enough representation to often
    /// work, until they don't.
    private func matchingBrace<S: StringProtocol>(in s: S, openAt: Int) -> S.Index? {
        var depth = 0
        var idx = s.index(s.startIndex, offsetBy: openAt)
        while idx < s.endIndex {
            if s[idx] == "{" { depth += 1 }
            else if s[idx] == "}" {
                depth -= 1
                if depth == 0 { return idx }
            }
            idx = s.index(after: idx)
        }
        return nil
    }

    private func isNoiseLine(_ line: String) -> Bool {
        guard line.hasPrefix("\\") else { return false }
        let name = line.dropFirst().prefix(while: { $0.isLetter })
        return Self.noiseCommands.contains(String(name))
    }

    /// A line containing real math delimiters is handed to the LaTeX
    /// renderer whole — MathJax renders the surrounding plain text as-is
    /// and only typesets the delimited math, which is exactly the mixed
    /// prose+equation rendering a resume/paper line actually needs. A line
    /// with no math gets `\textbf`/`\textit`/`\emph` turned into real
    /// bold/italic instead, since MathJax has no reason to understand those
    /// outside of math mode.
    @ViewBuilder
    private func inlineContent(_ line: String) -> some View {
        if line.contains("$") || line.contains("\\[") || line.contains("\\(") {
            LaTeX(line)
                .font(NSFont.systemFont(ofSize: 13))
                .parsingMode(.onlyEquations)
                .blockMode(.blockText)
                .errorMode(.original)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(formattedText(line))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Zero-argument commands (no `{...}` to expand) that stand in for a
    /// single typeset character/symbol.
    private static let zeroArgSubstitutions: [String: String] = [
        "ldots": "\u{2026}", "dots": "\u{2026}", "cdots": "\u{2026}",
    ]

    /// `~`/`--`/`---` aren't backslash commands, so they're substituted in
    /// plain text segments directly rather than in the backslash-scanning
    /// loop below: `~` is LaTeX's non-breaking space, and `--`/`---` are its
    /// en-/em-dash ligatures — all three otherwise show as their literal
    /// source characters instead of what LaTeX actually typesets. Order
    /// matters: replacing `---` first means a real `---` can't be seen as
    /// `--` plus a leftover `-` by the second replacement.
    private func substituteTypography(_ s: some StringProtocol) -> String {
        String(s)
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "---", with: "\u{2014}")
            .replacingOccurrences(of: "--", with: "\u{2013}")
    }

    /// Citations/cross-references (`\cite`, `\ref`, `\pageref`, …) can't be
    /// resolved here — that needs an actual bibliography/label pass this
    /// preview doesn't have — so their raw internal key (meaningless to a
    /// reader, e.g. `smith2020` or `fig:diagram1`) is replaced with a
    /// neutral placeholder instead of being shown as if it were content.
    private static let citationCommands: Set<String> = ["cite", "citep", "citet", "citeauthor", "citeyear", "nocite"]
    private static let referenceCommands: Set<String> = ["ref", "eqref", "pageref", "autoref"]

    /// `\textbf{}`/`\textit{}`/`\emph{}`/`\texttt{}`/`\underline{}`/`\sout{}`
    /// become real bold/italic/monospace/underline/strikethrough runs;
    /// `\href{url}{label}`/`\url{...}` become real tappable links; `\\`
    /// becomes an actual line break; `\cite{}`/`\ref{}` and friends become a
    /// neutral `[cite]`/`[ref]` placeholder (see above); an unrecognized
    /// `\command{...}{...}…` with several brace groups (a custom macro like
    /// a resume template's `\resumeSubheading{a}{b}{c}{d}`) shows all of its
    /// groups joined, not just the first; common escaped characters are
    /// unescaped so `\%`/`\&`/`\_` read naturally.
    private func formattedText(_ line: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(line)

        while let backslash = rest.firstIndex(of: "\\") {
            // `{\declword ...}` — an old-style TeX font-switching group
            // (e.g. `{\bfseries Name}`), where the command takes NO brace
            // argument of its own and instead just changes state for the
            // rest of its enclosing group. Distinct from `\textbf{...}`
            // (name immediately followed by `{`) and handled before the
            // backslash is treated normally, so this group's own `{` never
            // gets appended as a stray literal character the way it used to.
            if backslash > rest.startIndex, rest[rest.index(before: backslash)] == "{" {
                let braceOpen = rest.index(before: backslash)
                let afterSlash = rest[rest.index(after: backslash)...]
                let declName = String(afterSlash.prefix(while: { $0.isLetter }))
                let afterDecl = afterSlash.dropFirst(declName.count)
                if !declName.isEmpty, afterDecl.first != "{",
                   let braceEnd = matchingBrace(in: rest, openAt: rest.distance(from: rest.startIndex, to: braceOpen)) {
                    result += AttributedString(substituteTypography(rest[rest.startIndex..<braceOpen]))
                    let groupInner = String(afterDecl[afterDecl.startIndex..<braceEnd])
                    var run = formattedText(groupInner)
                    switch declName {
                    case "bf", "bfseries": run.inlinePresentationIntent = .stronglyEmphasized
                    case "it", "itshape", "sl", "slshape", "em": run.inlinePresentationIntent = .emphasized
                    case "tt", "ttfamily": run.font = .system(size: 13, design: .monospaced)
                    default: break
                    }
                    result += run
                    rest = rest[rest.index(after: braceEnd)...]
                    continue
                }
            }

            result += AttributedString(substituteTypography(rest[rest.startIndex..<backslash]))
            let afterSlash = rest[rest.index(after: backslash)...]

            if afterSlash.hasPrefix("\\") {
                result += AttributedString("\n")
                rest = afterSlash.dropFirst()
                continue
            }

            if let escaped = afterSlash.first, "%&_#{}$".contains(escaped) {
                result += AttributedString(String(escaped))
                rest = afterSlash.dropFirst()
                continue
            }

            let name = String(afterSlash.prefix(while: { $0.isLetter }))
            let afterName = afterSlash.dropFirst(name.count)

            if let substitution = Self.zeroArgSubstitutions[name] {
                result += AttributedString(substitution)
                rest = afterName
                continue
            }

            guard !name.isEmpty, afterName.first == "{",
                  let braceEnd = matchingBrace(in: afterName, openAt: 0) else {
                // Not a recognized `\name{...}` shape — drop just the
                // backslash so the rest of the token still reads naturally
                // instead of showing a stray `\`.
                rest = afterSlash
                continue
            }
            let innerRange = afterName.index(after: afterName.startIndex)..<braceEnd
            let inner = String(afterName[innerRange])
            let consumed = afterName.distance(from: afterName.startIndex, to: braceEnd) + 1
            rest = afterName.dropFirst(consumed)

            if name == "href" {
                if rest.first == "{", let labelEnd = matchingBrace(in: rest, openAt: 0) {
                    let label = String(rest[rest.index(after: rest.startIndex)..<labelEnd])
                    rest = rest[rest.index(after: labelEnd)...]
                    var linkRun = formattedText(label)
                    linkRun.link = URL(string: inner)
                    linkRun.foregroundColor = .accentColor
                    result += linkRun
                } else {
                    // Malformed `\href` (no label group) — show the URL
                    // itself as the link text rather than dropping it.
                    var linkRun = AttributedString(inner)
                    linkRun.link = URL(string: inner)
                    linkRun.foregroundColor = .accentColor
                    result += linkRun
                }
                continue
            }
            if name == "url" {
                var linkRun = AttributedString(inner)
                linkRun.link = URL(string: inner)
                linkRun.foregroundColor = .accentColor
                result += linkRun
                continue
            }
            if Self.citationCommands.contains(name) {
                var marker = AttributedString("[cite]")
                marker.foregroundColor = .secondary
                result += marker
                continue
            }
            if Self.referenceCommands.contains(name) {
                var marker = AttributedString("[ref]")
                marker.foregroundColor = .secondary
                result += marker
                continue
            }

            var run = formattedText(inner)
            switch name {
            case "textbf": run.inlinePresentationIntent = .stronglyEmphasized
            case "textit", "emph": run.inlinePresentationIntent = .emphasized
            case "texttt": run.font = .system(size: 13, design: .monospaced)
            case "underline": run.underlineStyle = .single
            case "sout", "strikethrough": run.strikethroughStyle = .single
            default:
                // Unrecognized macro — if more brace groups immediately
                // follow, this is likely a multi-argument macro (e.g. a
                // resume template's own `\resumeSubheading{a}{b}{c}{d}`);
                // fold them all into one readable run instead of leaving
                // the later groups as literal `{b}{c}{d}`. Capped so
                // malformed/unbalanced input can't loop indefinitely.
                var extraGroups = 0
                while extraGroups < 5, rest.first == "{",
                      let nextEnd = matchingBrace(in: rest, openAt: 0) {
                    let nextInner = String(rest[rest.index(after: rest.startIndex)..<nextEnd])
                    run += AttributedString("  ")
                    run += formattedText(nextInner)
                    rest = rest[rest.index(after: nextEnd)...]
                    extraGroups += 1
                }
            }
            result += run
        }
        result += AttributedString(substituteTypography(rest))
        return result
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
