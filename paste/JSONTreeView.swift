import SwiftUI

/// A parsed JSON value that keeps object key order — `JSONSerialization`
/// returns `[String: Any]` for objects, and `Dictionary` has no defined
/// iteration order, so going through it would visually scramble the
/// structure the AI prompt deliberately ordered (see AIStructuring.swift's
/// "DESIGN THE JSON STRUCTURE ON PURPOSE" section). A small hand-rolled
/// parser is simpler than fighting JSONSerialization for something it was
/// never designed to preserve.
indirect enum JSONValue {
    case object([(key: String, value: JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)   // kept as raw source text — reformatting through Double would mangle large IDs/precision
    case bool(Bool)
    case null

    static func parse(_ text: String) -> JSONValue? {
        var parser = JSONTreeParser(text)
        guard let value = parser.parseValue() else { return nil }
        parser.skipWhitespace()
        return value
    }
}

private struct JSONTreeParser {
    private let chars: [Character]
    private var i = 0

    init(_ s: String) { chars = Array(s) }

    mutating func skipWhitespace() {
        while i < chars.count, chars[i] == " " || chars[i] == "\n" || chars[i] == "\t" || chars[i] == "\r" { i += 1 }
    }

    private func peek() -> Character? { i < chars.count ? chars[i] : nil }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t":
            guard matchLiteral("true") else { return nil }
            return .bool(true)
        case "f":
            guard matchLiteral("false") else { return nil }
            return .bool(false)
        case "n":
            guard matchLiteral("null") else { return nil }
            return .null
        default:
            return parseNumber()
        }
    }

    private mutating func matchLiteral(_ lit: String) -> Bool {
        let litChars = Array(lit)
        guard i + litChars.count <= chars.count else { return false }
        for (offset, lc) in litChars.enumerated() where chars[i + offset] != lc { return false }
        i += litChars.count
        return true
    }

    private mutating func parseObject() -> JSONValue? {
        i += 1 // {
        var pairs: [(String, JSONValue)] = []
        skipWhitespace()
        if peek() == "}" { i += 1; return .object(pairs) }
        while true {
            skipWhitespace()
            guard peek() == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == ":" else { return nil }
            i += 1
            guard let value = parseValue() else { return nil }
            pairs.append((key, value))
            skipWhitespace()
            if peek() == "," { i += 1; continue }
            if peek() == "}" { i += 1; break }
            return nil
        }
        return .object(pairs)
    }

    private mutating func parseArray() -> JSONValue? {
        i += 1 // [
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { i += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            if peek() == "," { i += 1; continue }
            if peek() == "]" { i += 1; break }
            return nil
        }
        return .array(items)
    }

    private mutating func parseString() -> String? {
        guard peek() == "\"" else { return nil }
        i += 1
        var out = ""
        while let c = peek() {
            if c == "\"" { i += 1; return out }
            if c == "\\" {
                i += 1
                guard let esc = peek() else { return nil }
                switch esc {
                case "\"": out.append("\""); case "\\": out.append("\\"); case "/": out.append("/")
                case "n": out.append("\n"); case "t": out.append("\t"); case "r": out.append("\r")
                case "b": out.append("\u{08}"); case "f": out.append("\u{0C}")
                case "u":
                    guard i + 4 < chars.count else { return nil }
                    let hex = String(chars[(i + 1)...(i + 4)])
                    if let scalarVal = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(scalarVal) {
                        out.append(Character(scalar))
                    }
                    i += 4
                default: out.append(esc)
                }
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return nil
    }

    private mutating func parseNumber() -> JSONValue? {
        let start = i
        if peek() == "-" { i += 1 }
        while let c = peek(), c.isNumber || c == "." || c == "e" || c == "E" || c == "+" || c == "-" { i += 1 }
        guard i > start else { return nil }
        return .number(String(chars[start..<i]))
    }
}

/// Renders a parsed JSON value as an indented tree — the visual counterpart
/// to `AIFactIndex.groupedFlatten`'s hierarchy for the Details popup, but
/// full-depth and un-collapsed since this card has real room to show it,
/// unlike the fixed-size popup.
struct JSONTreeView: View {
    let json: String

    var body: some View {
        if let value = JSONValue.parse(json) {
            VStack(alignment: .leading, spacing: 0) {
                JSONNodeView(key: nil, value: value, depth: 0)
            }
            .padding(12)
        } else {
            // Malformed JSON should never reach here in practice (the
            // prompt requires valid output), but a raw fallback beats a
            // blank card if it ever does.
            Text(json)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.textPri)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
    }
}

private struct JSONNodeView: View {
    let key: String?
    let value: JSONValue
    let depth: Int

    private static let indentWidth: CGFloat = 14

    var body: some View {
        switch value {
        case .object(let pairs):
            VStack(alignment: .leading, spacing: 6) {
                if let key {
                    keyLabel(key)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        JSONNodeView(key: pair.key, value: pair.value, depth: depth + 1)
                    }
                }
                .padding(.leading, key == nil ? 0 : Self.indentWidth)
                .overlay(alignment: .leading) {
                    if key != nil {
                        Rectangle().fill(Color.border).frame(width: 1)
                            .padding(.leading, 3)
                    }
                }
            }

        case .array(let items):
            VStack(alignment: .leading, spacing: 6) {
                if let key {
                    keyLabel(key)
                }
                // A scalar array reads as one line ("a, b, c") — matches
                // how the Details popup and fact chips already treat these,
                // so the same data looks the same everywhere in the app.
                if let joined = Self.scalarArrayJoined(items) {
                    Text(joined)
                        .font(.system(size: 12))
                        .foregroundColor(.textPri)
                        .textSelection(.enabled)
                        .padding(.leading, key == nil ? 0 : Self.indentWidth)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                            JSONNodeView(key: "#\(i + 1)", value: item, depth: depth + 1)
                        }
                    }
                    .padding(.leading, key == nil ? 0 : Self.indentWidth)
                    .overlay(alignment: .leading) {
                        if key != nil {
                            Rectangle().fill(Color.border).frame(width: 1)
                                .padding(.leading, 3)
                        }
                    }
                }
            }

        case .string(let s):
            leafRow(key: key, text: s, color: .textPri)
        case .number(let n):
            leafRow(key: key, text: n, color: .accent, monospaced: true)
        case .bool(let b):
            leafRow(key: key, text: b ? "true" : "false", color: .textSec, monospaced: true)
        case .null:
            leafRow(key: key, text: "\u{2014}", color: .textDim, monospaced: true)
        }
    }

    private func keyLabel(_ key: String) -> some View {
        Text(Self.displayKey(key))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(.textDim)
            .tracking(0.4)
    }

    @ViewBuilder
    private func leafRow(key: String?, text: String, color: Color, monospaced: Bool = false) -> some View {
        if let key {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                keyLabel(key).frame(minWidth: 60, alignment: .leading)
                Text(text)
                    .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                    .foregroundColor(color)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(text)
                .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
                .foregroundColor(color)
                .textSelection(.enabled)
        }
    }

    /// "andia_de_das_plot_no" -> "andia de das plot no", array indices
    /// ("#3") pass through untouched — matches the same underscore-to-space
    /// convention `AIFactIndex.flatten` already uses, so a value reads the
    /// same whether you're seeing it here or in the Details popup.
    private static func displayKey(_ key: String) -> String {
        key.hasPrefix("#") ? key : key.replacingOccurrences(of: "_", with: " ").uppercased()
    }

    private static func scalarArrayJoined(_ items: [JSONValue]) -> String? {
        guard !items.isEmpty else { return nil }
        var parts: [String] = []
        for item in items {
            switch item {
            case .string(let s): parts.append(s)
            case .number(let n): parts.append(n)
            case .bool(let b): parts.append(b ? "true" : "false")
            default: return nil
            }
        }
        return parts.joined(separator: ", ")
    }
}
