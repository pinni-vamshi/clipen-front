import AppKit
@preconcurrency import PDFKit

enum PDFTools {
    static let all: [ClipboardTool] = [
        make("pdf.extract-all-text", icon: "doc.text", label: "Extract All Text", group: "TEXT") { pdf, _ in
            guard let text = await PDFService.extractAllText(from: pdf) else { return nil }
            return .text(text)
        },
        make("pdf.first-page-text", icon: "doc", label: "First Page Text", group: "TEXT") { pdf, _ in
            guard let text = await PDFService.extractFirstPageText(from: pdf) else { return nil }
            return .text(text)
        },
        make("pdf.page-count", icon: "number.circle", label: "Page Count", group: "INFO") { pdf, _ in
            .text("\(pdf.pageCount) pages")
        },
        // Interactive — `runAsync` here is a no-op placeholder; the real
        // behaviour is intercepted in ClipboardManager.commitPaste, which
        // swaps the transform panel into the inline page-picker instead of
        // running this closure.  Two flavours: one combines selected pages
        // into a single PDF; the other renders each selected page as its
        // own PNG image file.  Both share the picker UI; mode is set on
        // entry based on which tool ID was active when ⌘ was released.
        make("pdf.paste-pages", icon: "doc.text.below.ecg", label: "Paste Specific Pages", group: "TEXT") { pdf, _ in
            .status("Pick pages in the panel.")
        },
        make("pdf.paste-pages-as-images", icon: "photo.stack", label: "Paste Specific Pages as Images", group: "EXPORT") { pdf, _ in
            .status("Pick pages in the panel.")
        },
        make("pdf.pages-as-png", icon: "photo.stack", label: "Pages as PNG Images", group: "EXPORT") { pdf, data in
            await PDFService.exportPagesAsImages(from: pdf, originalData: data)
        },
        make("pdf.reduce-size", icon: "arrow.down.doc", label: "Reduce PDF Size", group: "OPTIMIZE") { pdf, data in
            await PDFService.reducedCopy(from: pdf, originalData: data)
        },
        ClipboardTool(
            id: "ai.pdf-summarize",
            icon: "text.line.first.and.arrowtriangle.forward",
            label: "Summarize",
            group: "AI",
            preview: { item in
                guard AIService.isModelAvailable(), pdfInput(for: item) != nil else { return nil }
                return "Summarize this PDF"
            },
            runAsync: { item in
                guard let input = pdfInput(for: item) else { return nil }
                guard let text = await PDFService.extractAllText(from: input.pdf), AIService.fits(text) else {
                    return .status("No extractable text found in PDF.")
                }
                guard let summary = await AIService.transform(
                    instructions: "You are a concise summarizer. Summarize the given document text in 2-5 sentences. Output ONLY the summary, no preamble.",
                    text: text
                ) else {
                    return .status("Apple Intelligence couldn't summarize this.")
                }
                return .text(summary)
            }
        ),
        ClipboardTool(
            id: "ai.pdf-describe-pages",
            icon: "text.below.photo",
            label: "Describe Each Page (AI)",
            group: "AI",
            preview: { item in
                // Renders + describes every page one at a time — capped at a
                // small page count so this can't turn into a multi-minute
                // run on a 200-page PDF. Requires the image-description
                // capability specifically (not just the text model), since
                // each page is handed to Foundation Models as a real image.
                guard AIService.isImageDescribeAvailable(),
                      let input = pdfInput(for: item),
                      (1...Self.maxDescribablePages).contains(input.pdf.pageCount) else { return nil }
                return "Describe each of \(input.pdf.pageCount) pages"
            },
            runAsync: { item in
                guard let input = pdfInput(for: item),
                      (1...Self.maxDescribablePages).contains(input.pdf.pageCount) else { return nil }
                var lines: [String] = []
                for i in 0..<input.pdf.pageCount {
                    guard let page = input.pdf.page(at: i),
                          let cgImage = PDFService.renderCGImage(page: page, scale: 1.5) else {
                        lines.append("Page \(i + 1): [Couldn't render this page]")
                        continue
                    }
                    let description = await AIService.describeImage(cgImage)
                    lines.append("Page \(i + 1): \(description ?? "[Couldn't describe this page]")")
                }
                guard !lines.isEmpty else { return .status("Couldn't describe any pages.") }
                return .text(lines.joined(separator: "\n\n"))
            }
        ),
    ]

    /// Page-by-page AI description renders + runs the model once PER page —
    /// linear cost that's fine for a handful of pages but would make a long
    /// document take minutes. Hidden above this cap rather than silently slow.
    private static let maxDescribablePages = 10

    private static func make(
        _ id: String,
        icon: String,
        label: String,
        group: String,
        apply: @escaping (PDFDocument, Data?) async -> TransformOutput?
    ) -> ClipboardTool {
        ClipboardTool(
            id: id,
            icon: icon,
            label: label,
            group: group,
            preview: { item in
                guard pdfInput(for: item) != nil else { return nil }
                switch id {
                case "pdf.extract-all-text": return "Extract text from all pages"
                case "pdf.first-page-text": return "Extract text from the first page"
                case "pdf.page-count": return "Show total page count"
                case "pdf.pages-as-png": return "Export each page as a PNG image"
                case "pdf.reduce-size": return "Create a smaller PDF copy"
                case "pdf.paste-pages": return "Pick pages → paste as one combined PDF"
                case "pdf.paste-pages-as-images": return "Pick pages → paste each as a PNG image"
                default: return ""
                }
            },
            runAsync: { item in
                guard let input = pdfInput(for: item) else { return nil }
                guard let result = await apply(input.pdf, input.data) else {
                    switch id {
                    case "pdf.extract-all-text", "pdf.first-page-text":
                        return .status("No text found in PDF.")
                    default:
                        return nil
                    }
                }
                return result
            }
        )
    }

    static func pdfInput(for item: ClipboardItem) -> (pdf: PDFDocument, data: Data?)? {
        switch item.content {
        case .image(let image, let data, let dataType) where dataType.rawValue.contains("pdf"):
            guard let pdf = PDFDocument(data: data) ?? PDFDocument(data: image.tiffRepresentation ?? Data()) else { return nil }
            return (pdf, data)
        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            guard let pdf = PDFDocument(url: url) else { return nil }
            return (pdf, try? Data(contentsOf: url))
        // One-element files-list of a PDF — same as a single .file capture.
        case .files(let urls) where urls.count == 1 && urls[0].pathExtension.lowercased() == "pdf":
            guard let pdf = PDFDocument(url: urls[0]) else { return nil }
            return (pdf, try? Data(contentsOf: urls[0]))
        default:
            return nil
        }
    }
}

enum PDFService {
    static func extractAllText(from pdf: PDFDocument) async -> String? {
        // PDFDocument is not Sendable — extract page strings on the calling actor,
        // then dispatch only the join+trim to a background thread.
        let pages: [String] = (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let combined = pages.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: combined.isEmpty ? nil : combined)
            }
        }
    }

