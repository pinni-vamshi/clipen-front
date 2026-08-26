import AppKit
import Foundation

enum TextTools {
    static let all: [ClipboardTool] = [
        editTool,
        undoEditTool,
        pastePlainTool,
        pasteFormattedTool,
        make("text.title-case", icon: "textformat", label: "Title Case", group: "CASE") {
            guard isPlainText($0) else { return nil }
            return $0.titleCased
        },
        uppercaseTool,
        lowercaseTool,
        make("text.trim", icon: "scissors", label: "Trim whitespace", group: "EDIT") {
            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == $0 ? nil : trimmed
        },
        make("text.json-pretty", icon: "curlybraces", label: "JSON Pretty", group: "FORMAT") {
            jsonPretty($0)
        },
        make("text.json-minify", icon: "curlybraces.square", label: "JSON Minify", group: "FORMAT") {
            jsonMinify($0)
        },
        make("text.url-encode", icon: "link", label: "URL Encode", group: "ENCODE") {
            guard isURL($0) else { return nil }
            return encodeURLComponents($0)
        },
        make("text.url-decode", icon: "link.badge.plus", label: "URL Decode", group: "ENCODE") {
            guard $0.contains("%") else { return nil }
            let decoded = $0.removingPercentEncoding
            return decoded == $0 ? nil : decoded
        },
        make("text.base64-encode", icon: "doc.badge.ellipsis", label: "Base64 Encode", group: "ENCODE") {
            guard $0.count <= 1000, !$0.isEmpty else { return nil }
            return Data($0.utf8).base64EncodedString()
        },
        make("text.base64-decode", icon: "doc.badge.minus", label: "Base64 Decode", group: "ENCODE") {
            let s = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 4,
                  let data = Data(base64Encoded: s),
                  let result = String(data: data, encoding: .utf8),
                  !result.isEmpty else { return nil }
            return result
        },
        make("text.snake-case", icon: "square.2.layers.3d", label: "snake_case", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toSnakeCase
            return out == $0 ? nil : out
        },
        make("text.kebab-case", icon: "minus", label: "kebab-case", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toKebabCase
            return out == $0 ? nil : out
        },
        make("text.camel-case", icon: "c.circle", label: "camelCase", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.toCamelCase
            return out == $0 ? nil : out
        },
        make("text.pascal-case", icon: "textformat.abc", label: "PascalCase", group: "DEV") {
            guard isIdentifierLike($0) else { return nil }
            let out = $0.components(separatedBy: .init(charactersIn: " _-"))
                .filter { !$0.isEmpty }
                .map { $0.capitalized }
                .joined()
            return out == $0 ? nil : out
        },
    ] + aiTools

    private static let aiTools: [ClipboardTool] = [
        makeAI("ai.proofread", icon: "checkmark.seal", label: "Proofread & Fix Grammar", group: "AI",
               minLength: 4) { text in
            await AIService.transform(
                instructions: "You are a careful proofreader. Fix spelling, grammar, and punctuation in the given text WITHOUT changing its meaning, tone, or structure. This is a CORRECTION task: produce a corrected version of the SAME text, not a response, reply, or answer to it. Output ONLY the corrected text, no preamble.",
                text: text
            )
        },
    ]

    static let supportedTranslationLanguages: [(name: String, code: String)] = [
        ("English", "en"), ("Spanish", "es"), ("French", "fr"), ("German", "de"),
        ("Italian", "it"), ("Portuguese", "pt"), ("Dutch", "nl"), ("Russian", "ru"),
        ("Chinese (Simplified)", "zh-Hans"), ("Japanese", "ja"), ("Korean", "ko"),
        ("Arabic", "ar"), ("Hindi", "hi"), ("Turkish", "tr"), ("Vietnamese", "vi"),
        ("Polish", "pl"), ("Swedish", "sv"), ("Thai", "th"), ("Indonesian", "id"),
        ("Greek", "el"),
    ]

    private static func makeAI(
        _ id: String,
        icon: String,
        label: String,
        group: String,
        minLength: Int,
        apply: @escaping (String) async -> String?
    ) -> ClipboardTool {
        ClipboardTool(
            id: id,
            icon: icon,
            label: label,
            group: group,
            preview: { item in
                guard AIService.isModelAvailable(),
                      let text = input(for: item), AIService.fits(text),
                      text.count >= minLength else { return nil }
                return label
            },
            runAsync: { item in
                guard let text = input(for: item), AIService.fits(text) else { return nil }
                guard let result = await apply(text) else {
                    await MainActor.run {
                        AuthManager.shared.registerActionUsage(actionID: "fail.\(id.replacingOccurrences(of: ".", with: "_"))")
                    }
                    return .status("Apple Intelligence couldn't process this.")
                }
                return .text(result)
            }
        )
    }

