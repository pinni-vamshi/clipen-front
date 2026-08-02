import AppKit
import AVKit
import Highlightr
import ModelIO
import NaturalLanguage
import Quartz
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import WebKit
@preconcurrency import PDFKit


struct AsyncDelimitedFilePreview: View {
    let url: URL
    @State private var rows: [[String]]?
    @State private var isTruncated = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let rows {
                VStack(alignment: .leading, spacing: 0) {
                    if isTruncated {
                        Text("Showing the first part of a large file")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                    }
                    StyledTablePreview(rows: rows)
                        .padding(10)
                }
            } else if loadFailed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            rows = nil
            isTruncated = false
            loadFailed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                FileKindDetector.readableTextPreview(from: url)
            }.value
            guard !Task.isCancelled else { return }
            guard let loaded else { loadFailed = true; return }
            let delimiter = DelimitedTableParser.detectDelimiter(loaded.text)
            rows = DelimitedTableParser.parse(loaded.text, delimiter: delimiter)
            isTruncated = loaded.isTruncated
        }
    }
}

struct AsyncTextFilePreview: View {
    let url: URL
    @State private var text: String?
    @State private var isTruncated = false
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let text {
                VStack(alignment: .leading, spacing: 0) {
                    if isTruncated {
                        Text("Showing the first part of a large file")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.primary.opacity(0.06))
                    }
                    if let lang = CodeLanguageDetector.languageForExtension(url.pathExtension) {
                        CodeSyntaxPreview(text: text, language: lang)
                            .padding(.top, isTruncated ? 8 : 0)
                    } else {
                        ScrollView {
                            Text(text)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, isTruncated ? 8 : 0)
                        }
                    }
                }
            } else if loadFailed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            text = nil
            isTruncated = false
            loadFailed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                FileKindDetector.readableTextPreview(from: url)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded {
                text = loaded.text
                isTruncated = loaded.isTruncated
            } else {
                loadFailed = true
            }
        }
    }
}

