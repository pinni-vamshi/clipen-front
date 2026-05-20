import AppKit
import Foundation

enum ToolRegistry {
    static func tools(for item: ClipboardItem) -> [ClipboardTool] {
        switch item.content {
        case .text, .richText, .html:
            return applicable(TextTools.all + FileTools.all, to: item)
        case .image(_, _, let dataType) where dataType.rawValue.contains("pdf"):
            return applicable(PDFTools.all, to: item)
        case .image:
            return applicable(ImageTools.all, to: item)
        case .file(let url) where url.pathExtension.lowercased() == "pdf":
            return applicable(FileTools.all + PDFTools.all, to: item)
        case .file(let url) where FileKindDetector.isImageFile(url):
            return applicable(FileTools.all + ImageTools.all, to: item)
        case .file(let url) where FileKindDetector.isMediaFile(url):
            return applicable(FileTools.all + MediaTools.all, to: item)
        case .file:
            return applicable(FileTools.all + TextTools.all, to: item)
        case .files:
            return applicable(FileTools.all, to: item)
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

    static func toolID(item: ClipboardItem, index: Int) -> String? {
        let tools = tools(for: item)
        guard tools.indices.contains(index) else { return nil }
        return tools[index].id
    }

    private static func applicable(_ tools: [ClipboardTool], to item: ClipboardItem) -> [ClipboardTool] {
        let filtered = tools.filter { tool in
            if tool.preview(item) != nil { return true }
            if let runSync = tool.runSync {
                if case .status = runSync(item) { return false }
            }
            return false
        }
        return filtered.sorted { lhs, rhs in
            let ls = AuthManager.shared.toolImportanceScore(for: lhs.id)
            let rs = AuthManager.shared.toolImportanceScore(for: rhs.id)
            if ls == rs {
                // Keep original declaration order stable for ties.
                return (tools.firstIndex(where: { $0.id == lhs.id }) ?? .max)
                    < (tools.firstIndex(where: { $0.id == rhs.id }) ?? .max)
            }
            return ls > rs
        }
    }
}
