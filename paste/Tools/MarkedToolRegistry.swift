import AppKit
import Foundation
import PDFKit

struct MarkedTool {
    let id:      String
    let icon:    String
    let label:   String
    let preview: ([ClipboardItem]) -> String?
    let run:     ([ClipboardItem]) async -> TransformOutput?
}

enum MarkedToolRegistry {

    enum MarkedClass: Hashable { case text, image, pdf, file, mixed }

    static func classify(_ items: [ClipboardItem]) -> MarkedClass {
        func cls(_ item: ClipboardItem) -> MarkedClass {
            switch item.content {
            case .image(_, _, let dataType):
                return dataType.rawValue.contains("pdf") ? .pdf : .image
            case .file(let url):
                if url.pathExtension.lowercased() == "pdf" { return .pdf }
                if FileKindDetector.isImageFile(url) { return .image }
                return .file
            case .files(let urls):
                if urls.count == 1 {
                    if urls[0].pathExtension.lowercased() == "pdf" { return .pdf }
                    if FileKindDetector.isImageFile(urls[0]) { return .image }
                }
                return .file
            case .text, .richText, .html, .rtfd, .svg:
                return .text
            case .blob:
                return .mixed
            }
        }
        let classes = Set(items.map(cls))
        return classes.count == 1 ? classes.first! : .mixed
    }

    static func tools(for items: [ClipboardItem]) -> [MarkedTool] {
        guard items.count >= 2 else { return [] }
        switch classify(items) {
        case .text:  return textTools
        case .image: return imageTools
        case .pdf:   return pdfTools
        case .file:  return fileTools
        case .mixed: return mixedTools
        }
    }

    static func displays(for items: [ClipboardItem]) -> [TransformDisplay] {
        tools(for: items).compactMap { tool in
            guard let preview = tool.preview(items) else { return nil }
            return TransformDisplay(
                id: tool.id, icon: tool.icon, label: tool.label,
                group: "MARKED (\(items.count))",
                preview: preview.isEmpty ? nil : preview
            )
        }
    }

    static func run(items: [ClipboardItem], toolID: String) async -> TransformOutput? {
        guard let tool = tools(for: items).first(where: { $0.id == toolID }) else { return nil }
        return await tool.run(items)
    }

    private static func plainText(_ item: ClipboardItem) -> String? {
        if case .svg(let s) = item.content { return s }
        return TextTools.input(for: item)
    }

