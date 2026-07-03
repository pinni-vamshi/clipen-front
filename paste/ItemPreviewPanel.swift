import AppKit
import AVKit
import ModelIO
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit

final class ItemPreviewPanel: NSPanel {
    private var hostingView: NSHostingView<AnyView>?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func show(for item: ClipboardItem, near popupFrame: NSRect) {
        let view = AnyView(ItemPreviewView(item: item))
        if let hostingView {
            hostingView.rootView = view
        } else {
            let hostingView = NSHostingView(rootView: view)
            contentView = hostingView
            self.hostingView = hostingView
        }

        let w: CGFloat = 520
        let h: CGFloat = 420
        let screen = NSScreen.main?.visibleFrame ?? .zero
        var x = popupFrame.maxX + 10
        if x + w > screen.maxX { x = popupFrame.minX - w - 10 }
        x = max(screen.minX + 10, x)
        // Align preview's top edge to popup's top edge (instead of vertical centering)
        // so content starts from a stable top position while cycling items.
        let y = max(screen.minY + 10, min(popupFrame.maxY - h, screen.maxY - h - 10))

        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        if !isVisible { orderFront(nil) }
    }

    func hide() {
        // Reset the SwiftUI tree first so AVPlayer / QLPreviewView get dismantled
        // (and stop playing) before the panel disappears.
        hostingView?.rootView = AnyView(EmptyView())
        orderOut(nil)
    }
}

private struct ItemPreviewView: View {
    let item: ClipboardItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    ItemTagStrip(tags: item.tags, maxVisible: 5, compact: false)
                    if let metadata = item.metadataSummary {
                        Text(metadata)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text("Space to close")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        }
        .background(SystemPopoverMaterial())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 10)
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .text(let text):
            if let url = Self.validWebURL(text) {
                WebsitePreview(url: url)
            } else {
                textPreview(text, monospaced: true)
            }
        case .richText(let attrStr, _):
            AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
        case .html(let html, let plain):
            if ClipboardManager.htmlContainsTable(html) {
                HTMLStringPreview(html: html)
            } else {
                textPreview(plain, monospaced: false)
            }
        case .rtfd(let data, let plain):
            if let attrStr = NSAttributedString(rtfd: data, documentAttributes: nil) {
                AttributedTextPreview(attributedString: attrStr.adjustingColorsForCurrentAppearance())
            } else {
                textPreview(plain, monospaced: false)
            }
        case .image(let image, let data, let dataType):
            if dataType.rawValue.contains("pdf"), let pdf = PDFDocument(data: data) {
                PDFPreview(document: pdf)
            } else if dataType.rawValue.contains("gif") {
                AnimatedImageView(data: data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else {
                imagePreview(image)
            }
        case .file(let url):
            filePreview(url)
        case .files(let urls):
            fileListPreview(urls)
        case .svg(let src):
            textPreview(src, monospaced: true)
        case .blob(let typeMap):
            textPreview(typeMap.keys.sorted().map { "· \($0)" }.joined(separator: "\n"),
                        monospaced: true)
        }
    }

    private static func validWebURL(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.contains("\n"), !t.contains("\r"),
              let url = URL(string: t),
              url.scheme == "http" || url.scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    private func textPreview(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func imagePreview(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func filePreview(_ url: URL) -> some View {
        if url.pathExtension.lowercased() == "pdf", let pdf = PDFDocument(url: url) {
            PDFPreview(document: pdf)
        } else if url.pathExtension.lowercased() == "gif", let data = try? Data(contentsOf: url) {
            AnimatedImageView(data: data)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if let image = NSImage(contentsOf: url) {
            imagePreview(image)
        } else if FileKindDetector.isHTMLFile(url) {
            HTMLFilePreview(url: url)
        } else if let text = FileKindDetector.readableText(from: url) {
            textPreview(text, monospaced: true)
        } else if FileKindDetector.isMediaFile(url) {
            AVMediaPreview(url: url)
        } else if FileKindDetector.is3DModelFile(url) {
            Model3DPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        } else if FileManager.default.fileExists(atPath: url.path) {
            QuickLookFilePreview(url: url)
        } else if let docText = FileKindDetector.readableDocumentText(from: url) {
            // Fallback when the file isn't on disk (e.g. evicted snapshot) but we
            // cached extractable text from a document (docx, pptx, pages…).
            textPreview(docText, monospaced: false)
        } else {
            VStack(spacing: 12) {
                Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                    .resizable()
                    .frame(width: 72, height: 72)
                Text(url.lastPathComponent)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileListPreview(_ urls: [URL]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(urls, id: \.path) { url in
                    HStack(spacing: 10) {
                        Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                            .resizable()
                            .frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Text(url.deletingLastPathComponent().path)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

/// Renders a 3D model as a rotatable/zoomable scene. SceneKit loads .scn/.usd*
/// natively; everything else (.obj/.stl/.fbx/.gltf/.dae/.ply/.abc/.glb) is
/// bridged in through Model I/O's MDLAsset → SCNScene importer. Falls back to a
/// label if a format can't be decoded on this OS.
struct Model3DPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true      // drag to rotate, scroll to zoom
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = Self.loadScene(url)
        // The preview panel is non-activating (never key), so mouse-drag rotation
        // can't reach SceneKit. Auto-spin the whole scene so the model is seen
        // from all sides without interaction. Drag still works in any window that
        // CAN become key (e.g. if the model is opened in the main window).
        Self.startAutoRotation(in: view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        view.scene = Self.loadScene(url)
        Self.startAutoRotation(in: view)
    }

    /// Wrap the model in a pivot node and spin it slowly around Y. Idempotent —
    /// re-running on the same scene won't stack multiple rotations.
    private static func startAutoRotation(in view: SCNView) {
        guard let scene = view.scene else { return }
        let pivotName = "clipenAutoSpin"
        if scene.rootNode.childNode(withName: pivotName, recursively: false) != nil { return }
        let pivot = SCNNode()
        pivot.name = pivotName
        // Re-parent all existing top-level content under the spinning pivot.
        for child in scene.rootNode.childNodes where child.name != pivotName {
            child.removeFromParentNode()
            pivot.addChildNode(child)
        }
        scene.rootNode.addChildNode(pivot)
        let spin = SCNAction.repeatForever(
            .rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 8))
        pivot.runAction(spin)
    }

    private static func loadScene(_ url: URL) -> SCNScene {
        // Native path: SceneKit reads .scn and USD variants directly.
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            return scene
        }
        // Bridge path: Model I/O imports OBJ/STL/PLY/DAE/Alembic, etc.
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        return scene
    }
}

/// Plays animated GIFs. SwiftUI's `Image` is static and shows only the first
/// frame; `NSImageView` with `animates = true` runs the GIF's frame loop.
struct AnimatedImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(data: data)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.image = NSImage(data: data)
        view.animates = true
    }
}

private struct HTMLFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url != url { load(url, in: view) }
    }

    private func load(_ url: URL, in view: WKWebView) {
        if url.pathExtension.lowercased() == "webarchive" {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
    }
}

private struct AVMediaPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        view.player = player
        // Auto-play as soon as the preview opens.
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Only swap the player when the URL actually changes to avoid restarting.
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        // Called when the panel is hidden — stop playback immediately.
        view.player?.pause()
        view.player = nil
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true   // Auto-play audio/video inside QuickLook previews.
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        // Clear the preview item when the panel is hidden so QL stops any playback.
        view.previewItem = nil
    }
}

private struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

struct HTMLStringPreview: NSViewRepresentable {
    final class Coordinator {
        var lastHTML: String?
    }

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground") // Make background transparent
        loadHTML(view)
        context.coordinator.lastHTML = html
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.lastHTML != html else { return }
        loadHTML(view)
        context.coordinator.lastHTML = html
    }

    private func loadHTML(_ view: WKWebView) {
        let styledHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            :root {
                color-scheme: light dark;
            }
            body {
                font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
                font-size: 13px;
                margin: 0;
                padding: 8px;
                background-color: transparent;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                margin-top: 8px;
                margin-bottom: 12px;
            }
            th, td {
                border: 1px solid rgba(128, 128, 128, 0.3);
                padding: 6px 8px;
                text-align: left;
            }
            th {
                background-color: rgba(128, 128, 128, 0.1);
                font-weight: 600;
            }
        </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
        view.loadHTMLString(styledHTML, baseURL: nil)
    }
}

struct AttributedTextPreview: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.importsGraphics = true // For RTFD graphics
        textView.allowsUndo = false
        textView.textStorage?.setAttributedString(attributedString)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.textStorage?.string != attributedString.string {
            textView.textStorage?.setAttributedString(attributedString)
        }
    }
}