struct FilePreviewContent: View {
    let url: URL

    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var body: some View {
        Group {
            if isDirectory {
                FolderTreePreview(url: url)
            } else if url.pathExtension.lowercased() == "pdf" {
                AsyncPDFFilePreview(url: url)
            } else if url.pathExtension.lowercased() == "gif" {
                AsyncGIFFilePreview(url: url)
            // Known-not-an-image extensions MUST short-circuit before the
            // greedy `NSImage(contentsOf:)` probe below — that call reads the
            // WHOLE file on main to try image detection, which for a 50 MB
            // GLB / video / etc. is a 2-10 s beach-ball freeze before we ever
            // reach the correct branch.
            } else if FileKindDetector.isGLTFModelFile(url) {
                // glTF/GLB rendering (via GLTFKit2's shared concurrent loader
                // queue) was causing hangs and crashes in practice — removed
                // rather than left half-working. The file itself still
                // copies/pastes normally; it just doesn't render a preview.
                NoPreviewAvailableView(url: url)
            } else if FileKindDetector.is3DModelFile(url) {
                Model3DPreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if FileKindDetector.isMediaFile(url) {
                AVMediaPreview(url: url)
            } else if FileKindDetector.isHTMLFile(url) {
                HTMLFilePreview(url: url)
            } else if ["csv", "tsv"].contains(url.pathExtension.lowercased()) {
                AsyncDelimitedFilePreview(url: url)
            } else if FileKindDetector.isTextFile(url) {
                AsyncTextFilePreview(url: url)
            } else if FileKindDetector.isImageFile(url) {
                // Loads via NSImage on a background queue rather than the
                // main-thread NSImage(contentsOf:) below — a 20 MB HEIC used
                // to hitch main for 100-500 ms before the preview appeared.
                AsyncImageFilePreview(url: url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if let image = NSImage(contentsOf: url) {
                ZoomableImagePreview(image: image)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if FileManager.default.fileExists(atPath: url.path) {
                QuickLookFilePreview(url: url)
            } else if let docText = FileKindDetector.readableDocumentText(from: url) {
                ScrollView {
                    Text(docText)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
    }
}

/// Default empty state for a file whose type is recognized but has no
/// working preview renderer. The file itself is unaffected — this only
/// affects what shows in the preview panel.
struct NoPreviewAvailableView: View {
    let url: URL

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: ClipenIconCache.shared.fileIcon(for: url))
                .resizable()
                .frame(width: 72, height: 72)
            Text(url.lastPathComponent)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text("No preview available")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FolderTreePreview: View {
    let url: URL

    struct Entry: Identifiable {
        let id = UUID()
        let name: String
        let depth: Int
        let isDir: Bool
    }

    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var truncated = false

    private static let maxDepth = 5
    private static let maxEntries = 2000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13)).foregroundColor(.accentColor)
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                if !loading {
                    Text("\(entries.count)\(truncated ? "+" : "") items")
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 28, weight: .thin)).foregroundColor(.secondary)
                    Text("Empty folder").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { e in
                            HStack(spacing: 6) {
                                Image(systemName: e.isDir ? "folder.fill" : Self.icon(forFile: e.name))
                                    .font(.system(size: 11))
                                    .foregroundColor(e.isDir ? .accentColor : .secondary)
                                    .frame(width: 14)
                                Text(e.name)
                                    .font(.system(size: 12, weight: e.isDir ? .medium : .regular))
                                    .foregroundColor(e.isDir ? .primary : .primary.opacity(0.82))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.leading, CGFloat(e.depth) * 16)
                        }
                        if truncated {
                            Text("… more (truncated)")
                                .font(.system(size: 10)).foregroundColor(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                }
            }
        }
        .task(id: url) {
            loading = true
            let result = await Self.scan(url)
            entries = result.entries
            truncated = result.truncated
            loading = false
        }
    }

    private static func icon(forFile name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png","jpg","jpeg","gif","heic","webp","tiff","bmp": return "photo"
        case "pdf":                                               return "doc.richtext"
        case "mp4","mov","m4v","avi","mkv":                       return "film"
        case "mp3","wav","aac","m4a","flac":                      return "music.note"
        case "zip","tar","gz","dmg","7z":                         return "archivebox"
        case "swift","js","ts","py","rb","go","c","cpp","h","java","rs","sh": return "chevron.left.forwardslash.chevron.right"
        default:                                                  return "doc"
        }
    }

    private static func scan(_ root: URL) async -> (entries: [Entry], truncated: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var out: [Entry] = []
                var truncated = false
                let fm = FileManager.default

                func walk(_ dir: URL, depth: Int) {
                    guard depth < maxDepth else { return }
                    guard let items = try? fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]) else { return }
                    let sorted = items.sorted { a, b in
                        let ad = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        let bd = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        if ad != bd { return ad && !bd }
                        return a.lastPathComponent.localizedCaseInsensitiveCompare(b.lastPathComponent) == .orderedAscending
                    }
                    for item in sorted {
                        if out.count >= maxEntries { truncated = true; return }
                        let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                        out.append(Entry(name: item.lastPathComponent, depth: depth, isDir: isDir))
                        if isDir { walk(item, depth: depth + 1) }
                    }
                }
                walk(root, depth: 0)
                continuation.resume(returning: (out, truncated))
            }
        }
    }
}

struct Model3DPreview: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
        var loadToken: UUID?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SpinUntilTouchedSCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.scene = SCNScene() // placeholder until async load lands
        Self.loadSceneAsync(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        Self.loadSceneAsync(url, into: view, coordinator: context.coordinator)
    }

    /// Loads on a background queue and swaps in on the main thread. A UUID
    /// token guards against a stale load winning after the view was reused
    /// for a different URL.
    private static func loadSceneAsync(_ url: URL, into view: SCNView, coordinator: Coordinator) {
        let token = UUID()
        coordinator.loadToken = token
        coordinator.loadedURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let scene = loadScene(url)
            DispatchQueue.main.async { [weak view] in
                guard let view, coordinator.loadToken == token else { return }
                view.scene = scene
                startAutoRotation(in: view)
            }
        }
    }

    final class SpinUntilTouchedSCNView: SCNView {
        private func stopAutoSpin() {
            scene?.rootNode.childNode(withName: "clipenAutoSpin", recursively: false)?
                .removeAllActions()
        }
        override func mouseDown(with event: NSEvent) {
            stopAutoSpin()
            super.mouseDown(with: event)
        }
        override func scrollWheel(with event: NSEvent) {
            stopAutoSpin()
            super.scrollWheel(with: event)
        }
        override func magnify(with event: NSEvent) {
            stopAutoSpin()
            super.magnify(with: event)
        }
    }

    private static func startAutoRotation(in view: SCNView) {
        guard let scene = view.scene else { return }
        let pivotName = "clipenAutoSpin"
        if scene.rootNode.childNode(withName: pivotName, recursively: false) != nil { return }
        let pivot = SCNNode()
        pivot.name = pivotName
        for child in scene.rootNode.childNodes where child.name != pivotName {
            child.removeFromParentNode()
            pivot.addChildNode(child)
        }
        scene.rootNode.addChildNode(pivot)
        let spin = SCNAction.repeatForever(
            .rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 8))
        pivot.runAction(spin)
    }

    // Native SceneKit/ModelIO formats only — glTF/GLB never reach here
    // (routed to NoPreviewAvailableView instead; see FileKindDetector.isGLTFModelFile).
    private static func loadScene(_ url: URL) -> SCNScene {
        if let scene = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            return scene
        }
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let scene = SCNScene(mdlAsset: asset)
        return scene
    }
}

