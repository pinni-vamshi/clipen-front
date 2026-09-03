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

    @State private var blocks: [Block] = []

    var body: some View {
        ScrollView {

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { $0.view }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: text) {
            blocks = parsedBlocks
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

enum DelimitedTableParser {

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

        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}

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

struct LaTeXRenderedPreview: View {
    let text: String

    private var normalizedSource: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyDelimited = t.hasPrefix("$") || t.hasPrefix("\\[") || t.hasPrefix("\\(")
        return alreadyDelimited ? t : "\\[\n\(t)\n\\]"
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {

            LaTeX(normalizedSource)
                .font(NSFont.systemFont(ofSize: 15))
                .parsingMode(.onlyEquations)
                .blockMode(.blockViews)

                .errorMode(.original)
                .foregroundColor(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

actor MathRenderGate {
    static let shared = MathRenderGate()
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct GatedMath<Content: View>: View {
    let source: String
    @ViewBuilder let content: () -> Content
    @State private var isMyTurn = false

    var body: some View {
        Group {
            if isMyTurn {
                content()
            } else {
                Text(source)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: source) {
            await MathRenderGate.shared.acquire()
            isMyTurn = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            await MathRenderGate.shared.release()
        }
    }
}

struct LaTeXDocumentPreview: View {
    let text: String

    @State private var blocks: [Block] = []

    var body: some View {
        ScrollView {

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(blocks) { $0.view }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .task(id: text) {
            blocks = parsedBlocks
        }
    }

    private struct Block: Identifiable {
        let id = UUID()
        let view: AnyView
    }

    private var documentBody: String {
        guard let start = text.range(of: "\\begin{document}") else { return text }
        let afterStart = String(text[start.upperBound...])
        guard let end = afterStart.range(of: "\\end{document}") else { return afterStart }
        return String(afterStart[..<end.lowerBound])
    }

    private var preambleText: String {
        guard let start = text.range(of: "\\begin{document}") else { return "" }
        return String(text[text.startIndex..<start.lowerBound])
    }

    private func extractPreambleField(_ command: String) -> String? {
        let preamble = preambleText
        let marker = "\\\(command){"
        guard let markerRange = preamble.range(of: marker) else { return nil }
        let braceIndex = preamble.index(before: markerRange.upperBound)
        guard let closeIndex = matchingBrace(
            in: preamble, openAt: preamble.distance(from: preamble.startIndex, to: braceIndex)
        ) else { return nil }
        return String(preamble[preamble.index(after: braceIndex)..<closeIndex])
    }

    private static let verbatimEnvironments: [(open: String, close: String)] = [
        ("\\begin{verbatim}", "\\end{verbatim}"),
        ("\\begin{lstlisting", "\\end{lstlisting}"),
        ("\\begin{minted}", "\\end{minted}"),
    ]

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

    private func mathBlock(_ source: String) -> some View {
        GatedMath(source: source) {
            LaTeX(source)
                .font(NSFont.systemFont(ofSize: 13))
                .parsingMode(.onlyEquations)
                .blockMode(.blockViews)
                .errorMode(.original)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let theoremEnvironments: [String: String] = [
        "theorem": "Theorem", "lemma": "Lemma", "proposition": "Proposition",
        "corollary": "Corollary", "definition": "Definition", "remark": "Remark",
        "example": "Example", "proof": "Proof", "claim": "Claim",
        "conjecture": "Conjecture", "notation": "Notation", "observation": "Observation",
    ]

    private static let noiseCommands: Set<String> = [
        "documentclass", "usepackage", "newcommand", "renewcommand", "providecommand",
        "newenvironment", "renewenvironment", "def", "let", "RequirePackage",
        "pagestyle", "thispagestyle", "fancyhf", "headrulewidth", "footrulewidth",
        "addtolength", "setlength", "tabcolsep", "setcounter",
        "urlstyle", "raggedbottom", "raggedright", "raggedleft", "centering",
        "hypersetup", "DeclareMathOperator", "definecolor", "geometry",
        "allsectionsfont", "selectfont", "fontsize", "familydefault", "sfdefault",
        "vspace", "hspace", "newline", "noindent", "indent",
        "clearpage", "newpage", "vfill", "hfill", "medskip", "smallskip", "bigskip",
        "label", "maketitle",
    ]

    private static func isTableRuleLine(_ line: String) -> Bool {
        line == "\\toprule" || line == "\\midrule" || line == "\\bottomrule" ||
        line == "\\hline" || line.hasPrefix("\\cline{")
    }

    private static func splitTableRow(_ raw: String) -> [String] {
        var cells: [String] = []
        var current = ""
        let chars = Array(raw)
        var idx = 0
        while idx < chars.count {
            if chars[idx] == "\\", idx + 1 < chars.count, chars[idx + 1] == "&" {
                current.append("\\&")
                idx += 2
                continue
            }
            if chars[idx] == "&" {
                cells.append(current)
                current = ""
                idx += 1
                continue
            }
            current.append(chars[idx])
            idx += 1
        }
        cells.append(current)
        return cells
    }

    private static func parseTabularRows(_ lines: [String]) -> [[String]] {
        var rows: [[String]] = []
        var buffer = ""
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || isTableRuleLine(t) { continue }
            buffer += (buffer.isEmpty ? "" : " ") + t

            while let range = buffer.range(of: "\\\\") {
                let rowSource = String(buffer[buffer.startIndex..<range.lowerBound])
                let cells = splitTableRow(rowSource).map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.contains(where: { !$0.isEmpty }) { rows.append(cells) }
                var remainder = buffer[range.upperBound...]
                if remainder.first == "[", let close = remainder.firstIndex(of: "]") {
                    remainder = remainder[remainder.index(after: close)...]
                }
                buffer = String(remainder).trimmingCharacters(in: .whitespaces)
            }
        }

        let cells = splitTableRow(buffer).map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.contains(where: { !$0.isEmpty }) { rows.append(cells) }
        return rows
    }

    private func tabularGrid(_ rows: [[String]]) -> some View {
        let colCount = rows.map(\.count).max() ?? 1
        return VStack(spacing: 1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                HStack(spacing: 1) {
                    ForEach(0..<colCount, id: \.self) { c in
                        (c < row.count ? inlineContent(row[c]) : inlineContent(""))
                            .font(.system(size: 13, weight: r == 0 ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .frame(minWidth: 60, alignment: .leading)
                            .background(Color.primary.opacity(r == 0 ? 0.06 : 0.02))
                            .overlay(Rectangle().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(4)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.15), lineWidth: 1))
    }

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
                        .font(.system(size: Self.headerFontSize(for: level), weight: .bold))
                )))
                continue
            }

            if trimmed == "\\maketitle" {
                let title  = extractPreambleField("title")
                let author = extractPreambleField("author")

                let date = extractPreambleField("date").flatMap { $0 == "\\today" ? nil : $0 }
                if title != nil || author != nil || date != nil {
                    blocks.append(Block(view: AnyView(
                        VStack(alignment: .leading, spacing: 4) {
                            if let title { inlineContent(title).font(.system(size: 19, weight: .bold)) }
                            if let author { inlineContent(author).font(.system(size: 14)) }
                            if let date {
                                inlineContent(date).font(.system(size: 12)).foregroundColor(.secondary)
                            }
                        }
                    )))
                }
                continue
            }

            if let vb = Self.verbatimEnvironments.first(where: { trimmed.hasPrefix($0.open) }) {
                var codeLines: [String] = []
                while i < lines.count {
                    let raw = lines[i]
                    i += 1
                    if raw.trimmingCharacters(in: .whitespaces).hasPrefix(vb.close) { break }
                    codeLines.append(raw)
                }
                blocks.append(Block(view: AnyView(
                    CodeSyntaxPreview(text: codeLines.joined(separator: "\n"), language: nil)
                        .frame(minHeight: 20)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                )))
                continue
            }

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

            if trimmed.hasPrefix("\\begin{"),
               let nameEnd = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)...].firstIndex(of: "}"),
               let displayLabel = Self.theoremEnvironments[String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<nameEnd])] {
                let envName = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)..<nameEnd])
                let afterEnv = trimmed[trimmed.index(after: nameEnd)...]
                var label = displayLabel
                if afterEnv.first == "[", let closeBracket = afterEnv.firstIndex(of: "]") {
                    label += " (\(afterEnv[afterEnv.index(after: afterEnv.startIndex)..<closeBracket]))"
                }
                label += "."

                let endMarker = "\\end{\(envName)}"
                var bodyLines: [String] = []
                while i < lines.count {
                    let bodyLine = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if bodyLine.hasPrefix(endMarker) { break }
                    bodyLines.append(bodyLine)
                }
                blocks.append(Block(view: AnyView(
                    VStack(alignment: .leading, spacing: 4) {
                        inlineContent(label).font(.system(size: 13, weight: .bold))
                        ForEach(Array(bodyLines.enumerated()), id: \.offset) { _, bodyLine in
                            if !bodyLine.isEmpty { inlineContent(bodyLine) }
                        }
                    }
                    .padding(10)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                )))
                continue
            }

            if trimmed.hasPrefix("\\begin{itemize}") || trimmed.hasPrefix("\\begin{enumerate}")
                || trimmed.hasPrefix("\\begin{description}") {
                let numbered  = trimmed.hasPrefix("\\begin{enumerate}")
                let described = trimmed.hasPrefix("\\begin{description}")
                var n = 1
                while i < lines.count {
                    let itemLine = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if itemLine.hasPrefix("\\end{itemize}") || itemLine.hasPrefix("\\end{enumerate}")
                        || itemLine.hasPrefix("\\end{description}") { break }
                    guard itemLine.hasPrefix("\\item") else { continue }
                    var rest = itemLine.dropFirst(5)

                    var label: String? = nil
                    if described, rest.first == "[", let closeBracket = rest.firstIndex(of: "]") {
                        label = String(rest[rest.index(after: rest.startIndex)..<closeBracket])
                        rest = rest[rest.index(after: closeBracket)...]
                    }
                    let content = String(rest).trimmingCharacters(in: .whitespaces)
                    guard !content.isEmpty || label != nil else { continue }

                    if let label {
                        blocks.append(Block(view: AnyView(
                            HStack(alignment: .top, spacing: 6) {
                                inlineContent(label).font(.system(size: 13, weight: .semibold))
                                inlineContent(content)
                            }
                            .padding(.leading, 8)
                        )))
                    } else {
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
                }
                continue
            }

            if trimmed.hasPrefix("\\begin{tabular") {
                var rowLines: [String] = []
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    i += 1
                    if rowLine.hasPrefix("\\end{tabular") { break }
                    rowLines.append(rowLine)
                }
                let rows = Self.parseTabularRows(rowLines)
                if !rows.isEmpty {
                    blocks.append(Block(view: AnyView(tabularGrid(rows))))
                }
                continue
            }

            if isNoiseLine(trimmed) { continue }

            if trimmed.hasPrefix("\\begin{") || trimmed.hasPrefix("\\end{") { continue }

            blocks.append(Block(view: AnyView(inlineContent(trimmed))))
        }
        return blocks
    }

    private func sectionHeader(_ line: String) -> (level: Int, title: String)? {
        for (level, tag) in [
            (0, "part"), (0, "chapter"),
            (1, "section"), (2, "subsection"), (3, "subsubsection"),
            (4, "paragraph"), (4, "subparagraph"),
        ] {
            for form in ["\\\(tag)*{", "\\\(tag){"] {
                guard line.hasPrefix(form), let close = matchingBrace(in: line, openAt: form.count - 1) else { continue }
                return (level, String(line[line.index(line.startIndex, offsetBy: form.count)..<close]))
            }
        }
        return nil
    }

    private static func headerFontSize(for level: Int) -> CGFloat {
        switch level {
        case 0:  return 19
        case 1:  return 17
        case 2:  return 15
        case 3:  return 14
        default: return 13
        }
    }

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

    @ViewBuilder
    private func inlineContent(_ line: String) -> some View {
        if line.contains("$") || line.contains("\\[") || line.contains("\\(") {
            GatedMath(source: line) {
                LaTeX(line)
                    .font(NSFont.systemFont(ofSize: 13))
                    .parsingMode(.onlyEquations)
                    .blockMode(.blockText)
                    .errorMode(.original)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text(formattedText(line))
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let zeroArgSubstitutions: [String: String] = [
        "ldots": "\u{2026}", "dots": "\u{2026}", "cdots": "\u{2026}",
    ]

    private func substituteTypography(_ s: some StringProtocol) -> String {
        String(s)
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "---", with: "\u{2014}")
            .replacingOccurrences(of: "--", with: "\u{2013}")
    }

    private static let citationCommands: Set<String> = ["cite", "citep", "citet", "citeauthor", "citeyear", "nocite"]
    private static let referenceCommands: Set<String> = ["ref", "eqref", "pageref", "autoref"]

    private func formattedText(_ line: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(line)

        while let backslash = rest.firstIndex(of: "\\") {

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

    private let cache = NSCache<NSString, NSAttributedString>()

    private init() { cache.countLimit = 200 }

    private static func cacheKey(_ code: String, languageDisplayName: String?, dark: Bool) -> NSString {
        "\(code.count)|\(code.prefix(48))|\(code.suffix(48))|\(languageDisplayName ?? "-")|\(dark ? "d" : "l")" as NSString
    }

    func highlight(_ code: String, languageDisplayName: String?, dark: Bool) async -> NSAttributedString? {

        nonisolated(unsafe) let key = Self.cacheKey(code, languageDisplayName: languageDisplayName, dark: dark)

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

    static let maxHighlightLength = 100_000

    func highlightSync(_ code: String, languageDisplayName: String?, dark: Bool) -> NSAttributedString? {

        nonisolated(unsafe) let key = Self.cacheKey(code, languageDisplayName: languageDisplayName, dark: dark)
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

        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()
    }
}
