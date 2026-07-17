import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import webp

enum ImageService {
    static let webpPasteboardType = NSPasteboard.PasteboardType("public.webp")

    enum ImageFormatKind: Equatable {
        case png, jpeg, webp, gif, tiff, heic, bmp, other
    }

    struct ImageInput {
        let image: NSImage
        let data: Data
        let dataType: NSPasteboard.PasteboardType
        let sourceURL: URL?
    }

    struct ImageCandidate {
        let data: Data
        let image: NSImage
        let dataType: NSPasteboard.PasteboardType
        let label: String
    }

    private static let inputCacheLock = NSLock()
    private static var cachedInput: (id: UUID, input: ImageInput)?

    static func imageInput(for item: ClipboardItem) -> ImageInput? {
        inputCacheLock.lock()
        if let cached = cachedInput, cached.id == item.id {
            let hit = cached.input
            inputCacheLock.unlock()
            return hit
        }
        inputCacheLock.unlock()

        guard let input = decodeImageInput(for: item) else { return nil }
        inputCacheLock.lock()
        cachedInput = (item.id, input)
        inputCacheLock.unlock()
        return input
    }

    private static func decodeImageInput(for item: ClipboardItem) -> ImageInput? {
        switch item.content {
        case .image(let image, let data, let dataType) where !dataType.rawValue.contains("pdf"):
            return ImageInput(image: NSImage(data: data) ?? image, data: data, dataType: dataType, sourceURL: nil)
        case .file(let url) where FileKindDetector.isImageFile(url):
            guard let data = try? Data(contentsOf: url),
                  let image = decodeImage(from: data) else { return nil }
            return ImageInput(image: image, data: data, dataType: pasteboardType(for: url), sourceURL: url)
        case .files(let urls) where urls.count == 1 && FileKindDetector.isImageFile(urls[0]):
            guard let data = try? Data(contentsOf: urls[0]),
                  let image = decodeImage(from: data) else { return nil }
            return ImageInput(image: image, data: data, dataType: pasteboardType(for: urls[0]), sourceURL: urls[0])
        default:
            return nil
        }
    }

