import SwiftUI
import ImageIO
import os

/// Latency instrumentation for Clipen's real-time interaction pipeline.
///
/// Uses `OSSignposter`, which is effectively free when no Instruments trace is
/// attached: `signpostsEnabled` short-circuits before any work, so these calls
/// stay compiled into release builds (that's the point — a shipped build can be
/// profiled on real hardware) without a measurable cost on the keystroke path.
///
/// Inspect in Instruments → **Points of Interest**, alongside **Time Profiler**,
/// **SwiftUI**, **Core Animation**, **Allocations**, and **Leaks**. The markers
/// let you measure, on device, the interaction pipeline:
///   `v.keydown` → `selection.target` → `popup.show` → `preview.request`
/// i.e. CGEvent V keydown → selection mutation → popover on screen → preview.
enum ClipenSignpost {
    static let signposter = OSSignposter(subsystem: "com.clipen.app",
                                         category: .pointsOfInterest)

    /// One-shot marker (no duration) — cheap enough for the keystroke path.
    /// `emitEvent` with a `StaticString` does no argument formatting and the
    /// signposting machinery no-ops when no trace is attached, so this stays in
    /// release builds without a measurable cost.
    @inline(__always)
    static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }
}

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
    private init() {
        cache.countLimit = 300
        // Bound by decoded BYTES too, not just count. A 360px thumbnail is
        // ~360·360·4 ≈ 0.5 MB, so 300 of them could pin ~150 MB resident with
        // no cost ceiling. Cap total decoded thumbnail memory at ~96 MB; NSCache
        // evicts the least-recently-used entries once either limit is hit.
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    /// Estimated decoded footprint of a thumbnail, for NSCache cost accounting.
    private static func cost(_ image: NSImage) -> Int {
        guard let rep = image.representations.first else { return 0 }
        return max(1, rep.pixelsWide * rep.pixelsHigh * 4)
    }

    /// Thumbnail for an in-memory clipboard image, keyed by the item's ID.
    /// Synchronous — CGImageSource thumbnailing is a few ms, paid once per
    /// item, and every later row render is a cache hit.
    func thumbnail(forData data: Data, key: String, maxPixel: CGFloat = 360) -> NSImage? {
        let k = "data:\(key)" as NSString
        if let hit = cache.object(forKey: k) { return hit }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = Self.makeThumb(src, maxPixel) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: k, cost: Self.cost(img))
        return img
    }

    /// Cache-only lookup for a file thumbnail (no disk I/O) — lets rows show
    /// instantly on re-materialization without an async round-trip.
    func cachedFileThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: "file:\(url.path)" as NSString)
    }

    func storeFileThumbnail(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: "file:\(url.path)" as NSString, cost: Self.cost(image))
    }

    /// Cache-only lookup / store for an in-memory image's thumbnail — the
    /// async counterpart to `thumbnail(forData:)` so list rows can decode a
    /// pasted image OFF the main thread (a synchronous decode per image row
    /// on the first scroll-through is what made the list stutter).
    func cachedDataThumbnail(key: String) -> NSImage? {
        cache.object(forKey: "data:\(key)" as NSString)
    }

    func storeDataThumbnail(_ image: NSImage, key: String) {
        cache.setObject(image, forKey: "data:\(key)" as NSString, cost: Self.cost(image))
    }

    /// Pure decode of in-memory image data, safe on a background task.
    nonisolated static func decodeDataThumbnail(data: Data, maxPixel: CGFloat = 360) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg  = makeThumb(src, maxPixel) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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

/// Async, cached, downsampled thumbnail for an IN-MEMORY pasted image in list
/// rows — same pattern as `CachedFileThumbnail`, decoding off the main thread
/// so a fast scroll through image-heavy history never blocks on per-row
/// CGImageSource decodes. Cache hits show instantly.
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
