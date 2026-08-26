import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import webp

enum VisionOutcome<T> {
    case success(T)
    case decodeFailed
    case visionError
    case empty
}

enum SubjectLiftService {
    static func removeBackground(from image: NSImage) async -> VisionOutcome<(Data, NSImage)> {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .decodeFailed
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    guard let observation = request.results?.first else {
                        continuation.resume(returning: .empty)
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
                        continuation.resume(returning: .visionError)
                        return
                    }
                    continuation.resume(returning: .success((png, out)))
                } catch {
                    continuation.resume(returning: .visionError)
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
                switch await OCRService.extractText(from: input.image) {
                case .success(let text):
                    return .text(text)
                case .decodeFailed:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.image_decode") }
                    return .status("Couldn't read this image.")
                case .visionError:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.ocr_vision_error") }
                    return .status("No text found in image.")
                case .empty:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.ocr") }
                    return .status("No text found in image.")
                }
            }
        ),
        ClipboardTool(
            id: "image.remove-background",
            icon: "person.crop.rectangle.badge.xmark",
            label: "Remove Background",
            group: "VISION",
            preview: { item in
                ImageService.imageInput(for: item) == nil ? nil : "Cut out the subject, transparent background"
            },
            runAsync: { item in
                guard let input = ImageService.imageInput(for: item) else { return nil }
                switch await SubjectLiftService.removeBackground(from: input.image) {
                case .success(let (png, image)):
                    guard let content = ClipboardContent.imageContent(rawData: png, dataType: .init("public.png"), fallback: image) else {
                        return .status("Couldn't create image from result.")
                    }
                    return .item(ClipboardItem(content: content), message: "Removed background.")
                case .decodeFailed:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.image_decode") }
                    return .status("Couldn't find a clear subject to cut out.")
                case .visionError:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.remove_background_vision_error") }
                    return .status("Couldn't find a clear subject to cut out.")
                case .empty:
                    await MainActor.run { AuthManager.shared.registerActionUsage(actionID: "fail.remove_background") }
                    return .status("Couldn't find a clear subject to cut out.")
                }
            }
        )
    ]

}

enum OCRService {

    static func extractText(from img: NSImage) async -> VisionOutcome<String> {
        guard let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .decodeFailed
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let preferred = Locale.preferredLanguages.prefix(3).map { String($0) }
                request.recognitionLanguages = preferred.isEmpty ? ["en-US"] : preferred
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: .visionError)
                    return
                }
                let lines = (request.results ?? [])
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: lines.isEmpty ? .empty : .success(lines))
            }
        }
    }
}
