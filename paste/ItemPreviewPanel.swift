import AppKit
import AVKit
import Quartz
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
        level = .floating
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.24), radius: 22, x: 0, y: 10)
    }

    @ViewBuilder
    private var content: some View {
        switch item.content {
        case .text(let text):
            textPreview(text, monospaced: true)
        case .richText(_, plain: let text), .html(_, plain: let text):
            textPreview(text, monospaced: false)
        case .image(let image, let data, let dataType):
            if dataType.rawValue.contains("pdf"), let pdf = PDFDocument(data: data) {
                PDFPreview(document: pdf)
            } else {
                imagePreview(image)
            }
        case .file(let url):
            filePreview(url)
        case .files(let urls):
            fileListPreview(urls)
        }
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
        } else if let image = NSImage(contentsOf: url) {
            imagePreview(image)
        } else if FileKindDetector.isHTMLFile(url) {
            HTMLFilePreview(url: url)
        } else if let text = FileKindDetector.readableText(from: url) {
            textPreview(text, monospaced: true)
        } else if FileKindDetector.isMediaFile(url) {
            AVMediaPreview(url: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            QuickLookFilePreview(url: url)
        } else {
            VStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
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

private struct HTMLFilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        load(url, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        load(url, in: view)
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
        // Create the player but do NOT call play() — user presses play manually.
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        // Only swap the player when the URL actually changes to avoid restarting.
        guard (view.player?.currentItem?.asset as? AVURLAsset)?.url != url else { return }
        view.player?.pause()
        view.player = AVPlayer(url: url)
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
        view.autostarts = false   // Do NOT auto-play audio/video inside QL previews.
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
        view.document = document
    }
}