    private static func isEditDenied(_ item: ClipboardItem) -> Bool {
        guard item.tags.contains(.markdown) else { return false }
        switch item.content {
        case .html, .richText, .rtfd: return true
        default: return false
        }
    }

    private static let editTool = ClipboardTool(
        id: "text.edit",
        icon: "square.and.pencil",
        label: "Edit (E)",
        group: "EDIT",
        preview: { item in
            guard !isEditDenied(item),
                  ClipboardManager.editablePlainText(for: item) != nil else { return nil }
            return "Inline edit — Enter to save, Esc to cancel"
        },
        runSync: { item in
            guard ClipboardManager.editablePlainText(for: item) != nil else { return nil }

            ClipboardManager.shared.beginInlineEdit(for: item)
            return .status("Editing inline…")
        },
        runAsync: { item in
            guard ClipboardManager.editablePlainText(for: item) != nil else { return nil }
            await MainActor.run {
                ClipboardManager.shared.beginInlineEdit(for: item)
            }
            return .status("Editing inline…")
        }
    )

    private static let undoEditTool = ClipboardTool(
        id: "text.undo-edit",
        icon: "arrow.uturn.backward",
        label: "Undo Edit",
        group: "EDIT",
        preview: { item in
            ClipboardManager.shared.inlineEditOriginals[item.id] != nil
                ? "Restore the content before last edit" : nil
        },
        runSync: { item in
            DispatchQueue.main.async { ClipboardManager.shared.revertInlineEdit(id: item.id) }
            return .status("Edit reverted.")
        },
        runAsync: { _ in nil }
    )