// MARK: - Live website preview (shared with QuickClipPanel)

struct WebsitePreview: NSViewRepresentable {
    let url: URL

    final class Coordinator: NSObject, WKNavigationDelegate {
        var progressView: NSProgressIndicator?

        func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
            progressView?.startAnimation(nil)
        }
        func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
            progressView?.stopAnimation(nil)
            progressView?.isHidden = true
        }
        func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
            progressView?.stopAnimation(nil)
            progressView?.isHidden = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        progress.startAnimation(nil)
        context.coordinator.progressView = progress

        webView.load(URLRequest(url: url, timeoutInterval: 10))
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let webView = container.subviews.first(where: { $0 is WKWebView }) as? WKWebView,
              (webView.url?.absoluteString ?? "") != url.absoluteString else { return }
        webView.load(URLRequest(url: url, timeoutInterval: 10))
    }
}

extension NSAttributedString {
    func adjustingColorsForCurrentAppearance() -> NSAttributedString {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let mutable = NSMutableAttributedString(attributedString: self)

        mutable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: mutable.length), options: []) { value, range, _ in
            if let color = value as? NSColor {
                if let rgbColor = color.usingColorSpace(.deviceRGB) {
                    let r = rgbColor.redComponent
                    let g = rgbColor.greenComponent
                    let b = rgbColor.blueComponent
                    let luminance = 0.299 * r + 0.587 * g + 0.114 * b

                    if isDarkMode && luminance < 0.25 {
                        mutable.addAttribute(.foregroundColor, value: NSColor.white, range: range)
                    } else if !isDarkMode && luminance > 0.85 {
                        mutable.addAttribute(.foregroundColor, value: NSColor.textColor, range: range)
                    }
                }
            }
        }
        return mutable
    }
}
