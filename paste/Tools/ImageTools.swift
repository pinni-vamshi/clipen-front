import AppKit
import Vision
import webp

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
                ImageService.imageInput(for: item) == nil ? nil : "Extract text from the image"
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
            label: "Reduce Image Size",
            group: "OPTIMIZE",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : "Create a smaller WebP image copy"
            },
            runAsync: { item in
                await ImageService.reducedCopy(from: item)
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
    static let webpPasteboardType = NSPasteboard.PasteboardType("public.webp")

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

    static func reducedCopy(from item: ClipboardItem) async -> TransformOutput? {
        guard let input = imageInput(for: item) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let encoder = WebPEncoder()
                var bestData = input.data
                var bestImage: NSImage?
                var strategy: String?

                func consider(_ data: Data, image: NSImage, strategyLabel: String) {
                    guard data.count < bestData.count else { return }
                    bestData = data
                    bestImage = image
                    strategy = strategyLabel
                }

                let qualityCandidates: [(Float, String)] = [
                    (85, "WebP quality 85%"),
                    (75, "WebP quality 75%"),
                    (65, "WebP quality 65%"),
                    (55, "WebP quality 55%")
                ]

                for (quality, label) in qualityCandidates {
                    guard let webpData = encodeWebP(image: input.image, quality: quality, encoder: encoder),
                          let webpImage = decodeWebP(data: webpData) else { continue }
                    consider(webpData, image: webpImage, strategyLabel: label)
                }

                if bestImage == nil {
                    let scaleCandidates: [(CGFloat, Float, String)] = [
                        (0.9, 75, "scaled to 90% (WebP 75%)"),
                        (0.8, 70, "scaled to 80% (WebP 70%)"),
                        (0.7, 65, "scaled to 70% (WebP 65%)")
                    ]
                    for (scale, quality, label) in scaleCandidates {
                        guard let scaledImage = scaledCopy(of: input.image, factor: scale) else { continue }
                        let width = max(1, Int(scaledImage.size.width.rounded()))
                        let height = max(1, Int(scaledImage.size.height.rounded()))
                        guard let webpData = encodeWebP(
                            image: scaledImage,
                            quality: quality,
                            encoder: encoder,
                            width: width,
                            height: height
                        ),
                        let webpImage = decodeWebP(data: webpData) else { continue }
                        consider(webpData, image: webpImage, strategyLabel: label)
                    }
                }

                guard let reducedImage = bestImage else {
                    continuation.resume(returning: .item(
                        ClipboardItem(content: .image(input.image, rawData: input.data, dataType: input.dataType)),
                        message: "Image is already optimized. Pasted original image."
                    ))
                    return
                }

                let before = ByteCountFormatter.string(fromByteCount: Int64(input.data.count), countStyle: .file)
                let after = ByteCountFormatter.string(fromByteCount: Int64(bestData.count), countStyle: .file)
                let compressed = ClipboardItem(
                    content: .image(reducedImage, rawData: bestData, dataType: webpPasteboardType)
                )
                let mode = strategy.map { " (\($0))" } ?? ""
                continuation.resume(returning: .item(compressed, message: "Reduced image: \(before) → \(after)\(mode)"))
            }
        }
    }

    private static func encodeWebP(
        image: NSImage,
        quality: Float,
        encoder: WebPEncoder,
        width: Int = 0,
        height: Int = 0
    ) -> Data? {
        try? encoder.encode(
            image,
            config: .preset(.picture, quality: quality),
            width: width,
            height: height
        )
    }

    private static func decodeWebP(data: Data) -> NSImage? {
        guard let image = try? WebPDecoder().decode(toImage: data, options: WebpDecoderOptions()) as NSImage else {
            return NSImage(data: data)
        }
        return image
    }

    private static func scaledCopy(of image: NSImage, factor: CGFloat) -> NSImage? {
        guard factor > 0, factor < 1 else { return nil }
        let target = NSSize(
            width: max(1, image.size.width * factor),
            height: max(1, image.size.height * factor)
        )
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy,
                   fraction: 1.0)
        scaled.unlockFocus()
        return scaled
    }

    private static func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType {
        switch url.pathExtension.lowercased() {
        case "png": return .init("public.png")
        case "jpg", "jpeg": return .init("public.jpeg")
        case "heic": return .init("public.heic")
        case "gif": return .init("public.gif")
        case "webp": return webpPasteboardType
        case "tif", "tiff": return .tiff
        case "pdf": return .init("com.adobe.pdf")
        default: return .init("public.image")
        }
    }
}
