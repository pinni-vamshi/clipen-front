import AppKit
import Foundation

enum ToolRegistry {
    static func tools(for item: ClipboardItem) -> [ClipboardTool] {
        applicable(toolPool(for: item), to: item)
    }

    /// One primary pool per item so image/PDF/file tools sort among themselves
    /// (usage scores), not buried under unrelated text tools.
    private static func toolPool(for item: ClipboardItem) -> [ClipboardTool] {
        let tags = Set(item.tags)
        if tags.contains(.image) { return ImageTools.all }
        if tags.contains(.pdf) { return PDFTools.all }
        if tags.contains(.video) || tags.contains(.audio) { return MediaTools.all }
        if tags.contains(.files) { return FileTools.all }
        if tags.contains(.file) { return FileTools.all }
        return mergedPools(for: item.tags)
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

    /// Union tool lists for every tag on the item (deduped by tool id).
    private static func mergedPools(for tags: [ClipboardTag]) -> [ClipboardTool] {
        var seen = Set<String>()
        var merged: [ClipboardTool] = []
        merged.reserveCapacity(48)

        for tag in tags.sorted(by: { $0.priority < $1.priority }) {
            for tool in pool(for: tag) where seen.insert(tool.id).inserted {
                merged.append(tool)
            }
        }
        return merged
    }

    private static func pool(for tag: ClipboardTag) -> [ClipboardTool] {
        switch tag {
        case .image:
            return ImageTools.all
        case .pdf:
            return PDFTools.all
        case .file, .files:
            return FileTools.all
        case .video, .audio:
            return MediaTools.all
        case .html, .richText, .url, .json, .markdown, .latex, .table,
             .email, .phone, .address, .code, .color, .text:
            return TextTools.all + FileTools.all
        }
    }

    private static func applicable(_ tools: [ClipboardTool], to item: ClipboardItem) -> [ClipboardTool] {
        let filtered = tools.filter { tool in
            if tool.id == "image.ocr", !AuthManager.shared.ocrEnabled { return false }
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
