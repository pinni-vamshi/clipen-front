import Foundation

enum CodeLanguageDetector {

    static func detect(_ text: String, fileExtension: String? = nil) -> String? {
        guard text.count <= 50_000 else {
            return fileExtension.flatMap { languageForExtension($0) }
        }

        var scores: [String: Double] = [:]

        if let shebangLang = shebangLanguage(text) {
            scores[shebangLang, default: 0] += 6
        }

        for (lang, tokens) in weightedTokens {
            var s = 0.0
            for (token, weight) in tokens where text.contains(token) {
                s += weight
            }
            if s > 0 { scores[lang, default: 0] += s }
        }

        if let ext = fileExtension, let extLang = languageForExtension(ext) {
            scores[extLang, default: 0] += 4
        }

        guard let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        return best.value >= 3 ? best.key : nil
    }

    static func languageForExtension(_ ext: String) -> String? {
        extensionMap[ext.lowercased()]
    }

    static func hljsIdentifier(for displayName: String?) -> String? {
        guard let displayName else { return nil }
        return hljsMap[displayName]
    }

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
                       ("self.", 1), ("None", 1), ("lambda ", 2)],
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
        "hpp": "C/C++", "hh": "C/C++", "m": "C/C++", "mm": "C/C++",
        "html": "HTML", "htm": "HTML", "xhtml": "HTML",
        "css": "CSS", "scss": "CSS", "sass": "CSS", "less": "CSS",
        "sql": "SQL",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "command": "Shell",
        "rb": "Ruby", "erb": "Ruby",
        "php": "PHP",
        "json": "JSON",
        "yaml": "YAML", "yml": "YAML",
        "tex": "LaTeX",
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
    ]
}
