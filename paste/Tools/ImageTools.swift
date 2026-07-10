import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import webp

/// Subject/background segmentation via Vision's instance-mask request — a
/// headless equivalent of VisionKit's interactive "lift subject" gesture,
/// usable as a pure function (no live view/interaction required).
enum SubjectLiftService {
    static func removeBackground(from image: NSImage) async -> (Data, NSImage)? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    guard let observation = request.results?.first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let masked = try observation.generateMaskedImage(
                        ofInstances: observation.allInstances,
                        from: handler,
                        croppedToInstancesExtent: false
                    )
                    let rep = NSCIImageRep(ciImage: CIImage(cvPixelBuffer: masked))
                    let out = NSImage(size: rep.size)
                    out.addRepresentation(rep)
                    guard let png = out.pngData() else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: (png, out))
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

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
            id: "image.reduce-size",
            icon: "arrow.down.doc",
            label: "Reduce Image Size",
            group: "OPTIMIZE",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : "Smaller file, same format (JPEG/PNG/WebP…)"
            },
            runAsync: { item in
                await ImageService.reducedCopy(from: item)
            }
        ),
        makeConvertTool(id: "image.convert-png", icon: "photo", label: "Convert to PNG", target: .png, kind: .png),
        makeConvertTool(id: "image.convert-jpeg", icon: "photo.fill", label: "Convert to JPEG", target: .jpeg, kind: .jpeg),
        makeConvertTool(id: "image.convert-webp", icon: "photo.badge.arrow.down", label: "Convert to WebP", target: .webp, kind: .webp),
        makeConvertTool(id: "image.convert-heic", icon: "camera", label: "Convert to HEIC", target: .heic, kind: .heic),
        makeConvertTool(id: "image.convert-gif", icon: "photo.stack", label: "Convert to GIF", target: .gif, kind: .gif),
        makeConvertTool(id: "image.convert-tiff", icon: "doc.richtext", label: "Convert to TIFF", target: .tiff, kind: .tiff),
        makeConvertTool(id: "image.convert-bmp", icon: "rectangle.dashed", label: "Convert to BMP", target: .bmp, kind: .bmp),
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
                guard let text = await OCRService.extractText(from: input.image) else {
                    // Analytics: OCR produced nothing for a real image.
                    await MainActor.run {
                        AuthManager.shared.registerActionUsage(actionID: "fail.ocr")
                    }
                    return .status("No text found in image.")
                }
                return .text(text)
            }
        ),
        ClipboardTool(
            id: "image.remove-background",
            icon: "person.crop.rectangle.badge.minus",
            label: "Remove Background",
            group: "VISION",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : "Cut out the subject, transparent background"
            },
            runAsync: { item in
                guard let input = ImageService.imageInput(for: item) else { return nil }
                guard let (png, image) = await SubjectLiftService.removeBackground(from: input.image) else {
                    return .status("Couldn't find a clear subject to cut out.")
                }
                return .item(
                    ClipboardItem(content: ClipboardContent.imageContent(rawData: png, dataType: .init("public.png"), fallback: image)!),
                    message: "Removed background."
                )
            }
        ),
        ClipboardTool(
            id: "ai.describe-image",
            icon: "text.below.photo",
            label: "Describe Image",
            group: "AI",
            preview: { item in
                guard AIService.isImageDescribeAvailable(),
                      ImageService.imageInput(for: item) != nil else { return nil }
                return "Generate a description (alt text) for this image"
            },
            runAsync: { item in
                guard let input = ImageService.imageInput(for: item) else { return nil }
                guard let cgImage = input.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    return .status("Couldn't read this image.")
                }
                guard let description = await AIService.describeImage(cgImage) else {
                    return .status("Apple Intelligence couldn't describe this image.")
                }
                return .text(description)
            }
        )
    ]

    private static func makeConvertTool(
        id: String,
        icon: String,
        label: String,
        target: ImageService.ConvertTarget,
        kind: ImageService.ImageFormatKind
    ) -> ClipboardTool {
        ClipboardTool(
            id: id,
            icon: icon,
            label: label,
            group: "CONVERT",
            preview: { item in
                guard let input = ImageService.imageInput(for: item) else { return nil }
                if ImageService.formatKind(for: input) == kind { return nil }
                if target == .jpeg, ImageService.hasAlphaChannel(input.image) { return nil }
                return "Paste as \(ImageService.formatLabel(for: kind)) image"
            },
            runAsync: { item in await ImageService.convertCopy(from: item, to: target) }
        )
    }
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

