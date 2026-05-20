import Foundation

enum TextTools {
    static let all: [ClipboardTool] = [
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
            return $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
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
    ]

    static func input(for item: ClipboardItem) -> String? {
        switch item.content {
        case .text(let s):               return s
        case .richText(_, plain: let s): return s
        case .html(_, plain: let s):     return s
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
