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
        make("pdf.pages-as-png", icon: "photo.stack", label: "Pages as PNG Images", group: "EXPORT") { pdf, data in
            await PDFService.exportPagesAsImages(from: pdf, originalData: data)
        },
        make("pdf.reduce-size", icon: "arrow.down.doc", label: "Reduce File Size", group: "OPTIMIZE") { pdf, data in
            await PDFService.reducedCopy(from: pdf, originalData: data)
        },
    ]

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
            preview: { item in pdfInput(for: item) == nil ? nil : "" },
            runAsync: { item in
                guard let input = pdfInput(for: item) else { return nil }
                return await apply(input.pdf, input.data)
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
        default:
            return nil
        }
    }
}

enum PDFService {
    static func extractAllText(from pdf: PDFDocument) async -> String? {
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

        guard let cgImage = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
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
