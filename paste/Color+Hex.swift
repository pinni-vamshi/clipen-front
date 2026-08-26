import SwiftUI
import ImageIO
import os

enum ClipenSignpost {
    static let signposter = OSSignposter(subsystem: "com.clipen.app",
                                         category: .pointsOfInterest)

    @inline(__always)
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var val: UInt64 = 0
        Scanner(string: h).scanHexInt64(&val)
        self.init(
            red:   Double((val >> 16) & 0xFF) / 255,
            green: Double((val >> 8)  & 0xFF) / 255,
            blue:  Double( val        & 0xFF) / 255
        )
    }

    init(light: String, dark: String) {
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        }
        self.init(dynamic)
    }
}

struct SystemPopoverMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

final class ItemThumbnailCache {
    static let shared = ItemThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() {
        cache.countLimit = 300
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    private static func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    func thumbnail(forData data: Data, key: String, maxPixel: CGFloat = 360) -> NSImage? {
        let k = "data:\(key)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = Self.makeThumb(src, maxPixel) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: k, cost: Self.cost(img))
        return img
    }

    func cachedFileThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: "file:\(url.path)" as NSString)
    }

    func storeFileThumbnail(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: "file:\(url.path)" as NSString, cost: Self.cost(image))
    }

    func cachedDataThumbnail(key: String) -> NSImage? {
        cache.object(forKey: "data:\(key)" as NSString)
    }

    func storeDataThumbnail(_ image: NSImage, key: String) {
        cache.setObject(image, forKey: "data:\(key)" as NSString, cost: Self.cost(image))
    }

    nonisolated static func decodeDataThumbnail(data: Data, maxPixel: CGFloat = 360) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = makeThumb(src, maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func decodeFileThumbnail(url: URL, maxPixel: CGFloat = 360) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg  = makeThumb(src, maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func makeThumb(_ src: CGImageSource, _ maxPixel: CGFloat) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// Shrinks an already-decoded image by drawing, never by re-invoking
    /// ImageIO on compressed bytes. Use this whenever a smaller size is
    /// needed from an image the app already has in memory — it is the
    /// difference between a sub-millisecond CGContext draw and, measured
    /// directly against a screenshot-sized RGBA PNG (the ⌘⇧4-then-Space
    /// window capture, with its soft drop-shadow alpha), a ~220ms ImageIO
    /// thumbnail decode. Capture used to pay that decode twice — once to
    /// build the 1024px row/preview image, again moments later in
    /// prewarmPreviewCaches to build the 360px cache entry, both from the
    /// same source bytes — which is exactly the redundant CPU spike that
    /// showed up as a jerky selection-highlight animation on screenshots
    /// specifically (their alpha channel makes the ImageIO decode far
    /// slower than an opaque JPEG/PNG of the same pixel size) and not on
    /// ordinary images.
    nonisolated static func resizedThumbnail(from image: NSImage, maxPixel: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        guard max(w, h) > maxPixel else { return image }   // already small enough
        let scale = maxPixel / max(w, h)
        let outW = max(1, Int(w * scale)), outH = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let outCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: outW, height: outH))
    }
}

struct CachedFileThumbnail: View {
    let url:  URL
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
            }
        }
        .task(id: url) {
            if let hit = ItemThumbnailCache.shared.cachedFileThumbnail(for: url) {
                image = hit
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                ItemThumbnailCache.decodeFileThumbnail(url: url)
            }.value
            if let decoded {
                ItemThumbnailCache.shared.storeFileThumbnail(decoded, for: url)
                image = decoded
            }
        }
    }
}

struct CachedDataThumbnail: View {
    let data: Data
    let key:  String
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: size, height: size)
            }
        }
        .task(id: key) {
            if let hit = ItemThumbnailCache.shared.cachedDataThumbnail(key: key) {
                image = hit
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                ItemThumbnailCache.decodeDataThumbnail(data: data)
            }.value
            if let decoded {
                ItemThumbnailCache.shared.storeDataThumbnail(decoded, key: key)
                image = decoded
            }
        }
    }
}

final class ClipenIconCache {
    static let shared = ClipenIconCache()

    private let fileIcons = NSCache<NSString, NSImage>()
    private let appIcons = NSCache<NSString, NSImage>()

    private init() {
        fileIcons.countLimit = 512
        fileIcons.totalCostLimit = 32 * 1024 * 1024
        appIcons.countLimit = 128
        appIcons.totalCostLimit = 16 * 1024 * 1024
    }

    func fileIcon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = fileIcons.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        fileIcons.setObject(icon, forKey: key)
        return icon
    }

    func appIcon(forBundleID bundleID: String) -> NSImage? {
        let key = bundleID as NSString
        if let cached = appIcons.object(forKey: key) { return cached }
        guard let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        appIcons.setObject(icon, forKey: key)
        return icon
    }
}
