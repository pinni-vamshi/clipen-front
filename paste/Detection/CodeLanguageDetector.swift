import Foundation

enum CodeLanguageDetector {

    static func detect(_ text: String, fileExtension: String? = nil) -> String? {
        guard text.count <= 50_000 else {
            return fileExtension.flatMap { languageForExtension($0) }
        }

        var scores: [String: Double] = [:]
        var tokenHits: [String: Int] = [:]

        let shebangLang = shebangLanguage(text)
        if let shebangLang {
            scores[shebangLang, default: 0] += 6
        }

        for (lang, tokens) in weightedTokens {
            var s = 0.0
            var hits = 0
            for (token, weight) in tokens where occurs(token, in: text) {
                s += weight
                hits += 1
            }
            if s > 0 {
                scores[lang, default: 0] += s
                tokenHits[lang] = hits
            }
        }

        let extLang = fileExtension.flatMap { languageForExtension($0) }
        if let extLang {
            scores[extLang, default: 0] += 4
        }

        guard let best = scores.max(by: { $0.value < $1.value }), best.value >= 3 else { return nil }

        // A shebang or a file extension is direct evidence; keywords alone
        // are not. One keyword is all ordinary writing ever trips — "the
        // user interface", "she puts", "data class imbalance", "my
        // companion" each used to score a full 3 and tag a sentence as
        // TypeScript, Ruby or Kotlin. So a keyword-only verdict needs either
        // two different keywords, or the punctuation density real code has
        // and prose doesn't. SQL and YAML are exempt: SQL's tokens are
        // matched in upper case, which prose effectively never is, and
        // YAML's (`- name:`, `: |`) aren't things sentences contain — while
        // YAML itself has almost no punctuation for the density test to see.
        if best.key == shebangLang || best.key == extLang || best.key == "SQL" || best.key == "YAML" {
            return best.key
        }
        let density = codePunctuationDensity(text)
        let hits = tokenHits[best.key] ?? 0
        if density >= 0.04 { return best.key }
        if hits >= 2, density >= 0.015 || best.value >= 6 { return best.key }
        return nil
    }

    /// `text.contains(token)` with a word boundary in front of tokens that
    /// start with a letter, so `val ` no longer matches inside "interval ",
    /// `let ` inside "outlet ", or `end\n` at the end of "weekend".
    private static func occurs(_ token: String, in text: String) -> Bool {
        guard let first = token.first, first.isLetter else { return text.contains(token) }
        var from = text.startIndex
        while let r = text.range(of: token, options: .literal, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex { return true }
            let prev = text[text.index(before: r.lowerBound)]
            if !(prev.isLetter || prev.isNumber || prev == "_") { return true }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    /// Share of non-space characters that are code punctuation. Prose sits
    /// well under 1%; even terse code is several percent.
    private static func codePunctuationDensity(_ text: String) -> Double {
        var symbols = 0
        var total = 0
        for ch in text.prefix(20_000) where !ch.isWhitespace {
            total += 1
            switch ch {
            case "{", "}", "(", ")", "[", "]", ";", "=", "<", ">", "*", "&", "|": symbols += 1
            default: break
            }
        }
        return total == 0 ? 0 : Double(symbols) / Double(total)
    }

    /// Languages whose comments start with `#`. In these, a `# ...` line is a
    /// comment, not a Markdown heading.
    static let hashCommentLanguages: Set<String> = ["Python", "Shell", "Ruby", "YAML", "Perl", "PHP", "TOML"]

    static func languageForExtension(_ ext: String) -> String? {
        extensionMap[ext.lowercased()]
    }

    /// The highlight.js language id for a name from anywhere in the app: a
    /// detector display name ("Swift", "C/C++"), a fence tag from Markdown
    /// ("swift", "py", "sh", "ts"), or a lowercase name ("json").
    ///
    /// This used to be an exact lookup on display names only, so `"json"`
    /// (what the JSON preview passes), every Markdown fence tag and every
    /// lowercase name returned nil. Highlightr treats nil as "guess", and
    /// guessing runs every grammar it has over the text — slow, done twice
    /// per copy by the capture-time prewarm, and sometimes the wrong
    /// language entirely.
    static func hljsIdentifier(for displayName: String?) -> String? {
        guard let raw = displayName?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let id = hljsMap[raw] { return id }
        let key = raw.lowercased()
        if let id = hljsAliases[key] { return id }
        if let display = extensionMap[key], let id = hljsMap[display] { return id }
        if let display = hljsMap.keys.first(where: { $0.lowercased() == key }) { return hljsMap[display] }
        // highlight.js knows far more languages than we name. A plain id is
        // passed through; Highlightr falls back to guessing if it's unknown.
        let idChars = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "+#-_"))
        return key.unicodeScalars.allSatisfy(idChars.contains) ? key : nil
    }

