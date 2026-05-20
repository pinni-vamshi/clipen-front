import AppKit
import Vision

enum ImageTools {
    static let all: [ClipboardTool] = [
        ClipboardTool(
            id: "image.info",
            icon: "info.circle",
            label: "Paste Image Info",
            group: "INFO",
            preview: { item in ImageService.imageInput(for: item).map { ImageService.infoText(for: $0) } },
            runSync: { item in ImageService.imageInput(for: item).map { .text(ImageService.infoText(for: $0)) } },
            runAsync: { item in ImageService.imageInput(for: item).map { .text(ImageService.infoText(for: $0)) } }
        ),
        ClipboardTool(
            id: "image.convert-png",
            icon: "photo.badge.arrow.down",
            label: "Convert to PNG",
            group: "EXPORT",
            preview: { item in ImageService.imageInput(for: item) == nil ? nil : "Paste as PNG image" },
            runAsync: { item in
                await ImageService.pngCopy(from: item)
            }
        ),
        ClipboardTool(
            id: "image.ocr",
            icon: "text.viewfinder",
            label: "Extract Text (OCR)",
            group: "VISION",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : ""
            },
            runAsync: { item in
                guard let input = ImageService.imageInput(for: item) else { return nil }
                guard let text = await OCRService.extractText(from: input.image) else { return nil }
                return .text(text)
            }
        ),
        ClipboardTool(
            id: "image.reduce-size",
            icon: "arrow.down.doc",
            label: "Reduce File Size",
            group: "OPTIMIZE",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : ""
            },
            runAsync: { item in
                await ImageService.losslessReducedCopy(from: item)
            }
        )
    ]
}

enum OCRService {
    static func extractText(from img: NSImage) async -> String? {
        guard let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let preferred = Locale.preferredLanguages.prefix(3).map { String($0) }
                request.recognitionLanguages = preferred.isEmpty ? ["en-US"] : preferred
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: lines.isEmpty ? nil : lines)
            }
        }
    }
}

enum ImageService {
    struct ImageInput {
        let image: NSImage
        let data: Data
        let dataType: NSPasteboard.PasteboardType
        let sourceURL: URL?
    }

    static func imageInput(for item: ClipboardItem) -> ImageInput? {
        switch item.content {
        case .image(let image, let data, let dataType) where !dataType.rawValue.contains("pdf"):
            return ImageInput(image: image, data: data, dataType: dataType, sourceURL: nil)
        case .file(let url) where FileKindDetector.isImageFile(url):
            guard let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data) else { return nil }
            return ImageInput(image: image, data: data, dataType: pasteboardType(for: url), sourceURL: url)
        default:
            return nil
        }
    }

    static func infoText(for input: ImageInput) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(input.data.count), countStyle: .file)
        let dimensions = "\(Int(input.image.size.width))×\(Int(input.image.size.height))"
        var lines = [
            "Type: \(input.dataType.rawValue)",
            "Dimensions: \(dimensions)",
            "Size: \(size)"
        ]
        if let url = input.sourceURL {
            lines.insert("Name: \(url.lastPathComponent)", at: 0)
            lines.append("Path: \(url.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func pngCopy(from item: ClipboardItem) async -> TransformOutput? {
        guard let input = imageInput(for: item) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let pngData = input.image.pngData(), let pngImage = NSImage(data: pngData) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: .item(
                    ClipboardItem(content: .image(pngImage, rawData: pngData, dataType: .init("public.png"))),
                    message: "Converted image to PNG."
                ))
            }
        }
    }

    static func losslessReducedCopy(from item: ClipboardItem) async -> TransformOutput? {
        guard let input = imageInput(for: item) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let pngData = input.image.pngData(), let pngImage = NSImage(data: pngData) else {
                    continuation.resume(returning: nil)
                    return
                }

                guard pngData.count < input.data.count else {
                    continuation.resume(returning: .status("Image is already smaller than a lossless PNG copy."))
                    return
                }

                let before = ByteCountFormatter.string(fromByteCount: Int64(input.data.count), countStyle: .file)
                let after  = ByteCountFormatter.string(fromByteCount: Int64(pngData.count), countStyle: .file)
                let compressed = ClipboardItem(
                    content: .image(pngImage, rawData: pngData, dataType: .init("public.png"))
                )
                continuation.resume(returning: .item(compressed, message: "Reduced image: \(before) → \(after)"))
            }
        }
    }

    private static func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType {
        switch url.pathExtension.lowercased() {
        case "png": return .init("public.png")
        case "jpg", "jpeg": return .init("public.jpeg")
        case "heic": return .init("public.heic")
        case "gif": return .init("public.gif")
        case "tif", "tiff": return .tiff
        case "pdf": return .init("com.adobe.pdf")
        default: return .init("public.image")
        }
    }
}