struct AnimatedImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(data: data)
        view.animates = true
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        context.coordinator.lastDataCount = data.count
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        guard context.coordinator.lastDataCount != data.count else { return }
        context.coordinator.lastDataCount = data.count
        view.image = NSImage(data: data)
        view.animates = true
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastDataCount: Int = -1
    }
}

private struct HTMLFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsMagnification = true
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
        player.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        let player = AVPlayer(url: url)
        view.player = player
        player.play()
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

private struct QuickLookFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        guard let view = QLPreviewView(frame: .zero, style: .normal) else {
            return QLPreviewView()
        }
        view.autostarts = true
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        view.previewItem = url as NSURL
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.previewItem = nil
    }
}

struct PDFPreview: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.minScaleFactor = view.scaleFactorForSizeToFit
        view.maxScaleFactor = 8
        view.document = document
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.minScaleFactor = view.scaleFactorForSizeToFit
        }
    }

    final class InteractivePDFView: PDFView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func magnify(with event: NSEvent) {
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + event.magnification)))
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else {
                super.scrollWheel(with: event)
                return
            }
            let delta = max(-10, min(10, event.scrollingDeltaY))
            guard delta != 0 else { return }
            scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * (1 + delta * 0.02)))
        }
    }
}

struct ZoomableImagePreview: NSViewRepresentable {
    let image: NSImage
    var animatedData: Data? = nil
    var fullResData: Data? = nil

    func makeNSView(context: Context) -> FitOnLayoutScrollView {
        let scrollView = FitOnLayoutScrollView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 8

        let imageView = NSImageView()
        if let animatedData, let animated = NSImage(data: animatedData) {
            imageView.image = animated
            imageView.animates = true
            scrollView.lastImageDataCount = animatedData.count
        } else if let fullResData {
            imageView.image = image
            scrollView.lastImageDataCount = fullResData.count
            Self.decodeFullRes(fullResData, into: imageView, scrollView: scrollView)
        } else {
            imageView.image = image
        }
        imageView.imageScaling = .scaleProportionallyUpOrDown
        scrollView.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: scrollView,
                                                   action: #selector(FitOnLayoutScrollView.toggleZoom(_:)))
        doubleClick.numberOfClicksRequired = 2
        imageView.addGestureRecognizer(doubleClick)
        return scrollView
    }

    func updateNSView(_ scrollView: FitOnLayoutScrollView, context: Context) {
        guard let imageView = scrollView.documentView as? NSImageView else { return }
        if let animatedData {
            guard scrollView.lastImageDataCount != animatedData.count else { return }
            imageView.image = NSImage(data: animatedData)
            imageView.animates = true
            scrollView.lastImageDataCount = animatedData.count
            scrollView.magnification = 1
        } else if let fullResData {
            guard scrollView.lastImageDataCount != fullResData.count else { return }
            imageView.image = image
            scrollView.lastImageDataCount = fullResData.count
            scrollView.magnification = 1
            Self.decodeFullRes(fullResData, into: imageView, scrollView: scrollView)
        } else if imageView.image !== image {
            imageView.image = image
            scrollView.magnification = 1
        }
    }

    private static func decodeFullRes(_ data: Data, into imageView: NSImageView,
                                      scrollView: FitOnLayoutScrollView) {
        DispatchQueue.global(qos: .userInitiated).async {
            let full = NSImage(data: data)
            DispatchQueue.main.async {
                guard let full, scrollView.lastImageDataCount == data.count else { return }
                imageView.image = full
            }
        }
    }