    private static let hljsAliases: [String: String] = [
        "js": "javascript", "node": "javascript", "javascript": "javascript",
        "ts": "typescript", "typescript": "typescript",
        "py": "python", "python3": "python",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "terminal": "bash",
        "c": "cpp", "c++": "cpp", "h": "cpp",
        "objc": "objectivec", "objective-c": "objectivec", "obj-c": "objectivec",
        "html": "xml", "xhtml": "xml", "svg": "xml", "plist": "xml",
        "yml": "yaml", "md": "markdown", "tex": "latex",
        "golang": "go", "rs": "rust", "kt": "kotlin", "rb": "ruby", "cs": "csharp", "c#": "csharp",
        "toml": "ini", "conf": "ini", "dockerfile": "dockerfile", "docker": "dockerfile",
    ]

    private static func shebangLanguage(_ text: String) -> String? {
        guard text.hasPrefix("#!") else { return nil }
        let firstLine = text.prefix(while: { $0 != "\n" }).lowercased()
        if firstLine.contains("python") { return "Python" }
        if firstLine.contains("bash") || firstLine.contains("/sh") || firstLine.contains("zsh") { return "Shell" }
        if firstLine.contains("ruby") { return "Ruby" }
        if firstLine.contains("node") { return "JavaScript" }
        if firstLine.contains("perl") { return "Perl" }
        if firstLine.contains("php") { return "PHP" }
        return nil
    }

