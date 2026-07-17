import AppKit
import UniformTypeIdentifiers

enum FileTools {
    static let all: [ClipboardTool] = [
        ClipboardTool(
            id: "file.show-in-finder",
            icon: "finder",
            label: "Show in Finder",
            group: "FILE",
            preview: { item in
                let urls = fileURLs(for: item).filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return nil }
                return urls.count == 1 ? urls[0].path : "\(urls.count) files"
            },
            runSync: { item in
                let urls = fileURLs(for: item).filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return .status("File no longer exists.") }
                return .revealFiles(urls, message: "Shown in Finder.")
            },
            runAsync: { item in
                let urls = fileURLs(for: item).filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return .status("File no longer exists.") }
                return .revealFiles(urls, message: "Shown in Finder.")
            }
        ),
        ClipboardTool(
            id: "file.copy-name",
            icon: "text.cursor",
            label: "Paste File Name",
            group: "FILE",
            preview: { item in
                let urls = fileURLs(for: item)
                guard !urls.isEmpty else { return nil }
                return urls.map(\.lastPathComponent).joined(separator: "\n")
            },
            runSync: { item in
                let names = fileURLs(for: item).map(\.lastPathComponent).filter { !$0.isEmpty }
                guard !names.isEmpty else { return nil }
                return .text(names.joined(separator: "\n"))
            },
            runAsync: { item in
                let names = fileURLs(for: item).map(\.lastPathComponent).filter { !$0.isEmpty }
                guard !names.isEmpty else { return nil }
                return .text(names.joined(separator: "\n"))
            }
        ),
        ClipboardTool(
            id: "file.copy-path",
            icon: "point.topleft.down.curvedto.point.bottomright.up",
            label: "Paste File Path",
            group: "FILE",
            preview: { item in
                let paths = fileURLs(for: item).map(\.path)
                guard !paths.isEmpty else { return nil }
                return paths.joined(separator: "\n")
            },
            runSync: { item in
                let paths = fileURLs(for: item).map(\.path)
                guard !paths.isEmpty else { return nil }
                return .text(paths.joined(separator: "\n"))
            },
            runAsync: { item in
                let paths = fileURLs(for: item).map(\.path)
                guard !paths.isEmpty else { return nil }
                return .text(paths.joined(separator: "\n"))
            }
        ),
        ClipboardTool(
            id: "file.paste-contents",
            icon: "doc.plaintext",
            label: "Paste File Contents",
            group: "TEXT",
            preview: { item in
                readableFilePreview(for: item).map { String($0.prefix(120)) }
            },
            runSync: { item in
                readableFileText(for: item).map(TransformOutput.text)
            },
            runAsync: { item in
                readableFileText(for: item).map(TransformOutput.text)
            }
        ),
        ClipboardTool(
            id: "file.info",
            icon: "info.circle",
            label: "Paste File Info",
            group: "INFO",
            preview: { item in
                let urls = fileURLs(for: item)
                guard !urls.isEmpty else { return nil }
                return urls.count == 1 ? infoLines(for: urls[0]).joined(separator: " · ") : "\(urls.count) files"
            },
            runSync: { item in
                let urls = fileURLs(for: item)
                guard !urls.isEmpty else { return nil }
                return .text(urls.map { infoLines(for: $0).joined(separator: "\n") }.joined(separator: "\n\n"))
            },
            runAsync: { item in
                let urls = fileURLs(for: item)
                guard !urls.isEmpty else { return nil }
                return .text(urls.map { infoLines(for: $0).joined(separator: "\n") }.joined(separator: "\n\n"))
            }
        ),
        ClipboardTool(
            id: "file.copy-as-new-file",
            icon: "doc.on.doc",
            label: "Paste File Copy",
            group: "FILE",
            preview: { item in
                let urls = fileURLs(for: item).filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return nil }
                return urls.count == 1 ? "Create a pasteable copy" : "Create \(urls.count) pasteable copies"
            },
            runAsync: { item in
                let urls = fileURLs(for: item).filter { FileManager.default.fileExists(atPath: $0.path) }
                guard !urls.isEmpty else { return .status("File no longer exists.") }
                return await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let copied = FileSnapshotStore.snapshot(urls)
                        guard !copied.isEmpty else {
                            continuation.resume(returning: .status("Couldn't create file copy."))
                            return
                        }
                        if copied.count == 1 {
                            continuation.resume(returning: .item(
                                ClipboardItem(content: .file(copied[0])),
                                message: "Created file copy."
                            ))
                        } else {
                            continuation.resume(returning: .files(copied, message: "Created \(copied.count) file copies."))
                        }
                    }
                }
            }
        )
    ]

    static func fileURLs(for item: ClipboardItem) -> [URL] {
        switch item.content {
        case .file(let url):
            return [url]
        case .files(let urls):
            return urls
        case .text(let s), .richText(_, plain: let s), .html(_, plain: let s):
            return localFileURL(from: s).map { [$0] } ?? []
        default:
            return []
        }
    }

    private static func localFileURL(from string: String) -> URL? {
        let raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains("\n") else { return nil }
        let url: URL
        if raw.hasPrefix("file://"), let parsed = URL(string: raw), parsed.isFileURL {
            url = parsed
        } else if raw.hasPrefix("/") || raw.hasPrefix("~") {
            url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Short preview of a file's text WITHOUT reading the whole file. The old
    /// preview called readableFileText (which reads up to 200 MB per text file
    /// via Data(contentsOf:)) and then took prefix(120) — a huge main-thread
    /// read to show 120 characters when the panel opens on a big log/CSV.
    /// readableTextPreview streams only the first ~300 KB via FileHandle;
    /// documents already cap at 5 000 chars in readableDocumentText.
    private static func readableFilePreview(for item: ClipboardItem) -> String? {
        guard let url = fileURLs(for: item).first else { return nil }
        if FileKindDetector.isTextFile(url) {
            return FileKindDetector.readableTextPreview(from: url)?.text
        }
        return FileKindDetector.readableDocumentText(from: url)
    }

    private static func readableFileText(for item: ClipboardItem) -> String? {
        let allURLs = fileURLs(for: item)
        guard !allURLs.isEmpty else { return nil }
        let parts = allURLs.compactMap { url -> String? in
            let text: String?
            if FileKindDetector.isTextFile(url) {
                text = FileKindDetector.readableText(from: url)
            } else {
                text = FileKindDetector.readableDocumentText(from: url)
            }
            guard let t = text else { return nil }
            if allURLs.count == 1 { return t }
            return "===== \(url.lastPathComponent) =====\n\(t)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    private static func infoLines(for url: URL) -> [String] {
        var lines = [
            "Name: \(url.lastPathComponent)",
            "Path: \(url.path)"
        ]
        if let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription {
            lines.append("Type: \(type)")
        }
        if let size = fileSize(url) {
            lines.append("Size: \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        if let modified = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
            lines.append("Modified: \(dateFormatter.string(from: modified))")
        }
        return lines
    }

    private static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
