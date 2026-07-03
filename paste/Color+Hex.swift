import SwiftUI

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
