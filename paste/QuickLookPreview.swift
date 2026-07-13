import AppKit
import Quartz

@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var previewItems: [URL] = []

    func toggle(for item: ClipboardItem) {
        guard let panel = QLPreviewPanel.shared() else { return }
        let urls = Self.previewURLs(for: item)
        guard !urls.isEmpty else { return }

        if panel.isVisible, previewItems == urls {
            panel.orderOut(nil)
            return
        }
        previewItems = urls
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems.indices.contains(index) ? previewItems[index] as QLPreviewItem : nil
    }

    private static func previewURLs(for item: ClipboardItem) -> [URL] {
        switch item.content {
        case .file(let url) where FileManager.default.fileExists(atPath: url.path):
            return [url]
        case .files(let urls):
            return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        case .image(_, let rawData, let dataType):
            let ext = dataType.rawValue.contains("gif") ? "gif"
                : dataType.rawValue.contains("png") ? "png"
                : dataType.rawValue.contains("pdf") ? "pdf"
                : "jpg"
            return tempFile(for: item.id, data: rawData, ext: ext).map { [$0] } ?? []
        case .svg(let source):
            return tempFile(for: item.id, data: Data(source.utf8), ext: "svg").map { [$0] } ?? []
        case .html(let html, plain: _):
            return tempFile(for: item.id, data: Data(html.utf8), ext: "html").map { [$0] } ?? []
        case .rtfd(let data, plain: _):
            return tempFile(for: item.id, data: data, ext: "rtfd").map { [$0] } ?? []
        case .richText(let attributed, plain: _):
            guard let rtf = try? attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            else { return [] }
            return tempFile(for: item.id, data: rtf, ext: "rtf").map { [$0] } ?? []
        case .text(let s):
            return tempFile(for: item.id, data: Data(s.utf8), ext: "txt").map { [$0] } ?? []
        case .file, .blob:
            return []
        }
    }

    private static func tempFile(for id: UUID, data: Data, ext: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipenQuickLook/\(id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preview.\(ext)")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