    private static func texts(_ items: [ClipboardItem]) -> [String] {
        items.compactMap { plainText($0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
             .filter { !$0.isEmpty }
    }

    private static let textTools: [MarkedTool] = [
        MarkedTool(id: "marked.merge-lines", icon: "text.append", label: "Merge as One Text",
            preview: { "Join \($0.count) items, one per line, in mark order" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                return .text(parts.joined(separator: "\n"))
            }),
        MarkedTool(id: "marked.numbered-list", icon: "list.number", label: "Paste as Numbered List",
            preview: { "1. 2. 3. — \($0.count) items in mark order" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                return .text(parts.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))
            }),
        MarkedTool(id: "marked.bulleted-list", icon: "list.bullet", label: "Paste as Bulleted List",
            preview: { "- item — \($0.count) items in mark order" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                return .text(parts.map { "- \($0)" }.joined(separator: "\n"))
            }),
        MarkedTool(id: "marked.json-array", icon: "curlybraces.square", label: "Paste as JSON Array",
            preview: { "[\"…\", \"…\"] — \($0.count) elements" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                let values: [Any] = parts.map { part in
                    if let data = part.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
                        return obj
                    }
                    return part
                }
                guard let out = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted]),
                      let str = String(data: out, encoding: .utf8) else { return nil }
                return .text(str)
            }),
        MarkedTool(id: "marked.dedupe-merge", icon: "line.3.horizontal.decrease", label: "Merge + Dedupe Lines",
            preview: { "All lines from \($0.count) items, duplicates dropped" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                var seen = Set<String>()
                var lines: [String] = []
                for part in parts {
                    for line in part.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
                        lines.append(trimmed)
                    }
                }
                return lines.isEmpty ? nil : .text(lines.joined(separator: "\n"))
            }),
        MarkedTool(id: "marked.quote-join", icon: "quote.opening", label: "Quote + Comma Join",
            preview: { "'a', 'b', 'c' — SQL IN (…) style, \($0.count) values" },
            run: { items in
                let parts = texts(items)
                guard parts.count >= 2 else { return nil }
                let quoted = parts.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
                return .text(quoted.joined(separator: ", "))
            }),
        MarkedTool(id: "marked.ai-summarize", icon: "text.line.first.and.arrowtriangle.forward",
            label: "Summarize All (Apple Intelligence)",
            preview: { items in
                guard AIService.isModelAvailable() else { return nil }
                return "Summarize \(items.count) items into one paragraph"
            },
            run: { items in await MarkedToolService.summarizeAll(items) }),
    ]

    private static let imageTools: [MarkedTool] = [
        MarkedTool(id: "marked.images-to-pdf", icon: "doc.richtext", label: "Combine into One PDF",
            preview: { "One PDF, \($0.count) pages, in mark order" },
            run: { items in await MarkedToolService.imagesToPDF(items) }),
        MarkedTool(id: "marked.stitch-vertical", icon: "square.stack", label: "Stitch Vertically",
            preview: { "One tall image from \($0.count) images" },
            run: { items in await MarkedToolService.stitch(items, vertical: true) }),
        MarkedTool(id: "marked.stitch-horizontal", icon: "square.stack.3d.right", label: "Stitch Horizontally",
            preview: { "One wide image from \($0.count) images" },
            run: { items in await MarkedToolService.stitch(items, vertical: false) }),
        MarkedTool(id: "marked.ocr-all", icon: "text.viewfinder", label: "OCR All → One Text",
            preview: { "Extract text from all \($0.count) images" },
            run: { items in await MarkedToolService.ocrAll(items) }),
    ]

    private static let pdfTools: [MarkedTool] = [
        MarkedTool(id: "marked.merge-pdfs", icon: "doc.on.doc", label: "Merge into One PDF",
            preview: { "Concatenate \($0.count) PDFs in mark order" },
            run: { items in await MarkedToolService.mergePDFs(items) }),
        MarkedTool(id: "marked.pdf-text-all", icon: "doc.text", label: "Extract Text from All",
            preview: { "All text from \($0.count) PDFs, with headers" },
            run: { items in await MarkedToolService.pdfTextAll(items) }),
    ]

    private static let fileTools: [MarkedTool] = [
        MarkedTool(id: "marked.zip", icon: "archivebox", label: "Zip Marked Files",
            preview: { items in
                let count = items.flatMap { FileTools.fileURLs(for: $0) }
                    .filter { FileManager.default.fileExists(atPath: $0.path) }.count
                return count >= 2 ? "One .zip with \(count) files" : nil
            },
            run: { items in await MarkedToolService.zip(items) }),
        MarkedTool(id: "marked.paste-paths", icon: "point.topleft.down.curvedto.point.bottomright.up",
            label: "Paste All Paths",
            preview: { items in
                let count = items.flatMap { FileTools.fileURLs(for: $0) }.count
                return count >= 2 ? "\(count) paths, one per line" : nil
            },
            run: { items in
                let paths = items.flatMap { FileTools.fileURLs(for: $0) }.map(\.path)
                guard paths.count >= 2 else { return nil }
                return .text(paths.joined(separator: "\n"))
            }),
        MarkedTool(id: "marked.files-info", icon: "info.circle", label: "Paste Combined Info",
            preview: { items in
                let count = items.flatMap { FileTools.fileURLs(for: $0) }.count
                return count >= 2 ? "Name + size for \(count) files, plus total" : nil
            },
            run: { items in MarkedToolService.combinedFileInfo(items) }),
    ]

    private static let mixedTools: [MarkedTool] = [
        MarkedTool(id: "marked.merge-document", icon: "doc.append", label: "Merge as Document",
            preview: { "Flatten \($0.count) items (text, OCR, PDF text, file contents) into one text" },
            run: { items in await MarkedToolService.mergeAsDocument(items) }),
        MarkedTool(id: "marked.file-bundle", icon: "folder", label: "Paste as File Bundle",
            preview: { "Materialise \($0.count) items as files, pasted together" },
            run: { items in await MarkedToolService.fileBundle(items) }),
        MarkedTool(id: "marked.ai-summarize-mixed", icon: "text.line.first.and.arrowtriangle.forward",
            label: "Summarize All (Apple Intelligence)",
            preview: { items in
                guard AIService.isModelAvailable() else { return nil }
                return "Flatten \(items.count) items and summarize into one paragraph"
            },
            run: { items in await MarkedToolService.summarizeAll(items) }),
    ]
}

