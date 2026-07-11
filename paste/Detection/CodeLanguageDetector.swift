import Foundation

enum CodeLanguageDetector {
    static func detect(_ text: String) -> String? {
        guard text.count <= 50_000 else { return nil }
        let checks: [(String, [String])] = [
            ("Swift",      ["func ", "var ", "let ", "guard ", "struct ", "import SwiftUI", "@State", ".self"]),
            ("Python",     ["def ", "import ", "print(", "if __name__", "elif ", "self.", "None", "True"]),
            ("JavaScript", ["function ", "const ", "=>", "console.log", "require(", "async ", "await "]),
            ("TypeScript", ["interface ", ": string", ": number", "export ", "import { ", ": void"]),
            ("Rust",       ["fn ", "let mut", "impl ", "pub fn", "println!", "match ", "::"]),
            ("Go",         ["func ", "package ", ":=", "fmt.Println", "go func", "chan "]),
            ("Kotlin",     ["fun ", "val ", "data class", "companion ", "override fun"]),
            ("Java",       ["public class", "public static void", "System.out.println", "@Override"]),
            ("C/C++",      ["#include", "int main", "printf(", "std::", "nullptr", "cout <<"]),
            ("HTML",       ["<html", "<div", "<body", "<!DOCTYPE", "<script", "<style"]),
            ("CSS",        ["font-size:", "color:", "margin:", "padding:", "display:", "flex;"]),
            ("SQL",        ["SELECT ", "FROM ", "WHERE ", "INSERT INTO", "CREATE TABLE", "JOIN "]),
            ("Shell",      ["#!/bin/", "echo ", "grep ", "chmod ", "export ", "alias "]),
            ("Ruby",       ["def ", "end\n", "puts ", "attr_", ".each", "do |"]),
            ("LaTeX",      ["\\begin{", "\\end{", "\\frac{", "\\sum", "\\int", "\\alpha"]),
        ]

        // Score EVERY language by its total keyword hits and return the best
        // match, rather than short-circuiting on the first language in list
        // order to reach 2 hits. Many keywords overlap across languages
        // (`func `, `import `, `def `), so first-to-2 biased results toward
        // whichever language happened to be checked first.
        var best: (lang: String, hits: Int)? = nil
        for (lang, keywords) in checks {
            let hits = keywords.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            if hits >= 2, hits > (best?.hits ?? 1) {
                best = (lang, hits)
            }
        }
        return best?.lang
    }
}