    private static let uppercaseTool = ClipboardTool(
        id: "text.uppercase",
        icon: "arrow.up.to.line.compact",
        label: "UPPERCASE (U)",
        group: "CASE",
        preview: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.uppercased()
            return out == s ? nil : out
        },
        runSync: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.uppercased()
            return out == s ? nil : .text(out)
        },
        runAsync: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.uppercased()
            return out == s ? nil : .text(out)
        }
    )

    private static let lowercaseTool = ClipboardTool(
        id: "text.lowercase",
        icon: "arrow.down.to.line.compact",
        label: "lowercase (L)",
        group: "CASE",
        preview: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.lowercased()
            return out == s ? nil : out
        },
        runSync: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.lowercased()
            return out == s ? nil : .text(out)
        },
        runAsync: { item in
            guard let s = input(for: item), isPlainTextOrHexColor(s) else { return nil }
            let out = s.lowercased()
            return out == s ? nil : .text(out)
        }
    )

    private static func richPlainText(for item: ClipboardItem) -> String? {
        switch item.content {
        case .richText(let attr, plain: let s):
            guard !s.isEmpty, hasRealFormatting(attr) else { return nil }
            return s
        case .html(let html, plain: let s):
            guard !s.isEmpty, htmlHasRealFormatting(html) else { return nil }
            return s
        case .rtfd(let data, plain: let s):
            guard !s.isEmpty,
                  let attr = NSAttributedString(rtfd: data, documentAttributes: nil),
                  hasRealFormatting(attr) else { return nil }
            return s
        default:
            return nil
        }
    }

    // Checked against a real rendering — an actually-parsed NSAttributedString
    // — rather than guessed from source markup, so this one function serves
    // both .richText/.rtfd (already real NSAttributedString) and .html (parsed
    // into one below) with identical, reliable logic. Broadened past
    // bold/italic/underline/strikethrough/link/attachment/backgroundColor to
    // also catch foregroundColor (colored, non-default text was previously
    // invisible to this check entirely), paragraph-level formatting (
    // alignment, indentation, line spacing — e.g. a centered or indented
    // quote), kerning, baseline offset (super/subscript), a text shadow, and
    // stroke width (outlined text). Errs toward over-detecting rather than
    // under: offering "Paste as Plain Text" when it turns out not to matter
    // costs nothing, while silently withholding it on real formatting is
    // exactly the reported bug.
    private static func hasRealFormatting(_ attr: NSAttributedString) -> Bool {
        guard attr.length > 0 else { return false }
        var found = false
        // Distinct (family, rounded point size) combinations seen across the
        // run. A single uniform font/size never gets flagged by this alone —
        // that would be far too aggressive (most plain pastes land in one
        // consistent font) — but MULTIPLE combinations in one paste (a
        // heading sized differently from its body, an inline term in a
        // different family) is a reliable, low-false-positive signal that
        // the old checks (which only ever looked at bold/italic traits, not
        // family or size at all) completely missed.
        var fontSignatures = Set<String>()
        attr.enumerateAttributes(in: NSRange(location: 0, length: attr.length)) { attrs, _, stop in
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || traits.contains(.italic)
                    || traits.contains(.condensed) || traits.contains(.expanded) { found = true }
                // A whole paste sitting in ONE deliberately-chosen font
                // (Georgia, a brand/body face, Comic Sans) with no
                // bold/italic/color anywhere used to slip through entirely
                // — fontSignatures.count > 1 only ever caught MULTIPLE
                // fonts in one paste, never "the source app locked this to
                // a specific typeface throughout." Excluded here, in
                // addition to the system UI font, are the two fonts
                // AppKit/RTF fall back to when NO font was ever explicitly
                // chosen: Times (the default for unstyled imported HTML,
                // confirmed directly — a <p> with zero CSS parses to
                // Times-Roman 12pt) and Helvetica (the default plain-text
                // font in TextEdit/Mail/Notes compose fields). Without this
                // exclusion, Pure Paste would appear on nearly every
                // rich-text/HTML capture regardless of whether it carries
                // any real styling, since those two are what "nothing was
                // ever set" looks like in practice — not a deliberate
                // choice by whoever wrote the source content.
                let genuinelyDefaultFamilies: Set<String> = [".AppleSystemUIFont", "Times", "Helvetica"]
                if !genuinelyDefaultFamilies.contains(font.familyName ?? "") { found = true }
                fontSignatures.insert("\(font.familyName ?? font.fontName)@\(Int(font.pointSize.rounded()))")
            }
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 { found = true }
            if let strikethrough = attrs[.strikethroughStyle] as? Int, strikethrough != 0 { found = true }
            if attrs[.link] != nil { found = true }
            if attrs[.attachment] != nil { found = true }
            if attrs[.backgroundColor] != nil { found = true }
            if attrs[.foregroundColor] != nil { found = true }
            if let kern = attrs[.kern] as? CGFloat, kern != 0 { found = true }
            if let baseline = attrs[.baselineOffset] as? CGFloat, baseline != 0 { found = true }
            if attrs[.shadow] != nil { found = true }
            if let stroke = attrs[.strokeWidth] as? CGFloat, stroke != 0 { found = true }
            if let obliqueness = attrs[.obliqueness] as? CGFloat, obliqueness != 0 { found = true }
            if let expansion = attrs[.expansion] as? CGFloat, expansion != 0 { found = true }
            if let ligature = attrs[.ligature] as? Int, ligature == 0 { found = true }
            if let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle {
                if paragraph.alignment != .natural && paragraph.alignment != .left { found = true }
                if paragraph.firstLineHeadIndent != 0 || paragraph.headIndent != 0 { found = true }
                if paragraph.lineSpacing != 0 || paragraph.paragraphSpacing != 0 { found = true }
                // paragraphSpacing (space AFTER) was already checked above;
                // paragraphSpacingBefore is a distinct NSParagraphStyle field
                // for space BEFORE a paragraph and was silently uncovered.
                if paragraph.paragraphSpacingBefore != 0 { found = true }
                // Line-height variants: a document that varies only these
                // (common from DTP-style apps) had nothing above that would
                // ever catch it — alignment/indent/spacing/lists/tabs all
                // stay at their defaults in that case.
                if paragraph.lineHeightMultiple != 0 { found = true }
                if paragraph.minimumLineHeight != 0 || paragraph.maximumLineHeight != 0 { found = true }
                if !paragraph.textLists.isEmpty { found = true }
                if !paragraph.tabStops.isEmpty { found = true }
            }
            if found { stop.pointee = true }
        }
        return found || fontSignatures.count > 1
    }

    // Two independent signals, either one sufficient: a widened marker list
    // (a fast, cheap first pass — now covering far more of what real web/app
    // HTML actually uses, not just the handful of tags the original list
    // had) OR-ed with actually parsing the markup into an NSAttributedString
    // and running the exact same real-attribute check the rich-text and RTFD
    // paths already use. The marker list alone previously missed anything
    // styled only through font-family, font-size, alignment, indentation,
    // letter-spacing, or CSS classes resolved via a <style> block — all
    // common on ordinary websites — which is what made this option
    // disappear unpredictably. The parse-and-inspect signal closes that gap
    // structurally instead of chasing more substrings one at a time.
    private static func htmlHasRealFormatting(_ html: String) -> Bool {
        let lower = html.lowercased()
        let markers = [
            "<b>", "<b ", "<strong", "<i>", "<i ", "<em", "<u>", "<u ",
            "<s>", "<strike", "<del", "<ins", "<mark", "<sup", "<sub",
            "<h1", "<h2", "<h3", "<h4", "<h5", "<h6",
            "<a ", "<ul", "<ol", "<li", "<blockquote", "<code", "<pre",
            "<font", "<hr", "<table", "<tr", "<td", "<th",
            "font-weight", "font-style", "font-family", "font-size",
            "text-decoration", "text-align", "text-indent", "text-transform",
            "letter-spacing", "line-height", "vertical-align",
            "color:", "background-color", "background:", "border",
            "padding", "margin", " style=",
            // AppKit's HTML importer doesn't reliably translate text-shadow
            // into an NSShadow attribute, so the second signal (parse into
            // NSAttributedString, inspect real attributes) can't be trusted
            // to catch it — this marker is the only backstop for it.
            "text-shadow",
        ]
        if markers.contains(where: { lower.contains($0) }) { return true }

        guard let data = html.data(using: .utf8),
              let parsed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil)
        else { return false }
        return hasRealFormatting(parsed)
    }

    private static func markdownStrippedPlainText(for item: ClipboardItem) -> String? {
        guard case .text(let raw) = item.content, case .markdown = item.detectedType else { return nil }
        guard let parsed = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .full))
        else { return nil }
        let stripped = String(parsed.characters)
        return stripped != raw ? stripped : nil
    }

    private static func pastePlainEligibleText(for item: ClipboardItem) -> String? {
        richPlainText(for: item) ?? markdownStrippedPlainText(for: item)
    }

    private static var pastePlainDefault: Bool {
        UserDefaults.standard.object(forKey: "pastePlainTextByDefault") as? Bool ?? false
    }

    private static func plainOutput(for item: ClipboardItem) -> TransformOutput? {
        // Returns `.text`, never `.item(.html(...))` — this tool used to hand
        // back a rebuilt HTML table, so "Paste as Plain Text" pasted markup.
        guard let plain = TableCellExtractor.pureText(for: item)
                ?? pastePlainEligibleText(for: item) else { return nil }
        return .text(plain)
    }

    private static let pastePlainTool = ClipboardTool(
        id: "text.paste-plain",
        icon: "textformat",
        label: "Paste as Plain Text",
        group: "PASTE",
        preview: { item in
            guard !pastePlainDefault else { return nil }
            return TableCellExtractor.pureText(for: item) ?? pastePlainEligibleText(for: item)
        },
        runSync: { item in plainOutput(for: item) },
        runAsync: { item in plainOutput(for: item) }
    )

    private static let pasteFormattedTool = ClipboardTool(
        id: "text.paste-formatted",
        icon: "textformat.alt",
        label: "Paste with Formatting",
        group: "PASTE",
        preview: { item in
            guard pastePlainDefault,
                  richPlainText(for: item) != nil else { return nil }
            return "Paste with original formatting"
        },
        runSync: { item in
            guard richPlainText(for: item) != nil else { return nil }
            return .item(item, message: "Pasted with original formatting.")
        },
        runAsync: { item in
            guard richPlainText(for: item) != nil else { return nil }
            return .item(item, message: "Pasted with original formatting.")
        }
    )

    static func input(for item: ClipboardItem) -> String? {
        switch item.content {
        case .text(let s):               return s
        case .richText(_, plain: let s): return s
        case .html(_, plain: let s):     return s
        case .rtfd(_, plain: let s):     return s
        case .svg(let s):                return s
        case .file(let url) where url.pathExtension.lowercased() != "pdf":
            return FileKindDetector.readableText(from: url)
        default:
            return nil
        }
    }

    private static func make(
        _ id: String,
        icon: String,
        label: String,
        group: String,
        apply: @escaping (String) -> String?
    ) -> ClipboardTool {
        ClipboardTool(
            id: id,
            icon: icon,
            label: label,
            group: group,
            preview: { item in input(for: item).flatMap(apply) },
            runSync: { item in input(for: item).flatMap(apply).map(TransformOutput.text) },
            runAsync: { item in input(for: item).flatMap(apply).map(TransformOutput.text) }
        )
    }

    private static func isHexColor(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 4 else { return false }
        return t.dropFirst().allSatisfy { $0.isHexDigit }
    }

    private static func encodeURLComponents(_ urlString: String) -> String? {
        guard var components = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let encodedPath = components.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        let encodedQuery = components.query?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        components.path = encodedPath ?? components.path
        components.query = encodedQuery
        return components.url?.absoluteString
    }

    private static func isURL(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("http://") || t.hasPrefix("https://"),
              let url = URL(string: t), url.host != nil else { return false }
        return true
    }

    private static func isJSON(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("{") || t.hasPrefix("[") else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil
    }

    private static func isPlainText(_ s: String) -> Bool {
        !isURL(s) && !isJSON(s) && !isHexColor(s)
    }

    private static func isPlainTextOrHexColor(_ s: String) -> Bool {
        !isURL(s) && !isJSON(s)
    }

    private static func isIdentifierLike(_ s: String) -> Bool {
        guard !isURL(s), !isJSON(s), !isHexColor(s) else { return false }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 80, !t.contains("\n") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _-"))
        return t.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func jsonPretty(_ str: String) -> String? {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func jsonMinify(_ str: String) -> String? {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj)
        else { return nil }
        return String(data: out, encoding: .utf8)
    }

}
