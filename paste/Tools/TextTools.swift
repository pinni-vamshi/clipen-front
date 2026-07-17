import Foundation

enum TextTools {
    static let all: [ClipboardTool] = [
        editTool,
        pastePlainTool,
        pasteFormattedTool,
        make("text.title-case", icon: "textformat", label: "Title Case", group: "CASE") {
            guard isPlainText($0) else { return nil }
            return $0.titleCased
        },
        make("text.uppercase", icon: "arrow.up.to.line.compact", label: "UPPERCASE", group: "CASE") {
            guard isPlainTextOrHexColor($0) else { return nil }
            let out = $0.uppercased()
            return out == $0 ? nil : out
        },
        make("text.lowercase", icon: "arrow.down.to.line.compact", label: "lowercase", group: "CASE") {
            guard isPlainTextOrHexColor($0) else { return nil }
            let out = $0.lowercased()
            return out == $0 ? nil : out
        },
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
        make("text.csv-markdown", icon: "tablecells", label: "CSV/TSV to Markdown Table", group: "FORMAT") {
            delimitedTableToMarkdown($0)
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
        makeAI("ai.summarize", icon: "text.line.first.and.arrowtriangle.forward", label: "Summarize", group: "AI",
               minLength: AIService.minSummarizableLength) { text in
            await AIService.transform(
                instructions: "You are a concise summarizer. Summarize the given text in 2-4 sentences. Output ONLY the summary, no preamble.",
                text: text
            )
        },
        makeAI("ai.key-points", icon: "list.bullet.rectangle", label: "Extract Key Points", group: "AI",
               minLength: AIService.minSummarizableLength) { text in
            await AIService.transform(
                instructions: "Extract the key points from the given text as a short bulleted list (max 6 bullets, each one line). Output ONLY the list, no preamble.",
                text: text
            )
        },
        makeAI("ai.proofread", icon: "checkmark.seal", label: "Proofread & Fix Grammar", group: "AI",
               minLength: 4) { text in
            await AIService.transform(
                instructions: "You are a careful proofreader. Fix spelling, grammar, and punctuation in the given text WITHOUT changing its meaning, tone, or structure. This is a CORRECTION task: produce a corrected version of the SAME text, not a response, reply, or answer to it. Output ONLY the corrected text, no preamble.",
                text: text
            )
        },
        makeAI("ai.rewrite-professional", icon: "briefcase", label: "Rewrite Professionally", group: "AI",
               minLength: 4) { text in
            await AIService.transform(
                instructions: "Rewrite the given text in a clear, professional tone suitable for work communication, keeping the same meaning and roughly the same length. This is a REWRITE task: produce a new version of the SAME text, not a response, reply, or answer to it. Output ONLY the rewritten text, no preamble.",
                text: text
            )
        },
        makeAI("ai.rewrite-friendly", icon: "face.smiling", label: "Rewrite Casually", group: "AI",
               minLength: 4) { text in
            await AIService.transform(
                instructions: "Rewrite the given text in a warm, casual, friendly tone, keeping the same meaning and roughly the same length. This is a REWRITE task: produce a new version of the SAME text, not a response, reply, or answer to it. Output ONLY the rewritten text, no preamble.",
                text: text
            )
        },
        makeAI("ai.explain", icon: "questionmark.bubble", label: "Explain This", group: "AI",
               minLength: 4) { text in
            await AIService.transform(
                instructions: "Explain the given text simply and clearly, as if to someone unfamiliar with the topic. Keep it under 5 sentences. Output ONLY the explanation, no preamble.",
                text: text
            )
        },
        ClipboardTool(
            id: "ai.convert-json", icon: "curlybraces", label: "Convert to JSON (AI)", group: "AI",
            preview: { item in
                guard AIService.isModelAvailable(),
                      let text = input(for: item), AIService.fits(text),
                      text.count >= 20, !isJSON(text) else { return nil }
                return "Convert to JSON (AI)"
            },
            runAsync: { item in
                guard let text = input(for: item), AIService.fits(text) else { return nil }
                guard let result = await AIService.transform(
                    instructions: "Convert the given text into well-structured JSON, inferring reasonable field names from its content. Output ONLY valid JSON, no markdown code fences, no preamble.",
                    text: text
                ) else {
                    return .status("Apple Intelligence couldn't convert this to JSON.")
                }
                return .text(result)
            }
        ),
        ClipboardTool(
            id: "ai.convert-table", icon: "tablecells", label: "Convert to Table (AI)", group: "AI",
            preview: { item in
                guard AIService.isModelAvailable(),
                      let text = input(for: item), AIService.fits(text),
                      text.count >= 20, delimitedTableToMarkdown(text) == nil else { return nil }
                return "Convert to a Markdown table (AI)"
            },
            runAsync: { item in
                guard let text = input(for: item), AIService.fits(text) else { return nil }
                guard let result = await AIService.transform(
                    instructions: "Convert the given text into a well-structured Markdown table, inferring reasonable column headers from its content. Output ONLY the Markdown table, no preamble.",
                    text: text
                ) else {
                    return .status("Apple Intelligence couldn't convert this to a table.")
                }
                return .text(result)
            }
        ),
        ClipboardTool(
            id: "ai.translate", icon: "character.bubble", label: "Translate", group: "AI",
            preview: { item in
                guard AIService.isModelAvailable(),
                      let text = input(for: item), AIService.fits(text) else { return nil }
                return "Pick a language…"
            },
            runAsync: { _ in .status("Pick a language in the panel.") }
        ),
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
                    return .status("Apple Intelligence couldn't process this.")
                }
                return .text(result)
            }
        )
    }

    private static let editTool = ClipboardTool(
        id: "text.edit",
        icon: "square.and.pencil",
        label: "Edit",
        group: "EDIT",
        preview: { item in
            guard ClipboardManager.editablePlainText(for: item) != nil else { return nil }
            return "Edit in reference panel…"
        },
        runSync: { item in
            guard ClipboardManager.editablePlainText(for: item) != nil else { return nil }
            AuthManager.shared.registerToolUsage(toolID: "text.edit")
            ClipboardManager.shared.openQuickClipPanel(for: item, focusContent: true)
            return .status("Opened in reference panel for editing.")
        },
        runAsync: { item in
            guard ClipboardManager.editablePlainText(for: item) != nil else { return nil }
            AuthManager.shared.registerToolUsage(toolID: "text.edit")
            await MainActor.run {
                ClipboardManager.shared.openQuickClipPanel(for: item, focusContent: true)
            }
            return .status("Opened in reference panel for editing.")
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

    private static let pastePlainTool = ClipboardTool(
        id: "text.paste-plain",
        icon: "textformat",
        label: "Paste as Plain Text",
        group: "PASTE",
        preview: { item in
            guard !pastePlainDefault else { return nil }
            return richPlainText(for: item)
        },
        runSync: { item in
            guard let plain = richPlainText(for: item) else { return nil }
            return .text(plain)
        },
        runAsync: { item in
            guard let plain = richPlainText(for: item) else { return nil }
            return .text(plain)
        }
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

    private static func delimitedTableToMarkdown(_ str: String) -> String? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let delimiter: Character
        if trimmed.contains("\t") {
            delimiter = "\t"
        } else if trimmed.contains(",") {
            delimiter = ","
        } else {
            return nil
        }

        let rows = trimmed
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(80)
            .map { parseDelimitedLine($0, delimiter: delimiter) }

        guard rows.count >= 2,
              let width = rows.map(\.count).max(),
              width >= 2 else { return nil }

        let normalized = rows.map { row in
            row + Array(repeating: "", count: max(0, width - row.count))
        }
        let header = normalized[0]
        let body = normalized.dropFirst()

        func markdownRow(_ row: [String]) -> String {
            "| " + row.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
        }

        return ([markdownRow(header), markdownRow(Array(repeating: "---", count: width))]
                + body.map(markdownRow))
            .joined(separator: "\n")
    }

    private static func parseDelimitedLine(_ line: String, delimiter: Character) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        current.append("\"")
                    } else {
                        inQuotes = false
                        if next == delimiter {
                            fields.append(current.trimmingCharacters(in: .whitespaces))
                            current = ""
                        } else {
                            current.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == delimiter, !inQuotes {
                fields.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }

        fields.append(current.trimmingCharacters(in: .whitespaces))
        return fields
    }
}
