import AppKit
import Foundation

enum ToolRegistry {
    static func tools(for item: ClipboardItem) -> [ClipboardTool] {
        applicable(toolPool(for: item), to: item)
    }

    /// One primary pool per item so image/PDF/file tools sort among themselves
    /// (usage scores), not buried under unrelated text tools.
    private static func toolPool(for item: ClipboardItem) -> [ClipboardTool] {
        switch item.content {
        case .image:
            return ImageTools.all

        case .file(let url):
            if FileKindDetector.isVideoFile(url) || FileKindDetector.isAudioFile(url) {
                return MediaTools.all
            }
            if url.pathExtension.lowercased() == "pdf" {
                return PDFTools.all
            }
            return FileTools.all

        case .files(let urls):
            if let first = urls.first,
               urls.count == 1,
               (FileKindDetector.isVideoFile(first) || FileKindDetector.isAudioFile(first)) {
                return MediaTools.all
            }
            return FileTools.all

        case .text, .richText, .html:
            return TextTools.all + FileTools.all
        }
    }

    static func displays(for item: ClipboardItem) -> [TransformDisplay] {
        tools(for: item).map { tool in
            let preview = tool.preview(item)
            return TransformDisplay(
                id: tool.id,
                icon: tool.icon,
                label: tool.label,
                group: tool.group,
                preview: preview?.isEmpty == true ? nil : preview
            )
        }
    }

    static func isAsync(item: ClipboardItem, index: Int) -> Bool {
        guard tools(for: item).indices.contains(index) else { return false }
        return tools(for: item)[index].isAsync
    }

    static func runSync(item: ClipboardItem, index: Int) -> TransformOutput? {
        let tools = tools(for: item)
        guard tools.indices.contains(index), let runSync = tools[index].runSync else { return nil }
        return runSync(item)
    }

    static func run(item: ClipboardItem, index: Int) async -> TransformOutput? {
        let tools = tools(for: item)
        guard tools.indices.contains(index) else { return nil }
        return await tools[index].runAsync(item)
    }

    static func isAsync(item: ClipboardItem, toolID: String) -> Bool {
        guard let tool = tool(for: item, toolID: toolID) else { return false }
        return tool.isAsync
    }

    static func runSync(item: ClipboardItem, toolID: String) -> TransformOutput? {
        guard let tool = tool(for: item, toolID: toolID),
              let runSync = tool.runSync else { return nil }
        return runSync(item)
    }

    static func run(item: ClipboardItem, toolID: String) async -> TransformOutput? {
        guard let tool = tool(for: item, toolID: toolID) else { return nil }
        return await tool.runAsync(item)
    }

    static func toolID(item: ClipboardItem, index: Int) -> String? {
        let tools = tools(for: item)
        guard tools.indices.contains(index) else { return nil }
        return tools[index].id
    }

    private static func applicable(_ tools: [ClipboardTool], to item: ClipboardItem) -> [ClipboardTool] {
        let filtered = tools.filter { tool in
            if tool.id == "image.ocr", !AuthManager.shared.ocrEnabled { return false }
            if (tool.id == "pdf.extract-all-text" || tool.id == "pdf.first-page-text"),
               !AuthManager.shared.pdfTextExtract {
                return false
            }
            if tool.preview(item) != nil { return true }
            if let runSync = tool.runSync {
                if case .status = runSync(item) { return false }
            }
            return false
        }
        let catalogOrder = Dictionary(uniqueKeysWithValues: tools.enumerated().map { ($1.id, $0) })
        return filtered.sorted { lhs, rhs in
            let ls = AuthManager.shared.toolImportanceScore(for: lhs.id)
            let rs = AuthManager.shared.toolImportanceScore(for: rhs.id)
            if ls != rs { return ls > rs }
            return (catalogOrder[lhs.id] ?? .max) < (catalogOrder[rhs.id] ?? .max)
        }
    }

    private static func tool(for item: ClipboardItem, toolID: String) -> ClipboardTool? {
        tools(for: item).first(where: { $0.id == toolID })
    }
}
