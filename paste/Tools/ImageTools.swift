import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import webp

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
