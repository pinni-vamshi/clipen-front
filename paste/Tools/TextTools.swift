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
            // Registration + opening the editor happen inside beginInlineEdit.
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

    // Deliberately NOT wired to applyCaseTransformForSelection (that stays
    // reserved for the direct L/U keypress, which mutates the item in place
    // and keeps the popup open for toggling). From the Transform panel,
    // release-⌘ is expected to PASTE the result like every other tool here —
    // these used to return `.status(...)`, the same "nothing to paste, just a
    // message" category as an OCR failure, which is why selecting Uppercase/
    // lowercase from the panel and releasing ⌘ only ever flashed a status and
    // left the result sitting in the preview instead of pasting it. Following
    // the same plain, stateless `make(...)` pattern as every sibling CASE tool
    // (e.g. Title Case just above) fixes that: compute the value, return
    // `.text`, and the normal transform-paste path takes it from there.
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
        case .richText(_, plain: let s), .html(_, plain: let s), .rtfd(_, plain: let s):
            return s.isEmpty ? nil : s
        default:
            return nil
        }
    }

    /// Read the pure-paste setting from UserDefaults (thread-safe) rather than
    /// ClipboardManager.shared, because tool previews are evaluated by
    /// ToolRegistry on background queues (async apply/capture paths) and the
    /// manager's @Published property is main-actor state.
    private static var pastePlainDefault: Bool {
        UserDefaults.standard.object(forKey: "pastePlainTextByDefault") as? Bool ?? false
    }

    /// A real table must still paste as a table — flattening it to tab text
    /// only reads back as columns in a spreadsheet; anywhere else (Word,
    /// Pages, Notes, Mail) it lands as bare text with visible tab gaps and
    /// the table is simply gone. So a table gets a fresh, un-styled HTML
    /// table (structure kept, every bold/color/font stripped); anything else
    /// falls back to the flat plain-text string as before.
    private static func plainOutput(for item: ClipboardItem) -> TransformOutput? {
        if let table = TableCellExtractor.plainTableHTML(for: item) {
            return .item(ClipboardItem(content: .html(table.html, plain: table.plain)),
                         message: "Pasted without formatting.")
        }
        guard let plain = richPlainText(for: item) else { return nil }
        return .text(plain)
    }

    private static let pastePlainTool = ClipboardTool(
        id: "text.paste-plain",
        icon: "textformat",
        label: "Paste as Plain Text",
        group: "PASTE",
        preview: { item in
            guard !pastePlainDefault else { return nil }
            return richPlainText(for: item)
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