    static func extractFirstPageText(from pdf: PDFDocument) async -> String? {
        let raw = pdf.page(at: 0)?.string ?? ""
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
    }

    static func reducedCopy(from pdf: PDFDocument, originalData: Data?) async -> TransformOutput? {
        let optimizedData = pdf.dataRepresentation()
        let sourceData = originalData ?? optimizedData
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let sourceData, let optimizedData else {
                    continuation.resume(returning: nil)
                    return
                }

                guard optimizedData.count < sourceData.count else {
                    continuation.resume(returning: .status("PDF is already optimized."))
                    return
                }

                do {
                    let url = try optimizedOutputURL(fileExtension: "pdf")
                    try optimizedData.write(to: url, options: .atomic)
                    let before = ByteCountFormatter.string(fromByteCount: Int64(sourceData.count), countStyle: .file)
                    let after  = ByteCountFormatter.string(fromByteCount: Int64(optimizedData.count), countStyle: .file)
                    continuation.resume(returning: .item(
                        ClipboardItem(content: .file(url)),
                        message: "Reduced PDF: \(before) → \(after)"
                    ))
                } catch {
                    continuation.resume(returning: .status("Couldn't create optimized PDF copy."))
                }
            }
        }
    }

    static func exportPagesAsImages(from pdf: PDFDocument, originalData: Data?) async -> TransformOutput? {
        let sourceData = originalData ?? pdf.dataRepresentation()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let sourceData,
                      let backgroundPDF = PDFDocument(data: sourceData),
                      backgroundPDF.pageCount > 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let dir = try optimizedOutputDirectory(named: "PDF-Pages-\(UUID().uuidString)")
                    var urls: [URL] = []
                    urls.reserveCapacity(backgroundPDF.pageCount)

                    for pageIndex in 0..<backgroundPDF.pageCount {
                        guard let page = backgroundPDF.page(at: pageIndex),
                              let pngData = render(page: page, scale: 2.0) else { continue }

                        let filename = String(format: "page-%03d.png", pageIndex + 1)
                        let url = dir.appendingPathComponent(filename)
                        try pngData.write(to: url, options: .atomic)
                        urls.append(url)
                    }

                    guard !urls.isEmpty else {
                        continuation.resume(returning: .status("Couldn't render PDF pages as images."))
                        return
                    }

                    let label = urls.count == 1 ? "1 page image" : "\(urls.count) page images"
                    continuation.resume(returning: .files(urls, message: "Created \(label) from PDF."))
                } catch {
                    continuation.resume(returning: .status("Couldn't create page image files."))
                }
            }
        }
    }

    private static func render(page: PDFPage, scale: CGFloat) -> Data? {
        guard let cgImage = renderCGImage(page: page, scale: scale) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// Rendered directly as a CGImage (no PNG round-trip) — used by the AI
    /// "Describe Each Page" tool, which hands the pixels straight to
    /// Foundation Models instead of writing/reading a file.
    static func renderCGImage(page: PDFPage, scale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    private static func optimizedOutputURL(fileExtension ext: String) throws -> URL {
        try optimizedOutputDirectory(named: nil)
            .appendingPathComponent("Clipen-Optimized-\(UUID().uuidString).\(ext)")
    }

    private static func optimizedOutputDirectory(named subfolder: String?) throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Optimized", isDirectory: true)
        let target = subfolder.map { dir.appendingPathComponent($0, isDirectory: true) } ?? dir
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }
}
