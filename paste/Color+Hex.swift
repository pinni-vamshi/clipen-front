import SwiftUI
import ImageIO

/// Convenience initializer for SwiftUI Color from a hex string like "#RRGGBB"
/// (the leading "#" is optional). Used across the app — defined once here so
/// it doesn't drift in 3 different file-private copies like it used to.
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

    /// A color that resolves to a different hex value depending on the
    /// CURRENT system/window appearance, resolved fresh at draw time via
    /// `NSColor`'s dynamic provider — not baked in once like plain
    /// `Color(hex:)`. This is what lets the design tokens below follow
    /// Dark Mode without the app forcing `.preferredColorScheme(.dark)`.
    init(light: String, dark: String) {
        let dynamic = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(Color(hex: isDark ? dark : light))
        }
        self.init(dynamic)
    }
}

/// Wraps the real macOS `NSVisualEffectView` with the same `.popover` material
/// system UI uses for things like Look Up / Quick Look info popovers — a
/// vibrant, blurred dark-glass panel, distinct from SwiftUI's generic
/// `.regularMaterial` (which just follows light/dark appearance).
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

/// Downsampled row thumbnails, generated once and cached. List rows were
/// handing FULL-RESOLUTION captures (retina screenshots are easily 3–6
/// megapixels) straight to SwiftUI `Image`, which re-scaled the whole bitmap
/// to a ~36–48pt row on every frame while scrolling — the main-window scroll
/// lag. CGImageSource thumbnailing decodes at most `maxPixel` on the long
/// edge, so rows composite a tiny bitmap instead.
final class ItemThumbnailCache {
    static let shared = ItemThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 300 }

    /// Thumbnail for an in-memory clipboard image, keyed by the item's ID.
    /// Synchronous — CGImageSource thumbnailing is a few ms, paid once per
    /// item, and every later row render is a cache hit.
    func thumbnail(forData data: Data, key: String, maxPixel: CGFloat = 360) -> NSImage? {
        let k = "data:\(key)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = Self.makeThumb(src, maxPixel) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: k)
        return img
    }

    /// Cache-only lookup for a file thumbnail (no disk I/O) — lets rows show
    /// instantly on re-materialization without an async round-trip.
    func cachedFileThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: "file:\(url.path)" as NSString)
    }

    func storeFileThumbnail(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: "file:\(url.path)" as NSString)
    }

    /// Pure decode, safe to run on a background task — touches no shared state.
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
}

/// Async, cached, downsampled thumbnail for image FILES in list rows.
/// Replaces two identical private structs (main window + popup) that each
/// re-read the full image from disk every time a lazy row re-materialized
/// during scrolling — no cache, no downsampling, duplicated code.
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

final class ClipenIconCache {
    static let shared = ClipenIconCache()

    private let fileIcons = NSCache<NSString, NSImage>()
    private let appIcons = NSCache<NSString, NSImage>()

    private init() {
        fileIcons.countLimit = 512
        appIcons.countLimit = 128
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