enum MarkedToolService {

    private static func outputDir(subfolder: String? = nil) throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        let target = subfolder.map { dir.appendingPathComponent($0, isDirectory: true) } ?? dir
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    static func imagesToPDF(_ items: [ClipboardItem]) async -> TransformOutput? {
        let inputs = items.compactMap { ImageService.imageInput(for: $0) }
        guard inputs.count >= 2 else { return .status("Need at least 2 images.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pdf = PDFDocument()
                for input in inputs {
                    if let page = PDFPage(image: input.image) {
                        pdf.insert(page, at: pdf.pageCount)
                    }
                }
                guard pdf.pageCount >= 2, let data = pdf.dataRepresentation() else {
                    continuation.resume(returning: .status("Couldn't build the PDF."))
                    return
                }
                do {
                    let url = try outputDir().appendingPathComponent("Combined-\(UUID().uuidString).pdf")
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: .item(
                        ClipboardItem(content: .file(url)),
                        message: "Combined \(pdf.pageCount) images into one PDF."
                    ))
                } catch {
                    continuation.resume(returning: .status("Couldn't write the PDF file."))
                }
            }
        }
    }

    static func stitch(_ items: [ClipboardItem], vertical: Bool) async -> TransformOutput? {
        let images = items.compactMap { ImageService.imageInput(for: $0)?.image }
        guard images.count >= 2 else { return .status("Need at least 2 images.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var cgs: [CGImage] = []
                cgs.reserveCapacity(images.count)
                for img in images {
                    var rect = NSRect(origin: .zero, size: img.size)
                    guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                        continuation.resume(returning: .status("Couldn't stitch the images."))
                        return
                    }
                    cgs.append(cg)
                }
                let width  = vertical ? (cgs.map(\.width).max() ?? 0) : cgs.map(\.width).reduce(0, +)
                let height = vertical ? cgs.map(\.height).reduce(0, +) : (cgs.map(\.height).max() ?? 0)
                guard width > 0, height > 0,
                      let ctx = CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    continuation.resume(returning: .status("Couldn't stitch the images."))
                    return
                }
                var offset = 0
                if vertical {
                    for cg in cgs {
                        ctx.draw(cg, in: CGRect(x: 0, y: height - offset - cg.height,
                                                width: cg.width, height: cg.height))
                        offset += cg.height
                    }
                } else {
                    for cg in cgs {
                        ctx.draw(cg, in: CGRect(x: offset, y: 0, width: cg.width, height: cg.height))
                        offset += cg.width
                    }
                }
                guard let stitched = ctx.makeImage(),
                      let png = NSBitmapImageRep(cgImage: stitched).representation(using: .png, properties: [:]) else {
                    continuation.resume(returning: .status("Couldn't encode the stitched image."))
                    return
                }
                let fallback = NSImage(cgImage: stitched, size: NSSize(width: width, height: height))
                continuation.resume(returning: .item(
                    ClipboardItem(content: ClipboardContent.imageContent(rawData: png, dataType: .init("public.png"), fallback: fallback)!),
                    message: "Stitched \(cgs.count) images \(vertical ? "vertically" : "horizontally")."
                ))
            }
        }
    }

    static func ocrAll(_ items: [ClipboardItem]) async -> TransformOutput? {
        let inputs = items.compactMap { ImageService.imageInput(for: $0) }
        guard inputs.count >= 2 else { return .status("Need at least 2 images.") }
        let byIndex: [Int: String] = await withTaskGroup(of: (Int, String?).self) { group in
            for (idx, input) in inputs.enumerated() {
                let image = input.image
                group.addTask { (idx, await OCRService.extractText(from: image)) }
            }
            var out: [Int: String] = [:]
            for await (idx, text) in group where text != nil {
                out[idx] = text
            }
            return out
        }
        let parts = inputs.indices.compactMap { idx in
            byIndex[idx].map { "===== image \(idx + 1) =====\n\($0)" }
        }
        guard !parts.isEmpty else { return .status("No text found in any image.") }
        return .text(parts.joined(separator: "\n\n"))
    }

    static func mergePDFs(_ items: [ClipboardItem]) async -> TransformOutput? {
        let inputs = items.compactMap { PDFTools.pdfInput(for: $0) }
        guard inputs.count >= 2 else { return .status("Need at least 2 PDFs.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let merged = PDFDocument()
                var pageIndex = 0
                for input in inputs {
                    for i in 0..<input.pdf.pageCount {
                        if let page = input.pdf.page(at: i) {
                            merged.insert(page, at: pageIndex)
                            pageIndex += 1
                        }
                    }
                }
                guard merged.pageCount > 0, let data = merged.dataRepresentation() else {
                    continuation.resume(returning: .status("Couldn't merge the PDFs."))
                    return
                }
                do {
                    let url = try outputDir().appendingPathComponent("Merged-\(UUID().uuidString).pdf")
                    try data.write(to: url, options: .atomic)
                    continuation.resume(returning: .item(
                        ClipboardItem(content: .file(url)),
                        message: "Merged \(inputs.count) PDFs (\(merged.pageCount) pages)."
                    ))
                } catch {
                    continuation.resume(returning: .status("Couldn't write the merged PDF."))
                }
            }
        }
    }

    static func pdfTextAll(_ items: [ClipboardItem]) async -> TransformOutput? {
        let inputs = items.compactMap { PDFTools.pdfInput(for: $0) }
        guard inputs.count >= 2 else { return .status("Need at least 2 PDFs.") }
        var parts: [String] = []
        for (idx, input) in inputs.enumerated() {
            if let text = await PDFService.extractAllText(from: input.pdf) {
                parts.append("===== PDF \(idx + 1) =====\n\(text)")
            }
        }
        guard !parts.isEmpty else { return .status("No text found in any PDF.") }
        return .text(parts.joined(separator: "\n\n"))
    }

    static func zip(_ items: [ClipboardItem]) async -> TransformOutput? {
        let urls = items.flatMap { FileTools.fileURLs(for: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard urls.count >= 2 else { return .status("Need at least 2 existing files.") }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let stage = try outputDir(subfolder: "ZipStage-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: stage) }
                    var usedNames = Set<String>()
                    for url in urls {
                        var name = url.lastPathComponent
                        var counter = 2
                        while usedNames.contains(name) {
                            let stem = url.deletingPathExtension().lastPathComponent
                            let ext  = url.pathExtension
                            name = ext.isEmpty ? "\(stem) \(counter)" : "\(stem) \(counter).\(ext)"
                            counter += 1
                        }
                        usedNames.insert(name)
                        try FileManager.default.copyItem(at: url, to: stage.appendingPathComponent(name))
                    }
                    let zipURL = try outputDir().appendingPathComponent("Archive-\(UUID().uuidString).zip")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    process.arguments = ["-c", "-k", "--sequesterRsrc", stage.path, zipURL.path]
                    try process.run()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0,
                          FileManager.default.fileExists(atPath: zipURL.path) else {
                        continuation.resume(returning: .status("Couldn't create the zip archive."))
                        return
                    }
                    continuation.resume(returning: .item(
                        ClipboardItem(content: .file(zipURL)),
                        message: "Zipped \(urls.count) files."
                    ))
                } catch {
                    continuation.resume(returning: .status("Couldn't create the zip archive."))
                }
            }
        }
    }

    static func combinedFileInfo(_ items: [ClipboardItem]) -> TransformOutput? {
        let urls = items.flatMap { FileTools.fileURLs(for: $0) }
        guard urls.count >= 2 else { return nil }
        var lines: [String] = []
        var total: UInt64 = 0
        for url in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
            total += size
            lines.append("\(url.lastPathComponent) — \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        }
        lines.append("Total: \(urls.count) files — \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))")
        return .text(lines.joined(separator: "\n"))
    }

    static func flattenToText(_ items: [ClipboardItem]) async -> [String] {
        var parts: [String] = []
        for item in items {
            if let pdf = PDFTools.pdfInput(for: item) {
                if let text = await PDFService.extractAllText(from: pdf.pdf) { parts.append(text) }
            } else if let input = ImageService.imageInput(for: item) {
                if let text = await OCRService.extractText(from: input.image) {
                    parts.append(text)
                } else {
                    parts.append("[Image \(Int(input.image.size.width))×\(Int(input.image.size.height))]")
                }
            } else if case .svg(let src) = item.content {
                parts.append(src)
            } else if let text = TextTools.input(for: item), !text.isEmpty {
                parts.append(text)
            } else {
                let urls = FileTools.fileURLs(for: item)
                if !urls.isEmpty {
                    parts.append(urls.map(\.lastPathComponent).joined(separator: "\n"))
                }
            }
        }
        return parts
    }

    static func mergeAsDocument(_ items: [ClipboardItem]) async -> TransformOutput? {
        guard items.count >= 2 else { return nil }
        let parts = await flattenToText(items)
        guard parts.count >= 2 else { return .status("Couldn't flatten the marked items to text.") }
        return .text(parts.joined(separator: "\n\n"))
    }

    static func summarizeAll(_ items: [ClipboardItem]) async -> TransformOutput? {
        guard items.count >= 2 else { return nil }
        let parts = await flattenToText(items)
        guard !parts.isEmpty else { return .status("Couldn't flatten the marked items to text.") }
        let combined = parts.joined(separator: "\n\n")
        guard AIService.fits(combined) else {
            return .status("Combined text is too long to summarize at once.")
        }
        guard let summary = await AIService.transform(
            instructions: "You are a concise summarizer. Summarize the given text (assembled from multiple clipboard items) in one clear paragraph, 3-6 sentences. Output ONLY the summary, no preamble.",
            text: combined
        ) else {
            return .status("Apple Intelligence couldn't summarize this.")
        }
        return .text(summary)
    }

    static func fileBundle(_ items: [ClipboardItem]) async -> TransformOutput? {
        guard items.count >= 2 else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let dir = try outputDir(subfolder: "Bundle-\(UUID().uuidString)")
                    var urls: [URL] = []
                    for (idx, item) in items.enumerated() {
                        switch item.content {
                        case .file(let u):
                            if FileManager.default.fileExists(atPath: u.path) { urls.append(u) }
                        case .files(let us):
                            urls.append(contentsOf: us.filter { FileManager.default.fileExists(atPath: $0.path) })
                        case .image(_, let data, let dataType):
                            let ext = dataType.rawValue.contains("pdf") ? "pdf"
                                : dataType.rawValue.contains("jpeg") ? "jpg"
                                : dataType.rawValue.contains("gif") ? "gif" : "png"
                            let url = dir.appendingPathComponent("item-\(idx + 1).\(ext)")
                            try data.write(to: url, options: .atomic)
                            urls.append(url)
                        default:
                            if let text = TextTools.input(for: item) ?? {
                                if case .svg(let s) = item.content { return s } else { return nil }
                            }() {
                                let ext = { if case .svg = item.content { return "svg" } else { return "txt" } }()
                                let url = dir.appendingPathComponent("item-\(idx + 1).\(ext)")
                                try text.write(to: url, atomically: true, encoding: .utf8)
                                urls.append(url)
                            }
                        }
                    }
                    guard urls.count >= 2 else {
                        continuation.resume(returning: .status("Couldn't materialise the marked items as files."))
                        return
                    }
                    continuation.resume(returning: .files(urls, message: "Bundled \(urls.count) files."))
                } catch {
                    continuation.resume(returning: .status("Couldn't create the file bundle."))
                }
            }
        }
    }
}
