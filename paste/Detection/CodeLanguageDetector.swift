import Foundation

enum CodeLanguageDetector {
    static func detect(_ text: String) -> String? {
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

        for (lang, keywords) in checks {
            var hits = 0
            for keyword in keywords where text.contains(keyword) {
                hits += 1
                if hits >= 2 { return lang }
            }
        }
        return nil
    }
}
