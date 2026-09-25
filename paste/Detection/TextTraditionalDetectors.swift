import AppKit
import Foundation

enum TextTraditionalDetectors {
    static func color(from content: ClipboardContent) -> NSColor? {
        guard case .text(let s) = content else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("#"), t.count == 7 || t.count == 4 else { return nil }
        let hex = String(t.dropFirst())
        guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return NSColor(hexString: t)
    }

    private static let maxSingleValueScanLength = 2_048
    private static let maxDocumentScanLength = 50_000

    static func candidates(for text: String, color: NSColor?) -> [DetectionCandidate] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }

        let n = t.count
        let scanSingleValue = n <= maxSingleValueScanLength
        let scanDocument    = n <= maxDocumentScanLength

        var candidates: [DetectionCandidate] = []

        if let color {
            candidates.append(.init(type: .hexColor(color), confidence: 1.0, method: .deterministic))
        }

        if scanSingleValue,
           (t.hasPrefix("http://") || t.hasPrefix("https://")),
           let url = URL(string: t), url.host != nil {
            candidates.append(.init(type: .url, confidence: 0.98, method: .deterministic))
        }

        if scanSingleValue, isEmail(t) {
            candidates.append(.init(type: .email, confidence: 0.97, method: .deterministic))
        }

        if scanSingleValue, isPhoneNumber(t) {
            candidates.append(.init(type: .phone, confidence: 0.9, method: .deterministic))
        }

        if t.hasPrefix("{") || t.hasPrefix("[") {
            if scanDocument {
                if (try? JSONSerialization.jsonObject(with: Data(t.utf8))) != nil {
                    candidates.append(.init(type: .json, confidence: 0.99, method: .deterministic))
                }
            } else if t.hasSuffix("}") || t.hasSuffix("]") {
                candidates.append(.init(type: .json, confidence: 0.8, method: .deterministic))
            }
        }

        if let table = detectDelimitedTable(t) {
            candidates.append(.init(type: .table(table), confidence: 0.92, method: .deterministic))
        }

        if scanDocument, isLatex(t) {
            candidates.append(.init(type: .latex, confidence: 0.9, method: .deterministic))
        } else if scanDocument, isUnicodeMath(t) {
            // Lower confidence than real LaTeX on purpose: markup is proof,
            // whereas a run of symbols is inference and should lose to any
            // detector that can point at actual syntax.
            candidates.append(.init(type: .latex, confidence: 0.72, method: .deterministic))
        }

        if scanDocument, isMarkdown(t) {
            candidates.append(.init(type: .markdown, confidence: 0.86, method: .deterministic))
        }

        if let lang = CodeLanguageDetector.detect(t) {
            candidates.append(.init(type: .code(lang), confidence: 0.84, method: .deterministic))
        }

        if scanDocument, isCommand(t) {
            candidates.append(.init(type: .code("Shell"), confidence: 0.88, method: .deterministic))
        }

        if scanSingleValue, isPostalAddress(t) {
            candidates.append(.init(type: .address, confidence: 0.72, method: .deterministic))
        }

        return candidates
    }

    private static let distinctiveCommands: Set<String> = [
        "sudo","git","npm","npx","yarn","pnpm","brew","curl","wget","docker","kubectl",
        "kubectx","ssh","scp","rsync","xcodebuild","xcrun","cargo","rustc","gradle","mvn",
        "pip","pip3","gem","bundle","rails","rake","composer","gh","glab","terraform",
        "ansible","vagrant","helm","systemctl","journalctl","launchctl","defaults",
        "hdiutil","diskutil","codesign","notarytool","stapler","adb","flutter","expo",
        "tsc","eslint","prettier","jest","webpack","vite","psql","mysql","mongo",
        "redis-cli","aws","gcloud","az","heroku","apt","apt-get","dnf","pacman","conda",
        "poetry","deno","bun","otool","swiftc","dotnet","chmod","chown","chsh","ifconfig",
        "systemsetup","softwareupdate","networksetup","scutil","pmset",
    ]

    private static let commonCommands: Set<String> = [
        "cd","ls","cat","cp","mv","rm","rmdir","mkdir","touch","ln","echo","printf",
        "export","source","make","cmake","find","grep","egrep","awk","sed","tar","zip",
        "unzip","gzip","open","code","vim","nvim","nano","emacs","less","more","head",
        "tail","sort","uniq","wc","tr","cut","xargs","tee","which","whereis","man","kill",
        "killall","ps","top","htop","df","du","free","mount","ping","dig","nslookup",
        "node","python","python3","go","java","ruby","php","perl","curl","set","alias",
    ]

    private static func lineLooksLikeCommand(_ raw: String) -> Bool {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var startedWithPrompt = false
        for prompt in ["$ ", "# ", "% ", "❯ ", "➜ ", "PS> ", "> "] where line.hasPrefix(prompt) {
            line = String(line.dropFirst(prompt.count)).trimmingCharacters(in: .whitespaces)
            startedWithPrompt = true
            break
        }
        guard let firstToken = line.split(separator: " ").first.map(String.init),
              !firstToken.isEmpty else { return false }
        if startedWithPrompt { return true }
        let cmd = firstToken.lowercased()
        if distinctiveCommands.contains(cmd) { return true }
        let hasFlag  = line.range(of: #"\s-\w"#, options: .regularExpression) != nil
        let hasPath  = line.contains("/") || line.contains("./") || line.contains("~/")
        let hasChain = line.contains(" | ") || line.contains("&&") || line.contains("; ")
            || line.contains(" > ") || line.contains(" >> ") || line.contains("$(") || line.contains("`")
        if commonCommands.contains(cmd), hasFlag || hasPath || hasChain { return true }
        return false
    }

    private static func isCommand(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty, lines.count <= 40 else { return false }
        if lines.count == 1 { return lineLooksLikeCommand(lines[0]) }
        let cmdCount = lines.filter(lineLooksLikeCommand).count
        return cmdCount >= 2 && Double(cmdCount) >= Double(lines.count) * 0.6
    }

    private static func detectDelimitedTable(_ text: String) -> String? {
        guard text.contains("\n") else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2, lines.count <= 200 else { return nil }
        for (delimiter, label) in [("\t", "TSV"), (",", "CSV")] {
            let counts = lines.map { $0.split(separator: Character(delimiter), omittingEmptySubsequences: false).count }
            if let first = counts.first, first >= 2, counts.allSatisfy({ $0 == first }) {
                return label
            }
        }
        return nil
    }

    private static func isLatex(_ text: String) -> Bool {

        guard !text.contains("\\documentclass"), !text.contains("\\begin{document}") else {
            return false
        }
        let keywords = ["\\begin{", "\\end{", "\\frac{", "\\sum", "\\int",
                        "\\alpha", "\\beta", "\\gamma", "\\delta", "\\theta",
                        "\\lambda", "\\pi", "\\sigma", "\\sqrt{", "\\infty",
                        "\\text{", "\\mathbf{", "\\cdot", "\\times"]
        let inlineMath = text.hasPrefix("$") && text.hasSuffix("$") && text.count > 2
        let displayMath = text.hasPrefix("\\[") && text.hasSuffix("\\]")
        return keywords.contains(where: { text.contains($0) }) || inlineMath || displayMath
    }

    /// Math written as Unicode symbols rather than LaTeX commands.
    ///
    /// `isLatex` can only see markup — backslash commands or `$` delimiters —
    /// so it misses the form maths actually arrives in when copied out of a
    /// PDF, a Word equation, a web page or a chat answer: literal `∈`, `α`,
    /// `⊕`, `→`, with not one backslash anywhere. A whole category of
    /// mathematical clips was landing as ordinary prose and rendering in the
    /// plain-text preview.
    ///
    /// Three conditions, all required, because the cost of a false positive
    /// is mislabelling normal writing as maths:
    ///  - a STRONG operator (`∈`, `∑`, `≠`, `→`…). Greek letters alone are
    ///    deliberately not enough, or every line of Greek prose would match.
    ///  - at least `minDistinctMathSymbols` different symbols, so one stray
    ///    `α` or a lone `°` in a sentence cannot qualify.
    ///  - at least `minTotalMathSymbols` occurrences, so a passing mention
    ///    loses to a genuine derivation.
    static func isUnicodeMath(_ text: String) -> Bool {
        guard !text.contains("\\"), !text.contains("$") else { return false }

        var distinct = Set<Character>()
        var total = 0
        var sawStrong = false
        for ch in text {
            if strongMathOperators.contains(ch) {
                sawStrong = true
                distinct.insert(ch); total += 1
                continue
            }
            if isMathSymbolCharacter(ch) {
                distinct.insert(ch); total += 1
            }
        }
        return sawStrong
            && distinct.count >= minDistinctMathSymbols
            && total >= minTotalMathSymbols
    }

    private static let minDistinctMathSymbols = 3
    private static let minTotalMathSymbols = 6

    /// Symbols that essentially only occur in mathematics. One of these has
    /// to be present before anything else is even counted.
    private static let strongMathOperators: Set<Character> = [
        "\u{2208}", "\u{2209}", "\u{220B}",            // ∈ ∉ ∋
        "\u{2200}", "\u{2203}", "\u{2204}",            // ∀ ∃ ∄
        "\u{2211}", "\u{220F}", "\u{222B}",            // ∑ ∏ ∫
        "\u{2295}", "\u{2297}", "\u{2299}",            // ⊕ ⊗ ⊙
        "\u{2260}", "\u{2264}", "\u{2265}",            // ≠ ≤ ≥
        "\u{2261}", "\u{2248}", "\u{221D}",            // ≡ ≈ ∝
        "\u{2192}", "\u{21A6}", "\u{21D2}", "\u{21D4}", // → ↦ ⇒ ⇔
        "\u{221A}", "\u{221E}", "\u{2202}", "\u{2207}", // √ ∞ ∂ ∇
        "\u{2286}", "\u{2282}", "\u{222A}", "\u{2229}", // ⊆ ⊂ ∪ ∩
        "\u{2227}", "\u{2228}", "\u{00AC}",            // ∧ ∨ ¬
        "\u{2245}", "\u{2254}", "\u{22A2}", "\u{22A8}", // ≅ ≔ ⊢ ⊨
    ]

    /// Counted toward the density thresholds but never sufficient alone:
    /// Greek letters, sub/superscript digits, and the general Unicode
    /// maths-symbol category.
    private static func isMathSymbolCharacter(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        switch scalar.value {
        case 0x0370...0x03FF, 0x1D400...0x1D7FF:  // Greek, maths alphanumerics
            return true
        case 0x2070...0x209F:                     // super/subscripts
            return true
        case 0x2212, 0x00B7, 0x22C5, 0x00D7, 0x00F7:  // − · ⋅ × ÷
            return true
        default:
            return scalar.properties.isMath
        }
    }

    private static func isMarkdown(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return false }
        if t.hasPrefix("# ") || t.hasPrefix("## ") || t.contains("\n# ") { return true }

        if t.contains("```") || DetectionRegex.matches(#"\[[^\]\n]+\]\([^)\n]+\)"#, in: t) { return true }
        if DetectionRegex.matches(#"(?m)^[ \t]*[-*][ \t]+\S+"#, in: t) ||
           DetectionRegex.matches(#"(?m)^[ \t]*\d+\.[ \t]+\S+"#, in: t) { return true }
        return t.contains("**") || t.contains("__")
    }

    private static func isEmail(_ text: String) -> Bool {
        DetectionRegex.matches(#"^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$"#, in: text, options: [.caseInsensitive])
    }

    private static func isPhoneNumber(_ text: String) -> Bool {
        guard !text.contains("\n") else { return false }
        let t = text.trimmingCharacters(in: .whitespaces)

        if DetectionRegex.matches(#"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, in: t) { return false }

        if DetectionRegex.matches(#"^\d{1,4}[.\-/]\d{1,2}[.\-/]\d{2,4}$"#, in: t) { return false }

        if DetectionRegex.matches(#"^\d+\.\d+(\.\d+)+$"#, in: t) { return false }

        let allowed = CharacterSet(charactersIn: "+0123456789()-. ")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }

        let digits = t.filter(\.isNumber).count
        guard digits >= 7 && digits <= 15 else { return false }

        let hasSeparators = t.contains(where: { "+()-. ".contains($0) })
        if !hasSeparators {
            return digits == 10 || digits == 11
        }

        return true
    }

    private static func isPostalAddress(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= 180, t.contains(where: \.isNumber) else { return false }
        let markers = [" street", " st.", " road", " rd.", " avenue", " ave", " boulevard",
                       " blvd", " lane", " ln", " drive", " dr.", " apt", " suite", " floor"]
        return markers.contains(where: { t.contains($0) })
    }
}
