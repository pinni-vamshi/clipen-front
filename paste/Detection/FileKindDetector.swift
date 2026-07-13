import Foundation
import PDFKit

enum FileKindDetector {
    nonisolated static func isImageFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "bmp",
             "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2":
            return true
        default:
            return false
        }
    }

    nonisolated static func isCodeFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "swift", "py", "rb", "go", "rs", "java", "kt", "kts",
             "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx",
             "m", "mm", "js", "mjs", "cjs", "ts", "jsx", "tsx",
             "php", "sh", "zsh", "bash", "fish", "ps1",
             "sql", "css", "scss", "sass", "less",
             "vue", "svelte", "lua", "pl", "r", "scala", "dart",
             "ex", "exs", "erl", "clj", "cljs", "cljc",
             "hs", "ml", "mli", "fs", "fsi", "vb", "asm", "s":
            return true
        default:
            return false
        }
    }

    nonisolated static func isPlainTextFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "txt", "text", "log", "csv", "tsv", "xml",
             "yaml", "yml", "toml", "ini", "env", "plist",
             "srt", "vtt", "ics", "vcf":
            return true
        default:
            return false
        }
    }

    nonisolated static func isTextFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "txt", "text", "md", "markdown", "json", "csv", "tsv", "xml", "html", "htm",
             "css", "js", "ts", "jsx", "tsx", "swift", "py", "rb", "go", "rs", "java",
             "kt", "c", "h", "m", "mm", "cpp", "hpp", "sql", "sh", "zsh", "bash",
             "log", "yaml", "yml", "toml", "ini", "env", "plist", "srt", "vtt", "ics", "vcf":
            return true
        default:
            return false
        }
    }

    nonisolated static func isHTMLFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "html", "htm", "webarchive":
            return true
        default:
            return false
        }
    }

    nonisolated static func isVideoFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mpeg", "mpg",
             "3gp", "3g2", "mts", "m2ts", "ts":
            return true
        default:
            return false
        }
    }

    nonisolated static func isAudioFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "mp3", "aac", "wav", "m4a", "aiff", "aif", "caf", "flac", "ogg", "oga",
             "opus", "wma", "amr":
            return true
        default:
            return false
        }
    }

    nonisolated static func isMediaFile(_ url: URL) -> Bool {
        isVideoFile(url) || isAudioFile(url)
    }

    nonisolated static func is3DModelFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "usdz", "usd", "usda", "usdc", "obj", "stl", "ply",
             "dae", "abc", "scn", "fbx", "gltf", "glb",
             "blend", "dwg", "dxf":
            return true
        default:
            return false
        }
    }

    nonisolated static func isDocumentFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "ppt", "pptx", "pps", "ppsx", "pot", "potx",
             "xls", "xlsx", "xlsm", "xlsb", "xlt", "xltx",
             "doc", "docx", "dot", "dotx",
             "pages", "numbers", "key",
             "pdf", "rtf", "rtfd", "odt", "ods", "odp",
             "html", "htm", "webarchive",
             "epub", "mobi", "azw3":
            return true
        default:
            return false
        }
    }

    nonisolated static func isArchiveFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso":
            return true
        default:
            return false
        }
    }

    nonisolated static func isDesignFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "psd", "ai", "sketch", "fig", "xd", "indd":
            return true
        default:
            return false
        }
    }

    nonisolated static func isFontFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "ttf", "otf", "woff", "woff2", "ttc":
            return true
        default:
            return false
        }
    }

    nonisolated static func isDataFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "sqlite", "sqlite3", "db", "parquet", "arrow":
            return true
        default:
            return false
        }
    }

    nonisolated static func isInstallerFile(_ url: URL) -> Bool {
        switch fileExtension(url) {
        case "dmg", "pkg", "app":
            return true
        default:
            return false
        }
    }

    nonisolated static func readableText(from url: URL, maxBytes: Int = 200 * 1024 * 1024) -> String? {
        guard isTextFile(url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              size <= maxBytes,
              let data = try? Data(contentsOf: url) else { return nil }

        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .isoLatin1)
    }

    nonisolated static func readableTextPreview(
        from url: URL, maxPreviewBytes: Int = 300_000
    ) -> (text: String, isTruncated: Bool)? {
        guard isTextFile(url),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let isTruncated = size > maxPreviewBytes
        let data = isTruncated ? handle.readData(ofLength: maxPreviewBytes) : handle.readDataToEndOfFile()

        func decode(_ d: Data) -> String? {
            guard let s = String(data: d, encoding: .utf8)
                ?? String(data: d, encoding: .utf16)
                ?? String(data: d, encoding: .isoLatin1) else { return nil }
            return String(s.drop(while: \.isWhitespace))
        }
        guard isTruncated else {
            guard let text = decode(data) else { return nil }
            return (text, false)
        }
        var trimmed = data
        for _ in 0..<4 {
            if let text = decode(trimmed) { return (text, true) }
            guard !trimmed.isEmpty else { break }
            trimmed.removeLast()
        }
        return nil
    }

    nonisolated static func readableDocumentText(from url: URL, maxChars: Int = 5_000) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { return nil }
            var text = ""
            for i in 0..<min(pdf.pageCount, 3) {
                if let pageText = pdf.page(at: i)?.string {
                    text += pageText + "\n"
                }
                if text.count > maxChars { break }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(maxChars))

        case "doc", "docx", "rtf", "rtfd", "odt", "pages":
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue,
               size > 200 * 1024 * 1024 { return nil }
            guard let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
            let trimmed = attr.string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(maxChars))

        default:
            return nil
        }
    }

    private nonisolated static func fileExtension(_ url: URL) -> String {
        url.pathExtension.lowercased()
    }
}