    final class FitOnLayoutScrollView: NSScrollView {
        var lastImageDataCount: Int?

        override func layout() {
            super.layout()
            if magnification <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        // Explicitly handle trackpad pinch. The preview lives in a
        // non-activating panel, so NSScrollView's built-in magnification can't
        // be relied on to receive the gesture — overriding magnify(with:)
        // guarantees pinch-to-zoom works even while ⌘ is held for the popup.
        override func magnify(with event: NSEvent) {
            let target = min(maxMagnification, max(minMagnification, magnification * (1 + event.magnification)))
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            setMagnification(target, centeredAt: point)
            if target <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.modifierFlags.contains(.command) else {
                super.scrollWheel(with: event)
                return
            }
            let delta = max(-10, min(10, event.scrollingDeltaY))
            guard delta != 0 else { return }
            let target = min(maxMagnification, max(minMagnification, magnification * (1 + delta * 0.02)))
            let point = documentView?.convert(event.locationInWindow, from: nil) ?? .zero
            setMagnification(target, centeredAt: point)
            if target <= 1.001 {
                documentView?.frame = contentView.bounds
            }
        }

        @objc func toggleZoom(_ gesture: NSClickGestureRecognizer) {
            let target: CGFloat = magnification <= 1.001 ? 2.5 : 1
            let point = gesture.location(in: documentView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                animator().setMagnification(target, centeredAt: point)
            }
            if target == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
                    guard let self, self.magnification <= 1.001 else { return }
                    self.documentView?.frame = self.contentView.bounds
                }
            }
        }
    }
}

/// One shared WKWebView reused across every HTMLStringPreview mount. Building
/// a WebKit view is 100-200 ms (WebKit process, JS context, layout engine);
/// cycling through HTML items used to pay that cost per item. Because only
/// one HTML preview is visible at any time (the popover shows one item and
/// swaps rootView on change), reuse is safe.
private enum HTMLWebViewPool {
    static let shared: WKWebView = {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = true
        return view
    }()
}

struct HTMLStringPreview: NSViewRepresentable {
    final class Coordinator {
        var lastHTML: String?
    }

    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let view = HTMLWebViewPool.shared
        // Reparent if AppKit tore off from a previous host — cheap when it's
        // already the child of nothing (fresh) or the same superview.
        view.removeFromSuperview()
        if context.coordinator.lastHTML != html {
            loadHTML(view)
            context.coordinator.lastHTML = html
        }
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


// ============================================================================
// Blob preview — the ".blob(typeMap)" content case used to just list the
// pasteboard type names. Freeform, Notes canvas fragments, WebKit-custom
// clipboards, private-app copies etc. all land here. When any of the blob's
// types map to a renderer we already have, use it — the shape/data on the
// clipboard is the same bytes the destination app would receive on paste, so
// this preview matches what pasting produces.
// ============================================================================

struct BlobContentPreview: View {
    let typeMap: [String: Data]