    private static let weightedTokens: [String: [(String, Double)]] = [
        "Swift":      [("import SwiftUI", 4), ("@State", 3), ("guard let", 2), ("func ", 1), ("-> ", 0.5),
                       ("var ", 0.5), ("let ", 0.5), ("struct ", 1), ("?? ", 1), ("@Published", 3)],
        "Python":     [("def ", 1.5), ("if __name__", 4), ("elif ", 3), ("import ", 0.5), ("print(", 1),
                       ("self.", 1), ("None", 1), ("lambda ", 2), ("):\n", 2), (" in range(", 3)],
        "JavaScript": [("function ", 1), ("=>", 1), ("console.log", 3), ("const ", 1), ("require(", 2),
                       ("document.", 2), ("=== ", 1.5), ("await ", 1)],
        "TypeScript": [("interface ", 3), (": string", 2), (": number", 2), (": void", 2), ("export ", 1),
                       ("import { ", 1), ("<T>", 2), ("as const", 2)],
        "Rust":       [("fn ", 1.5), ("let mut", 3), ("impl ", 3), ("pub fn", 3), ("println!", 4),
                       ("match ", 1), ("::", 0.5), ("&str", 3), ("Vec<", 2)],
        "Go":         [("func ", 1), (":=", 3), ("fmt.Println", 4), ("package ", 2), ("go func", 3),
                       ("chan ", 3), ("interface{}", 3), ("err != nil", 4)],
        "Kotlin":     [("fun ", 2), ("val ", 1), ("data class", 4), ("companion ", 3), ("override fun", 3),
                       ("?: ", 1), ("suspend ", 2)],
        "Java":       [("public class", 3), ("public static void", 4), ("System.out.println", 4),
                       ("@Override", 3), ("private ", 0.5), ("new ", 0.5), ("implements ", 2)],
        "C/C++":      [("#include", 3), ("int main", 3), ("printf(", 2), ("std::", 3), ("nullptr", 3),
                       ("cout <<", 3), ("malloc(", 3), ("template<", 3)],
        "HTML":       [("<html", 3), ("<div", 2), ("<body", 3), ("<!DOCTYPE", 4), ("<script", 2),
                       ("</", 1), ("class=\"", 1.5)],
        "CSS":        [("font-size:", 2), ("color:", 1.5), ("margin:", 2), ("padding:", 2), ("display:", 2),
                       ("flex", 1), ("@media", 3), ("border-radius:", 3)],
        "SQL":        [("SELECT ", 2), ("FROM ", 2), ("WHERE ", 2), ("INSERT INTO", 3), ("CREATE TABLE", 4),
                       ("JOIN ", 2), ("GROUP BY", 3)],
        "Shell":      [("#!/bin/", 4), ("echo ", 1), ("grep ", 2), ("chmod ", 3), ("export ", 1),
                       ("&&", 0.5), ("$(", 2)],
        "Ruby":       [("def ", 1), ("puts ", 3), ("attr_", 3), (".each", 2), ("do |", 3), ("end\n", 1),
                       ("require ", 1)],
        "PHP":        [("<?php", 4), ("echo ", 1), ("function ", 1), ("=> ", 1), ("public function", 3)],
        "JSON":       [("{\"", 2), ("\": ", 1), ("\": {", 2), ("\": [", 2), ("[{", 1)],
        "YAML":       [("---\n", 2), (": |", 2), ("- name:", 3), (":\n  ", 1)],
        "LaTeX":      [("\\begin{", 4), ("\\end{", 3), ("\\frac{", 3), ("\\sum", 2), ("\\int", 2),
                       ("\\alpha", 2), ("\\usepackage", 4)],
    ]

    private static let extensionMap: [String: String] = [
        "swift": "Swift",
        "py": "Python", "pyw": "Python",
        "js": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript", "jsx": "JavaScript",
        "ts": "TypeScript", "tsx": "TypeScript",
        "rs": "Rust",
        "go": "Go",
        "kt": "Kotlin", "kts": "Kotlin",
        "java": "Java",
        "c": "C/C++", "h": "C/C++", "cpp": "C/C++", "cc": "C/C++", "cxx": "C/C++",
        "hpp": "C/C++", "hh": "C/C++", "m": "Objective-C", "mm": "Objective-C",
        "html": "HTML", "htm": "HTML", "xhtml": "HTML",
        "css": "CSS", "scss": "CSS", "sass": "CSS", "less": "CSS",
        "sql": "SQL",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "command": "Shell",
        "rb": "Ruby", "erb": "Ruby",
        "php": "PHP",
        "json": "JSON",
        "yaml": "YAML", "yml": "YAML",
        "tex": "LaTeX",
        "xml": "XML", "plist": "XML", "svg": "XML",
        "toml": "TOML", "ini": "INI",
        "dart": "Dart", "lua": "Lua", "scala": "Scala", "r": "R",
    ]

    private static let hljsMap: [String: String] = [
        "Swift": "swift",
        "Python": "python",
        "JavaScript": "javascript",
        "TypeScript": "typescript",
        "Rust": "rust",
        "Go": "go",
        "Kotlin": "kotlin",
        "Java": "java",
        "C/C++": "cpp",
        "HTML": "xml",
        "CSS": "css",
        "SQL": "sql",
        "Shell": "bash",
        "Ruby": "ruby",
        "PHP": "php",
        "JSON": "json",
        "YAML": "yaml",
        "LaTeX": "latex",
        "Objective-C": "objectivec",
        "XML": "xml",
        "TOML": "ini",
        "INI": "ini",
        "Dart": "dart",
        "Lua": "lua",
        "Scala": "scala",
        "R": "r",
    ]
}