    private static func decodeImage(from data: Data) -> NSImage? {
        if let img = NSImage(data: data) { return img }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func isAnimatedGIF(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              (type as String) == (UTType.gif.identifier) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    /// True for a multi-page TIFF. Our encode pipeline draws a single CGImage,
    /// so re-encoding one would silently drop every page but the first — the
    /// same fidelity loss `isAnimatedGIF` guards against for GIFs.
    static func isMultiPageTIFF(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src),
              (type as String) == (UTType.tiff.identifier) else { return false }
        return CGImageSourceGetCount(src) > 1
    }

    static func formatKind(for input: ImageInput) -> ImageFormatKind {
        if let url = input.sourceURL {
            switch url.pathExtension.lowercased() {
            case "png": return .png
            case "jpg", "jpeg": return .jpeg
            case "webp": return .webp
            case "gif": return .gif
            case "tif", "tiff": return .tiff
            case "heic": return .heic
            default: break
            }
        }
        let raw = input.dataType.rawValue.lowercased()
        if raw.contains("png") { return .png }
        if raw.contains("jpeg") || raw.contains("jpg") { return .jpeg }
        if raw.contains("webp") { return .webp }
        if raw.contains("gif") { return .gif }
        if raw.contains("tiff") { return .tiff }
        if raw.contains("heic") { return .heic }
        if raw.contains("bmp") || raw.contains("microsoft.bmp") { return .bmp }
        return .other
    }

    static func formatLabel(for kind: ImageFormatKind) -> String {
        switch kind {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .webp: return "WebP"
        case .gif: return "GIF"
        case .tiff: return "TIFF"
        case .heic: return "HEIC"
        case .bmp: return "BMP"
        case .other: return "image"
        }
    }

    static func infoText(for input: ImageInput) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(input.data.count), countStyle: .file)
        let dimensions = "\(Int(input.image.size.width))×\(Int(input.image.size.height))"
        var lines = [
            "Type: \(input.dataType.rawValue)",
            "Format: \(formatLabel(for: formatKind(for: input)))",
            "Dimensions: \(dimensions)",
            "Size: \(size)"
        ]
        if let url = input.sourceURL {
            lines.insert("Name: \(url.lastPathComponent)", at: 0)
            lines.append("Path: \(url.path)")
        }
        return lines.joined(separator: "\n")
    }

    static func reducedCopy(from item: ClipboardItem) async -> TransformOutput? {
        guard let input = imageInput(for: item) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let originalBytes = input.data.count
                let kind = formatKind(for: input)
                let targetType = pasteboardType(for: kind, fallback: input.dataType)

                if kind == .gif, isAnimatedGIF(input.data) {
                    continuation.resume(returning: .item(
                        ClipboardItem(content: ClipboardContent.imageContent(rawData: input.data, dataType: input.dataType, fallback: input.image)!),
                        message: "Animated GIF kept as-is — reducing would drop the animation."
                    ))
                    return
                }

                if kind == .tiff, isMultiPageTIFF(input.data) {
                    continuation.resume(returning: .item(
                        ClipboardItem(content: ClipboardContent.imageContent(rawData: input.data, dataType: input.dataType, fallback: input.image)!),
                        message: "Multi-page TIFF kept as-is — reducing would drop pages."
                    ))
                    return
                }

                var best: ImageCandidate?

                func consider(_ data: Data, image: NSImage, label: String) {
                    guard data.count < originalBytes else { return }
                    guard best == nil || data.count < best!.data.count else { return }
                    best = ImageCandidate(data: data, image: image, dataType: targetType, label: label)
                }

                // Each encode attempt allocates a full-resolution RGBA buffer
                // (rgbaCGImage) plus an autoreleased NSBitmapImageRep. Draining
                // per iteration keeps a big image from stacking several of them
                // before the surrounding queue block's pool would.
                switch kind {
                case .jpeg:
                    for (q, label) in [(CGFloat(0.82), "JPEG 82%"), (CGFloat(0.70), "JPEG 70%"), (CGFloat(0.58), "JPEG 58%")] {
                        autoreleasepool {
                            if let (data, img) = encodeJPEG(image: input.image, quality: q) {
                                consider(data, image: img, label: label)
                            }
                        }
                    }
                case .png:
                    if let (data, img) = encodePNG(image: input.image) {
                        consider(data, image: img, label: "PNG re-encoded")
                    }
                case .webp:
                    let encoder = WebPEncoder()
                    for (q, label) in [(Float(80), "WebP 80%"), (Float(70), "WebP 70%"), (Float(60), "WebP 60%")] {
                        autoreleasepool {
                            if let data = encodeWebP(image: input.image, quality: q, encoder: encoder),
                               let img = decodeWebP(data: data) {
                                consider(data, image: img, label: label)
                            }
                        }
                    }
                case .heic:
                    for (q, label) in [(CGFloat(0.85), "HEIC 85%"), (CGFloat(0.70), "HEIC 70%")] {
                        autoreleasepool {
                            if let (data, img) = encodeHEIC(image: input.image, quality: q) {
                                consider(data, image: img, label: label)
                            }
                        }
                    }
                case .gif:
                    if let (data, img) = encodeGIF(image: input.image) {
                        consider(data, image: img, label: "GIF re-encoded")
                    }
                case .tiff:
                    if let (data, img) = encodeTIFF(image: input.image) {
                        consider(data, image: img, label: "TIFF LZW")
                    }
                case .bmp:
                    if let (data, img) = encodeBMP(image: input.image) {
                        consider(data, image: img, label: "BMP re-encoded")
                    }
                case .other:
                    break
                }

                if best == nil {
                    for (scale, scaleLabel) in [(CGFloat(0.9), "90%"), (CGFloat(0.8), "80%"), (CGFloat(0.7), "70%")] {
                      autoreleasepool {
                        guard let scaled = scaledCopy(of: input.image, factor: scale) else { return }
                        switch kind {
                        case .jpeg:
                            if let (data, img) = encodeJPEG(image: scaled, quality: 0.75) {
                                consider(data, image: img, label: "\(scaleLabel) size, JPEG 75%")
                            }
                        case .png:
                            if let (data, img) = encodePNG(image: scaled) {
                                consider(data, image: img, label: "\(scaleLabel) size, PNG")
                            }
                        case .webp:
                            let encoder = WebPEncoder()
                            if let data = encodeWebP(image: scaled, quality: 70, encoder: encoder),
                               let img = decodeWebP(data: data) {
                                consider(data, image: img, label: "\(scaleLabel) size, WebP 70%")
                            }
                        case .heic:
                            if let (data, img) = encodeHEIC(image: scaled, quality: 0.75) {
                                consider(data, image: img, label: "\(scaleLabel) size, HEIC 75%")
                            }
                        case .gif:
                            if let (data, img) = encodeGIF(image: scaled) {
                                consider(data, image: img, label: "\(scaleLabel) size, GIF")
                            }
                        case .tiff:
                            if let (data, img) = encodeTIFF(image: scaled) {
                                consider(data, image: img, label: "\(scaleLabel) size, TIFF")
                            }
                        case .bmp:
                            if let (data, img) = encodeBMP(image: scaled) {
                                consider(data, image: img, label: "\(scaleLabel) size, BMP")
                            }
                        default:
                            break
                        }
                      }
                    }
                }

                guard let winner = best else {
                    continuation.resume(returning: .item(
                        ClipboardItem(content: ClipboardContent.imageContent(rawData: input.data, dataType: input.dataType, fallback: input.image)!),
                        message: "Image is already optimized. Pasted original (\(formatLabel(for: kind)))."
                    ))
                    return
                }

                let before = ByteCountFormatter.string(fromByteCount: Int64(originalBytes), countStyle: .file)
                let after = ByteCountFormatter.string(fromByteCount: Int64(winner.data.count), countStyle: .file)
                continuation.resume(returning: .item(
                    ClipboardItem(content: ClipboardContent.imageContent(rawData: winner.data, dataType: winner.dataType, fallback: winner.image)!),
                    message: "Reduced \(formatLabel(for: kind)): \(before) → \(after) (\(winner.label))"
                ))
            }
        }
    }

    static func persistExportFile(
        data: Data,
        dataType: NSPasteboard.PasteboardType,
        baseName: String?
    ) -> String? {
        let ext = pathExtension(for: dataType)
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stem = sanitizedFileStem(baseName ?? "Converted Image")
        var candidate = directory.appendingPathComponent("\(stem).\(ext)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) \(suffix).\(ext)")
            suffix += 1
        }
        do {
            try data.write(to: candidate, options: .atomic)
            return candidate.lastPathComponent
        } catch {
            return nil
        }
    }

    static func shouldWriteExportFile(transformed: ClipboardItem, source: ClipboardItem) -> Bool {
        guard case .image(_, _, let newType) = transformed.content else { return false }
        switch source.content {
        case .file, .files:
            return true
        case .image(_, _, let oldType):
            return formatKind(forPasteboardType: oldType) != formatKind(forPasteboardType: newType)
        default:
            return true
        }
    }

    static func formatKind(forPasteboardType type: NSPasteboard.PasteboardType) -> ImageFormatKind {
        formatKindFromExtension(pathExtension(for: type))
    }

    static func exportFileURL(fileName: String) -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clipen/Converted/\(fileName)", isDirectory: false)
    }

    static func pasteboardTypes(for item: ClipboardItem) -> [NSPasteboard.PasteboardType] {
        guard case .image(_, let rawData, let dataType) = item.content else { return [] }
        var types = [dataType]
        if let compat = compatibilityPasteboardPayload(
            image: NSImage(data: rawData) ?? NSImage(),
            rawData: rawData,
            dataType: dataType
        ), !types.contains(compat.type) {
            types.append(compat.type)
        }
        if shouldAttachTiffFallback(for: dataType) {
            types.append(.tiff)
        }
        return types
    }

    private static func pathExtension(for dataType: NSPasteboard.PasteboardType) -> String {
        let raw = dataType.rawValue.lowercased()
        if raw.contains("png") { return "png" }
        if raw.contains("jpeg") || raw.contains("jpg") { return "jpg" }
        if raw.contains("webp") { return "webp" }
        if raw.contains("gif") { return "gif" }
        if raw.contains("tiff") { return "tiff" }
        if raw.contains("heic") { return "heic" }
        if raw.contains("bmp") { return "bmp" }
        return "img"
    }

    private static func sanitizedFileStem(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Converted Image" }
        let safe = trimmed.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                return Character(scalar)
            }
            return "_"
        }
        let result = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "._"))
        return result.isEmpty ? "Converted Image" : String(result.prefix(80))
    }

    static func compatibilityPasteboardPayload(
        image: NSImage,
        rawData: Data,
        dataType: NSPasteboard.PasteboardType
    ) -> (data: Data, type: NSPasteboard.PasteboardType)? {
        if dataType == webpPasteboardType, let cg = decodeCGImage(from: rawData) {
            if !cgHasAlpha(cg), let jpeg = jpegData(from: cg, quality: 0.82) {
                return (jpeg, .init("public.jpeg"))
            }
            if let png = pngData(from: cg) { return (png, .init("public.png")) }
            return nil
        }
        if dataType.rawValue == "public.jpeg" { return (rawData, .init("public.jpeg")) }
        if dataType.rawValue == "public.png" { return (rawData, .init("public.png")) }
        if dataType.rawValue == "public.gif" { return (rawData, .init("public.gif")) }
        if dataType.rawValue == "public.heic" { return (rawData, .init("public.heic")) }
        if dataType == .tiff { return (rawData, .tiff) }
        if dataType.rawValue.contains("bmp") { return (rawData, dataType) }
        if let cg = decodeCGImage(from: rawData), let png = pngData(from: cg) {
            return (png, .init("public.png"))
        }
        if let png = image.pngData() { return (png, .init("public.png")) }
        return nil
    }

    static func shouldAttachTiffFallback(for dataType: NSPasteboard.PasteboardType) -> Bool {
        let raw = dataType.rawValue.lowercased()
        let known = ["webp", "jpeg", "jpg", "png", "gif", "heic", "bmp", "tiff"]
        return !known.contains(where: { raw.contains($0) })
    }

    private static func encodeWebP(
        image: NSImage,
        quality: Float,
        encoder: WebPEncoder,
        width: Int = 0,
        height: Int = 0
    ) -> Data? {
        let (pixelWidth, pixelHeight) = pixelDimensions(of: image)
        guard let cgImage = rgbaCGImage(from: image, pixelWidth: pixelWidth, pixelHeight: pixelHeight) else {
            return nil
        }
        return try? encoder.encode(
            RGBA: cgImage,
            config: .preset(.picture, quality: quality),
            resizeWidth: width,
            resizeHeight: height
        )
    }

    private static func encodePNG(image: NSImage) -> (Data, NSImage)? {
        let (pw, ph) = pixelDimensions(of: image)
        guard let cg = rgbaCGImage(from: image, pixelWidth: pw, pixelHeight: ph),
              let data = pngData(from: cg),
              let out = NSImage(data: data) else { return nil }
        return (data, out)
    }

    private static func encodeJPEG(image: NSImage, quality: CGFloat) -> (Data, NSImage)? {
        let (pw, ph) = pixelDimensions(of: image)
        guard let cg = rgbaCGImage(from: image, pixelWidth: pw, pixelHeight: ph),
              let data = jpegData(from: cg, quality: quality),
              let out = NSImage(data: data) else { return nil }
        return (data, out)
    }

    private static func encodeGIF(image: NSImage) -> (Data, NSImage)? {
        encodedBitmap(image: image, fileType: .gif, properties: [:])
    }

    private static func encodeTIFF(image: NSImage) -> (Data, NSImage)? {
        encodedBitmap(
            image: image,
            fileType: .tiff,
            properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw]
        )
    }

    private static func encodeHEIC(image: NSImage, quality: CGFloat) -> (Data, NSImage)? {
        let (pw, ph) = pixelDimensions(of: image)
        guard let cg = rgbaCGImage(from: image, pixelWidth: pw, pixelHeight: ph),
              let data = heicData(from: cg, quality: quality),
              let out = NSImage(data: data) else { return nil }
        return (data, out)
    }

    private static func encodeBMP(image: NSImage) -> (Data, NSImage)? {
        encodedBitmap(image: image, fileType: .bmp, properties: [:])
    }

    private static func encodedBitmap(
        image: NSImage,
        fileType: NSBitmapImageRep.FileType,
        properties: [NSBitmapImageRep.PropertyKey: Any]
    ) -> (Data, NSImage)? {
        let (pw, ph) = pixelDimensions(of: image)
        guard let cg = rgbaCGImage(from: image, pixelWidth: pw, pixelHeight: ph),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: fileType, properties: properties),
              let out = NSImage(data: data) else { return nil }
        return (data, out)
    }

    private static func heicData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func decodeWebP(data: Data) -> NSImage? {
        guard let cg = decodeCGImage(from: data) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func decodeCGImage(from data: Data) -> CGImage? {
        try? WebPDecoder().decode(data, options: WebpDecoderOptions())
    }

    private static func pngData(from cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private static func cgHasAlpha(_ cg: CGImage) -> Bool {
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func rgbaCGImage(from image: NSImage, pixelWidth: Int, pixelHeight: Int) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let dest = CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)

        if let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            context.draw(source, in: dest)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: dest, from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()
        }

        return context.makeImage()
    }

    private static func pixelDimensions(of image: NSImage) -> (Int, Int) {
        if let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first,
           rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        var proposed = CGRect(origin: .zero, size: image.size)
        if let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) {
            return (cg.width, cg.height)
        }
        return (max(1, Int(image.size.width.rounded())), max(1, Int(image.size.height.rounded())))
    }

    private static func scaledCopy(of image: NSImage, factor: CGFloat) -> NSImage? {
        guard factor > 0, factor < 1 else { return nil }
        // Was NSImage.lockFocus, which is not safe off the main thread — and
        // reducedCopy calls this from a background queue. rgbaCGImage draws
        // the source into an explicit CGContext at the target pixel size
        // (high interpolation), the same thread-agnostic path stitch and the
        // encoders already use, so scaling no longer touches AppKit's
        // main-thread graphics state.
        let (pw, ph) = pixelDimensions(of: image)
        let tw = max(1, Int((CGFloat(pw) * factor).rounded()))
        let th = max(1, Int((CGFloat(ph) * factor).rounded()))
        guard let cg = rgbaCGImage(from: image, pixelWidth: tw, pixelHeight: th) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: tw, height: th))
    }

    private static func pasteboardType(for url: URL) -> NSPasteboard.PasteboardType {
        pasteboardType(for: formatKindFromExtension(url.pathExtension), fallback: .init("public.image"))
    }

    private static func pasteboardType(for kind: ImageFormatKind, fallback: NSPasteboard.PasteboardType) -> NSPasteboard.PasteboardType {
        switch kind {
        case .png: return .init("public.png")
        case .jpeg: return .init("public.jpeg")
        case .webp: return webpPasteboardType
        case .gif: return .init("public.gif")
        case .tiff: return .tiff
        case .heic: return .init("public.heic")
        case .bmp: return .init("com.microsoft.bmp")
        case .other: return fallback
        }
    }

    private static func formatKindFromExtension(_ ext: String) -> ImageFormatKind {
        switch ext.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        case "webp": return .webp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        case "heic": return .heic
        case "bmp": return .bmp
        default: return .other
        }
    }
}