    var body: some View {
        Group {
            if let (image, data, dataType) = firstImage() {
                if dataType.contains("pdf"), let pdf = PDFDocument(data: data) {
                    PDFPreview(document: pdf)
                } else if dataType.contains("gif") {
                    ZoomableImagePreview(image: image, animatedData: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ZoomableImagePreview(image: image, fullResData: data)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
            } else if let pdf = firstPDF() {
                PDFPreview(document: pdf)
            } else if let attr = firstRichText() {
                let adjusted = attr.adjustingColorsForCurrentAppearance()
                AttributedTextPreview(attributedString: adjusted)
            } else if let svg = firstSVG() {
                let plain = String(data: svg, encoding: .utf8) ?? ""
                if !plain.isEmpty { textPreview(plain, monospaced: true) }
                else { fallbackTypeList }
            } else if let html = firstHTML() {
                HTMLStringPreview(html: html)
            } else if let text = firstUTF8Text() {
                textPreview(text, monospaced: shouldMonospace(text))
            } else {
                fallbackTypeList
            }
        }
    }

    // MARK: - Type resolvers

    private static let imageTypes: [String] = [
        "public.png", "public.tiff", "public.jpeg", "public.heic",
        "public.gif", "com.compuserve.gif", "com.adobe.pdf"
    ]

    private func firstImage() -> (NSImage, Data, String)? {
        for type in Self.imageTypes {
            guard let data = typeMap[type], let img = NSImage(data: data) else { continue }
            return (img, data, type)
        }
        return nil
    }

    private func firstPDF() -> PDFDocument? {
        guard let data = typeMap["com.adobe.pdf"] else { return nil }
        return PDFDocument(data: data)
    }

    private func firstRichText() -> NSAttributedString? {
        for type in ["com.apple.flat-rtfd", "public.rtfd", "NSRTFDPboardType"] {
            if let data = typeMap[type],
               let attr = NSAttributedString(rtfd: data, documentAttributes: nil),
               !attr.string.isEmpty { return attr }
        }
        for type in ["public.rtf", "NSRTFPboardType"] {
            if let data = typeMap[type],
               let attr = NSAttributedString(rtf: data, documentAttributes: nil),
               !attr.string.isEmpty { return attr }
        }
        return nil
    }

    private func firstSVG() -> Data? {
        for type in ["public.svg-image", "com.adobe.illustrator.svg", "org.w3.svg"] {
            if let data = typeMap[type], !data.isEmpty { return data }
        }
        return nil
    }

    private func firstHTML() -> String? {
        for type in ["public.html", "Apple HTML pasteboard type"] {
            guard let data = typeMap[type] else { continue }
            let s = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1)
            if let s, !s.isEmpty { return s }
        }
        return nil
    }

    private static let plainTextPreferred = [
        "public.utf8-plain-text", "public.plain-text", "public.text", "NSStringPboardType"
    ]

    private func firstUTF8Text() -> String? {
        for type in Self.plainTextPreferred {
            if let data = typeMap[type],
               let s = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
               !s.isEmpty { return s }
        }
        // Some private types are actually plain UTF-8 payloads; opportunistic
        // decode as a last resort before giving up on the whole clipping.
        for (_, data) in typeMap where data.count < 128_000 {
            if let s = String(data: data, encoding: .utf8),
               !s.isEmpty, s.allSatisfy({ $0.isASCII || $0.isLetter || $0.isNumber || $0.isPunctuation || $0.isWhitespace }) {
                return s
            }
        }
        return nil
    }

    private func shouldMonospace(_ s: String) -> Bool {
        s.contains("{") || s.contains("[") || s.contains("\t") || s.contains("<?xml")
    }

    // MARK: - Fallback

    private var fallbackTypeList: some View {
        textPreview(typeMap.keys.sorted().map { "· \($0)" }.joined(separator: "\n"),
                    monospaced: true)
    }

    private func textPreview(_ text: String, monospaced: Bool) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Loads a file-URL image with NSImage on a background queue, shows a spinner
/// until the image lands. Cycling to a big HEIC/PNG file in the preview no
/// longer freezes main while NSImage reads and decodes the whole file.

struct AsyncImageFilePreview: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ZoomableImagePreview(image: image)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = nil
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// `PDFDocument(url:)` reads and parses the whole file — for a large PDF
/// that's a real main-thread stall. Same async-decode pattern as
/// AsyncImageFilePreview above.
struct AsyncPDFFilePreview: View {
    let url: URL
    @State private var document: PDFDocument?
    @State private var failed = false

    var body: some View {
        Group {
            if let document {
                PDFPreview(document: document)
            } else if failed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            document = nil
            failed = false
            let loaded = await Task.detached(priority: .userInitiated) {
                PDFDocument(url: url)
            }.value
            guard !Task.isCancelled else { return }
            if let loaded { document = loaded } else { failed = true }
        }
    }
}

/// `Data(contentsOf:)` + `NSImage(data:)` for a large animated GIF is real
/// main-thread I/O + decode work. Same async pattern as the image/PDF cases.
struct AsyncGIFFilePreview: View {
    let url: URL
    @State private var loaded: (image: NSImage, data: Data)?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded {
                ZoomableImagePreview(image: loaded.image, animatedData: loaded.data)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if failed {
                QuickLookFilePreview(url: url)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            loaded = nil
            failed = false
            let result = await Task.detached(priority: .userInitiated) { () -> (NSImage, Data)? in
                guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { return nil }
                return (image, data)
            }.value
            guard !Task.isCancelled else { return }
            if let result { loaded = result } else { failed = true }
        }
    }
}
